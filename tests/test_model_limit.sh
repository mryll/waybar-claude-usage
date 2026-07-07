#!/usr/bin/env bash
# Model-scoped weekly limit (limits[] kind "weekly_scoped", e.g. Fable).
source "$(dirname "$0")/lib.sh"

BASE='"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":27,"resets_at":"2030-01-01T00:00:00+00:00"}'
FABLE='{'"$BASE"',"limits":[{"kind":"session","group":"session","percent":42,"resets_at":"2030-01-01T00:00:00+00:00","scope":null},{"kind":"weekly_all","group":"weekly","percent":27,"resets_at":"2030-01-01T00:00:00+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":67,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}'

# --- default tooltip gets a "<Model> only" section ---
run_claudebar "$FABLE"
assert_exit0 "fable: exit 0"; assert_json_valid "fable: valid JSON"
assert_tip_has "fable: tooltip section" "Fable only"
assert_tip_has "fable: tooltip pct" "67%"
assert_class "fable: 67% drives class mid" "mid"

# --- placeholders ---
run_claudebar "$FABLE" --format '{model_name} {model_pct}% r{model_remaining_pct} {model_reset}'
assert_exit0 "placeholders: exit 0"
assert_text_has "placeholders: name" "Fable"
assert_text_has "placeholders: pct" "67%"
assert_text_has "placeholders: remaining" "r33"
run_claudebar "$FABLE" --format '{model_bar}'
assert_json_valid "model_bar: valid JSON"; assert_text_has "model_bar renders blocks" "█"

# --- class picks up a critical model limit ---
CRIT="${FABLE//\"percent\":67/\"percent\":95}"
run_claudebar "$CRIT"
assert_class "model 95% drives class critical" "critical"

# --- no limits[] → placeholders degrade like sonnet's ---
run_claudebar '{'"$BASE"'}' --format 'n[{model_name}] p{model_pct}'
assert_exit0 "no limits: exit 0"; assert_json_valid "no limits: valid JSON"
assert_text_has "no limits: empty name, pct 0" "n[] p0"
run_claudebar '{'"$BASE"'}'
_plain .tooltip | grep -q " only" && _no "no limits: no model section" "tooltip has ' only'" || _ok "no limits: no model section"

# --- weekly_scoped without a model scope is ignored ---
SURF='{'"$BASE"',"limits":[{"kind":"weekly_scoped","percent":80,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":null,"surface":"cowork"}}]}'
run_claudebar "$SURF"
assert_exit0 "surface-scoped: exit 0"; assert_class "surface-scoped ignored: class low" "low"

# --- dedup: seven_day_sonnet + scoped Sonnet limit → one section only ---
DUP='{'"$BASE"',"seven_day_sonnet":{"utilization":15,"resets_at":"2030-01-01T00:00:00+00:00"},"limits":[{"kind":"weekly_scoped","percent":15,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Sonnet"}}}]}'
run_claudebar "$DUP"
assert_exit0 "sonnet dedup: exit 0"
n=$(_plain .tooltip | grep -c "Sonnet only")
[[ "$n" == "1" ]] && _ok "sonnet dedup: single section" || _no "sonnet dedup: single section" "count=$n"

# --- dedup must not shadow a later real model: [Sonnet dup, Fable] → both sections ---
ORD='{'"$BASE"',"seven_day_sonnet":{"utilization":15,"resets_at":"2030-01-01T00:00:00+00:00"},"limits":[{"kind":"weekly_scoped","percent":15,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Sonnet"}}},{"kind":"weekly_scoped","percent":67,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}'
run_claudebar "$ORD"
assert_exit0 "sonnet-then-fable: exit 0"
assert_tip_has "sonnet-then-fable: fable section survives" "Fable only"
n=$(_plain .tooltip | grep -c "Sonnet only")
[[ "$n" == "1" ]] && _ok "sonnet-then-fable: sonnet not duplicated" || _no "sonnet-then-fable: sonnet not duplicated" "count=$n"

