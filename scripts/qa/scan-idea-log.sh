#!/usr/bin/env bash
# Scans an IntelliJ idea.log for threading errors and CodeScan plugin errors.
# Prints each hit with the following 15 lines of its log entry, a count per pattern,
# and the distinct stack-trace tops with how often each happened.
#
# Every hit of the 4 platform patterns (slow operation on the UI thread, read access,
# UI-thread access, "UI was frozen") is sorted into one of three groups:
#   CodeScan - the logger is org.sonarlint / org.sonarsource.sonarlint, or the stack trace has
#              an org.sonarlint. frame, or the entry names the plugin ("[Plugin: com.code-scan.intellij]" or
#              "Plugin to blame: CodeScan"). For a freeze see --freeze-dumps.
#   other    - there is a stack trace and it has no CodeScan frame (another plugin or the IDE).
#   unknown  - there is no stack trace to judge (for example "Suppressed a frequent exception"
#              repeats, or a freeze with no dump).
# The 2 "ERROR from / with org.sonarlint" patterns are CodeScan by definition. The second one also counts an
# ERROR entry that names the plugin without an org.sonarlint frame.
#
# IntelliJ often logs one exception twice, under two loggers a few ms apart (for example PluginManager and then
# "Unhandled exception in EDT"). An entry is merged into the one before it, and not counted again, when it has the
# same pattern, the same first CodeScan frame, a different logger, and starts within 100 ms of it. The Summary says
# how many were merged ("Merged duplicates"). The "Plugin to blame: CodeScan version: ..." entry that IntelliJ writes
# right after an exception (within 100 ms, no stack; also an entry naming "[Plugin: com.code-scan.intellij]" with no
# stack and no pattern) belongs to that hit and is not counted ("Blame follow-up lines folded"). If that hit was
# other or unknown, IntelliJ's blame makes it CodeScan ("Relabelled CodeScan by a blame line"). Without a hit just
# before it, the blame entry counts as a CodeScan error.
#
# Usage: scan-idea-log.sh [--strict] [--freeze-dumps <log dir>] [--] <idea.log>
#   --freeze-dumps <log dir>  The folder that holds idea.log and the threadDumps-freeze-<yyyyMMdd-HHmmss>-*
#                             folders. A "UI was frozen" hit is matched to its dump folder by the folder name in
#                             the log line ("details saved to <path>"). A line with no folder name, a missing
#                             folder, no thread dump file or no UI thread block is unknown (the time of the line
#                             is not used: IntelliJ names the folder by the freeze start, which a line does not state
#                             reliably). From the thread dump (the "AWT-EventQueue" block is the UI thread):
#                               - the UI thread has an org.sonarlint. frame: CodeScan.
#                               - the UI block has no frames at all: unknown.
#                               - the UI thread is WAITING, TIMED_WAITING or BLOCKED and has no CodeScan frame:
#                                 the thread that holds the lock it waits for decides. That owner is read from
#                                 the UI block's ' on <lock> owned by "<thread>"' line (IntelliJ's format), or from
#                                 its "- waiting to lock <0x..>" / "- parking to wait for <0x..>" line matched to the
#                                 thread with "- locked <0x..>" (or "- <0x..>" under "Locked ownable synchronizers")
#                                 for the same address (jstack format). Owner has a CodeScan frame: CodeScan; owner
#                                 found without one: other. No owner found: unknown if any thread has a CodeScan
#                                 frame, other if none has. A running CodeScan thread on its own never makes a
#                                 freeze CodeScan (the CodeScan polling thread is often caught running).
#                               - the UI thread is busy (RUNNABLE) with no CodeScan frame: other.
#                             A line starting with "----------" (the coroutine dump and later sections) ends the
#                             threads; nothing after it is read.
#                             With several thread dump files in one folder: CodeScan beats unknown beats other.
#                             org.sonarlint. frames also match the official SonarLint plugin, so with both plugins
#                             installed SonarLint hits are counted as CodeScan.
#   --strict                  Any hit, whoever caused it, gives exit 1.
#   --                        Ends the options, so a log file can have a name that starts with a dash.
# Exit:  1 = at least one CodeScan hit (with --strict: at least one hit of any kind).
#        0 = no hits, or every hit is other/unknown (a note says so).
#        2 = bad usage or unreadable file.
# Works with macOS bash 3.2 / BSD awk and Linux bash / mawk / gawk.
set -u

usage() {
  echo "usage: $(basename "$0") [--strict] [--freeze-dumps <log dir>] [--] <idea.log>" >&2
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
    --) shift; break ;;
    -*) usage; exit 2 ;;
    *)
      if [ -n "$LOG" ]; then usage; exit 2; fi
      LOG="$1"; shift ;;
  esac
