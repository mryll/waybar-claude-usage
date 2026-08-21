# Demo fixture

`demo-data` impersonates `claudebar` with a fixed, plausible day of usage, so README screenshots show every section at once — five usage windows spread across the whole color gauge (34% green → 100% red), all four pacing states, and a fully populated credit ledger — without exposing a real account. It builds a throwaway `HOME` containing the API documents the real script would have cached and then runs the real script against it, so bar text, tooltip, `--json`, `--no-color` and theme resolution behave exactly as in production. Resets are computed at run time, so countdowns and pacing stay live.

```bash
PATH="$PWD/screenshots/demo:$PATH" claudebar          # waybar mode
PATH="$PWD/screenshots/demo:$PATH" claudebar --json   # structured mode
```

Optional variants: `CLAUDEBAR_DEMO_ERROR=429` (or `503:Custom message`) renders the API-error card, and `CLAUDEBAR_DEMO_STALE=1` renders the `` stale footer instead of `Updated HH:MM`. This directory is documentation tooling only — it is not part of the build, the install target, or the test suite.
