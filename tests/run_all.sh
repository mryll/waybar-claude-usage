#!/usr/bin/env bash
# Run the whole suite; non-zero exit if any file fails.
cd "$(dirname "$0")"
rc=0
for t in test_*.sh; do
  echo "== $t =="
  bash "$t" || rc=1
done
echo "== lint =="
bash -n ../claudebar || rc=1
if command -v shellcheck >/dev/null 2>&1; then
  n=$(shellcheck -S style ../claudebar | grep -cE 'SC[0-9]+ \(')
  echo "shellcheck warnings: $n (baseline 4)"
  [[ "$n" -le 4 ]] || rc=1
else
  echo "shellcheck not installed — skipped"
fi
exit $rc
