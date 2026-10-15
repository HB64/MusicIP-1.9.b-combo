#!/usr/bin/env bash
# Starts the screen and the viewer, then waits.  Starts NOTHING else — no
# window manager, no Wine.  You run those by hand, one at a time, and watch.
#
# COMBINED IMAGE: derived from the saysaar Mixer image.  Adds MusicMagicServer
# (port 10003, same default.m3lib) next to the Mixer (port 10002).  The Server is
# the ONLY writer of default.m3lib; the Mixer is never flushed or closed cleanly,
# because either would write its in-memory copy over the Server's.  Changes are
# marked "COMBINED".
set -u

ts(){ date -u +%H:%M:%S; }

rm -rf /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true

echo "[$(ts)] starting screen :99 (1280x800)"
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &

# Wait for the screen to be answerable rather than guessing at a sleep.
for i in $(seq 1 30); do
  xdpyinfo -display :99 >/dev/null 2>&1 && break
  sleep 0.5
done
if ! xdpyinfo -display :99 >/dev/null 2>&1; then
  echo "[$(ts)] FAILED: screen :99 never came up"; exit 1
fi
echo "[$(ts)] screen is up"

# Viewer.  Bound to inside the container only; the browser reaches it through
# novnc on 8989.  No password: 8989 is published to your machine alone.
echo "[$(ts)] starting viewer on 5900 (container-internal)"
x11vnc -display :99 -forever -shared -nopw -localhost -rfbport 5900 -quiet &

echo "[$(ts)] starting window manager"
openbox &

echo "[$(ts)] serving novnc on 8989"
websockify --web=/usr/share/novnc 8989 localhost:5900 &

# --- Log trimmer -------------------------------------------------------
# MusicIP writes log.txt into its roaming folder, which is the persist mount,
# i.e. real disk on the host.  Nothing in MusicIP ever trims it, and -logex
# makes it grow faster.  Emptying the file IN PLACE (not deleting it) keeps
# the Mixer's open handle valid, so it just carries on appending.
# Checked once a day.  Size in MB, overridable at docker run with
# -e LOG_MAX_MB=50.
LOG_MAX_MB="${LOG_MAX_MB:-20}"
LOG_FILE="/home/mip/.wine/drive_c/users/mip/AppData/Roaming/MusicIP/MusicIP Mixer/log.txt"

echo "[$(ts)] log trimmer on — empties log.txt above ${LOG_MAX_MB} MB"
(
  while true; do
    sleep 86400
    [ -f "$LOG_FILE" ] || continue
    sz=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$sz" -gt $(( LOG_MAX_MB * 1024 * 1024 )) ]; then
      : > "$LOG_FILE"
      echo "[$(ts)] log.txt reached $(( sz / 1024 / 1024 )) MB — emptied"
    fi
  done
) &

