#!/usr/bin/env bash
# Tests for run-ide-scenarios.sh that need no real Docker or IDE: a stub "docker" program is put first on PATH and
# plays the container (it writes an idea.log and JUnit results into the folder mounted as /out).
# Run: bash scripts/qa/test-run-ide-scenarios.sh
# Env: RIS=<path>  the run-ide-scenarios.sh to test (default: the one next to this file).
# Works with macOS bash 3.2 and Linux bash.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RIS="${RIS:-$HERE/run-ide-scenarios.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-ide-scenarios-test.XXXXXX")"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

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
expect_no_out() {
  if printf '%s\n' "$OUT" | grep -F -q -- "$2"; then not_ok "$1: output has no '$2'" "found"; else ok "$1: output has no '$2'"; fi
}
expect_file() {
  if [ -e "$2" ]; then ok "$1: $3"; else not_ok "$1: $3" "missing: $2"; fi
}
expect_no_file() {
  if [ -e "$2" ]; then not_ok "$1: $3" "still there: $2"; else ok "$1: $3"; fi
}

# The stub. "docker run" records its arguments in $STUB_ARGS and fakes the container's results in the /out mount:
# STUB_LOG   = clean | slow-op (a slow operation on the UI thread with a CodeScan frame) | no-idea-log | none
# STUB_TESTS = pass (2 passed) | fail (1 passed, 1 failed) | skip (1 passed, 1 skipped) | none
# STUB_RC    = the exit code of "docker run" (its-run.sh's: 0, 3 or 5)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  info|build|kill) exit 0 ;;
  run)
    printf '%s\n' "$@" > "$STUB_ARGS"
    out=""
    prev=""
    for a in "$@"; do
      case "$a" in *:/out) [ "$prev" = "-v" ] && out="${a%:/out}" ;; esac
      prev="$a"
    done
    [ -n "$out" ] || exit 99
    TS="2026-11-14 10:00:00,100 [ 1000]"
    case "${STUB_LOG:-clean}" in
      clean) mkdir -p "$out/log"; echo "$TS   INFO - #c.i.i.StartupUtil - IDE STARTED" > "$out/log/idea.log" ;;
      slow-op)
        mkdir -p "$out/log"
        {
          echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
          printf '\tat com.intellij.util.SlowOperations.assertSlowOperationsAreAllowed(SlowOperations.java:114)\n'
          printf '\tat org.sonarlint.intellij.config.project.SonarLintProjectConfigurable.reset(SonarLintProjectConfigurable.java:125)\n'
        } > "$out/log/idea.log" ;;
      no-idea-log) mkdir -p "$out/log"; echo x > "$out/log/other.txt" ;;
      none) : ;;
    esac
    case "${STUB_TESTS:-pass}" in
      none) : ;;
      *)
        mkdir -p "$out/test-results"
        {
          echo '<?xml version="1.0" encoding="UTF-8"?>'
          echo '<testsuite name="org.sonarlint.intellij.its.tests.StandaloneIdeaTests" tests="2">'
          echo '  <testcase name="javaIssues()" classname="org.sonarlint.intellij.its.tests.StandaloneIdeaTests" time="1.0"/>'
          case "${STUB_TESTS:-pass}" in
            pass) echo '  <testcase name="jsIssues()" classname="org.sonarlint.intellij.its.tests.StandaloneIdeaTests" time="1.0"/>' ;;
            fail)
              echo '  <testcase name="jsIssues()" classname="org.sonarlint.intellij.its.tests.StandaloneIdeaTests" time="1.0">'
              echo '    <failure message="boom" type="java.lang.AssertionError">boom</failure>'
              echo '  </testcase>' ;;
            skip)
              echo '  <testcase name="jsIssues()" classname="org.sonarlint.intellij.its.tests.StandaloneIdeaTests" time="0.0">'
              echo '    <skipped/>'
              echo '  </testcase>' ;;
          esac
          echo '</testsuite>'
        } > "$out/test-results/TEST-org.sonarlint.intellij.its.tests.StandaloneIdeaTests.xml" ;;
    esac
    exit "${STUB_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/docker"