done
# After "--" every argument is a file name, even one that starts with a dash.
if [ $# -gt 0 ]; then
  if [ -n "$LOG" ] || [ $# -gt 1 ]; then usage; exit 2; fi
  LOG="$1"
fi
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

# Prints CodeScan, other or unknown for one freeze dump folder (the rules are in the header).
classify_dump() {
  local dir="$1" file res seen_cs=0 seen_unknown=0 seen_other=0
  for file in "$dir"/threadDump-*.txt; do
    [ -f "$file" ] || continue
    res="$(awk '
      # A block runs to the next thread header (a line starting with a quote). It can hold blank
      # lines: a busy thread has one between the State line and its first frame.
      function endBlock() {
        if (cur == 0) return
        if (cur == 1) { edt = 1; edtFrames += frames; if (bcs) edtCs = 1; edtState = state }
        else if (bcs) anyCs = 1
        if (bcs) csName[name] = 1
        cur = 0
      }
      function addrOf(s) { return match(s, /<0x[0-9a-fA-F]+>/) ? substr(s, RSTART, RLENGTH) : "" }
      # IntelliJ writes the lock owner by name: " on <lock>@<hash> owned by \"<thread>\" Id=<n>".
      function ownerName(s) { sub(/^.* owned by "/, "", s); sub(/".*$/, "", s); return s }
      # IntelliJ ends the threads with "---------- Coroutine dump ----------" and similar sections. Their
      # lines are not part of the last thread, and a CodeScan coroutine there is not a running thread.
      stop { next }
      /^----------/ { endBlock(); stop = 1; next }
      /^"/ {
        endBlock()
        name = substr($0, 2); sub(/".*$/, "", name); seen[name] = 1
        cur = ($0 ~ /^"AWT-EventQueue/ ? 1 : 2); frames = 0; bcs = 0; state = ""
        if (cur == 1 && $0 ~ / owned by "/) wantName = ownerName($0)
        next
      }
      cur && /java\.lang\.Thread\.State:/ { state = $0; sub(/^.*State: */, "", state); sub(/[ (].*$/, "", state) }
      # org.sonarlint. is also the package of the official SonarLint plugin, so a user with both plugins
      # installed gets SonarLint frames counted as CodeScan.
      cur && /^[ \t]+at / { frames++; if ($0 ~ /org\.sonar(lint|source\.sonarlint)\./) bcs = 1 }
      cur == 1 && / owned by "/ { wantName = ownerName($0) }
      # jstack format: the UI thread waits for an address, and the owner lists it as "- locked <0x..>" (a
      # monitor) or as "- <0x..>" under "Locked ownable synchronizers" (a java.util.concurrent lock).
      cur == 1 && /^[ \t]+- (waiting to lock|parking to wait for) +<0x/ { wantAddr = addrOf($0) }
      cur && /^[ \t]+- (locked )?<0x/ { holder[addrOf($0)] = name }
      END {
        endBlock()
        if (!edt) print "none"
        else if (edtFrames == 0) print "unknown"
        else if (edtCs) print "cs"
        else if (edtState == "WAITING" || edtState == "TIMED_WAITING" || edtState == "BLOCKED") {
          owner = ""
          if (wantName != "" && (wantName in seen)) owner = wantName
          else if (wantAddr != "" && (wantAddr in holder)) owner = holder[wantAddr]
          # A CodeScan thread that merely runs (for example the polling thread) is not proof: without
          # a known lock owner it is unknown.
          if (owner != "") print ((owner in csName) ? "cs" : "other")
          else print (anyCs ? "unknown" : "other")
        }
        else print "other"
      }
    ' "$file" 2>/dev/null)" || res=""
    case "$res" in
      cs) seen_cs=1 ;;
      unknown) seen_unknown=1 ;;
      other) seen_other=1 ;;
      none) ;;
      *) echo "warning: cannot read thread dump $file" >&2 ;;
    esac
  done
  if [ "$seen_cs" -eq 1 ]; then echo CodeScan
  elif [ "$seen_unknown" -eq 1 ]; then echo unknown
  elif [ "$seen_other" -eq 1 ]; then echo other
  else echo unknown
  fi
}

# One line per freeze folder: <folder name> <TAB> <class>
if [ -n "$DUMPS" ]; then
  for d in "$DUMPS"/threadDumps-freeze-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*; do
    [ -d "$d" ] || continue
    printf '%s\t%s\n' "${d##*/}" "$(classify_dump "$d")" >> "$TMPMAP"
  done
fi

