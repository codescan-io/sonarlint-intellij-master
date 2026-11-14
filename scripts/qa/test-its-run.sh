#!/usr/bin/env bash
# Tests for its-run.sh that need no IDE or Gradle: a fake source tree whose "gradlew" plays the three Gradle runs
# (prepare, start the IDE, run the tests), and a stub "curl" that answers for the robot server.
# Run: bash scripts/qa/test-its-run.sh
# Env: IR=<path>  the its-run.sh to test (default: the one next to this file).
# Works with macOS bash 3.2 and Linux bash.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
IR="${IR:-$HERE/its-run.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/its-run-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd)"
IJ=IC-2023.1.7
LOGDIR="$TMP/src/its/build/idea-sandbox/$IJ/log_runIdeForUiTests"
cleanup() { pkill -f "$LOGDIR" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0
OUT=""
CODE=0

ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
not_ok() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1"
  echo "       $2"
  echo "$OUT" | sed 's/^/       | /'
}
expect_code() {
  if [ "$CODE" -eq "$2" ]; then ok "$1: exit $2"; else not_ok "$1: exit $2" "got exit $CODE"; fi
}
expect_out() {
  if printf '%s\n' "$OUT" | grep -F -q -- "$2"; then ok "$1: output has '$2'"; else not_ok "$1: output has '$2'" "missing"; fi
}
expect_file_has() {
  if grep -F -q -- "$3" "$2" 2>/dev/null; then ok "$1: $(basename "$2") has '$3'"; else not_ok "$1: $(basename "$2") has '$3'" "missing in $2"; fi
}
expect_no_file() {
  if [ -e "$2" ]; then not_ok "$1: no $(basename "$2")" "still there: $2"; else ok "$1: no $(basename "$2")"; fi
}
expect_ide_stopped() {
  if pgrep -f "$LOGDIR" >/dev/null 2>&1; then not_ok "$1: the IDE was stopped" "still running"; else ok "$1: the IDE was stopped"; fi
}
expect_faster_than() {
  if [ "$ELAPSED" -lt "$2" ]; then ok "$1: ended within $2 s"; else not_ok "$1: ended within $2 s" "took $ELAPSED s"; fi
}

export STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR" "$TMP/bin" "$TMP/src" "$TMP/plugin"

# The robot server "answers" while $STUB_DIR/robot-up exists.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [ -f "$STUB_DIR/robot-up" ]; then printf 200; else printf 000; fi
STUB

# STUB_PREPARE_RC = exit code of the preparation run
# STUB_IDE  = up (starts and its robot answers) | silent (starts, robot never answers) | exit (stops at once)
# STUB_TEST = pass | fail | hang
cat > "$TMP/src/gradlew" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/gradle-calls"
v=""
for a in "$@"; do case "$a" in -PijVersion=*) v="${a#-PijVersion=}" ;; esac; done
logdir="$PWD/its/build/idea-sandbox/$v/log_runIdeForUiTests"
for a in "$@"; do
  case "$a" in
    :its:prepareSandbox_runIdeForUiTests) exit "${STUB_PREPARE_RC:-0}" ;;
    :its:runIdeForUiTests)
      [ "${STUB_IDE:-up}" = exit ] && exit 1
      mkdir -p "$logdir" && echo NEW > "$logdir/idea.log"
      [ "${STUB_IDE:-up}" = up ] && touch "$STUB_DIR/robot-up"
      # The fake IDE: its command line holds the sandbox log folder, as the real one's does.
      exec bash -c 'trap "rm -f \"$1\"; exit 143" TERM; while :; do sleep 1; done' ide "$STUB_DIR/robot-up" "$logdir" ;;
    :its:test)
      mkdir -p its/build/test-results/test
      echo '<testsuite/>' > its/build/test-results/test/TEST-x.xml
      case "${STUB_TEST:-pass}" in pass) exit 0 ;; fail) exit 1 ;; hang) sleep 30; exit 0 ;; esac ;;
  esac
done
exit 0
STUB
chmod +x "$TMP/bin/curl" "$TMP/src/gradlew"

