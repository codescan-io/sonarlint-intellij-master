#!/usr/bin/env bash
# Scans an IntelliJ idea.log for threading errors and CodeScan plugin errors.
# Prints each hit with the following 15 lines of its log entry, a count per pattern,
# and the distinct stack-trace tops with how often each happened.
#
# Every hit of the 4 platform patterns (slow operation on the UI thread, read access,
# UI-thread access, "UI was frozen") is sorted into one of three groups:
#   CodeScan - the logger is org.sonarlint / org.sonarsource.sonarlint, or the stack trace has
#              an org.sonarlint. frame (for a freeze: the UI thread in the freeze dump has one).
#   other    - there is a stack trace and it has no CodeScan frame (another plugin or the IDE).
#   unknown  - there is no stack trace to judge (for example "Suppressed a frequent exception"
#              repeats, or a freeze with no dump).
# The 2 "ERROR from / with org.sonarlint" patterns are CodeScan by definition.
#
# Usage: scan-idea-log.sh [--strict] [--freeze-dumps <log dir>] <idea.log>
#   --freeze-dumps <log dir>  The folder that holds idea.log and the threadDumps-freeze-<yyyyMMdd-HHmmss>-*
#                             folders. Each "UI was frozen" hit is matched to its dump folder: first by the
#                             folder name in the log line, else by the closest timestamp within 5 seconds.
#                             The freeze is CodeScan if the "AWT-EventQueue" thread block in a thread dump
#                             has an org.sonarlint. frame, other if it has not, unknown if there is no
#                             dump, no thread dump file, or no such thread block.
#   --strict                  Any hit, whoever caused it, gives exit 1.
# Exit:  1 = at least one CodeScan hit (with --strict: at least one hit of any kind).
#        0 = no hits, or every hit is other/unknown (a note says so).
#        2 = bad usage or unreadable file.
# Works with macOS bash 3.2 / BSD awk and Linux bash / mawk / gawk.
set -u

usage() {
  echo "usage: $(basename "$0") [--strict] [--freeze-dumps <log dir>] <idea.log>" >&2
}

STRICT=0
DUMPS=""
LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --freeze-dumps)
      if [ $# -lt 2 ]; then usage; exit 2; fi
      DUMPS="$2"; shift 2 ;;
    -*) usage; exit 2 ;;
    *)
      if [ -n "$LOG" ]; then usage; exit 2; fi
      LOG="$1"; shift ;;
  esac
done
if [ -z "$LOG" ]; then usage; exit 2; fi
if [ ! -f "$LOG" ] || [ ! -r "$LOG" ]; then
  echo "error: cannot read log file: $LOG" >&2
  exit 2
fi
if [ -n "$DUMPS" ] && { [ ! -d "$DUMPS" ] || [ ! -r "$DUMPS" ]; }; then
  echo "error: cannot read freeze dump folder: $DUMPS" >&2
  exit 2
fi

# Logs can hold bytes that are not valid text; byte-wise matching keeps awk from stopping on them.
export LC_ALL=C

TMPMAP="$(mktemp "${TMPDIR:-/tmp}/scan-idea-log.XXXXXX")" || { echo "error: cannot create a temp file" >&2; exit 2; }
trap 'rm -f "$TMPMAP"' EXIT

# Prints CodeScan, other or unknown for one freeze dump folder, from the UI thread blocks of its thread dumps.
classify_dump() {
  local dir="$1" file res any_block=0 cs=0
  for file in "$dir"/threadDump-*.txt; do
    [ -f "$file" ] || continue
    res="$(awk '
      /^"AWT-EventQueue/ { inb = 1; block = 1; next }
      inb && (/^$/ || /^"/) { inb = 0 }
      inb && /org\.sonar(lint|source\.sonarlint)\./ { cs = 1 }
      END { print (block ? "block" : "none") " " (cs ? "cs" : "nocs") }
    ' "$file" 2>/dev/null)" || res=""
    case "$res" in
      "block cs") any_block=1; cs=1 ;;
      "block nocs") any_block=1 ;;
      "") echo "warning: cannot read thread dump $file" >&2 ;;
    esac
  done
  if [ "$cs" -eq 1 ]; then echo CodeScan
  elif [ "$any_block" -eq 1 ]; then echo other
  else echo unknown
  fi
}

