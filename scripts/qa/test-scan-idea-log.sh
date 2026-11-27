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
run_scan "$f"
expect_code "slow-op default" 0
expect_split_early() { printf '%s\n' "$OUT" | grep -A1 '^  Slow operations are prohibited on EDT: 1' | grep -q 'CodeScan: 0  other: 0  unknown: 1'; }
if expect_split_early; then ok "slow-op default: unknown 1"; else not_ok "slow-op default: unknown 1" "split not 0/0/1"; fi

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

# Mixed log: the three classes add up, and the existing Total line still counts every hit. The repeat comes before
# the full read-access entry, so there is nothing to match it to and it stays unknown.
f="$TMP/mixed.log"
{
  cat "$TMP/ts-edt.log"
  cat "$TMP/suppressed.log"
  cat "$TMP/read-codescan.log"
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

# ---- "Suppressed a frequent exception" repeats -----------------------------------------
# IntelliJ counts repeats by a hash of the whole stack trace and writes the first one in full, so a repeat takes the
# group of the earlier full entries of its pattern from the same logger, when they all have one group.

# full_slow <logger> <frame>: a slow operation on the UI thread with a stack, as 2026.1.5 writes it.
full_slow() {
  echo "$TS SEVERE - #$1 - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
  echo "java.lang.Throwable: Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
  echo "	at com.intellij.util.SlowOperations.assertSlowOperationsAreAllowed(SlowOperations.java:128)"
  echo "	at $2"
}
repeat_slow() {
  echo "$TS   WARN - #$1 - Suppressed a frequent exception logged for the 2nd time: Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
}
IDE_FRAME="com.intellij.openapi.vfs.newvfs.persistent.FSRecordsImpl.update(FSRecordsImpl.java:789)"
CS_FRAME="org.sonarlint.intellij.core.BackendService.x(BackendService.kt:1)"

# Every earlier full entry is the IDE's: the repeat is other, and the check passes.
f="$TMP/repeat-other.log"
{ full_slow c.i.u.SlowOperations "$IDE_FRAME"; full_slow c.i.u.SlowOperations "$IDE_FRAME"; repeat_slow c.i.u.SlowOperations; } > "$f"
run_scan "$f"
expect_split "repeat of other" "Slow operations are prohibited on EDT" 0 3 0
expect_code "repeat of other" 0
expect_out "repeat of other" "Repeats matched to an earlier full entry: 1"
expect_out "repeat of other" "repeat: every earlier full entry of this kind from c.i.u.SlowOperations in this log is other"
expect_out "repeat of other" "1 x [Slow operations are prohibited on EDT] other"

# Every earlier full entry is CodeScan's: the repeat is CodeScan.
f="$TMP/repeat-codescan.log"
{ full_slow c.i.u.SlowOperations "$CS_FRAME"; repeat_slow c.i.u.SlowOperations; } > "$f"
run_scan "$f"
expect_split "repeat of CodeScan" "Slow operations are prohibited on EDT" 2 0 0
expect_code "repeat of CodeScan" 1

# Earlier full entries of both groups: the repeat could be either, so it stays unknown.
f="$TMP/repeat-both.log"
{ full_slow c.i.u.SlowOperations "$IDE_FRAME"; full_slow c.i.u.SlowOperations "$CS_FRAME"; repeat_slow c.i.u.SlowOperations; } > "$f"
run_scan "$f"
expect_split "repeat, both groups before" "Slow operations are prohibited on EDT" 1 1 1
expect_out "repeat, both groups before" "Repeats matched to an earlier full entry: 0"

# A full entry from another logger does not count.
f="$TMP/repeat-logger.log"
{ full_slow c.i.o.OtherLogger "$IDE_FRAME"; repeat_slow c.i.u.SlowOperations; } > "$f"
run_scan "$f"
expect_split "repeat, other logger before" "Slow operations are prohibited on EDT" 0 1 1

# A full entry of another pattern does not count.
f="$TMP/repeat-pattern.log"
{ cat "$TMP/read-codescan.log"; repeat_slow c.i.o.a.i.ApplicationImpl; } > "$f"
run_scan "$f"
expect_split "repeat, other pattern before" "Slow operations are prohibited on EDT" 0 0 1

# A full entry that IntelliJ blames on CodeScan (blame line within 100 ms) counts as CodeScan for the repeat.
f="$TMP/repeat-blamed.log"
{
  full_slow c.i.u.SlowOperations "$IDE_FRAME"
  echo "$TS SEVERE - #c.i.u.SlowOperations - Plugin to blame: CodeScan version: 8.0.0-CODESCAN"
  repeat_slow c.i.u.SlowOperations
} > "$f"
run_scan "$f"
expect_split "repeat of a blamed entry" "Slow operations are prohibited on EDT" 2 0 0

# A WARN with no stack that is not a repeat stays unknown, even after full entries.
f="$TMP/repeat-not.log"
{ full_slow c.i.u.SlowOperations "$IDE_FRAME"; echo "$TS   WARN - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See javadoc."; } > "$f"
run_scan "$f"
expect_split "no stack, not a repeat" "Slow operations are prohibited on EDT" 0 1 1

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
# B: CodeScan only in a background thread whose state is not known (no State line): not enough to blame CodeScan.
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
# G and H: a busy UI thread. Real IntelliJ dumps put a blank line between the State line and the frames.
make_dump_runnable() { # <folder name> <file name> <frame on the UI thread>
  mkdir -p "$DUMPS/$1"
  {
    echo '"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 runnable'
    echo "     java.lang.Thread.State: RUNNABLE"
    echo ""
    echo "	at $3"
    echo "	at java.desktop/java.awt.EventQueue.dispatchEvent(EventQueue.java:1)"
    echo ""
    echo '"main" prio=0 tid=0x0 nid=0x0 waiting on condition'
    echo "     java.lang.Thread.State: WAITING"
    echo "	at java.base/java.lang.Object.wait(Native Method)"
    echo ""
  } > "$DUMPS/$1/$2"
}
make_dump_runnable "threadDumps-freeze-20261113-190016-IU-261.1-9sec" "threadDump-20261113-190016.txt" \
  "org.sonarlint.intellij.ui.SomePanel.paint(SomePanel.java:10)"
make_dump_runnable "threadDumps-freeze-20261113-200016-IU-261.1-9sec" "threadDump-20261113-200016.txt" \
  "com.intellij.ui.Other.paint(Other.java:10)"
# State-aware dumps. make_states <folder> <edt state> <edt frame or -> <thread state> <frame in the other thread>
make_states() {
  mkdir -p "$DUMPS/$1"
  {
    echo '"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 waiting on condition'
    echo "     java.lang.Thread.State: $2"
    echo ""
    if [ "$3" != "-" ]; then echo "	at $3"; fi
    echo ""
    echo '"SonarLint analysis" prio=0 tid=0x0 nid=0x0 runnable'
    echo "     java.lang.Thread.State: $4"
    echo "	at $5"
    echo ""
  } > "$DUMPS/$1/threadDump-20261113-000000.txt"
}
LOCK="com.intellij.openapi.application.impl.ApplicationImpl.runWriteAction(ApplicationImpl.java:1)"
CSF="org.sonarlint.intellij.analysis.Analysis.run(Analysis.java:1)"
OTHERF="com.intellij.Other.run(Other.java:1)"
make_states "threadDumps-freeze-20261113-210000-IU-261.1-9sec" WAITING "$LOCK" RUNNABLE "$CSF"
make_states "threadDumps-freeze-20261113-210100-IU-261.1-9sec" TIMED_WAITING "$LOCK" WAITING "$CSF"
make_states "threadDumps-freeze-20261113-210200-IU-261.1-9sec" BLOCKED "$LOCK" RUNNABLE "$OTHERF"
make_states "threadDumps-freeze-20261113-210300-IU-261.1-9sec" BLOCKED "$LOCK" RUNNABLE "$CSF"
make_states "threadDumps-freeze-20261113-210400-IU-261.1-9sec" RUNNABLE "-" RUNNABLE "$CSF"
make_states "threadDumps-freeze-20261113-210500-IU-261.1-9sec" RUNNABLE "$LOCK" RUNNABLE "$CSF"
make_states "threadDumps-freeze-20261113-210600-IU-261.1-9sec" BLOCKED "$LOCK" BLOCKED "org.sonarsource.sonarlint.core.Engine.run(Engine.java:1)"
make_states "threadDumps-freeze-20261113-210700-IU-261.1-9sec" "WAITING (parking)" "$LOCK" "RUNNABLE" "$CSF"
# Folders that are not freeze dumps must be ignored.
make_dump "threadDumps-Dispatchers.IO-20261113-180016-IU-261.1" "threadDump-20261113-180016.txt" \
  "AWT-EventQueue-0" "org.sonarlint.intellij.ui.FindingDetailsPanel.show(FindingDetailsPanel.kt:75)" \
  "Thread-2" "com.intellij.Other.run(Other.java:1)"

# <freeze start hh:mm:ss> [folder name]: a log with one freeze line, written at the start plus the 9000 ms length.
# Without a folder name the line has no "details saved to" part.
freeze_log() {
  local h m sec end
  h=${1%%:*}; m=${1#*:}; m=${m%%:*}; sec=${1##*:}
  end=$((10#$h * 3600 + 10#$m * 60 + 10#$sec + 9))
  end="$(printf '%02d:%02d:%02d' $((end / 3600)) $((end % 3600 / 60)) $((end % 60)))"
  f="$(echo "$TMP/freeze-$1.log" | tr ':' '-')"
  if [ -n "${2:-}" ]; then
    echo "2026-11-13 $end,500 [ 1000]  WARN - #c.i.d.PerformanceWatcherImpl - UI was frozen for 9000ms, details saved to $DUMPS/$2" > "$f"
  else
    echo "2026-11-13 $end,500 [ 1000]  WARN - #c.i.d.PerformanceWatcherImpl - UI was frozen for 9000ms" > "$f"
  fi
  echo "$f"
}
FZ="UI was frozen"

# Matched by the folder name in the log line.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 11:00:25 threadDumps-freeze-20261113-110016-IU-261.1-9sec)"
expect_split "freeze named A" "$FZ" 1 0 0
expect_code "freeze named A" 1
expect_out "freeze named A" "CodeScan total: 1"

# The time of the line is no longer used to find a folder: a freeze line with no folder name is unknown,
# also when a folder exists at the same time (these lines have no "details saved to").
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 12:00:18)"
expect_split "freeze without folder name B" "$FZ" 0 0 1
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 11:00:17)"
expect_split "freeze without folder name A" "$FZ" 0 0 1
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 15:00:13)"
expect_split "freeze without folder name D/E" "$FZ" 0 0 1
expect_code "freeze without folder name" 0

# CodeScan on a background thread that is not running (no State line) is not enough: unknown, not other.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 12:00:18 threadDumps-freeze-20261113-120016-IU-261.1-9sec)"
expect_split "freeze B named" "$FZ" 0 0 1

# D is CodeScan on the UI thread, E has no CodeScan frame anywhere.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 15:00:19 threadDumps-freeze-20261113-150010-IU-261.1-9sec)"
expect_split "freeze D named" "$FZ" 1 0 0
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 15:00:19 threadDumps-freeze-20261113-150014-IU-261.1-9sec)"
expect_split "freeze E named" "$FZ" 0 1 0