run() {
  local name=$1 start
  shift
  rm -f "$STUB_DIR/robot-up" "$STUB_DIR/gradle-calls"
  start=$(date +%s)
  OUT="$(PATH="$TMP/bin:$PATH" START_TIMEOUT_SEC="${START_TIMEOUT_SEC:-20}" TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-20}" \
    STOP_TIMEOUT_SEC=5 bash "$IR" --src "$TMP/src" --plugin-dir "$TMP/plugin" --ij-version "$IJ" --out "$TMP/out-$name" "$@" 2>&1)"
  CODE=$?
  ELAPSED=$(( $(date +%s) - start ))
}

# 1. Tests pass: exit 0, the IDE's log and the test results are collected, the IDE is stopped.
#    A log left in the sandbox by an earlier run does not count.
mkdir -p "$LOGDIR" && echo OLD > "$LOGDIR/idea.log" && echo OLD > "$LOGDIR/idea.1.log"
run pass --tests '*StandaloneIdeaTests*'
expect_code "pass" 0
expect_file_has "pass" "$TMP/out-pass/log/idea.log" "NEW"
expect_no_file "pass: old log" "$TMP/out-pass/log/idea.1.log"
expect_file_has "pass" "$TMP/out-pass/test-results/TEST-x.xml" "testsuite"
expect_file_has "pass: --tests" "$STUB_DIR/gradle-calls" ":its:test --tests *StandaloneIdeaTests*"
expect_file_has "pass: plugin" "$STUB_DIR/gradle-calls" "-PslPluginDirectory=$TMP/plugin"
expect_ide_stopped "pass"

# 2. A failed test: exit 5, results still collected.
STUB_TEST=fail run fail
expect_code "failed test" 5
expect_file_has "failed test" "$TMP/out-fail/log/idea.log" "NEW"
expect_ide_stopped "failed test"

# 3. Tests that hang are stopped at TEST_TIMEOUT_SEC: exit 5, and the run ends.
STUB_TEST=hang TEST_TIMEOUT_SEC=3 run hang
expect_code "hanging tests" 5
expect_faster_than "hanging tests" 28
expect_ide_stopped "hanging tests"

# 4. The IDE's robot server never answers: exit 3 after START_TIMEOUT_SEC, the IDE is stopped.
STUB_IDE=silent START_TIMEOUT_SEC=4 run silent
expect_code "robot never answers" 3
expect_faster_than "robot never answers" 15
expect_ide_stopped "robot never answers"
expect_file_has "robot never answers: log kept" "$TMP/out-silent/log/idea.log" "NEW"

# 5. The IDE's Gradle run stops before the robot answers: exit 3 without waiting for START_TIMEOUT_SEC.
STUB_IDE=exit run ide-exit
expect_code "IDE stops at once" 3
expect_faster_than "IDE stops at once" 15
expect_out "IDE stops at once" "the IDE stopped before its robot server answered"

# 6. Preparation fails: exit 3, no IDE started.
STUB_PREPARE_RC=1 run prepare-fails
expect_code "preparation fails" 3
if grep -q ':its:runIdeForUiTests' "$STUB_DIR/gradle-calls" 2>/dev/null; then not_ok "preparation fails: no IDE start" "IDE was started"; else ok "preparation fails: no IDE start"; fi

# 7. Something already answers on the robot port: exit 3 before any Gradle run.
rm -f "$STUB_DIR/gradle-calls"
touch "$STUB_DIR/robot-up"
OUT="$(PATH="$TMP/bin:$PATH" bash "$IR" --src "$TMP/src" --plugin-dir "$TMP/plugin" --ij-version "$IJ" --out "$TMP/out-busy" 2>&1)"
CODE=$?
expect_code "port in use" 3
expect_out "port in use" "something already answers"
expect_no_file "port in use: no Gradle run" "$STUB_DIR/gradle-calls"
rm -f "$STUB_DIR/robot-up"

# 8. Bad usage.
OUT="$(bash "$IR" 2>&1)"; CODE=$?
expect_code "no arguments" 2
OUT="$(bash "$IR" --src "$TMP/src" --plugin-dir "$TMP/plugin" --ij-version 2023.1.7 --out "$TMP/out-x" 2>&1)"; CODE=$?
expect_code "version without product code" 2

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
