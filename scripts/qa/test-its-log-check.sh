#!/usr/bin/env bash
# Tests the Gradle wiring of the UI-test log check (:its:checkIdeLog, run after :its:test).
# Run from anywhere with a JDK 17 on JAVA_HOME: bash scripts/qa/test-its-log-check.sh
# Slow (9 Gradle runs, up to a minute each with a warm Gradle cache). Works with macOS bash 3.2 and Linux bash.
# It moves the default UI-test sandbox's IDE log folder aside (to <folder>-previous), as the start of a UI test run does.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/its-log-check-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
OUT=""
CODE=0

run_gradle() {
  OUT="$(cd "$ROOT" && ./gradlew --console=plain "$@" 2>&1)"
  CODE=$?
}
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
not_ok() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1"
  echo "       $2"
  echo "$OUT" | tail -40 | sed 's/^/       | /'
}
expect_code() {
  if [ "$CODE" -eq "$2" ]; then ok "$1: Gradle exit $2"; else not_ok "$1: Gradle exit $2" "got exit $CODE"; fi
}
expect_no_out() {
  if printf '%s\n' "$OUT" | grep -F -q -- "$2"; then not_ok "$1: output lacks '$2'" "present"; else ok "$1: output lacks '$2'"; fi
}
expect_out() {
  if printf '%s\n' "$OUT" | grep -F -q -- "$2"; then ok "$1: output has '$2'"; else not_ok "$1: output has '$2'" "missing"; fi
}

TS='2026-11-13 10:00:00,123 [  12345]'
mkdir -p "$TMP/slow" "$TMP/clean"
{
  echo "$TS   INFO - #c.i.i.StartupUtil - IDE STARTED"
  echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
  printf '\tat com.intellij.util.SlowOperations.assertSlowOperationsAreAllowed(SlowOperations.java:114)\n'
  printf '\tat org.sonarlint.intellij.config.project.SonarLintProjectConfigurable.reset(SonarLintProjectConfigurable.java:125)\n'
} > "$TMP/slow/idea.log"
echo "$TS   INFO - #c.i.i.StartupUtil - IDE STARTED" > "$TMP/clean/idea.log"
# A slow operation with no stack trace: the log check cannot tell whether it is CodeScan's.
mkdir -p "$TMP/unknown"
echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc." > "$TMP/unknown/idea.log"

# The failure must be the log check's own (scan-ide-logs.sh exit 1), not any other Gradle failure.
run_gradle :its:checkIdeLog -PideLogDir="$TMP/slow"
expect_code "known slow operation" 1
expect_out "known slow operation" "Execution failed for task ':its:checkIdeLog'"
expect_out "known slow operation" "finished with non-zero exit value 1"
expect_out "known slow operation" "CodeScan total: 1"

run_gradle :its:checkIdeLog -PideLogDir="$TMP/unknown"
expect_code "unknown hit" 1
expect_out "unknown hit" "Execution failed for task ':its:checkIdeLog'"
expect_out "unknown hit" "finished with non-zero exit value 6"

run_gradle :its:checkIdeLog -PideLogDir="$TMP/clean"
if [ "$CODE" -eq 0 ]; then ok "clean log: Gradle passes"; else not_ok "clean log: Gradle passes" "Gradle failed (exit $CODE)"; fi

# The check must run after the UI tests, also when they fail.
run_gradle :its:test --dry-run
expect_out "after :its:test" ":its:checkIdeLog SKIPPED"

# Only tests that need no IDE ran (no UI test class was loaded): there is no IDE log to read, so the check is skipped
# with a message, not failed. A marker left by an earlier run must not count.
MARKER="$ROOT/its/build/its-ui-test-ran.txt"
mkdir -p "$(dirname "$MARKER")" && echo "left by an earlier run" > "$MARKER"
run_gradle :its:test --tests 'org.sonarlint.intellij.its.utils.IdeErrorsTest'
expect_code "IDE-free tests only" 0
expect_out "IDE-free tests only" "IDE log check skipped"
expect_no_out "IDE-free tests only" "non-zero exit value"

# A UI test run first moves the sandbox's old IDE log folder aside, so an earlier run's log is never checked again.
# The log folder must exist again afterwards: the 2026.1.5 IDE writes no idea.log when its log folder is missing.
SANDBOX_LOG="$ROOT/its/build/idea-sandbox/IC-2023.1.7/log_runIdeForUiTests"
empty_log_folder() { [ -d "$SANDBOX_LOG" ] && [ -z "$(ls -A "$SANDBOX_LOG")" ]; }
rm -rf "$SANDBOX_LOG-previous"
mkdir -p "$SANDBOX_LOG" && echo "old run $$" > "$SANDBOX_LOG/idea.log"
run_gradle :its:rotateIdeLog
expect_code "rotate the IDE log" 0
if grep -q "old run $$" "$SANDBOX_LOG-previous/idea.log" 2>/dev/null; then
  ok "rotate the IDE log: moved to log_runIdeForUiTests-previous"
else
  not_ok "rotate the IDE log: moved to log_runIdeForUiTests-previous" "$(ls -d "$SANDBOX_LOG"* 2>&1)"
fi
empty_log_folder && ok "rotate the IDE log: an empty log folder is left for the IDE" \
  || not_ok "rotate the IDE log: an empty log folder is left for the IDE" "$(ls -la "$SANDBOX_LOG" 2>&1)"
# prepareSandbox creates an empty log folder just before; moving it would replace the real earlier log.
run_gradle :its:rotateIdeLog
expect_code "rotate an empty log folder" 0
grep -q "old run $$" "$SANDBOX_LOG-previous/idea.log" 2>/dev/null && ok "rotate an empty log folder: the earlier log is kept" \
  || not_ok "rotate an empty log folder: the earlier log is kept" "$(ls -la "$SANDBOX_LOG-previous" 2>&1)"
empty_log_folder && ok "rotate an empty log folder: the log folder is still there" \
  || not_ok "rotate an empty log folder: the log folder is still there" "$(ls -la "$SANDBOX_LOG" 2>&1)"
rm -rf "$SANDBOX_LOG"
run_gradle :its:rotateIdeLog
expect_code "rotate with no log folder" 0
empty_log_folder && ok "rotate with no log folder: an empty log folder is created" \
  || not_ok "rotate with no log folder: an empty log folder is created" "$(ls -la "$SANDBOX_LOG" 2>&1)"
run_gradle :its:runIdeForUiTests --dry-run
expect_out "before the UI-test IDE starts" ":its:rotateIdeLog SKIPPED"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
