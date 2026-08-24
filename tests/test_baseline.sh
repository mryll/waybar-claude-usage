#!/usr/bin/env bash
# shellcheck disable=SC2034  # fixtures referenced indirectly via ${!fx_name}
# Backward-compat guard: NO accidental output change. Compares the current script
# vs the last commit with an intentionally accepted output (bump BASE_REF when a
# release changes the output on purpose), same instant (tooltip embeds wall-clock
# time), over a matrix of fixtures × existing flags.
source "$(dirname "$0")/lib.sh"
BASE_REF="${BASE_REF:-ba67db1}"   # the tooltip meter reaches the right edge
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Since the continuous-gradient release, tooltip colors are interpolated per
# percentage and usage bars are colored per cell, so Pango span colors and span
# structure intentionally differ from older refs. norm() therefore strips Pango
# tags and compares the PLAIN-TEXT structure (text content, bar lengths, glyphs,
# layout, class field) — still a byte-level guard for everything that was not
# deliberately changed. Bump BASE_REF at the next release to restore full
# byte-identity comparison.
norm(){ sed 's/Updated [0-9][0-9]:[0-9][0-9]/Updated XX:XX/g; s/<[^>]*>//g'; }
# Extra-usage copy and its meter intentionally changed to distinguish prepaid
# balance from the monthly cap. Preserve the historical guard for the bar face
# and every tooltip section before that boundary; test_extra_usage.sh owns the
# new credit section contract itself.
norm_before_extra(){
    norm | jq -c '.tooltip |= (split("  󰄑  Extra usage")[0] | gsub("─+"; "─"))'
}
base="$(mktemp)"
git -C "$REPO" show "$BASE_REF:claudebar" > "$base" || { echo "FATAL: cannot extract $BASE_REF:claudebar" >&2; rm -f "$base"; exit 1; }
chmod +x "$base"

# fixtures
MIN='{"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":27,"resets_at":"2030-01-01T00:00:00+00:00"}}'
SON='{"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":27,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day_sonnet":{"utilization":15,"resets_at":"2030-01-01T00:00:00+00:00"}}'
EXTRA='{"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":27,"resets_at":"2030-01-01T00:00:00+00:00"},"extra_usage":{"is_enabled":true,"used_credits":250,"monthly_limit":5000}}'
BAD='{"five_hour":{"utilization":"x"},"seven_day":{"utilization":null}}'

cmp_same() {  # <name> <usage> [flags...]
    local name="$1" usage="$2"; shift 2
    SCRIPT="$base" run_claudebar "$usage" "$@"; local b; b="$(norm <<<"$OUT")"
    run_claudebar "$usage" "$@";               local n; n="$(norm <<<"$OUT")"
    [[ "$b" == "$n" ]] && _ok "$name" || _no "$name" "$(diff <(printf '%s' "$b") <(printf '%s' "$n") | head -40)"
}

cmp_same_before_extra() {  # <name> <usage> [flags...]
    local name="$1" usage="$2"; shift 2
    SCRIPT="$base" run_claudebar "$usage" "$@"; local b; b="$(norm_before_extra <<<"$OUT")"
    run_claudebar "$usage" "$@";               local n; n="$(norm_before_extra <<<"$OUT")"
    [[ "$b" == "$n" ]] && _ok "$name" || _no "$name" "$(diff <(printf '%s' "$b") <(printf '%s' "$n") | head -40)"
}

for fx_name in MIN SON BAD; do
    fx="${!fx_name}"
    cmp_same "baseline $fx_name default"          "$fx"
    cmp_same "baseline $fx_name --tooltip-pace-pts" "$fx" --tooltip-pace-pts
    cmp_same "baseline $fx_name custom --format"   "$fx" --format '{session_pct}% w{weekly_pct}%'
    cmp_same "baseline $fx_name custom --tooltip-format" "$fx" --tooltip-format '{session_bar} {weekly_bar}'
done

cmp_same_before_extra "baseline EXTRA default" "$EXTRA"
cmp_same_before_extra "baseline EXTRA --tooltip-pace-pts" "$EXTRA" --tooltip-pace-pts
cmp_same_before_extra "baseline EXTRA custom --format" "$EXTRA" --format '{session_pct}% w{weekly_pct}%'
cmp_same "baseline EXTRA custom --tooltip-format" "$EXTRA" --tooltip-format '{session_bar} {weekly_bar}'

# --- v0.7.0 baseline: zero- and one-model limits[] payloads must render
# byte-identically to the first model-scoped release (BASE_REF predates limits[]).
MODEL_BASE_REF="${MODEL_BASE_REF:-ba67db1}"   # same
git -C "$REPO" show "$MODEL_BASE_REF:claudebar" > "$base" || { echo "FATAL: cannot extract $MODEL_BASE_REF:claudebar" >&2; rm -f "$base"; exit 1; }
FAB='{"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":27,"resets_at":"2030-01-01T00:00:00+00:00"},"limits":[{"kind":"weekly_scoped","percent":67,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}'
for fx_name in MIN FAB; do
    fx="${!fx_name}"
    cmp_same "baseline-0.7 $fx_name default"            "$fx"
    cmp_same "baseline-0.7 $fx_name --tooltip-pace-pts" "$fx" --tooltip-pace-pts
    cmp_same "baseline-0.7 $fx_name --remaining"        "$fx" --remaining
    cmp_same "baseline-0.7 $fx_name custom --format"    "$fx" --format '{model_name} {model_pct}% {model_bar}'
done

rm -f "$base"
finish
