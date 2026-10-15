#!/usr/bin/env bash
# Root init for the mixer image.  Mirrors build-v2/entrypoint.sh: remap the
# `mip` account to PUID/PGID, fix ownership, clear stale /tmp state that only
# root can clear, then drop privileges and hand off to start-display.sh.
#
# WHY THIS EXISTS.  The image build runs `wineboot` as uid 1000 and leaves an X
# lock and a wine temp dir behind, owned by 1000 and readable only by their
# owner.  Any previous container run leaves the same.  Run with any PUID other
# than 1000 and the dropped user cannot remove them, and wine dies with
#   wine: chdir to /tmp/wine-XXXXXX : Permission denied
# Xvfb comes up, the Mixer never starts, the API never answers.  Root can
# always clear them.  Xvfb also cannot create /tmp/.X11-unix unless it is root,
# which is the _XSERVTransmkdir error this removes.
#
set -u

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
ROAMING="/home/mip/.wine/drive_c/users/mip/AppData/Roaming/MusicIP/MusicIP Mixer"
DEF="/opt/defaults"

ts(){ date -u +%H:%M:%S; }
echo "[$(ts)] init (uid $(id -u)) — target mip ${PUID}:${PGID}"

# --- 1. Remap the service account.  Idempotent; -o permits a non-unique id.
if [ "$(id -g mip)" != "$PGID" ]; then groupmod -o -g "$PGID" mip; fi
if [ "$(id -u mip)" != "$PUID" ]; then usermod  -o -u "$PUID" -g "$PGID" mip; fi

# --- 2. Own the Wine prefix, but ONLY when ownership actually differs.
# Unconditional chown -R would walk the whole prefix on every boot.
if [ "$(stat -c '%u:%g' /home/mip)" != "$PUID:$PGID" ]; then
  echo "[$(ts)] chown /home/mip -> ${PUID}:${PGID}"
  chown -R "$PUID:$PGID" /home/mip
fi

# --- 3. Seed the persist folder.  PRECEDENCE TO USER-SUPPLIED FILES: anything
# already there is left strictly alone.  Delete a file and it comes back next
# boot with the default; edit it and it is never touched again.
#
# mip.m3usr is the Mixer's own settings file.  A fresh one leaves the API
# switched on but NOT started, so nothing listens, and shows a tip dialog at
# every start.  The seeded copy was set by hand (API started, tips
# off, Power Search and Power Tools on, window maximized) and holds nothing
# personal.
#
# register.key is the MusicIP key, public on Spicefly's site for years.  Without
# it inline Power Search answers "No such filter".  A key you supply wins.
#
# NOT seeded: default.m3lib (MIP creates its own cache).  Moods/ is created empty
# and never populated; the install-dir symlink points at it.
mkdir -p "$ROAMING"
for f in recipes.xml powerwords.txt mip.m3usr register.key; do
  if [ ! -e "$ROAMING/$f" ]; then
    echo "[$(ts)] seeding $f"
    cp "$DEF/$f" "$ROAMING/$f" 2>/dev/null || true
  fi
done
mkdir -p "$ROAMING/Moods"
# djs/ is made by the Mixer at every start, for the dead MyDJ feature, and no
# switch stops it.  A note inside says so.  The Mixer only reads *.m3dj files
# there, so a .txt is ignored.
mkdir -p "$ROAMING/djs"
if [ ! -e "$ROAMING/djs/README.txt" ]; then
  printf 'Nuisance folder installed by MIP. If you find a way to remove it, please share\r\n' > "$ROAMING/djs/README.txt"
fi
# cache-backups/ is where the snapshot loop in start-display.sh writes.
mkdir -p "$ROAMING/cache-backups"

# --- 3b. The image's own guide, rewritten at EVERY boot.  It is documentation,
# not settings, so it is the one file here the image overwrites.  The headless
# image's README.txt is removed by that name only: it survived the cutover
# describing the wrong image.  NOTHING ELSE IS EVER DELETED.
cp -f "$DEF/ABOUT_THIS_FOLDER.txt" "$ROAMING/ABOUT THIS FOLDER.txt" 2>/dev/null || true
rm -f "$ROAMING/README.txt" 2>/dev/null || true

# --- 3c. Name anything unrecognised, and leave it alone.  This is how a stale
# file gets noticed instead of sitting there for weeks.  It is a report, not a
# clean-up.
( cd "$ROAMING" 2>/dev/null || exit 0
  unknown=""
  for e in * .[!.]*; do
    [ -e "$e" ] || continue
    case "$e" in
      recipes.xml|powerwords.txt|mip.m3usr|register.key|mmm.ini) ;;
      default.m3lib|default.m3lib-saving|log.txt) ;;
      "ABOUT THIS FOLDER.txt") ;;
      Moods|djs|cache-backups) ;;
      *) unknown="$unknown $e" ;;
    esac
  done
  [ -n "$unknown" ] && echo "[$(ts)] unexpected in the persist folder, left untouched:$unknown"
) || true

chown -R "$PUID:$PGID" "$ROAMING" 2>/dev/null || true

# --- 4. Clear stale /tmp state while STILL ROOT, and create the X socket dir.
rm -rf /tmp/.X99-lock /tmp/.X11-unix /tmp/wine-* /tmp/.wine-* /tmp/runtime-* /tmp/mixer.stopping 2>/dev/null || true
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
chmod 1777 /tmp 2>/dev/null || true

echo "[$(ts)] dropping to mip and starting the display"
exec setpriv --reuid mip --regid mip --init-groups /home/mip/start-display.sh