# UI thread waiting or blocked, no CodeScan frame on it, and no lock owner named: a CodeScan thread anywhere
# makes it unknown, none makes it other. A running CodeScan thread alone never makes it CodeScan.
named() { run_scan --freeze-dumps "$DUMPS" "$(freeze_log 21:00:09 "threadDumps-freeze-20261113-$1-IU-261.1-9sec")"; }
named 210000; expect_split "waiting, no owner, CodeScan thread RUNNABLE" "$FZ" 0 0 1
named 210100; expect_split "timed waiting, CodeScan thread waiting" "$FZ" 0 0 1
named 210200; expect_split "blocked, no CodeScan thread" "$FZ" 0 1 0
named 210300; expect_split "blocked, no owner, CodeScan thread RUNNABLE" "$FZ" 0 0 1
named 210400; expect_split "UI block without frames" "$FZ" 0 0 1
named 210500; expect_split "UI thread RUNNABLE elsewhere, CodeScan thread RUNNABLE" "$FZ" 0 1 0
named 210600; expect_split "blocked, core library thread blocked too" "$FZ" 0 0 1
named 210700; expect_split "waiting (parking), no owner, CodeScan thread RUNNABLE" "$FZ" 0 0 1

# Lock owners. make_raw <folder>: the thread dump is read from stdin.
make_raw() { mkdir -p "$DUMPS/$1"; cat > "$DUMPS/$1/threadDump-20261113-000000.txt"; }
fz_named() { run_scan --freeze-dumps "$DUMPS" "$(freeze_log 22:00:09 "$1")"; }
# The CodeScan polling thread that runs every few ms (EditorChangeTrigger$EventWatcher). It is often caught RUNNABLE.
POLL_THREAD='"sonarlint-auto-trigger-codescan" prio=0 tid=0x0 nid=0x0 runnable
     java.lang.Thread.State: RUNNABLE

	at java.base@25.0.4/java.lang.Thread.sleep(Thread.java:509)
	at org.sonarlint.intellij.trigger.EditorChangeTrigger$EventWatcher.checkTimers(EditorChangeTrigger.java:153)
	at org.sonarlint.intellij.trigger.EditorChangeTrigger$EventWatcher.run(EditorChangeTrigger.java:125)
