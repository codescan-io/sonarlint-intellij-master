#!/usr/bin/env bash
# Layer 3 of the QA loop: runs the Remote-Robot UI tests (its/) against a real IntelliJ IDEA with the CodeScan plugin,
# by default in a Linux Docker container on a virtual screen, then checks the IDE's idea.log with scan-ide-logs.sh.
#
# Usage: run-ide-scenarios.sh <ide-version> [--foreground] [--plugin <plugin.zip>] [--tests <filter>] [--out <dir>]
#   <ide-version>  2023.1.7, 2026.1.5, ...: IntelliJ IDEA Community (IC) before 2025.3, the single IntelliJ IDEA (IU)
#                  from 2025.3 on. A full Gradle value such as IC-2024.1.7 or IU-2026.1.5 is used as it is.
#   --foreground   run on this machine's own screen instead of in Docker (for debugging). The UI tests move the mouse
#                  and type; keep your hands off until it ends.
#   --plugin       test this plugin zip instead of building one with ./gradlew buildPlugin (which needs CodeArtifact
#                  access, see CLAUDE.md). The CodeArtifact token never goes into the container.
#   --tests        only these UI tests (a Gradle --tests filter such as '*CodeScanScenarioTests*')
#   --out          results folder (default build/qa/<ide-version>; emptied first)
# Env:   QA_CACHE_DIR      the container's Gradle cache, with the downloaded IDEs, is kept in $QA_CACHE_DIR/gradle-home
#                          (default ~/.cache/codescan-qa)
#        QA_DOCKER_CPUS / QA_DOCKER_MEMORY   container limits (6 / 6g)
#        PREPARE_TIMEOUT_SEC, START_TIMEOUT_SEC, TEST_TIMEOUT_SEC: see its-run.sh
# Results in <out>: tests.txt (UI test results), scan.txt (full log check), log/ (idea.log, freeze dumps), test-report/,
#        test-results/, gradle-*.log, screens/
# Exit:  0 = the UI tests passed and the log check found no CodeScan hits
#        1 = the UI tests passed and the log check found CodeScan hits
#        2 = bad usage
#        3 = the run did not happen (Docker not running, plugin build failed, the IDE did not start, no idea.log)
#        4 = the log check itself failed for some log (scan-ide-logs.sh exit 3 or 4); the result is incomplete
#        5 = some UI tests failed or did not run to the end, no UI test ran (all skipped), or, without --tests, one of
#            the test classes this loop is for ($REQUIRED_CLASSES below) did not run. The log check is still done
#            and printed.
# The log check fails the run only for CodeScan hits. Hits from the IDE or another plugin ("other") and hits whose
# source it cannot tell ("unknown") are counted on the "Log check:" line; read scan.txt for them.
# Works with macOS bash 3.2 and Linux bash.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE=codescan-qa-ide:1
VERSION=""
FOREGROUND=0
PLUGIN=""
TESTS=""
OUT=""

usage() { sed -n '2,/^set -u/{/^set -u/!p;}' "$0" >&2; exit 2; }
need_value() { [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: $1 needs a value" >&2; usage; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^set -u/{/^set -u/!p;}' "$0"; exit 0 ;;
    --foreground) FOREGROUND=1; shift ;;
    --plugin) need_value "$@"; PLUGIN="$2"; shift 2 ;;
    --tests) need_value "$@"; TESTS="$2"; shift 2 ;;
    --out) need_value "$@"; OUT="$2"; shift 2 ;;
    -*) echo "error: unknown argument: $1" >&2; usage ;;
    *) [ -z "$VERSION" ] || { echo "error: only one <ide-version>" >&2; usage; }; VERSION="$1"; shift ;;
  esac
done
[ -n "$VERSION" ] || { echo "error: <ide-version> is required" >&2; usage; }

