#!/usr/bin/env bash
# Runs inside the qa container (see Dockerfile and baseline-docker.sh).
# Starts the IDE with CodeScan on Xvfb, opens one Apex and one Java file, copies logs to /out.
#
# Mounts: /ide.tar.gz (IDE tarball, read-only), /plugin.zip (plugin, read-only),
#         /src-project (sample project, read-only), /out (results, writable).
# Exit: 0 = IDE ran for the whole time, CodeScan analysed a file, and logs were collected
#       3 = IDE did not start, or there is no idea.log
#       4 = IDE exited before it was stopped (also when it crashed during the scripted steps, which the wait
#           loop does not cover), or it stopped without an IDE SHUTDOWN line in idea.log, or it had to be killed
#           because it was still running 90 s after SIGTERM (logs are still collected)
#       5 = the CodeScan analysis did not show a result for Hello.java (see "analysis check" below)
#       7 = the IDE started but the CodeScan plugin was not loaded (no CodeScan in "Loaded custom plugins")
set -u

RUN_MINUTES="${RUN_MINUTES:-5}"
START_TIMEOUT_SEC="${START_TIMEOUT_SEC:-300}"
# The QA_* variables are for test-ide-in-container.sh, which runs this script outside Docker with stub programs.
# In the container none of them is set, so the defaults apply.
OUT="${QA_OUT:-/out}"
IDE="${QA_IDE_DIR:-/opt/idea}"
WORK="${QA_WORK_DIR:-/work}"
IDE_TARBALL="${QA_IDE_TARBALL:-/ide.tar.gz}"
PLUGIN_ZIP="${QA_PLUGIN_ZIP:-/plugin.zip}"
SRC_PROJECT="${QA_SRC_PROJECT:-/src-project}"
SLEEP_SCALE="${QA_SLEEP_SCALE:-1}"
IDE_HOME="$WORK/ide-home"
PROJECT="$WORK/project"
SHOTS="$OUT/screens"
mkdir -p "$OUT" "$SHOTS" "$IDE" "$IDE_HOME/config/options" "$IDE_HOME/system" "$IDE_HOME/plugins" "$IDE_HOME/log"

# sleep, with every length multiplied by QA_SLEEP_SCALE (1 in the container; a test makes it small).
nap() { sleep "$(awk -v n="$1" -v s="$SLEEP_SCALE" 'BEGIN { printf "%.3f", n * s }')"; }

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }
shot() { xwd -root -silent 2>/dev/null | convert xwd:- "$SHOTS/$1.png" 2>/dev/null && log "screenshot $1.png"; }

# True if the text on a screenshot (read with OCR, also after inverting the dark theme) matches the pattern.
screen_has() {
  local img="$SHOTS/$1.png"
  [ -s "$img" ] || return 1
  tesseract "$img" stdout 2>/dev/null | grep -Eq "$2" && return 0
  convert "$img" -colorspace Gray -negate -resize 200% "$SHOTS/ocr-tmp.png" 2>/dev/null \
    && tesseract "$SHOTS/ocr-tmp.png" stdout 2>/dev/null | grep -Eq "$2"
}

IDE_PID=""
collect() {
  cp -a "$IDE_HOME/log" "$OUT/" 2>/dev/null
  cp "$IDE_HOME/vmoptions" "$OUT/vmoptions.txt" 2>/dev/null
}
# fail_with <exit code> <message>: stops the IDE, collects the logs and exits.
fail_with() {
  local code="$1"; shift
  log "FAILED: $*"
  shot "failure"
  [ -n "$IDE_PID" ] && kill -KILL "$IDE_PID" 2>/dev/null
  collect
  exit "$code"
}
fail() { fail_with 3 "$@"; }

log "unpacking IDE"
tar -xzf "$IDE_TARBALL" -C "$IDE" --strip-components=1 || fail "cannot unpack IDE tarball"
log "IDE: $(grep -o '"version": *"[^"]*"\|"buildNumber": *"[^"]*"' "$IDE/product-info.json" | tr '\n' ' ')"

log "installing plugin"
unzip -q "$PLUGIN_ZIP" -d "$IDE_HOME/plugins" || fail "cannot unzip plugin"

log "copying sample project"
cp -a "$SRC_PROJECT" "$PROJECT" || fail "cannot copy project"
chmod -R u+w "$PROJECT"
rm -rf "$PROJECT/.git" "$PROJECT/.idea" "$PROJECT/.claude"
mkdir -p "$PROJECT/java-sample/src/main/java/demo"
JAVA_FILE="$PROJECT/java-sample/src/main/java/demo/Hello.java"
cat > "$JAVA_FILE" <<'JAVA'
package demo;

public class Hello {
  public static void main(String[] args) {
    String unused = "x";
    try {
      System.out.println("hello " + args.length);
    } catch (Exception e) {
    }
  }
}
JAVA
APEX_FILE="$(find "$PROJECT/force-app" -name 'AccountServiceLayer.cls' | head -1)"
[ -n "$APEX_FILE" ] || APEX_FILE="$(find "$PROJECT/force-app" -name '*.cls' | head -1)"
[ -n "$APEX_FILE" ] || fail "no .cls file in project"

