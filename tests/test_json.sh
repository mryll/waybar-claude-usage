#!/usr/bin/env bash
# Structured JSON output mode (--json): raw data contract for alternative
# frontends (Omarchy shell plugin). Numbers stay numbers, timestamps stay
# ISO-8601, severity is a state string, no Pango markup anywhere.
source "$(dirname "$0")/lib.sh"

# jq-based asserts on $OUT
assert_jq() {  # <name> <jq-filter> <expected>
    local got; got=$(jq -r "$2" <<<"$OUT" 2>/dev/null)
    [[ "$got" == "$3" ]] && _ok "$1" || _no "$1" "jq '$2' = $got, want $3"
}
assert_no_pango() {  # <name>
    grep -qF '<span' <<<"$OUT" && _no "$1" "output contains <span" || _ok "$1"
}

FULL='{"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":77,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day_sonnet":{"utilization":15,"resets_at":"2030-01-01T00:00:00+00:00"},"limits":[{"kind":"weekly_scoped","percent":91,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}],"extra_usage":{"is_enabled":true,"used_credits":250,"monthly_limit":5000}}'
MIN='{"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":27,"resets_at":"2030-01-01T00:00:00+00:00"}}'

echo "== full payload"
run_claudebar_with_credits "$FULL" '{"amount":1000,"currency":"USD"}' --json
assert_exit0     "exit 0"
assert_json_valid "valid JSON"
assert_no_pango  "no Pango markup"
assert_jq "schema_version"        '.schema_version'          '1'
assert_jq "plan label"            '.plan'                    'Max'
assert_jq "session used_pct"      '.session.used_pct'        '42'
assert_jq "session remaining_pct" '.session.remaining_pct'   '58'
assert_jq "session resets_at ISO" '.session.resets_at'       '2030-01-01T00:00:00+00:00'
assert_jq "session state (42 -> low)"   '.session.state'     'low'
assert_jq "weekly state (77 -> high)"   '.weekly.state'      'high'
assert_jq "sonnet present"        '.sonnet.used_pct'         '15'
assert_jq "model entry name"      '.models[0].name'          'Fable'
assert_jq "model state (91 -> critical)" '.models[0].state'  'critical'
assert_jq "models count"          '.models | length'         '1'
assert_jq "extra spent cents"     '.extra_usage.used_credit_cents'   '250'
assert_jq "extra available cents" '.extra_usage.available_credit_cents' '1000'
assert_jq "extra funded cents"    '.extra_usage.funded_credit_cents' '1250'
assert_jq "extra limit cents"     '.extra_usage.monthly_limit_cents' '5000'
assert_jq "extra used_pct"        '.extra_usage.used_pct'    '20'
assert_jq "overall max_pct"       '.overall.max_pct'         '91'
assert_jq "overall state"         '.overall.state'           'critical'
# Gauge palette: the resolved anchor colors, so the QML frontend paints the
# same green→amber→red ramp the Pango tooltip does (one palette, two frontends).
assert_jq "palette low (One Dark fallback)"      '.palette.low'      '#98c379'
assert_jq "palette mid"                          '.palette.mid'      '#e5c07b'
assert_jq "palette high"                         '.palette.high'     '#d19a66'
assert_jq "palette critical"                     '.palette.critical' '#e06c75'
assert_jq "palette aliases are hex colors" \
    '[.palette | to_entries[] | select(.key != "stops") | .value | test("^#[0-9a-fA-F]{6}$")] | all' 'true'
# The ramp is published with its stop POSITIONS, so a frontend interpolates the
# same thresholds instead of hardcoding them a second time.
assert_jq "stops: one per anchor"        '.palette.stops | length' '4'
assert_jq "stops: thresholds"            '[.palette.stops[].pct] | @csv' '0,50,75,90'
assert_jq "stops: ascending"             '[.palette.stops[].pct] == ([.palette.stops[].pct] | sort)' 'true'
assert_jq "stops: colors are hex"        '[.palette.stops[].color | test("^#[0-9a-fA-F]{6}$")] | all' 'true'
assert_jq "stops agree with the aliases" \
    '[.palette.stops[].color] == [.palette.low, .palette.mid, .palette.high, .palette.critical]' 'true'
# Every state boundary in the payload sits on a published stop: one definition.
assert_jq "stops cover the severity boundaries" \
    '[.palette.stops[].pct] | contains([50, 75, 90])' 'true'