mkdir -p "$TMP/zip-src" && echo x > "$TMP/zip-src/CodeScan.txt"
( cd "$TMP/zip-src" && zip -q "$TMP/plugin.zip" CodeScan.txt ) || { echo "error: needs the zip program"; exit 2; }

# This machine's Gradle home, with an unpacked copy of the Gradle the project's wrapper names.
HOST_GRADLE="$TMP/host-gradle"
DIST="$(sed -n 's#^distributionUrl=.*/\(gradle-[^/]*\)\.zip$#\1#p' "$HERE/../../gradle/wrapper/gradle-wrapper.properties")"
mkdir -p "$HOST_GRADLE/wrapper/dists/$DIST/hash1/gradle-x/bin"
touch "$HOST_GRADLE/wrapper/dists/$DIST/hash1/$DIST.zip.ok" "$HOST_GRADLE/wrapper/dists/$DIST/hash1/$DIST.zip.lck"

export STUB_ARGS="$TMP/docker-args.txt"
run() {
  local name=$1
  shift
  rm -f "$STUB_ARGS"
  OUT="$(PATH="$TMP/bin:$PATH" QA_CACHE_DIR="$TMP/cache-$name" GRADLE_USER_HOME="$HOST_GRADLE" \
    bash "$RIS" "$@" --plugin "$TMP/plugin.zip" --out "$TMP/out-$name" 2>&1)"
  CODE=$?
}
args_have() {
  if grep -F -x -q -- "$2" "$STUB_ARGS" 2>/dev/null; then ok "$1: docker gets '$2'"; else not_ok "$1: docker gets '$2'" "args: $(tr '\n' ' ' < "$STUB_ARGS" 2>/dev/null)"; fi
}

# 1. UI tests pass, clean log: exit 0, and the summary says so.
run clean 2023.1.7
expect_code "clean" 0
expect_out "clean" "UI tests: 2 run, 2 passed, 0 failed, 0 skipped"
expect_out "clean" "CodeScan total: 0"
expect_file "clean" "$TMP/out-clean/tests.txt" "tests.txt written"
expect_file "clean" "$TMP/out-clean/scan.txt" "scan.txt written"
expect_file "clean" "$TMP/out-clean/plugin/CodeScan.txt" "plugin unzipped for the container"

# 2. Version names: IC before 2025.3, IU from 2025.3 on, a full Gradle value as it is.
for pair in 2023.1.7:IC-2023.1.7 2025.2.4:IC-2025.2.4 2025.3:IU-2025.3 2026.1.5:IU-2026.1.5 IC-2024.1.7:IC-2024.1.7; do
  run version "${pair%%:*}"
  args_have "version ${pair%%:*}" "${pair#*:}"
done
run bad-version nonsense
expect_code "bad version" 2

# 3. UI tests pass but the IDE logged a CodeScan slow operation (Gradle then failed in checkIdeLog: exit 5): exit 1.
STUB_LOG=slow-op STUB_RC=5 run slow 2026.1.5
expect_code "slow-op" 1
expect_out "slow-op" "CodeScan total: 1"
expect_out "slow-op" "SonarLintProjectConfigurable.reset(SonarLintProjectConfigurable.java:125)"

# 4. A failed UI test: exit 5, named in the summary; the log check still runs.
STUB_TESTS=fail STUB_RC=5 run fail 2023.1.7
expect_code "failed test" 5
expect_out "failed test" "UI tests: 2 run, 1 passed, 1 failed, 0 skipped"
expect_out "failed test" "FAILED  StandaloneIdeaTests > jsIssues()"
expect_out "failed test" "CodeScan total: 0"

# 5. A skipped UI test is named, and is not a failure.
STUB_TESTS=skip run skip 2023.1.7
expect_code "skipped test" 0
expect_out "skipped test" "skipped StandaloneIdeaTests > jsIssues()"

