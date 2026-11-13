#!/usr/bin/env bash
#
# Checks that the CodeScan changes listed in docs/codescan-customizations.md
# (top-level folder, next to this repo) are still in place.
# Each line of output starts with PASS or FAIL and the row ID from that doc.
#
# Usage: scripts/qa/check-customizations.sh [--zip <plugin zip>] [<source dir>]
#   <source dir>  root of a sonarlint-intellij-master checkout (default: this repo)
#   --zip         also check the built plugin zip (build/distributions/*.zip)
#
# Exit code: 0 = every check passed, 1 = at least one check failed, 2 = bad input.
# Works on macOS bash 3.2 and Linux. Needs unzip only for --zip.
#
set -u

usage() { echo "Usage: $0 [--zip <plugin zip>] [<source dir>]" >&2; exit 2; }

ZIP=""
SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --zip) [ $# -ge 2 ] || usage; ZIP=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) [ -z "$SRC" ] || usage; SRC=$1; shift ;;
  esac
done
if [ -z "$SRC" ]; then
  SRC=$(cd "$(dirname "$0")/../.." && pwd)
fi

PLUGIN_XML="$SRC/src/main/resources/META-INF/plugin.xml"
UTILS="$SRC/common/src/main/java/org/sonarlint/intellij/common/util/SonarLintUtils.java"
ICONS="images/CodeScan.png images/CodeScanAction.svg images/CodeScanToolWindow.svg images/codescan-16.png images/codescan-round.png images/codescan@2x.png META-INF/pluginIcon.svg"

if [ ! -d "$SRC" ]; then echo "ERROR: source dir not found: $SRC" >&2; exit 2; fi
if [ ! -f "$PLUGIN_XML" ]; then echo "ERROR: not a plugin source tree, no $PLUGIN_XML" >&2; exit 2; fi
if [ -n "$ZIP" ] && [ ! -f "$ZIP" ]; then echo "ERROR: zip not found: $ZIP" >&2; exit 2; fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-cust.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED_ROWS=""
pass() { PASSED=$((PASSED + 1)); echo "PASS $1 $2"; }
fail() {
  echo "FAIL $1 $2"
  case " $FAILED_ROWS " in *" $1 "*) ;; *) FAILED_ROWS="${FAILED_ROWS:+$FAILED_ROWS }$1" ;; esac
}

xml_value() {   # first text value of <tag>...</tag> in plugin.xml
  sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" "$PLUGIN_XML" | head -1
}

check_p1() {
  id=$(xml_value id)
  name=$(xml_value name)
  if [ "$id" = "com.code-scan.intellij" ] && [ "$name" = "CodeScan" ]; then
    pass P1 "plugin.xml id is com.code-scan.intellij and name is CodeScan"
  else
    fail P1 "plugin.xml id/name: expected com.code-scan.intellij/CodeScan, found '$id'/'$name'"
  fi
}

element_text() {
  awk -v t="$1" '
    !on { i = match($0, "<" t "([[:space:]>/]|$)"); if (!i) next; on = 1; $0 = substr($0, i) }
    { out = out " " $0 }
    index($0, "</" t ">") || $0 ~ /\/>/ { print out; exit }' "$PLUGIN_XML" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //'
}

check_p2() {
  name_line=$(element_text name)
  vendor_line=$(element_text vendor)
  if [ -z "$name_line" ] || [ -z "$vendor_line" ]; then
    fail P2 "plugin.xml has no <name> or no <vendor> element"
  elif printf '%s\n%s\n' "$name_line" "$vendor_line" | grep -qi 'sonar'; then
    fail P2 "plugin.xml <name>/<vendor> mention Sonar: $(printf '%s | %s' "$name_line" "$vendor_line" | sed 's/^[[:space:]]*//')"
  else
    pass P2 "plugin.xml <name> and <vendor> do not mention Sonar"
  fi
}

check_p4_source() {
  missing=""
  for f in $ICONS; do
    [ -s "$SRC/src/main/resources/$f" ] || missing="$missing $f"
  done
  if [ -z "$missing" ]; then
    pass P4 "CodeScan icon files are in the source tree"
  else
    fail P4 "CodeScan icon files missing from src/main/resources:$missing"
  fi
}

