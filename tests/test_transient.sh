#!/usr/bin/env bash
# Transient network failure handling (boot robustness, adaptive deadline):
#  - boot-like start (old/missing/future-mtime cache) + no HTTP response
#      -> cached data + in-memory ⏸ (NO .stale on disk) + .net_wait episode marker
#  - sibling with a recent .net_wait -> exactly ONE attempt, no sleeps
#  - young cache (mid-session blip)  -> quick budget, no .net_wait
#  - transient failures retried until the deadline (curl recovers -> fresh data)
#  - hard HTTP failure (5xx)         -> .stale + .last_error persisted (regression)
source "$(dirname "$0")/lib.sh"

# Shrink the hidden budgets so the suite doesn't sleep for real.
export CLAUDEBAR_TEST_NET_QUICK_BUDGET=1
export CLAUDEBAR_TEST_NET_LONG_BUDGET=1
export CLAUDEBAR_TEST_NET_RETRY_DELAY=1

USAGE='{"five_hour":{"utilization":42,"resets_at":"2100-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2100-01-01T00:00:00Z"}}'

# Custom harness: scriptable curl stub + controllable cache/.net_wait mtimes.
# Keeps $THOME alive for marker inspection; callers rm -rf it.
# _run_transient <curl-stub-body> <cache-spec: old|young|none|future> [nw-spec: now|future]
_run_transient() {
    local stub="$1" cache_spec="$2" nw_spec="${3:-}"
    THOME="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$THOME/.claude" "$THOME/.cache/claudebar" "$THOME/bin" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '%s' "$stub" > "$THOME/bin/curl" && chmod +x "$THOME/bin/curl" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '#!/usr/bin/env bash\nexit 0\n' > "$THOME/bin/notify-send" && chmod +x "$THOME/bin/notify-send"
    printf '%s' "$VALID_CREDS" > "$THOME/.claude/.credentials.json" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    local now; now=$(date +%s)
    case "$cache_spec" in
        old)    printf '%s' "$USAGE" > "$THOME/.cache/claudebar/usage.json"
                touch -d "@$(( now - 1200 ))" "$THOME/.cache/claudebar/usage.json" ;;
        young)  printf '%s' "$USAGE" > "$THOME/.cache/claudebar/usage.json"
                touch -d "@$(( now - 120 ))" "$THOME/.cache/claudebar/usage.json" ;;
        future) printf '%s' "$USAGE" > "$THOME/.cache/claudebar/usage.json"
                touch -d "@$(( now + 3600 ))" "$THOME/.cache/claudebar/usage.json" ;;
        none)   : ;;
    esac
    case "$nw_spec" in
        now)    touch "$THOME/.cache/claudebar/.net_wait" ;;
        future) touch -d "@$(( now + 3600 ))" "$THOME/.cache/claudebar/.net_wait" ;;
    esac
    OUT=$(run_pinned "$THOME" "$SCRIPT"); RC=$?
    return 0
}

curl_calls() { cat "$THOME/.curl_count" 2>/dev/null || echo 0; }
assert_no_stale()   { [[ ! -f "$THOME/.cache/claudebar/.stale" ]] && _ok "$1" || _no "$1" ".stale was written"; }
assert_net_wait()   { [[ -f "$THOME/.cache/claudebar/.net_wait" ]] && _ok "$1" || _no "$1" ".net_wait missing"; }
assert_no_net_wait(){ [[ ! -f "$THOME/.cache/claudebar/.net_wait" ]] && _ok "$1" || _no "$1" ".net_wait was written"; }

COUNT_FAIL_STUB='#!/usr/bin/env bash
cnt="$HOME/.curl_count"
n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$cnt"
exit 1
'

# --- Boot-like: old cache + always-fail -> long budget, ⏸ in memory, episode marked ---
_run_transient "$COUNT_FAIL_STUB" old
assert_exit0       "boot-like w/ cache: exit 0"
assert_json_valid  "boot-like w/ cache: valid JSON"
assert_text_has    "boot-like w/ cache: shows cached pct" "42%"
assert_text_has    "boot-like w/ cache: shows the pause mark" ""
assert_tip_has     "boot-like w/ cache: tooltip explains" "stale (waiting for network)"
assert_no_stale    "boot-like w/ cache: no .stale on disk"
assert_net_wait    "boot-like w/ cache: .net_wait episode marker written"
_c=$(curl_calls)
[[ "$_c" -ge 2 ]] && _ok "boot-like w/ cache: retried within budget (calls=$_c)" || _no "boot-like w/ cache: retried within budget" "calls=$_c"
rm -rf "$THOME"

