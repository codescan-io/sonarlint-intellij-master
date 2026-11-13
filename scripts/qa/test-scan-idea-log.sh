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
run_scan --strict "$f"
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
run_scan --strict "$f"
expect_code "read-access" 1
expect_out "read-access" "Read access is allowed from inside read-action: 1"

f="$TMP/edt.log"
echo "$TS  ERROR - #c.i.o.a.i.ApplicationImpl - Access is allowed from Event Dispatch Thread (EDT) only" > "$f"
run_scan --strict "$f"
expect_code "edt-access" 1
expect_out "edt-access" "Access is allowed from Event Dispatch Thread: 1"

f="$TMP/freeze.log"
echo "$TS   INFO - #c.i.d.PerformanceWatcherImpl - UI was frozen for 12000ms, details saved to /tmp/threadDumps-freeze" > "$f"
run_scan --strict "$f"
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
run_scan --strict "$f"
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

# ---- CodeScan / other / unknown split -------------------------------------------------

# expect_split <name> <pattern text> <codescan> <other> <unknown>: checks the split line under a pattern line.
expect_split() {
  local got
  got="$(printf '%s\n' "$OUT" | awk -v p="  $2: " 'index($0, p) == 1 { getline; print; exit }' | sed 's/^ *//')"
  if [ "$got" = "CodeScan: $3  other: $4  unknown: $5" ]; then
    ok "$1: split $3/$4/$5"
  else
    not_ok "$1: split $3/$4/$5" "got '$got'"
  fi
}

# The TypeScript plugin trips the EDT check. No CodeScan frame anywhere: other.
f="$TMP/ts-edt.log"
{
  echo "$TS SEVERE - #c.i.j.n.l.n.NodeModulesDirectoryManager - Access is allowed from Event Dispatch Thread (EDT) only"
  echo "java.lang.Throwable: Access is allowed from Event Dispatch Thread (EDT) only"
  echo "	at com.intellij.openapi.diagnostic.Logger.error(Logger.java:375)"
  echo "	at com.intellij.openapi.application.impl.ApplicationImpl.assertIsDispatchThread(ApplicationImpl.java:1)"
  echo "	at com.intellij.javascript.nodejs.library.node_modules.NodeModulesDirectoryManager.getNodeModulesDirectories(NodeModulesDirectoryManager.java:5)"
  echo "	at com.intellij.lang.typescript.compiler.TypeScriptMessageBus.onChange(TypeScriptMessageBus.java:9)"
} > "$f"
run_scan "$f"
expect_split "ts-edt" "Access is allowed from Event Dispatch Thread" 0 1 0
expect_out "ts-edt" "CodeScan total: 0"
expect_code "ts-edt default" 0
expect_out "ts-edt default" "not from CodeScan"
run_scan --strict "$f"
expect_code "ts-edt strict" 1
expect_split "ts-edt strict" "Access is allowed from Event Dispatch Thread" 0 1 0

# A CodeScan frame deep in the stack makes the hit CodeScan.
f="$TMP/read-codescan.log"
{
  echo "$TS SEVERE - #c.i.o.a.i.ApplicationImpl - Read access is allowed from inside read-action only (see Application.runReadAction())"
  echo "java.lang.Throwable: Read access is allowed from inside read-action only"
  echo "	at com.intellij.openapi.diagnostic.Logger.error(Logger.java:375)"
  echo "	at com.intellij.psi.impl.PsiManagerImpl.findFile(PsiManagerImpl.java:3)"
  echo "	at org.sonarlint.intellij.finding.LiveFinding.isValid(LiveFinding.java:91)"
} > "$f"
run_scan "$f"
expect_code "read-codescan" 1
expect_split "read-codescan" "Read access is allowed from inside read-action" 1 0 0
expect_out "read-codescan" "CodeScan total: 1"
expect_out "read-codescan" "org.sonarlint.intellij.finding.LiveFinding.isValid(LiveFinding.java:91)"

# CodeScan as the logger name counts even without a stack.
f="$TMP/logger-codescan.log"
echo "$TS SEVERE - #org.sonarlint.intellij.editor.Foo - Read access is allowed from inside read-action only" > "$f"
run_scan "$f"
expect_split "logger-codescan" "Read access is allowed from inside read-action" 1 0 0

# "Suppressed a frequent exception" repeats an earlier error and has no stack: unknown.
f="$TMP/suppressed.log"
echo "$TS  WARN - #c.i.o.a.i.ApplicationImpl - Suppressed a frequent exception logged for the 3rd time: Read access is allowed from inside read-action only" > "$f"
run_scan "$f"
expect_split "suppressed" "Read access is allowed from inside read-action" 0 0 1
expect_code "suppressed default" 0
expect_out "suppressed default" "CodeScan total: 0"
run_scan --strict "$f"
expect_code "suppressed strict" 1

