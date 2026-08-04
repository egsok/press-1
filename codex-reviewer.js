const fs = require("fs");
const path = require("path");
const os = require("os");
const { TextDecoder } = require("util");

// press-1 — Codex auto-review detector (experimental, default-on). Extracted
// from codex-permission-request.js as a self-contained unit: this whole file
// exists only because the current PermissionRequest payload does not expose the
// effective reviewer. When upstream ships an official reviewer/defer field
// (openai/codex#23465), replace the transcript probe with that field and delete
// this module. Deployed next to the hook in ~/.codex/hooks/ (install.ps1).
// NOTE: Codex trusted_hash covers the entry hook script only — this module
// rides along in the same deploy dir without its own trust hash.
//
// Contract (docs/ARCHITECTURE.md, "Exact same-turn Auto-review bypass"): a
// proven exact same-turn turn_context.approvals_reviewer === "auto_review" lets
// the caller exit 0 empty (no pending/sound); ANY ambiguity or failure keeps
// the popup. The probe never leaks transcript/request data into its result.

const PERM_DIR = path.join(
  process.env.TEMP || path.join(process.env.USERPROFILE, "AppData", "Local", "Temp"),
  "press-1"
);

// Codex can route an approval to its auto-reviewer, but the current
// PermissionRequest payload does not expose that reviewer directly. On every
// standard hook route, inspect the matching turn_context in the bounded local
// rollout tail. Default-on; this dedicated flag restores the normal popup. Its
// Desktop-specific filename is retained as a compatibility contract.
const CODEX_AUTO_REVIEW_OFF_FLAG = process.env.USERPROFILE
  ? path.join(process.env.USERPROFILE, ".press-1-off-codex-desktop-auto-review")
  : "";
const REVIEWER_STATUS_FILE = path.join(PERM_DIR, "codex-reviewer-last.json");
const REVIEWER_SCAN_MAX_BYTES = 32 * 1024 * 1024;
const REVIEWER_READ_CHUNK_BYTES = 256 * 1024;
// Semantic cap for a reviewer-bearing turn_context candidate. Other complete
// JSONL records may legitimately be larger (for example embedded image/tool
// outputs), but the enclosing snapshot remains bounded by REVIEWER_SCAN_MAX_BYTES.
const REVIEWER_LINE_MAX_BYTES = 4 * 1024 * 1024;
// Buffer.toString("utf8") silently replaces malformed bytes with U+FFFD. Fatal
// decoding is required before top-level type classification: corruption must
// never turn a would-be turn_context into an apparently irrelevant record.
const REVIEWER_UTF8_DECODER = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const REVIEWER_BUDGET_MS = 250;
const REVIEWER_MAX_ATTEMPTS = 3;

// The experimental reviewer bypass has an opt-OUT preference, so lookup errors
// must fail toward the popup. Only a definite ENOENT proves that the flag is
// absent; a missing profile/path or any other filesystem result disables the
// probe for this request. This stricter policy is local to the experimental
// feature — the hook's long-standing master flags intentionally use flagExists().
function autoReviewOptOutState() {
  if (!CODEX_AUTO_REVIEW_OFF_FLAG) return "unknown";
  try {
    fs.lstatSync(CODEX_AUTO_REVIEW_OFF_FLAG);
    return "present";
  } catch (error) {
    return error && error.code === "ENOENT" ? "absent" : "unknown";
  }
}

function reviewerBudgetExpired(started) {
  return Date.now() - started >= REVIEWER_BUDGET_MS;
}

function isUncOrDevicePath(file) {
  return /^[\\/]{2}/.test(file);
}

// Native/resumed Codex threads on Windows can serialize an ordinary local
// drive transcript or CODEX_HOME with the extended-length spelling
// `\\?\C:\...`. Node 22's realpathSync cannot consume that spelling reliably,
// and treating every `\\` prefix as unsafe conflates it with remote/arbitrary
// device namespaces. Strip ONLY the exact local-drive form; UNC, `\\.\`,
// `\\?\UNC`, GLOBALROOT, volume GUID and every other namespace keep their
// leading separators and are rejected by isUncOrDevicePath(). Normalized paths
// still have to pass extension, canonical containment and regular-file checks.
function normalizeExtendedLocalDrivePath(file) {
  const match = /^\\\\\?\\([A-Za-z]:\\[^/:\0\r\n]*)$/.exec(file);
  return match && match[0].length === file.length ? match[1] : file;
}

function isInsidePath(file, root) {
  const rel = path.relative(root, file);
  return !!rel && rel !== ".." && !rel.startsWith(".." + path.sep) && !path.isAbsolute(rel);
}