'
# Case A, cut down from a real IntelliJ 2026.1 dump: the UI thread waits for its next event
# (" on ...ConditionObject@..." with no owner) and the CodeScan polling thread happens to be RUNNABLE.
make_raw "threadDumps-freeze-20261113-220000-IU-261.1-10sec" <<EOF
"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 waiting on condition
     java.lang.Thread.State: WAITING
 on java.util.concurrent.locks.AbstractQueuedSynchronizer\$ConditionObject@5d4befa5
	at java.base@25.0.4/jdk.internal.misc.Unsafe.park(Native Method)
	at java.desktop/java.awt.EventQueue.getNextEvent(EventQueue.java:561)
	at com.intellij.ide.IdeEventQueue.getNextEvent(IdeEventQueue.kt:448)

$POLL_THREAD
"Reference Handler" prio=0 tid=0x0 nid=0x0 runnable
     java.lang.Thread.State: RUNNABLE
	at java.base@25.0.4/java.lang.ref.Reference.waitForReferencePendingList(Native Method)
EOF
fz_named threadDumps-freeze-20261113-220000-IU-261.1-10sec
expect_split "case A: UI thread idle, CodeScan polling thread RUNNABLE" "$FZ" 0 0 1
expect_out "case A" "CodeScan total: 0"
expect_code "case A" 0

# IntelliJ's own format names the owner: " on <lock>@<hash> owned by \"<thread>\" Id=<n>".
# The owner has a CodeScan frame: CodeScan.
make_raw "threadDumps-freeze-20261113-220100-IU-261.1-10sec" <<'EOF'
"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 blocked
     java.lang.Thread.State: BLOCKED
 on java.lang.Object@1a2b owned by "SonarLint analysis" Id=77
	at com.intellij.openapi.editor.impl.EditorImpl.paint(EditorImpl.java:1)

