#!/usr/bin/env bash
# Scans an IntelliJ idea.log for threading errors and CodeScan plugin errors.
# Prints each hit with the following 15 lines of its log entry, a count per pattern,
# and the distinct stack-trace tops with how often each happened.
#
# Usage: scan-idea-log.sh <idea.log>
# Exit:  0 = no hits, 1 = at least one hit, 2 = bad usage or unreadable file.
# Works with macOS bash 3.2 / BSD awk and Linux bash / mawk / gawk.
set -u

if [ $# -ne 1 ]; then
  echo "usage: $(basename "$0") <idea.log>" >&2
  exit 2
fi
LOG="$1"
if [ ! -f "$LOG" ] || [ ! -r "$LOG" ]; then
  echo "error: cannot read log file: $LOG" >&2
  exit 2
fi

awk -v context=15 '
BEGIN {
  n = 0
  pat[++n] = "Slow operations are prohibited on EDT"
  pat[++n] = "Read access is allowed from inside read-action"
  pat[++n] = "Access is allowed from Event Dispatch Thread"
  pat[++n] = "UI was frozen"
  fixedPatterns = n
  sonarLogger = ++n
  pat[sonarLogger] = "ERROR from org.sonarlint logger"
  sonarTrace = ++n
  pat[sonarTrace] = "ERROR with org.sonarlint in its stack trace"
  for (i = 1; i <= n; i++) count[i] = 0
  lines = 0
  tops = 0
}

# The plugin ships its core library under org.sonarsource.sonarlint, so both count as CodeScan code.
function isPluginFrame(s) { return s ~ /org\.sonar(lint|source\.sonarlint)\./ }

# A frame line looks like "\tat pkg.Class.method(File.java:12)".
function frameText(s) { sub(/^[ \t]+at /, "", s); return s }

# The 2 frames above the first CodeScan frame, then that frame. Raw first frames are the
# same logging/assertion plumbing for every hit, so they would not tell traces apart.
function stackTop(   i, f, nf, first, from, key) {
  nf = 0; first = 0
  for (i = 2; i <= lines; i++) {
    if (buf[i] ~ /^[ \t]+at /) {
      frame[++nf] = frameText(buf[i])
      if (!first && isPluginFrame(buf[i])) first = nf
    } else if (nf > 0) break
  }
  if (nf == 0) return "(no stack trace)"
  if (!first) first = (nf < 3 ? nf : 3)
  from = (first > 2 ? first - 2 : 1)
  key = ""
  for (f = from; f <= first; f++) key = key "\n      " frame[f]
  return key
}

function flush(   i, j, hit, matched, isError, key, last) {
  if (lines == 0) return
  hit = ""
  for (i = 1; i <= fixedPatterns; i++) {
    matched = 0
    for (j = 1; j <= lines && !matched; j++) if (index(buf[j], pat[i]) > 0) matched = 1
    if (matched) { count[i]++; hit = hit (hit == "" ? "" : ", ") pat[i] }
  }
  isError = (buf[1] ~ /(ERROR|SEVERE) - /)
  if (isError && buf[1] ~ /(ERROR|SEVERE) - #?org\.sonar(lint|source\.sonarlint)\./) {
    count[sonarLogger]++; hit = hit (hit == "" ? "" : ", ") pat[sonarLogger]
  } else if (isError && hit == "") {
    matched = 0
    for (j = 2; j <= lines && !matched; j++) if (buf[j] ~ /^[ \t]+at / && isPluginFrame(buf[j])) matched = 1
    if (matched) { count[sonarTrace]++; hit = pat[sonarTrace] }
  }
  if (hit != "") {
    print "=== " hit " (line " startLine ") ==="
    last = (lines < context + 1 ? lines : context + 1)
    for (i = 1; i <= last; i++) print buf[i]
    key = "[" hit "]" stackTop()
    if (!(key in topCount)) { topOrder[++tops] = key; topCount[key] = 0 }
    topCount[key]++
  }
  lines = 0
}

/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:/ { flush(); startLine = NR }
{ if (lines == 0) startLine = NR; buf[++lines] = $0 }

END {
  flush()
  total = 0
  print ""
  print "Distinct stack tops (2 frames above the first CodeScan frame, then that frame):"
  if (tops == 0) print "  (none)"
  for (t = 1; t <= tops; t++) print "  " topCount[topOrder[t]] " x " topOrder[t]
  print ""
  print "Summary:"
  for (i = 1; i <= n; i++) { print "  " pat[i] ": " count[i]; total += count[i] }
  print "  Total: " total
  exit (total > 0 ? 1 : 0)
}
' "$LOG"
