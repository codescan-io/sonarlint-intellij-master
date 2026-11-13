#!/usr/bin/env bash
#
# Tests for check-customizations.sh.
#
# It unpacks two real source trees from git (with `git archive`, so no
# worktree is left behind):
#   - the last CodeScan release (PRE_REF, default pre-catchup-7.2.3) with the row P33 fix applied: every check must PASS;
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
  # Without --zip or --no-zip the script looks for a zip itself (and exits 3 if there is none); most cases are about
  # the source tree only, so they say --no-zip.
  case " $* " in *" --zip "*|*" --no-zip "*) ;; *) set -- --no-zip "$@" ;; esac
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

ROWS="P1 P2 P4 P5 P8 P9 P32"

PRE="$WORK/pre tree"      # the space is on purpose: paths with spaces must work
UP="$WORK/upstream"
extract "$PRE_REF" "$PRE" || { echo "cannot unpack $PRE_REF"; exit 2; }
extract "$UP_REF" "$UP"   || { echo "cannot unpack $UP_REF"; exit 2; }

# 7.2.3 registered the git branch provider under the old name, so it was never found (row P33). The baseline is
# 7.2.3 plus that fix; the p32-git-ns cases below put the old name back and must fail.
PRE_GIT_XML="$PRE/src/main/resources/META-INF/plugin-git.xml"
if ! grep -q 'defaultExtensionNs="org.sonarlint.idea"' "$PRE_GIT_XML"; then
  echo "plugin-git.xml in $PRE_REF no longer has the old name: update the row P33 fix in this script"
  exit 2
fi
sed 's:defaultExtensionNs="org.sonarlint.idea":defaultExtensionNs="com.code-scan.intellij":' "$PRE_GIT_XML" > "$PRE_GIT_XML.new" &&
  mv "$PRE_GIT_XML.new" "$PRE_GIT_XML"

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
expect_line up "^Failed rows: P1 P2 P4 P5 P8 P9 P32$"
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

PRE_VERSION=$(sed -n 's/^version=//p' "$PRE/gradle.properties")
ICONS="images/CodeScan.png images/CodeScanAction.svg images/CodeScanToolWindow.svg images/codescan-16.png images/codescan-round.png images/codescan@2x.png META-INF/pluginIcon.svg"

# stage_jar <dir>: lays out what the main plugin jar of a good CodeScan build holds. Real files come from the 7.2.3 tree.
# The SonarLintIcons.class is a stand-in: a text file with the icon paths, which is what the check looks for in a real class.
stage_jar() {
  d=$1
  mkdir -p "$d/META-INF" "$d/images" "$d/org/sonarlint/intellij"
  for e in $ICONS; do cp "$PRE/src/main/resources/$e" "$d/$e"; done
  for e in plugin.xml plugin-java.xml plugin-git.xml; do cp "$PRE/src/main/resources/META-INF/$e" "$d/META-INF/$e"; done
  # the build replaces ${project.version} in plugin.xml
  sed "s/\${project.version}/$PRE_VERSION/" "$PRE/src/main/resources/META-INF/plugin.xml" > "$d/META-INF/plugin.xml"
  : > "$d/org/sonarlint/intellij/SonarLintIcons.class"
  for e in CodeScan.png codescan-16.png CodeScanToolWindow.svg CodeScanAction.svg codescan-round.png codescan@2x.png execute.png; do
    echo "/images/$e" >> "$d/org/sonarlint/intellij/SonarLintIcons.class"
  done
  # a real class file also holds the names of its fields
  grep -ohE 'SonarLintIcons\.[A-Z_0-9]+' "$PRE"/src/main/resources/META-INF/plugin*.xml | sed 's/.*\.//' | sort -u >> "$d/org/sonarlint/intellij/SonarLintIcons.class"
}

# pack_zip <jar dir> <zipfile>: a plugin zip with the main jar (from the dir) and one unrelated jar next to it
pack_zip() {
  d=$(mktemp -d "$WORK/zip.XXXXXX")
  mkdir -p "$d/plugin/CodeScan/lib"
  (cd "$1" && zip -qr "$d/plugin/CodeScan/lib/${JARNAME:-codescan-intellij-7.3.0.jar}" .)
  (cd "$d/plugin/CodeScan/lib" && echo x > other.txt && zip -q other.jar other.txt && rm other.txt &&
    if [ -n "${EXTRAJAR:-}" ]; then cp other.jar "$EXTRAJAR"; fi)
  rm -f "$2"
  (cd "$d/plugin" && zip -qr "$2" CodeScan)
}

# zip_case <name> <rows> <command...>: stage a good jar, run <command> with the staging dir as $1, zip it, check the 7.2.3 tree
# with --zip, and expect exactly <rows> to fail ("-" means none must fail).
zip_case() {
  zname=$1; zrows=$2; shift 2
  zd=$(mktemp -d "$WORK/stage.XXXXXX")
  stage_jar "$zd"
  "$@" "$zd"
  pack_zip "$zd" "$WORK/$zname.zip"
  before=$FAILS
  run_check "$zname" --zip "$WORK/$zname.zip" "$PRE"
  if [ "$zrows" = "-" ]; then
    expect_rc "$zname" 0
    expect_no_line "$zname" "^FAIL "
  else
    expect_rc "$zname" nonzero
    for r in $zrows; do expect_line "$zname" "^FAIL $r .*zip"; done
    expect_line "$zname" "^Failed rows: $zrows$"
  fi
  show_output "$before" "$zname"
}

# Changes to a staged jar. The staging dir is always the last argument.
zrm()  { rm -f "$2/$1"; }                           # zrm <relpath> <dir>
zcp()  { cp "$1" "$3/$2"; }                         # zcp <source file> <relpath> <dir>
zsed() { sed "$1" "$3/$2" > "$3/$2.new" && mv "$3/$2.new" "$3/$2"; }   # zsed <sed script> <relpath> <dir>
UPMETA="$UP/src/main/resources/META-INF"

