#!/usr/bin/env bash
# Tests for scan-idea-log.sh. Run: bash scripts/qa/test-scan-idea-log.sh
# Works with macOS bash 3.2 and Linux bash.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/scan-idea-log.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scan-idea-log-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
OUT=""
CODE=0

run_scan() {
  OUT="$(bash "$SCAN" "$@" 2>&1)"
  CODE=$?
}

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
expect_no_out() {
  if printf '%s\n' "$OUT" | grep -F -q -- "$2"; then not_ok "$1: output lacks '$2'" "present"; else ok "$1: output lacks '$2'"; fi
}

TS='2026-11-13 10:00:00,123 [  12345]'

f="$TMP/slow.log"
echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc." > "$f"
run_scan "$f"
expect_code "slow-op" 1
expect_out "slow-op" "Slow operations are prohibited on EDT: 1"
expect_out "slow-op" "Total: 1"

f="$TMP/empty.log"
: > "$f"
run_scan "$f"
expect_code "empty" 0
expect_out "empty" "Total: 0"

f="$TMP/read.log"
echo "$TS  ERROR - #c.i.o.a.i.ApplicationImpl - Read access is allowed from inside read-action only (see Application.runReadAction())" > "$f"
run_scan "$f"
expect_code "read-access" 1
expect_out "read-access" "Read access is allowed from inside read-action: 1"

f="$TMP/edt.log"
echo "$TS  ERROR - #c.i.o.a.i.ApplicationImpl - Access is allowed from Event Dispatch Thread (EDT) only" > "$f"
run_scan "$f"
expect_code "edt-access" 1
expect_out "edt-access" "Access is allowed from Event Dispatch Thread: 1"

f="$TMP/freeze.log"
echo "$TS   INFO - #c.i.d.PerformanceWatcherImpl - UI was frozen for 12000ms, details saved to /tmp/threadDumps-freeze" > "$f"
run_scan "$f"
expect_code "ui-freeze" 1
expect_out "ui-freeze" "UI was frozen: 1"

f="$TMP/sonarlint-error.log"
echo "$TS  ERROR - #org.sonarlint.intellij.analysis.SonarLintAnalyzer - Analysis failed" > "$f"
run_scan "$f"
expect_code "sonarlint-error" 1
expect_out "sonarlint-error" "ERROR from org.sonarlint logger: 1"

f="$TMP/other-error.log"
{
  echo "$TS  ERROR - #c.i.o.v.VcsInitialization - Something unrelated broke"
  echo "$TS   WARN - #org.sonarlint.intellij.core.BackendService - only a warning"
  echo "$TS   INFO - #org.sonarlint.intellij.SonarLintPlugin - ERROR word inside an info message"
} > "$f"
run_scan "$f"
expect_code "other-error" 0
expect_out "other-error" "Total: 0"

f="$TMP/context.log"
{
  echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See javadoc."
  i=1
  while [ $i -le 16 ]; do echo "	at frame.number$i(Frame.java:$i)"; i=$((i + 1)); done
} > "$f"
run_scan "$f"
expect_out "context" "frame.number1("
expect_out "context" "frame.number15("
expect_no_out "context" "frame.number16("

f="$TMP/many.log"
{
  echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See javadoc."
  echo "	at a.b(C.java:1)"
  echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See javadoc."
  echo "$TS   INFO - #c.i.d.PerformanceWatcherImpl - UI was frozen for 5000ms"
} > "$f"
run_scan "$f"
expect_code "many" 1
expect_out "many" "Slow operations are prohibited on EDT: 2"
expect_out "many" "UI was frozen: 1"
expect_out "many" "Total: 3"

# IntelliJ 2026.1 writes Logger.error() entries with level SEVERE instead of ERROR.
f="$TMP/severe.log"
echo "$TS SEVERE - #org.sonarlint.intellij.core.BackendService - Backend failed" > "$f"
run_scan "$f"
expect_code "severe-sonarlint" 1
expect_out "severe-sonarlint" "ERROR from org.sonarlint logger: 1"

f="$TMP/core-error.log"
echo "$TS SEVERE - org.sonarsource.sonarlint.core.analysis.AnalysisEngine - Analysis engine failed" > "$f"
run_scan "$f"
expect_code "core-logger" 1
expect_out "core-logger" "ERROR from org.sonarlint logger: 1"

# The message is repeated on the Throwable line under the header: one entry, one count.
f="$TMP/one-entry.log"
{
  echo "$TS SEVERE - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
  echo "java.lang.Throwable: Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
  echo "	at com.intellij.openapi.diagnostic.Logger.error(Logger.java:375)"
  echo "	at org.sonarlint.intellij.Foo.bar(Foo.kt:10)"
  echo "$TS   INFO - #c.i.Other - next entry"
} > "$f"
run_scan "$f"
expect_code "one-entry" 1
expect_out "one-entry" "Slow operations are prohibited on EDT: 1"
expect_out "one-entry" "ERROR with org.sonarlint in its stack trace: 0"
expect_out "one-entry" "Total: 1"

# Exceptions thrown by plugin code are often logged by a platform logger.
f="$TMP/platform-logger.log"
{
  echo "$TS SEVERE - #c.i.u.m.i.MessageBusImpl - org.springframework.beans.factory.UnsatisfiedDependencyException: Error creating bean"
  echo "java.util.concurrent.ExecutionException: org.springframework.beans.factory.UnsatisfiedDependencyException"
  echo "	at java.base/java.util.concurrent.CompletableFuture.get(CompletableFuture.java:2096)"
  echo "	at org.sonarlint.intellij.core.BackendService.getInitializedBackend(BackendService.kt:97)"
  echo "$TS SEVERE - #c.i.u.m.i.MessageBusImpl - unrelated platform error"
  echo "	at com.intellij.Foo.bar(Foo.java:1)"
} > "$f"
run_scan "$f"
expect_code "platform-logger" 1
expect_out "platform-logger" "ERROR with org.sonarlint in its stack trace: 1"
expect_out "platform-logger" "Total: 1"

f="$TMP/tops.log"
slow_entry() {
  echo "$TS SEVERE - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See javadoc."
  echo "java.lang.Throwable: Slow operations are prohibited on EDT. See javadoc."
  echo "	at com.intellij.openapi.diagnostic.Logger.error(Logger.java:375)"
  echo "	at com.intellij.util.SlowOperations.assertSlowOperationsAreAllowed(SlowOperations.java:117)"
  echo "	at com.intellij.vfs.Slow.call(Slow.java:5)"
  echo "	at org.sonarlint.intellij.$1(X.kt:1)"
  echo "	at org.sonarlint.intellij.Caller.run(Caller.kt:2)"
}
{
  slow_entry "A.first"
  slow_entry "A.first"
  slow_entry "B.second"
  echo "$TS   INFO - #c.i.d.PerformanceWatcherImpl - UI was frozen for 5000ms"
} > "$f"
run_scan "$f"
expect_out "tops" "2 x [Slow operations are prohibited on EDT]"
expect_out "tops" "1 x [Slow operations are prohibited on EDT]"
expect_out "tops" "com.intellij.vfs.Slow.call(Slow.java:5)"
expect_out "tops" "org.sonarlint.intellij.A.first(X.kt:1)"
expect_out "tops" "1 x [UI was frozen]"

run_scan "$TMP/does-not-exist.log"
expect_code "missing-file" 2
run_scan
expect_code "no-argument" 2

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
