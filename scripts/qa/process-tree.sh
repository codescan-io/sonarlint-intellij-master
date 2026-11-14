# Sourced by its-run.sh and run-ide-scenarios.sh: stops a process together with every process it started.
# Gradle's build process detaches itself (it calls setsid), so killing the process group of "./gradlew" misses it,
# and killing only "./gradlew" leaves the build running. The process tree, read from parent IDs, still has it.
# Works with macOS bash 3.2 and Linux bash; needs pgrep and ps.

# Prints the process IDs of the given processes and of all their descendants, parents first.
process_tree() {
  local pid
  for pid in "$@"; do
    echo "$pid"
    # shellcheck disable=SC2046
    process_tree $(pgrep -P "$pid" 2>/dev/null)
  done
}

# True while process $1 runs (a process that ended but was not yet collected by its parent does not count).
process_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*|"") return 1 ;; esac
  return 0
}

# Stops process $1 and its whole tree: SIGTERM to all of them at once, then SIGKILL to whatever still runs after
# $2 seconds (default 10). The tree is read before anything is stopped, as a stopped parent's children move to init.
stop_tree() {
  local root=${1:-} secs=${2:-10} pids alive p deadline
  [ -n "$root" ] || return 0
  pids="$(process_tree "$root")"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  deadline=$(( $(date +%s) + secs ))
  while :; do
    alive=""
    for p in $pids; do process_alive "$p" && alive="$alive $p"; done
    [ -n "$alive" ] || return 0
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 1
  done
  echo "warning: still running $secs s after SIGTERM, killing:$alive" >&2
  # shellcheck disable=SC2086
  kill -KILL $alive 2>/dev/null
  return 0
}