if command -v zip > /dev/null 2>&1; then
  zip_case zipgood - true
  expect_line zipgood "^PASS P4 .*zip"
  expect_line zipgood "^PASS P1 .*zip"
  expect_line zipgood "^PASS P2 .*zip"
  expect_line zipgood "^PASS P32 .*zip"

  zip_case zipbad P4 zrm images/CodeScanToolWindow.svg
  expect_line zipbad "^FAIL P4 .*zip.*CodeScanToolWindow.svg"

  # Finding 4: the icon code and the plugin icon inside the zip must be the CodeScan ones.
  zip_case zip-icons-code P4 zcp "$UP/src/main/java/org/sonarlint/intellij/SonarLintIcons.kt" org/sonarlint/intellij/SonarLintIcons.class
  zip_case zip-icon-upstream P4 zcp "$UPMETA/pluginIcon.svg" META-INF/pluginIcon.svg
  zip_case zip-icon-dark P4 zcp "$UPMETA/pluginIcon_dark.svg" META-INF/pluginIcon_dark.svg

  # Finding 3: plugin.xml inside the zip is read too (the build can rewrite it).
  zip_case zip-name P1 zsed 's:<name>CodeScan</name>:<name>Renamed</name>:' META-INF/plugin.xml
  zip_case zip-id "P1" zsed 's:<id>com.code-scan.intellij</id>:<id>org.sonarlint.idea</id>:' META-INF/plugin.xml
  zip_case zip-vendor P2 zsed 's:>CodeScan</vendor>:>SonarSource</vendor>:' META-INF/plugin.xml
  zip_case zip-no-plugin-xml "P1 P2 P4 P32" zrm META-INF/plugin.xml
  zip_case zip-java-ns P32 zsed 's:defaultExtensionNs="com.code-scan.intellij":defaultExtensionNs="org.sonarlint.idea":' META-INF/plugin-java.xml

  # a zip that is not a plugin zip at all (no lib/*.jar)
  (cd "$WORK" && echo x > readme.txt && zip -q notplugin.zip readme.txt)
  run_check zipnotplugin --zip "$WORK/notplugin.zip" "$PRE"
  expect_rc zipnotplugin nonzero
  expect_line zipnotplugin "^FAIL P4 "
else
  not_ok "zip command not found; cannot test --zip"
fi

# The real built 7.2.3 zip. It still has the row P33 bug (plugin-git.xml under the old name), so that must be its
# only failure and every other check must pass. Skipped when the zip has not been built here.
MAIN_REPO=$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)/.." 2> /dev/null && pwd)
REAL_ZIP=${REAL_ZIP:-$MAIN_REPO/build/distributions/CodeScan-7.3.0.zip}
if [ -f "$REAL_ZIP" ]; then
  before=$FAILS
  run_check realzip --zip "$REAL_ZIP" "$PRE"
  expect_rc realzip nonzero
  for id in $ROWS; do expect_line realzip "^PASS $id "; done
  expect_line realzip "^PASS P4 .*zip"
  expect_line realzip "^PASS P1 .*zip"
  expect_line realzip "^FAIL P32 zip: .*plugin-git.xml registers extensions under the SonarLint namespace"
  expect_line realzip "^Failed rows: P32$"
  if [ "$(grep -c '^FAIL ' "$WORK/realzip.out")" -eq 1 ]; then ok "realzip: plugin-git.xml is the only failure"; else not_ok "realzip: expected exactly one FAIL line"; fi
  show_output "$before" realzip
else
  echo "skip   - real zip test: $REAL_ZIP not found (build it with ./gradlew buildPlugin, or set REAL_ZIP)"
fi

# change_and_expect <name> <tree> <relpath> <PASS|FAIL> <row> <command...>
# Rewrites one file via <command>, runs the check, then restores it.
# In the CodeScan tree a FAIL must be the only failed row; in the upstream tree other rows fail anyway.
change_and_expect() {
  name=$1; tree=$2; rel=$3; want=$4; row=$5; shift 5
  file="$tree/$rel"
  if [ ! -f "$file" ]; then not_ok "$name: file to change not found: $rel"; return; fi
  cp "$file" "$WORK/saved"
  "$@" "$WORK/saved" > "$file"
  if cmp -s "$file" "$WORK/saved"; then not_ok "$name: the change did nothing to $rel"; cp "$WORK/saved" "$file"; return; fi
  before=$FAILS
  run_check "$name" "$tree"
  if [ "$want" = FAIL ]; then
    expect_line "$name" "^FAIL $row "
    expect_no_line "$name" "^PASS $row "
    if [ "$tree" = "$PRE" ]; then
      expect_rc "$name" nonzero
      expect_line "$name" "^Failed rows: $row$"
    fi
  else
    expect_line "$name" "^PASS $row "
    expect_no_line "$name" "^FAIL $row "
    [ "$tree" = "$PRE" ] && expect_rc "$name" 0
  fi
  show_output "$before" "$name"
  cp "$WORK/saved" "$file"
}

# Each change below breaks exactly one row in the CodeScan tree.
mutate_and_expect() { change_and_expect "$1" "$PRE" "$2" FAIL "$4" sed "$3"; }

TOOLWIN=src/main/java/org/sonarlint/intellij/ui/SonarLintToolWindowFactory.java
mutate_and_expect id-changed   src/main/resources/META-INF/plugin.xml 's:<id>com.code-scan.intellij</id>:<id>org.sonarlint.idea</id>:' P1
mutate_and_expect vendor-sonar src/main/resources/META-INF/plugin.xml 's:>CodeScan</vendor>:>SonarSource</vendor>:' P2
# A <vendor> element written over two lines must be read whole.
change_and_expect vendor-multiline-sonar "$PRE" src/main/resources/META-INF/plugin.xml FAIL P2 \
  awk '/<vendor/ { print "    <vendor email=\"support@codescan.io\""; print "            url=\"https://www.sonarsource.com\">SonarSource</vendor>"; next } { print }'
change_and_expect vendor-multiline-ok "$PRE" src/main/resources/META-INF/plugin.xml PASS P2 \
  awk '/<vendor/ { print "    <vendor email=\"support@codescan.io\""; print "            url=\"https://codescan.io\">CodeScan</vendor>"; next } { print }'
mutate_and_expect taint-on     common/src/main/java/org/sonarlint/intellij/common/util/SonarLintUtils.java '/isTaintVulnerabilitiesEnabled()/,/}/s/return false;/return true;/' P8
# If the code that adds the taint tab moves or is renamed, P8 cannot tell; it must FAIL rather than guess PASS.
mutate_and_expect taint-call-renamed "$TOOLWIN" 's/addTaintVulnerabilitiesTab(project/addSecurityTab(project/' P8
# Every call that adds the tab must be inside the switch, not just somewhere in the same file.
change_and_expect taint-unguarded-before "$PRE" "$TOOLWIN" FAIL P8 \
  awk '/if \(SonarLintUtils\.isTaintVulnerabilitiesEnabled\(\)\)/ { print "    addTaintVulnerabilitiesTab(project, contentManager);" } { print }'
change_and_expect taint-unguarded-after "$PRE" "$TOOLWIN" FAIL P8 \
  awk '{ print } /addLogTab\(project, toolWindow\);/ { print "    addTaintVulnerabilitiesTab(project, contentManager);" }'
mutate_and_expect header-bad  src/main/java/org/sonarlint/intellij/SonarLintPlugin.java '2s/CodeScan for IntelliJ IDEA/SonarLint for IntelliJ IDEA/' P9
expect_line header-bad "SonarLintPlugin.java"