# --- The Mixer ---------------------------------------------------------
# Started here so the container comes up serving with nobody clicking.
# Relaunched if it exits; restarted if its API stops answering (watchdog
# below); stopped cleanly on docker stop.  A dialog that leaves the API
# answering is not caught — that is what the screen is for.
#
# Options, and why:
#   -remoteaccess   turns on the HTTP interface
#   -readonly       never write to music files, even if something asks
#   -notrash        no Recycle Bin routing; there is no Recycle Bin here
#   -nodiskscan     no hunting for drives and removable devices.  Documented as
#                   devices only — it does NOT suppress the music scan.
#   -feedback=off   no usage pings to MusicIP's long-dead servers
#   -logex          fuller diagnostics in log.txt (see the trimmer above)
#   -slim           makes SlimServer a Send To target, so a mix made in the
#                   window plays on a Lyrion player.  REQUIRED, not automatic,
#                   whatever Help says.  Lyrion's command interface must be on
#                   its default port 9090; the host is compiled into MusicIP.
#   -nowizard       no first-run wizard.  Undocumented, but a wizard in an
#                   unattended container is a dialog nobody can dismiss.
#   -nowatcher      removes the Watch Folders page from Preferences.  Opening
#                   that page froze the window, and Preferences reopens on it,
#                   so without this switch all of Preferences is lost after one
#                   visit.  It does NOT stop watching: tested on Debian
#                   2026-09-11, new, deleted and retagged music still came in.
#
# NOT set, and why:
#   -noauto        documented as disabling automatic passes, INCLUDING "the
#                  initial scan if watchfolders are configured".  That scan is
#                  how new music is meant to arrive.  Never set it.
#   -logexwatcher  dropped 2026-09-12.  It was on to prove the watcher worked,
#                  which it did; all it does now is write a line per file every
#                  time a batch of new music arrives.
#   -slimcli, -slimhttp
#                  both TESTED 2026-09-12 with the switch read back off the
#                  running process, and both are IGNORED.  -slimhttp=9091,
#                  a port where nothing listens, did not break the push.
#                  Do not add either.
#
# The API service itself is switched on inside the Mixer's own settings,
# which live in mip.m3usr in the persist folder — not on this line.  The image
# seeds a mip.m3usr with the API started (see entrypoint.sh).
MIXER_DIR="/home/mip/.wine/drive_c/Program Files/MusicIP/MusicIP Mixer"
MIXER_ARGS="${MIXER_ARGS:--remoteaccess -readonly -notrash -nodiskscan -feedback=off -logex -nowizard -nowatcher -slim}"

# --- Talking to the Mixer's own API, from inside the container -----------
# No curl in the image; python3 is here because the viewer needs it.
API="http://127.0.0.1:10002/api"
api(){  # api <command> <timeout seconds>  -> prints the answer, or nothing
  timeout "$(( ${2:-10} + 5 ))" python3 -c 'import sys,urllib.request
print(urllib.request.urlopen(sys.argv[1], timeout=float(sys.argv[2])).read().decode(errors="replace").strip())' \
    "$API/$1" "${2:-10}" 2>/dev/null
}
mixer_running(){ pgrep -f 'MusicMagicMixer\.exe' >/dev/null; }
STOPFLAG=/tmp/mixer.stopping
rm -f "$STOPFLAG"   # left over from a previous stop of this container

# COMBINED: the Server, its folder and its API on 10003.
SERVER_DIR="/home/mip/.wine/drive_c/Program Files/MusicIP/MusicIP Server"
SAPI="http://127.0.0.1:10003/api"
sapi(){  # sapi <command> <timeout seconds>  -> prints the answer, or nothing
  timeout "$(( ${2:-10} + 5 ))" python3 -c 'import sys,urllib.request
print(urllib.request.urlopen(sys.argv[1], timeout=float(sys.argv[2])).read().decode(errors="replace").strip())' \
    "$SAPI/$1" "${2:-10}" 2>/dev/null
}
server_running(){ pgrep -f 'MusicMagicServer\.exe' >/dev/null; }

# --- Clean stop ----------------------------------------------------------
# docker stop sends SIGTERM to this script, which is PID 1.  Without a handler
# Docker killed everything after its timeout, possibly mid-save.  Now:
#   1. save the library through the API (flush);
#   2. close the Mixer's window, exactly as clicking its close button does —
#      TESTED 2026-09-11: a window close exits the Mixer properly and it saves
#      its settings file.  The API's own shutdown command was TESTED the same
#      day and ignored, so it is not used;
#   3. wait for it to exit, and force it only if it will not go.
# Worst case is about two minutes, so give the container a stop timeout of 3
# minutes (compose: stop_grace_period: 3m; docker stop -t 180).
clean_stop(){
  touch "$STOPFLAG"
  # COMBINED: the Server saves the shared library.  The Mixer is ended WITHOUT
  # flush or window close, so it cannot overwrite the Server's file.
  echo "[$(ts)] stop requested — the Server saves the library"
  r=$(sapi flush 60)
  echo "[$(ts)] flush answered: ${r:-nothing}"
  echo "[$(ts)] ending the Mixer without saving"
  pkill -KILL -f 'MusicMagicMixer\.exe' 2>/dev/null
  echo "[$(ts)] closing the Server's window"
  pkill -f 'MusicMagicServer\.exe' 2>/dev/null
  for i in $(seq 1 30); do server_running || break; sleep 1; done
  if server_running; then
    echo "[$(ts)] Server did not exit — forcing it"
    wineserver -k 2>/dev/null
    sleep 2
  else
    echo "[$(ts)] Server exited by itself"
  fi
  echo "[$(ts)] stopped"
  exit 0
}
trap clean_stop TERM INT