# Mixed log: the three classes add up, and the existing Total line still counts every hit.
f="$TMP/mixed.log"
{
  cat "$TMP/ts-edt.log"
  cat "$TMP/read-codescan.log"
  cat "$TMP/suppressed.log"
  echo "$TS SEVERE - #org.sonarlint.intellij.core.BackendService - Backend failed"
} > "$f"
run_scan "$f"
expect_code "mixed" 1
expect_out "mixed" "Total: 4"
expect_out "mixed" "CodeScan total: 2"
expect_split "mixed read" "Read access is allowed from inside read-action" 1 0 1
expect_split "mixed logger" "ERROR from org.sonarlint logger" 1 0 0

# The CodeScan frame can be in a "Caused by:" block; the stack top comes from that block.
f="$TMP/caused-by.log"
{
  echo "$TS SEVERE - #c.i.o.a.i.ExceptionsKt - Unhandled exception in EDT"
  echo "com.intellij.openapi.diagnostic.UnhandledException: Read access is allowed from inside read-action only"
  echo "Current thread: Thread[#48,AWT-EventQueue-0,6,main]"
  echo "	at com.intellij.openapi.application.impl.ExceptionsKt.processUnhandledException(exceptions.kt:55)"
  echo "	at com.intellij.ide.IdeEventQueue.processException(IdeEventQueue.kt:465)"
  echo "Caused by: com.intellij.openapi.diagnostic.RuntimeExceptionWithAttachments: Read access is allowed from inside read-action only"
  echo "Current thread: Thread[#48,AWT-EventQueue-0,6,main]"
  echo "	at com.intellij.psi.impl.PsiFileImpl.isValid(PsiFileImpl.java:232)"
  echo "	at org.sonarlint.intellij.finding.LiveFinding.isValid(LiveFinding.java:91)"
} > "$f"
run_scan "$f"
expect_split "caused-by" "Read access is allowed from inside read-action" 1 0 0
expect_out "caused-by" "1 x [Read access is allowed from inside read-action] CodeScan"
expect_out "caused-by" "      org.sonarlint.intellij.finding.LiveFinding.isValid(LiveFinding.java:91)"

# The stack-top key names the class, also when there is no stack.
run_scan "$TMP/suppressed.log"
expect_out "no-stack key" "1 x [Read access is allowed from inside read-action] unknown"
expect_out "no-stack key" "(no stack trace)"

# ---- Freeze dumps ----------------------------------------------------------------------

DUMPS="$TMP/logdir"
mkdir -p "$DUMPS"
make_dump() { # <folder name> <file name> <thread to put first> <extra frame in that thread> <other thread> <frame in other thread>
  mkdir -p "$DUMPS/$1"
  {
    echo "\"$3\" prio=0 tid=0x0 nid=0x0 waiting on condition"
    echo "     java.lang.Thread.State: TIMED_WAITING"
    echo "	at java.base@25.0.4/jdk.internal.misc.Unsafe.park(Native Method)"
    echo "	at $4"
    echo ""
    echo "\"$5\" prio=0 tid=0x0 nid=0x0 runnable"
    echo "	at $6"
    echo ""
  } > "$DUMPS/$1/$2"
}
# A: the UI thread runs CodeScan code.
make_dump "threadDumps-freeze-20261113-110016-IU-261.1-9sec" "threadDump-20261113-110016.txt" \
  "AWT-EventQueue-0" "org.sonarlint.intellij.ui.FindingDetailsPanel.show(FindingDetailsPanel.kt:75)" \
  "DefaultDispatcher-worker-1" "com.intellij.Other.run(Other.java:1)"
# B: CodeScan only in a background thread.
make_dump "threadDumps-freeze-20261113-120016-IU-261.1-9sec" "threadDump-20261113-120016.txt" \
  "AWT-EventQueue-0" "com.intellij.ide.IdeEventQueue.run(IdeEventQueue.java:1)" \
  "Thread-7" 'org.sonarlint.intellij.trigger.EditorChangeTrigger$EventWatcher.run(EditorChangeTrigger.java:2)'
# C: empty folder.
mkdir -p "$DUMPS/threadDumps-freeze-20261113-130016-IU-261.1-9sec"
# D and E: two folders 4 seconds apart, D is CodeScan on the UI thread, E is not.
make_dump "threadDumps-freeze-20261113-150010-IU-261.1-9sec" "threadDump-20261113-150010.txt" \
  "AWT-EventQueue-0" "org.sonarlint.intellij.ui.FindingDetailsPanel.show(FindingDetailsPanel.kt:75)" \
  "Thread-7" "com.intellij.Other.run(Other.java:1)"
make_dump "threadDumps-freeze-20261113-150014-IU-261.1-9sec" "threadDump-20261113-150014.txt" \
  "AWT-EventQueue-0" "com.intellij.ide.IdeEventQueue.run(IdeEventQueue.java:1)" \
  "Thread-7" "com.intellij.Other.run(Other.java:1)"
