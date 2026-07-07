#!/usr/bin/env bash
# shellcheck disable=SC2034  # fixtures referenced indirectly via ${!fx_name}
# Backward-compat guard: NO accidental output change. Compares the current script
# vs the last commit with an intentionally accepted output (bump BASE_REF when a
# release changes the output on purpose), same instant (tooltip embeds wall-clock
# time), over a matrix of fixtures × existing flags.
source "$(dirname "$0")/lib.sh"
BASE_REF="${BASE_REF:-ac1f66a}"   # v0.5.0 — plain tooltip default + --frame/--frame-font
REPO="$(cd "$(dirname "$0")/.." && pwd)"
norm(){ sed 's/Updated [0-9][0-9]:[0-9][0-9]/Updated XX:XX/g'; }
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

for fx_name in MIN SON EXTRA BAD; do
    fx="${!fx_name}"
    cmp_same "baseline $fx_name default"          "$fx"
    cmp_same "baseline $fx_name --tooltip-pace-pts" "$fx" --tooltip-pace-pts
    cmp_same "baseline $fx_name custom --format"   "$fx" --format '{session_pct}% w{weekly_pct}%'
    cmp_same "baseline $fx_name custom --tooltip-format" "$fx" --tooltip-format '{session_bar} {weekly_bar}'
done

# --- v0.7.0 baseline: zero- and one-model limits[] payloads must render
# byte-identically to the first model-scoped release (BASE_REF predates limits[]).
MODEL_BASE_REF="${MODEL_BASE_REF:-08aedef}"   # v0.7.0 — model-scoped weekly limits
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