# 6. The run did not happen (the IDE did not start, no log): exit 3.
STUB_LOG=none STUB_TESTS=none STUB_RC=3 run no-run 2023.1.7
expect_code "no run" 3

# 7. Gradle failed (exit 5) yet no test failed and the log is clean: still a failure, not a pass.
STUB_RC=5 run gradle-only 2023.1.7
expect_code "Gradle failed, tests passed" 5

# 8. A log folder with no idea.log: the log check is incomplete, exit 4.
STUB_LOG=no-idea-log run no-idea 2023.1.7
expect_code "no idea.log" 4

# 9. A reused results folder: an old idea.log and old results do not count for this run.
mkdir -p "$TMP/out-reuse/log" "$TMP/out-reuse/test-results"
echo "2026-11-13 10:00:00,100 [ 1000] SEVERE - #org.sonarlint.intellij.Foo - old" > "$TMP/out-reuse/log/idea.1.log"
cp "$TMP/out-fail/test-results/"*.xml "$TMP/out-reuse/test-results/"
run reuse 2023.1.7
expect_code "reused folder" 0
expect_no_file "reused folder" "$TMP/out-reuse/log/idea.1.log" "old idea.1.log removed"

# 10. --tests reaches the container; no CodeArtifact token or setting does.
CODEARTIFACT_AUTH_TOKEN=secret-value-123 run tests-filter 2023.1.7 --tests '*StandaloneIdeaTests*'
args_have "--tests" "*StandaloneIdeaTests*"
if grep -q -e 'CODEARTIFACT' -e 'secret-value-123' "$STUB_ARGS"; then not_ok "no token" "docker args mention CodeArtifact"; else ok "no token: docker args do not mention CodeArtifact"; fi
expect_no_out "no token" "secret-value-123"

# 11. The container starts with this machine's unpacked Gradle, also when an earlier failed download left a
#     half-made folder (lock file only) in the container's Gradle home.
mkdir -p "$TMP/cache-gradle-copy/gradle-home/wrapper/dists/$DIST/hash1"
touch "$TMP/cache-gradle-copy/gradle-home/wrapper/dists/$DIST/hash1/$DIST.zip.lck"
run gradle-copy 2023.1.7
expect_file "Gradle copy" "$TMP/cache-gradle-copy/gradle-home/wrapper/dists/$DIST/hash1/$DIST.zip.ok" "Gradle's done-marker copied"
expect_file "Gradle copy" "$TMP/cache-gradle-copy/gradle-home/wrapper/dists/$DIST/hash1/gradle-x/bin" "unpacked Gradle copied"
expect_file "Gradle copy" "$TMP/cache-gradle-copy/gradle-home/gradle.properties" "container Gradle settings written"
# No copy on this machine: the container downloads Gradle itself, and nothing fails here.
OUT="$(PATH="$TMP/bin:$PATH" QA_CACHE_DIR="$TMP/cache-no-host" GRADLE_USER_HOME="$TMP/empty-gradle" \
  bash "$RIS" 2023.1.7 --plugin "$TMP/plugin.zip" --out "$TMP/out-no-host" 2>&1)"
CODE=$?
expect_code "no Gradle on this machine" 0
expect_no_file "no Gradle on this machine" "$TMP/cache-no-host/gradle-home/wrapper" "nothing copied"

# 12. Bad usage.
OUT="$(PATH="$TMP/bin:$PATH" bash "$RIS" 2>&1)"; CODE=$?
expect_code "no version" 2
# A fake home, so that a broken check can never empty folders in the real one.
mkdir -p "$TMP/fake-home"
OUT="$(PATH="$TMP/bin:$PATH" HOME="$TMP/fake-home" bash "$RIS" 2023.1.7 --plugin "$TMP/plugin.zip" --out "$TMP/fake-home" 2>&1)"; CODE=$?
expect_code "--out is the home folder" 2
OUT="$(PATH="$TMP/bin:$PATH" bash "$RIS" 2023.1.7 --plugin "$TMP/missing.zip" 2>&1)"; CODE=$?
expect_code "missing plugin zip" 2

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