# Keeps first-start dialogs (license agreement, data sharing, settings import,
# project trust, tips) from blocking the virtual screen.
mkdir -p "$HOME/.java/.userPrefs/jetbrains/privacy_policy" "$HOME/.local/share/JetBrains/consentOptions"
cat > "$HOME"/.java/.userPrefs/jetbrains/privacy_policy/prefs.xml <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE map SYSTEM "http://java.sun.com/dtd/preferences.dtd">
<map MAP_XML_VERSION="1.0">
  <entry key="accepted_version" value="999.999"/>
  <entry key="eua_accepted_version" value="999.999"/>
  <entry key="euacommunity_accepted_version" value="999.999"/>
</map>
XML
printf 'rsch.send.usage.stat:1.1:0:%s000\n' "$(date +%s)" > "$HOME/.local/share/JetBrains/consentOptions/accepted"
cat > "$IDE_HOME/config/options/trusted-paths.xml" <<XML
<application>
  <component name="Trusted.Paths.Settings">
    <option name="TRUSTED_PATHS">
      <list>
        <option value="$WORK" />
      </list>
    </option>
  </component>
</application>
XML

cat > "$IDE_HOME/idea.properties" <<EOF
idea.config.path=$IDE_HOME/config
idea.system.path=$IDE_HOME/system
idea.plugins.path=$IDE_HOME/plugins
idea.log.path=$IDE_HOME/log
EOF
cp "$IDE/bin/idea64.vmoptions" "$IDE_HOME/vmoptions" 2>/dev/null || : > "$IDE_HOME/vmoptions"
cat >> "$IDE_HOME/vmoptions" <<'EOF'
-Xmx2g
-Dide.slow.operations.assertion=true
-Didea.is.internal=true
-Dsonarlint.telemetry.disabled=true
-Djb.consents.confirmation.enabled=false
-Djb.privacy.policy.text=<!--999.999-->
-Didea.initially.ask.config=never
-Didea.trust.all.projects=true
-Dide.show.tips.on.startup.default.value=false
-Dide.newUsersOnboarding=false
EOF
export IDEA_PROPERTIES="$IDE_HOME/idea.properties"
export IDEA_VM_OPTIONS="$IDE_HOME/vmoptions"
LAUNCHER="$IDE/bin/idea"
[ -x "$LAUNCHER" ] || LAUNCHER="$IDE/bin/idea.sh"

log "starting Xvfb and window manager"
Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp > "$OUT/xvfb.txt" 2>&1 &
i=0
until xdpyinfo >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -gt 30 ] && fail "Xvfb did not start"; nap 1
done
fluxbox >/dev/null 2>&1 &

log "starting IDE with project $PROJECT"
"$LAUNCHER" "$PROJECT" > "$OUT/ide-stdout.txt" 2>&1 &
IDE_PID=$!

IDEA_LOG="$IDE_HOME/log/idea.log"
waited=0
until grep -q 'Project frame set to' "$IDEA_LOG" 2>/dev/null; do
  kill -0 "$IDE_PID" 2>/dev/null || fail "IDE process exited during start"
  [ $waited -ge "$START_TIMEOUT_SEC" ] && fail "project window not open after ${START_TIMEOUT_SEC}s"
  nap 5; waited=$((waited + 5))
done
log "project window open after ~${waited}s"
grep -m1 'Loaded custom plugins' "$IDEA_LOG" | sed 's/.* - //' | tee -a "$OUT/run.log"
grep -q 'Loaded custom plugins.*CodeScan' "$IDEA_LOG" || fail_with 7 "CodeScan plugin was not loaded"

T0=$(date +%s)

ide_window() { xdotool search --onlyvisible --name 'project' 2>/dev/null | head -1; }
# Escape first: it closes onboarding pop-ups ("Meet the Islands Theme", tours) that take
# the focus and also hold back files opened from the command line.
keys() {
  local w; w="$(ide_window)"
  [ -n "$w" ] && xdotool windowactivate "$w" >/dev/null 2>&1
  nap 1
  xdotool key --delay 300 Escape Escape "$@"
}
# Opens a file in the running IDE and waits (at most 60s) until idea.log says it opened.
open_file() {
  local name; name="$(basename "$1")"
  log "opening $1"
  "$LAUNCHER" --line 1 "$1" >> "$OUT/ide-stdout.txt" 2>&1 &
  local p=$! n=0
  until grep -q "fileOpened $name" "$IDEA_LOG"; do
    n=$((n + 1)); [ $n -gt 60 ] && { kill "$p" 2>/dev/null; fail "$name not opened after 60s"; }
    nap 1
  done
  log "$name open after ~${n}s"
  kill "$p" 2>/dev/null
}

nap 20
keys
nap 5
shot "01-project-open"
open_file "$APEX_FILE"
nap 20
open_file "$JAVA_FILE"
nap 20
shot "02-files-open"

