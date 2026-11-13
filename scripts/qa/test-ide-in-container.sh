#!/usr/bin/env bash
# Tests for ide-in-container.sh without Docker and without a real IDE.
# Stub programs (xdotool, tesseract, xwd, convert, Xvfb, ...) and a stub IDE launcher are put first on PATH.
# The sleep lengths are cut to 2% with QA_SLEEP_SCALE, and the script's folders are moved with the QA_* variables.
# The stub IDE dies when a named screenshot appears (STUB_CRASH_AFTER), so a crash lands at the same step
# every time and the tests do not depend on timing.
# Run: bash scripts/qa/test-ide-in-container.sh
# Env: IC=<path>  the ide-in-container.sh to test (default: the one next to this file).
# Works with macOS bash 3.2 and Linux bash.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
IC="${IC:-$HERE/ide-in-container.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ide-in-container-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
OUT=""
CODE=0
RUN=0
RUN_DIR=""

ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
not_ok() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1"
  echo "       $2"
  echo "$OUT" | tail -15 | sed 's/^/       | /'
}
expect_code() {
  if [ "$CODE" -eq "$2" ]; then ok "$1: exit $2"; else not_ok "$1: exit $2" "got exit $CODE"; fi
}
expect_out() {
  if printf '%s\n' "$OUT" | grep -F -q -- "$2"; then ok "$1: output has '$2'"; else not_ok "$1: output has '$2'" "missing"; fi
}
expect_no_out() {
  if printf '%s\n' "$OUT" | grep -F -q -- "$2"; then not_ok "$1: output has no '$2'" "found"; else ok "$1: output has no '$2'"; fi
}
expect_file() {
  if [ -s "$RUN_DIR/out/$2" ]; then ok "$1: $2 was collected"; else not_ok "$1: $2 was collected" "missing or empty"; fi
}

BIN="$TMP/bin"
mkdir -p "$BIN"
for prog in xdotool Xvfb xdpyinfo fluxbox; do
  printf '#!/bin/sh\nexit 0\n' > "$BIN/$prog"
