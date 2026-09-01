# CLAUDE.md

- Install: `make install PREFIX=~/.local` (or `sudo make install`); no build step
- Tests: `bash tests/run_all.sh`

## Non-Obvious Rules

- The script must **always exit 0** with valid Waybar JSON (`{"text","tooltip","class"}`), even on errors — Waybar hides modules that exit non-zero. Use `die()`. Tooltip and bar text are Pango markup.
- **The CLI always runs through `/bin/sh -c 'exec "$0" "$@"'`, never direct.** A nonexistent binary handed to Quickshell 0.3.1 can abort the whole shell inside the failed start (#6), before any QML signal fires. The failed-start discriminator is `!sawExit || exitCode === 126 || exitCode === 127` on empty output; any other exited-empty run is an operational failure, never "not installed".
- **The bundled-script fallback fires ONLY on a failed start.** PATH first, always: the AUR release wins when it exists. Never fall back on operational errors.
- **`schema_version` is pinned to 2 on both sides.** A schema bump must change script, panel and tests in one commit.
- **`installCmd` is the one constant** — the message shows it and the button copies it (argv-exec, no shell line). The button gates on `notInstalled`, never on error text.
- **A tooltip meter is PARKED, not rendered in place**: a `METER:<i>` sentinel plus parallel `meter_*` arrays, resolved by the width pass — which must skip `METER:` lines or the measurement is circular. All meters in one tooltip share the same bar length. After mutating `BAR_LEN`, rebuild `GRAD_CELLS` (`GRAD_CELLS=(); init_grad_cells`) — indexing past it is fatal under `set -u`.

## Hardening invariants

The plugin runs inside the long-lived omarchy-shell process, so a blocking read
or write takes the whole shell down. Regression tests live in
`tests/test_hardening.sh`; the rationale for each rule is in the script's own
comments at the relevant site.

- Every read of a file this script does not own goes through `read_bounded` (O_NONBLOCK open + byte cap); `jq` never opens a foreign path itself.
- Every write on a predictable path is guarded, on the fd where one exists. The credentials write-back stages its temp in the SAME directory as the target (rename(2), atomic), creates it BEFORE the refresh POST (a 200 may rotate the refresh token), and re-reads + compares before the `mv` (the claude CLI also writes that file).
- Every `curl` starts with `-q` as the FIRST argument. `curl_auth_cfg` is the only place a curl config is built, and it REJECTS tokens that could inject config lines.
- Secrets never go in argv — stdin for curl (`--config -`, `--data @-`), the environment for jq.
- The panel refuses to retain more than 1Mi UTF-16 units of CLI output (a tripwire with a per-run flag, not a limit).