assert_jq "cache not stale"       '.cache.stale'             'false'
assert_jq "cache age numeric"     '.cache.age_s | type'      'number'
assert_jq "no error"              '.error'                   'null'
# pace: elapsed 0 (far-future reset), so delta == used_pct — self-consistent
assert_jq "pace delta = used - elapsed" \
    '.session.pace.delta_pts == .session.used_pct - .session.elapsed_pct' 'true'
assert_jq "pace state string"     '.session.pace.state'      'hot'
assert_jq "pace pts label"        '.session.pace.pts_label'  '42pts ahead'

echo "== minimal payload"
run_claudebar "$MIN" --json
assert_exit0     "exit 0"
assert_json_valid "valid JSON"
assert_jq "sonnet null when absent"      '.sonnet'      'null'
assert_jq "models empty when absent"     '.models'      '[]'
assert_jq "extra null when absent"       '.extra_usage' 'null'
assert_jq "weekly state (27 -> low)"     '.weekly.state' 'low'

echo "== sonnet dedup (scoped Sonnet entry skipped when seven_day_sonnet is present)"
DUP='{"five_hour":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day_sonnet":{"utilization":15,"resets_at":"2030-01-01T00:00:00+00:00"},"limits":[{"kind":"weekly_scoped","percent":15,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Sonnet"}}},{"kind":"weekly_scoped","percent":33,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}'
run_claudebar "$DUP" --json
assert_jq "sonnet window kept"    '.sonnet.used_pct'  '15'
assert_jq "only Fable in models"  '.models | length'  '1'
assert_jq "Fable is the entry"    '.models[0].name'   'Fable'

echo "== model name unescape (raw data, not Pango-escaped)"
AMP='{"five_hour":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2030-01-01T00:00:00+00:00"},"limits":[{"kind":"weekly_scoped","percent":5,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"A&B <X>"}}}]}'
run_claudebar "$AMP" --json
assert_jq "name round-trips raw"  '.models[0].name'   'A&B <X>'

echo "== error paths still emit schema_version JSON, exit 0"
run_claudebar_creds '{}' "$MIN" --json
assert_exit0      "no-token creds: exit 0"
assert_json_valid "no-token creds: valid JSON"
assert_jq "no-token creds: schema_version" '.schema_version' '1'
assert_jq "no-token creds: error message"  '.error.message | length > 0' 'true'
assert_no_pango   "no-token creds: no <b>/<span> markup"
run_claudebar_creds 'not json' "$MIN" --json
assert_json_valid "invalid creds file: valid JSON"
assert_jq "invalid creds file: error set"  '.error | type' 'object'

echo "== --refresh with network down reuses cache and reports transient staleness"
export CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 CLAUDEBAR_TEST_NET_RETRY_DELAY=0
run_claudebar "$MIN" --json --refresh
assert_exit0      "--refresh offline: exit 0"
assert_json_valid "--refresh offline: valid JSON"
assert_jq "--refresh offline: data from cache" '.session.used_pct' '42'
assert_jq "--refresh offline: stale"           '.cache.stale'      'true'
assert_jq "--refresh offline: stale_kind"      '.cache.stale_kind' 'network'
unset CLAUDEBAR_TEST_NET_QUICK_BUDGET CLAUDEBAR_TEST_NET_LONG_BUDGET CLAUDEBAR_TEST_NET_RETRY_DELAY

echo "== palette honors --color-* overrides (same anchors that color the tooltip)"
run_claudebar "$MIN" --json --color-low '#00ff00' --color-mid '#112233' \
    --color-high '#445566' --color-critical '#ff0000'
assert_exit0      "palette overrides: exit 0"
assert_jq "palette low overridden"      '.palette.low'      '#00ff00'
assert_jq "palette mid overridden"      '.palette.mid'      '#112233'
assert_jq "palette high overridden"     '.palette.high'     '#445566'
assert_jq "palette critical overridden" '.palette.critical' '#ff0000'
assert_jq "overrides reach the stops too" \
    '[.palette.stops[].color] | join(",")' '#00ff00,#112233,#445566,#ff0000'

echo "== palette follows the active Omarchy theme (both layouts)"
# <theme-relative-dir> <colors.toml body> [args...] — builds a HOME with a theme
# file at that location and runs --json against it.
run_themed_json() {
    local rel="$1" body="$2"; shift 2
    local home; home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin" "$home/$rel"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$home/bin/curl" && chmod +x "$home/bin/curl"
    printf '%s' "$VALID_CREDS" > "$home/.claude/.credentials.json"
    printf '%s' "$MIN" > "$home/.cache/claudebar/usage.json"
    printf '%s' "$body" > "$home/$rel/colors.toml"
    OUT=$(run_pinned "$home" "$SCRIPT" --json "$@"); RC=$?
    rm -rf "$home"
    return 0
}

