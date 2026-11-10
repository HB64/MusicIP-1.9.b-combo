#!/usr/bin/env python3
# Refresh endpoint for the combined image. GET /refresh makes the Server save the
# shared library, then ends the Mixer so its restart loop reloads the file.
# The Mixer is never flushed: its in-memory copy must not overwrite the Server's.
# A watcher also reloads the Server whenever default.m3lib is changed by someone else
# (e.g. a Lyrion export flushing the Mixer), so the Server never holds stale statistics.
# If the Mixer's song count then differs from the Server's, the Mixer is restarted as well.
# Optional (WATCH_READY=1): a ready folder with already analysed music is moved into the music
# folder once it has been quiet for a while, after which the Server is told to add it.
import os, shutil, subprocess, threading, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

SERVER_FLUSH = "http://127.0.0.1:10003/api/flush"
SERVER_PAGE = os.environ.get("SERVER_PAGE", "http://127.0.0.1:10003/server")
MIXER_COUNT = os.environ.get("MIXER_COUNT", "http://127.0.0.1:10002/api/getSongCount")
SERVER_RELOAD = os.environ.get("RELOAD_URL", "http://127.0.0.1:10003/server/reload")
CACHE_FILE = os.environ.get("CACHE_FILE", "/home/mip/.wine/drive_c/users/mip/AppData/Roaming/MusicIP/MusicIP Mixer/default.m3lib")
POLL = float(os.environ.get("POLL", "5"))       # seconds between checks
STABLE = float(os.environ.get("STABLE", "10"))  # file must stay unchanged this long
IDLE_POLL = float(os.environ.get("IDLE_POLL", "2"))
IDLE_MIN = float(os.environ.get("IDLE_MIN", "5"))      # at least this long before refreshing
IDLE_MAX = float(os.environ.get("IDLE_MAX", "900"))    # give up waiting after this long
SERVER_ADD = os.environ.get("ADD_URL", "http://127.0.0.1:10003/server/add")
WATCH_READY = os.environ.get("WATCH_READY", "0") == "1"      # off unless switched on
READY_DIR = os.environ.get("READY_DIR", "/music-ready")      # where analysed music is dropped
MUSIC_DIR = os.environ.get("MUSIC_DIR", "/music")            # where it is moved to
ADD_ROOT = os.environ.get("ADD_ROOT", "Z:\\music")           # the music folder as MusicIP sees it
READY_QUIET = float(os.environ.get("READY_QUIET", "300"))    # seconds without changes before moving
READY_POLL = float(os.environ.get("READY_POLL", "30"))
lock = threading.Lock()

def refresh():
    if not lock.acquire(blocking=False):
        return
    try:
        try:
            urllib.request.urlopen(SERVER_FLUSH, timeout=60).read()
        except Exception as e:
            print("refresh: Server flush failed:", e, flush=True)
            return
        time.sleep(2)
        subprocess.run(["pkill", "-f", r"MusicMagicMixer\.exe"])
        time.sleep(15)
        subprocess.run(["pkill", "-KILL", "-f", r"MusicMagicMixer\.exe"])
    finally:
        lock.release()

def server_state():
    """Server page -> (active text, stats). None when the Server does not answer."""
    import re
    try:
        body = urllib.request.urlopen(SERVER_PAGE, timeout=5).read().decode("utf-8", "replace")
    except Exception:
        return None
    stats = tuple((re.search(r'id="%s"[^>]*>([^<]*)<' % i, body) or [None, ""])[1].strip()
                  for i in ("st-total", "st-mixable", "st-todo"))
    m = re.search(r'id="st-active"[^>]*>(.*?)</span>', body, re.S)
    active = ""
    if m:
        t = re.sub(r"<(script|style).*?</\1>", "", m.group(1), flags=re.S | re.I)
        t = re.sub(r"<[^>]*>", "", t)
        active = re.sub(r"\s+", " ", t).strip()
    return active, stats

def wait_idle():
    """Wait until the Server is idle with stable numbers (or give up); returns the last stats."""
    start = time.time(); last = None; stable = 0
    while time.time() - start < IDLE_MAX:
        time.sleep(IDLE_POLL)
        st = server_state()
        if st is None:
            continue
        active, stats = st
        stable = stable + 1 if (not active and stats == last) else 0
        last = stats
        if stable >= 3 and time.time() - start >= IDLE_MIN:
            break
    return last

def refresh_when_idle():
    """Wait until the Server has finished, then refresh the Mixer."""
    wait_idle()
    refresh()

def digits(text):
    d = "".join(c for c in str(text) if c.isdigit())
    return int(d) if d else None