# Extension point names must start with the plugin id, or the IDE silently finds no extensions.
mutate_and_expect ep-name-reverted common/src/main/java/org/sonarlint/intellij/common/LanguageActivator.java 's/"com\.code-scan\.intellij\.languageActivator"/"org.sonarlint.idea.languageActivator"/' P32
mutate_and_expect ep-qualified-sonar src/main/resources/META-INF/plugin.xml 's:<extensionPoints>:<extensionPoints><extensionPoint qualifiedName="org.sonarlint.idea.extra" interface="a.B"/>:' P32

# P5: the address must be the value actually used as the default, not just a string somewhere.
mutate_and_expect url-not-default src/main/java/org/sonarlint/intellij/config/global/wizard/ServerStep.java 's|setServerUrl(CodescanCloudConstants.CODESCAN_US_URL)|setServerUrl("https://sonarcloud.io")|' P5
mkdir -p "$UP/src/main/java/org/sonarlint/intellij"
printf 'package org.sonarlint.intellij;\nclass Unused { static final String URL = "https://app.codescan.io"; }\n' > "$UP/src/main/java/org/sonarlint/intellij/Unused.java"
run_check url-unused-const "$UP"
expect_line url-unused-const "^FAIL P5 "
expect_no_line url-unused-const "^PASS P5 "
rm -f "$UP/src/main/java/org/sonarlint/intellij/Unused.java"
# A default in getProperty alone is not the Redo (see the p5-backend-* cases below): upstream still returns null without the websocket property.
change_and_expect url-redo-form "$UP" src/main/java/org/sonarlint/intellij/core/BackendService.kt FAIL P5 \
  sed 's|getProperty("sonarlint.internal.sonarcloud.url")|getProperty("sonarlint.internal.sonarcloud.url", "https://app.codescan.io")|'

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

# ---- Fix round 2: every false PASS the reviewer found. Each case works on a fresh copy of a tree. ----

# new_case <name> [up]: copy the 7.2.3 tree (or the upstream tree) to $CASE
new_case() {
  CASE="$WORK/case-$1"; rm -rf "$CASE"
  if [ "${2:-}" = up ]; then cp -R "$UP" "$CASE"; else cp -R "$PRE" "$CASE"; fi
}
# case_sed <relpath> <sed script>
case_sed() { sed "$2" "$CASE/$1" > "$CASE/$1.new" && mv "$CASE/$1.new" "$CASE/$1"; }
# expect_rows <name> <rows>: the check must fail exactly these rows on $CASE (rows "-": nothing may fail)
expect_rows() {
  rname=$1; rrows=$2
  before=$FAILS
  run_check "$rname" "$CASE"
  if [ "$rrows" = "-" ]; then
    expect_rc "$rname" 0
    expect_no_line "$rname" "^FAIL "
  else
    expect_rc "$rname" nonzero
    for r in $rrows; do expect_line "$rname" "^FAIL $r "; done
    expect_line "$rname" "^Failed rows: $rrows$"
  fi
  show_output "$before" "$rname"
  rm -rf "$CASE"
}
UPICONS="$UP/src/main/java/org/sonarlint/intellij/SonarLintIcons.kt"
PIC=src/main/java/org/sonarlint/intellij/SonarLintIcons.kt
META=src/main/resources/META-INF

# P1: only the name changes, the id stays.
new_case name-only
case_sed $META/plugin.xml 's:<name>CodeScan</name>:<name>SonarLint</name>:'
expect_rows name-only "P1 P2"

# 1. P5 must follow the backend. In 10.x the wizard constant only fills the connection wizard.
new_case p5-wizard-only up
case_sed common/src/main/java/org/sonarlint/intellij/common/util/SonarLintUtils.java 's|DEFAULT_SONARCLOUD_URL = "https://sonarcloud.io"|DEFAULT_SONARCLOUD_URL = "https://app.codescan.io"|'
run_check p5-wizard-only "$CASE"
expect_line p5-wizard-only "^FAIL P5 "
expect_no_line p5-wizard-only "^PASS P5 "
rm -rf "$CASE"
# ... a default in getProperty or an elvis fallback does NOT reach the backend: upstream builds the DTO only when the
# websocket property is also set, and returns null otherwise. P5 is a first warning sign, Task 5 gets the real code test.
new_case p5-backend-default up
case_sed src/main/java/org/sonarlint/intellij/core/BackendService.kt 's|getProperty("sonarlint.internal.sonarcloud.url")|getProperty("sonarlint.internal.sonarcloud.url", "https://app.codescan.io")|'
run_check p5-backend-default "$CASE"
expect_line p5-backend-default "^FAIL P5 .*websocket"
expect_no_line p5-backend-default "^PASS P5 "
rm -rf "$CASE"
new_case p5-backend-elvis up
case_sed src/main/java/org/sonarlint/intellij/core/BackendService.kt 's|getProperty("sonarlint.internal.sonarcloud.url")$|getProperty("sonarlint.internal.sonarcloud.url") ?: "https://app.codescan.io"|'
run_check p5-backend-elvis "$CASE"
expect_line p5-backend-elvis "^FAIL P5 .*websocket"
expect_no_line p5-backend-elvis "^PASS P5 "
rm -rf "$CASE"

# 2. P4: the icon code and the plugin icon must be the CodeScan ones, not only present.
# (upstream's file with the CodeScan license header on top, so that only P4 is affected, not P9)
new_case p4-icons-code
{ head -19 "$CASE/$PIC"; tail -n +20 "$UPICONS"; } > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$PIC"
expect_rows p4-icons-code P4
# The same for the plugin icons: the header of CodeScan's pluginIcon.svg (7.2.3 has no dark one), then upstream's image.
svg_with_our_header() {
  { awk '{ print } /^-->/ { exit }' "$CASE/$META/pluginIcon.svg"; awk 'seen { print } /^-->/ { seen = 1 }' "$UP/$META/$1"; } > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$META/$1"
}
new_case p4-plugin-icon
svg_with_our_header pluginIcon.svg
expect_rows p4-plugin-icon P4
new_case p4-plugin-icon-dark
svg_with_our_header pluginIcon_dark.svg
expect_rows p4-plugin-icon-dark P4
new_case p4-icons-code-one-path
case_sed $PIC 's|"/images/CodeScanToolWindow.svg"|"/images/sonarlint-toolwindow.svg"|'
expect_rows p4-icons-code-one-path P4

# 3 (source part): P4 must fail for upstream's SonarLintIcons.kt, and P1/P2 name the zip when the zip is wrong: see the zip cases above.