# --- Boot-like: no cache + always-fail -> neutral Loading…, low class ---
_run_transient "$COUNT_FAIL_STUB" none
assert_exit0       "no cache: exit 0"
assert_json_valid  "no cache: valid JSON"
assert_text_has    "no cache: shows Loading…" "Loading…"
assert_class       "no cache: class low" low
assert_tip_has     "no cache: tooltip explains" "Waiting for network"
assert_no_stale    "no cache: no .stale on disk"
assert_net_wait    "no cache: .net_wait episode marker written"
rm -rf "$THOME"

# --- Sibling: recent .net_wait -> exactly one attempt, no sleeps ---
_run_transient "$COUNT_FAIL_STUB" old now
assert_exit0       "sibling w/ marker: exit 0"
assert_text_has    "sibling w/ marker: shows the pause mark" ""
assert_no_stale    "sibling w/ marker: no .stale on disk"
_c=$(curl_calls)
[[ "$_c" -eq 1 ]] && _ok "sibling w/ marker: exactly one attempt" || _no "sibling w/ marker: exactly one attempt" "calls=$_c"
rm -rf "$THOME"

# --- Future .net_wait mtime (clock skew) is ignored -> long budget again ---
_run_transient "$COUNT_FAIL_STUB" old future
assert_exit0       "future marker: exit 0"
_c=$(curl_calls)
[[ "$_c" -ge 2 ]] && _ok "future marker ignored: long budget used (calls=$_c)" || _no "future marker ignored: long budget used" "calls=$_c"
rm -rf "$THOME"

# --- Mid-session blip: young cache -> quick budget, NO episode marker ---
_run_transient "$COUNT_FAIL_STUB" young
assert_exit0       "young cache: exit 0"
assert_text_has    "young cache: shows the pause mark" ""
assert_no_stale    "young cache: no .stale on disk"
assert_no_net_wait "young cache: no .net_wait (quick budget)"
rm -rf "$THOME"

# --- Future cache mtime (clock skew) -> boot-like, data still shown ---
_run_transient "$COUNT_FAIL_STUB" future
assert_exit0       "future cache: exit 0"
assert_text_has    "future cache: shows cached pct" "42%"
assert_text_has    "future cache: shows the pause mark" ""
assert_net_wait    "future cache: treated as boot-like"
rm -rf "$THOME"

# --- Retry recovery: curl fails twice, succeeds on 3rd poll -> fresh data ---
# DELAY=0 is safe ONLY here: the stub succeeds by call count, so the loop
# terminates deterministically without spinning until the clock advances.
export CLAUDEBAR_TEST_NET_RETRY_DELAY=0
export CLAUDEBAR_TEST_NET_LONG_BUDGET=5
RETRY_STUB='#!/usr/bin/env bash
cnt="$HOME/.curl_count"
n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$cnt"
if (( n < 3 )); then exit 1; fi
printf "%s\n200" "{\"five_hour\":{\"utilization\":77,\"resets_at\":\"2100-01-01T00:00:00Z\"},\"seven_day\":{\"utilization\":10,\"resets_at\":\"2100-01-01T00:00:00Z\"}}"
'
_run_transient "$RETRY_STUB" old
assert_exit0       "retry recovers: exit 0"
assert_json_valid  "retry recovers: valid JSON"
assert_text_has    "retry recovers: fresh data after polls" "77%"
_c=$(curl_calls)
[[ "$_c" -eq 3 ]] && _ok "retry recovers: succeeded on 3rd poll" || _no "retry recovers: succeeded on 3rd poll" "calls=$_c"
assert_no_stale    "retry recovers: no .stale on disk"
assert_no_net_wait "retry recovers: no .net_wait after success"
rm -rf "$THOME"
export CLAUDEBAR_TEST_NET_RETRY_DELAY=1
export CLAUDEBAR_TEST_NET_LONG_BUDGET=1

# --- REGRESSION: hard HTTP failure (500) still persists .stale + .last_error ---
HARD_STUB='#!/usr/bin/env bash
printf "%s\n500" "{\"error\":{\"message\":\"boom\"}}"
'
_run_transient "$HARD_STUB" old
assert_exit0       "hard 500: exit 0"
assert_json_valid  "hard 500: valid JSON"
assert_text_has    "hard 500: shows cached pct" "42%"
assert_text_has    "hard 500: shows the pause mark" ""
assert_tip_has     "hard 500: tooltip explains" "stale (API errors)"
[[ -f "$THOME/.cache/claudebar/.stale" ]] && _ok "hard 500: .stale persisted" || _no "hard 500: .stale persisted" "marker missing"
[[ -f "$THOME/.cache/claudebar/.last_error" ]] && _ok "hard 500: .last_error written" || _no "hard 500: .last_error written" "file missing"
rm -rf "$THOME"

finish