check_p4_zip() {
  if ! command -v unzip > /dev/null 2>&1; then
    fail P4 "zip: unzip command not found, cannot check $ZIP"
    return
  fi
  if ! unzip -Z1 "$ZIP" > "$TMP/zip.lst" 2> "$TMP/zip.err"; then
    fail P4 "zip: cannot read $ZIP: $(head -1 "$TMP/zip.err")"
    return
  fi
  : > "$TMP/entries.lst"
  jars=0
  while IFS= read -r entry; do
    case "$entry" in
      */lib/*.jar|lib/*.jar)
        jars=$((jars + 1))
        # Stream the one entry to a fixed file name: nothing from the zip decides where files are written.
        if unzip -p "$ZIP" "$entry" > "$TMP/inner.jar" 2> /dev/null; then
          unzip -Z1 "$TMP/inner.jar" >> "$TMP/entries.lst" 2> /dev/null
        fi
        ;;
    esac
  done < "$TMP/zip.lst"
  if [ "$jars" -eq 0 ]; then
    fail P4 "zip: no lib/*.jar inside $ZIP, is it a plugin zip?"
    return
  fi
  missing=""
  for f in $ICONS; do
    grep -qxF "$f" "$TMP/entries.lst" || missing="$missing $f"
  done
  if [ -z "$missing" ]; then
    pass P4 "CodeScan icon files are inside the plugin zip"
  else
    fail P4 "zip: CodeScan icon files missing from the jars in $ZIP:$missing"
  fi
}

check_p5() {
  # A string in the code is not enough: the address must reach a place that uses it as the default.
  # Accepted: setServerUrl/setHostUrl (7.2.3 wizard) or the backend DTO (after the Redo); names holding the URL count too.
  set --
  for d in "$SRC/src/main" "$SRC/common/src/main"; do [ -d "$d" ] && set -- "$@" "$d"; done
  if [ $# -eq 0 ]; then fail P5 "no src/main or common/src/main folder"; return; fi
  grep -rhE --include='*.java' --include='*.kt' \
    'app\.codescan\.io|sonarlint\.internal\.sonarcloud\.url|setServerUrl\(|setHostUrl\(|SonarCloudAlternativeEnvironmentDto\(|alternativeSonarCloudEnv' \
    "$@" > "$TMP/p5.lines" 2> /dev/null
  awk '
    function lhs_name(s,   i) {
      i = index(s, "="); if (!i) return ""
      s = substr(s, 1, i - 1); sub(/:.*/, "", s)
      if (!match(s, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/)) return ""
      s = substr(s, RSTART, RLENGTH); gsub(/[[:space:]]/, "", s); return s
    }
    function holds(s,   n) {
      if (s ~ /"https:\/\/app\.codescan\.io\/?"/) return 1
      for (n in H) if (s ~ ("(^|[^A-Za-z0-9_])" n "([^A-Za-z0-9_]|$)")) return 1
      return 0
    }
    { L[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++)
        if (L[i] ~ /=[[:space:]]*"https:\/\/app\.codescan\.io\/?"/) { n = lhs_name(L[i]); if (n != "") H[n] = 1 }
      for (i = 1; i <= NR; i++)
        if (L[i] ~ /getProperty\("sonarlint\.internal\.sonarcloud\.url",/) {
          a = L[i]; sub(/.*getProperty\("sonarlint\.internal\.sonarcloud\.url",/, "", a)
          if (holds(a)) { n = lhs_name(L[i]); if (n != "") H[n] = 1 }
        }
      for (n in H) print "NAME " n
      for (i = 1; i <= NR; i++)
        if (L[i] ~ /setServerUrl\(|setHostUrl\(|SonarCloudAlternativeEnvironmentDto\(|alternativeSonarCloudEnv/ && holds(L[i])) {
          s = L[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); print "USE " s
        }
    }' "$TMP/p5.lines" > "$TMP/p5.out"
  use=$(sed -n 's/^USE //p' "$TMP/p5.out" | head -1)
  names=$(sed -n 's/^NAME //p' "$TMP/p5.out" | sort | tr '\n' ' ')
  if [ -n "$use" ]; then
    pass P5 "https://app.codescan.io is used as the default cloud address: $use"
  elif [ -n "$names" ]; then
    fail P5 "https://app.codescan.io is held by ${names}but never used as the default (setServerUrl/setHostUrl/SonarCloudAlternativeEnvironmentDto)"
  else
    fail P5 "https://app.codescan.io is not used as the default cloud address in src/main or common/src/main"
  fi
}

check_p8() {
  # Every call that adds the tab must sit inside an if (...isTaintVulnerabilitiesEnabled()) block, and that switch must return false.
  # No call found means the code moved; FAIL so a person updates this check, instead of guessing PASS.
  callers=$(grep -rlE --include='*.java' --include='*.kt' 'addTaintVulnerabilitiesTab\(project' "$SRC/src/main" 2> /dev/null)
  if [ -z "$callers" ]; then
    fail P8 "cannot find the code that adds the taint tab (addTaintVulnerabilitiesTab(project...) in src/main); check by hand and update this script"
    return
  fi
  unguarded=""
  while IFS= read -r f; do
    # Braces in strings or comments are not special-cased; a wrong count can only produce a FAIL, never a false PASS.
    lines=$(awk '
      {
        line = $0
        g = index(line, "isTaintVulnerabilitiesEnabled()")
        c = index(line, "addTaintVulnerabilitiesTab(project")
        is_guard = g && line ~ /if[[:space:]]*\(/ && line !~ /![[:space:]]*([A-Za-z_][A-Za-z0-9_]*\.)?isTaintVulnerabilitiesEnabled\(\)/
        if (c && line !~ /(void|fun)[[:space:]]+addTaintVulnerabilitiesTab/ && !(top > 0 || next_guarded || (is_guard && g < c)))
          print FNR
        if (next_guarded && line ~ /^[[:space:]]*\{/) stack[++top] = depth
        if (line ~ /[^[:space:]]/) next_guarded = 0
        pushed = 0
        for (k = 1; k <= length(line); k++) {
          ch = substr(line, k, 1)
          if (ch == "{") { if (is_guard && k > g && !pushed) { stack[++top] = depth; pushed = 1 } depth++ }
          else if (ch == "}") { depth--; while (top > 0 && depth <= stack[top]) top-- }
        }
        if (is_guard && !pushed && line !~ /;[[:space:]]*$/) next_guarded = 1
      }' "$f")
    [ -n "$lines" ] && unguarded="$unguarded ${f#"$SRC"/}:$(echo $lines | tr ' ' ',')"
  done <<EOF2
$callers
EOF2
  if [ -n "$unguarded" ]; then
    fail P8 "taint tab is added outside the isTaintVulnerabilitiesEnabled() switch at:$unguarded"
    return
  fi
  if [ ! -f "$UTILS" ]; then
    fail P8 "cannot find ${UTILS#"$SRC"/} to read isTaintVulnerabilitiesEnabled()"
    return
  fi
  body=$(awk '/boolean isTaintVulnerabilitiesEnabled\(\)/ { f = 1; next }
              f && /^[[:space:]]*}/ { exit }
              f { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }' "$UTILS")
  if [ "$body" = "return false;" ]; then
    pass P8 "taint tab is not registered (isTaintVulnerabilitiesEnabled() returns false)"
  else
    fail P8 "taint tab is registered: isTaintVulnerabilitiesEnabled() body is '$(echo $body)'"
  fi
}

check_p9() {
  header="$SRC/HEADER"
  if [ ! -f "$header" ]; then fail P9 "HEADER file not found"; return; fi
  first=$(head -1 "$header" | tr -d '\r')
  if [ "$first" != "CodeScan for IntelliJ IDEA" ]; then
    fail P9 "HEADER first line is '$first', expected 'CodeScan for IntelliJ IDEA'"
    return
  fi
  # The license plugin (SLASHSTAR_STYLE) writes HEADER as a /* ... */ block at the top of each file.
  awk 'BEGIN { print "/*" } { sub(/\r$/, ""); if ($0 == "") print " *"; else print " * " $0 } END { print " */" }' "$header" > "$TMP/expected"
  # Same scope as the license check in build.gradle.kts: java/kt files in the source folders of the root module and
  # each sub-module, minus generated protobuf code. Test data and its/projects/ sample projects are not source folders.
  find "$SRC" \( -name build -o -name .gradle -o -name .git -o -name .worktrees -o -name node_modules \) -prune -o \
    -type f \( -name '*.java' -o -name '*.kt' \) ! -path '*/proto/*.java' -print |
    awk -v p="$SRC/" 'index($0, p) == 1 && substr($0, length(p) + 1) ~ /^([^\/]+\/)?src\/(main|test)\/(java|kotlin)\//' > "$TMP/files"
  total=$(awk 'END { print NR }' "$TMP/files")
  if [ "$total" -eq 0 ]; then fail P9 "no .java/.kt files found under $SRC"; return; fi
  # xargs exits non-zero if awk fails on any batch; a crash must never read as "no bad files".
  if ! tr '\n' '\0' < "$TMP/files" | xargs -0 awk -v expfile="$TMP/expected" '
    BEGIN { n = 0; while ((getline line < expfile) > 0) want[++n] = line; if (n < 3) exit 3 }
    function finish() { if (cur != "" && !bad && matched < n) print cur }
    FNR == 1 { finish(); cur = FILENAME; bad = 0; matched = 0 }
    bad { next }
    FNR <= n { sub(/\r$/, ""); if ($0 == want[FNR]) matched++; else { bad = 1; print FILENAME } }
    END { finish() }' > "$TMP/bad" 2> "$TMP/awk.err"; then
    fail P9 "could not compare headers: $(head -1 "$TMP/awk.err")"
    return
  fi
  nbad=$(awk 'END { print NR }' "$TMP/bad")
  if [ "$nbad" -eq 0 ]; then
    pass P9 "license header matches HEADER in all $total .java/.kt files"
  else
    list=$(head -5 "$TMP/bad" | awk -v p="$SRC/" 'index($0, p) == 1 { $0 = substr($0, length(p) + 1) } { print }' | tr '\n' ' ')
    fail P9 "license header differs from HEADER in $nbad of $total files, e.g. $list"
  fi
}

check_p32() {
  # The IDE looks extensions up by full name. A name that does not start with the plugin id finds nothing, with no error.
  prefix="com.code-scan.intellij."
  common="$SRC/common/src/main"
  if [ ! -d "$common" ]; then fail P32 "no common/src/main folder"; return; fi
  grep -rhoE --include='*.java' --include='*.kt' 'ExtensionPointName(\.create)?(<[^>]*>)?\([[:space:]]*"[^"]*"' "$common" 2> /dev/null |
    sed 's/.*"\([^"]*\)"$/\1/' > "$TMP/ep.names"
  for x in "$SRC"/src/main/resources/META-INF/plugin*.xml; do
    [ -f "$x" ] && grep -oE 'qualifiedName="[^"]*"' "$x" | sed 's/.*="\([^"]*\)"$/\1/' >> "$TMP/ep.names"
  done
  total=$(awk 'END { print NR }' "$TMP/ep.names")
  if [ "$total" -eq 0 ]; then
    fail P32 "no ExtensionPointName.create(\"...\") found in common/src/main; check by hand and update this script"
    return
  fi
  bad=$(awk -v p="$prefix" 'index($0, p) != 1' "$TMP/ep.names" | tr '\n' ' ')
  if [ -z "$bad" ]; then
    pass P32 "all $total extension point names start with $prefix"
  else
    fail P32 "extension point names that do not start with $prefix (extensions would not be found): $bad"
  fi
}

check_p1
check_p2
check_p4_source
[ -n "$ZIP" ] && check_p4_zip
check_p5
check_p8
check_p9
check_p32

echo
if [ -z "$FAILED_ROWS" ]; then
  echo "Result: $PASSED checks passed, 0 failed"
  exit 0
fi
echo "Failed rows: $FAILED_ROWS"
exit 1