# --- multiple model-scoped limits → one tooltip section per model ---
MULTI='{'"$BASE"',"limits":[{"kind":"weekly_scoped","percent":67,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":89,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Opus"}}}]}'
run_claudebar "$MULTI"
assert_exit0 "multi-model: exit 0"; assert_json_valid "multi-model: valid JSON"
assert_tip_has "multi-model: first section" "Fable only"
assert_tip_has "multi-model: second section" "Opus only"
assert_class "multi-model: worst limit (89) drives class" "high"
# each section carries its OWN values, not the first entry's
_plain .tooltip | grep -A2 "Fable only" | grep -q "67%" && _ok "multi-model: fable has 67%" || _no "multi-model: fable has 67%" "$(_plain .tooltip | grep -A2 'Fable only')"
_plain .tooltip | grep -A2 "Opus only" | grep -q "89%" && _ok "multi-model: opus has 89%" || _no "multi-model: opus has 89%" "$(_plain .tooltip | grep -A2 'Opus only')"

# {model_*} placeholders track the FIRST entry
run_claudebar "$MULTI" --format '{model_name} {model_pct}%'
assert_exit0 "multi-model placeholders: exit 0"; assert_json_valid "multi-model placeholders: valid JSON"
assert_text_has "multi-model: placeholders = first entry" "Fable 67%"

# a second model at 100 flips class to critical
MULTI100="${MULTI//\"percent\":89/\"percent\":100}"
run_claudebar "$MULTI100"
assert_exit0 "multi-model 100: exit 0"; assert_json_valid "multi-model 100: valid JSON"
assert_class "multi-model: second at 100 → critical" "critical"

# --- hostile size: 6 valid entries → capped at 4 sections, contract holds ---
_entries=""
for i in 1 2 3 4 5 6; do
    _entries+='{"kind":"weekly_scoped","percent":'"$((i*10))"',"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"M'"$i"'"}}},'
done
CAP='{'"$BASE"',"limits":['"${_entries%,}"']}'
run_claudebar "$CAP"
assert_exit0 "cap: exit 0"; assert_json_valid "cap: valid JSON"
n=$(_plain .tooltip | grep -c " only")
[[ "$n" == "4" ]] && _ok "cap: 6 entries render 4 sections" || _no "cap: 6 entries render 4 sections" "count=$n"

# dedup composes with multi-model: [Sonnet dup, Fable, Opus] → all three, Sonnet once
TRI='{'"$BASE"',"seven_day_sonnet":{"utilization":15,"resets_at":"2030-01-01T00:00:00+00:00"},"limits":[{"kind":"weekly_scoped","percent":15,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Sonnet"}}},{"kind":"weekly_scoped","percent":67,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":30,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Opus"}}}]}'
run_claudebar "$TRI"
assert_exit0 "tri-model dedup: exit 0"; assert_json_valid "tri-model dedup: valid JSON"
assert_tip_has "tri-model dedup: fable shown" "Fable only"
assert_tip_has "tri-model dedup: opus shown" "Opus only"
n=$(_plain .tooltip | grep -c "Sonnet only")
[[ "$n" == "1" ]] && _ok "tri-model dedup: sonnet once" || _no "tri-model dedup: sonnet once" "count=$n"

# --- Pango escaping of display_name ---
ESC='{'"$BASE"',"limits":[{"kind":"weekly_scoped","percent":10,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"A<b>&c"}}}]}'
run_claudebar "$ESC"
assert_exit0 "escaping: exit 0"; assert_json_valid "escaping: valid JSON"
jq -r .tooltip <<<"$OUT" | grep -q "A&lt;b&gt;&amp;c" && _ok "escaping: name escaped" || _no "escaping: name escaped" "$(jq -r .tooltip <<<"$OUT" | grep -o 'A[^ ]*' | head -1)"

