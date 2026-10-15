#!/usr/bin/env python3
# Refresh endpoint for the combined image. GET /refresh makes the Server save the
# shared library, then ends the Mixer so its restart loop reloads the file.
# The Mixer is never flushed: its in-memory copy must not overwrite the Server's.
# A watcher also reloads the Server whenever default.m3lib is changed by someone else
# (e.g. a Lyrion export flushing the Mixer), so the Server never holds stale statistics.
# If the Mixer's song count then differs from the Server's, the Mixer is restarted as well.
import os, subprocess, threading, time, urllib.request
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
HTTPServer(("0.0.0.0", 8199), H).serve_forever()