"Netty worker" prio=0 tid=0x0 nid=0x0 runnable
     java.lang.Thread.State: RUNNABLE
	at java.base@25/sun.nio.ch.KQueue.poll(Native Method)

"SonarLint analysis" prio=0 tid=0x0 nid=0x0 waiting on condition
     java.lang.Thread.State: TIMED_WAITING
	at java.base@25/java.lang.Thread.sleep(Thread.java:1)
	at org.sonarlint.intellij.analysis.Analysis.run(Analysis.java:1)
EOF
fz_named threadDumps-freeze-20261113-220100-IU-261.1-10sec
expect_split "lock owned by a CodeScan thread (IntelliJ format)" "$FZ" 1 0 0
expect_code "lock owned by a CodeScan thread (IntelliJ format)" 1

# The owner has no CodeScan frame: other, even though the CodeScan polling thread is RUNNABLE.
make_raw "threadDumps-freeze-20261113-220200-IU-261.1-10sec" <<EOF
"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 waiting on condition
     java.lang.Thread.State: WAITING
 on java.util.concurrent.locks.ReentrantReadWriteLock\$NonfairSync@578c6b38 owned by "DefaultDispatcher-worker-17" Id=64
	at java.base@25.0.4/jdk.internal.misc.Unsafe.park(Native Method)
	at com.intellij.openapi.application.impl.ApplicationImpl.runWriteAction(ApplicationImpl.java:1)

$POLL_THREAD
"DefaultDispatcher-worker-17" prio=0 tid=0x0 nid=0x0 runnable
     java.lang.Thread.State: RUNNABLE
	at com.intellij.psi.impl.PsiManagerImpl.findFile(PsiManagerImpl.java:3)
EOF
fz_named threadDumps-freeze-20261113-220200-IU-261.1-10sec
expect_split "lock owned by another thread (IntelliJ format)" "$FZ" 0 1 0
expect_code "lock owned by another thread (IntelliJ format)" 0

# jstack format: "- waiting to lock <0x..>" on the UI thread, "- locked <0x..>" on the owner.
make_raw "threadDumps-freeze-20261113-220300-IU-261.1-10sec" <<'EOF'
"AWT-EventQueue-0" #48 prio=6 os_prio=31 tid=0x1 nid=0x2 waiting for monitor entry
   java.lang.Thread.State: BLOCKED (on object monitor)
	at com.intellij.Foo.bar(Foo.java:1)
	- waiting to lock <0x00000007aa> (a java.lang.Object)
	at com.intellij.Foo.baz(Foo.java:2)

"Other" #50 prio=5 tid=0x3 nid=0x4 runnable
   java.lang.Thread.State: RUNNABLE
	at com.intellij.Other.run(Other.java:1)
	- locked <0x00000007bb> (a java.lang.Object)

"SonarLint worker" #51 prio=5 tid=0x5 nid=0x6 waiting on condition
   java.lang.Thread.State: TIMED_WAITING (sleeping)
	at java.lang.Thread.sleep(Native Method)
	at org.sonarlint.intellij.Worker.run(Worker.java:9)
	- locked <0x00000007aa> (a java.lang.Object)
EOF
fz_named threadDumps-freeze-20261113-220300-IU-261.1-10sec
expect_split "lock owned by a CodeScan thread (jstack format)" "$FZ" 1 0 0

# jstack format, the owner is another thread; "parking to wait for" is matched to "Locked ownable synchronizers".
make_raw "threadDumps-freeze-20261113-220400-IU-261.1-10sec" <<EOF
"AWT-EventQueue-0" #48 prio=6 tid=0x1 nid=0x2 waiting on condition
   java.lang.Thread.State: WAITING (parking)
	at jdk.internal.misc.Unsafe.park(Native Method)
	- parking to wait for  <0x00000007cc> (a java.util.concurrent.locks.ReentrantLock\$NonfairSync)
	at com.intellij.Foo.bar(Foo.java:1)

$POLL_THREAD
"Other" #50 prio=5 tid=0x3 nid=0x4 runnable
   java.lang.Thread.State: RUNNABLE
	at com.intellij.Other.run(Other.java:1)

   Locked ownable synchronizers:
	- <0x00000007cc> (a java.util.concurrent.locks.ReentrantLock\$NonfairSync)
EOF
fz_named threadDumps-freeze-20261113-220400-IU-261.1-10sec
expect_split "lock owned by another thread (jstack format, parking)" "$FZ" 0 1 0

# An owner is named but its thread is not in the dump: no owner found, so the CodeScan thread makes it unknown ...
make_raw "threadDumps-freeze-20261113-220500-IU-261.1-10sec" <<EOF
"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 blocked
     java.lang.Thread.State: BLOCKED
 on java.lang.Object@1a2b owned by "Gone thread" Id=9
	at com.intellij.Foo.bar(Foo.java:1)