function reviewerResult(reason, started, metrics) {
  return {
    schema: 1,
    ts: Date.now(),
    pid: process.pid,
    outcome: reason === "exact_auto_review" ? "auto_pass" : "popup",
    reason,
    elapsed_ms: Math.max(0, Date.now() - started),
    attempts: metrics.attempts,
    file_bytes: metrics.file_bytes,
    scanned_bytes: metrics.scanned_bytes,
    grew: metrics.grew,
    tail_truncated: metrics.tail_truncated,
  };
}

// Parse complete JSONL records from a bounded file snapshot. When the snapshot
// begins inside an older line, that first fragment is discarded: it lies beyond
// the authorized 32 MiB tail and must not become a malformed-record false alarm.
function scanReviewerRecords(buffer, tailTruncated, turnId, started) {
  let lineStart = 0;
  if (tailTruncated) {
    const firstNl = buffer.indexOf(0x0a);
    if (firstNl === -1) return "record_invalid";
    lineStart = firstNl + 1;
  }

  let invalid = false;
  const reviewers = new Map();
  while (lineStart < buffer.length) {
    if (reviewerBudgetExpired(started)) return "budget_exceeded";
    const nl = buffer.indexOf(0x0a, lineStart);
    let lineEnd = nl === -1 ? buffer.length : nl;
    if (lineEnd > lineStart && buffer[lineEnd - 1] === 0x0d) lineEnd--;
    const lineBytes = lineEnd - lineStart;
    if (lineBytes > 0) {
      let record;
      try {
        const line = REVIEWER_UTF8_DECODER.decode(buffer.subarray(lineStart, lineEnd));
        record = JSON.parse(line);
      }
      catch { invalid = true; }
      if (reviewerBudgetExpired(started)) return "budget_exceeded";
      if (record && record.type === "turn_context") {
        if (lineBytes > REVIEWER_LINE_MAX_BYTES) {
          invalid = true;
        } else {
          const payload = record.payload;
          if (!payload || typeof payload !== "object" || Array.isArray(payload)
            || typeof payload.turn_id !== "string") {
            invalid = true;
          } else if (payload.turn_id === turnId) {
            if (!Object.prototype.hasOwnProperty.call(payload, "approvals_reviewer")) {
              invalid = true;
            } else {
              const reviewer = payload.approvals_reviewer;
              if (reviewer !== null && typeof reviewer !== "string") {
                invalid = true;
              } else {
                const key = reviewer === null ? "null" : "string:" + reviewer;
                reviewers.set(key, reviewer);
              }
            }
          }
        }
      }
    }
    if (nl === -1) break;
    lineStart = nl + 1;
  }

  if (invalid) return "record_invalid";
  if (reviewers.size === 0) return "turn_not_found";
  if (reviewers.size > 1) return "reviewer_conflict";
  const reviewer = reviewers.values().next().value;
  if (reviewer === "auto_review") return "exact_auto_review";
  if (reviewer === "user") return "reviewer_user";
  return "reviewer_other";
}