# 4. P8: a commented-out guard is not a guard.
new_case p8-comment-line
awk '/if \(SonarLintUtils\.isTaintVulnerabilitiesEnabled\(\)\) \{/ { print "    // " $0; g = 1; next }
     g && /^ *}/ { print "    // " $0; g = 0; next } { print }' "$CASE/$TOOLWIN" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$TOOLWIN"
expect_rows p8-comment-line P8
new_case p8-comment-block
awk '/if \(SonarLintUtils\.isTaintVulnerabilitiesEnabled\(\)\) \{/ { print "    /* " $0 " */"; g = 1; next }
     g && /^ *}/ { print "    /* " $0 " */"; g = 0; next } { print }' "$CASE/$TOOLWIN" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$TOOLWIN"
expect_rows p8-comment-block P8
# A comment next to the real code must not break the real code: a trailing note after "return false;" is fine.
new_case p8-trailing-note
case_sed common/src/main/java/org/sonarlint/intellij/common/util/SonarLintUtils.java '/isTaintVulnerabilitiesEnabled()/,/}/s|return false;|return false; // was: return true;|'
expect_rows p8-trailing-note -

# 5. P5: a commented-out line is not a use. And a "//" inside a string is not a comment.
new_case p5-comment
case_sed src/main/java/org/sonarlint/intellij/config/global/wizard/ServerStep.java 's|^\( *\)model.setServerUrl(CodescanCloudConstants.CODESCAN_US_URL);|\1// model.setServerUrl(CodescanCloudConstants.CODESCAN_US_URL);|'
expect_rows p5-comment P5
new_case p5-comment-block
case_sed src/main/java/org/sonarlint/intellij/config/global/wizard/ServerStep.java 's|^\( *\)model.setServerUrl(CodescanCloudConstants.CODESCAN_US_URL);|\1/* model.setServerUrl(CodescanCloudConstants.CODESCAN_US_URL); */|'
expect_rows p5-comment-block P5
new_case p5-url-in-string
case_sed src/main/java/org/sonarlint/intellij/config/global/wizard/ServerStep.java 's|^\( *\)model.setServerUrl(CodescanCloudConstants.CODESCAN_US_URL);|\1model.setServerUrl("https://app.codescan.io"); // not https://sonarcloud.io|'
expect_rows p5-url-in-string -
new_case p5-url-in-string-comment-only
case_sed src/main/java/org/sonarlint/intellij/config/global/wizard/ServerStep.java 's|^\( *\)model.setServerUrl(CodescanCloudConstants.CODESCAN_US_URL);|\1model.setServerUrl("https://sonarcloud.io"); // was "https://app.codescan.io"|'
expect_rows p5-url-in-string-comment-only P5
# An XML comment around the real <name> must not hide a wrong one.
new_case p1-xml-comment
awk '/<name>CodeScan<\/name>/ { print "    <!-- <name>CodeScan</name> -->"; print "    <name>SonarLint</name>"; next } { print }' "$CASE/$META/plugin.xml" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$META/plugin.xml"
expect_rows p1-xml-comment "P1 P2"

# 6. P32: plugin-java.xml must register under com.code-scan.intellij; other plugin-*.xml files that plugin.xml loads too.
new_case p32-java-ns
case_sed $META/plugin-java.xml 's:defaultExtensionNs="com.code-scan.intellij":defaultExtensionNs="org.sonarlint.idea":'
expect_rows p32-java-ns P32
new_case p32-other-loaded
case_sed $META/plugin.xml 's:<depends optional="true" config-file="plugin-git.xml">Git4Idea</depends>:&<depends optional="true" config-file="plugin-plsql.xml">com.intellij.modules.plsql</depends>:'
expect_rows p32-other-loaded P32
# plugin-git.xml with the old name (as in 7.2.3, row P33): the git branch provider would never be found.
new_case p32-git-ns
case_sed $META/plugin-git.xml 's:defaultExtensionNs="com.code-scan.intellij":defaultExtensionNs="org.sonarlint.idea":'
expect_rows p32-git-ns P32
expect_line p32-git-ns "^FAIL P32 .*plugin-git.xml registers extensions under the SonarLint namespace"

# 8. P9: an empty source file has no header.
new_case p9-empty
: > "$CASE/src/main/java/org/sonarlint/intellij/EmptyThing.java"
expect_rows p9-empty P9
# 9. P9 skips **/proto/*.java, as the build's license check does (build.gradle.kts excludes it), but not deeper folders.
new_case p9-proto-dir
mkdir -p "$CASE/src/main/java/org/sonarlint/intellij/proto"
printf 'package org.sonarlint.intellij.proto;\nclass Handwritten {}\n' > "$CASE/src/main/java/org/sonarlint/intellij/proto/Handwritten.java"
expect_rows p9-proto-dir -
new_case p9-proto-subdir
mkdir -p "$CASE/src/main/java/org/sonarlint/intellij/proto/sub"
printf 'package org.sonarlint.intellij.proto.sub;\nclass Handwritten {}\n' > "$CASE/src/main/java/org/sonarlint/intellij/proto/sub/Handwritten.java"
expect_rows p9-proto-subdir P9
new_case p9-generated-skipped
mkdir -p "$CASE/build/generated/source/proto/main/java"
printf 'package x;\nclass Gen {}\n' > "$CASE/build/generated/source/proto/main/java/Gen.java"
expect_rows p9-generated-skipped -

# ---- Fix round 3: a third reviewer's trees that wrongly passed ----

BS=src/main/java/org/sonarlint/intellij/core/BackendService.kt
FCONTRIB=common/src/main/java/org/sonarlint/intellij/common/analysis/FilesContributor.java

