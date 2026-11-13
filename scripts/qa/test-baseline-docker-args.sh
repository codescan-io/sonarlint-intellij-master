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
    bash "$BD" --plugin "$TMP/plugin.zip" --project "$TMP/project" --minutes 1 --out "$TMP/out"
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

run_bd --bogus
expect_code "unknown flag" 2
expect_out "unknown flag" "unknown argument: --bogus"

run_bd --help
expect_code "help" 0
expect_out "help" "Usage: baseline-docker.sh"
expect_out "help" "5 = the CodeScan analysis showed no result"

# Exit codes of the container run are passed on: 4 and 5 as they are, anything else that fails as 3.
run_ok_args clean 4
expect_code "container exit 4" 4
run_ok_args clean 5
expect_code "container exit 5" 5
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

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
