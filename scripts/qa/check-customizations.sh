#!/usr/bin/env bash
#
# Checks that the CodeScan changes listed in docs/codescan-customizations.md
# (top-level folder, next to this repo) are still in place.
# Each line of output starts with PASS or FAIL and the row ID from that doc.
#
# Usage: scripts/qa/check-customizations.sh [--zip <plugin zip> | --no-zip] [<source dir>]
#   <source dir>  root of a sonarlint-intellij-master checkout (default: this repo)
#   --zip         also check the built plugin zip: the plugin.xml, the plugin icon and the icon code inside its
#                 main jar are read as well, and its version must be the one the source tree builds
#   --no-zip      on purpose, check the source tree only (prints a SKIP line, exit code stays 0)
#   Without --zip and --no-zip the newest build/distributions/*.zip of the source dir is checked. If there is
#   none, the zip checks are skipped, the SKIP line is printed and the exit code is 3, never 0: a run that
#   did not look at the zip must not read as a full pass.
#
# Exit code: 0 = every check passed, 1 = at least one check failed, 2 = bad input,
#            3 = the source passed but the zip checks were skipped because there was no zip (see above).
# Works on macOS bash 3.2 and Linux. Needs unzip only for the zip checks.
#
set -u

usage() { echo "Usage: $0 [--zip <plugin zip> | --no-zip] [<source dir>]" >&2; exit 2; }

ZIP=""
NOZIP=0
SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --zip) [ $# -ge 2 ] || usage; ZIP=$2; shift 2 ;;
    --no-zip) NOZIP=1; shift ;;
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
# SonarLintIcons.kt must name these CodeScan images. A file that is only present proves nothing: upstream's
# SonarLintIcons.kt would leave them unused and the IDE would show the SonarLint icons.
ICON_REFS="/images/CodeScan.png /images/CodeScanAction.svg /images/CodeScanToolWindow.svg /images/codescan-16.png /images/codescan-round.png /images/codescan@2x.png"
# META-INF/pluginIcon.svg (and pluginIcon_dark.svg if there is one) must be the CodeScan logo. I look for its blue,
# a distinctive string that only the CodeScan icon at pre-catchup-7.2.3 has (SonarLint's icons use #126ED3), rather than
# a checksum: a license-header refresh or a whitespace edit changes a checksum but not the logo. If the logo is
# redesigned on purpose, change the colour here.
ICON_MARK="#3868f5"

if [ ! -d "$SRC" ]; then echo "ERROR: source dir not found: $SRC" >&2; exit 2; fi
if [ ! -f "$PLUGIN_XML" ]; then echo "ERROR: not a plugin source tree, no $PLUGIN_XML" >&2; exit 2; fi
if [ -n "$ZIP" ] && [ "$NOZIP" -eq 1 ]; then echo "ERROR: --zip and --no-zip cannot be used together" >&2; exit 2; fi
if [ -n "$ZIP" ] && [ ! -f "$ZIP" ]; then echo "ERROR: zip not found: $ZIP" >&2; exit 2; fi
# No zip named: take the newest build/distributions/*.zip (the build leaves one zip per version there).
ZIP_NOTE=""
SKIP_ZIP=""
if [ -z "$ZIP" ] && [ "$NOZIP" -eq 0 ]; then
  found=$(ls -t "$SRC"/build/distributions/*.zip 2> /dev/null | head -1)
  if [ -n "$found" ] && [ -f "$found" ]; then
    ZIP=$found
    ZIP_NOTE="NOTE zip checks use the newest zip in build/distributions: $ZIP"
  else
    SKIP_ZIP="SKIP zip checks (no --zip and no build/distributions zip)"
  fi
elif [ "$NOZIP" -eq 1 ]; then
  SKIP_ZIP="SKIP zip checks (--no-zip)"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-cust.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED_ROWS=""
pass() { PASSED=$((PASSED + 1)); echo "PASS $1 $2"; }
fail() {
  echo "FAIL $1 $2"
  case " $FAILED_ROWS " in *" $1 "*) ;; *) FAILED_ROWS="${FAILED_ROWS:+$FAILED_ROWS }$1" ;; esac
}

# Comment strippers: one output line per input line, so line numbers stay valid.
STRIP_AWK="$TMP/strip-code.awk"
cat > "$STRIP_AWK" <<'EOF'
# Java/Kotlin: drops // and /* */ comments. A "//" inside "...", '...' or """...""" is text and stays
# (so "https://app.codescan.io" survives). Kotlin's nested /* */ comments are not handled.
BEGIN { dq = "\""; sq = sprintf("%c", 39); q3 = dq dq dq }
mark && FNR == 1 { print "@@FILE " FILENAME }
FNR == 1 { inblk = 0; inraw = 0 }
{
  line = $0
  if (!inblk && !inraw && index(line, "/") == 0 && index(line, dq) == 0 && index(line, sq) == 0) { print line; next }
  n = length(line); out = ""; i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (inblk) {
      if (c == "*" && substr(line, i + 1, 1) == "/") { inblk = 0; i += 2 } else i++
      continue
    }
    if (inraw) {
      if (substr(line, i, 3) == q3) { inraw = 0; out = out q3; i += 3 } else { out = out c; i++ }
      continue
    }
    if (substr(line, i, 3) == q3) { inraw = 1; out = out q3; i += 3; continue }
    if (c == dq || c == sq) {
      out = out c; i++
      while (i <= n) {
        d = substr(line, i, 1); out = out d; i++
        if (d == "\\") { out = out substr(line, i, 1); i++ }
        else if (d == c) break
      }
      continue
    }
    if (c == "/") {
      d = substr(line, i + 1, 1)
      if (d == "/") break
      if (d == "*") { inblk = 1; i += 2; out = out " "; continue }
    }
    out = out c; i++
  }
  print out
}
EOF
XMLSTRIP_AWK="$TMP/strip-xml.awk"
cat > "$XMLSTRIP_AWK" <<'EOF'
FNR == 1 { inc = 0 }
{
  line = $0; out = ""
  while (1) {
    if (inc) {
      i = index(line, "-->")
      if (!i) { line = ""; break }
      line = substr(line, i + 3); inc = 0
    }
    i = index(line, "<!--")
    if (!i) { out = out line; break }
    out = out substr(line, 1, i - 1); line = substr(line, i + 4); inc = 1
  }
  print out
}
EOF
strip_code() { awk -f "$STRIP_AWK" "$@"; }
strip_xml()  { awk -f "$XMLSTRIP_AWK" "$@"; }