# put_up <relpath>: copy ONE upstream file into $CASE. Java/Kotlin files keep the CodeScan license header, so that only
# the check under test reacts and not P9.
put_up() {
  mkdir -p "$(dirname "$CASE/$1")"
  case "$1" in
    *.java|*.kt)
      if [ -f "$CASE/$1" ]; then hdr="$CASE/$1"; else hdr="$PRE/$PIC"; fi
      { head -19 "$hdr"; tail -n +20 "$UP/$1"; } > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$1" ;;
    *) cp "$UP/$1" "$CASE/$1" ;;
  esac
}
# expect_fails <name> <rows>: run the check on $CASE; these rows must FAIL (other rows may fail too)
expect_fails() {
  fname=$1; frows=$2
  before=$FAILS
  run_check "$fname" "$CASE"
  expect_rc "$fname" nonzero
  for r in $frows; do expect_line "$fname" "^FAIL $r "; done
  show_output "$before" "$fname"
  rm -rf "$CASE"
}
# fix_backend: in an upstream copy, make the function always return the DTO with the CodeScan address (the intended fix)
fix_backend() {
  awk '/private fun getSonarCloudAlternativeEnvironment\(\)/ {
         print "    private fun getSonarCloudAlternativeEnvironment(): SonarCloudAlternativeEnvironmentDto {"
         print "        val sonarCloudUrl = System.getProperty(\"sonarlint.internal.sonarcloud.url\") ?: \"https://app.codescan.io\""
         print "        val sonarCloudWebSocketUrl = System.getProperty(\"sonarlint.internal.sonarcloud.websocket.url\") ?: \"wss://app.codescan.io/ws\""
         print "        return SonarCloudAlternativeEnvironmentDto(URI.create(sonarCloudUrl), URI.create(sonarCloudWebSocketUrl))"
         print "    }"
         skip = 1; next }
       skip && /^    }/ { skip = 0; next }
       skip { next }
       { print }' "$CASE/$BS" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$BS"
}
# expect_row_line <name> <PASS|FAIL> <row> [more regex]: run the check on $CASE and look at one row's line
expect_row_line() {
  rl=$1
  before=$FAILS
  run_check "$rl" "$CASE"
  expect_line "$rl" "^$2 $3 ${4:-}"
  if [ "$2" = PASS ]; then expect_no_line "$rl" "^FAIL $3 "; else expect_no_line "$rl" "^PASS $3 "; fi
  show_output "$before" "$rl"
  rm -rf "$CASE"
}

# 1a. The intended fix: the function always returns the DTO with the CodeScan address, and start-up passes it in.
new_case p5-backend-fixed up
fix_backend
expect_row_line p5-backend-fixed PASS P5
# 1b. Start-up passes a literal null instead of the alternative environment (what /tmp/rv/upB did).
new_case p5-start-null up
fix_backend
case_sed $BS 's|^\( *\)getSonarCloudAlternativeEnvironment(),|\1null,|'
expect_row_line p5-start-null FAIL P5 ".*InitializeParams"
new_case p5-upB up
case_sed $BS 's|^\( *\)getSonarCloudAlternativeEnvironment(),|\1null,|'
case_sed $BS 's|URI.create(sonarCloudUrl)|URI.create("https://app.codescan.io")|'
expect_row_line p5-upB FAIL P5
# 1c. A name that holds the address in ANOTHER file is not the same name.
new_case p5-decoy-name up
fix_backend
case_sed $BS 's|\(sonarlint.internal.sonarcloud.url")\) ?: "https://app.codescan.io"|\1|'
printf 'package org.sonarlint.intellij.core\nval sonarCloudUrl = "https://app.codescan.io"\n' > "$CASE/src/main/java/org/sonarlint/intellij/core/Decoy.kt"
expect_row_line p5-decoy-name FAIL P5
new_case p5-decoy-name-7
case_sed src/main/java/org/sonarlint/intellij/config/global/wizard/ServerStep.java 's|setServerUrl(CodescanCloudConstants.CODESCAN_US_URL)|setServerUrl(DEFAULT_URL)|'
{ head -19 "$CASE/$PIC"; printf 'package org.sonarlint.intellij.config.global.wizard;\nclass Decoy2 { static final String DEFAULT_URL = "https://app.codescan.io"; }\n'; } > "$CASE/src/main/java/org/sonarlint/intellij/config/global/wizard/Decoy2.java"
expect_rows p5-decoy-name-7 P5
# 1d. 10.x is told by BackendService.kt using InitializeParams, not by one exact import line.
new_case p5-wildcard-import up
case_sed $BS 's|^import org.sonarsource.sonarlint.core.rpc.protocol.backend.initialize.InitializeParams$|import org.sonarsource.sonarlint.core.rpc.protocol.backend.initialize.*|'
# the wizard alone sets the address (enough in 7.2.3, not in 10.x)
case_sed src/main/java/org/sonarlint/intellij/config/global/wizard/ServerStep.java 's|model.setServerUrl(SONARCLOUD_URL);|model.setServerUrl("https://app.codescan.io");|'
expect_row_line p5-wildcard-import FAIL P5

# 2. P4: upstream's branded images and names must not come back, in code, in plugin.xml and in the zip.
# preD from the reviewer: upstream's SONARQUBE_* icons added to SonarLintIcons.kt, and plugin.xml uses them.
add_up_icons() {
  awk '{ print } /val SONARLINT_32 = / {
    print "    val SONARQUBE_FOR_INTELLIJ_13PX = getIcon(\"/images/sonarqube_for_intellij_13px.svg\")"
    print "    val SONARQUBE_FOR_INTELLIJ_EMPTY_TOOLWINDOW = getIcon(\"/images/sonarqube_for_intellij_empty_toolwindow.svg\")" }' "$CASE/$PIC" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$PIC"
}
new_case p4-preD
add_up_icons
case_sed $META/plugin.xml 's/SonarLintIcons\.SONARLINT_ACTION/SonarLintIcons.SONARQUBE_FOR_INTELLIJ_13PX/'
case_sed $META/plugin.xml 's/SonarLintIcons\.SONARLINT_TOOLWINDOW_EMPTY/SonarLintIcons.SONARQUBE_FOR_INTELLIJ_EMPTY_TOOLWINDOW/'
expect_rows p4-preD P4
new_case p4-kt-upstream-names
add_up_icons
expect_rows p4-kt-upstream-names P4
new_case p4-xml-upstream-names
case_sed $META/plugin.xml 's/SonarLintIcons\.SONARLINT_ACTION/SonarLintIcons.SONARQUBE_FOR_INTELLIJ_13PX/'
expect_rows p4-xml-upstream-names P4
new_case p4-xml-name-only
awk '{ print } /val SONARLINT_ACTION = / { print "    @JvmField"; print "    val SONARQUBE_ACTION = getIcon(\"/images/CodeScanAction.svg\")" }' "$CASE/$PIC" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$PIC"
case_sed $META/plugin.xml 's/SonarLintIcons\.SONARLINT_ACTION/SonarLintIcons.SONARQUBE_ACTION/'
expect_rows p4-xml-name-only P4
if command -v zip > /dev/null 2>&1; then
  zapp() { echo "$1" >> "$3/$2"; }     # zapp <text> <relpath> <dir>
  zip_case zip-icons-sonar-path P4 zapp "/images/sonarqube_for_intellij_13px.svg" org/sonarlint/intellij/SonarLintIcons.class
  zip_case zip-xml-icon-field P4 zsed 's/SonarLintIcons\.SONARLINT_ACTION/SonarLintIcons.SONARQUBE_FOR_INTELLIJ_13PX/' META-INF/plugin.xml
  zip_case zip-xml-icon-unknown P4 zsed 's/SonarLintIcons\.SONARLINT_ACTION/SonarLintIcons.NOT_IN_THE_CLASS/' META-INF/plugin.xml