# --- The Mixer, relaunched if it exits -------------------------------------
echo "[$(ts)] starting the Mixer"
(
  trap - TERM INT
  cd "$MIXER_DIR" || exit 1
  while [ ! -e "$STOPFLAG" ]; do
    wine MusicMagicMixer.exe $MIXER_ARGS
    [ -e "$STOPFLAG" ] && break
    echo "[$(ts)] Mixer exited — restarting in 10s"
    sleep 10
  done
) &

# --- COMBINED: the Server, restarted if it is gone -------------------------
# `MusicMagicServer.exe start` may detach, so it is started once and checked by
# process name rather than looped on its exit.
echo "[$(ts)] starting the Server on 10003"
(
  trap - TERM INT
  cd "$SERVER_DIR" || exit 1
  while [ ! -e "$STOPFLAG" ]; do
    if ! server_running; then
      wine MusicMagicServer.exe start &
      sleep 20
    fi
    sleep 10
  done
) &

# --- COMBINED: refresh endpoint on 8199 (replaces the mip-refresh sidecar) ---
# GET /refresh: the Server saves the library, then the Mixer is ended and the
# loop above starts it again, loading the fresh file.
echo "[$(ts)] refresh endpoint on 8199"
python3 /home/mip/refresh.py &

# --- Recovery: restart a Mixer whose API has stopped answering -------------
# The loop above only catches a Mixer that EXITS.  This catches one that is
# still running but no longer answers the API — which is what the music
# depends on.  It arms only after the API has answered once, so a slow library
# load never counts.  After WATCHDOG_FAILS missed checks in a row, WATCHDOG_EVERY
# seconds apart, the Mixer is killed and the loop above starts it again.
# Unsaved library changes since the last flush are lost when that happens.
WATCHDOG_EVERY="${WATCHDOG_EVERY:-60}"
WATCHDOG_FAILS="${WATCHDOG_FAILS:-5}"
echo "[$(ts)] watchdog on — restarts the Mixer after ${WATCHDOG_FAILS} missed API checks, ${WATCHDOG_EVERY}s apart"
(
  trap - TERM INT
  armed=0; fails=0
  while [ ! -e "$STOPFLAG" ]; do
    sleep "$WATCHDOG_EVERY"
    [ -e "$STOPFLAG" ] && break
    if [ -n "$(api getSongCount 20)" ]; then
      [ "$armed" = 0 ] && echo "[$(ts)] watchdog: API answering"
      armed=1; fails=0
    elif [ "$armed" = 1 ]; then
      fails=$((fails + 1))
      echo "[$(ts)] watchdog: API did not answer (${fails} of ${WATCHDOG_FAILS})"
      [ -e "$STOPFLAG" ] && break   # a clean stop is already under way
      if [ "$fails" -ge "$WATCHDOG_FAILS" ]; then
        echo "[$(ts)] watchdog: restarting the Mixer"
        pkill -f 'MusicMagicMixer\.exe'
        sleep 15
        mixer_running && pkill -KILL -f 'MusicMagicMixer\.exe'
        armed=0; fails=0
      fi
    fi
  done
) &

