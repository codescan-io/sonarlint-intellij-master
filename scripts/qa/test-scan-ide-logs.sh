#!/usr/bin/env bash
# Tests for scan-ide-logs.sh. Run: bash scripts/qa/test-scan-ide-logs.sh
# Works with macOS bash 3.2 and Linux bash.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/scan-ide-logs.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scan-ide-logs-test.XXXXXX")"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

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
expect_file_has() {
  if [ -f "$2" ] && grep -F -q -- "$3" "$2"; then ok "$1: $(basename "$2") has '$3'"; else not_ok "$1: $(basename "$2") has '$3'" "missing"; fi
}
expect_file_lacks() {
  if [ -f "$2" ] && grep -F -q -- "$3" "$2"; then not_ok "$1: $(basename "$2") lacks '$3'" "present"; else ok "$1: $(basename "$2") lacks '$3'"; fi
}

TS='2026-11-13 10:00:00,123 [  12345]'
# A slow operation on the UI thread with a CodeScan frame in its stack: the kind of line the UI tests must catch.
slow_op_codescan() {
  echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
  printf '\tat com.intellij.util.SlowOperations.assertSlowOperationsAreAllowed(SlowOperations.java:114)\n'
  printf '\tat com.intellij.openapi.options.ex.ConfigurableWrapper.getConfigurable(ConfigurableWrapper.java:120)\n'
  printf '\tat org.sonarlint.intellij.config.project.SonarLintProjectConfigurable.reset(SonarLintProjectConfigurable.java:125)\n'
}
clean_line() { echo "$TS   INFO - #c.i.i.StartupUtil - IDE STARTED"; }

# 1. A known slow-operation line with a CodeScan frame fails the check.
d="$TMP/slow"; mkdir -p "$d"
{ clean_line; slow_op_codescan; } > "$d/idea.log"
run_scan "$d" "$TMP/slow-report/scan.txt"
expect_code "slow-op" 1
expect_out "slow-op" "##### idea.log"
expect_out "slow-op" "SonarLintProjectConfigurable.reset(SonarLintProjectConfigurable.java:125)"
expect_out "slow-op" "CodeScan total: 1"
expect_file_has "slow-op" "$TMP/slow-report/scan.txt" "=== Slow operations are prohibited on EDT (line 2) ==="

d="$TMP/clean"; mkdir -p "$d"
clean_line > "$d/idea.log"
run_scan "$d" "$TMP/clean.txt"
expect_code "clean" 0
expect_out "clean" "CodeScan total: 0"

# 3. IntelliJ rotates idea.log; a hit in idea.1.log counts too.
d="$TMP/rotated"; mkdir -p "$d"
clean_line > "$d/idea.log"
slow_op_codescan > "$d/idea.1.log"
run_scan "$d" "$TMP/rotated.txt"
expect_code "rotated" 1
expect_out "rotated" "##### idea.1.log"
expect_file_has "rotated" "$TMP/rotated.txt" "##### idea.log"

# 4. A reused report file is overwritten, not added to.
run_scan "$TMP/clean" "$TMP/rotated.txt"
expect_code "reused report" 0
expect_file_lacks "reused report" "$TMP/rotated.txt" "idea.1.log"

# 5. A freeze is judged from its thread dump in the same folder (CodeScan frame on the UI thread).
d="$TMP/freeze"; mkdir -p "$d/threadDumps-freeze-20261113-100000-IC-231.9423-12sec"
echo "$TS   INFO - #c.i.d.PerformanceWatcherImpl - UI was frozen for 12000ms, details saved to $d/threadDumps-freeze-20261113-100000-IC-231.9423-12sec" > "$d/idea.log"
{
  echo '"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 runnable'
  echo '     java.lang.Thread.State: RUNNABLE'
  printf '\tat org.sonarlint.intellij.core.ProjectBindingManager.getServerConnection(ProjectBindingManager.kt:80)\n'
} > "$d/threadDumps-freeze-20261113-100000-IC-231.9423-12sec/threadDump-20261113-100000.txt"
run_scan "$d" "$TMP/freeze.txt"
expect_code "freeze" 1
expect_out "freeze" "UI was frozen: 1"

# 6. A folder without any idea.log is not a pass: the IDE log is missing.
d="$TMP/nolog"; mkdir -p "$d"
echo "x" > "$d/other.txt"
run_scan "$d" "$TMP/nolog.txt"
expect_code "no idea.log" 3
expect_out "no idea.log" "no idea.log"

# 7. A log that cannot be read makes the result incomplete; that beats a CodeScan hit in another log.
d="$TMP/unreadable"; mkdir -p "$d"
slow_op_codescan > "$d/idea.log"
clean_line > "$d/idea.1.log"
chmod 000 "$d/idea.1.log"
if [ -r "$d/idea.1.log" ]; then
  ok "unreadable: skipped (running as a user who can read any file)"
else
  run_scan "$d" "$TMP/unreadable.txt"
  expect_code "unreadable" 4
  expect_out "unreadable" "log check failed for"
fi

run_scan
expect_code "no arguments" 2
run_scan "$TMP/does-not-exist" "$TMP/x.txt"
expect_code "missing folder" 2
run_scan "$TMP/clean"
expect_code "missing report path" 2

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
