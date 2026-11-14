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
cleanup() {
  for f in "$TMP"/*.pid; do [ -f "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
  chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"
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
expect_no_out() {
  if printf '%s\n' "$OUT" | grep -F -q -- "$2"; then not_ok "$1: output has no '$2'" "found"; else ok "$1: output has no '$2'"; fi
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
expect_file() {
  if [ -e "$2" ]; then ok "$1: $3"; else not_ok "$1: $3" "missing: $2"; fi
}
expect_no_file() {
  if [ -e "$2" ]; then not_ok "$1: $3" "still there: $2"; else ok "$1: $3"; fi
}

# The stub. "docker run" records its arguments in $STUB_ARGS and fakes the container's results in the /out mount:
# STUB_LOG   = clean | slow-op (a slow operation on the UI thread with a CodeScan frame) | ide-slow-op (one with no
#              CodeScan frame) | unknown-slow-op (one with no stack trace, so its source cannot be told) | no-idea-log
#              | none
# STUB_TESTS = pass (4 passed) | fail (3 passed, 1 failed) | skip (3 passed, 1 skipped) | all-skipped (4 skipped)
#              | scenario-skipped (3 passed; CodeScanScenarioTests skipped) | none
#              StandaloneIdeaTests has 2 tests; CodeScanScenarioTests and ConnectedAnalysisTests have 1 each.
# STUB_RC    = the exit code of "docker run" (its-run.sh's: 0, 3 or 5)
# STUB_RUN_WAIT=1: "docker run" waits (at most 60 s) until "docker kill" is called, then exits 137.
# "docker kill" records its arguments in $STUB_KILLS.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  info|build) exit 0 ;;
  kill) shift; printf '%s\n' "$*" >> "$STUB_KILLS"; exit 0 ;;
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
      ide-slow-op)
        mkdir -p "$out/log"
        {
          echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc."
          printf '\tat com.intellij.util.SlowOperations.assertSlowOperationsAreAllowed(SlowOperations.java:114)\n'
          printf '\tat com.intellij.openapi.vfs.newvfs.persistent.FSRecords.update(FSRecords.java:382)\n'
        } > "$out/log/idea.log" ;;
      unknown-slow-op)
        mkdir -p "$out/log"
        echo "$TS  ERROR - #c.i.u.SlowOperations - Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc." > "$out/log/idea.log" ;;
      no-idea-log) mkdir -p "$out/log"; echo x > "$out/log/other.txt" ;;
      none) : ;;
    esac
    # One JUnit XML file per test class: suite <class> <test> <passed|failed|skipped> [<test> <result> ...]
    suite() {
      local class="org.sonarlint.intellij.its.tests.$1"
      shift
      {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"$class\">"
        while [ $# -gt 0 ]; do
          case "$2" in
            passed) echo "  <testcase name=\"$1\" classname=\"$class\" time=\"1.0\"/>" ;;
            failed) printf '  <testcase name="%s" classname="%s" time="1.0">\n    <failure message="boom" type="java.lang.AssertionError">boom</failure>\n  </testcase>\n' "$1" "$class" ;;
            skipped) printf '  <testcase name="%s" classname="%s" time="0.0">\n    <skipped/>\n  </testcase>\n' "$1" "$class" ;;
          esac
          shift 2
        done
        echo '</testsuite>'
      } > "$out/test-results/TEST-$class.xml"
    }
    if [ "${STUB_TESTS:-pass}" != none ]; then
      mkdir -p "$out/test-results"
      first=passed; second=passed; scenario=passed; connected=passed
      case "${STUB_TESTS:-pass}" in
        fail) second=failed ;;
        skip) second=skipped ;;
        all-skipped) first=skipped; second=skipped; scenario=skipped; connected=skipped ;;
        scenario-skipped) scenario=skipped ;;
      esac
      suite StandaloneIdeaTests "javaIssues()" "$first" "jsIssues()" "$second"
      suite CodeScanScenarioTests "openProjectDuringIndexing()" "$scenario"
      suite ConnectedAnalysisTests "should_bind_to_codescan_then_sync_then_unbind()" "$connected"
    fi
    if [ "${STUB_RUN_WAIT:-0}" = 1 ]; then
      for _ in $(seq 60); do [ -s "$STUB_KILLS" ] && exit 137; sleep 1; done
    fi
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
export STUB_KILLS="$TMP/docker-kills.txt"
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
expect_out "clean" "UI tests: 4 in total, 4 passed, 0 failed, 0 skipped"
expect_out "clean" "CodeScan total: 0"
expect_file "clean" "$TMP/out-clean/tests.txt" "tests.txt written"
expect_file "clean" "$TMP/out-clean/scan.txt" "scan.txt written"
expect_file "clean" "$TMP/out-clean/plugin/CodeScan.txt" "plugin unzipped for the container"
# The C library's memory pools are capped in the container: uncapped, the 2026.1.5 IDE held 637 MB it had already
# freed, and it was killed (exit 137) in 6 GB.
args_have "clean" "MALLOC_ARENA_MAX=2"

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

# 3b. Hits with no CodeScan frame (the IDE's own) do not fail the run, but their count is printed with the result.
STUB_LOG=ide-slow-op run ide-slow 2023.1.7
expect_code "IDE-only slow-op" 0
expect_out "IDE-only slow-op" "Log check: 0 CodeScan, 1 other (the IDE or another plugin), 0 unknown"

# 3c. A hit whose source the log check cannot tell (no stack trace) does not pass silently: exit 6, also when
#     Gradle's own log check (which fails on it too) made its-run.sh exit 5.
STUB_LOG=unknown-slow-op STUB_RC=5 run unknown 2026.1.5
expect_code "unknown hit" 6
expect_out "unknown hit" "Log check: 0 CodeScan, 0 other (the IDE or another plugin), 1 unknown"
STUB_LOG=unknown-slow-op run unknown-gradle-passed 2026.1.5
expect_code "unknown hit, Gradle passed" 6
# ... but a failed UI test still comes first.
STUB_LOG=unknown-slow-op STUB_TESTS=fail STUB_RC=5 run unknown-and-fail 2026.1.5
expect_code "unknown hit and a failed test" 5

# 4. A failed UI test: exit 5, named in the summary; the log check still runs.
STUB_TESTS=fail STUB_RC=5 run fail 2023.1.7
expect_code "failed test" 5
expect_out "failed test" "UI tests: 4 in total, 3 passed, 1 failed, 0 skipped"
expect_out "failed test" "FAILED  StandaloneIdeaTests > jsIssues()"
expect_out "failed test" "CodeScan total: 0"

# 5. A skipped UI test is named, and is not a failure.
STUB_TESTS=skip run skip 2023.1.7
expect_code "skipped test" 0
expect_out "skipped test" "skipped StandaloneIdeaTests > jsIssues()"
# ... but a run in which every test was skipped is not a pass.
STUB_TESTS=all-skipped run all-skipped 2023.1.7
expect_code "every test skipped" 5
expect_out "every test skipped" "no UI test ran"
# ... nor one in which a test class the loop is for did not run (needed unless --tests picks the tests).
STUB_TESTS=scenario-skipped run scenario-skipped 2023.1.7
expect_code "scenario skipped" 5
expect_out "scenario skipped" "CodeScanScenarioTests did not run"
STUB_TESTS=scenario-skipped run scenario-skipped-filter 2023.1.7 --tests '*StandaloneIdeaTests*'
expect_code "scenario skipped, --tests given" 0

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

# 11b. --indexing-project: mounted read-only into the container and passed on to its-run.sh; INDEXING_FILES is passed
#      on; a missing folder gives a warning and no mount.
mkdir -p "$TMP/indexing-src"
INDEXING_SRC="$(cd "$TMP/indexing-src" && pwd)"
INDEXING_FILES=12 run indexing 2023.1.7 --indexing-project "$TMP/indexing-src"
expect_code "indexing project" 0
args_have "indexing project: read-only mount" "$INDEXING_SRC:/indexing-project:ro"
args_have "indexing project: file count" "INDEXING_FILES"
args_have "indexing project: folder handed to the container command" "$INDEXING_SRC"
if grep -F -q -- '--indexing-project /indexing-project' "$STUB_ARGS"; then ok "indexing project: its-run.sh option"; else not_ok "indexing project: its-run.sh option" "missing"; fi
run indexing-missing 2023.1.7 --indexing-project "$TMP/no-such-folder"
expect_code "indexing project missing" 0
expect_out "indexing project missing" "warning: --indexing-project folder not found: $TMP/no-such-folder"
if grep -q ':/indexing-project:ro$' "$STUB_ARGS"; then not_ok "indexing project missing: no mount" "mounted"; else ok "indexing project missing: no mount"; fi

# 12. Stopped by SIGHUP (the terminal closed) or SIGTERM while the container runs: the container is stopped, exit 3.
for SIG in HUP TERM; do
  rm -f "$STUB_ARGS" "$STUB_KILLS"
  PATH="$TMP/bin:$PATH" QA_CACHE_DIR="$TMP/cache-$SIG" GRADLE_USER_HOME="$HOST_GRADLE" STUB_RUN_WAIT=1 \
    bash "$RIS" 2023.1.7 --plugin "$TMP/plugin.zip" --out "$TMP/out-$SIG" > "$TMP/$SIG.txt" 2>&1 &
  RIS_PID=$!
  wait_for_file "$STUB_ARGS" 20
  kill -"$SIG" "$RIS_PID"
  wait "$RIS_PID"; CODE=$?
  OUT="$(cat "$TMP/$SIG.txt")"
  expect_code "$SIG during the container run" 3
  if grep -q '^codescan-qa-its-' "$STUB_KILLS" 2>/dev/null; then ok "$SIG during the container run: container stopped"; else not_ok "$SIG during the container run: container stopped" "no docker kill"; fi
done

# 13. The plugin build (no --plugin): stopped at BUILD_TIMEOUT_SEC, or by a signal, together with the build process
#     Gradle detached from "./gradlew" (setsid). A copy of the scripts in a fake source tree whose gradlew plays it.
FAKE="$TMP/fake-root"
mkdir -p "$FAKE/scripts/qa" "$FAKE/gradle/wrapper"
cp "$(dirname "$RIS")"/*.sh "$(dirname "$RIS")/Dockerfile" "$FAKE/scripts/qa/"
cp "$HERE/../../gradle/wrapper/gradle-wrapper.properties" "$FAKE/gradle/wrapper/"
cat > "$FAKE/gradlew" <<'STUB'
#!/usr/bin/env bash
perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' sleep 4244 &
echo $! > "$BUILD_PID_FILE"
wait
STUB
chmod +x "$FAKE/gradlew"
export BUILD_PID_FILE="$TMP/build-java.pid"
rm -f "$BUILD_PID_FILE"
start=$(date +%s)
OUT="$(PATH="$TMP/bin:$PATH" QA_CACHE_DIR="$TMP/cache-build" BUILD_TIMEOUT_SEC=3 \
  bash "$FAKE/scripts/qa/run-ide-scenarios.sh" 2023.1.7 --out "$TMP/out-build-timeout" 2>&1)"
CODE=$?
expect_code "build time limit" 3
expect_stopped "build time limit: the detached build process" "$BUILD_PID_FILE"
if [ $(( $(date +%s) - start )) -lt 25 ]; then ok "build time limit: ended within 25 s"; else not_ok "build time limit: ended within 25 s" "took longer"; fi
rm -f "$BUILD_PID_FILE"
PATH="$TMP/bin:$PATH" QA_CACHE_DIR="$TMP/cache-build" bash "$FAKE/scripts/qa/run-ide-scenarios.sh" 2023.1.7 \
  --out "$TMP/out-build-hup" > "$TMP/build-hup.txt" 2>&1 &
RIS_PID=$!
wait_for_file "$BUILD_PID_FILE" 20
kill -HUP "$RIS_PID"
wait "$RIS_PID"; CODE=$?
OUT="$(cat "$TMP/build-hup.txt")"
expect_code "HUP during the build" 3
expect_stopped "HUP during the build: the detached build process" "$BUILD_PID_FILE"

# 14. Bad usage.
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