# strip_tree <outfile> <dir>...: all .java/.kt files below the dirs, comments stripped, in one file.
# Each file starts with a line "@@FILE <path>", so a check can tell which file a line came from.
# Returns non-zero if a folder or file could not be read: a read error must never look like "no match".
strip_tree() {
  out=$1; shift
  find "$@" -type f \( -name '*.java' -o -name '*.kt' \) -print0 > "$TMP/strip.list" 2> "$TMP/strip.err" || return 1
  : > "$out"
  [ -s "$TMP/strip.list" ] || return 0
  xargs -0 awk -v mark=1 -f "$STRIP_AWK" < "$TMP/strip.list" > "$out" 2>> "$TMP/strip.err" || return 1
}

xml_value() {
  sed -n "s:.*<$2>\(.*\)</$2>.*:\1:p" "$1" | head -1
}

element_text() {
  awk -v t="$2" '
    !on { i = match($0, "<" t "([[:space:]>/]|$)"); if (!i) next; on = 1; $0 = substr($0, i) }
    { out = out " " $0 }
    index($0, "</" t ">") || $0 ~ /\/>/ { print out; exit }' "$1" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //'
}

ZIP_ERR=""
ZIP_DIR="$TMP/zip"
prepare_zip() {
  mkdir -p "$ZIP_DIR/META-INF"
  if ! command -v unzip > /dev/null 2>&1; then ZIP_ERR="unzip command not found, cannot check $ZIP"; return; fi
  if ! unzip -Z1 "$ZIP" > "$TMP/zip.lst" 2> "$TMP/zip.err"; then
    ZIP_ERR="cannot read $ZIP: $(head -1 "$TMP/zip.err")"
    return
  fi
  : > "$TMP/entries.lst"
  jars=0; main=0; main_cls=0
  while IFS= read -r entry; do
    case "$entry" in
      */lib/*.jar|lib/*.jar)
        jars=$((jars + 1))
        # Stream the one entry to a fixed file name: nothing from the zip decides where files are written.
        if unzip -p "$ZIP" "$entry" > "$TMP/inner.jar" 2> /dev/null && unzip -Z1 "$TMP/inner.jar" > "$TMP/inner.lst" 2> /dev/null; then
          cat "$TMP/inner.lst" >> "$TMP/entries.lst"
          has_pl=0; has_cls=0
          grep -qxF 'META-INF/plugin.xml' "$TMP/inner.lst" && has_pl=1
          grep -qxF 'org/sonarlint/intellij/SonarLintIcons.class' "$TMP/inner.lst" && has_cls=1
          # The main jar is the one with plugin.xml; if several have one, prefer the one with our icon code.
          if [ "$has_pl" -eq 1 ] && { [ "$main" -eq 0 ] || { [ "$has_cls" -eq 1 ] && [ "$main_cls" -eq 0 ]; }; }; then
            cp "$TMP/inner.jar" "$TMP/main.jar"; main=1; main_cls=$has_cls
          fi
        fi
        ;;
    esac
  done < "$TMP/zip.lst"
  if [ "$jars" -eq 0 ]; then ZIP_ERR="no lib/*.jar inside $ZIP, is it a plugin zip?"; return; fi
  if [ "$main" -eq 0 ]; then ZIP_ERR="no jar with META-INF/plugin.xml inside $ZIP, is it a plugin zip?"; return; fi
  unzip -p "$TMP/main.jar" META-INF/plugin.xml > "$ZIP_DIR/META-INF/plugin.xml" 2> /dev/null ||
    { ZIP_ERR="cannot read META-INF/plugin.xml from the main jar of $ZIP"; return; }
  # Only plain names are taken out, so nothing from the zip decides where a file is written.
  unzip -Z1 "$TMP/main.jar" 2> /dev/null | grep -E '^META-INF/(plugin-[A-Za-z0-9._-]+\.xml|pluginIcon[A-Za-z0-9._-]*\.svg)$' |
    while IFS= read -r e; do unzip -p "$TMP/main.jar" "$e" > "$ZIP_DIR/$e" 2> /dev/null; done
  : > "$ZIP_DIR/SonarLintIcons.class"
  unzip -p "$TMP/main.jar" org/sonarlint/intellij/SonarLintIcons.class > "$ZIP_DIR/SonarLintIcons.class" 2> /dev/null
  return 0
}
if [ -n "$ZIP" ]; then prepare_zip; fi

zip_xml_check() {
  [ -n "$ZIP" ] || return 0
  if [ -n "$ZIP_ERR" ]; then fail "$2" "zip: $ZIP_ERR"; return; fi
  strip_xml "$ZIP_DIR/META-INF/plugin.xml" > "$TMP/zip-plugin.xml"
  "$1" "$TMP/zip-plugin.xml" "zip: plugin.xml "
}

check_p1() {
  id=$(xml_value "$1" id)
  name=$(xml_value "$1" name)
  if [ "$id" = "com.code-scan.intellij" ] && [ "$name" = "CodeScan" ]; then
    pass P1 "${2:-plugin.xml }id is com.code-scan.intellij and name is CodeScan"
  else
    fail P1 "${2:-plugin.xml }id/name: expected com.code-scan.intellij/CodeScan, found '$id'/'$name'"
  fi
}

check_p2() {
  name_line=$(element_text "$1" name)
  vendor_line=$(element_text "$1" vendor)
  if [ -z "$name_line" ] || [ -z "$vendor_line" ]; then
    fail P2 "${2:-plugin.xml }has no <name> or no <vendor> element"
  elif printf '%s\n%s\n' "$name_line" "$vendor_line" | grep -qi 'sonar'; then
    fail P2 "${2:-plugin.xml }<name>/<vendor> mention Sonar: $(printf '%s | %s' "$name_line" "$vendor_line" | sed 's/^[[:space:]]*//')"
  else
    pass P2 "${2:-plugin.xml }<name> and <vendor> do not mention Sonar"
  fi
}

