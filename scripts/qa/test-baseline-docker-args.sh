#!/usr/bin/env bash
# Tests for baseline-docker.sh that need no real Docker: a stub "docker" program is put first on PATH.
# Run: bash scripts/qa/test-baseline-docker-args.sh
# Env: BD=<path>  the baseline-docker.sh to test (default: the one next to this file).
# Works with macOS bash 3.2 and Linux bash.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BD="${BD:-$HERE/baseline-docker.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/baseline-docker-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

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

# The stub: answers info/build/kill, and for "run" writes a fake result into the folder mounted as /out.
# STUB_MODE = freeze-cs (a freeze whose UI thread is in CodeScan code), clean (no hits), none (no idea.log).
# STUB_RC   = the exit code of "docker run".
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  info) [ "${2:-}" = "--format" ] && echo x86_64; exit 0 ;;
  build|kill) exit 0 ;;
  run)
    out=""
    prev=""
    for a in "$@"; do
      case "$a" in *:/out) [ "$prev" = "-v" ] && out="${a%:/out}" ;; esac
      prev="$a"
    done
    [ -n "$out" ] || exit 99
    mkdir -p "$out/log"
    case "${STUB_MODE:-clean}" in
      freeze-cs)
        d="threadDumps-freeze-20261113-100000-IU-261.1-9sec"
        mkdir -p "$out/log/$d"
        {
          echo '"AWT-EventQueue-0" prio=0 tid=0x0 nid=0x0 runnable'
          echo "     java.lang.Thread.State: RUNNABLE"
          echo ""
          echo "	at org.sonarlint.intellij.ui.SomePanel.paint(SomePanel.java:10)"
          echo ""
        } > "$out/log/$d/threadDump-20261113-100001.txt"
        echo "2026-11-13 10:00:09,500 [ 1000]  WARN - #c.i.d.PerformanceWatcherImpl - UI was frozen for 9000ms, details saved to /x/$d" > "$out/log/idea.log" ;;
      clean)
        echo "2026-11-13 10:00:00,100 [ 1000]  INFO - #c.i.Foo - all fine" > "$out/log/idea.log" ;;
      rotated)
        # idea.log is clean; the CodeScan error is in the rotated idea.1.log.
        echo "2026-11-13 10:00:00,100 [ 1000]  INFO - #c.i.Foo - all fine" > "$out/log/idea.log"
        echo "2026-11-13 09:00:00,100 [ 1000] SEVERE - #org.sonarlint.intellij.Foo - boom" > "$out/log/idea.1.log" ;;
      unreadable)
        echo "2026-11-13 10:00:00,100 [ 1000]  INFO - #c.i.Foo - all fine" > "$out/log/idea.log"
        chmod 000 "$out/log/idea.log" ;;
      none) : ;;
    esac
    exit "${STUB_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/docker"

echo dummy > "$TMP/ide.tar.gz"
echo dummy > "$TMP/plugin.zip"
mkdir -p "$TMP/project"

# Runs a command in the background and waits at most $LIMIT_TENTHS tenths of a second. A command still
# running then is a hang: it is stopped and CODE is 99.
LIMIT_TENTHS=80
run_bounded() {
  local out="$TMP/bounded.out" pid n=0
  "$@" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -gt "$LIMIT_TENTHS" ]; then
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      CODE=99; OUT="still running after $((LIMIT_TENTHS / 10)) s (hang)
$(cat "$out")"
      return
    fi
    sleep 0.1
  done
  wait "$pid"; CODE=$?
  OUT="$(cat "$out")"
}

run_bd() {
  run_bounded env PATH="$TMP/bin:$PATH" IDE_TARBALL="$TMP/ide.tar.gz" bash "$BD" "$@"
}
# A stub run goes through the script's own polling, so it gets more time than an argument check.
run_ok_args() {
  rm -rf "$TMP/out"
  LIMIT_TENTHS=600
  run_bounded env PATH="$TMP/bin:$PATH" IDE_TARBALL="$TMP/ide.tar.gz" STUB_MODE="$1" STUB_RC="$2" \
    bash "$BD" --plugin "$TMP/plugin.zip" --project "$TMP/project" --minutes "${3:-4}" --out "$TMP/out"
  LIMIT_TENTHS=80
}

# A flag with no value must be a usage error, not a loop that never ends.
for flag in --plugin --project --ide-version --minutes --out; do
  run_bd "$flag"
  expect_code "missing value for $flag" 2
  expect_out "missing value for $flag" "needs a value"
done
run_bd --plugin "$TMP/plugin.zip" --project "$TMP/project" --minutes
expect_code "missing value at the end" 2
run_bd --plugin ""
expect_code "empty value" 2

