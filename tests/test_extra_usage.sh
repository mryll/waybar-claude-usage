#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# Real /oauth/usage shape when usage credits are configured but the balance is
# depleted: is_enabled=false + disabled_reason "out_of_credits", yet the spend
# ($5.72 of $205.00) is still present. The Claude usage page shows it, so must we.
OUT_OF_CREDITS='{"five_hour":{"utilization":6,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":59,"resets_at":"2030-01-01T00:00:00+00:00"},"extra_usage":{"is_enabled":false,"monthly_limit":20500,"used_credits":572,"disabled_reason":"out_of_credits"}}'
run_claudebar "$OUT_OF_CREDITS"
assert_exit0     "out-of-credits: exit 0"
assert_json_valid "out-of-credits: valid JSON"
assert_tip_has   "out-of-credits: shows Extra usage section" "Extra usage"
assert_tip_has   "out-of-credits: shows spent"  '$5.72'
assert_tip_has   "out-of-credits: shows limit"  'Limit: $205.00'

# Overage never configured (no limit, no spend) → stay hidden, no empty section.
NEVER='{"five_hour":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"extra_usage":{"is_enabled":false,"monthly_limit":0,"used_credits":0}}'
run_claudebar "$NEVER"
assert_exit0 "never-configured: exit 0"
if _plain .tooltip | grep -qF "Extra usage"; then
    _no "never-configured: section hidden" "unexpected Extra usage section"
else
    _ok "never-configured: section hidden"
fi
# Custom placeholders stay empty (not "$0.00") for the zero object.
run_claudebar "$NEVER" --format '{extra_spent}|{extra_limit}|{extra_pct}'
assert_text_has "never-configured: empty dollar placeholders" '||0'

# Enabled + spend still renders (unchanged behavior).
ENABLED='{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":20,"resets_at":"2030-01-01T00:00:00+00:00"},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":250}}'
run_claudebar "$ENABLED"
assert_exit0     "enabled: exit 0"
assert_json_valid "enabled: valid JSON"
assert_tip_has "enabled: shows spent" '$2.50'
assert_tip_has "enabled: shows limit" 'Limit: $50.00'

finish