$POLL_THREAD
EOF
fz_named threadDumps-freeze-20261113-220500-IU-261.1-10sec
expect_split "owner not in the dump, CodeScan thread present" "$FZ" 0 0 1
# ... and other when no thread has a CodeScan frame.
make_raw "threadDumps-freeze-20261113-220600-IU-261.1-10sec" <<'EOF'
"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 blocked
     java.lang.Thread.State: BLOCKED
	at com.intellij.Foo.bar(Foo.java:1)
	- waiting to lock <0x00000007dd> (a java.lang.Object)

"Other" prio=0 tid=0x0 nid=0x0 runnable
     java.lang.Thread.State: RUNNABLE
	at com.intellij.Other.run(Other.java:1)
EOF
fz_named threadDumps-freeze-20261113-220600-IU-261.1-10sec
expect_split "no owner found, no CodeScan thread" "$FZ" 0 1 0

# Case B: the coroutine dump after the threads ("---------- Coroutine dump ...") is not part of the last
# thread, so its suspended CodeScan coroutine does not count. No CodeScan thread, no owner: other.
make_raw "threadDumps-freeze-20261113-220700-IU-261.1-10sec" <<'EOF'
"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 waiting on condition
     java.lang.Thread.State: WAITING
 on java.lang.Object@1
	at java.base@25/jdk.internal.misc.Unsafe.park(Native Method)
	at com.other.Plugin.lock(Plugin.java:1)

"Netty worker" prio=0 tid=0x0 nid=0x0 runnable
     java.lang.Thread.State: RUNNABLE
 (in native)
	at java.base@25/sun.nio.ch.KQueue.poll(Native Method)


---------- Coroutine dump (stripped) ----------

- BlockingCoroutine{Active}@bf64270 [BlockingEventLoop]
	- "org.sonarlint.intellij.SomeService":StandaloneCoroutine{Active}, state: SUSPENDED [Kernel]
		at org.sonarlint.intellij.SomeService$1.invokeSuspend(SomeService.kt:35)
"looks like a thread" prio=0 tid=0x0 nid=0x0 runnable
     java.lang.Thread.State: RUNNABLE
	at org.sonarlint.intellij.Fake.run(Fake.java:1)
EOF
fz_named threadDumps-freeze-20261113-220700-IU-261.1-10sec
expect_split "case B: coroutine dump is not read" "$FZ" 0 1 0
expect_code "case B" 0

# Empty folder, folder with only a report, thread dump without a UI thread: unknown, with the folder named.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 13:00:18 threadDumps-freeze-20261113-130016-IU-261.1-9sec)"
expect_split "freeze empty folder" "$FZ" 0 0 1
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 16:00:18 threadDumps-freeze-20261113-160016-IU-261.1-9sec)"
expect_split "freeze report only" "$FZ" 0 0 1
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 17:00:18 threadDumps-freeze-20261113-170016-IU-261.1-9sec)"
expect_split "freeze no UI block" "$FZ" 0 0 1
expect_code "freeze no UI block" 0

# A named folder that is missing is unknown, even though a folder exists at that time.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 11:00:18 threadDumps-freeze-20261113-110018-IU-261.1-gone)"
expect_split "freeze named but missing" "$FZ" 0 0 1

# Not a freeze folder: ignored.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 18:00:18 threadDumps-Dispatchers.IO-20261113-180016-IU-261.1)"
expect_split "freeze other folder kind" "$FZ" 0 0 1

# A busy UI thread (blank line before the frames): CodeScan frame on it is CodeScan, no CodeScan frame is other.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 19:00:07 threadDumps-freeze-20261113-190016-IU-261.1-9sec)"
expect_split "freeze runnable layout CodeScan" "$FZ" 1 0 0
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 20:00:07 threadDumps-freeze-20261113-200016-IU-261.1-9sec)"
expect_split "freeze runnable layout other" "$FZ" 0 1 0
# ... also when the folder is named in the line.
run_scan --freeze-dumps "$DUMPS" "$(freeze_log 19:30:00 threadDumps-freeze-20261113-190016-IU-261.1-9sec)"
expect_split "freeze runnable layout named" "$FZ" 1 0 0

# Without --freeze-dumps a freeze is unknown.
run_scan "$(freeze_log 11:00:25 threadDumps-freeze-20261113-110016-IU-261.1-9sec)"
expect_split "freeze without flag" "$FZ" 0 0 1

# One entry is one hit: a CodeScan logger plus a platform pattern is not counted twice.
f="$TMP/double.log"
{
  echo "$TS SEVERE - #org.sonarlint.intellij.Foo - Read access is allowed from inside read-action only"
  echo "java.lang.RuntimeException: boom"
  echo "	at com.intellij.util.Foo.bar(Foo.java:1)"
} > "$f"
run_scan "$f"
expect_out "double count" "Total: 1"
expect_out "double count" "CodeScan total: 1"
expect_split "double count" "Read access is allowed from inside read-action" 1 0 0
expect_split "double count" "ERROR from org.sonarlint logger" 0 0 0

