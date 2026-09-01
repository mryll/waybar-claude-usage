#!/usr/bin/env bash
# Static contract of the bundled-script fallback (the panel runs the clone's
# own script when the PATH command cannot START) and the copy-install button.
# The QML has no test runner; these greps pin the load-bearing lines the same
# way test_hardening.sh pins the collector tripwire. Every expectation is
# written out by hand — a test that reads the constant it checks can never fail.
set -euo pipefail
cd "$(dirname "$0")/.."
panel=omarchy/Panel.qml
widget=omarchy/BarWidget.qml

pass=0
check() { # <desc> <cmd...>
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        echo "  ok   $desc"; pass=$((pass + 1))
    else
        echo "  FAIL $desc"; exit 1
    fi
}
check_absent() { # <desc> <pattern> <file>
    local desc=$1 pattern=$2 file=$3
    if grep -qF -- "$pattern" "$file"; then
        echo "  FAIL $desc"; exit 1
    else
        echo "  ok   $desc"; pass=$((pass + 1))
    fi
}

# -- the run goes through sh, never direct: handing Quickshell a nonexistent
#    binary aborts the whole shell inside the failed start (issue #6), before
#    any QML signal fires. sh always starts; a failed exec is sh exiting
#    126/127, which the empty branch maps to the failed-start path.
check "the command is wrapped in sh" \
    grep -qF "statusProc.command = [\"/bin/sh\", \"-c\", 'exec \"\$0\" \"\$@\"', resolvedBin].concat(args)" "$panel"
check "statusProc.command is assigned exactly once" \
    test "$(grep -cF 'statusProc.command =' "$panel")" = 1
check_absent "the direct (unwrapped) form is banned" 'statusProc.command = [resolvedBin]' "$panel"

# -- failed-start discrimination: sawExit is reset per run and set on exit;
#    the not-installed path is reachable without an exit (belt) or on sh's
#    exec failing with 126/127.
check "startRun resets sawExit"            grep -qF 'sawExit = false' "$panel"
check "onExited sets sawExit"              grep -qF 'root.sawExit = true' "$panel"
check "startRun resets tripwireFired"     grep -qF 'tripwireFired = false' "$panel"
check "the empty branch gates on the per-run tripwire flag, not stale text" \
                                           grep -qF 'if (tripwireFired) {' "$panel"
check "fallback gated on !sawExit or exec-failure codes" \
    grep -qF '} else if (!sawExit || exitCode === 126 || exitCode === 127) {' "$panel"
check "a run that exited empty never claims not-installed" \
                                           grep -qF 'produced no output (exit ' "$panel"

# -- PATH first, always: the resolved command starts as the bare name, and the
#    bundled path only ever replaces it, never precedes it.
check "resolvedBin starts at binName"      grep -qF 'property string resolvedBin: binName' "$panel"
check "fallback only from the PATH name"   grep -qF 'resolvedBin === binName && bundledCmd !== ""' "$panel"

# -- URL -> path derivation: segment-wise decode, no naive scheme strip.
check "urlToPath decodes each segment"     grep -qF 'split("/").map(decodeURIComponent).join("/")' "$widget"
check_absent "naive file:// replace is banned" 'replace("file://' "$widget"

# -- schema pinned on the panel side (the script side is pinned in test_json.sh).
check "handle() pins schema_version 2"     grep -qF 'Number(d.schema_version) !== 2' "$panel"

# -- copy-install button: one constant, argv-exec, gated on the flag.
check "installCmd literal appears exactly once" \
    test "$(grep -cF 'yay -S claudebar' "$panel")" = 1
check "wl-copy goes through execArgv argv-style" \
    grep -qF 'Util.execArgv(["wl-copy", root.installCmd])' "$panel"
check_absent "no shell line is built around wl-copy" 'bash -c' "$panel"
check "button gates on notInstalled, not on error text" \
    grep -qF 'visible: root.notInstalled' "$panel"

echo "test_bundled_fallback: $pass passed"
