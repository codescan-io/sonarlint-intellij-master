#!/usr/bin/env bash
# Checks every idea*.log in an IDE log folder with scan-idea-log.sh and writes the full result to a report file.
# Prints, per log, the distinct stack tops and the summary. The freeze thread dumps are read from the same folder.
#
# Usage: scan-ide-logs.sh <IDE log folder> <report file>
# Exit:  0 = no CodeScan hits in any log
#        1 = at least one CodeScan hit (see scan-idea-log.sh)
#        2 = bad usage, or the folder does not exist
#        3 = the folder has no idea.log (the IDE did not run, or wrote its log elsewhere)
#        4 = the check failed for some log (unreadable file); the result is incomplete, so this beats 1
#        6 = no CodeScan hits, but some hits whose source the log check cannot tell ("unknown", for example a slow
#            operation logged with no stack trace). They might be CodeScan's, so they must not pass as a clean log;
#            read the report. 1 beats 6. Hits from the IDE or another plugin ("other") do not change the exit code.
# Works with macOS bash 3.2 and Linux bash.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
usage() { echo "usage: $(basename "$0") <IDE log folder> <report file>" >&2; exit 2; }
[ $# -eq 2 ] || usage
LOG_DIR="$1"
REPORT="$2"
[ -d "$LOG_DIR" ] || { echo "error: no such log folder: $LOG_DIR" >&2; exit 2; }
mkdir -p "$(dirname "$REPORT")" || exit 2
: > "$REPORT" || exit 2

# IntelliJ rotates idea.log to idea.1.log, idea.2.log, ..., so every idea*.log in the folder is checked.
FOUND=0
RC=0
SCAN_FAILED=0
for LOG in "$LOG_DIR"/idea*.log; do
  [ -f "$LOG" ] || continue
  FOUND=1
  {
    echo "##### $(basename "$LOG")"
    bash "$HERE/scan-idea-log.sh" --freeze-dumps "$LOG_DIR" -- "$LOG"
  } >> "$REPORT" 2>&1
  SCAN_RC=$?
  case "$SCAN_RC" in
    0) ;;
    1) RC=1 ;;
    *) SCAN_FAILED=1; echo "error: log check failed for $LOG (exit $SCAN_RC); see $REPORT" >&2 ;;
  esac
done
if [ "$FOUND" -eq 0 ]; then
  echo "error: no idea.log in $LOG_DIR" | tee -a "$REPORT" >&2
  exit 3
fi

awk '/^##### /{print; s=0; next} /^Distinct stack tops/{s=1} s' "$REPORT"
echo "full log check: $REPORT"
# Every pattern's split line reads "    CodeScan: <n>  other: <n>  unknown: <n>"; summed over all patterns and logs.
UNKNOWN="$(awk '/^    CodeScan: [0-9]+  other: [0-9]+  unknown: [0-9]+/ { u += $6 } END { print u + 0 }' "$REPORT")"
[ "$SCAN_FAILED" -eq 1 ] && exit 4
[ "$RC" -eq 1 ] && exit 1
if [ "$UNKNOWN" -gt 0 ]; then
  echo "error: $UNKNOWN hit(s) whose source the log check cannot tell (unknown); they might be CodeScan's: read $REPORT" >&2
  exit 6
fi
exit 0
