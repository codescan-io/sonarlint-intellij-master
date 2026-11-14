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
cleanup() {
  pkill -f "$LOGDIR" 2>/dev/null
  for f in "$TMP"/stub/*.pid; do [ -f "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
  [ -n "${DECOY:-}" ] && kill "$DECOY" 2>/dev/null
  rm -rf "$TMP"
}
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
# The process whose ID is in file $2 no longer runs.
expect_stopped() {
  local pid
  pid="$(cat "$2" 2>/dev/null)"
  if [ -z "$pid" ]; then not_ok "$1: stopped" "no process ID in $2"
  elif kill -0 "$pid" 2>/dev/null; then not_ok "$1: stopped" "process $pid still runs"; kill -KILL "$pid" 2>/dev/null
  else ok "$1: stopped"; fi
}
wait_for_file() {
  local deadline=$(( $(date +%s) + $2 ))
  until [ -s "$1" ]; do [ "$(date +%s)" -lt "$deadline" ] || return 1; sleep 1; done
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
# STUB_TEST = pass | fail | hang | no-results (passes but writes no results, as when Gradle reuses an earlier run)
#             | hang-detached (hangs in a child process that left the process group, as Gradle's build process does;
#               its process ID is in $STUB_DIR/detached.pid)
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
      if [ "${STUB_TEST:-pass}" != no-results ]; then
        mkdir -p its/build/test-results/test
        echo '<testsuite/>' > its/build/test-results/test/TEST-x.xml
      fi
      case "${STUB_TEST:-pass}" in
        pass|no-results) exit 0 ;;
        fail) exit 1 ;;
        hang) sleep 30; exit 0 ;;
        hang-detached)
          perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' sleep 4243 &
          echo $! > "$STUB_DIR/detached.pid"
          wait; exit 0 ;;
      esac ;;
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
# Every Gradle run ends its own Java processes (no daemon, no Kotlin compile daemon): left running, they hold memory
# the IDE needs in a container with a memory limit.
for want in --no-daemon -Pkotlin.compiler.execution.strategy=in-process; do
  if grep -v -F -e "$want" "$STUB_DIR/gradle-calls" | grep -q .; then
    not_ok "pass: every Gradle run has $want" "$(grep -v -F -e "$want" "$STUB_DIR/gradle-calls")"
  else
    ok "pass: every Gradle run has $want"
  fi
done

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

# 3b. A Gradle run stopped at its time limit is stopped with all it started, also a process that left its process
#     group (Gradle's build process does).
rm -f "$STUB_DIR/detached.pid"
STUB_TEST=hang-detached TEST_TIMEOUT_SEC=3 run hang-detached
expect_code "hanging tests in a detached process" 5
expect_stopped "hanging tests in a detached process" "$STUB_DIR/detached.pid"

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

# 8. Results left in the source tree by an earlier run do not count, when :its:test writes none (Gradle found the
#    task up to date, or took its result from the build cache).
mkdir -p "$TMP/src/its/build/test-results/test" "$TMP/src/its/build/reports/ide-log-check"
echo '<testsuite name="old"/>' > "$TMP/src/its/build/test-results/test/TEST-old.xml"
echo 'old log check' > "$TMP/src/its/build/reports/ide-log-check/scan.txt"
STUB_TEST=no-results run stale
expect_no_file "earlier results" "$TMP/out-stale/test-results/TEST-old.xml"
expect_no_file "earlier log check" "$TMP/out-stale/gradle-log-check.txt"

# 9. Only this sandbox's IDE is stopped: its path is matched as plain text. As a pattern, the "." in IC-2023.1.7
#    matches any character, so another sandbox's IDE (here IC-2023x1x7) would be stopped too.
bash -c 'while :; do sleep 1; done' decoy "$TMP/src/its/build/idea-sandbox/IC-2023x1x7/log_runIdeForUiTests" &
DECOY=$!
run decoy
if kill -0 "$DECOY" 2>/dev/null; then ok "decoy: another sandbox's IDE left running"; else not_ok "decoy: another sandbox's IDE left running" "it was stopped"; fi
kill "$DECOY" 2>/dev/null; wait "$DECOY" 2>/dev/null; DECOY=""

# 10. Stopped by a signal (HUP: the terminal closed; TERM: docker stop), its-run.sh stops the IDE and the Gradle run
#     it started, collects what there is and exits 3. (A background job cannot get INT: bash ignores it there.)
for SIG in HUP TERM; do
  rm -f "$STUB_DIR/robot-up" "$STUB_DIR/gradle-calls" "$STUB_DIR/detached.pid"
  PATH="$TMP/bin:$PATH" STUB_TEST=hang-detached START_TIMEOUT_SEC=20 TEST_TIMEOUT_SEC=60 STOP_TIMEOUT_SEC=5 \
    bash "$IR" --src "$TMP/src" --plugin-dir "$TMP/plugin" --ij-version "$IJ" --out "$TMP/out-$SIG" > "$TMP/$SIG.txt" 2>&1 &
  IR_PID=$!
  wait_for_file "$STUB_DIR/detached.pid" 20
  start=$(date +%s)
  kill -"$SIG" "$IR_PID"
  wait "$IR_PID"; CODE=$?
  ELAPSED=$(( $(date +%s) - start ))
  OUT="$(cat "$TMP/$SIG.txt")"
  expect_code "$SIG" 3
  expect_faster_than "$SIG" 25
  expect_out "$SIG" "interrupted"
  expect_ide_stopped "$SIG"
  expect_stopped "$SIG: the Gradle test run" "$STUB_DIR/detached.pid"
  expect_file_has "$SIG: log kept" "$TMP/out-$SIG/log/idea.log" "NEW"
done

# 11. --indexing-project and INDEXING_FILES reach :its:test as Gradle properties; a missing folder is skipped with a
#     warning (the real-indexing scenario then skips itself).
mkdir -p "$TMP/indexing project"
INDEXING_FILES=12 run indexing --indexing-project "$TMP/indexing project"
expect_code "indexing" 0
expect_file_has "indexing" "$STUB_DIR/gradle-calls" ":its:test -PindexingProject=$TMP/indexing project -PindexingFiles=12"
run indexing-missing --indexing-project "$TMP/no-such-folder"
expect_code "indexing folder missing" 0
expect_out "indexing folder missing" "warning: --indexing-project folder not found: $TMP/no-such-folder"
if grep -q -e "-PindexingProject" "$STUB_DIR/gradle-calls"; then not_ok "indexing folder missing: no -PindexingProject" "passed on"; else ok "indexing folder missing: no -PindexingProject"; fi

# 12. Bad usage.
OUT="$(bash "$IR" 2>&1)"; CODE=$?
expect_code "no arguments" 2
OUT="$(bash "$IR" --src "$TMP/src" --plugin-dir "$TMP/plugin" --ij-version 2023.1.7 --out "$TMP/out-x" 2>&1)"; CODE=$?
expect_code "version without product code" 2

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
