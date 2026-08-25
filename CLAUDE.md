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
