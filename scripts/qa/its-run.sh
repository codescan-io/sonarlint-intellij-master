#!/usr/bin/env bash
# Starts the UI-test IDE with the CodeScan plugin, runs the UI tests against it, stops it and collects the results.
# Used by run-ide-scenarios.sh: inside the Docker container (with --xvfb), or on this machine (--foreground).
#
# Usage: its-run.sh --src <source tree> --plugin-dir <unpacked plugin folder> --ij-version <IC-2023.1.7|IU-2026.1.5>
#                   --out <results folder> [--tests <Gradle test filter>] [--xvfb]
# Env:   PREPARE_TIMEOUT_SEC (3600)  compile the tests and prepare the IDE; the first run downloads the IDE (1-2 GB)
#        START_TIMEOUT_SEC (600)     until the IDE's robot server answers on port 8082
#        TEST_TIMEOUT_SEC (5400)     the whole UI test run
#        STOP_TIMEOUT_SEC (90)       for the IDE to stop after SIGTERM; then it is killed
# Results in <out>: log/ (the IDE's log folder: idea.log and freeze dumps), test-results/ (JUnit XML), test-report/
#        (HTML), gradle-prepare.log, gradle-ide.log, gradle-test.log, gradle-log-check.txt, screens/ (with --xvfb)
# Exit:  0 = ./gradlew :its:test passed (the UI tests and the log check after them)
#        2 = bad usage
#        3 = the run did not happen: preparation failed, port 8082 was already in use, or the IDE did not start
#        5 = ./gradlew :its:test failed: a UI test failed, the log check failed, or the run hit TEST_TIMEOUT_SEC
# Works with macOS bash 3.2 and Linux bash.
set -u

SRC=""
PLUGIN_DIR=""
IJ_VERSION=""
OUT=""
TESTS=""
XVFB=0
usage() { sed -n '2,/^set -u/{/^set -u/!p;}' "$0" >&2; exit 2; }
need_value() { [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: $1 needs a value" >&2; usage; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --src) need_value "$@"; SRC="$2"; shift 2 ;;
    --plugin-dir) need_value "$@"; PLUGIN_DIR="$2"; shift 2 ;;
    --ij-version) need_value "$@"; IJ_VERSION="$2"; shift 2 ;;
    --out) need_value "$@"; OUT="$2"; shift 2 ;;
    --tests) need_value "$@"; TESTS="$2"; shift 2 ;;
    --xvfb) XVFB=1; shift ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done
[ -x "$SRC/gradlew" ] || { echo "error: --src must be the plugin source tree (with gradlew)" >&2; usage; }
[ -d "$PLUGIN_DIR" ] || { echo "error: --plugin-dir must be an existing folder" >&2; usage; }
case "$IJ_VERSION" in [A-Z][A-Z]-[0-9]*) ;; *) echo "error: --ij-version must look like IC-2023.1.7" >&2; usage ;; esac
[ -n "$OUT" ] || { echo "error: --out is required" >&2; usage; }
mkdir -p "$OUT" || exit 2

PREPARE_TIMEOUT_SEC="${PREPARE_TIMEOUT_SEC:-3600}"
START_TIMEOUT_SEC="${START_TIMEOUT_SEC:-600}"
TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-5400}"
STOP_TIMEOUT_SEC="${STOP_TIMEOUT_SEC:-90}"
ROBOT_URL="http://127.0.0.1:8082/"
# The IntelliJ Platform Gradle plugin names the sandbox after the IDE (IC-2023.1.7); the log folder after the task.
LOG_DIR="$SRC/its/build/idea-sandbox/$IJ_VERSION/log_runIdeForUiTests"
# No Gradle daemon and no Kotlin compile daemon: each Gradle run ends its own Java processes. Left running, the
# preparation's daemons held memory the IDE needs (IntelliJ 2026.1.5 was killed, exit 137, in a 6 GB container).
GRADLE_ARGS="--console=plain --no-daemon -Pkotlin.compiler.execution.strategy=in-process -PijVersion=$IJ_VERSION -PslPluginDirectory=$PLUGIN_DIR"
IDE_GRADLE_PID=""

