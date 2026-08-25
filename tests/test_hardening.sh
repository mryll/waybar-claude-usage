#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
GOOD='{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":20,"resets_at":"2030-01-01T00:00:00+00:00"}}'
chk(){ assert_exit0 "$1: exit 0"; assert_json_valid "$1: valid JSON"; }

# --- malformed usage payloads ---
run_claudebar '{"five_hour":1,"seven_day":{"utilization":20,"resets_at":"2030-01-01T00:00:00+00:00"}}'; chk "five_hour non-object"
run_claudebar '{"five_hour":{"utilization":"high","resets_at":5},"seven_day":{"utilization":20}}'; chk "string utilization + non-string resets_at"
run_claudebar '{"five_hour":{"utilization":20},"seven_day":{"utilization":20},"seven_day_sonnet":7}'; chk "seven_day_sonnet non-object"
run_claudebar '{"five_hour":{"utilization":20},"seven_day":{"utilization":20},"extra_usage":9}'; chk "extra_usage non-object"
run_claudebar '{"five_hour":{"utilization":20},"seven_day":{"utilization":20},"extra_usage":{"is_enabled":true,"monthly_limit":"x","used_credits":[1]}}'; chk "extra_usage string/array fields"
run_claudebar '123'; chk "usage is a scalar"
run_claudebar '[]'; chk "usage is an array"
run_claudebar '{"seven_day":{"utilization":20}}'; chk "missing five_hour"

# --- malformed creds (valid JSON, wrong types) ---
run_claudebar_creds '{"claudeAiOauth":"not-an-object"}' "$GOOD"; chk "claudeAiOauth non-object"
run_claudebar_creds '{"claudeAiOauth":{"accessToken":"x","expiresAt":"soon","subscriptionType":["a"],"rateLimitTier":5}}' "$GOOD"; chk "wrong-typed creds fields"
run_claudebar_creds '{"claudeAiOauth":{}}' "$GOOD"; chk "empty claudeAiOauth"

# --- syntactically INVALID json cache (try/catch can't catch parse errors) ---
run_claudebar 'not json at all'; chk "invalid-JSON usage cache"
run_claudebar '{"five_hour":{"utilization":20'; chk "truncated/invalid JSON cache"

# --- huge numbers (1e100) that jq emits in scientific notation, breaking (( )) ---
run_claudebar '{"five_hour":{"utilization":1e100,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":20,"resets_at":"2030-01-01T00:00:00+00:00"}}'; chk "1e100 utilization"
run_claudebar '{"five_hour":{"utilization":20},"seven_day":{"utilization":20},"extra_usage":{"is_enabled":true,"monthly_limit":1e100,"used_credits":1e100}}'; chk "1e100 extra credits"

# --- negative numbers must not make a negative-width bar (printf crash) ---
run_claudebar '{"five_hour":{"utilization":-100000,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":-5,"resets_at":"2030-01-01T00:00:00+00:00"}}'; chk "negative utilization"
run_claudebar '{"five_hour":{"utilization":20},"seven_day":{"utilization":20},"extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":-100000}}'; chk "negative used_credits"

# --- multi-document JSON stream in the cache (jq -e . alone would accept it) ---
run_claudebar '{"five_hour":{"utilization":10},"seven_day":{"utilization":20}} {"five_hour":{"utilization":30},"seven_day":{"utilization":40}}'; chk "multi-document usage stream"
# --- hostile FILE TYPES on paths the script does not own ---
# The plugin runs INSIDE the long-lived omarchy-shell process, so a read that
# never returns — or a write, because open(2) on a FIFO blocks for a reader that
# never comes — does not degrade the widget, it takes the shell down. `timeout`
# IS the assertion here: exit 124 is exactly the hang being guarded against.
# The oversize cases prove the byte caps, which is the other half: without them
# a multi-megabyte file lands whole in a shell variable inside that same process.
_run_hostile() {  # <label> <setup-fn>   (setup-fn is called with the fake HOME)
    local label="$1" setup="$2" home
    home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin" \
             "$home/.local/state/omarchy/current/theme" "$home/.cache/wal" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '#!/usr/bin/env bash\nexit 1\n' > "$home/bin/curl" && chmod +x "$home/bin/curl" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '%s' "$VALID_CREDS" > "$home/.claude/.credentials.json"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-test"}}' > "$home/.claude.json"
    printf '%s' "$GOOD" > "$home/.cache/claudebar/usage.json"
    "$setup" "$home"
    # Budgets pinned to 0: with no reachable network these cases would otherwise
    # each burn the full boot-like retry budget for nothing.
    OUT=$(run_pinned "$home" env CLAUDEBAR_TEST_NET_RETRY_DELAY=0 \
            CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 \
            timeout 20 "$SCRIPT"); RC=$?
    rm -rf "$home"
    [[ "$RC" -ne 124 ]] && _ok "$label: returns" || _no "$label: returns" "timed out — blocked"
    assert_exit0 "$label: exit 0"
    assert_json_valid "$label: valid JSON"
}
_big() { head -c 3000000 /dev/zero | tr '\0' 'A' > "$1"; }

_h_fifo_cache()   { rm -f "$1/.cache/claudebar/usage.json"; mkfifo "$1/.cache/claudebar/usage.json"; }
_h_fifo_creds()   { rm -f "$1/.claude/.credentials.json"; mkfifo "$1/.claude/.credentials.json"; }
_h_fifo_lock()    { mkfifo "$1/.cache/claudebar/.fetch.lock"; }
_h_fifo_lasterr() { mkfifo "$1/.cache/claudebar/.last_error"; }
_h_fifo_credits() { mkfifo "$1/.cache/claudebar/credits.json"; }
_h_fifo_theme()   { mkfifo "$1/.local/state/omarchy/current/theme/colors.toml"; }
_h_fifo_pywal()   { mkfifo "$1/.cache/wal/colors.json"; }
_h_big_cache()    { _big "$1/.cache/claudebar/usage.json"; }
_h_big_creds()    { _big "$1/.claude/.credentials.json"; }
_h_big_theme()    { _big "$1/.local/state/omarchy/current/theme/colors.toml"; }

_run_hostile "FIFO usage cache"    _h_fifo_cache
_run_hostile "FIFO credentials"    _h_fifo_creds
_run_hostile "FIFO fetch lock"     _h_fifo_lock     # write side: `exec 9>` blocks
_run_hostile "FIFO .last_error"    _h_fifo_lasterr
_run_hostile "FIFO credits cache"  _h_fifo_credits
_run_hostile "FIFO omarchy theme"  _h_fifo_theme
_run_hostile "FIFO pywal cache"    _h_fifo_pywal
_run_hostile "3MB usage cache"     _h_big_cache
_run_hostile "3MB credentials"     _h_big_creds
_run_hostile "3MB omarchy theme"   _h_big_theme
finish