# One line per freeze folder: <yyyyMMdd-HHmmss> <TAB> <folder name> <TAB> <class>
if [ -n "$DUMPS" ]; then
  for d in "$DUMPS"/threadDumps-freeze-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*; do
    [ -d "$d" ] || continue
    name="${d##*/}"
    stamp="${name#threadDumps-freeze-}"
    stamp="${stamp:0:15}"
    printf '%s\t%s\t%s\n' "$stamp" "$name" "$(classify_dump "$d")" >> "$TMPMAP"
  done
fi

awk -v context=15 -v strict="$STRICT" -v mapfile="$TMPMAP" -v window=5 '
BEGIN {
  n = 0
  pat[++n] = "Slow operations are prohibited on EDT"
  pat[++n] = "Read access is allowed from inside read-action"
  pat[++n] = "Access is allowed from Event Dispatch Thread"
  pat[++n] = "UI was frozen"
  fixedPatterns = n
  freezePat = 4
  sonarLogger = ++n
  pat[sonarLogger] = "ERROR from org.sonarlint logger"
  sonarTrace = ++n
  pat[sonarTrace] = "ERROR with org.sonarlint in its stack trace"
  for (i = 1; i <= n; i++) { cs[i] = 0; ot[i] = 0; un[i] = 0 }
  lines = 0
  tops = 0
  dumps = 0
  while ((getline row < mapfile) > 0) {
    split(row, part, "\t")
    dumps++
    dumpEpoch[dumps] = stampEpoch(part[1])
    dumpName[dumps] = part[2]
    dumpClass[part[2]] = part[3]
  }
  close(mapfile)
}

# Seconds for a "yyyyMMdd-HHmmss" stamp; only differences matter, so a day number from a fixed formula is enough.
function stampEpoch(s) {
  return epoch(substr(s, 1, 4) + 0, substr(s, 5, 2) + 0, substr(s, 7, 2) + 0, substr(s, 10, 2) + 0, substr(s, 12, 2) + 0, substr(s, 14, 2) + 0)
}
function epoch(y, m, d, hh, mm, ss,   a) {
  a = (m <= 2 ? 1 : 0)
  y -= a; m += 12 * a
  return (365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d) * 86400 + hh * 3600 + mm * 60 + ss
}