fi

# 3. One upstream file in an otherwise CodeScan tree.
# Upstream's file also turns taint and server events on in the backend flags, so P8 fails too.
new_case p5-up-backendservice
put_up $BS
expect_rows p5-up-backendservice "P5 P8"
new_case p32-up-filescontributor
put_up $FCONTRIB
expect_rows p32-up-filescontributor P32
new_case p32-up-pluginjava
put_up $META/plugin-java.xml
expect_rows p32-up-pluginjava P32
new_case p4-up-pluginxml
put_up $META/plugin.xml
expect_fails p4-up-pluginxml "P1 P2 P4"
new_case p4-up-icons-kt
put_up $PIC
expect_rows p4-up-icons-kt P4

# 4. No zip: look in build/distributions, otherwise say SKIP and exit 3 (0 only with --no-zip).
run_raw() { name=$1; shift; "$CHECK" "$@" > "$WORK/$name.out" 2>&1; RC=$?; }
expect_rc_is() { if [ "$RC" -eq "$2" ]; then ok "$1: exit code $2"; else not_ok "$1: expected exit code $2, got $RC"; fi; }
new_case zip-skip
run_raw zip-skip "$CASE"
expect_rc_is zip-skip 3
expect_line zip-skip '^SKIP zip checks \(no --zip and no build/distributions zip\)$'
expect_no_line zip-skip '^FAIL '
run_raw zip-noflag --no-zip "$CASE"
expect_rc_is zip-noflag 0
expect_line zip-noflag '^SKIP zip checks '
echo x > "$WORK/x.zip"
run_raw zip-both --no-zip --zip "$WORK/x.zip" "$CASE"
expect_rc_is zip-both 2
expect_line zip-both 'no-zip.*zip|zip.*no-zip'
expect_no_line zip-both 'Unknown|unknown'
case_sed $META/plugin.xml 's:<id>com.code-scan.intellij</id>:<id>org.sonarlint.idea</id>:'
run_raw zip-skip-fail "$CASE"
expect_rc_is zip-skip-fail 1
expect_line zip-skip-fail '^FAIL P1 '
rm -rf "$CASE"
if command -v zip > /dev/null 2>&1; then
  GD=$(mktemp -d "$WORK/stage.XXXXXX"); stage_jar "$GD"; pack_zip "$GD" "$WORK/good.zip"
  BD=$(mktemp -d "$WORK/stage.XXXXXX"); stage_jar "$BD"; rm -f "$BD/META-INF/plugin.xml"; pack_zip "$BD" "$WORK/bad.zip"
  new_case zip-found
  mkdir -p "$CASE/build/distributions"; cp "$WORK/good.zip" "$CASE/build/distributions/CodeScan-7.3.0.zip"
  run_raw zip-found "$CASE"
  expect_rc_is zip-found 0
  expect_line zip-found '^PASS P4 .*zip'
  expect_no_line zip-found '^SKIP '
  # several zips: the newest one is used
  cp "$WORK/bad.zip" "$CASE/build/distributions/CodeScan-7.2.0.zip"
  touch -t 202001010000 "$CASE/build/distributions/CodeScan-7.2.0.zip"
  run_raw zip-newest-good "$CASE"
  expect_rc_is zip-newest-good 0
  touch -t 202001010000 "$CASE/build/distributions/CodeScan-7.3.0.zip"
  touch -t 202101010000 "$CASE/build/distributions/CodeScan-7.2.0.zip"
  run_raw zip-newest-bad "$CASE"
  expect_rc_is zip-newest-bad 1
  expect_line zip-newest-bad '^FAIL P4 .*zip'
  rm -rf "$CASE"
fi

# 5. A stale zip (built from another version of the source) must fail.
if command -v zip > /dev/null 2>&1; then
  zip_case zip-stale P1 zsed 's:<version>7.3.0</version>:<version>7.2.9</version>:' META-INF/plugin.xml
  expect_line zip-stale '^FAIL P1 .*zip.*version'
  new_case zip-stale-source
  case_sed gradle.properties 's/^version=.*/version=7.4.0/'
  run_check zip-stale-source --zip "$WORK/good.zip" "$CASE"
  expect_line zip-stale-source '^FAIL P1 .*zip.*version'
  case_sed gradle.properties 's/^version=.*/# no version here/'
  run_check zip-no-version --zip "$WORK/good.zip" "$CASE"
  expect_line zip-no-version '^FAIL P1 .*version'
  rm -rf "$CASE"
fi

# set_alt_env_body <body file>: in $CASE (an upstream copy), replace getSonarCloudAlternativeEnvironment() with the
# function in <body file> (from its "private fun" line to its closing "    }").
set_alt_env_body() {
  awk -v bf="$1" '/private fun getSonarCloudAlternativeEnvironment\(\)/ {
         while ((getline l < bf) > 0) print l
         skip = 1; next }
       skip && /^    }/ { skip = 0; next }
       skip { next }
       { print }' "$CASE/$BS" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$BS"
}
# P5: each way of returning null instead of the DTO must fail.
cat > "$WORK/body-let.kt" <<'EOF'
    private fun getSonarCloudAlternativeEnvironment(): SonarCloudAlternativeEnvironmentDto? {
        val sonarCloudUrl = System.getProperty("sonarlint.internal.sonarcloud.url") ?: "https://app.codescan.io"
        val ws = System.getProperty("sonarlint.internal.sonarcloud.websocket.url")
        return ws?.let { SonarCloudAlternativeEnvironmentDto(URI.create(sonarCloudUrl), URI.create(it)) }
    }
EOF
cat > "$WORK/body-env.kt" <<'EOF'
    private fun getSonarCloudAlternativeEnvironment(): SonarCloudAlternativeEnvironmentDto? {
        val ws = System.getenv("CODESCAN_WS") ?: return null
        return SonarCloudAlternativeEnvironmentDto(URI.create("https://app.codescan.io"), URI.create(ws))
    }
EOF
cat > "$WORK/body-takeif.kt" <<'EOF'
    private fun getSonarCloudAlternativeEnvironment(): SonarCloudAlternativeEnvironmentDto? {
        val sonarCloudUrl = System.getProperty("sonarlint.internal.sonarcloud.url") ?: "https://app.codescan.io"
        val sonarCloudWebSocketUrl = System.getProperty("sonarlint.internal.sonarcloud.websocket.url")
        return SonarCloudAlternativeEnvironmentDto(URI.create(sonarCloudUrl), URI.create(sonarCloudWebSocketUrl ?: "")).takeIf { sonarCloudWebSocketUrl != null }
    }
