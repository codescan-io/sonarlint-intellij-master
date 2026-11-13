#!/usr/bin/env bash
# Runs inside the qa container (see Dockerfile and baseline-docker.sh).
# Starts the IDE with CodeScan on Xvfb, opens one Apex and one Java file, copies logs to /out.
#
# Mounts: /ide.tar.gz (IDE tarball, read-only), /plugin.zip (plugin, read-only),
#         /src-project (sample project, read-only), /out (results, writable).
# Exit: 0 = IDE ran and logs were collected, 3 = IDE did not start or no log.
set -u

RUN_MINUTES="${RUN_MINUTES:-5}"
START_TIMEOUT_SEC="${START_TIMEOUT_SEC:-300}"
OUT=/out
IDE=/opt/idea
IDE_HOME=/work/ide-home
PROJECT=/work/project
SHOTS="$OUT/screens"
mkdir -p "$OUT" "$SHOTS" "$IDE" "$IDE_HOME/config/options" "$IDE_HOME/system" "$IDE_HOME/plugins" "$IDE_HOME/log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }
shot() { xwd -root -silent 2>/dev/null | convert xwd:- "$SHOTS/$1.png" 2>/dev/null && log "screenshot $1.png"; }

IDE_PID=""
collect() {
  cp -a "$IDE_HOME/log" "$OUT/" 2>/dev/null
  cp "$IDE_HOME/vmoptions" "$OUT/vmoptions.txt" 2>/dev/null
}
fail() {
  log "FAILED: $*"
  shot "failure"
  [ -n "$IDE_PID" ] && kill -KILL "$IDE_PID" 2>/dev/null
  collect
  exit 3
}

log "unpacking IDE"
tar -xzf /ide.tar.gz -C "$IDE" --strip-components=1 || fail "cannot unpack IDE tarball"
log "IDE: $(grep -o '"version": *"[^"]*"\|"buildNumber": *"[^"]*"' "$IDE/product-info.json" | tr '\n' ' ')"

log "installing plugin"
unzip -q /plugin.zip -d "$IDE_HOME/plugins" || fail "cannot unzip plugin"

log "copying sample project"
cp -a /src-project "$PROJECT" || fail "cannot copy project"
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
cat > "$IDE_HOME/config/options/trusted-paths.xml" <<'XML'
<application>
  <component name="Trusted.Paths.Settings">
    <option name="TRUSTED_PATHS">
      <list>
        <option value="/work" />
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
  i=$((i + 1)); [ $i -gt 30 ] && fail "Xvfb did not start"; sleep 1
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
  sleep 5; waited=$((waited + 5))
done
log "project window open after ~${waited}s"
grep -m1 'Loaded custom plugins' "$IDEA_LOG" | sed 's/.* - //' | tee -a "$OUT/run.log"
grep -q 'Loaded custom plugins.*CodeScan' "$IDEA_LOG" || fail "CodeScan plugin was not loaded"

T0=$(date +%s)

ide_window() { xdotool search --onlyvisible --name 'project' 2>/dev/null | head -1; }
# Escape first: it closes onboarding pop-ups ("Meet the Islands Theme", tours) that take
# the focus and also hold back files opened from the command line.
keys() {
  local w; w="$(ide_window)"
  [ -n "$w" ] && xdotool windowactivate "$w" >/dev/null 2>&1
  sleep 1
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
    sleep 1
  done
  log "$name open after ~${n}s"
  kill "$p" 2>/dev/null
}

sleep 20
keys
sleep 5
shot "01-project-open"
open_file "$APEX_FILE"
sleep 20
open_file "$JAVA_FILE"
sleep 20
shot "02-files-open"

log "running Analyze with CodeScan (ctrl+shift+s) on Hello.java"
keys ctrl+shift+s; sleep 30
shot "03-analyze-java"
# Recent Files (ctrl+e) has the previous file selected, which is the Apex file.
keys ctrl+e; sleep 3; xdotool key Return; sleep 3
log "running Analyze with CodeScan (ctrl+shift+s) on $(basename "$APEX_FILE")"
keys ctrl+shift+s; sleep 30
shot "04-analyze-apex"
log "opening Settings > CodeScan"
keys ctrl+alt+s; sleep 8; xdotool type --delay 80 "CodeScan"; sleep 8
shot "05-settings"
xdotool key Escape; sleep 3

END=$((T0 + RUN_MINUTES * 60))
while [ "$(date +%s)" -lt "$END" ]; do
  kill -0 "$IDE_PID" 2>/dev/null || { log "IDE exited early"; break; }
  sleep 10
done
shot "06-before-exit"

log "closing IDE (SIGTERM, which IntelliJ handles as a normal exit)"
kill -TERM "$IDE_PID" 2>/dev/null
n=0
while kill -0 "$IDE_PID" 2>/dev/null && [ $n -lt 90 ]; do sleep 2; n=$((n + 2)); done
if kill -0 "$IDE_PID" 2>/dev/null; then
  log "IDE still running after 90s, killing it"
  kill -KILL "$IDE_PID" 2>/dev/null
else
  log "IDE exited"
fi
grep -q 'IDE SHUTDOWN' "$IDEA_LOG" && log "idea.log has the IDE SHUTDOWN line"
collect
[ -s "$OUT/log/idea.log" ] || { log "FAILED: no idea.log"; exit 3; }
log "done"
exit 0