# Runs a command in the background with its output in $2 and waits at most $1 seconds. Returns its exit code,
# or 124 if it had to be stopped.
run_bounded() {
  local secs=$1 log=$2 pid deadline
  shift 2
  "$@" > "$log" 2>&1 &
  pid=$!
  deadline=$(( $(date +%s) + secs ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "error: still running after $secs s, stopping it: $*" >&2
      kill -TERM "$pid" 2>/dev/null; sleep 10; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 2
  done
  wait "$pid"
}

robot_answers() { [ "$(curl --connect-timeout 2 --max-time 5 -s -o /dev/null -w '%{http_code}' "$ROBOT_URL")" = 200 ]; }

# Only the IDE started from this sandbox matches: its command line holds the sandbox log path. Never any other IDE.
stop_ide() {
  local deadline
  pkill -TERM -f "$LOG_DIR" 2>/dev/null
  deadline=$(( $(date +%s) + STOP_TIMEOUT_SEC ))
  while pgrep -f "$LOG_DIR" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "error: the IDE was still running $STOP_TIMEOUT_SEC s after SIGTERM, killing it" >&2
      pkill -KILL -f "$LOG_DIR" 2>/dev/null
      break
    fi
    sleep 1
  done
  if [ -n "$IDE_GRADLE_PID" ]; then
    deadline=$(( $(date +%s) + 60 ))
    while kill -0 "$IDE_GRADLE_PID" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
    kill -TERM "$IDE_GRADLE_PID" 2>/dev/null
  fi
}

screenshot() { [ "$XVFB" -eq 1 ] && mkdir -p "$OUT/screens" && import -window root "$OUT/screens/$1.png" 2>/dev/null; }

collect() {
  rm -rf "$OUT/log" "$OUT/test-results" "$OUT/test-report"
  [ -d "$LOG_DIR" ] && mkdir -p "$OUT/log" && cp -R "$LOG_DIR/." "$OUT/log/"
  [ -d "$SRC/its/build/test-results/test" ] && mkdir -p "$OUT/test-results" && cp -R "$SRC/its/build/test-results/test/." "$OUT/test-results/"
  [ -d "$SRC/its/build/reports/tests/test" ] && mkdir -p "$OUT/test-report" && cp -R "$SRC/its/build/reports/tests/test/." "$OUT/test-report/"
  [ -f "$SRC/its/build/reports/ide-log-check/scan.txt" ] && cp "$SRC/its/build/reports/ide-log-check/scan.txt" "$OUT/gradle-log-check.txt"
  return 0
}

finish() {
  local rc=$1
  screenshot end
  stop_ide
  collect
  exit "$rc"
}

if [ "$XVFB" -eq 1 ]; then
  export DISPLAY="${DISPLAY:-:99}"
  Xvfb "$DISPLAY" -screen 0 1920x1080x24 -nolisten tcp > "$OUT/xvfb.log" 2>&1 &
  deadline=$(( $(date +%s) + 30 ))
  until xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "error: the virtual screen did not start" >&2; exit 3; }
    sleep 1
  done
  fluxbox > "$OUT/fluxbox.log" 2>&1 &
fi

if robot_answers; then
  echo "error: something already answers on $ROBOT_URL (another UI-test IDE?); stop it first" >&2
  exit 3
fi

cd "$SRC" || exit 2
echo "preparing: compile the UI tests and the $IJ_VERSION sandbox (log: $OUT/gradle-prepare.log)"
# shellcheck disable=SC2086
run_bounded "$PREPARE_TIMEOUT_SEC" "$OUT/gradle-prepare.log" ./gradlew $GRADLE_ARGS :its:testClasses :its:prepareSandbox_runIdeForUiTests \
  || { echo "error: preparation failed; see $OUT/gradle-prepare.log" >&2; exit 3; }

# An idea.log, test results or a log check left from an earlier run in this tree must not count for this one.
rm -rf "$LOG_DIR" "$SRC/its/build/test-results/test" "$SRC/its/build/reports/tests/test" "$SRC/its/build/reports/ide-log-check"
echo "starting the $IJ_VERSION IDE (log: $OUT/gradle-ide.log)"
# shellcheck disable=SC2086
./gradlew $GRADLE_ARGS :its:runIdeForUiTests > "$OUT/gradle-ide.log" 2>&1 &
IDE_GRADLE_PID=$!
deadline=$(( $(date +%s) + START_TIMEOUT_SEC ))
until robot_answers; do
  kill -0 "$IDE_GRADLE_PID" 2>/dev/null || { echo "error: the IDE stopped before its robot server answered; see $OUT/gradle-ide.log" >&2; finish 3; }
  [ "$(date +%s)" -lt "$deadline" ] || { echo "error: the IDE's robot server did not answer within $START_TIMEOUT_SEC s" >&2; finish 3; }
  sleep 2
done
echo "IDE is up; running the UI tests (log: $OUT/gradle-test.log)"
screenshot start

if [ -n "$TESTS" ]; then
  # shellcheck disable=SC2086
  run_bounded "$TEST_TIMEOUT_SEC" "$OUT/gradle-test.log" ./gradlew $GRADLE_ARGS :its:test --tests "$TESTS"
else
  # shellcheck disable=SC2086
  run_bounded "$TEST_TIMEOUT_SEC" "$OUT/gradle-test.log" ./gradlew $GRADLE_ARGS :its:test
fi
TEST_RC=$?
[ "$TEST_RC" -eq 0 ] && finish 0
echo "error: ./gradlew :its:test failed (exit $TEST_RC); see $OUT/gradle-test.log" >&2
finish 5
