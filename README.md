# MusicIP combined image (Mixer + Server, Wine / Windows 1.9.b)

Docker image for running MusicIP — the classic music analysis and mix generation server — using the **headless Windows 1.9.b** build under Wine, with **two** MusicIP programs in one container that share one library file:

- the **Mixer** (port `10002`): the API used for mixes and Power Search filters, with its library in memory;
- the **Server** (port `10003`): the web page for Add music, Refresh songs and Reload cache, running a patched `MusicMagicServer.exe` with higher mix limits.

A small refresh service (port `8199`) keeps the two in sync, so adding music in the Server shows up in the Mixer without manual steps.

## Before you start

### Permissions

The entrypoint remaps the `mip` account to the `PUID`/`PGID` you provide and takes ownership of the Wine prefix on startup, so no manual `chown` step is required. Set `PUID`/`PGID` to match the owner of your persist folder (and music directory) on the host. After the setup step the entrypoint uses `setpriv` to drop from root to `mip` before launching Wine and MusicIP.

### Persist folder

Mount a persist folder at `.../AppData/Roaming/MusicIP/MusicIP Mixer` (see the compose example). It holds `default.m3lib` (the library, shared by Mixer and Server), your settings and your recipes. On first start the entrypoint seeds it with working defaults (`recipes.xml`, `powerwords.txt`, `mip.m3usr`, `register.key`) and never touches them again once they exist. Delete a file and it comes back with the default; edit it and it stays.

## Usage

### docker-compose

```yaml
services:
  mip:
    image: ghcr.io/hb64/mip-combo:latest
    container_name: mip
    restart: unless-stopped
    stop_grace_period: 90s
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Amsterdam
    ports:
      - "10002:10002"   # Mixer API (Power Search, mixes)
      - "10003:10003"   # Server (Add music, Refresh, Reload cache)
      - "8989:8989"     # noVNC (the Mixer window)
      - "8199:8199"     # refresh service
    volumes:
      - /path/to/music:/music
      - /path/to/appdata:/home/mip/.wine/drive_c/users/mip/AppData/Roaming/MusicIP/MusicIP Mixer
```

`stop_grace_period: 90s` gives the Server time to save the library on a normal stop.

Check that it is up:

```bash
curl http://localhost:10002/api/version        # Mixer
curl http://localhost:10003/api/getSongCount   # Server
curl -i http://localhost:8199/refresh-when-idle   # refresh service, expect 202
```

### Music path inside MusicIP

Your music is mounted at `/music`, which Wine maps to `Z:\music`. This is the path MusicIP uses for your library, and the "Add music folder" field on the Server page (`http://localhost:10003`) is pre-filled with it — just click **Add music**.

If you mounted your music somewhere else than `/music`, tick **"Music folder differs from Z:\music"** on the Server page and enter the matching Wine path (e.g. `Z:\mymusic`; Wine's `Z:` drive maps to the container's `/`), and change the container side of the volume mount to match.

## How the Mixer and the Server stay in sync

Both programs use the same `default.m3lib`. The Server writes it when it scans music. The Mixer keeps its own copy in memory and is only ever **restarted** (never flushed), so its copy can never overwrite the Server's.

The refresh service (`refresh.py`, port `8199`):

| Endpoint / function | What it does |
|---|---|
| `/refresh` | The Server saves the library, then the Mixer is restarted and reloads the file (30–45 seconds). |
| `/refresh-when-idle` | Waits until the Server has finished (idle, numbers stable), then does `/refresh`. |
| File watcher | When `default.m3lib` is changed by someone else (for example a Lyrion export that flushes the Mixer, or a restored backup), the Server reloads it after 10 seconds of quiet. Then the Mixer's song count is compared with the Server's: if they differ, the Mixer is restarted too; if they are equal (a normal Mixer flush) nothing happens. |

The Server page calls `/refresh-when-idle` by itself after **Add music**, **Refresh** and **Reload cache**, so the Mixer follows without extra steps.

## Changes made in the Mixer window

Changes you make in the Mixer window (noVNC, port `8989`) live in the Mixer's memory. The Mixer writes them to `default.m3lib` **only when it exits**, so nothing reaches the library file, the Server or the Server page until then.

