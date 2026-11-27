#!/usr/bin/env bash
# Checks that the UI tests' sample project (its/projects/codescan-sample) is complete in git: every file its README
# lists, and every other file in the folder, is tracked. A file that only exists in one working tree (for example
# because a .gitignore rule hides it) passes the UI tests there and fails them everywhere else.
# Run from anywhere: bash scripts/qa/test-codescan-sample.sh. Works with macOS bash 3.2 and Linux bash.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SAMPLE=its/projects/codescan-sample
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ $# -lt 2 ] || echo "       $2"; }
tracked() { git -C "$ROOT" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; }

[ -f "$ROOT/$SAMPLE/README" ] || { echo "error: no $SAMPLE/README" >&2; exit 2; }

# The README lists each file as "- <path>: <what it is for>".
LISTED="$(sed -n 's/^- \([^ :]*\):.*/\1/p' "$ROOT/$SAMPLE/README")"
[ -n "$LISTED" ] && ok "the README lists files" || not_ok "the README lists files" "no '- <path>:' line found"
for P in $LISTED; do
  if [ ! -f "$ROOT/$SAMPLE/$P" ]; then
    not_ok "README file exists: $P" "missing from the working tree"
  elif tracked "$SAMPLE/$P"; then
    ok "README file is tracked by git: $P"
  else
    not_ok "README file is tracked by git: $P" "$(git -C "$ROOT" check-ignore -v -- "$SAMPLE/$P" 2>/dev/null || echo "not added")"
  fi
done

UNTRACKED=0
while IFS= read -r F; do
  [ -n "$F" ] || continue
  tracked "$F" && continue
  UNTRACKED=1
  not_ok "tracked by git: $F" "$(git -C "$ROOT" check-ignore -v -- "$F" 2>/dev/null || echo "not added")"
done <<EOF
$(cd "$ROOT" && find "$SAMPLE" -type f | sort)
EOF
[ "$UNTRACKED" -eq 0 ] && ok "every file in $SAMPLE is tracked by git"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