# --- Cache snapshots ----------------------------------------------------
# WHY: so a lost or corrupt cache does not cost a re-analysis of the whole
# library.  MusicIP analyses new material as it arrives; Lyrion's ratings and
# play counts only reach the cache when MusicIP Flow exports, and that export
# ends with a flush.  A flush is the only thing that writes default.m3lib, so
# a NEW TIMESTAMP on that file is the moment worth copying.
#
# The rule, and it is the whole rule: the timestamp changed, it has been still
# for SNAP_SETTLE seconds, so copy it.  Then delete copies older than SNAP_DAYS.
# One copy is pinned at the start and never swept, so a run of bad ones cannot
# leave you with nothing.  Only files matching the name this loop writes are
# ever deleted.
#
#   SNAP_ENABLE=0     turn it off
#   SNAP_DAYS=7       delete dated copies older than this many days
#   SNAP_SETTLE=300   seconds the file must be unchanged before copying
SNAP_ENABLE="${SNAP_ENABLE:-1}"
SNAP_DAYS="${SNAP_DAYS:-7}"
SNAP_SETTLE="${SNAP_SETTLE:-300}"
ROAMING="/home/mip/.wine/drive_c/users/mip/AppData/Roaming/MusicIP/MusicIP Mixer"
CACHE="$ROAMING/default.m3lib"
SNAPDIR="$ROAMING/cache-backups"

if [ "$SNAP_ENABLE" = "1" ]; then
echo "[$(ts)] cache snapshots on — a copy after every flush, kept ${SNAP_DAYS} days, in cache-backups/"
(
  trap - TERM INT
  mkdir -p "$SNAPDIR" 2>/dev/null || true
  last_seen=""
  while [ ! -e "$STOPFLAG" ]; do
    sleep 300
    [ -e "$STOPFLAG" ] && break
    [ -f "$CACHE" ] || continue

    mt=$(stat -c %Y "$CACHE" 2>/dev/null) || continue
    [ "$mt" = "$last_seen" ] && continue                        # nothing new
    [ $(( $(date +%s) - mt )) -lt "$SNAP_SETTLE" ] && continue  # still settling

    dest="$SNAPDIR/default.m3lib.$(date -d "@$mt" +%Y-%m-%d_%H%M)"
    if [ -e "$dest" ]; then last_seen="$mt"; continue; fi

    # Refuse if the filesystem has less than twice the cache free.
    need=$(( $(stat -c %s "$CACHE") / 1024 * 2 ))
    free=$(df -Pk "$SNAPDIR" | awk 'NR==2{print $4}')
    if [ "${free:-0}" -lt "$need" ]; then
      echo "[$(ts)] snapshot skipped — not enough free space"
      last_seen="$mt"; continue
    fi

    if cp -p "$CACHE" "$dest.part" 2>/dev/null && mv "$dest.part" "$dest" 2>/dev/null; then
      echo "[$(ts)] cache snapshot taken: $(basename "$dest")"
      last_seen="$mt"
      [ -e "$SNAPDIR/default.m3lib.pinned" ] || cp -p "$dest" "$SNAPDIR/default.m3lib.pinned"
      # Sweep — ONLY the dated name this loop writes.  .pinned never matches.
      find "$SNAPDIR" -maxdepth 1 -type f \
           -name 'default.m3lib.????-??-??_????' \
           -mtime +"$SNAP_DAYS" -print -delete 2>/dev/null \
        | while read -r old; do echo "[$(ts)] dropped old snapshot: $(basename "$old")"; done
    else
      rm -f "$dest.part" 2>/dev/null
      echo "[$(ts)] snapshot FAILED to write"
    fi
  done
) &
fi

echo "[$(ts)] ready — open http://localhost:8989/vnc.html and click Connect"
# wait returns early when a signal arrives; loop so the handler always runs.
while true; do wait; sleep 1; done