To save your changes:

1. Click **Exit** in the Mixer window. It briefly shows that it is saving the database.
2. The Mixer restarts by itself and loads the saved file (30-45 seconds).
3. The refresh service sees the new file and reloads the Server after 10 seconds of quiet. The Server page may show "Cache has been modified on disk" for a short while; it clears by itself once the Mixer has started.

Changes that are not saved this way are lost when the refresh service restarts the Mixer, which happens after **Add music**, **Refresh** or **Reload cache**. So click **Exit** when you are done with a change, before you start any of those actions.

## Using with Lyrion Music Server (LMS)

Under Wine, MusicIP stores and returns paths in Windows format (`Z:\music\...`), while LMS expects `/music/...`. The plugin you use for mixing has to translate between the two (path conversion: MusicIP `Z:\music`, Lyrion `/music`).

In the combined container the Mixer API is on `10002` and the Server is on `10003`. A plugin that assumes the Server pages are served on the Mixer port will hide Add music and Search, so give it both ports. The MIPster plugin has a MusicIP settings page for this:

| Setting | Value |
|---|---|
| MusicIP Server Port | `10003` |
| MusicIP Mixer Refresh Port | `8199` |

With these it shows the Server's statistics and the Mixer's song count and offers Add music, Refresh songs and Reload cache. Leave them empty if you have no combined container.

The page refreshes itself while it is open, so you can watch the Mixer catch up after a change: every 5 seconds while the Server is busy or the Mixer count is unknown or restarting, otherwise every 15 seconds. It pauses while you are typing in a field or the tab is hidden, and stops when you leave the page.

## Patched MusicMagicServer.exe (higher mix limits)

The `MusicMagicServer.exe` in this image is a patched build of the original 1.9.b server. The stock server caps the size of a mix; the patched one raises those caps:

| Limit | Stock | Patched |
|---|---|---|
| Tracks | 75 | 300 |
| Minutes | 300 | 1000 |
| MB | 300 | 1000 |

The cap is enforced inside the server executable itself (the MusicIP Mixer executable has no such cap), so it can't be changed through configuration.

**What changed:** 31 bytes; the file size is identical (3,059,712 bytes). The limits are stored as constants in the code and are changed in place. One clamp compared against a 1-byte constant (`cmp esi, 75`), which can't hold 300, so that instruction jumps to a small stub placed in unused zero padding at file offset `0x23EED0`; the stub does the same compare and clamp against 300. Nothing else is modified.

| File | MD5 |
|---|---|
| Original `MusicMagicServer.exe` | `d83a71f4e42acdbcf4e35ae7780c234c` |
| Patched `MusicMagicServer.exe` (this image) | `c37e760523243de07f8b24213aaf76ce` |

To verify what your container is running:

```bash
docker exec mip md5sum "/home/mip/.wine/drive_c/Program Files/MusicIP/MusicIP Server/MusicMagicServer.exe"
```

The Server also has a customised `index.html` (the page on port `10003`), which adds the automatic Mixer refresh described above.

## Parameters

| Parameter | Function |
|---|---|
| `PUID` | User ID for file permissions (default: `1000`) |
| `PGID` | Group ID for file permissions (default: `1000`) |
| `TZ` | Time zone, e.g. `Europe/Amsterdam` |
| `-p 10002:10002` | MusicIP Mixer API |
| `-p 10003:10003` | MusicIP Server (web page and API) |
| `-p 8989:8989` | noVNC, to see and use the Mixer window |
| `-p 8199:8199` | Refresh service |
| `-v ...AppData/Roaming/MusicIP/MusicIP Mixer` | Persist folder: library, settings and recipes |
| `-v .../music:/music` | Your music library (appears to MusicIP as `Z:\music`) |

Optional environment variables for the refresh service:

| Variable | Function | Default |
|---|---|---|
| `CACHE_FILE` | Path of `default.m3lib` to watch | the file in the persist folder |
| `POLL` | Seconds between file checks | `5` |
| `STABLE` | Seconds the file must stay unchanged before reacting | `10` |
| `RELOAD_URL`, `SERVER_PAGE`, `MIXER_COUNT` | URLs the service uses | local Server and Mixer |
| `IDLE_POLL`, `IDLE_MIN`, `IDLE_MAX` | Waiting for the Server to become idle (seconds) | `2` / `5` / `900` |