# The class of the freeze dump for the entry header in buf[1]: by the folder name in the line, else by time.
function freezeClass(   p, name, t, i, diff, best, bestDiff) {
  p = index(buf[1], "details saved to ")
  if (p > 0) {
    name = substr(buf[1], p + 17)
    sub(/[ \t\r]+$/, "", name)
    sub(/^.*\//, "", name)
    if (name ~ /^threadDumps-freeze-/) return (name in dumpClass ? dumpClass[name] : "unknown")
  }
  if (!match(buf[1], /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) return "unknown"
  t = epoch(substr(buf[1], 1, 4) + 0, substr(buf[1], 6, 2) + 0, substr(buf[1], 9, 2) + 0, substr(buf[1], 12, 2) + 0, substr(buf[1], 15, 2) + 0, substr(buf[1], 18, 2) + 0)
  best = 0; bestDiff = window + 1
  for (i = 1; i <= dumps; i++) {
    diff = t - dumpEpoch[i]; if (diff < 0) diff = -diff
    if (diff < bestDiff) { bestDiff = diff; best = i }
  }
  return (best > 0 ? dumpClass[dumpName[best]] : "unknown")
}

# The plugin ships its core library under org.sonarsource.sonarlint, so both count as CodeScan code.
function isPluginFrame(s) { return s ~ /org\.sonar(lint|source\.sonarlint)\./ }

# A frame line looks like "\tat pkg.Class.method(File.java:12)".
function frameText(s) { sub(/^[ \t]+at /, "", s); return s }

# The 2 frames above the first CodeScan frame, then that frame. Raw first frames are the
# same logging/assertion plumbing for every hit, so they would not tell traces apart.
# A trace can have several blocks ("Caused by:"); the first block that has a CodeScan frame is used,
# else the first block.
function stackTop(   i, f, nf, first, from, key, pick) {
  nf = 0; first = 0; pick = 0
  for (i = 2; i <= lines + 1; i++) {
    if (i <= lines && buf[i] ~ /^[ \t]+at /) {
      frame[++nf] = frameText(buf[i])
      if (!first && isPluginFrame(buf[i])) first = nf
    } else if (nf > 0) {
      if (first) { pick = 1; break }
      if (!saved) { for (f = 1; f <= nf; f++) savedFrame[f] = frame[f]; savedN = nf; saved = 1 }
      nf = 0
    }
  }
  if (!pick) {
    if (!saved) return "\n      (no stack trace)"
    for (f = 1; f <= savedN; f++) frame[f] = savedFrame[f]
    nf = savedN
  }
  if (!first) first = (nf < 3 ? nf : 3)
  from = (first > 2 ? first - 2 : 1)
  key = ""
  for (f = from; f <= first; f++) key = key "\n      " frame[f]
  saved = 0
  return key
}

# CodeScan if the logger or a stack frame is CodeScan code, other if there is a stack without it, else unknown.
function entryClass(   j, hasStack, hasPlugin) {
  if (buf[1] ~ /(ERROR|SEVERE|WARN|INFO|DEBUG) - #?org\.sonar(lint|source\.sonarlint)\./) return "CodeScan"
  hasStack = 0; hasPlugin = 0
  for (j = 2; j <= lines; j++) {
    if (buf[j] ~ /^[ \t]+at /) { hasStack = 1; if (isPluginFrame(buf[j])) hasPlugin = 1 }
  }
  if (hasPlugin) return "CodeScan"
  return (hasStack ? "other" : "unknown")
}

function tally(i, class) {
  if (class == "CodeScan") cs[i]++
  else if (class == "other") ot[i]++
  else un[i]++
}

function flush(   i, j, hit, matched, isError, key, last, class, fclass) {
  if (lines == 0) return
  hit = ""
  class = entryClass()
  for (i = 1; i <= fixedPatterns; i++) {
    matched = 0
    for (j = 1; j <= lines && !matched; j++) if (index(buf[j], pat[i]) > 0) matched = 1
    if (matched) {
      if (i == freezePat) { fclass = freezeClass(); tally(i, fclass); if (hit == "") class = fclass }
      else tally(i, class)
      hit = hit (hit == "" ? "" : ", ") pat[i]
    }
  }
  isError = (buf[1] ~ /(ERROR|SEVERE) - /)
  if (isError && buf[1] ~ /(ERROR|SEVERE) - #?org\.sonar(lint|source\.sonarlint)\./) {
    cs[sonarLogger]++; hit = hit (hit == "" ? "" : ", ") pat[sonarLogger]
  } else if (isError && hit == "") {
    matched = 0
    for (j = 2; j <= lines && !matched; j++) if (buf[j] ~ /^[ \t]+at / && isPluginFrame(buf[j])) matched = 1
    if (matched) { cs[sonarTrace]++; hit = pat[sonarTrace]; class = "CodeScan" }
  }
  if (hit != "") {
    print "=== " hit " (line " startLine ") ==="
    last = (lines < context + 1 ? lines : context + 1)
    for (i = 1; i <= last; i++) print buf[i]
    key = "[" hit "] " class stackTop()
    if (!(key in topCount)) { topOrder[++tops] = key; topCount[key] = 0 }
    topCount[key]++
  }
  lines = 0
}

/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:/ { flush(); startLine = NR }
{ if (lines == 0) startLine = NR; buf[++lines] = $0 }

END {
  flush()
  total = 0; csTotal = 0
  print ""
  print "Distinct stack tops (class, then 2 frames above the first CodeScan frame, then that frame):"
  if (tops == 0) print "  (none)"
  for (t = 1; t <= tops; t++) print "  " topCount[topOrder[t]] " x " topOrder[t]
  print ""
  print "Summary:"
  for (i = 1; i <= n; i++) {
    c = cs[i] + ot[i] + un[i]
    print "  " pat[i] ": " c
    print "    CodeScan: " cs[i] "  other: " ot[i] "  unknown: " un[i]
    total += c; csTotal += cs[i]
  }
  print "  Total: " total
  if (total > csTotal) print "  Note: " (total - csTotal) " hit(s) are not from CodeScan (other or unknown); see the split under each pattern."
  print "  CodeScan total: " csTotal
  if (strict) exit (total > 0 ? 1 : 0)
  exit (csTotal > 0 ? 1 : 0)
}
' "$LOG"
