# Offline test suites

Three suites cover the protocol logic without a live Claude Code session. Sandboxes live in `%TEMP%\press-1-tests\` — the repo tree is never written to.

| Suite | What it covers | Run |
|-------|----------------|-----|
| `hook.test.js` (62) | host fingerprint classification, decision channel for editor-terminal/panel/WT/conhost (allow / always-echo / deny), `editor_exe` capture, 60-min window + early-exit, picker liveness beacon, readable tool summaries (ExitPlanMode → label, or plan text with `#`/`##` headings stripped — not JSON), teardown interplay | `node tests/hook.test.js` |
| `ahk-harness.ahk` (56) | pending parsing (anchor guards), row build + FIFO, decision_file + `editor_exe` wiring, `wait_until` cutoff, liveness gates (dead window, dead hook PID, dead picker beacon), editor-terminal/panel/standalone rows, digit→word mapping | `& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests\ahk-harness.ahk` → results in `%TEMP%\press-1-tests\ahk-out.txt` |
| `merge-hooks.test.js` (27) | settings.json merge: clean machine, foreign hooks preserved, idempotency, command/timeout upgrade (PermissionRequest ≥ 3660), fail-loud on invalid JSON | `node tests/merge-hooks.test.js` |

Notes:

- The AHK harness `#Include`s the real `press-1.ahk` and then redirects its directories to the sandbox — run it from the repo so the relative include resolves. It exercises parsing/lifecycle functions only; no popups are shown.
- The hook suite spawns the real `permission-request.js` as a child with an isolated `TEMP`, exactly like Claude Code would (stdin payload → stdout decision). Editor-terminal/panel/standalone permission hooks now block on the decision channel, so the suite reaps the blocked children at the end of those cases.
- Run all three after any change to `permission-request.js`, `session-teardown.js`, `press-1.ahk`, or `merge-hooks.js`.