done
printf '#!/bin/sh\necho x\n' > "$BIN/xwd"
# convert xwd:- <file>   or   convert <in> ... <out>: the last argument is written.
cat > "$BIN/convert" <<'STUB'
#!/bin/sh
for last; do :; done
echo image > "$last"
STUB
# tesseract <image> stdout: prints the text the test chose.
cat > "$BIN/tesseract" <<'STUB'
#!/bin/sh
echo "${STUB_OCR_TEXT:-}"
STUB
cat > "$BIN/unzip" <<'STUB'
#!/bin/sh
# unzip -q <zip> -d <dir>
mkdir -p "$4/CodeScan/lib"
STUB
chmod +x "$BIN"/*

# The IDE tarball holds one top folder with product-info.json and the launcher bin/idea.
IDE_SRC="$TMP/ide-src/idea-stub"
mkdir -p "$IDE_SRC/bin"
echo '{ "version": "2026.1.5", "buildNumber": "261.1" }' > "$IDE_SRC/product-info.json"
cat > "$IDE_SRC/bin/idea" <<'STUB'
#!/usr/bin/env bash
# Stub IDE launcher. Env: STUB_NO_START=1 exit at once; STUB_CRASH_AFTER=<screenshot name> die when that
# screenshot exists; STUB_SHUTDOWN=0 do not write the IDE SHUTDOWN line on SIGTERM; STUB_IGNORE_TERM=1 keep running on SIGTERM;
# STUB_HANG_ON_TERM=1 write the IDE SHUTDOWN line on SIGTERM but then keep running (a shutdown that hangs).
log="$(sed -n 's/^idea.log.path=//p' "$IDEA_PROPERTIES")/idea.log"
stamp() { date '+%Y-%m-%d %H:%M:%S,000'; }
if [ "${1:-}" = "--line" ]; then
  echo "$(stamp) [  1000]   INFO - #c.i.Stub - fileOpened $(basename "$3")" >> "$log"
  exit 0
fi
[ "${STUB_NO_START:-0}" = 1 ] && exit 1
echo "$(stamp) [  1000]   INFO - #c.i.Stub - Project frame set to stub" >> "$log"
echo "$(stamp) [  1000]   INFO - #c.i.Stub - Loaded custom plugins: CodeScan (7.3.2)" >> "$log"
if [ "${STUB_IGNORE_TERM:-0}" = 1 ]; then
  trap '' TERM
elif [ "${STUB_HANG_ON_TERM:-0}" = 1 ]; then
  trap 'echo "$(stamp) [  1000]   INFO - #c.i.Stub - ------------------------------------------------------ IDE SHUTDOWN ------------------------------------------------------" >> "$log"; trap "" TERM' TERM
else
  trap 'if [ "${STUB_SHUTDOWN:-1}" = 1 ]; then echo "$(stamp) [  1000]   INFO - #c.i.Stub - ------------------------------------------------------ IDE SHUTDOWN ------------------------------------------------------" >> "$log"; fi; exit 0' TERM
fi
while :; do
  if [ -n "${STUB_CRASH_AFTER:-}" ] && [ -e "$QA_OUT/screens/$STUB_CRASH_AFTER.png" ]; then
    echo "$(stamp) [  1000]   INFO - #c.i.Stub - (stub IDE crashes here)" >> "$log"
    exit 137
  fi
  sleep 0.05
done
STUB
chmod +x "$IDE_SRC/bin/idea"
tar -czf "$TMP/ide.tar.gz" -C "$TMP/ide-src" idea-stub
echo zip > "$TMP/plugin.zip"
mkdir -p "$TMP/sample/force-app/main/default/classes"
echo "public class AccountServiceLayer {}" > "$TMP/sample/force-app/main/default/classes/AccountServiceLayer.cls"

# run_ic <RUN_MINUTES>: runs the script once in its own folders, at most 60 seconds. Sets CODE and OUT.
# Anything else for the stubs is passed as VAR=value arguments after the minutes.
run_ic() {
  local minutes="$1"; shift
  RUN=$((RUN + 1))
  RUN_DIR="$TMP/run$RUN"
  mkdir -p "$RUN_DIR/home"
  (
    export PATH="$BIN:$PATH" HOME="$RUN_DIR/home" RUN_MINUTES="$minutes" START_TIMEOUT_SEC=2000
    export QA_OUT="$RUN_DIR/out" QA_IDE_DIR="$RUN_DIR/ide" QA_WORK_DIR="$RUN_DIR/work"
    export QA_IDE_TARBALL="$TMP/ide.tar.gz" QA_PLUGIN_ZIP="$TMP/plugin.zip" QA_SRC_PROJECT="$TMP/sample"
    export QA_SLEEP_SCALE=0.02 STUB_OCR_TEXT="Found 4 issues in 1 file"
    [ $# -gt 0 ] && export "$@"
    exec bash "$IC"
  ) > "$RUN_DIR/stdout.txt" 2>&1 &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    if [ $n -gt 600 ]; then kill -KILL "$pid" 2>/dev/null; echo "(test: gave up after 60 s)" >> "$RUN_DIR/stdout.txt"; break; fi
    sleep 0.1
  done
  wait "$pid"; CODE=$?
  [ $n -gt 600 ] && CODE=99
  OUT="$(cat "$RUN_DIR/stdout.txt")"
}

run_ic 5
expect_code "good run" 0
expect_out "good run" "CodeScan showed its analysis result for Hello.java"
expect_out "good run" "idea.log has the IDE SHUTDOWN line"
expect_file "good run" "log/idea.log"

# Blocking 1: the IDE dies during the scripted steps (about 160 s in a real run). With --minutes 1 or 2
# the wait loop never runs, so only the check before the stop can see the crash.
run_ic 1 STUB_CRASH_AFTER=04-analyze-apex
expect_code "crash in the scripted steps, 1 min" 4
expect_out "crash in the scripted steps, 1 min" "the IDE had already exited"
expect_file "crash in the scripted steps, 1 min" "log/idea.log"
run_ic 2 STUB_CRASH_AFTER=05-settings
expect_code "crash in the scripted steps, 2 min" 4
run_ic 0 STUB_CRASH_AFTER=03-analyze-java
expect_code "crash in the scripted steps, 0 min" 4

run_ic 5 STUB_CRASH_AFTER=05-settings
expect_code "crash in the wait loop" 4
expect_out "crash in the wait loop" "IDE exited early"
expect_file "crash in the wait loop" "log/idea.log"

# A normal stop must leave the IDE SHUTDOWN line in idea.log.
run_ic 5 STUB_SHUTDOWN=0
expect_code "no SHUTDOWN line" 4
expect_out "no SHUTDOWN line" "idea.log has no IDE SHUTDOWN line"
expect_no_out "no SHUTDOWN line" "CodeScan showed its analysis result"
expect_file "no SHUTDOWN line" "log/idea.log"

# An IDE that does not react to SIGTERM is killed after the wait, and has no SHUTDOWN line either.
run_ic 5 STUB_IGNORE_TERM=1
expect_code "IDE ignores SIGTERM" 4
expect_out "IDE ignores SIGTERM" "killing it"
expect_out "IDE ignores SIGTERM" "idea.log has no IDE SHUTDOWN line"

# A shutdown that starts (the SHUTDOWN line is written) but never ends is not a normal stop either.
run_ic 5 STUB_HANG_ON_TERM=1
expect_code "shutdown hangs" 4
expect_out "shutdown hangs" "killing it"
expect_out "shutdown hangs" "did not stop within 90 s"
expect_no_out "shutdown hangs" "CodeScan showed its analysis result"
expect_file "shutdown hangs" "log/idea.log"

run_ic 5 STUB_OCR_TEXT="Nothing to see here"
expect_code "no analysis result on screen" 5
expect_out "no analysis result on screen" "did not show 'Found N issues'"
expect_file "no analysis result on screen" "log/idea.log"

# The result is also found when the text is a single issue in one file.
run_ic 5 STUB_OCR_TEXT="Found 1 issue in 1 file"
expect_code "one issue on screen" 0

run_ic 5 STUB_NO_START=1
expect_code "IDE does not start" 3
expect_out "IDE does not start" "IDE process exited during start"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