# The logger is the word after "LEVEL - #", not text inside the message.
f="$TMP/message-text.log"
echo "$TS   INFO - #c.i.Foo - server said: ERROR - #org.sonarlint.x - nope" > "$f"
run_scan "$f"
expect_out "message text" "Total: 0"
expect_out "message text" "CodeScan total: 0"
f="$TMP/message-text-slow.log"
echo "$TS   WARN - #c.i.Foo - see WARN - #org.sonarlint.x - Slow operations are prohibited on EDT" > "$f"
run_scan "$f"
expect_split "message text slow" "Slow operations are prohibited on EDT" 0 0 1

# TRACE is a level too.
f="$TMP/trace.log"
echo "$TS  TRACE - #org.sonarlint.x - Slow operations are prohibited on EDT" > "$f"
run_scan "$f"
expect_split "trace logger" "Slow operations are prohibited on EDT" 1 0 0

# FINE, FINER and FINEST are levels too.
for lvl in FINE FINER FINEST; do
  f="$TMP/level-$lvl.log"
  echo "$TS $lvl - #org.sonarlint.x - Slow operations are prohibited on EDT" > "$f"
  run_scan "$f"
  expect_split "level $lvl" "Slow operations are prohibited on EDT" 1 0 0
done

# IntelliJ names the plugin it blames. That is CodeScan even when no stack frame says org.sonarlint.
f="$TMP/blame.log"
{
  echo "$TS SEVERE - #c.i.s.ComponentManagerImpl - Cannot create class org.sonarlint.intellij.core.Foo [Plugin: com.code-scan.intellij]"
  echo "com.intellij.diagnostic.PluginException: Cannot create class org.sonarlint.intellij.core.Foo [Plugin: com.code-scan.intellij]"
  echo "	at com.intellij.serviceContainer.ComponentManagerImpl.instantiateClass(ComponentManagerImpl.kt:1)"
} > "$f"
run_scan "$f"
expect_code "blame bracket" 1
expect_split "blame bracket" "ERROR with org.sonarlint in its stack trace" 1 0 0
f="$TMP/blame2.log"
echo "$TS SEVERE - #c.i.s.ComponentManagerImpl - Plugin to blame: CodeScan version: 7.3.2" > "$f"
run_scan "$f"
expect_code "blame line" 1
expect_split "blame line" "ERROR with org.sonarlint in its stack trace" 1 0 0
f="$TMP/blame-other.log"
{
  echo "$TS SEVERE - #c.i.s.ComponentManagerImpl - Cannot create class a.b.C [Plugin: org.other.plugin]"
  echo "	at com.intellij.serviceContainer.ComponentManagerImpl.instantiateClass(ComponentManagerImpl.kt:1)"
  echo "$TS SEVERE - #c.i.s.ComponentManagerImpl - Plugin to blame: Other plugin version: 1.0"
} > "$f"
run_scan "$f"
expect_code "blame other plugin" 0
expect_out "blame other plugin" "Total: 0"
# A platform pattern whose entry blames CodeScan, with no CodeScan frame, is CodeScan.
f="$TMP/blame-slow.log"
{
  echo "$TS SEVERE - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See javadoc. [Plugin: com.code-scan.intellij]"
  echo "java.lang.Throwable: Slow operations are prohibited on EDT"
  echo "	at com.intellij.util.SlowOperations.assertSlowOperationsAreAllowed(SlowOperations.java:117)"
} > "$f"
run_scan "$f"
expect_split "blame slow" "Slow operations are prohibited on EDT" 1 0 0

# One exception that IntelliJ logs under two loggers a few ms apart is one hit. The entries have the same first
# CodeScan frame; the second starts within 100 ms of the first.
dup_entry() { # <time with ms> <logger> <first CodeScan frame method>
  echo "2026-11-13 $1 [  12345] SEVERE - #$2 - Read access is allowed from inside read-action only"
  echo "java.lang.Throwable: Read access is allowed from inside read-action only"
  echo "	at com.intellij.psi.impl.PsiFileImpl.isValid(PsiFileImpl.java:232)"
  echo "	at org.sonarlint.intellij.finding.$3(LiveFinding.java:91)"
}
f="$TMP/dup-pair.log"
{
  dup_entry "10:00:00,100" "c.i.o.a.i.PluginManager" "LiveFinding.isValid"
  dup_entry "10:00:00,106" "c.i.o.a.i.ExceptionsKt" "LiveFinding.isValid"
} > "$f"
run_scan "$f"
expect_split "dup pair" "Read access is allowed from inside read-action" 1 0 0
expect_out "dup pair" "Total: 1"
expect_out "dup pair" "CodeScan total: 1"
expect_out "dup pair" "Merged duplicates: 1"
expect_out "dup pair" "1 x [Read access is allowed from inside read-action] CodeScan"

f="$TMP/dup-far.log"
{
  dup_entry "10:00:00,100" "c.i.o.a.i.PluginManager" "LiveFinding.isValid"
  dup_entry "10:00:00,600" "c.i.o.a.i.ExceptionsKt" "LiveFinding.isValid"
} > "$f"
run_scan "$f"
expect_out "dup 500 ms apart" "Total: 2"
expect_out "dup 500 ms apart" "Merged duplicates: 0"