awk -v context=15 -v strict="$STRICT" -v mapfile="$TMPMAP" -v mergeMs=100 '
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
  # An entry header is "<date> <time> [ <thread id>]  <LEVEL> - #<logger> - <message>". The logger is only
  # read at that position, so the same words inside a message do not count.
  hdr = "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:,]+ +\\[ *[0-9]+\\] +"
  sonarName = "#?org\\.sonar(lint|source\\.sonarlint)\\."
  levels = "(SEVERE|ERROR|WARN|INFO|DEBUG|TRACE|FINE|FINER|FINEST)"
  anyLoggerRe = hdr levels " - " sonarName
  errLoggerRe = hdr "(SEVERE|ERROR) - " sonarName
  errLevelRe = hdr "(SEVERE|ERROR) - "
  lines = 0
  tops = 0
  merged = 0; blameFolded = 0; relabelled = 0; lastNh = 0; hitDay = ""; hitMs = 0
  while ((getline row < mapfile) > 0) {
    split(row, part, "\t")
    dumpClass[part[1]] = part[2]
  }
  close(mapfile)
}

# The class of the freeze dump named in the entry header in buf[1] ("details saved to <path>"), else unknown.
function freezeClass(   p, name) {
  p = index(buf[1], "details saved to ")
  if (p == 0) return "unknown"
  name = substr(buf[1], p + 17)
  sub(/[ \t\r]+$/, "", name)
  sub(/^.*\//, "", name)
  if (name ~ /^threadDumps-freeze-/ && (name in dumpClass)) return dumpClass[name]
  return "unknown"
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

# IntelliJ names the plugin it blames in an error report.
function namesPlugin(s) { return s ~ /\[Plugin: com\.code-scan\.intellij\]/ || s ~ /Plugin to blame: CodeScan/ }

# CodeScan if the logger, a stack frame or the blamed plugin is CodeScan, other if there is a stack without it, else unknown.
function entryClass(   j, hasStack, hasPlugin) {
  if (buf[1] ~ anyLoggerRe) return "CodeScan"
  hasStack = 0; hasPlugin = 0
  for (j = 1; j <= lines; j++) {
    if (namesPlugin(buf[j])) hasPlugin = 1
    if (j > 1 && buf[j] ~ /^[ \t]+at /) { hasStack = 1; if (isPluginFrame(buf[j])) hasPlugin = 1 }
  }
  if (hasPlugin) return "CodeScan"
  return (hasStack ? "other" : "unknown")
}

function tally(i, class) {
  if (class == "CodeScan") cs[i]++
  else if (class == "other") ot[i]++
  else un[i]++
}

# The first CodeScan frame of the entry, or "".
function firstPluginFrame(   j) {
  for (j = 2; j <= lines; j++) if (buf[j] ~ /^[ \t]+at / && isPluginFrame(buf[j])) return frameText(buf[j])
  return ""
}

# The logger name in an entry header, without a leading "#".
function loggerOf(s,   t) {
  if (!match(s, hdr "[A-Z]+ - ")) return ""
  t = substr(s, RLENGTH + 1)
  sub(/^#/, "", t); sub(/ .*$/, "", t)
  return t
}

# Milliseconds since midnight for "yyyy-MM-dd HH:mm:ss,SSS" at the start of s.
function msOf(s) { return ((substr(s, 12, 2) * 60 + substr(s, 15, 2)) * 60 + substr(s, 18, 2)) * 1000 + substr(s, 21, 3) }

# True if this entry repeats the previous hit: same pattern(s), same first CodeScan frame, other logger, same day,
# within mergeMs. Two different problems from one CodeScan frame (read access, then a slow operation) stay two hits.
# Entries that are not hits, and hits with no CodeScan frame, leave the previous-hit fields alone.
# The previous-hit fields move on with every hit, so a chain of 3 loggers 50 ms apart is merged into one.
function isDuplicate(hit,   frame, logger, day, ms, dup) {
  day = substr(buf[1], 1, 10); ms = msOf(buf[1])
  hitDay = day; hitMs = ms
  frame = firstPluginFrame()
  if (frame == "") return 0
  logger = loggerOf(buf[1])
  dup = (hit == prevHit && frame == prevFrame && logger != prevLogger && day == prevDay && ms - prevMs >= 0 && ms - prevMs <= mergeMs)
  prevHit = hit; prevFrame = frame; prevLogger = logger; prevDay = day; prevMs = ms
  return dup
}

# IntelliJ reports an exception as several entries a few ms apart: the exception, "JDK: ...", "OS: ..." and
# "Plugin to blame: CodeScan version: ..." (no stack). That last entry belongs to the hit before it. An entry that
# names the plugin as "[Plugin: com.code-scan.intellij]" with no stack and no platform pattern is read the same way.
function isBlameFollowUp(   j, i, ms, named) {
  named = 0
  for (j = 1; j <= lines; j++) {
    if (j > 1 && buf[j] ~ /^[ \t]+at /) return 0
    if (namesPlugin(buf[j])) named = 1
    for (i = 1; i <= fixedPatterns; i++) if (index(buf[j], pat[i]) > 0) return 0
  }
  if (!named) return 0
  ms = msOf(buf[1])
  return (hitDay == substr(buf[1], 1, 10) && ms - hitMs >= 0 && ms - hitMs <= mergeMs)
}

# IntelliJ blames CodeScan for the last counted hit, so a part of it that was other or unknown becomes CodeScan.
function relabelLast(   h, changed, newKey) {
  changed = 0
  for (h = 1; h <= lastNh; h++) {
    if (lastClass[h] == "CodeScan") continue
    if (lastClass[h] == "other") ot[lastPat[h]]--; else un[lastPat[h]]--
    cs[lastPat[h]]++; lastClass[h] = "CodeScan"; changed = 1
  }
  if (!changed) return
  relabelled++
  topCount[lastKey]--
  newKey = "[" lastHit "] CodeScan" lastTop
  if (!(newKey in topCount)) { topOrder[++tops] = newKey; topCount[newKey] = 0 }
  topCount[newKey]++
  lastKey = newKey
  print "=== relabelled as CodeScan: the hit at line " lastLine " (IntelliJ blames CodeScan at line " startLine ") ==="
}

function flush(   i, j, matched, isError, key, last, class, fclass, nh, h, hit, top) {
  if (lines == 0) return
  if (isBlameFollowUp()) { blameFolded++; relabelLast(); lines = 0; return }
  nh = 0; hit = ""
  class = entryClass()
  for (i = 1; i <= fixedPatterns; i++) {
    matched = 0
    for (j = 1; j <= lines && !matched; j++) if (index(buf[j], pat[i]) > 0) matched = 1
    if (matched) {
      nh++; hitPat[nh] = i; hitClass[nh] = class
      if (i == freezePat) { fclass = freezeClass(); hitClass[nh] = fclass; if (nh == 1) class = fclass }
      hit = hit (hit == "" ? "" : ", ") pat[i]
    }
  }
  # An entry that already matched a platform pattern is one hit, not a second one for its logger.
  isError = (buf[1] ~ errLevelRe)
  if (isError && hit == "") {
    if (buf[1] ~ errLoggerRe) {
      nh++; hitPat[nh] = sonarLogger; hitClass[nh] = "CodeScan"; hit = pat[sonarLogger]
    } else {
      matched = 0
      for (j = 1; j <= lines && !matched; j++) {
        if (namesPlugin(buf[j])) matched = 1
        else if (j > 1 && buf[j] ~ /^[ \t]+at / && isPluginFrame(buf[j])) matched = 1
      }
      if (matched) { nh++; hitPat[nh] = sonarTrace; hitClass[nh] = "CodeScan"; hit = pat[sonarTrace]; class = "CodeScan" }
    }
  }
  if (nh > 0 && isDuplicate(hit)) {
    merged++
  } else if (nh > 0) {
    for (h = 1; h <= nh; h++) { tally(hitPat[h], hitClass[h]); lastPat[h] = hitPat[h]; lastClass[h] = hitClass[h] }
    lastNh = nh
    print "=== " hit " (line " startLine ") ==="
    last = (lines < context + 1 ? lines : context + 1)
    for (i = 1; i <= last; i++) print buf[i]
    top = stackTop()
    key = "[" hit "] " class top
    if (!(key in topCount)) { topOrder[++tops] = key; topCount[key] = 0 }
    topCount[key]++
    lastKey = key; lastHit = hit; lastTop = top; lastLine = startLine
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
  # A key whose only hit was relabelled has a count of 0.
  for (t = 1; t <= tops; t++) if (topCount[topOrder[t]] > 0) print "  " topCount[topOrder[t]] " x " topOrder[t]
  print ""
  print "Summary:"
  for (i = 1; i <= n; i++) {
    c = cs[i] + ot[i] + un[i]
    print "  " pat[i] ": " c
    print "    CodeScan: " cs[i] "  other: " ot[i] "  unknown: " un[i]
    total += c; csTotal += cs[i]
  }
  print "  Merged duplicates: " merged " (one exception logged under two loggers within " mergeMs " ms; counted once)"
  print "  Blame follow-up lines folded: " blameFolded " (\"Plugin to blame: CodeScan\" or \"[Plugin: com.code-scan.intellij]\" entry with no stack within " mergeMs " ms after a hit; not a hit of its own)"
  print "  Relabelled CodeScan by a blame line: " relabelled " (of those follow-ups, the ones whose hit was other or unknown)"
  print "  Total: " total
  if (total > csTotal) print "  Note: " (total - csTotal) " hit(s) are not from CodeScan (other or unknown); see the split under each pattern."
  print "  CodeScan total: " csTotal
  if (strict) exit (total > 0 ? 1 : 0)
  exit (csTotal > 0 ? 1 : 0)
}
' "$LOG"