# JetBrains ships one IntelliJ IDEA (product code IU) from 2025.3 on; before that the free edition is IC.
case "$VERSION" in
  [A-Z][A-Z]-[0-9]*) IJ_VERSION="$VERSION" ;;
  20[0-9][0-9].[0-9]*)
    YEAR="${VERSION%%.*}"; REST="${VERSION#*.}"; RELEASE="${REST%%.*}"
    case "$RELEASE" in ''|*[!0-9]*) echo "error: cannot read the IDE version: $VERSION" >&2; usage ;; esac
    if [ "$YEAR" -gt 2025 ] || { [ "$YEAR" -eq 2025 ] && [ "$RELEASE" -ge 3 ]; }; then IJ_VERSION="IU-$VERSION"; else IJ_VERSION="IC-$VERSION"; fi ;;
  *) echo "error: cannot read the IDE version: $VERSION" >&2; usage ;;
esac
if [ -n "$PLUGIN" ]; then
  [ -f "$PLUGIN" ] || { echo "error: --plugin must be an existing zip" >&2; usage; }
  PLUGIN="$(cd "$(dirname "$PLUGIN")" && pwd)/$(basename "$PLUGIN")"
fi
[ -n "$OUT" ] || OUT="$ROOT/build/qa/$VERSION"
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)" || exit 2
HOME_DIR="$(cd "$HOME" 2>/dev/null && pwd)"
case "$OUT" in /|"$HOME_DIR"|"$ROOT") echo "error: --out must be a results folder of its own" >&2; usage ;; esac
# A reused folder must not leave an old idea.log or test result to pass for this run.
rm -rf "$OUT/log" "$OUT/test-results" "$OUT/test-report" "$OUT/screens" "$OUT/plugin" "$OUT"/gradle-*.log \
  "$OUT/gradle-log-check.txt" "$OUT/scan.txt" "$OUT/tests.txt" "$OUT/run.log"

# Waits for background job $1 for at most $2 seconds; runs $3 (a command) if time runs out. Returns the job's exit code.
wait_bounded() {
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "error: still running after $2 s, stopping it" >&2
      eval "$3"
      break
    fi
    sleep 1
  done
  wait "$pid"
}

if [ "$FOREGROUND" -eq 0 ]; then
  docker info >/dev/null 2>&1 || { echo "error: Docker is not running" >&2; exit 3; }
fi

if [ -z "$PLUGIN" ]; then
  echo "building the plugin (log: $OUT/gradle-build-plugin.log)"
  ( cd "$ROOT" && ./gradlew --console=plain buildPlugin ) > "$OUT/gradle-build-plugin.log" 2>&1 &
  wait_bounded $! 1800 'kill $pid' || { echo "error: ./gradlew buildPlugin failed; see $OUT/gradle-build-plugin.log" >&2; exit 3; }
  PLUGIN="$(ls -t "$ROOT"/build/distributions/CodeScan-*.zip 2>/dev/null | grep -v blockmap | head -1)"
  [ -f "$PLUGIN" ] || { echo "error: no plugin zip in $ROOT/build/distributions" >&2; exit 3; }
fi
mkdir -p "$OUT/plugin" && unzip -q "$PLUGIN" -d "$OUT/plugin" || { echo "error: cannot unzip $PLUGIN" >&2; exit 3; }
echo "plugin: $PLUGIN"
echo "IDE: $IJ_VERSION; results in $OUT"

if [ "$FOREGROUND" -eq 1 ]; then
  bash "$HERE/its-run.sh" --src "$ROOT" --plugin-dir "$OUT/plugin" --ij-version "$IJ_VERSION" --out "$OUT" \
    ${TESTS:+--tests "$TESTS"} 2>&1 | tee "$OUT/run.log"
  RC=${PIPESTATUS[0]}