EOF
cat > "$WORK/body-ifexpr.kt" <<'EOF'
    private fun getSonarCloudAlternativeEnvironment(): SonarCloudAlternativeEnvironmentDto? {
        val sonarCloudUrl = System.getProperty("sonarlint.internal.sonarcloud.url") ?: "https://app.codescan.io"
        val sonarCloudWebSocketUrl = System.getProperty("sonarlint.internal.sonarcloud.websocket.url")
        return if (sonarCloudWebSocketUrl == null) {
            null
        } else SonarCloudAlternativeEnvironmentDto(URI.create(sonarCloudUrl), URI.create(sonarCloudWebSocketUrl))
    }
EOF
# the same null branches, but with a non-null return type (each pattern must fail on its own)
sed 's/SonarCloudAlternativeEnvironmentDto? {/SonarCloudAlternativeEnvironmentDto {/' "$WORK/body-let.kt" > "$WORK/body-let-nn.kt"
sed 's/SonarCloudAlternativeEnvironmentDto? {/SonarCloudAlternativeEnvironmentDto {/' "$WORK/body-ifexpr.kt" > "$WORK/body-ifexpr-nn.kt"
# a nullable return type alone is enough to fail
cat > "$WORK/body-nullable-type.kt" <<'EOF'
    private fun getSonarCloudAlternativeEnvironment(): SonarCloudAlternativeEnvironmentDto? {
        val sonarCloudWebSocketUrl = System.getProperty("sonarlint.internal.sonarcloud.websocket.url") ?: "wss://app.codescan.io/ws"
        return SonarCloudAlternativeEnvironmentDto(URI.create("https://app.codescan.io"), URI.create(sonarCloudWebSocketUrl))
    }
EOF
# the intended fix may still compare with null; that is not a null branch
cat > "$WORK/body-fixed-compare.kt" <<'EOF'
    private fun getSonarCloudAlternativeEnvironment(): SonarCloudAlternativeEnvironmentDto {
        val ws = System.getProperty("sonarlint.internal.sonarcloud.websocket.url")
        val wsUri = if (ws != null) URI.create(ws) else URI.create("wss://app.codescan.io/ws")
        return SonarCloudAlternativeEnvironmentDto(URI.create(System.getProperty("sonarlint.internal.sonarcloud.url", "https://app.codescan.io")), wsUri)
    }
EOF
for b in let env takeif ifexpr let-nn ifexpr-nn nullable-type; do
  new_case "p5-body-$b" up
  set_alt_env_body "$WORK/body-$b.kt"
  expect_row_line "p5-body-$b" FAIL P5 ".*getSonarCloudAlternativeEnvironment\(\) can return null"
done
new_case p5-body-fixed-compare up
set_alt_env_body "$WORK/body-fixed-compare.kt"
expect_row_line p5-body-fixed-compare PASS P5

# Built on fix_backend, which passes P5 (p5-backend-fixed), so only the one defect can make P5 fail.
new_case url-unused-const up
fix_backend
case_sed $BS 's|?: "https://app.codescan.io"|?: "https://sonarcloud.io"|'
printf 'package org.sonarlint.intellij;\nclass Unused { static final String URL = "https://app.codescan.io"; }\n' > "$CASE/src/main/java/org/sonarlint/intellij/Unused.java"
expect_row_line url-unused-const FAIL P5 ".*does not use https://app.codescan.io as the address"
# A default in getProperty alone is not the Redo: with upstream's null branch left in, P5 must name the null branch.
new_case url-redo-form up
case_sed $BS 's|getProperty("sonarlint.internal.sonarcloud.url")|getProperty("sonarlint.internal.sonarcloud.url", "https://app.codescan.io")|'
expect_row_line url-redo-form FAIL P5 ".*can return null"
new_case url-redo-form-ok up
fix_backend
case_sed $BS 's|getProperty("sonarlint.internal.sonarcloud.url") ?: "https://app.codescan.io"|getProperty("sonarlint.internal.sonarcloud.url", "https://app.codescan.io")|'
expect_row_line url-redo-form-ok PASS P5

# P8: any arguments, an always-true guard, and a switch in another class.
new_case p8a
awk '{ print } /addLogTab\(project, toolWindow\);/ { print "    addTaintVulnerabilitiesTab(toolWindow.getProject(), contentManager);" }' "$CASE/$TOOLWIN" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$TOOLWIN"
expect_rows p8a P8
new_case p8b
case_sed $TOOLWIN 's/if (SonarLintUtils.isTaintVulnerabilitiesEnabled()) {/if (SonarLintUtils.isTaintVulnerabilitiesEnabled() || true) {/'
expect_rows p8b P8
new_case p8-not-false
case_sed $TOOLWIN 's/if (SonarLintUtils.isTaintVulnerabilitiesEnabled()) {/if (SonarLintUtils.isTaintVulnerabilitiesEnabled() == false) {/'
expect_rows p8-not-false P8
new_case p8c
case_sed $TOOLWIN 's/if (SonarLintUtils.isTaintVulnerabilitiesEnabled()) {/if (TaintSwitch.isTaintVulnerabilitiesEnabled()) {/'
expect_rows p8c P8
# p8c with a TaintSwitch class: it must return false too
taint_switch() {   # taint_switch <return value>
  { head -19 "$CASE/$TOOLWIN"; printf 'package org.sonarlint.intellij.ui;\nclass TaintSwitch {\n  static boolean isTaintVulnerabilitiesEnabled() {\n    return %s;\n  }\n}\n' "$1"; } > "$CASE/src/main/java/org/sonarlint/intellij/ui/TaintSwitch.java"
  case_sed $TOOLWIN 's/if (SonarLintUtils.isTaintVulnerabilitiesEnabled()) {/if (TaintSwitch.isTaintVulnerabilitiesEnabled()) {/'
}
new_case p8c-true
taint_switch true
expect_rows p8c-true P8
new_case p8c-false
taint_switch false
expect_rows p8c-false -
# an extra condition joined with && keeps the tab off
new_case p8-and-guard
case_sed $TOOLWIN 's/if (SonarLintUtils.isTaintVulnerabilitiesEnabled()) {/if (SonarLintUtils.isTaintVulnerabilitiesEnabled() \&\& project != null) {/'
expect_rows p8-and-guard -
# 10.x backend feature flags: upstream turns taint and server-sent events on; CodeScan must turn both off.
taint_off_up() { case_sed common/src/main/java/org/sonarlint/intellij/common/util/SonarLintUtils.java '/isTaintVulnerabilitiesEnabled()/,/}/s/return !isCLion() && !isGoIde();/return false;/'; }
new_case p8-flags-upstream up
taint_off_up
expect_row_line p8-flags-upstream FAIL P8 ".*taintVulnerabilitiesEnabled"
new_case p8-flags-sse up
taint_off_up
case_sed $BS 's/taintVulnerabilitiesEnabled = true,/taintVulnerabilitiesEnabled = false,/'
expect_row_line p8-flags-sse FAIL P8 ".*shouldManageServerSentEvents"
new_case p8-flags-fixed up
taint_off_up
case_sed $BS 's/taintVulnerabilitiesEnabled = true,/taintVulnerabilitiesEnabled = false,/; s/shouldManageServerSentEvents = true,/shouldManageServerSentEvents = false,/'
expect_row_line p8-flags-fixed PASS P8

