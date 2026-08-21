#!/usr/bin/env bash
# Monochrome mode: --no-color[=all|bar|tooltip] and the NO_COLOR env var.
# "Plain" means no color markup on that surface while everything structural —
# glyphs, bar fill characters, markers, box drawing, bold, layout — survives.
# The waybar `class` field and the --json payload are machine contracts and
# must not change.
source "$(dirname "$0")/lib.sh"

FX='{"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":77,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day_sonnet":{"utilization":15,"resets_at":"2030-01-01T00:00:00+00:00"}}'

_field() { jq -r "$1" <<<"$OUT"; }
assert_colored() {  # <name> <jq-field>
    if /usr/bin/grep -qF "foreground=" <<<"$(_field "$2")"; then _ok "$1"
    else _no "$1" "expected color markup in $2"; fi
}
assert_plain() {  # <name> <jq-field>
    local v; v=$(_field "$2")
    if /usr/bin/grep -qF "foreground=" <<<"$v"; then _no "$1" "color markup left in $2"
    elif /usr/bin/grep -qE '#[0-9a-fA-F]{6}' <<<"$v"; then _no "$1" "inline hex left in $2"
    else _ok "$1"; fi
}
assert_has() {  # <name> <jq-field> <needle>
    /usr/bin/grep -qF -- "$3" <<<"$(_field "$2")" && _ok "$1" || _no "$1" "$2 lacks: $3"
}

assert_lacks() {  # <name> <jq-field> <needle>
    local v; v=$(jq -r "$2" <<<"$OUT")
    grep -qF -- "$3" <<<"$v" && _no "$1" "still contains: $3" || _ok "$1"
}

echo "== the four states"
run_claudebar "$FX"
assert_colored "default: bar colored"      .text
assert_colored "default: tooltip colored"  .tooltip

run_claudebar "$FX" --no-color
assert_exit0     "--no-color: exit 0"
assert_json_valid "--no-color: valid JSON"
assert_plain   "--no-color: bar plain"      .text
assert_plain   "--no-color: tooltip plain"  .tooltip

run_claudebar "$FX" --no-color=all
assert_plain   "--no-color=all: bar plain"      .text
assert_plain   "--no-color=all: tooltip plain"  .tooltip

run_claudebar "$FX" --no-color=bar
assert_plain   "--no-color=bar: bar plain"        .text
assert_colored "--no-color=bar: tooltip colored"  .tooltip

run_claudebar "$FX" --no-color=tooltip
assert_colored "--no-color=tooltip: bar colored"  .text
assert_plain   "--no-color=tooltip: tooltip plain" .tooltip

echo "== structure survives monochrome"
run_claudebar "$FX" --no-color
assert_has "plain tooltip keeps the session glyph"   .tooltip "󰔟"
assert_has "plain tooltip keeps bar fill characters" .tooltip "█"
assert_has "plain tooltip keeps the empty track"     .tooltip "░"
assert_has "plain tooltip keeps bold markup"         .tooltip "font_weight='bold'"
assert_has "plain tooltip keeps the separator rule"  .tooltip "─"
assert_has "plain tooltip keeps the percentage"      .tooltip "42%"
run_claudebar "$FX" --no-color --tooltip-pace-pts
assert_has "plain tooltip keeps the elapsed marker"  .tooltip "┃"
run_claudebar "$FX" --no-color --icon "󰚩"
assert_has "plain bar keeps the icon"                .text "󰚩"
run_claudebar "$FX" --no-color --format '{session_bar} {session_pace}'
assert_plain "plain bar strips placeholder colors"   .text
assert_has   "plain bar keeps placeholder glyphs"    .text "█"

echo "== monochrome also strips markup the USER wrote"
# --format is the user's string: it may carry colors this script never emits,
# in either quote style, and attributes beyond `foreground`.
run_claudebar "$FX" --no-color --format '<span foreground="#ff0000">A</span> <span background=#00ff00>B</span>'
assert_plain "double-quoted foreground stripped" .text
assert_has   "…keeping its text (A)"             .text "A"
assert_has   "…keeping its text (B)"             .text "B"
run_claudebar "$FX" --no-color --format "<span underline_color='#f00' fgcolor=blue>C</span>"
assert_plain "underline_color and fgcolor stripped" .text
assert_has   "…keeping its text (C)"                .text "C"
run_claudebar "$FX" --no-color --tooltip-format "<span background=\"#123456\">D</span>"
assert_plain "tooltip: user background stripped"  .tooltip
assert_has   "…keeping its text (D)"              .tooltip "D"
run_claudebar "$FX" --no-color --format '<b>bold</b> <i>it</i>'
assert_has   "non-color markup survives (b)"      .text "<b>bold</b>"
assert_has   "non-color markup survives (i)"      .text "<i>it</i>"
run_claudebar "$FX" --no-color --format 'plain color=red text'
assert_has   "body text that merely looks like an attribute is left alone" .text "color=red"

