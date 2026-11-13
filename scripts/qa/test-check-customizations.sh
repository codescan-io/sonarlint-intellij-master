#!/usr/bin/env bash
#
# Tests for check-customizations.sh.
#
# It unpacks two real source trees from git (with `git archive`, so no
# worktree is left behind):
#   - the last CodeScan release (PRE_REF, default pre-catchup-7.2.3): every check must PASS;
#   - plain upstream SonarLint (UP_REF, default 10.14.1.80220): the checks must FAIL and name the rows.
# Then it changes single files in the CodeScan tree to prove each check can fail,
# and builds tiny plugin zips by hand to test --zip.
#
# Needs: git, tar, zip, unzip. Works on macOS bash 3.2 and Linux.
# Usage: scripts/qa/test-check-customizations.sh
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CHECK="$HERE/check-customizations.sh"
REPO=$(git -C "$HERE" rev-parse --show-toplevel) || { echo "not inside a git checkout" >&2; exit 2; }
PRE_REF=${PRE_REF:-pre-catchup-7.2.3}
UP_REF=${UP_REF:-10.14.1.80220}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-cust-test.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

PASSES=0
FAILS=0
ok()     { PASSES=$((PASSES + 1)); echo "ok     - $1"; }
not_ok() { FAILS=$((FAILS + 1));   echo "NOT OK - $1"; }

# run_check <name> <args...>: runs the script, stores output in $WORK/<name>.out and exit code in RC
RC=0
run_check() {
  name=$1; shift
  if [ -x "$CHECK" ]; then
    "$CHECK" "$@" > "$WORK/$name.out" 2>&1
    RC=$?
  else
    echo "check-customizations.sh is missing or not executable: $CHECK" > "$WORK/$name.out"
    RC=127
  fi
}

expect_rc() {        # expect_rc <name> <expected rc: 0 | nonzero>
  if [ "$2" = 0 ]; then
    if [ "$RC" -eq 0 ]; then ok "$1: exit code 0"; else not_ok "$1: expected exit code 0, got $RC"; fi
  else
    if [ "$RC" -ne 0 ]; then ok "$1: exit code non-zero ($RC)"; else not_ok "$1: expected non-zero exit code, got 0"; fi
  fi
}

expect_line() {      # expect_line <name> <regex> : some output line matches
  if grep -Eq "$2" "$WORK/$1.out"; then ok "$1: output has /$2/"; else not_ok "$1: output lacks /$2/"; fi
}

expect_no_line() {   # expect_no_line <name> <regex>
  if grep -Eq "$2" "$WORK/$1.out"; then not_ok "$1: output should not have /$2/"; else ok "$1: output has no /$2/"; fi
}

show_output() {      # print the script output when a group of tests failed, to help debugging
  if [ "$FAILS" -ne "$1" ]; then
    echo "----- output of $2 -----"
    sed 's/^/    | /' "$WORK/$2.out"
    echo "-----"
  fi
}

extract() {
  mkdir -p "$2"
  if ! git -C "$REPO" rev-parse -q --verify "$1^{commit}" > /dev/null; then
    echo "git ref $1 not found in $REPO" >&2
    return 1
  fi
  git -C "$REPO" archive --format=tar "$1" | tar -x -C "$2"
}

ROWS="P1 P2 P4 P5 P8 P9"

PRE="$WORK/pre tree"      # the space is on purpose: paths with spaces must work
UP="$WORK/upstream"
extract "$PRE_REF" "$PRE" || { echo "cannot unpack $PRE_REF"; exit 2; }
extract "$UP_REF" "$UP"   || { echo "cannot unpack $UP_REF"; exit 2; }

before=$FAILS
run_check pre "$PRE"
expect_rc pre 0
for id in $ROWS; do expect_line pre "^PASS $id "; done
expect_no_line pre "^FAIL "
show_output "$before" pre

before=$FAILS
run_check up "$UP"
expect_rc up nonzero
for id in $ROWS; do expect_line up "^FAIL $id "; done
expect_no_line up "^PASS "
expect_line up "^Failed rows: P1 P2 P4 P5 P8 P9$"
show_output "$before" up

run_check missing "$WORK/does-not-exist"
expect_rc missing nonzero
expect_no_line missing "^PASS "

mkdir -p "$WORK/empty"
run_check empty "$WORK/empty"
expect_rc empty nonzero
expect_no_line empty "^PASS "

run_check badopt --no-such-option "$PRE"
expect_rc badopt nonzero

run_check nozipfile --zip "$WORK/no-such.zip" "$PRE"
expect_rc nozipfile nonzero

ICONS="images/CodeScan.png images/CodeScanAction.svg images/CodeScanToolWindow.svg images/codescan-16.png images/codescan-round.png images/codescan@2x.png META-INF/pluginIcon.svg"

make_zip() {
  zipfile=$1; shift
  d=$(mktemp -d "$WORK/zip.XXXXXX")
  mkdir -p "$d/jar" "$d/plugin/CodeScan/lib"
  for e in "$@"; do mkdir -p "$d/jar/$(dirname "$e")"; echo x > "$d/jar/$e"; done
  echo x > "$d/jar/placeholder.txt"
  (cd "$d/jar" && zip -qr "$d/plugin/CodeScan/lib/codescan-intellij-7.3.0.jar" .)
  (cd "$d/plugin/CodeScan/lib" && echo x > other.txt && zip -q other.jar other.txt && rm other.txt)
  (cd "$d/plugin" && zip -qr "$zipfile" CodeScan)
}