# Current layout: theme under XDG_STATE_HOME, named color keys.
NAMED_THEME='mode = "dark"
accent = "#7aa2f7"
background = "#1a1b26"
foreground = "#a9b1d6"
red = "#f7768e"
yellow = "#e0af68"
orange = "#eb927b"
green = "#9ece6a"
'
run_themed_json ".local/state/omarchy/current/theme" "$NAMED_THEME"
assert_exit0      "state-home theme: exit 0"
assert_json_valid "state-home theme: valid JSON"
assert_jq "state-home theme: low = green"      '.palette.low'      '#9ece6a'
assert_jq "state-home theme: mid = yellow"     '.palette.mid'      '#e0af68'
assert_jq "state-home theme: high = orange"    '.palette.high'     '#eb927b'
assert_jq "state-home theme: critical = red"   '.palette.critical' '#f7768e'

# Legacy layout: theme under ~/.config with terminal-palette keys. color1 still
# stands in for both red and orange, exactly as before this mapping existed.
LEGACY_THEME='accent = "#61afef"
foreground = "#abb2bf"
background = "#282c34"
color1 = "#ff0000"
color2 = "#00ff00"
color3 = "#ffff00"
'
run_themed_json ".config/omarchy/current/theme" "$LEGACY_THEME"
assert_jq "legacy theme: low = color2"        '.palette.low'      '#00ff00'
assert_jq "legacy theme: mid = color3"        '.palette.mid'      '#ffff00'
assert_jq "legacy theme: high = color1"       '.palette.high'     '#ff0000'
assert_jq "legacy theme: critical = color1"   '.palette.critical' '#ff0000'

# CLI overrides beat the theme.
run_themed_json ".local/state/omarchy/current/theme" "$NAMED_THEME" --color-low '#abcdef'
assert_jq "override beats theme"              '.palette.low'      '#abcdef'
assert_jq "theme still fills the rest"        '.palette.critical' '#f7768e'

echo "== pywal palette (non-Omarchy setups)"
# <wal-json> [--omarchy] [args...] — builds a HOME with a pywal cache, and
# optionally an Omarchy theme too, then runs --json against it.
# XDG_CACHE_HOME defaults to the fake HOME's .cache; pass CACHE_REL to move it.
run_pywal_json() {
    local wal="$1"; shift
    local with_theme=""
    [[ "${1:-}" == "--omarchy" ]] && { with_theme=1; shift; }
    local home; home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    local cache_rel="${CACHE_REL:-.cache}"
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin" "$home/$cache_rel/wal"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$home/bin/curl" && chmod +x "$home/bin/curl"
    printf '%s' "$VALID_CREDS" > "$home/.claude/.credentials.json"
    printf '%s' "$MIN" > "$home/.cache/claudebar/usage.json"
    [[ -n "$wal" ]] && printf '%s' "$wal" > "$home/$cache_rel/wal/colors.json"
    if [[ -n "$with_theme" ]]; then
        mkdir -p "$home/.local/state/omarchy/current/theme"
        printf 'green = "#9ece6a"\nyellow = "#e0af68"\norange = "#eb927b"\nred = "#f7768e"\n' \
            > "$home/.local/state/omarchy/current/theme/colors.toml"
    fi
    # XDG_CACHE_HOME deliberately points at $cache_rel (the point of the test is
    # that pywal is found wherever that variable says); everything else is
    # pinned inside the fake HOME exactly as run_pinned would.
    OUT=$(env HOME="$home" XDG_STATE_HOME="$home/.local/state" \
          XDG_CACHE_HOME="$home/$cache_rel" XDG_CONFIG_HOME="$home/.config" \
          PATH="$home/bin:$PATH" "$SCRIPT" --json "$@"); RC=$?
    rm -rf "$home"
    return 0
}

WAL_FULL='{"special":{"background":"#0d1117","foreground":"#c9d1d9","cursor":"#58a6ff"},
           "colors":{"color1":"#ff5555","color2":"#50fa7b","color3":"#f1fa8c","color4":"#8be9fd"}}'