else
  echo "building image $IMAGE"
  docker build -q -t "$IMAGE" -f "$HERE/Dockerfile" "$HERE" >/dev/null &
  wait_bounded $! 900 'kill $pid' || { echo "error: docker build failed" >&2; exit 3; }
  CACHE="${QA_CACHE_DIR:-$HOME/.cache/codescan-qa}"
  mkdir -p "$CACHE/gradle-home"
  # The Gradle wrapper gives up on a connection after 10 s, which its download from GitHub often needs from inside
  # Docker. So the container starts with this machine's unpacked copy of the same Gradle, when there is one. The
  # wrapper trusts a copy only next to its <name>.zip.ok marker; a folder without one is a failed download.
  DIST="$(sed -n 's#^distributionUrl=.*/\(gradle-[^/]*\)\.zip$#\1#p' "$ROOT/gradle/wrapper/gradle-wrapper.properties")"
  HOST_DISTS="${GRADLE_USER_HOME:-$HOME/.gradle}/wrapper/dists"
  for MARKER in "$HOST_DISTS/$DIST"/*/"$DIST.zip.ok"; do
    [ -n "$DIST" ] && [ -f "$MARKER" ] || continue
    SRC_DIR="$(dirname "$MARKER")"
    DEST_DIR="$CACHE/gradle-home/wrapper/dists/$DIST/$(basename "$SRC_DIR")"
    [ -f "$DEST_DIR/$DIST.zip.ok" ] && continue
    rm -rf "$DEST_DIR" "$DEST_DIR.copying" && mkdir -p "$(dirname "$DEST_DIR")" &&
      cp -R "$SRC_DIR" "$DEST_DIR.copying" && mv "$DEST_DIR.copying" "$DEST_DIR" ||
      echo "warning: could not copy Gradle $DIST into $CACHE; the container will download it" >&2
  done
  # The container's Gradle may use 2 GB per daemon, not the 8 GB the project asks for on a developer machine.
  printf '%s\n' "org.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=512M -Dfile.encoding=UTF-8" > "$CACHE/gradle-home/gradle.properties"
  NAME="codescan-qa-its-$$"
  trap 'docker kill "$NAME" >/dev/null 2>&1; exit 3' INT TERM
  # The sources are copied inside the container, so its build output never lands in this tree.
  # MALLOC_ARENA_MAX: uncapped, the C library keeps up to 8 memory pools per CPU in each Java process and holds on to
  # freed memory; the 2026.1.5 IDE held 637 MB that way and was killed (exit 137) in 6 GB.
  docker run --rm --name "$NAME" --cpus "${QA_DOCKER_CPUS:-6}" --memory "${QA_DOCKER_MEMORY:-6g}" --shm-size 1g \
    -e MALLOC_ARENA_MAX=2 \
    -e PREPARE_TIMEOUT_SEC -e START_TIMEOUT_SEC -e TEST_TIMEOUT_SEC \
    -v "$ROOT:/src:ro" \
    -v "$OUT/plugin:/plugin:ro" \
    -v "$CACHE/gradle-home:/home/qa/.gradle" \
    -v "$OUT:/out" \
    "$IMAGE" bash -c '
      mkdir -p /work/src &&
      tar -C /src --exclude=./.git --exclude=./.gradle --exclude=./build --exclude="./*/build" --exclude=./.worktrees \
          --exclude=./.superpowers --exclude=./.idea --exclude="./its/projects/*-tmp" -cf - . | tar -C /work/src -xf - &&
      exec bash /work/src/scripts/qa/its-run.sh --src /work/src --plugin-dir /plugin --ij-version "$0" --out /out --xvfb ${1:+--tests "$1"}
    ' "$IJ_VERSION" "$TESTS" > "$OUT/run.log" 2>&1 &
  # Upper bound on the whole container run: preparation, IDE start, the tests, and the IDE stop.
  wait_bounded $! $(( ${PREPARE_TIMEOUT_SEC:-3600} + ${START_TIMEOUT_SEC:-600} + ${TEST_TIMEOUT_SEC:-5400} + 600 )) \
    'docker kill "$NAME" >/dev/null 2>&1'
  RC=$?
  cat "$OUT/run.log"
fi

case "$RC" in
  0|5) ;;
  *) echo "error: the UI test run did not happen (exit $RC); see $OUT/run.log" >&2
     [ -s "$OUT/log/idea.log" ] || exit 3 ;;
esac

# The test classes a full run (no --tests) must have run at least one test of. A skipped test did not run: JUnit
# skips a whole class when, for example, an @EnabledIf condition is false, and that must not pass as a clean run.
REQUIRED_CLASSES="CodeScanScenarioTests ConnectedAnalysisTests StandaloneIdeaTests"

# UI test results from the JUnit XML files: totals, then the name of every failed and skipped test. Fails when a test
# failed, when no test ran, or when a required class did not run.
summarize_tests() {
  local required=""
  [ -n "$TESTS" ] || required="$REQUIRED_CLASSES"
  set -- "$OUT"/test-results/*.xml
  [ -f "$1" ] || { echo "UI tests: no results (the tests did not run)"; return 1; }
  awk -v required="$required" '
    # A test that was not skipped ran (passed or failed).
    function close_case() {
      if (current != "") { ran[cur_cls]++; nran++ }
      current = ""
    }
    /<testcase / {
      close_case()
      name = $0; sub(/.* name="/, "", name); sub(/".*/, "", name)
      cls = $0; sub(/.* classname="/, "", cls); sub(/".*/, "", cls); sub(/.*\./, "", cls)
      current = cls " > " name; cur_cls = cls; total++
      if ($0 ~ /\/>[ \t]*$/) close_case()
    }
    /<failure|<error/ && current != "" { failed[++nf] = current; close_case() }
    /<skipped/ && current != "" { skipped[++ns] = current; current = "" }
    /<\/testcase>/ { close_case() }
    END {
      close_case()
      printf "UI tests: %d in total, %d passed, %d failed, %d skipped\n", total, total - nf - ns, nf, ns
      for (i = 1; i <= nf; i++) print "  FAILED  " failed[i]
      for (i = 1; i <= ns; i++) print "  skipped " skipped[i]
      bad = (nf > 0)
      if (nran == 0) { print "  error: no UI test ran"; bad = 1 }
      n = split(required, req, " ")
      for (i = 1; i <= n; i++) if (!(req[i] in ran)) { print "  error: " req[i] " did not run"; bad = 1 }
      exit bad
    }
  ' "$@"
}
summarize_tests > "$OUT/tests.txt"
TESTS_OK=$?
cat "$OUT/tests.txt"

