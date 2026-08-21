#!/usr/bin/env bash
# Family contract: the rules claudebar and codexbar must answer the same way.
# Every assertion here has a byte-identical twin in codexbar/tests/test_family.sh
# (only the script name and the fixture change). When the two files stop
# mirroring each other, the family has drifted.
source "$(dirname "$0")/lib.sh"
MIN='{"five_hour":{"utilization":34,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":58,"resets_at":"2030-01-01T00:00:00+00:00"}}'

echo "== --help prints the reference and exits 0"
HELP=$("$SCRIPT" --help); RC=$?
[[ "$RC" -eq 0 ]] && _ok "--help: exit 0" || _no "--help: exit 0" "exit=$RC"
grep -q '^Usage: ' <<<"$HELP"            && _ok "--help: usage line"   || _no "--help: usage line" "$HELP"
grep -q -- '--no-color' <<<"$HELP"       && _ok "--help: documents --no-color" || _no "--help: documents --no-color" "missing"
grep -q -- '--frame' <<<"$HELP"          && _ok "--help: documents --frame"    || _no "--help: documents --frame" "missing"
grep -q '{icon}' <<<"$HELP"              && _ok "--help: documents {icon}"     || _no "--help: documents {icon}" "missing"
grep -q '^#' <<<"$HELP"                  && _no "--help: comment marks stripped" "leaked #" || _ok "--help: comment marks stripped"
HELP_H=$("$SCRIPT" -h)
[[ "$HELP_H" == "$HELP" ]] && _ok "-h is the same as --help" || _no "-h is the same as --help" "differs"

echo "== {icon} resolves to the widget mark"
run_claudebar "$MIN" --format '{icon}'
assert_exit0 "{icon}: exit 0"
_plain .text | grep -qF '{icon}' && _no "{icon} resolved" "left literal" || _ok "{icon} resolved"
_plain .text | grep -q '[^[:space:]]' && _ok "{icon} is not empty" || _no "{icon} is not empty" "blank"

echo "== --no-color strips UNQUOTED color attributes too"
run_claudebar "$MIN" --no-color --format "<span foreground=red>X</span> {session_pct}%"
assert_exit0 "unquoted attr: exit 0"
jq -r .text <<<"$OUT" | grep -q 'foreground' \
    && _no "unquoted foreground= stripped" "$(jq -r .text <<<"$OUT")" \
    || _ok "unquoted foreground= stripped"
jq -r .text <<<"$OUT" | grep -qF 'X' && _ok "…while the text survives" || _no "…while the text survives" "lost"

echo "== the bar tint is the continuous ramp at the DISPLAYED value"
# 34% sits between the low and mid anchors, so a stepped scale would paint it
# exactly the low anchor. The ramp must not.
run_claudebar "$MIN" --color-low '#000000' --color-mid '#ffffff' --format '{session_pct}%'
assert_exit0 "ramp: exit 0"
TINT=$(jq -r .text <<<"$OUT" | sed -n "s/.*foreground='\([^']*\)'.*/\1/p" | head -1)
[[ "$TINT" != "#000000" && "$TINT" != "" ]] \
    && _ok "34% is interpolated, not the low anchor ($TINT)" \
    || _no "34% is interpolated, not the low anchor" "tint=$TINT"

echo "== the network-loading tooltip breaks the line for real"
_lh=$(mktemp -d) || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
mkdir -p "$_lh/bin" "$_lh/.claude"
printf '#!/usr/bin/env bash\nexit 1\n' > "$_lh/bin/curl" && chmod +x "$_lh/bin/curl"
printf '%s' "$VALID_CREDS" > "$_lh/.claude/.credentials.json"
printf '%s' '{"oauthAccount":{"organizationUuid":"org-test"}}' > "$_lh/.claude.json"
OUT=$(run_pinned "$_lh" "$SCRIPT"); RC=$?
rm -rf "$_lh"
assert_exit0 "loading: exit 0"
jq -r .tooltip <<<"$OUT" | grep -qF '\n' \
    && _no "loading tooltip has no literal backslash-n" "$(jq -r .tooltip <<<"$OUT")" \
    || _ok "loading tooltip has no literal backslash-n"
[[ $(jq -r .tooltip <<<"$OUT" | wc -l) -ge 2 ]] \
    && _ok "loading tooltip is two real lines" \
    || _no "loading tooltip is two real lines" "$(jq -r .tooltip <<<"$OUT")"

finish