icon_ref_problems() {
  miss=""
  for p in $ICON_REFS; do LC_ALL=C grep -qaF -- "$p" "$1" || miss="$miss $p"; done
  [ -z "$miss" ] || echo "SonarLintIcons does not use:$miss"
}

icon_mark_problems() {
  [ -f "$1/pluginIcon.svg" ] || echo "META-INF/pluginIcon.svg is missing"
  for f in pluginIcon.svg pluginIcon_dark.svg; do
    if [ -f "$1/$f" ] && ! grep -qiF -- "$ICON_MARK" "$1/$f"; then
      echo "META-INF/$f is not the CodeScan logo (its colour $ICON_MARK is missing)"
    fi
  done
}

# Upstream SonarLint (10.14.1) brands its images with "sonarqube_..." (sonarqube_for_intellij*.svg, sonarqube_server*,
# sonarqube_cloud*) and older versions with "sonarlint". CodeScan must not show any of them, so no image path in the
# icon code may name SonarQube, SonarLint, SonarSource or SonarCloud. 7.2.3 itself has no such path (its fields keep
# upstream's names such as ICON_SONARQUBE_16, but they point at CodeScan images), so nothing is allowed here.
# Only file-name characters are taken, so in a compiled class file the match stops at the next entry.
SONAR_IMG_RE='/images/[A-Za-z0-9_./@-]*(sonarqube|sonarlint|sonarsource|sonarcloud)[A-Za-z0-9_./@-]*'
brand_problems() {   # brand_problems <stripped SonarLintIcons.kt or class file>
  bad=$(LC_ALL=C grep -aoiE "$SONAR_IMG_RE" "$1" | LC_ALL=C sort -u | tr '\n' ' ')
  [ -z "$bad" ] || echo "SonarLintIcons refers to SonarSource-branded images: ${bad% }"
}