// The detector is deliberately self-contained and fail-safe: every ambiguity or
// I/O/parser failure returns popup. It never leaks transcript/request data into
// its result, which is also the complete diagnostic-status schema.
function probeCodexReviewer(data) {
  const started = Date.now();
  const metrics = {
    attempts: 0,
    file_bytes: 0,
    scanned_bytes: 0,
    grew: false,
    tail_truncated: false,
  };
  const done = (reason) => reviewerResult(reason, started, metrics);

  if (!data || typeof data.turn_id !== "string" || !data.turn_id
    || typeof data.transcript_path !== "string" || !data.transcript_path) {
    return done("input_missing");
  }

  const transcript = normalizeExtendedLocalDrivePath(data.transcript_path);
  if (!path.isAbsolute(transcript) || isUncOrDevicePath(transcript)
    || path.extname(transcript).toLowerCase() !== ".jsonl") {
    return done("path_rejected");
  }

  const codexHome = normalizeExtendedLocalDrivePath(
    process.env.CODEX_HOME || path.join(process.env.USERPROFILE || os.homedir(), ".codex")
  );
  const sessionsRoot = path.join(codexHome, "sessions");
  if (!path.isAbsolute(sessionsRoot) || isUncOrDevicePath(sessionsRoot)) {
    return done("path_rejected");
  }
  // Cheap lexical rejection first; canonical real paths below are still the
  // actual containment boundary (and catch symlink/junction escapes).
  if (!isInsidePath(path.resolve(transcript), path.resolve(sessionsRoot))) {
    return done("path_rejected");
  }

  let realRoot;
  let realTranscript;
  try { realRoot = fs.realpathSync(sessionsRoot); }
  catch { return done("read_failed"); }
  try { realTranscript = fs.realpathSync(transcript); }
  catch { return done("read_failed"); }
  if (isUncOrDevicePath(realTranscript)
    || path.extname(realTranscript).toLowerCase() !== ".jsonl"
    || !isInsidePath(realTranscript, realRoot)) {
    return done("path_rejected");
  }
  if (reviewerBudgetExpired(started)) return done("budget_exceeded");

  let fd;
  try {
    fd = fs.openSync(realTranscript, "r");
    for (;;) {
      if (reviewerBudgetExpired(started) || metrics.attempts >= REVIEWER_MAX_ATTEMPTS)
        return done("budget_exceeded");
      metrics.attempts++;

      const before = fs.fstatSync(fd);
      metrics.file_bytes = before.size;
      if (!before.isFile()) return done("path_rejected");
      const readLength = Math.min(before.size, REVIEWER_SCAN_MAX_BYTES);
      const readStart = before.size - readLength;
      metrics.scanned_bytes = 0;
      metrics.tail_truncated = readStart > 0;
      const buffer = Buffer.allocUnsafe(readLength);
      while (metrics.scanned_bytes < readLength) {
        if (reviewerBudgetExpired(started)) return done("budget_exceeded");
        // Sync filesystem calls themselves cannot be preempted. Keep each one
        // small, then re-check the wall-clock deadline immediately afterward so
        // a 32 MiB snapshot is never one unbounded read from the hook's budget.
        const chunkLength = Math.min(
          readLength - metrics.scanned_bytes,
          REVIEWER_READ_CHUNK_BYTES
        );
        const n = fs.readSync(fd, buffer, metrics.scanned_bytes,
          chunkLength, readStart + metrics.scanned_bytes);
        if (n === 0) break;
        metrics.scanned_bytes += n;
        if (reviewerBudgetExpired(started)) return done("budget_exceeded");
      }
      if (metrics.scanned_bytes !== readLength) return done("read_failed");

      const afterRead = fs.fstatSync(fd);
      metrics.file_bytes = afterRead.size;
      if (afterRead.size > before.size) metrics.grew = true;
      if (afterRead.size !== before.size || afterRead.mtimeMs !== before.mtimeMs) continue;

      const reason = scanReviewerRecords(buffer, metrics.tail_truncated, data.turn_id, started);
      if (reason === "budget_exceeded") return done(reason);

      const afterScan = fs.fstatSync(fd);
      metrics.file_bytes = afterScan.size;
      if (afterScan.size > before.size) metrics.grew = true;
      if (afterScan.size !== before.size || afterScan.mtimeMs !== before.mtimeMs) continue;
      if (reviewerBudgetExpired(started)) return done("budget_exceeded");
      return done(reason);
    }
  } catch {
    return done("read_failed");
  } finally {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch {}
    }
  }
}

function writeReviewerStatus(status) {
  let tmp = "";
  try {
    fs.mkdirSync(PERM_DIR, { recursive: true });
    tmp = REVIEWER_STATUS_FILE + ".tmp-" + process.pid + "-" + Date.now();
    fs.writeFileSync(tmp, JSON.stringify(status), "utf8");
    fs.renameSync(tmp, REVIEWER_STATUS_FILE);
  } catch {
    if (tmp) {
      try { fs.unlinkSync(tmp); } catch {}
    }
  }
}

// Returns true only for a proven current-turn auto-review. The opt-out flag does
// not probe or touch status. PRESS1_PROXY exits before this function because its
// requests are already post-review, real manual approvals. Unexpected failures
// are contained locally and preserve the existing popup route.
function shouldPassCodexAutoReview(data) {
  if (autoReviewOptOutState() !== "absent") return false;
  let status;
  try { status = probeCodexReviewer(data); }
  catch {
    const started = Date.now();
    status = reviewerResult("read_failed", started, {
      attempts: 0, file_bytes: 0, scanned_bytes: 0, grew: false, tail_truncated: false,
    });
  }
  // Close the small toggle race: a flag created (or made unreadable) while the
  // bounded probe ran still restores the popup and leaves no misleading status.
  if (autoReviewOptOutState() !== "absent") return false;
  writeReviewerStatus(status);
  return status.outcome === "auto_pass";
}

module.exports = { shouldPassCodexAutoReview };