f="$TMP/dup-edge.log"
{
  dup_entry "10:00:00,100" "c.i.o.a.i.PluginManager" "LiveFinding.isValid"
  dup_entry "10:00:00,200" "c.i.o.a.i.ExceptionsKt" "LiveFinding.isValid"
} > "$f"
run_scan "$f"
expect_out "dup 100 ms apart" "Total: 1"
f="$TMP/dup-edge2.log"
{
  dup_entry "10:00:00,100" "c.i.o.a.i.PluginManager" "LiveFinding.isValid"
  dup_entry "10:00:00,201" "c.i.o.a.i.ExceptionsKt" "LiveFinding.isValid"
} > "$f"
run_scan "$f"
expect_out "dup 101 ms apart" "Total: 2"

# Not merged: another first CodeScan frame, the same logger twice, or entries without a CodeScan frame.
f="$TMP/dup-other-frame.log"
{
  dup_entry "10:00:00,100" "c.i.o.a.i.PluginManager" "LiveFinding.isValid"
  dup_entry "10:00:00,105" "c.i.o.a.i.ExceptionsKt" "LiveFinding.other"
} > "$f"
run_scan "$f"
expect_out "dup other frame" "Total: 2"
f="$TMP/dup-same-logger.log"
{
  dup_entry "10:00:00,100" "c.i.o.a.i.PluginManager" "LiveFinding.isValid"
  dup_entry "10:00:00,105" "c.i.o.a.i.PluginManager" "LiveFinding.isValid"
} > "$f"
run_scan "$f"
expect_out "dup same logger" "Total: 2"
# Two different problems (read access, then a slow operation) from the same CodeScan frame are two hits.
f="$TMP/dup-other-pattern.log"
{
  echo "2026-06-01 10:00:00,100 [  1] SEVERE - #c.i.o.a.i.ApplicationImpl - Read access is allowed from inside read-action only"
  echo "java.lang.Throwable: Read access is allowed from inside read-action only"
  echo "	at com.intellij.openapi.application.impl.ApplicationImpl.assertReadAccessAllowed(ApplicationImpl.java:1)"
  echo "	at org.sonarlint.intellij.finding.LiveFinding.isValid(LiveFinding.java:91)"
  echo "2026-06-01 10:00:00,140 [  1] SEVERE - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
  echo "java.lang.Throwable: Slow operations are prohibited on EDT."
  echo "	at com.intellij.util.SlowOperations.assertSlowOperationsAreAllowed(SlowOperations.java:1)"
  echo "	at org.sonarlint.intellij.finding.LiveFinding.isValid(LiveFinding.java:91)"
} > "$f"
run_scan "$f"
expect_out "dup other pattern" "Total: 2"
expect_out "dup other pattern" "Merged duplicates: 0"
expect_split "dup other pattern" "Read access is allowed from inside read-action" 1 0 0
expect_split "dup other pattern" "Slow operations are prohibited on EDT" 1 0 0
f="$TMP/dup-other-day.log"
{
  echo "2026-11-12 10:00:00,100 [  12345] SEVERE - #c.i.A - Read access is allowed from inside read-action only"
  echo "	at org.sonarlint.intellij.finding.LiveFinding.isValid(LiveFinding.java:91)"
  echo "2026-11-13 10:00:00,105 [  12345] SEVERE - #c.i.B - Read access is allowed from inside read-action only"
  echo "	at org.sonarlint.intellij.finding.LiveFinding.isValid(LiveFinding.java:91)"
} > "$f"
run_scan "$f"
expect_out "dup other day" "Total: 2"

# IntelliJ writes the report of one exception as several entries a few ms apart: the exception, then
# "JDK: ...", "OS: ..." and "Plugin to blame: CodeScan version: ..." with no stack. The blame line belongs to the
# exception before it and is not a hit of its own.
blame_tail() { # <time with ms> <logger>
  echo "2026-11-13 $1 [  12345] SEVERE - #$2 - JDK: 25.0.2; VM: OpenJDK 64-Bit Server VM"
  echo "2026-11-13 $1 [  12345] SEVERE - #$2 - OS: Mac OS X"
  echo "2026-11-13 $1 [  12345] SEVERE - #$2 - Plugin to blame: CodeScan version: 7.3.2"
}
f="$TMP/blame-tail.log"
{
  dup_entry "10:00:00,100" "c.i.u.c.ThreadingAssertions" "LiveFinding.isValid"
  blame_tail "10:00:00,101" "c.i.u.c.ThreadingAssertions"
} > "$f"
run_scan "$f"
expect_out "blame tail" "Total: 1"
expect_out "blame tail" "CodeScan total: 1"
expect_out "blame tail" "ERROR with org.sonarlint in its stack trace: 0"
expect_out "blame tail" "Blame follow-up lines folded: 1"

