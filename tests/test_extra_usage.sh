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
assert_tip_has   "out-of-credits: shows limit"  'Monthly limit: $205.00'

run_claudebar "$OUT_OF_CREDITS" --json
assert_jq_value "out-of-credits: balance known" '.extra_usage.balance_known' 'true'
assert_jq_value "out-of-credits: available is zero" '.extra_usage.available_credit_cents' '0'
assert_jq_value "out-of-credits: funded equals spent" '.extra_usage.funded_credit_cents' '572'
assert_jq_value "out-of-credits: real funds fully consumed" '.extra_usage.used_pct' '100'

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
assert_tip_has "enabled: shows limit" 'Monthly limit: $50.00'

# Exact prepaid balance is a separate amount from the monthly spending limit.
# $50.05 spent + $25.00 available = $75.05 real funds; rounded usage is 67%.
FUNDED='{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":20,"resets_at":"2030-01-01T00:00:00+00:00"},"extra_usage":{"is_enabled":true,"monthly_limit":20000,"used_credits":5005}}'
run_claudebar_with_credits "$FUNDED" '{"amount":2500,"currency":"USD"}' --json
assert_exit0 "funded: exit 0"
assert_json_valid "funded: valid JSON"
assert_jq_value "funded: spent stays exact" '.extra_usage.used_credit_cents' '5005'
assert_jq_value "funded: exact available credit" '.extra_usage.available_credit_cents' '2500'
assert_jq_value "funded: real pool is spent plus available" '.extra_usage.funded_credit_cents' '7505'
assert_jq_value "funded: percent uses real pool" '.extra_usage.used_pct' '67'
assert_jq_value "funded: monthly limit retained separately" '.extra_usage.monthly_limit_cents' '20000'

run_claudebar_with_credits "$FUNDED" '{"amount":2500,"currency":"USD"}'
assert_tip_has "funded tooltip: labels the real denominator" 'Spent: $50.05 / $75.05'
assert_tip_has "funded tooltip: percent matches that denominator" '67%'
assert_tip_has "funded tooltip: shows available credit" 'Available: $25.00'
assert_tip_has "funded tooltip: keeps monthly limit" 'Monthly limit: $200.00'

# Both frontends use the same compact wording. This static contract complements
# the behavioral Waybar assertions above; qmlformat/qmllint validate the QML.
PANEL_QML="$(cd "$(dirname "$0")/.." && pwd)/omarchy/Panel.qml"
if grep -qF 'readonly property string extraSpentSummary' "$PANEL_QML" \
   && grep -qF 'return "Spent: " + money(extra.used_credit_cents) + " / " + total' "$PANEL_QML"; then
    _ok "Quickshell: spent summary uses the funded-credit denominator"
else
    _no "Quickshell: spent summary uses the funded-credit denominator"
fi
if grep -qF 'readonly property string extraCreditSummary' "$PANEL_QML" \
   && grep -qF '"Available: "' "$PANEL_QML" \
   && grep -qF '" · Monthly limit: "' "$PANEL_QML"; then
    _ok "Quickshell: available credit and monthly limit stay separate"
else
    _no "Quickshell: available credit and monthly limit stay separate"
fi
if sed -n '/id: extraSpentLabel/,/anchors.left: parent.left/p' "$PANEL_QML" \
   | grep -qF 'font.pixelSize: Style.font.caption'; then
    _ok "Quickshell: spent summary matches the footer text size"
else
    _no "Quickshell: spent summary matches the footer text size"
fi

# A non-exhausted account with no usable balance response must stay unknown;
# falling back to the monthly limit would recreate the original misleading bar.
UNKNOWN='{"five_hour":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"extra_usage":{"is_enabled":false,"monthly_limit":20000,"used_credits":5005,"disabled_reason":"user_disabled"}}'
run_claudebar "$UNKNOWN" --json
assert_jq_value "unknown: balance marked unknown" '.extra_usage.balance_known' 'false'
assert_jq_value "unknown: available is null" '.extra_usage.available_credit_cents' 'null'
assert_jq_value "unknown: funded pool is null" '.extra_usage.funded_credit_cents' 'null'
assert_jq_value "unknown: percent is null" '.extra_usage.used_pct' 'null'

# Refresh boundary: the real collector must fetch and atomically cache the
# separate prepaid ledger response. The curl double only replaces the external
# service; claudebar's request routing, validation, cache write, and normalized
# output all remain real.
_run_refresh_with_balance() {
    FETCH_HOME="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$FETCH_HOME/.claude" "$FETCH_HOME/.cache/claudebar" "$FETCH_HOME/bin"
    printf '%s' "$VALID_CREDS" > "$FETCH_HOME/.claude/.credentials.json"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-test"}}' > "$FETCH_HOME/.claude.json"
    printf '%s' "$FUNDED" > "$FETCH_HOME/.usage_response"
    printf '%s' '{"amount":2500,"balance":{"money":null,"credits":{"amount_minor":2500,"exponent":2}},"balance_credits":2500,"currency":"USD","auto_reload_settings":null,"expiry_policy_months":null,"last_paid_purchase_cents":null,"next_expires_at":null,"pending_invoice_amount_cents":null,"promo_tranches":[],"tranches":[]}' > "$FETCH_HOME/.credits_response"
    printf '%s\n' '#!/usr/bin/env bash' \
      'url=""' \
      'for arg in "$@"; do [[ "$arg" == https://* ]] && url="$arg"; done' \
      'case "$url" in' \
      '  */api/oauth/usage) cat "$HOME/.usage_response"; printf "\n200" ;;' \
      '  */prepaid/credits) cat "$HOME/.credits_response"; printf "\n200" ;;' \
      '  *) printf "%s\n404" "{\"error\":{\"message\":\"unexpected test URL\"}}" ;;' \
      'esac' > "$FETCH_HOME/bin/curl"
    chmod +x "$FETCH_HOME/bin/curl"
    OUT=$(run_pinned "$FETCH_HOME" env \
      CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 \
      "$SCRIPT" --json --refresh)
    RC=$?
}

_run_refresh_with_balance
assert_exit0 "balance fetch: exit 0"
assert_json_valid "balance fetch: valid JSON"
assert_jq_value "balance fetch: available credit" '.extra_usage.available_credit_cents' '2500'
assert_jq_value "balance fetch: real-funds percent" '.extra_usage.used_pct' '67'
if [[ -f "$FETCH_HOME/.cache/claudebar/credits.json" ]] \
   && jq -e '.amount == 2500' "$FETCH_HOME/.cache/claudebar/credits.json" &>/dev/null; then
    _ok "balance fetch: response cached atomically"
else
    _no "balance fetch: response cached atomically" "credits.json missing or invalid"
fi
rm -rf "$FETCH_HOME"

finish