echo "== class is untouched (the CSS path stays open)"
for flags in "" "--no-color" "--no-color=bar" "--no-color=tooltip"; do
    # shellcheck disable=SC2086
    run_claudebar "$FX" $flags
    assert_class "class survives [${flags:-default}]" high
done

echo "== NO_COLOR environment variable"
export NO_COLOR=1
run_claudebar "$FX"
assert_plain   "NO_COLOR=1: bar plain"     .text
assert_plain   "NO_COLOR=1: tooltip plain" .tooltip
run_claudebar "$FX" --no-color=bar
assert_plain   "NO_COLOR=1 + --no-color=bar: bar plain"       .text
assert_colored "NO_COLOR=1 + --no-color=bar: tooltip colored" .tooltip
run_claudebar "$FX" --no-color=tooltip
assert_colored "NO_COLOR=1 + --no-color=tooltip: bar colored"  .text
assert_plain   "NO_COLOR=1 + --no-color=tooltip: tooltip plain" .tooltip
export NO_COLOR=""
run_claudebar "$FX"
assert_colored "NO_COLOR empty: bar colored"     .text
assert_colored "NO_COLOR empty: tooltip colored" .tooltip
unset NO_COLOR

echo "== unknown value is an argument error"
run_claudebar "$FX" --no-color=purple
assert_exit0      "unknown value: exit 0"
assert_json_valid "unknown value: valid JSON"
assert_class      "unknown value: critical class" critical
assert_tip_has    "unknown value: names the options" "--no-color must be all, bar, or tooltip"
run_claudebar "$FX" --json --no-color=purple
assert_exit0 "unknown value in JSON mode: exit 0"
assert_json_valid "unknown value in JSON mode: valid JSON"
_jq_is() { local got; got=$(jq -r "$2" <<<"$OUT"); [[ "$got" == "$3" ]] && _ok "$1" || _no "$1" "got $got want $3"; }
_jq_is "unknown value in JSON mode: schema_version" '.schema_version' '2'
_jq_is "unknown value in JSON mode: error message" '.error.message' '--no-color must be all, bar, or tooltip'

echo "== structured JSON is unchanged with and without the flag"
# Everything except the cache clock: each run gets a fresh fake HOME, so
# updated_at/data_age_seconds legitimately move between invocations.
_json_stable() { jq -S 'del(.data_age_seconds, .updated_at)' <<<"$1"; }
run_claudebar "$FX" --json;             plain_off=$(_json_stable "$OUT")
run_claudebar "$FX" --json --no-color;  plain_on=$(_json_stable "$OUT")
[[ "$plain_off" == "$plain_on" ]] && _ok "--json unchanged by --no-color" \
    || _no "--json unchanged by --no-color" "$(diff <(printf '%s' "$plain_off") <(printf '%s' "$plain_on"))"
run_claudebar "$FX" --json --no-color=bar; plain_bar=$(_json_stable "$OUT")
[[ "$plain_off" == "$plain_bar" ]] && _ok "--json unchanged by --no-color=bar" \
    || _no "--json unchanged by --no-color=bar" "$(diff <(printf '%s' "$plain_off") <(printf '%s' "$plain_bar"))"
export NO_COLOR=1
run_claudebar "$FX" --json; plain_env=$(_json_stable "$OUT")
unset NO_COLOR
[[ "$plain_off" == "$plain_env" ]] && _ok "--json unchanged by NO_COLOR env" \
    || _no "--json unchanged by NO_COLOR env" "$(diff <(printf '%s' "$plain_off") <(printf '%s' "$plain_env"))"
# The palette field is presentation data for the plugin, not markup: it stays.
run_claudebar "$FX" --json --no-color
_jq_is "palette survives --no-color" '.palette.low' '#98c379'

echo "== monochrome composes with other flags"
run_claudebar "$FX" --no-color --remaining
assert_exit0  "--no-color --remaining: exit 0"
assert_plain  "--no-color --remaining: bar plain"     .text
assert_plain  "--no-color --remaining: tooltip plain" .tooltip
# --frame is deprecated and a no-op: it must still be ACCEPTED (an existing
# Waybar config keeps working) and must change nothing.
run_claudebar "$FX" --no-color --frame
assert_plain  "--no-color --frame: tooltip plain"     .tooltip
assert_lacks  "--no-color --frame: draws no box"      .tooltip "╭"
_with_frame=$(jq -r .tooltip <<<"$OUT")
run_claudebar "$FX" --no-color
[[ "$(jq -r .tooltip <<<"$OUT")" == "$_with_frame" ]] \
    && _ok "--frame changes nothing" || _no "--frame changes nothing" "tooltip differs"
run_claudebar "$FX" --no-color --format-pace-color --format '{session_pace_delta}'
assert_plain  "--no-color beats --format-pace-color"  .text

finish