def sync_mixer():
    """After a Server reload: restart the Mixer only when its song count differs from the Server's.
    A Mixer flush (e.g. a Lyrion export) leaves both equal, so nothing happens then."""
    stats = wait_idle()
    server_total = digits(stats[0]) if stats else None
    try:
        body = urllib.request.urlopen(MIXER_COUNT, timeout=5).read().decode("utf-8", "replace")
    except Exception:
        return
    mixer_total = digits(body)
    if server_total is None or mixer_total is None or server_total == mixer_total:
        return
    print("watch: Mixer has %s songs, Server %s - refreshing the Mixer" % (mixer_total, server_total), flush=True)
    refresh()

def sig():
    try:
        st = os.stat(CACHE_FILE)
        return (st.st_mtime_ns, st.st_size)
    except OSError:
        return None

def watch():
    last = sig()
    while True:
        time.sleep(POLL)
        cur = sig()
        if cur is None or cur == last:
            continue
        stable_since = time.time()           # wait until the writer is done
        while time.time() - stable_since < STABLE:
            time.sleep(1)
            nxt = sig()
            if nxt != cur:
                cur, stable_since = nxt, time.time()
        if lock.locked():                    # our own refresh wrote it: nothing to do
            last = cur
            continue
        try:
            urllib.request.urlopen(SERVER_RELOAD, timeout=60).read()
            print("watch: cache changed on disk, Server reloaded", flush=True)
            sync_mixer()
        except Exception as e:
            print("watch: Server reload failed:", e, flush=True)
        last = cur

def ready_files():
    """All finished-looking files in the ready folder as (path, size, mtime)."""
    out = []
    for base, _dirs, names in os.walk(READY_DIR):
        for n in names:
            if n.startswith(".") or n.lower().endswith((".part", ".tmp")):
                continue
            p = os.path.join(base, n)
            try:
                st = os.stat(p)
            except OSError:
                continue
            out.append((p, st.st_size, st.st_mtime_ns))
    return sorted(out)

def move_one(src, size):
    """Copy to a .part name, check the size, rename, and only then remove the source.
    An existing file in the music folder is never overwritten. True when the file was moved."""
    rel = os.path.relpath(src, READY_DIR)
    dst = os.path.join(MUSIC_DIR, rel)
    tmp = dst + ".part"
    if os.path.exists(dst):
        print("ready: %s already exists in the music folder - left in the ready folder" % rel, flush=True)
        return False
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, tmp)
        if os.path.getsize(tmp) != size or os.path.getsize(src) != size:
            raise OSError("size mismatch after copy")
        shutil.copystat(src, tmp)
        os.replace(tmp, dst)
    except Exception as e:
        print("ready: could not copy %s: %s" % (rel, e), flush=True)
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False
    try:
        os.remove(src)
    except OSError as e:
        print("ready: copied %s but could not remove the original: %s" % (rel, e), flush=True)
        return False
    return True

def ready_loop():
    """Wait until the ready folder has been quiet, move everything, then have the Server add it."""
    print("ready: watching %s, moving to %s after %d s of quiet" % (READY_DIR, MUSIC_DIR, READY_QUIET), flush=True)
    for d in (READY_DIR, MUSIC_DIR):
        if not (os.path.isdir(d) and os.access(d, os.W_OK)):
            print("ready: WARNING %s is missing or not writable" % d, flush=True)
    last = None; changed = time.time(); done = None
    while True:
        time.sleep(READY_POLL)
        files = ready_files()
        if files != last:
            last, changed = files, time.time()
            continue
        if not files or files == done or time.time() - changed < READY_QUIET:
            continue
        moved = sum(1 for p, size, _ in files if move_one(p, size))
        for base, _dirs, _names in os.walk(READY_DIR, topdown=False):
            if base != READY_DIR:
                try:
                    os.rmdir(base)           # only succeeds when empty
                except OSError:
                    pass
        done = ready_files()                 # leftovers are not retried until they change
        print("ready: moved %d of %d files" % (moved, len(files)), flush=True)
        if not moved:
            continue
        try:
            urllib.request.urlopen(SERVER_ADD + "?root=" + urllib.parse.quote(ADD_ROOT), timeout=60).read()
        except Exception as e:
            print("ready: Add music request failed:", e, flush=True)
            continue
        refresh_when_idle()

class H(BaseHTTPRequestHandler):
    def _send(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0] == "/refresh":
            threading.Thread(target=refresh, daemon=True).start()
            self._send(202, "Refresh triggered - Mixer restarting")
        elif self.path.split("?")[0] == "/refresh-when-idle":
            threading.Thread(target=refresh_when_idle, daemon=True).start()
            self._send(202, "Waiting for the Server to finish, then refreshing the Mixer")
        else:
            self._send(404, "not found")

    def log_message(self, *a):
        pass

threading.Thread(target=watch, daemon=True).start()
if WATCH_READY:
    threading.Thread(target=ready_loop, daemon=True).start()
HTTPServer(("0.0.0.0", 8199), H).serve_forever()
