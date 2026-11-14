#!/usr/bin/env bash
# Tests the Gradle wiring of the UI-test log check (:its:checkIdeLog, run after :its:test).
# Run from anywhere with a JDK 17 on JAVA_HOME: bash scripts/qa/test-its-log-check.sh
# Slow (3 Gradle runs, about a minute each with a warm Gradle cache). Works with macOS bash 3.2 and Linux bash.
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

run_gradle :its:checkIdeLog -PideLogDir="$TMP/slow"
if [ "$CODE" -ne 0 ]; then ok "known slow operation: Gradle fails"; else not_ok "known slow operation: Gradle fails" "Gradle passed"; fi
expect_out "known slow operation" "CodeScan total: 1"

run_gradle :its:checkIdeLog -PideLogDir="$TMP/clean"
if [ "$CODE" -eq 0 ]; then ok "clean log: Gradle passes"; else not_ok "clean log: Gradle passes" "Gradle failed (exit $CODE)"; fi

# The check must run after the UI tests, also when they fail.
run_gradle :its:test --dry-run
expect_out "after :its:test" ":its:checkIdeLog SKIPPED"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