# P4: branded image paths in any icon="..." value and in any source file, not only SonarLintIcons.
new_case p4a
case_sed $META/plugin.xml 's|icon="org.sonarlint.intellij.SonarLintIcons.SONARLINT_ACTION"|icon="/images/sonarqube_for_intellij_13px.svg"|g'
# the image itself carries the CodeScan header here, so only P4 reacts (the reviewer's copy of upstream's image also fails P9)
cp "$CASE/src/main/resources/images/CodeScanAction.svg" "$CASE/src/main/resources/images/sonarqube_for_intellij_13px.svg"
expect_rows p4a P4
traffic_icons() {   # traffic_icons <dir under the tree>
  mkdir -p "$CASE/$1"
  { head -19 "$PRE/$PIC"; printf 'package org.sonarlint.intellij\nimport com.intellij.openapi.util.IconLoader\nobject TrafficIcons { val RED = IconLoader.getIcon("/images/sonarqube_for_intellij_red_13px.svg", TrafficIcons::class.java) }\n'; } > "$CASE/$1/TrafficIcons.kt"
}
new_case p4b
traffic_icons src/main/java/org/sonarlint/intellij
expect_rows p4b P4
new_case p4b-common
traffic_icons common/src/main/java/org/sonarlint/intellij/common
expect_rows p4b-common P4
# a branded path inside a comment is not a use
new_case p4-comment-ok
printf '// was "/images/sonarqube_for_intellij_red_13px.svg"\n' >> "$CASE/$PIC"
expect_rows p4-comment-ok -
if command -v zip > /dev/null 2>&1; then
  zip_case zip-p4a P4 zsed 's|icon="org.sonarlint.intellij.SonarLintIcons.SONARLINT_ACTION"|icon="/images/sonarqube_for_intellij_13px.svg"|g' META-INF/plugin.xml
  zclass() { mkdir -p "$2/org/sonarlint/intellij"; printf 'xx/images/sonarqube_for_intellij_red_13px.svg\001yy' > "$2/org/sonarlint/intellij/$1"; }
  zip_case zip-p4b P4 zclass TrafficIcons.class
fi

# P32: the name must be a string literal (decision: no constant is followed, not even a correct one).
new_case p32a
case_sed common/src/main/java/org/sonarlint/intellij/common/LanguageActivator.java 's|ExtensionPointName.create("com.code-scan.intellij.languageActivator")|ExtensionPointName.create(EP_ID)|'
awk '{ print } /^public interface LanguageActivator/ { print "  String EP_ID = \"org.sonarlint.idea.languageActivator\";" }' "$CASE/common/src/main/java/org/sonarlint/intellij/common/LanguageActivator.java" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/common/src/main/java/org/sonarlint/intellij/common/LanguageActivator.java"
expect_row_line p32a FAIL P32 ".*not a string literal"
new_case p32-const-good
case_sed common/src/main/java/org/sonarlint/intellij/common/LanguageActivator.java 's|ExtensionPointName.create("com.code-scan.intellij.languageActivator")|ExtensionPointName.create(EP_ID)|'
expect_row_line p32-const-good FAIL P32 ".*not a string literal"

# P9: a source folder named build is still checked; only <tree>/build and <tree>/<module>/build are skipped.
new_case p9a
mkdir -p "$CASE/src/main/java/org/sonarlint/intellij/build"
printf 'package org.sonarlint.intellij.build;\nclass NoHeader {}\n' > "$CASE/src/main/java/org/sonarlint/intellij/build/NoHeader.java"
expect_rows p9a P9
new_case p9-module-build
mkdir -p "$CASE/common/build/generated/src/main/java"
printf 'package x;\nclass Gen {}\n' > "$CASE/common/build/generated/src/main/java/Gen.java"
expect_rows p9-module-build -
run_check slash-no "$PRE"
run_check slash-yes "$PRE/"
expect_rc slash-yes 0
if cmp -s "$WORK/slash-no.out" "$WORK/slash-yes.out"; then ok "slash-yes: same output as without the slash"; else not_ok "slash-yes: output differs from the run without the slash"; show_output -1 slash-yes; fi
new_case p9a-slash
mkdir -p "$CASE/src/main/java/org/sonarlint/intellij/build"
printf 'package org.sonarlint.intellij.build;\nclass NoHeader {}\n' > "$CASE/src/main/java/org/sonarlint/intellij/build/NoHeader.java"
run_check p9a-slash "$CASE/"
expect_line p9a-slash "^FAIL P9 .*src/main/java/org/sonarlint/intellij/build/NoHeader.java"
rm -rf "$CASE"
# P9 also checks .svg and .form files (the build's license check maps them), and skips **/proto/*.java as the build does.
new_case p9-svg
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' > "$CASE/src/main/resources/images/NoHeader.svg"
expect_rows p9-svg P9
new_case p9-form
form=$(cd "$CASE" && find src/main/java -name '*.form' | head -1)
sed '/^<!--$/,/^-->$/d' "$CASE/$form" > "$CASE/x.new" && mv "$CASE/x.new" "$CASE/$form"
expect_rows p9-form P9

# plugin-git.xml is no longer skipped (row P33 is fixed), so there is no WARN line, and the zip copy is checked too.
run_check p32-git-nowarn "$PRE"
expect_no_line p32-git-nowarn "^WARN "
if command -v zip > /dev/null 2>&1; then
  zip_case zip-git-ns P32 zsed 's:defaultExtensionNs="com.code-scan.intellij":defaultExtensionNs="org.sonarlint.idea":' META-INF/plugin-git.xml
  expect_line zip-git-ns "^FAIL P32 zip: .*plugin-git.xml registers extensions under the SonarLint namespace"
  # Zip entry names with [ ] * ? are read as plain names, not patterns.
  JARNAME='codescan-intellij-[7].jar' zip_case zip-bracket-name - true
  # unescaped, this name is a pattern that also matches the decoy jar next to it
  JARNAME='codescan*intellij?.jar' EXTRAJAR='codescan-intellij-.jar' zip_case zip-star-name - true
fi

run_check pre-again "$PRE"
expect_rc pre-again 0

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