if command -v zip > /dev/null 2>&1; then
  make_zip "$WORK/good.zip" $ICONS
  before=$FAILS
  run_check zipgood --zip "$WORK/good.zip" "$PRE"
  expect_rc zipgood 0
  expect_line zipgood "^PASS P4 .*zip"
  show_output "$before" zipgood

  make_zip "$WORK/noicon.zip" images/CodeScan.png images/CodeScanAction.svg images/codescan-16.png images/codescan-round.png images/codescan@2x.png META-INF/pluginIcon.svg
  before=$FAILS
  run_check zipbad --zip "$WORK/noicon.zip" "$PRE"
  expect_rc zipbad nonzero
  expect_line zipbad "^FAIL P4 .*zip.*CodeScanToolWindow.svg"
  expect_line zipbad "^Failed rows: P4$"
  show_output "$before" zipbad

  # a zip that is not a plugin zip at all (no lib/*.jar)
  (cd "$WORK" && echo x > readme.txt && zip -q notplugin.zip readme.txt)
  run_check zipnotplugin --zip "$WORK/notplugin.zip" "$PRE"
  expect_rc zipnotplugin nonzero
  expect_line zipnotplugin "^FAIL P4 "
else
  not_ok "zip command not found; cannot test --zip"
fi

# Each change below breaks exactly one row in the CodeScan tree; it is put back afterwards.
mutate_and_expect() {
  name=$1; file="$PRE/$2"; expr=$3; row=$4
  if [ ! -f "$file" ]; then not_ok "$name: file to change not found: $2"; return; fi
  cp "$file" "$WORK/saved"
  sed "$expr" "$WORK/saved" > "$file"
  if cmp -s "$file" "$WORK/saved"; then not_ok "$name: the change did nothing to $2"; cp "$WORK/saved" "$file"; return; fi
  before=$FAILS
  run_check "$name" "$PRE"
  expect_rc "$name" nonzero
  expect_line "$name" "^FAIL $row "
  expect_line "$name" "^Failed rows: $row$"
  show_output "$before" "$name"
  cp "$WORK/saved" "$file"
}

mutate_and_expect id-changed   src/main/resources/META-INF/plugin.xml 's:<id>com.code-scan.intellij</id>:<id>org.sonarlint.idea</id>:' P1
mutate_and_expect vendor-sonar src/main/resources/META-INF/plugin.xml 's:>CodeScan</vendor>:>SonarSource</vendor>:' P2
mutate_and_expect taint-on     common/src/main/java/org/sonarlint/intellij/common/util/SonarLintUtils.java '/isTaintVulnerabilitiesEnabled()/,/}/s/return false;/return true;/' P8
# If the code that adds the taint tab moves or is renamed, P8 cannot tell; it must FAIL rather than guess PASS.
mutate_and_expect taint-call-renamed src/main/java/org/sonarlint/intellij/ui/SonarLintToolWindowFactory.java 's/addTaintVulnerabilitiesTab(project/addSecurityTab(project/' P8
mutate_and_expect header-bad  src/main/java/org/sonarlint/intellij/SonarLintPlugin.java '2s/CodeScan for IntelliJ IDEA/SonarLint for IntelliJ IDEA/' P9
expect_line header-bad "SonarLintPlugin.java"

# The URL lives in two files; P5 must fail only when both lose it.
F2=src/main/java/org/sonarlint/intellij/config/global/wizard/CodescanCloudConstants.java
cp "$PRE/common/src/main/java/org/sonarlint/intellij/common/util/SonarLintUtils.java" "$WORK/saved-utils"
sed 's:https\://app.codescan.io:https\://sonarcloud.io:' "$WORK/saved-utils" > "$PRE/common/src/main/java/org/sonarlint/intellij/common/util/SonarLintUtils.java"
mutate_and_expect url-gone-all "$F2" 's:https\://app.codescan.io:https\://sonarcloud.io:' P5
cp "$WORK/saved-utils" "$PRE/common/src/main/java/org/sonarlint/intellij/common/util/SonarLintUtils.java"

mv "$PRE/src/main/resources/images/CodeScanAction.svg" "$WORK/icon"
run_check icon-gone "$PRE"
expect_rc icon-gone nonzero
expect_line icon-gone "^FAIL P4 .*CodeScanAction.svg"
expect_line icon-gone "^Failed rows: P4$"
mv "$WORK/icon" "$PRE/src/main/resources/images/CodeScanAction.svg"

# If the header comparison itself breaks, P9 must say FAIL, never PASS. (Skipped as root: root can read anything.)
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$PRE/src/main/java/org/sonarlint/intellij/SonarLintPlugin.java"
  run_check header-unreadable "$PRE"
  chmod 644 "$PRE/src/main/java/org/sonarlint/intellij/SonarLintPlugin.java"
  expect_rc header-unreadable nonzero
  expect_line header-unreadable "^FAIL P9 "
  expect_no_line header-unreadable "^PASS P9 "
fi

run_check pre-again "$PRE"
expect_rc pre-again 0

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