f="$TMP/blame-tail-pair.log"
{
  dup_entry "10:00:00,100" "c.i.u.c.ThreadingAssertions" "LiveFinding.isValid"
  blame_tail "10:00:00,101" "c.i.u.c.ThreadingAssertions"
  dup_entry "10:00:00,103" "c.i.p.SingleRootFileViewProvider" "LiveFinding.isValid"
  blame_tail "10:00:00,104" "c.i.p.SingleRootFileViewProvider"
} > "$f"
run_scan "$f"
expect_out "blame tail pair" "Total: 1"
expect_out "blame tail pair" "Merged duplicates: 1"
expect_out "blame tail pair" "Blame follow-up lines folded: 2"

# A blame line after a hit that is not CodeScan: IntelliJ blames CodeScan for it, so that hit becomes CodeScan.
f="$TMP/blame-relabel.log"
{
  echo "2026-06-01 10:00:00,100 [  1] SEVERE - #c.i.o.a.i.ApplicationImpl - Access is allowed from Event Dispatch Thread only"
  echo "java.lang.Throwable: Access is allowed from Event Dispatch Thread only"
  echo "	at com.intellij.typescript.Foo.bar(Foo.java:1)"
  echo "2026-06-01 10:00:00,160 [  1] SEVERE - #c.i.d.PluginManager - Plugin to blame: CodeScan version: 7.3.1"
} > "$f"
run_scan "$f"
expect_code "blame relabels other hit" 1
expect_out "blame relabels other hit" "Total: 1"
expect_out "blame relabels other hit" "CodeScan total: 1"
expect_split "blame relabels other hit" "Access is allowed from Event Dispatch Thread" 1 0 0
expect_split "blame relabels other hit" "ERROR with org.sonarlint in its stack trace" 0 0 0
expect_out "blame relabels other hit" "Relabelled CodeScan by a blame line: 1"
expect_out "blame relabels other hit" "1 x [Access is allowed from Event Dispatch Thread] CodeScan"
expect_no_out "blame relabels other hit" "x [Access is allowed from Event Dispatch Thread] other"
# The same with the "[Plugin: com.code-scan.intellij]" form, after an unknown hit (no stack).
f="$TMP/blame-relabel-bracket.log"
{
  echo "2026-06-01 10:00:00,100 [  1]  WARN - #c.i.o.a.i.ApplicationImpl - Suppressed a frequent exception logged for the 3rd time: Read access is allowed from inside read-action only"
  echo "2026-06-01 10:00:00,130 [  1] SEVERE - #c.i.d.PluginManager - Cannot report [Plugin: com.code-scan.intellij]"
} > "$f"
run_scan "$f"
expect_split "blame bracket relabels unknown hit" "Read access is allowed from inside read-action" 1 0 0
expect_out "blame bracket relabels unknown hit" "Total: 1"
expect_out "blame bracket relabels unknown hit" "Relabelled CodeScan by a blame line: 1"
# A blame line after a CodeScan hit changes nothing.
run_scan "$TMP/blame-tail.log"
expect_out "blame after CodeScan hit" "Relabelled CodeScan by a blame line: 0"

f="$TMP/blame-tail-late.log"
{
  dup_entry "10:00:00,100" "c.i.u.c.ThreadingAssertions" "LiveFinding.isValid"
  blame_tail "10:00:05,000" "c.i.u.c.ThreadingAssertions"
} > "$f"
run_scan "$f"
expect_out "blame tail 5 s later" "Total: 2"
expect_out "blame tail 5 s later" "Blame follow-up lines folded: 0"

f="$TMP/blame-tail-header.log"
{
  echo "$TS SEVERE - #c.i.s.ComponentManagerImpl - Cannot create class org.sonarlint.intellij.core.Foo [Plugin: com.code-scan.intellij]"
  echo "	at com.intellij.serviceContainer.ComponentManagerImpl.instantiateClass(ComponentManagerImpl.kt:1)"
  blame_tail "10:00:00,124" "c.i.s.ComponentManagerImpl"
} > "$f"
run_scan "$f"
expect_out "blame after a plugin-named error" "Total: 1"
expect_out "blame after a plugin-named error" "Blame follow-up lines folded: 1"

# A chain: three loggers within 100 ms of each other are one hit; a later repeat after a gap is a new hit.
f="$TMP/dup-chain.log"
{
  dup_entry "10:00:00,100" "c.i.o.a.i.PluginManager" "LiveFinding.isValid"
  dup_entry "10:00:00,150" "c.i.o.a.i.ExceptionsKt" "LiveFinding.isValid"
  dup_entry "10:00:00,200" "c.i.p.i.SingleRootFileViewProvider" "LiveFinding.isValid"
  dup_entry "10:00:03,000" "c.i.o.a.i.PluginManager" "LiveFinding.isValid"
} > "$f"
run_scan "$f"
expect_out "dup chain" "Total: 2"
expect_out "dup chain" "Merged duplicates: 2"

# "--" ends the options, so a log file can be named like an option.
cp "$TMP/trace.log" "$TMP/-x.log"
OUT="$(cd "$TMP" && bash "$SCAN" -- -x.log 2>&1)"; CODE=$?
expect_code "double dash" 1
expect_out "double dash" "CodeScan total: 1"
OUT="$(cd "$TMP" && bash "$SCAN" -x.log 2>&1)"; CODE=$?
expect_code "dash file without double dash" 2

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