run_pywal_json "$WAL_FULL"
assert_exit0      "pywal: exit 0"
assert_json_valid "pywal: valid JSON"
assert_jq "pywal: low = color2 (green)"    '.palette.low'      '#50fa7b'
assert_jq "pywal: mid = color3 (yellow)"   '.palette.mid'      '#f1fa8c'
assert_jq "pywal: critical = color1 (red)" '.palette.critical' '#ff5555'
# No orange slot in the pywal format: synthesized as the yellow/red midpoint,
# which must be a real fourth step, distinct from both neighbours.
assert_jq "pywal: high is the yellow/red midpoint" '.palette.high' '#f8a770'
assert_jq "pywal: high differs from mid"           '.palette.high != .palette.mid'      'true'
assert_jq "pywal: high differs from critical"      '.palette.high != .palette.critical' 'true'

echo "== resolution chain precedence"
run_pywal_json "$WAL_FULL" --omarchy
assert_jq "omarchy beats pywal (low)"      '.palette.low'      '#9ece6a'
assert_jq "omarchy beats pywal (critical)" '.palette.critical' '#f7768e'
run_pywal_json "$WAL_FULL" --omarchy --color-low '#123456'
assert_jq "flags beat omarchy"             '.palette.low'      '#123456'
run_pywal_json "$WAL_FULL" --color-critical '#654321'
assert_jq "flags beat pywal"               '.palette.critical' '#654321'
assert_jq "flags leave the rest to pywal"  '.palette.low'      '#50fa7b'

echo "== pywal degrades silently"
run_pywal_json ""            # no colors.json at all
assert_exit0 "no pywal file: exit 0"
assert_jq "no pywal file: One Dark defaults"  '.palette.low' '#98c379'
run_pywal_json 'not json at all{{{'
assert_exit0 "garbage pywal JSON: exit 0"
assert_json_valid "garbage pywal JSON: valid output"
assert_jq "garbage pywal JSON: One Dark low"  '.palette.low'      '#98c379'
assert_jq "garbage pywal JSON: One Dark crit" '.palette.critical' '#e06c75'
run_pywal_json '{"special":{"foreground":"#c9d1d9"},"colors":{"color1":123,"color2":{"x":1},"color3":"nothex"}}'
assert_exit0 "non-hex / wrong-typed values: exit 0"
assert_jq "non-hex values ignored (low)"      '.palette.low'      '#98c379'
assert_jq "non-hex values ignored (critical)" '.palette.critical' '#e06c75'
# Regression guard: a palette missing one key must not shift the others.
run_pywal_json '{"special":{"foreground":"#c9d1d9"},"colors":{"color1":"#ff5555","color3":"#f1fa8c"}}'
assert_jq "missing color2 keeps default green" '.palette.low'      '#98c379'
assert_jq "missing color2 does not shift mid"  '.palette.mid'      '#f1fa8c'
assert_jq "missing color2 does not shift red"  '.palette.critical' '#ff5555'

echo "== XDG_CACHE_HOME is respected"
CACHE_REL=".custom-cache" run_pywal_json "$WAL_FULL"
assert_jq "pywal read from XDG_CACHE_HOME" '.palette.low' '#50fa7b'

