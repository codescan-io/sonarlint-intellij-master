#!/usr/bin/env bash
# Runs a real IntelliJ IDEA with the CodeScan plugin in a Linux Docker container on a
# virtual screen, then checks its idea.log with scan-idea-log.sh.
#
# Usage: baseline-docker.sh --plugin <plugin.zip> --project <dir>
#                           [--ide-version 2026.1.5] [--minutes 5] [--out <dir>]
# Env:   IDE_TARBALL=<file>  use this IDE tarball instead of downloading one
#        QA_CACHE_DIR        where downloaded IDE tarballs are kept (~/.cache/codescan-qa)
#        QA_DOCKER_CPUS / QA_DOCKER_MEMORY   container limits (6 / 4g)
# Exit:  0 = IDE ran, analysis ran, and the log check found no CodeScan hits
#        1 = the log check found CodeScan hits (see scan-idea-log.sh)
#        2 = bad usage
#        3 = the IDE or the container did not run (no usable idea.log)
#        4 = the IDE exited before the run time was up
#        5 = the CodeScan analysis showed no result for Hello.java (read from a screenshot)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
IDE_VERSION=2026.1.5
MINUTES=5
PLUGIN=""
PROJECT=""
OUT=""
IMAGE=codescan-qa-ide:1

usage() { sed -n '2,15p' "$0" >&2; exit 2; }
# A flag that needs a value must have one; a missing value is a usage error, not a reason to loop.
need_value() { [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: $1 needs a value" >&2; usage; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    --plugin) need_value "$@"; PLUGIN="$2"; shift 2 ;;
    --project) need_value "$@"; PROJECT="$2"; shift 2 ;;
    --ide-version) need_value "$@"; IDE_VERSION="$2"; shift 2 ;;
    --minutes) need_value "$@"; MINUTES="$2"; shift 2 ;;
    --out) need_value "$@"; OUT="$2"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done
[ -f "$PLUGIN" ] || { echo "error: --plugin <zip> is required and must exist" >&2; usage; }
[ -d "$PROJECT" ] || { echo "error: --project <dir> is required and must exist" >&2; usage; }
case "$MINUTES" in ''|*[!0-9]*) echo "error: --minutes must be a whole number" >&2; usage ;; esac
PLUGIN="$(cd "$(dirname "$PLUGIN")" && pwd)/$(basename "$PLUGIN")"
PROJECT="$(cd "$PROJECT" && pwd)"
[ -n "$OUT" ] || OUT="$HERE/../../build/qa/ide-$IDE_VERSION-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)"

docker info >/dev/null 2>&1 || { echo "error: Docker is not running" >&2; exit 3; }

if [ -z "${IDE_TARBALL:-}" ]; then
  case "$(docker info --format '{{.Architecture}}')" in
    aarch64|arm64) SUFFIX="-aarch64" ;;
    *) SUFFIX="" ;;
  esac
  CACHE="${QA_CACHE_DIR:-$HOME/.cache/codescan-qa}"
  mkdir -p "$CACHE"
  IDE_TARBALL="$CACHE/idea-$IDE_VERSION$SUFFIX.tar.gz"
  if [ ! -f "$IDE_TARBALL" ]; then
    URL="https://download.jetbrains.com/idea/idea-$IDE_VERSION$SUFFIX.tar.gz"
    echo "downloading $URL"
    curl -fsSL --connect-timeout 30 --max-time 60 --retry 3 -o "$IDE_TARBALL.sha256" "$URL.sha256" \
      && curl -fSL --connect-timeout 30 --max-time 1800 --retry 3 -o "$IDE_TARBALL.part" "$URL" \
      || { rm -f "$IDE_TARBALL.part" "$IDE_TARBALL.sha256"; echo "error: IDE download failed" >&2; exit 3; }
    WANT="$(awk '{print $1}' "$IDE_TARBALL.sha256")"
    GOT="$(shasum -a 256 "$IDE_TARBALL.part" 2>/dev/null || sha256sum "$IDE_TARBALL.part")"
    GOT="${GOT%% *}"
    if [ "$WANT" != "$GOT" ]; then
      rm -f "$IDE_TARBALL.part"; echo "error: IDE checksum mismatch" >&2; exit 3
    fi
    mv "$IDE_TARBALL.part" "$IDE_TARBALL"
  fi
fi
[ -f "$IDE_TARBALL" ] || { echo "error: IDE tarball not found: $IDE_TARBALL" >&2; exit 3; }

# Waits for background job $1 for at most $2 seconds; runs $3 (a command) if time runs out.
# Returns the job's exit code.
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

echo "building image $IMAGE"
docker build -q -t "$IMAGE" -f "$HERE/Dockerfile" "$HERE" >/dev/null &
wait_bounded $! 900 'kill $pid' || { echo "error: docker build failed" >&2; exit 3; }

NAME="codescan-qa-$$"
trap 'docker kill "$NAME" >/dev/null 2>&1; exit 3' INT TERM
echo "running IDE $IDE_VERSION for $MINUTES min; results in $OUT"
docker run --rm --name "$NAME" --cpus "${QA_DOCKER_CPUS:-6}" --memory "${QA_DOCKER_MEMORY:-4g}" --shm-size 1g \
  -e RUN_MINUTES="$MINUTES" \
  -v "$IDE_TARBALL:/ide.tar.gz:ro" \
  -v "$PLUGIN:/plugin.zip:ro" \
  -v "$PROJECT:/src-project:ro" \
  -v "$HERE/ide-in-container.sh:/ide-in-container.sh:ro" \
  -v "$OUT:/out" \
  "$IMAGE" bash /ide-in-container.sh &
# Upper bound on the whole container run: the IDE run itself plus start-up and shutdown.
wait_bounded $! $(( (MINUTES + 15) * 60 )) 'docker kill "$NAME" >/dev/null 2>&1'
RC=$?
# The container's own codes 4 and 5 are passed on as they are; any other failure is 3.
case "$RC" in
  0) ;;
  4) echo "error: the IDE exited before the run time was up; see $OUT/run.log and $OUT/screens" >&2; exit 4 ;;
  5) echo "error: the CodeScan analysis did not run; see $OUT/run.log and $OUT/screens" >&2; exit 5 ;;
  *) echo "error: the IDE run failed (exit $RC); see $OUT/run.log and $OUT/screens" >&2; exit 3 ;;
esac
if [ ! -s "$OUT/log/idea.log" ]; then
  echo "error: the IDE run left no idea.log; see $OUT/run.log and $OUT/screens" >&2
  exit 3
fi

# --freeze-dumps lets the check tell a freeze caused by CodeScan from one caused by the IDE or another plugin.
bash "$HERE/scan-idea-log.sh" --freeze-dumps "$OUT/log" "$OUT/log/idea.log" > "$OUT/scan.txt"
SCAN_RC=$?
sed -n '/^Summary:/,$p' "$OUT/scan.txt"
echo "full log check: $OUT/scan.txt"
exit "$SCAN_RC"
