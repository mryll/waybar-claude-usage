#!/usr/bin/env bash
# Simulated-API battery for --remaining mode. No network, no secrets.
source "$(dirname "$0")/lib.sh"

# --- Unit: remaining_pct_for clamps 0..100 (sourced indirectly via the script's behavior) ---
# 100 - used, clamped. Verified through the {session_remaining_pct} placeholder below;
# here we assert the boundary directly using --format.
run_claudebar '{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"}}' --format 'rem={session_remaining_pct}'
assert_exit0 "remaining_pct basic: exit 0"; assert_text_has "remaining_pct 40->60" "rem=60"

run_claudebar '{"five_hour":{"utilization":150,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"}}' --format 'rem={session_remaining_pct}'
assert_exit0 "remaining_pct >100 clamp: exit 0"; assert_text_has "remaining_pct 150->0" "rem=0"

# boundaries: 0 used -> 100 remaining; 100 used -> 0 remaining (also exercises weekly)
run_claudebar '{"five_hour":{"utilization":0,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":100,"resets_at":"2030-01-01T00:00:00+00:00"}}' --format 's{session_remaining_pct} w{weekly_remaining_pct}'
assert_exit0 "remaining_pct boundary: exit 0"; assert_text_has "0 used -> 100 left" "s100"; assert_text_has "100 used -> 0 left" "w0"

# {*_remaining_bar} resolves to a drain bar (filled cells = remaining%)
run_claudebar '{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"}}' --format '{session_remaining_bar}'
assert_exit0 "remaining_bar: exit 0"; assert_json_valid "remaining_bar: valid JSON"
assert_text_has "remaining_bar renders blocks" "█"

# {sonnet_remaining_bar} with no sonnet window -> full (100%) drain bar
run_claudebar '{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"}}' --format '{sonnet_remaining_bar}'
assert_exit0 "sonnet_remaining_bar no-sonnet: exit 0"; assert_json_valid "sonnet_remaining_bar: valid JSON"

FIX='{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"}}'

# --remaining flips the DEFAULT bar text to remaining% (40 used -> 60 left)
run_claudebar "$FIX" --remaining
assert_exit0 "--remaining default: exit 0"; assert_text_has "--remaining shows 60%" "60%"

# --format X --remaining keeps X (parser-state guard, both orders)
run_claudebar "$FIX" --format '{session_pct}%' --remaining
assert_text_has "--format then --remaining keeps usage 40%" "40%"
run_claudebar "$FIX" --remaining --format '{session_pct}%'
assert_text_has "--remaining then --format keeps usage 40%" "40%"

SON='{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day_sonnet":{"utilization":25,"resets_at":"2030-01-01T00:00:00+00:00"}}'

# Tooltip header gets "· Remaining" only under --remaining
run_claudebar "$SON" --remaining
assert_tip_has "header has Remaining label" "· Remaining"
# Tooltip shows remaining numbers (session 40->60, weekly 10->90, sonnet 25->75)
assert_tip_has "tooltip session remaining 60%" "60%"
assert_tip_has "tooltip sonnet remaining 75%" "75%"

# No flag: header has NO "· Remaining", tooltip shows usage numbers
run_claudebar "$SON"
_plain .tooltip | grep -qF -- "· Remaining" && _no "no-flag header clean" "leaked label" || _ok "no-flag header clean"
assert_tip_has "no-flag tooltip usage 40%" "40%"

# never-crash: --remaining with malformed sonnet must still exit 0 + valid JSON
run_claudebar '{"five_hour":{"utilization":"oops"},"seven_day":{"utilization":null},"seven_day_sonnet":"nope"}' --remaining --tooltip-pace-pts
assert_exit0 "--remaining malformed: exit 0"; assert_json_valid "--remaining malformed: valid JSON"

# extra_usage is NEVER remaining-framed, even under --remaining.
EX='{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"extra_usage":{"is_enabled":true,"used_credits":250,"monthly_limit":5000}}'
run_claudebar "$EX" --remaining
assert_exit0 "extra under --remaining: exit 0"; assert_json_valid "extra under --remaining: valid JSON"
assert_tip_has "extra still shows dollar limit" "Monthly limit:"

# smoke test: --remaining with battery bars + marker renders without crashing (exit 0 + valid JSON)
run_claudebar "$FIX" --remaining --tooltip-pace-pts
assert_exit0 "--remaining pace-pts: exit 0"; assert_json_valid "--remaining pace-pts: valid JSON"

# --remaining --tooltip-format Y keeps Y (no header label, custom content)
run_claudebar "$FIX" --remaining --tooltip-format 'CUSTOM {session_remaining_pct}'
assert_tip_has "custom tooltip-format honored" "CUSTOM 60"
_plain .tooltip | grep -qF -- "· Remaining" && _no "custom tooltip no label" "leaked label" || _ok "custom tooltip no label"

# --remaining --tooltip-format '' is treated as unset -> default remaining tooltip renders
run_claudebar "$FIX" --remaining --tooltip-format ''
assert_tip_has "empty tooltip-format -> default remaining tooltip" "· Remaining"

# --remaining --format-pace-color with a *_pace* format -> no conflict, exit 0
run_claudebar "$FIX" --remaining --format-pace-color --format '{session_pace} {session_remaining_pct}%'
assert_exit0 "--remaining + pace-color: exit 0"; assert_json_valid "--remaining + pace-color: valid JSON"

# never-crash sweep under --remaining for hardened-payload abuse
for bad in '{"five_hour":{"utilization":1e100},"seven_day":{"utilization":5}}' \
           '{"five_hour":{"utilization":-100000},"seven_day":{"utilization":5}}' \
           'not json' \
           '{"five_hour":{"utilization":5}} {"seven_day":{"utilization":5}}'; do
    run_claudebar "$bad" --remaining --tooltip-pace-pts
    assert_exit0 "never-crash --remaining [$bad]: exit 0"; assert_json_valid "never-crash --remaining [$bad]: valid JSON"
done

finish