echo "== harness hygiene: no fake-HOME run may inherit the real XDG dirs"
# The script honors $XDG_STATE_HOME (active Omarchy theme) and $XDG_CACHE_HOME
# (pywal palette), and a normal desktop session exports both. A helper that
# pins only HOME therefore reads the DEVELOPER'S OWN theme: it still passes
# here, for the wrong reason, and fails on CI or on a differently themed
# machine. This guards the harness itself against that regression.
_hygiene_leaks() {
    local f
    for f in "$(dirname "$0")"/*.sh; do
        # Join backslash continuations so a multi-line env prefix reads as one.
        sed -e ':a' -e '/\\$/{N;s/\\\n//;ta}' "$f" \
            | grep -E '(^|[^A-Za-z_])HOME="\$' \
            | grep -v 'XDG_STATE_HOME' \
            | sed "s|^|$(basename "$f"): |"
    done
}
_leaks=$(_hygiene_leaks)
[[ -z "$_leaks" ]] && _ok "every fake-HOME invocation pins XDG_STATE_HOME" \
    || _no "every fake-HOME invocation pins XDG_STATE_HOME" "$_leaks"
# And the guard itself must be able to see a leak, or it proves nothing.
_probe=$(mktemp -d)/probe.sh
# %s, so this source line does not itself look like an unpinned run to the
# scanner above — the probe FILE gets the leak, this file does not.
printf 'OUT=$(%s="$home" PATH="$home/bin:$PATH" "$SCRIPT" --json)\n' HOME > "$_probe"
_seen=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ta}' "$_probe" \
        | grep -E '(^|[^A-Za-z_])HOME="\$' | grep -vc 'XDG_STATE_HOME')
[[ "$_seen" == "1" ]] && _ok "the hygiene guard detects an unpinned run" \
    || _no "the hygiene guard detects an unpinned run" "saw $_seen"
rm -rf "$(dirname "$_probe")"

echo "== --color-* values are validated before they reach Pango"
# The value lands inside a single-quoted foreground attribute, so a quote would
# escape it and let the caller write arbitrary markup.
run_claudebar "$MIN" "--color-low=x" 2>/dev/null || true
for bad in "x'><span foreground='red'>" "red'" '<b>' "a b" "#12345" "#gggggg" ""; do
    run_claudebar "$MIN" --json --color-low "$bad"
    assert_exit0      "rejects [${bad:-<empty>}]: exit 0"
    assert_json_valid "rejects [${bad:-<empty>}]: valid JSON"
    assert_jq "rejects [${bad:-<empty>}]: names the flag" \
        '.error.message' '--color-low must be a hex color or a plain color name'
done
for good in red tomato '#abc' '#abcd' '#98c379' '#98c379ff'; do
    run_claudebar "$MIN" --json --color-low "$good"
    assert_jq "accepts [$good]"  '.error' 'null'
done
# A name cannot be interpolated, so the ramp falls back to discrete steps —
# the behavior that predates the gradient — instead of breaking the math.
run_claudebar "$MIN" --color-low red
assert_exit0     "color name: exit 0"
assert_json_valid "color name: valid JSON"
# assert_text_has strips tags, and the name lives inside the attribute itself.
/usr/bin/grep -qF "foreground='red'" <<<"$(jq -r .text <<<"$OUT")" \
    && _ok "color name: reaches the markup" \
    || _no "color name: reaches the markup" "$(jq -r .text <<<"$OUT")"

echo "== die() messages carry no literal backslash-n"
run_claudebar_creds '{}' "$MIN" --json
assert_jq "structured error is one flat line" '.error.message | test("\\\\n") | not' 'true'
assert_jq "structured error keeps its words"  '.error.message | test("Run claude to log in")' 'true'
run_claudebar_creds '{}' "$MIN"
assert_tip_has "waybar tooltip breaks the line for real" "No token."
_nl_count=$(jq -r '.tooltip' <<<"$OUT" | wc -l)
[[ "$_nl_count" -eq 2 ]] && _ok "waybar tooltip is two rendered lines" \
    || _no "waybar tooltip is two rendered lines" "got $_nl_count"

echo "== theme parsing edge cases"
NO_TRAILING_NEWLINE='green = "#00ff00"
yellow = "#ffff00"
red = "#ff0000"'
run_themed_json ".local/state/omarchy/current/theme" "$NO_TRAILING_NEWLINE"
assert_jq "last key survives a missing trailing newline" '.palette.critical' '#ff0000'
assert_jq "…and the earlier keys still land"             '.palette.low'      '#00ff00'
# A malformed semantic key must not shadow a valid legacy one behind it.
MIXED='red = "notahex"
color1 = "#ff0000"
green = "#00ff00"
'
run_themed_json ".local/state/omarchy/current/theme" "$MIXED"
assert_jq "invalid semantic key falls back to legacy" '.palette.critical' '#ff0000'
assert_jq "…without disturbing the valid ones"        '.palette.low'      '#00ff00'

echo "== arg errors in JSON mode speak the structured schema (pre-scan)"
run_claudebar "$MIN" --json --bogus
assert_exit0      "bad flag after --json: exit 0"
assert_json_valid "bad flag after --json: valid JSON"
assert_jq "bad flag after --json: schema_version" '.schema_version' '1'
assert_jq "bad flag after --json: message names the flag" '.error.message' 'Unknown option: --bogus'
run_claudebar "$MIN" --bogus --json
assert_json_valid "bad flag before --json: valid JSON"
assert_jq "bad flag before --json: still structured" '.schema_version' '1'
run_claudebar "$MIN" --json --icon
assert_json_valid "missing flag value: valid JSON"
assert_jq "missing flag value: structured message" '.error.message' '--icon requires a value'

echo "== control characters in arg errors escape cleanly through jq"
run_claudebar "$MIN" --json "--bad$(printf '\t')x$(printf '\001')y"
assert_exit0      "ctrl chars: exit 0"
assert_json_valid "ctrl chars: valid JSON"
assert_jq "ctrl chars: message is a string" '.error.message | type' 'string'
assert_jq "ctrl chars: message survives round-trip" '.error.message | contains("--bad")' 'true'

echo "== jq-less fallback emits the fixed literal"
# Arg errors fire before the dependency check; with no jq on PATH the JSON
# path must fall back to a fixed literal that nothing can break.
_h="$(mktemp -d)"
# PATH is deliberately a directory with no jq in it, so this one cannot go
# through run_pinned; the XDG vars are pinned by hand for the same reason.
OUT=$(env HOME="$_h" XDG_STATE_HOME="$_h/.local/state" XDG_CACHE_HOME="$_h/.cache" \
      XDG_CONFIG_HOME="$_h/.config" PATH="$_h" "$BASH" "$SCRIPT" --json --bogus); RC=$?
rm -rf "$_h"
[[ "$RC" -eq 0 ]] && _ok "jq-less: exit 0" || _no "jq-less: exit 0" "exit=$RC"
[[ "$OUT" == '{"schema_version":1,"error":{"message":"invalid arguments"}}' ]] \
    && _ok "jq-less: fixed literal" || _no "jq-less: fixed literal" "got: $OUT"

echo "== cache.age_s clamps at 0 on future mtime (clock skew)"
# Future cache mtime is boot-like (never fresh): with the network stubbed dead
# and zero retry budgets, claudebar reuses the cache — and the reported age
# must clamp at 0, never go negative.
run_future_cache_json() {  # <usage-json>
    local home; home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$home/bin/curl" && chmod +x "$home/bin/curl"
    printf '%s' "$VALID_CREDS" > "$home/.claude/.credentials.json"
    printf '%s' "$1" > "$home/.cache/claudebar/usage.json"
    touch -d '+2 hours' "$home/.cache/claudebar/usage.json"
    OUT=$(run_pinned "$home" env \
        CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 CLAUDEBAR_TEST_NET_RETRY_DELAY=0 \
        "$SCRIPT" --json); RC=$?
    rm -rf "$home"
    return 0
}
run_future_cache_json "$MIN"
assert_exit0      "future mtime: exit 0"
assert_json_valid "future mtime: valid JSON"
assert_jq "future mtime: age_s clamped at 0"  '.cache.age_s' '0'
assert_jq "future mtime: data still served"   '.session.used_pct' '42'

echo "== error.code shape (normalized: null | {message, code?})"
run_claudebar "$MIN" --json
assert_jq "healthy: error is null" '.error' 'null'
# Seed a .last_error (as a failed refresh/fetch would) and check the shape.
run_with_last_error_json() {  # <usage-json> <code> <message>
    local home; home="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$home/.claude" "$home/.cache/claudebar" "$home/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$home/bin/curl" && chmod +x "$home/bin/curl"
    printf '%s' "$VALID_CREDS" > "$home/.claude/.credentials.json"
    printf '%s' "$1" > "$home/.cache/claudebar/usage.json"
    printf '%s\n%s' "$2" "$3" > "$home/.cache/claudebar/.last_error"
    OUT=$(run_pinned "$home" "$SCRIPT" --json); RC=$?
    rm -rf "$home"
    return 0
}
run_with_last_error_json "$MIN" 429 "Rate limited"
assert_json_valid "last_error: valid JSON"
assert_jq "last_error: message"      '.error.message'  'Rate limited'
assert_jq "last_error: code numeric" '.error.code'     '429'
assert_jq "last_error: no http_code key" '.error | has("http_code")' 'false'
run_with_last_error_json "$MIN" 500 ""
assert_jq "last_error empty msg: message normalized" '.error.message' 'HTTP 500'

echo "== --refresh does not change waybar output shape"
export CLAUDEBAR_TEST_NET_QUICK_BUDGET=0 CLAUDEBAR_TEST_NET_LONG_BUDGET=0 CLAUDEBAR_TEST_NET_RETRY_DELAY=0
run_claudebar "$MIN" --refresh
assert_exit0      "--refresh waybar: exit 0"
assert_json_valid "--refresh waybar: valid JSON"
assert_text_has   "--refresh waybar: session pct in text" "42%"
unset CLAUDEBAR_TEST_NET_QUICK_BUDGET CLAUDEBAR_TEST_NET_LONG_BUDGET CLAUDEBAR_TEST_NET_RETRY_DELAY

finish