SCAN_RC=3
if [ -d "$OUT/log" ]; then
  bash "$HERE/scan-ide-logs.sh" "$OUT/log" "$OUT/scan.txt"
  SCAN_RC=$?
  # One line with every count, summed over all patterns and logs, so that hits which do not fail the run are seen.
  [ -f "$OUT/scan.txt" ] && awk '
    /^    CodeScan: [0-9]+  other: [0-9]+  unknown: [0-9]+/ { c += $2; o += $4; u += $6 }
    END {
      printf "Log check: %d CodeScan, %d other (the IDE or another plugin), %d unknown (cannot tell; read scan.txt)\n", c, o, u
      if (u > 0) print "warning: the log check cannot tell where " u " hit(s) came from; read " FILENAME
    }
  ' "$OUT/scan.txt"
else
  echo "error: the run left no IDE log folder" >&2
fi

[ "$RC" -ne 0 ] && [ "$RC" -ne 5 ] && exit 3
case "$SCAN_RC" in 3|4) exit 4 ;; 0|1) ;; *) exit 4 ;; esac
[ "$RC" -eq 5 ] && [ "$TESTS_OK" -eq 0 ] && [ "$SCAN_RC" -eq 0 ] && { echo "error: :its:test failed but no UI test did; see $OUT/gradle-test.log" >&2; exit 5; }
[ "$TESTS_OK" -ne 0 ] && exit 5
exit "$SCAN_RC"