log "running Analyze with CodeScan (ctrl+shift+s) on Hello.java"
keys ctrl+shift+s; nap 30
shot "03-analyze-java"
# Analysis check, part 1: the plugin prints its result ("Found 4 issues in 1 file") only in the CodeScan tool
# window, never in idea.log or on disk (it saves findings to disk only for some exits, which is not reliable).
# So the result is read from the screenshot. Hello.java is written above with known problems, so it must show.
ANALYSIS_OK=0
if screen_has "03-analyze-java" 'Found [0-9]+ issues? in [0-9]+ files?'; then
  ANALYSIS_OK=1
else
  nap 20; shot "03b-analyze-java-retry"
  screen_has "03b-analyze-java-retry" 'Found [0-9]+ issues? in [0-9]+ files?' && ANALYSIS_OK=1
fi
rm -f "$SHOTS/ocr-tmp.png"
# Recent Files (ctrl+e) has the previous file selected, which is the Apex file.
keys ctrl+e; nap 3; xdotool key Return; nap 3
log "running Analyze with CodeScan (ctrl+shift+s) on $(basename "$APEX_FILE")"
keys ctrl+shift+s; nap 30
shot "04-analyze-apex"
log "opening Settings > CodeScan"
keys ctrl+alt+s; nap 8; xdotool type --delay 80 "CodeScan"; nap 8
shot "05-settings"
# Positive control for the log check: building this page in the Settings dialog runs
# SonarLintProjectConfigurable:125 on the UI thread, a known CodeScan slow operation. The search above leaves
# Tools > CodeScan selected; Down moves the selection to its child page, Project Settings.
log "opening Settings > Tools > CodeScan > Project Settings"
xdotool key --delay 300 Down; nap 10
shot "05b-project-settings"
if screen_has "05b-project-settings" 'Bind project'; then
  log "Project Settings page is on screen"
else
  log "WARNING: the CodeScan Project Settings page was not seen on screen, so the known slow operation may not have run; see $SHOTS/05b-project-settings.png"
fi
rm -f "$SHOTS/ocr-tmp.png"
xdotool key Escape; nap 3

END=$((T0 + $(awk -v m="$RUN_MINUTES" -v s="$SLEEP_SCALE" 'BEGIN { printf "%d", m * 60 * s + 0.999 }')))
EARLY_EXIT=0
EXIT_REASON=""
while [ "$(date +%s)" -lt "$END" ]; do
  kill -0 "$IDE_PID" 2>/dev/null || { log "IDE exited early"; EARLY_EXIT=1; EXIT_REASON="the IDE exited before the $RUN_MINUTES minutes were up"; break; }
  nap 10
done
shot "06-before-exit"

# A crash in the scripted steps (about 170 s) is not seen by the loop above when RUN_MINUTES is short,
# so the IDE is checked again before it is stopped.
STOPPED_NORMALLY=0
KILLED=0
if kill -0 "$IDE_PID" 2>/dev/null; then
  log "closing IDE (SIGTERM, which IntelliJ handles as a normal exit)"
  kill -TERM "$IDE_PID" 2>/dev/null
  n=0
  while kill -0 "$IDE_PID" 2>/dev/null && [ $n -lt 90 ]; do nap 2; n=$((n + 2)); done
  if kill -0 "$IDE_PID" 2>/dev/null; then
    log "IDE still running after 90s, killing it"
    kill -KILL "$IDE_PID" 2>/dev/null
    KILLED=1
  else
    log "IDE exited"
  fi
  STOPPED_NORMALLY=1
else
  EARLY_EXIT=1
  [ "$EXIT_REASON" = "" ] && EXIT_REASON="the IDE had already exited before it was stopped (a crash during the run)"
fi
HAS_SHUTDOWN=0
grep -q 'IDE SHUTDOWN' "$IDEA_LOG" 2>/dev/null && HAS_SHUTDOWN=1
[ "$HAS_SHUTDOWN" -eq 1 ] && log "idea.log has the IDE SHUTDOWN line"
collect
[ -s "$OUT/log/idea.log" ] || { log "FAILED: no idea.log"; exit 3; }
if [ "$EARLY_EXIT" -eq 1 ]; then
  log "FAILED: $EXIT_REASON, so the run is not complete"
  exit 4
fi
# A normal stop writes the IDE SHUTDOWN line. Without it the IDE was killed or stopped badly.
if [ "$STOPPED_NORMALLY" -eq 1 ] && [ "$HAS_SHUTDOWN" -ne 1 ]; then
  log "FAILED: idea.log has no IDE SHUTDOWN line, so the IDE did not stop normally"
  exit 4
fi
# A shutdown that starts but has to be killed is a hang (for example a plugin blocking the exit), not a normal stop.
if [ "$KILLED" -eq 1 ]; then
  log "FAILED: the IDE did not stop within 90 s of SIGTERM and was killed, so it did not stop normally"
  exit 4
fi

# Analysis check, part 2: without a result on screen the run is not a clean pass, whatever idea.log says.
if [ "$ANALYSIS_OK" -ne 1 ]; then
  log "FAILED: the CodeScan tool window did not show 'Found N issues' for Hello.java, so the analysis did not run (or the keyboard shortcut was missed); see $SHOTS/03-analyze-java.png"
  exit 5
fi
log "CodeScan showed its analysis result for Hello.java"
log "done"
exit 0
