#!/usr/bin/env bash
# Test harness for claudebar. Runs the real script against crafted creds + usage
# with NO network: fake $HOME, far-future expiresAt (no refresh), fresh cache,
# and a `curl` stub (exits 1) so refresh/fetch can't reach the network.
set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claudebar"
PASS=0; FAIL=0

VALID_CREDS='{"claudeAiOauth":{"accessToken":"x","refreshToken":"y","expiresAt":4102444800000,"subscriptionType":"max","rateLimitTier":"default"}}'

_run() {  # <creds-json> <usage-json> [args...]
    local creds="$1" usage="$2"; shift 2
    local home; home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '#!/usr/bin/env bash\nexit 1\n' > "$home/bin/curl" && chmod +x "$home/bin/curl" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '%s' "$creds" > "$home/.claude/.credentials.json"      || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-test"}}' > "$home/.claude.json" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '%s' "$usage" > "$home/.cache/claudebar/usage.json"     || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    if [[ -n "${CLAUDEBAR_TEST_CREDITS_JSON:-}" ]]; then
        printf '%s' "$CLAUDEBAR_TEST_CREDITS_JSON" > "$home/.cache/claudebar/credits.json" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    fi
    touch "$home/.cache/claudebar/usage.json"
    OUT=$(run_pinned "$home" "$SCRIPT" "$@"); RC=$?
    rm -rf "$home"
    return 0
}
# Run a command against a fake HOME with EVERY environment variable the script
# consults pinned inside it. Forgetting one is a silent trap rather than a
# failure: the code honors $XDG_STATE_HOME for the active Omarchy theme and
# $XDG_CACHE_HOME for the pywal palette, and both are exported on a normal
# desktop session — so an unpinned run reads the DEVELOPER'S OWN theme and
# still passes here while failing on CI or on a machine themed differently.
# XDG_CONFIG_HOME is pinned too: the legacy theme path does not honor it today,
# but pinning it now means adding that support later cannot reopen the leak.
run_pinned() {  # <fake-home> <command> [args...]
    local home="$1"; shift
    env HOME="$home" \
        XDG_STATE_HOME="$home/.local/state" \
        XDG_CACHE_HOME="$home/.cache" \
        XDG_CONFIG_HOME="$home/.config" \
        PATH="$home/bin:$PATH" "$@"
}

# run_claudebar '<usage-json>' [args...]  — valid creds
run_claudebar() { _run "$VALID_CREDS" "$@"; }
# run_claudebar_with_credits '<usage-json>' '<prepaid-credits-json>' [args...]
run_claudebar_with_credits() {
    local usage="$1" credits="$2"; shift 2
    CLAUDEBAR_TEST_CREDITS_JSON="$credits" _run "$VALID_CREDS" "$usage" "$@"
}
# run_claudebar_creds '<creds-json>' '<usage-json>' [args...]
run_claudebar_creds() { _run "$@"; }

_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_no()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n    %s\n' "$1" "${2:-}"; }
assert_exit0()      { [[ "$RC" -eq 0 ]] && _ok "$1" || _no "$1" "exit=$RC"; }
assert_json_valid() { jq -e . >/dev/null 2>&1 <<<"$OUT" && _ok "$1" || _no "$1" "invalid JSON: $OUT"; }
_plain() { jq -r "$1" <<<"$OUT" | sed 's/<[^>]*>//g'; }
assert_text_has()  { _plain .text | grep -qF -- "$2" && _ok "$1" || _no "$1" "text lacks: $2"; }
assert_class() { local c; c=$(jq -r .class <<<"$OUT"); [[ "$c" == "$2" ]] && _ok "$1" || _no "$1" "class=$c want=$2"; }
assert_tip_has()  { _plain .tooltip | grep -qF -- "$2" && _ok "$1" || _no "$1" "tooltip lacks: $2"; }
assert_jq_value() {  # <name> <jq-filter> <expected>
    local got; got=$(jq -r "$2" <<<"$OUT" 2>/dev/null)
    [[ "$got" == "$3" ]] && _ok "$1" || _no "$1" "jq '$2' = $got, want $3"
}
finish() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; [[ "$FAIL" -eq 0 ]]; }