# escaped & survives {model_name} substitution (bash 5.2 patsub_replacement)
run_claudebar "$ESC" --format '{model_name}'
jq -r .text <<<"$OUT" | grep -qF "A&lt;b&gt;&amp;c" && _ok "escaping: --format keeps & literal" || _no "escaping: --format keeps & literal" "$(jq -r .text <<<"$OUT")"
run_claudebar "$ESC" --tooltip-format '{model_name}'
jq -r .tooltip <<<"$OUT" | grep -qF "A&lt;b&gt;&amp;c" && _ok "escaping: --tooltip-format keeps & literal" || _no "escaping: --tooltip-format keeps & literal" "$(jq -r .tooltip <<<"$OUT")"

# --- malformed scope.model (string) must not render or drive class ---
BADMODEL='{'"$BASE"',"limits":[{"kind":"weekly_scoped","percent":95,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":"bad"}}]}'
run_claudebar "$BADMODEL"
assert_exit0 "scope.model string: exit 0"; assert_class "scope.model string ignored: class low" "low"

# --- limits as an object (not array) is ignored, even with valid-looking entry ---
OBJLIMITS='{'"$BASE"',"limits":{"x":{"kind":"weekly_scoped","percent":95,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}}}'
run_claudebar "$OBJLIMITS"
assert_exit0 "limits object: exit 0"; assert_class "limits object ignored: class low" "low"

# --- non-string display_name falls back to "Model" ---
NUMNAME='{'"$BASE"',"limits":[{"kind":"weekly_scoped","percent":10,"resets_at":"2030-01-01T00:00:00+00:00","scope":{"model":{"display_name":7}}}]}'
run_claudebar "$NUMNAME"
assert_exit0 "numeric name: exit 0"; assert_tip_has "numeric name: Model fallback" "Model only"

# --- smoke: model window under the other flags ---
run_claudebar "$FABLE" --remaining
assert_exit0 "--remaining: exit 0"; assert_json_valid "--remaining: valid JSON"
assert_tip_has "--remaining: fable remaining pct" "33%"
run_claudebar "$FABLE" --tooltip-pace-pts
assert_exit0 "--tooltip-pace-pts: exit 0"; assert_json_valid "--tooltip-pace-pts: valid JSON"
run_claudebar "$FABLE" --format-pace-color --format '{model_pace_pts}'
assert_exit0 "--format-pace-color: exit 0"; assert_json_valid "--format-pace-color: valid JSON"

# --- control chars in resets_at must not split the TSV into fake rows ---
INJ='{'"$BASE"',"limits":[{"kind":"weekly_scoped","percent":10,"resets_at":"2030-01-01\n<span foreground=\"red\">X</span>\t99","scope":{"model":{"display_name":"Fable"}}}]}'
run_claudebar "$INJ"
assert_exit0 "resets_at injection: exit 0"; assert_json_valid "resets_at injection: valid JSON"
n=$(_plain .tooltip | grep -c " only")
[[ "$n" == "1" ]] && _ok "resets_at injection: single model row" || _no "resets_at injection: single model row" "count=$n"
jq -r .tooltip <<<"$OUT" | grep -q '<span foreground="red">' && _no "resets_at injection: no raw Pango injected" "raw span leaked" || _ok "resets_at injection: no raw Pango injected"

# --- malformed limits payloads never crash ---
for bad in '"limits":5' '"limits":[3,"x",null]' '"limits":[{"kind":"weekly_scoped","scope":"str"}]' '"limits":[{"kind":"weekly_scoped","percent":"high","scope":{"model":{"display_name":7}}}]' '"limits":[{"kind":"weekly_scoped","percent":1e100,"resets_at":5,"scope":{"model":{}}}]'; do
    run_claudebar '{'"$BASE"','"$bad"'}'
    assert_exit0 "malformed [$bad]: exit 0"; assert_json_valid "malformed [$bad]: valid JSON"
done

finish