# icon_field_problems <source|class> <icon code: stripped SonarLintIcons.kt, or the class file> <plugin xml file>...
# Every icon="...SonarLintIcons.FIELD" in the plugin xml files must name a field that shows a CodeScan image:
# FIELD must not be an upstream SONARQUBE_* name, must exist, and (source) must not map to a SonarSource-branded path.
icon_field_problems() {
  kind=$1; icode=$2; shift 2
  : > "$TMP/icon.fields"
  for x in "$@"; do
    [ -f "$x" ] || continue
    strip_xml "$x" | grep -oE 'icon="[^"]*SonarLintIcons\.[A-Za-z0-9_]+"' | sed 's/.*SonarLintIcons\.//; s/"$//' >> "$TMP/icon.fields"
  done
  sort -u "$TMP/icon.fields" > "$TMP/icon.fields.u"
  while IFS= read -r fld; do
    [ -n "$fld" ] || continue
    if printf '%s\n' "$fld" | grep -qi 'sonarqube'; then
      echo "plugin xml uses icon SonarLintIcons.$fld, an upstream SonarQube icon"
    elif [ "$kind" = class ]; then
      LC_ALL=C grep -qaF -- "$fld" "$icode" || echo "plugin xml uses icon SonarLintIcons.$fld, which is not in SonarLintIcons.class"
    else
      awk -v f="$fld" '
        { if (match($0, "(^|[^A-Za-z0-9_])val[[:space:]]+" f "[[:space:]]*[=:]")) { n = 3; found = 1 }
          else if ($0 ~ /(^|[^A-Za-z0-9_])va[lr][[:space:]]/) n = 0
          if (n > 0) { print; n-- } }
        END { exit found ? 0 : 1 }' "$icode" > "$TMP/icon.def"
      if [ $? -ne 0 ]; then
        echo "plugin xml uses icon SonarLintIcons.$fld, which SonarLintIcons.kt does not define"
      elif LC_ALL=C grep -qiE "$SONAR_IMG_RE" "$TMP/icon.def"; then
        echo "plugin xml uses icon SonarLintIcons.$fld, which maps to a SonarSource-branded image"
      elif ! grep -qE '/images/[^"]+' "$TMP/icon.def"; then
        echo "plugin xml uses icon SonarLintIcons.$fld, but its image path cannot be read; check by hand"
      fi
    fi
  done < "$TMP/icon.fields.u"
}

join_problems() { awk 'NR > 1 { printf "; " } { printf "%s", $0 } END { print "" }'; }

check_p4_source() {
  problems=""
  missing=""
  for f in $ICONS; do
    [ -s "$SRC/src/main/resources/$f" ] || missing="$missing $f"
  done
  [ -z "$missing" ] || problems="CodeScan icon files missing from src/main/resources:$missing"
  kt="$SRC/src/main/java/org/sonarlint/intellij/SonarLintIcons.kt"
  if [ -f "$kt" ]; then
    strip_code "$kt" > "$TMP/icons.txt"
    p=$(icon_ref_problems "$TMP/icons.txt")
    [ -z "$p" ] || problems="$problems${problems:+; }$p"
    p=$(brand_problems "$TMP/icons.txt")
    [ -z "$p" ] || problems="$problems${problems:+; }$p"
    p=$(icon_field_problems source "$TMP/icons.txt" "$SRC"/src/main/resources/META-INF/plugin*.xml | join_problems)
  else
    p="SonarLintIcons.kt not found"
  fi
  [ -z "$p" ] || problems="$problems${problems:+; }$p"
  p=$(icon_mark_problems "$SRC/src/main/resources/META-INF" | join_problems)
  p=${p%$'\n'}
  [ -z "$p" ] || problems="$problems${problems:+; }$p"
  if [ -z "$problems" ]; then
    pass P4 "CodeScan icon files are in the source tree, SonarLintIcons.kt uses them (and no SonarSource-branded image), plugin.xml icons point at CodeScan images and pluginIcon.svg is the CodeScan logo"
  else
    fail P4 "$problems"
  fi
}

check_p4_zip() {
  if [ -n "$ZIP_ERR" ]; then fail P4 "zip: $ZIP_ERR"; return; fi
  problems=""
  missing=""
  for f in $ICONS; do
    grep -qxF "$f" "$TMP/entries.lst" || missing="$missing $f"
  done
  [ -z "$missing" ] || problems="zip: CodeScan icon files missing from the jars in $ZIP:$missing"
  if [ -s "$ZIP_DIR/SonarLintIcons.class" ]; then
    p=$(icon_ref_problems "$ZIP_DIR/SonarLintIcons.class")
    [ -z "$p" ] || problems="$problems${problems:+; }zip: $p"
    p=$(brand_problems "$ZIP_DIR/SonarLintIcons.class")
    [ -z "$p" ] || problems="$problems${problems:+; }zip: $p"
    p=$(icon_field_problems class "$ZIP_DIR/SonarLintIcons.class" "$ZIP_DIR"/META-INF/plugin*.xml | join_problems)
  else
    p="SonarLintIcons.class not found in the main jar"
  fi
  [ -z "$p" ] || problems="$problems${problems:+; }zip: $p"
  p=$(icon_mark_problems "$ZIP_DIR/META-INF" | join_problems)
  [ -z "$p" ] || problems="$problems${problems:+; }zip: $p"
  if [ -z "$problems" ]; then
    pass P4 "zip: CodeScan icon files are inside the plugin zip, SonarLintIcons uses them (and no SonarSource-branded image), plugin.xml icons point at CodeScan images and pluginIcon.svg is the CodeScan logo"
  else
    fail P4 "$problems"
  fi
}