# F: a folder with a report but no thread dump file, and a thread dump with no UI thread block.
mkdir -p "$DUMPS/threadDumps-freeze-20261113-160016-IU-261.1-9sec"
echo "report" > "$DUMPS/threadDumps-freeze-20261113-160016-IU-261.1-9sec/report.txt"
make_dump "threadDumps-freeze-20261113-170016-IU-261.1-9sec" "threadDump-20261113-170016.txt" \
  "Thread-1" "org.sonarlint.intellij.Foo.run(Foo.java:1)" "Thread-2" "com.intellij.Other.run(Other.java:1)"
# Folders that are not freeze dumps must be ignored.
make_dump "threadDumps-Dispatchers.IO-20261113-180016-IU-261.1" "threadDump-20261113-180016.txt" \
  "AWT-EventQueue-0" "org.sonarlint.intellij.ui.FindingDetailsPanel.show(FindingDetailsPanel.kt:75)" \
  "Thread-2" "com.intellij.Other.run(Other.java:1)"

freeze_log() { # <time of day hh:mm:ss> [path suffix]
  f="$TMP/freeze-$1.log"
  f="$(echo "$f" | tr ':' '-')"
  if [ -n "${2:-}" ]; then
    echo "2026-11-13 $1,500 [ 1000]  WARN - #c.i.d.PerformanceWatcherImpl - UI was frozen for 9000ms, details saved to $DUMPS/$2" > "$f"
  else
    echo "2026-11-13 $1,500 [ 1000]  WARN - #c.i.d.PerformanceWatcherImpl - UI was frozen for 9000ms" > "$f"
  fi
  echo "$f"
}
FZ="UI was frozen"

# Matched by the folder name in the log line.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 11:00:25 threadDumps-freeze-20261113-110016-IU-261.1-9sec)"
expect_split "freeze named A" "$FZ" 1 0 0
expect_code "freeze named A" 1
expect_out "freeze named A" "CodeScan total: 1"

# Matched by time: log at 12:00:18, folder at 12:00:16.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 12:00:18)"
expect_split "freeze by time B" "$FZ" 0 1 0
expect_code "freeze by time B" 0

# CodeScan appears in the UI thread: matched by time too.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 11:00:17)"
expect_split "freeze by time A" "$FZ" 1 0 0

# The closest folder wins: 15:00:13 is 3 s from D (CodeScan) and 1 s from E (other).
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 15:00:13)"
expect_split "freeze closest" "$FZ" 0 1 0
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 15:00:11)"
expect_split "freeze closest 2" "$FZ" 1 0 0

# Empty folder, no folder near, folder with only a report, thread dump without a UI thread: unknown.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 13:00:18)"
expect_split "freeze empty folder" "$FZ" 0 0 1
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 14:00:00)"
expect_split "freeze no dump" "$FZ" 0 0 1
expect_code "freeze no dump" 0
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 16:00:18)"
expect_split "freeze report only" "$FZ" 0 0 1
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 17:00:18)"
expect_split "freeze no UI block" "$FZ" 0 0 1

# Further than the window (5 s): unknown, even though a folder exists.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 11:00:30)"
expect_split "freeze out of window" "$FZ" 0 0 1

# A named folder that is missing is unknown. The time match is not used for it.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 11:00:18 threadDumps-freeze-20261113-110018-IU-261.1-gone)"
expect_split "freeze named but missing" "$FZ" 0 0 1

# Not a freeze folder: ignored.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 18:00:18)"
expect_split "freeze other folder kind" "$FZ" 0 0 1

# Without --freeze-dumps a freeze is unknown.
run_scan "$(freeze_log 11:00:25 threadDumps-freeze-20261113-110016-IU-261.1-9sec)"
expect_split "freeze without flag" "$FZ" 0 0 1

# Bad usage.
run_scan --freeze-dumps "$TMP/no-such-dir" "$TMP/ts-edt.log"
expect_code "freeze-dumps missing dir" 2
run_scan "$TMP/ts-edt.log" --freeze-dumps
expect_code "freeze-dumps no value" 2
run_scan --bogus "$TMP/ts-edt.log"
expect_code "unknown flag" 2
run_scan "$TMP/ts-edt.log" "$TMP/mixed.log"
expect_code "two logs" 2

# Exit codes, summary lines on a clean log.
f="$TMP/clean.log"
echo "$TS   INFO - #c.i.Other - nothing here" > "$f"
run_scan "$f"
expect_code "clean default" 0
expect_out "clean default" "CodeScan total: 0"
expect_no_out "clean default" "not from CodeScan"
run_scan --strict "$f"
expect_code "clean strict" 0

run_scan "$TMP/does-not-exist.log"
expect_code "missing-file" 2
run_scan
expect_code "no-argument" 2

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