## Troubleshooting

**Permission errors on volumes** — Make sure `PUID`/`PGID` match the owner of the mounted directories on the host.

**Wine error messages in logs (Vulkan, Bluetooth, RPC/OLE)** — These are harmless. Wine logs errors for Windows subsystems MusicIP doesn't use. As long as `curl http://localhost:10002/api/version` responds, everything is fine.

**"Songs in Mixer" is unknown or lower than the Server's total for a while** — The Mixer restarts after Add music, Refresh or a changed library file, which normally takes 30–45 seconds (longer if a lot was added or removed). It catches up by itself, and the MIPster page follows along on its own.

**The Server shows "Cache has been modified on disk"** — The library file changed outside the Server. The refresh service reloads it automatically after 10 seconds; the **Reload cache** button does the same immediately. While the Mixer is restarting (30–45 seconds, for example after **Exit**), the library file is still in use and **Reload cache** does nothing; the notice stays until the Mixer has started, and then the Server reloads by itself.

**Port conflict** — Change the host side of the port mapping, e.g. `-p 11003:10003`.

**Music folder not found / "Add music folder" fails** — Confirm the container-side path in your volume mount matches what you enter on the Server page (see "Music path inside MusicIP" above). They must point to the same folder.

**Rating / play count export reports errors for some tracks** — MusicIP 1.9.b does not handle non-ASCII characters in file paths (for example `ö`, `é`, `²`, `’` or Japanese names). For those tracks the Mixer answers but refuses to set Rating, PlayCount and LastPlayed, so an export from Lyrion ends with "Export finished with errors". Tracks with plain ASCII paths are not affected. This comes from MusicIP itself, not from this image; renaming files or fixing tags only helps sporadically.

### ⚠️ MusicIP 1.9.b filter behaviour — stricter than 1.8

MusicIP 1.9.b enforces stricter rules for filter conditions than 1.8. Filters that worked in 1.8 can silently fail in 1.9.b with `MUSICIP RETURNED NOTHING`. **Review all your filters in the MusicIP Mixer GUI after migrating from 1.8.**

Known differences:

- **"Match ALL" with multiple Artist conditions** — no track can match multiple artists simultaneously, so the filter always returns nothing. Change to **"Match ANY"**.
- **Mixing `is` and `is not` conditions** — combining positive and negative conditions in the same filter fails in 1.9.b even when logically valid. Keep filters to either all `is` or all `is not` conditions.

#### ⚠️ "Match ANY" + a single `is not` condition can silently return your whole library

**Match ANY** is an OR across every condition in the filter. Adding even one `Artist is not X` (or `Genre is not X`) condition to an otherwise well-targeted Match ANY filter can undo it almost entirely: `NOT(X)` is true for nearly every track in your library except X's own, so under OR logic that single condition alone lets nearly everything through.

MusicIP's filter only has one match mode for its whole condition list, so there's no way to express "(any of these) AND (not this)" inside a single filter. Keep exclusions out of Match ANY filters, or split inclusion and exclusion into two filters and combine them at the recipe level.

Test a filter directly via the API to verify it works:

```bash
curl --get "http://localhost:10002/api/mix" \
  --data-urlencode "song=Z:\music\<path>" --data-urlencode "size=5" --data-urlencode "filter=<filtername>"
```

## Credits

The Mixer part of this image is based on the work of **saysaar**: the Docker image `saysaar/musicip-mixer-1.9`. The Dockerfile here was reconstructed from that image's build history, and these files come from it (some adjusted): `entrypoint.sh`, `start-display.sh`, the `defaults` folder and the layout of the MusicIP install. Many thanks for the groundwork.

Added on top of it: the MusicIP Server on its own port (patched `MusicMagicServer.exe` with the higher mix limits, and a custom `index.html`), `refresh.py` (the refresh service and file watcher) and the combined setup.

MusicIP itself is the work of its original authors and is not affiliated with this project.