check_p5() {
  # A search of the text cannot prove that the address reaches the backend; that proof is a code test (Task 5). This is
  # a first warning sign, aimed at the cases found so far. A string in the code is not enough: the address must
  # reach a place that uses it as the default.
  # 7.2.3 ("legacy": BackendService.kt imports InitializeParams from core.clientapi and no file builds a
  # SonarCloudAlternativeEnvironmentDto): the wizard sets it (setServerUrl/setHostUrl).
  # 10.x (anything else): only the backend counts, because there the wizard constant fills nothing but the connection
  # wizard. BackendService.kt must (1) build the SonarCloudAlternativeEnvironmentDto in a function that always
  # returns it with the CodeScan address (upstream returns null unless the websocket property is also set), and
  # (2) pass that function's result to InitializeParams(...), not null.
  # A name that holds the address counts only in the file that defines it (or as ClassName.NAME from another file).
  set --
  for d in "$SRC/src/main" "$SRC/common/src/main"; do [ -d "$d" ] && set -- "$@" "$d"; done
  if [ $# -eq 0 ]; then fail P5 "no src/main or common/src/main folder"; return; fi
  if ! strip_tree "$TMP/p5.all" "$@"; then
    fail P5 "could not read the source files: $(head -1 "$TMP/strip.err")"
    return
  fi
  cat > "$TMP/p5.awk" <<'EOF'
function base(path,   b) { b = path; sub(/.*\//, "", b); sub(/\.(java|kt)$/, "", b); return b }
function lhs_name(s,   i) {
  i = index(s, "="); if (!i) return ""
  s = substr(s, 1, i - 1); sub(/:.*/, "", s)
  if (!match(s, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/)) return ""
  s = substr(s, RSTART, RLENGTH); gsub(/[[:space:]]/, "", s); return s
}
function addname(f, n) {
  if (n == "") return
  NL[f] = NL[f] " " n
  qc++; QRE[qc] = "(^|[^A-Za-z0-9_])" CLS[f] "\\." n "([^A-Za-z0-9_]|$)"
  QN[qc] = CLS[f] "." n
}
function holds(s, f,   k, c, arr) {
  if (s ~ /"https:\/\/app\.codescan\.io\/?"/) return 1
  c = split(NL[f], arr, " ")
  for (k = 1; k <= c; k++) if (s ~ ("(^|[^A-Za-z0-9_.])" arr[k] "([^A-Za-z0-9_]|$)")) return 1
  for (k = 1; k <= qc; k++) if (s ~ QRE[k]) return 1
  return 0
}
function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
function isfun(s) { return s ~ /(^|[[:space:]])fun[[:space:]]/ }
/^@@FILE / { file = substr($0, 8); CLS[file] = base(file); if (file ~ /\/BackendService\.kt$/ && BS == "") BS = file; next }
{ N++; L[N] = $0; F[N] = file }
END {
  for (i = 1; i <= N; i++)
    if (L[i] ~ /=[[:space:]]*"https:\/\/app\.codescan\.io\/?"/) addname(F[i], lhs_name(L[i]))
  for (i = 1; i <= N; i++)
    if (L[i] ~ /getProperty\("sonarlint\.internal\.sonarcloud\.url"/) {
      a = L[i]
      # System.getProperty("...url", <default>)  or  System.getProperty("...url") ?: <default>
      if (a ~ /getProperty\("sonarlint\.internal\.sonarcloud\.url",/) sub(/.*getProperty\("sonarlint\.internal\.sonarcloud\.url",/, "", a)
      else if (a ~ /getProperty\("sonarlint\.internal\.sonarcloud\.url"\)[[:space:]]*\?:/) sub(/.*getProperty\("sonarlint\.internal\.sonarcloud\.url"\)[[:space:]]*\?:/, "", a)
      else a = ""
      if (a != "" && holds(a, F[i])) addname(F[i], lhs_name(L[i]))
    }
  for (k = 1; k <= qc; k++) print "NAME " QN[k]
  bs_init = 0; bs_legacy = 0; dto_any = 0
  for (i = 1; i <= N; i++) {
    if (L[i] ~ /SonarCloudAlternativeEnvironmentDto/) dto_any = 1
    if (F[i] == BS && L[i] ~ /InitializeParams/) bs_init = 1
    if (F[i] == BS && L[i] ~ /^[[:space:]]*import[[:space:]].*core\.clientapi\.backend\.initialize\.InitializeParams/) bs_legacy = 1
  }
  if (BS == "") { print "PROB cannot find BackendService.kt, so I cannot tell where the backend gets its cloud address; check by hand and update this script"; exit }
  if (!bs_init) { print "PROB BackendService.kt does not mention InitializeParams, so I cannot tell how the backend is started; check by hand and update this script"; exit }
  if (bs_legacy && !dto_any) {
    print "MODE legacy"
    for (i = 1; i <= N; i++)
      if (L[i] ~ /setServerUrl\(|setHostUrl\(|SonarCloudAlternativeEnvironmentDto\(|alternativeSonarCloudEnv/ && holds(L[i], F[i])) { print "USE " trim(L[i]); exit }
    exit
  }
  print "MODE 10x"
  di = 0
  for (i = 1; i <= N; i++) if (F[i] == BS && L[i] ~ /SonarCloudAlternativeEnvironmentDto\(/) { di = i; break }
  if (!di) { print "PROB BackendService.kt never builds a SonarCloudAlternativeEnvironmentDto, so https://app.codescan.io cannot reach the backend (a wizard setter only fills the connection wizard)"; exit }
  s = di
  while (s > 1 && F[s - 1] == BS && !isfun(L[s])) s--
  if (!isfun(L[s])) { print "PROB cannot find the function that builds the SonarCloudAlternativeEnvironmentDto in BackendService.kt; check by hand and update this script"; exit }
  fn = L[s]; sub(/\(.*/, "", fn); sub(/.*[. >]/, "", fn); fn = trim(fn)
  e = di
  while (e < N && F[e + 1] == BS && !isfun(L[e + 1])) e++
  hasws = 0; hasnull = 0; addr = 0
  for (k = s; k <= e; k++) {
    if (L[k] ~ /sonarlint\.internal\.sonarcloud\.websocket\.url/) hasws = 1
    if (L[k] ~ /(return|else)[[:space:]]+null([^A-Za-z0-9_]|$)/) hasnull = 1
    if (holds(L[k], BS)) addr = 1
  }
  if (hasws && hasnull)
    print "PROB " fn "() builds the SonarCloudAlternativeEnvironmentDto only when the websocket property sonarlint.internal.sonarcloud.websocket.url is set (otherwise it returns null), so the CodeScan address is dropped; it must always return the DTO with https://app.codescan.io"
  if (!addr)
    print "PROB " fn "() does not use https://app.codescan.io as the address of the SonarCloudAlternativeEnvironmentDto"
  ik = 0
  for (i = 1; i <= N; i++) if (F[i] == BS && L[i] !~ /^[[:space:]]*import[[:space:]]/ && L[i] ~ /InitializeParams\(/) { ik = i; break }
  if (!ik) { print "PROB BackendService.kt has no InitializeParams(...) call, so the cloud address is never passed to the backend"; exit }
  ctext = ""; depth = 0; started = 0; done = 0
  for (j = ik; j <= N && F[j] == BS && !done; j++) {
    t = L[j]
    if (j == ik) t = substr(t, index(t, "InitializeParams("))
    for (k = 1; k <= length(t) && !done; k++) {
      ch = substr(t, k, 1)
      if (ch == "(") { depth++; started = 1 } else if (ch == ")") { depth--; if (started && depth == 0) done = 1 }
      ctext = ctext ch
    }
    ctext = ctext "\n"
  }
  nloc = 0
  for (i = 1; i <= N; i++)
    if (F[i] == BS && (L[i] ~ ("=[[:space:]]*" fn "\\(") || L[i] ~ /=[[:space:]]*SonarCloudAlternativeEnvironmentDto\(/)) { nl = lhs_name(L[i]); if (nl != "") LOC[++nloc] = nl }
  passes = (ctext ~ ("(^|[^A-Za-z0-9_])" fn "\\(") || ctext ~ /SonarCloudAlternativeEnvironmentDto\(/)
  for (k = 1; k <= nloc && !passes; k++) if (ctext ~ ("(^|[^A-Za-z0-9_.])" LOC[k] "([^A-Za-z0-9_]|$)")) passes = 1
  if (!passes)
    print "PROB InitializeParams(...) in BackendService.kt does not pass the alternative environment (" fn "() or a SonarCloudAlternativeEnvironmentDto), so the backend never gets the CodeScan address"
  else
    print "OKCALL InitializeParams(...) gets " fn "(), which builds the SonarCloudAlternativeEnvironmentDto with https://app.codescan.io"
}
EOF
  awk -f "$TMP/p5.awk" "$TMP/p5.all" > "$TMP/p5.out" 2> "$TMP/p5.err" || { fail P5 "could not search the source: $(head -1 "$TMP/p5.err")"; return; }
  mode=$(sed -n 's/^MODE //p' "$TMP/p5.out" | head -1)
  names=$(sed -n 's/^NAME //p' "$TMP/p5.out" | sort -u | tr '\n' ' ')
  probs=$(sed -n 's/^PROB //p' "$TMP/p5.out" | join_problems)
  use=$(sed -n 's/^USE //p' "$TMP/p5.out" | head -1)
  okcall=$(sed -n 's/^OKCALL //p' "$TMP/p5.out" | head -1)
  if [ -n "$probs" ]; then
    fail P5 "$probs${names:+ (names that hold the address: ${names% })}"
  elif [ "$mode" = 10x ] && [ -n "$okcall" ]; then
    pass P5 "https://app.codescan.io reaches the 10.x backend (first warning sign only; Task 5's code test is the proof): $okcall"
  elif [ "$mode" = legacy ] && [ -n "$use" ]; then
    pass P5 "https://app.codescan.io is used as the default cloud address: $use"
  elif [ "$mode" = legacy ] && [ -n "$names" ]; then
    fail P5 "https://app.codescan.io is held by ${names}but never used as the default (setServerUrl/setHostUrl) in the same file"
  elif [ "$mode" = legacy ]; then
    fail P5 "https://app.codescan.io is not used as the default cloud address in src/main or common/src/main"
  else
    fail P5 "cannot tell whether https://app.codescan.io reaches the backend; check by hand and update this script"
  fi
}

check_p8() {
  # Every call that adds the tab must sit inside an if (...isTaintVulnerabilitiesEnabled()) block, and that switch must return false.
  # Comments are removed first, so a commented-out guard or call does not count.
  # No call found means the code moved; FAIL so a person updates this check, instead of guessing PASS.
  candidates=$(grep -rlE --include='*.java' --include='*.kt' 'addTaintVulnerabilitiesTab\(project' "$SRC/src/main" 2> /dev/null)
  callers=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if strip_code "$f" | grep -q 'addTaintVulnerabilitiesTab(project'; then callers="$callers$f
"; fi
  done <<EOF2
$candidates
EOF2
  callers=${callers%?}
  if [ -z "$callers" ]; then
    fail P8 "cannot find the code that adds the taint tab (addTaintVulnerabilitiesTab(project...) in src/main, outside comments); check by hand and update this script"
    return
  fi
  unguarded=""
  while IFS= read -r f; do
    # Braces in strings are not special-cased; a wrong count can only produce a FAIL, never a false PASS.
    lines=$(strip_code "$f" | awk '
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
      }')
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
  body=$(strip_code "$UTILS" | awk '/boolean isTaintVulnerabilitiesEnabled\(\)/ { f = 1; next }
              f && /^[[:space:]]*}/ { exit }
              f { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }')
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
  # each sub-module. Test data and its/projects/ sample projects are not source folders. Generated protobuf code is
  # written to build/generated/..., and every folder called build is skipped, so no path-name exclusion is needed:
  # a hand-written file in a folder that happens to be called "proto" must still carry the header.
  find "$SRC" \( -name build -o -name .gradle -o -name .git -o -name .worktrees -o -name node_modules \) -prune -o \
    -type f \( -name '*.java' -o -name '*.kt' \) -print |
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
  # awk never sees an empty file (it has no first line), so an empty file is reported here: it has no header either.
  while IFS= read -r f; do
    [ -s "$f" ] || printf '%s\n' "$f" >> "$TMP/bad"
  done < "$TMP/files"
  nbad=$(awk 'END { print NR }' "$TMP/bad")
  if [ "$nbad" -eq 0 ]; then
    pass P9 "license header matches HEADER in all $total .java/.kt files"
  else
    list=$(head -5 "$TMP/bad" | awk -v p="$SRC/" 'index($0, p) == 1 { $0 = substr($0, length(p) + 1) } { print }' | tr '\n' ' ')
    fail P9 "license header differs from HEADER (or the file is empty) in $nbad of $total files, e.g. $list"
  fi
}

# ns_problems <META-INF folder> <its plugin.xml, comments stripped>: one problem per line.
# Checked files: plugin-java.xml (its extensions are the Java analysis settings, row P10) and every other
# plugin-*.xml that plugin.xml loads with config-file="...". A file that plugin.xml does not load, such as
# plugin-clion.xml in 7.2.3, is never read by the IDE and is not checked.
# plugin-git.xml is left out on purpose: 7.2.3 has the old namespace there (row P33, a known bug that Task 5 fixes), and
# the script's baseline is that 7.2.3 passes. Add it here once P33 is fixed.
ns_problems() {
  files="plugin-java.xml $(grep -oE 'config-file="[^"]*"' "$2" | sed 's/^config-file="\(.*\)"$/\1/' | tr '\n' ' ')"
  seen=" "
  for f in $files; do
    case "$seen" in *" $f "*) continue ;; esac
    seen="$seen$f "
    case "$f" in */*) echo "$f: plugin.xml names a config file with a path; check by hand"; continue ;; esac
    [ "$f" = "plugin-git.xml" ] && continue
    if [ ! -f "$1/$f" ]; then echo "$f is loaded by plugin.xml but not found"; continue; fi
    strip_xml "$1/$f" | grep -oE 'defaultExtensionNs="[^"]*"' | sed 's/^defaultExtensionNs="\(.*\)"$/\1/' > "$TMP/ns.list"
    old=$(grep -E '^org\.sonarlint\.' "$TMP/ns.list" | sort -u | tr '\n' ' ')
    if [ -n "$old" ]; then
      echo "$f registers extensions under the SonarLint namespace ${old}(CodeScan extension points are com.code-scan.intellij.*, so they would never be found)"
    elif [ "$f" = "plugin-java.xml" ] && ! grep -qx 'com\.code-scan\.intellij' "$TMP/ns.list"; then
      echo "plugin-java.xml has no defaultExtensionNs=\"com.code-scan.intellij\" (the Java analysis settings, row P10, would not load)"
    fi
  done
}

check_p32() {
  # The IDE looks extensions up by full name. A name that does not start with the plugin id finds nothing, with no error.
  prefix="com.code-scan.intellij."
  common="$SRC/common/src/main"
  if [ ! -d "$common" ]; then fail P32 "no common/src/main folder"; return; fi
  if ! strip_tree "$TMP/ep.code" "$common"; then
    fail P32 "could not read the source files in common/src/main: $(head -1 "$TMP/strip.err")"
    return
  fi
  grep -oE 'ExtensionPointName(\.create)?(<[^>]*>)?\([[:space:]]*"[^"]*"' "$TMP/ep.code" |
    sed 's/.*"\([^"]*\)"$/\1/' > "$TMP/ep.names"
  for x in "$SRC"/src/main/resources/META-INF/plugin*.xml; do
    [ -f "$x" ] && strip_xml "$x" | grep -oE 'qualifiedName="[^"]*"' | sed 's/.*="\([^"]*\)"$/\1/' >> "$TMP/ep.names"
  done
  total=$(awk 'END { print NR }' "$TMP/ep.names")
  if [ "$total" -eq 0 ]; then
    fail P32 "no ExtensionPointName.create(\"...\") found in common/src/main; check by hand and update this script"
    return
  fi
  bad=$(awk -v p="$prefix" 'index($0, p) != 1' "$TMP/ep.names" | tr '\n' ' ')
  if [ -n "$bad" ]; then
    fail P32 "extension point names that do not start with $prefix (extensions would not be found): $bad"
    return
  fi
  strip_xml "$PLUGIN_XML" > "$TMP/src-plugin.xml"
  problems=$(ns_problems "$SRC/src/main/resources/META-INF" "$TMP/src-plugin.xml" | join_problems)
  note=""
  grep -q 'config-file="plugin-git.xml"' "$TMP/src-plugin.xml" &&
    note="; plugin-git.xml is not checked: known bug, row P33 (Task 5 fixes it)"
  if [ -z "$problems" ]; then
    pass P32 "all $total extension point names start with $prefix; plugin-java.xml and the other loaded plugin-*.xml register under com.code-scan.intellij$note"
  else
    fail P32 "$problems$note"
  fi
}

check_p32_zip() {
  [ -n "$ZIP" ] || return 0
  if [ -n "$ZIP_ERR" ]; then fail P32 "zip: $ZIP_ERR"; return; fi
  strip_xml "$ZIP_DIR/META-INF/plugin.xml" > "$TMP/zip-plugin.xml"
  problems=$(ns_problems "$ZIP_DIR/META-INF" "$TMP/zip-plugin.xml" | join_problems)
  if [ -z "$problems" ]; then
    pass P32 "zip: plugin-java.xml and the other loaded plugin-*.xml register under com.code-scan.intellij"
  else
    fail P32 "zip: $problems"
  fi
}

# A zip built from another version of the source must not pass for this tree: plugin.xml in the zip has the
# version the build wrote, and it must be the version= of gradle.properties (plugin.xml holds ${project.version}).
check_zip_version() {
  [ -n "$ZIP" ] || return 0
  [ -z "$ZIP_ERR" ] || return 0     # already reported by the zip checks of P1
  want=$(sed -n 's/^version=//p' "$SRC/gradle.properties" 2> /dev/null | head -1 | tr -d '[:space:]')
  if [ -z "$want" ]; then
    fail P1 "zip: cannot read version= from $SRC/gradle.properties, so I cannot tell whether the zip is built from this tree"
    return
  fi
  have=$(xml_value "$TMP/zip-plugin.xml" version | tr -d '[:space:]')
  if [ "$have" = "$want" ]; then
    pass P1 "zip: plugin.xml <version> $have is the version the source tree builds"
  else
    fail P1 "zip: plugin.xml <version> is '${have:-missing}' but the source tree builds '$want' (stale zip? rebuild it)"
  fi
}

strip_xml "$PLUGIN_XML" > "$TMP/src-plugin.xml"
check_p1 "$TMP/src-plugin.xml" ""
zip_xml_check check_p1 P1
check_p2 "$TMP/src-plugin.xml" ""
zip_xml_check check_p2 P2
check_zip_version
check_p4_source
[ -n "$ZIP" ] && check_p4_zip
check_p5
check_p8
check_p9
check_p32
check_p32_zip

echo
[ -z "$ZIP_NOTE" ] || echo "$ZIP_NOTE"
[ -z "$SKIP_ZIP" ] || echo "$SKIP_ZIP"
if [ -z "$FAILED_ROWS" ]; then
  echo "Result: $PASSED checks passed, 0 failed"
  # Skipped zip checks because no zip was found are not a full pass (--no-zip is the way to say "on purpose").
  [ "$NOZIP" -eq 0 ] && [ -n "$SKIP_ZIP" ] && exit 3
  exit 0
fi
echo "Failed rows: $FAILED_ROWS"
exit 1