# The scripted steps alone take about 3 minutes, so a shorter run time cannot be a real run.
for m in 0 1 3; do
  run_bd --plugin "$TMP/plugin.zip" --project "$TMP/project" --minutes "$m" --out "$TMP/out-min"
  expect_code "minutes $m" 2
  expect_out "minutes $m" "at least 4"
done
run_bd --plugin "$TMP/plugin.zip" --project "$TMP/project" --minutes abc --out "$TMP/out-min"
expect_code "minutes not a number" 2

run_bd --bogus
expect_code "unknown flag" 2
expect_out "unknown flag" "unknown argument: --bogus"

run_bd --help
expect_code "help" 0
expect_out "help" "Usage: baseline-docker.sh"
expect_out "help" "5 = the CodeScan analysis showed no result"
expect_out "help" "6 = the log check itself failed"
# Exit 4 has three causes in ide-in-container.sh; the help and the error must not name only the first one.
expect_out "help" "4 = the IDE did not run and stop normally"
expect_out "help" "7 = the CodeScan plugin was not loaded"

# Exit codes of the container run are passed on: 4 and 5 as they are, anything else that fails as 3.
run_ok_args clean 4
expect_code "container exit 4" 4
expect_out "container exit 4" "the IDE did not run and stop normally (it exited early, or stopped without the IDE SHUTDOWN line, or had to be killed)"
run_ok_args clean 5
expect_code "container exit 5" 5
# On 4 and 5 the IDE ran, so its log is still checked and scan.txt saved, but the exit code stays 4 or 5.
run_ok_args rotated 4
expect_code "container exit 4 with a CodeScan error" 4
expect_out "container exit 4 with a CodeScan error" "CodeScan total: 1"
if [ -s "$TMP/out/scan.txt" ]; then ok "container exit 4: scan.txt saved"; else not_ok "container exit 4: scan.txt saved" "missing"; fi
run_ok_args freeze-cs 5
expect_code "container exit 5 with a CodeScan freeze" 5
expect_out "container exit 5 with a CodeScan freeze" "CodeScan total: 1"
if [ -s "$TMP/out/scan.txt" ]; then ok "container exit 5: scan.txt saved"; else not_ok "container exit 5: scan.txt saved" "missing"; fi
run_ok_args unreadable 4
expect_code "container exit 4, scanner fails" 4
expect_out "container exit 4, scanner fails" "log check failed"
run_ok_args none 4
expect_code "container exit 4, no idea.log" 4
run_ok_args clean 7
expect_code "container exit 7" 7
expect_out "container exit 7" "CodeScan plugin was not loaded"
run_ok_args clean 3
expect_code "container exit 3" 3
run_ok_args clean 1
expect_code "container exit 1 is a failure" 3
run_ok_args clean 125
expect_code "container exit 125" 3
run_ok_args none 0
expect_code "no idea.log" 3

run_ok_args clean 0
expect_code "clean run" 0
expect_out "clean run" "CodeScan total: 0"

# The freeze is judged from its dump folder, so --freeze-dumps must reach the scanner.
run_ok_args freeze-cs 0
expect_code "CodeScan freeze" 1
expect_out "CodeScan freeze" "CodeScan total: 1"

# Every idea*.log is checked, not only idea.log (IntelliJ rotates it to idea.1.log, idea.2.log, ...).
run_ok_args rotated 0
expect_code "rotated log has a CodeScan error" 1
expect_out "rotated log has a CodeScan error" "CodeScan total: 1"
expect_out "rotated log has a CodeScan error" "idea.1.log"

# A scanner that cannot do its job is its own exit code (6), not "bad usage" (2).
run_ok_args unreadable 0
expect_code "scanner fails" 6
expect_out "scanner fails" "log check failed"

# A reused --out folder must not leave an old idea.log to pass for the new run.
# (The "scanner fails" run above left an unreadable idea.log there, so the folder is made afresh.)
rm -rf "$TMP/out"
mkdir -p "$TMP/out/log"
echo "2026-11-13 10:00:00,100 [ 1000] SEVERE - #org.sonarlint.intellij.Foo - old run" > "$TMP/out/log/idea.log"
LIMIT_TENTHS=600
run_bounded env PATH="$TMP/bin:$PATH" IDE_TARBALL="$TMP/ide.tar.gz" STUB_MODE=none STUB_RC=0 \
  bash "$BD" --plugin "$TMP/plugin.zip" --project "$TMP/project" --minutes 4 --out "$TMP/out"
LIMIT_TENTHS=80
expect_code "stale idea.log in a reused out folder" 3

# The smallest allowed run time is accepted.
run_ok_args clean 0 4
expect_code "minutes 4" 0

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
