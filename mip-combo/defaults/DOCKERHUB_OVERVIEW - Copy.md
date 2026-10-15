# MusicIP Mixer 1.96b, under Wine, in a container

`MusicMagicMixer.exe` — the real MusicIP Mixer, the 2008 Windows application —
running headless under Wine on Debian, with its own window served to your
browser, and its HTTP API on port 10002 for Lyrion Music Server (LMS) and
anything else that speaks to MusicIP.

MusicIP shipped two binaries. Most containerised setups run
`MusicMagicServer.exe`. **This image runs the Mixer instead**, because the two
are not equivalent:

| | `MusicMagicMixer.exe` (this image) | `MusicMagicServer.exe` |
|---|---|---|
| inline Power Search, `filter=?expression` | works, on `/api/mix` and `/api/songs` | answers `No such filter` |
| mix size | no ceiling — `size=5000` returns 5001 lines | capped at 75, whatever you ask |
| binary `.m3mood` moods | listed and mixable | not listed; `&mood=` returns HTTP 500 |
| a window you can look at | yes, in a browser | none |

The registration key is included. Power Search needs both the Mixer **and** a
key, and that key has been public on Spicefly's site for about twenty years.

---

## Quick start

```yaml
services:
  mip:
    image: saysaar/musicip-mixer-1.96b-wine
    container_name: mip
    network_mode: host          # see Networking below
    restart: unless-stopped
    stop_grace_period: 3m       # time to save the library and exit cleanly
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/London
    volumes:
      - "/your/persist/folder:/home/mip/.wine/drive_c/users/mip/AppData/Roaming/MusicIP/MusicIP Mixer"
      - "/your/music:/music:ro"
```

Then open **`http://<host>:8989/vnc.html`** and you are looking at MusicIP.

The API answers on **10002**. A first start on an empty folder seeds its
defaults, scans `/music`, and begins analysing; on a large library that takes a
while, and the window shows you exactly where it has got to.

**The mount path must be exactly as above.** The account name `mip` is baked
into it and cannot change.

**Music must be at `/music`.** Wine then maps it to `Z:\music`, which is the
path MusicIP records. Mount your music at the same path in LMS and the two
agree.

---

## Ports

| port | what |
|---|---|
| **10002** | MusicIP's HTTP API |
| **8989** | the viewer — `http://<host>:8989/vnc.html` |

The viewer has no password. Do not expose 8989 beyond your own network.

---

## Networking — read this before choosing bridge

The API is **inbound**, so bridge networking with `-p 10002:10002` serves
mixes perfectly well.

MusicIP's **Send To → SlimServer**, which pushes a mix straight to a Lyrion
player, is **outbound**: MusicIP opens a connection to `localhost:9090`. Under
bridge networking that localhost is the container itself, where nothing is
listening, so the push fails silently — no error, and nothing plays. Published
ports do not help an outbound connection, and the address cannot be
redirected: it is compiled into the binary, and the `-slimcli` and `-slimhttp`
switches are both ignored.

So if you want the push: **host networking**, and Lyrion's command interface on
its default port **9090**. MusicIP also chooses the player itself, and there is
no way to tell it which one.

---

## The persist folder

One mount, and it is MusicIP's own settings folder. The image writes a plain
guide called **`ABOUT THIS FOLDER.txt`** into it at every start, which explains
each file. In short:

**Yours.** `recipes.xml`, `powerwords.txt`, `Moods/`, `mip.m3usr`,
`register.key`. The image supplies a default only when the file is missing and
never overwrites one that is there. Delete one and the default comes back.

**MusicIP's.** `default.m3lib` — the library, every analysis and your filters.
No cache is shipped; MusicIP builds its own. `log.txt`, and `djs/`, a dead
feature no switch prevents.

**The image's.** `ABOUT THIS FOLDER.txt`, and `cache-backups/`.

Nothing the image does not recognise is ever deleted. It names such files once
in the container log and leaves them alone.

---

## Cache backups

MusicIP writes its library to disk only when something asks it to save — a
Lyrion export, File > Save, or closing the window. There is no timer, and a
crash loses whatever has not been saved.

So whenever the cache is written, the container waits for it to settle and
copies it into `cache-backups/`, named for the date and time of that save.
Copies older than seven days are deleted. One copy, `default.m3lib.pinned`, is
made from the first snapshot and then kept for ever.

To go back to one: stop the container, copy it over `default.m3lib` under that
name, start the container. The point is that losing a cache never costs you a
re-analysis of the whole library.

---

## Settings

| variable | default | what it does |
|---|---|---|
| `PUID` / `PGID` | `1000` | the account the Mixer runs as. The persist folder is chowned to match only when it differs |
| `TZ` | unset | container time zone |
| `MIXER_ARGS` | see below | replaces the **whole** switch line |
| `LOG_MAX_MB` | `20` | `log.txt` is emptied in place, once a day, above this size |
| `WATCHDOG_EVERY` | `60` | seconds between API liveness checks |
| `WATCHDOG_FAILS` | `5` | missed checks in a row before the Mixer is restarted |
| `SNAP_ENABLE` | `1` | `0` turns cache backups off |
| `SNAP_DAYS` | `7` | dated copies older than this are deleted |
| `SNAP_SETTLE` | `300` | seconds the cache must be unchanged before it is copied |

The default switch line:

```
-remoteaccess -readonly -notrash -nodiskscan -feedback=off -logex -nowizard -nowatcher -slim
```

`-remoteaccess` turns the API on, `-readonly` means your music files are never
written to, `-nowatcher` removes a Preferences page that freezes the window,
and `-slim` is what makes Send To → SlimServer available. **`MIXER_ARGS`
replaces the line entirely**, so if you set it, carry over what you still want.

---

## Stopping

The library is only written when MusicIP is asked to save it:

```
curl http://localhost:10002/api/flush
docker compose stop mip
```

Never a plain `docker stop` — that kills it in ten seconds, possibly
mid-write. `stop_grace_period: 3m` gives the clean stop room to save the
library and close the window properly.

---

## If it misbehaves

A stuck window:

```
docker exec mip pkill -f MusicMagicMixer
```

It comes back about ten seconds later and the container stays up. A watchdog
does the same by itself if the API stops answering.

Otherwise restart the container, or the host. Nothing a save wrote is lost.

---

## Known limits

* **New music arrives on its own**, through MusicIP's own watch on `Z:\music`,
  usually within minutes. There is no rescan command in the API and the Mixer
  has none of the server's web-page commands, so there is nothing to call.
* **The container analyses music but cannot write the analysis back into the
  files** — it goes into the cache only. Files that already carry a
  fingerprint are much faster.
* **The window sometimes draws only half of itself.** Move or scroll it and it
  repaints. Cosmetic, and unexplained.
* **The push chooses its own player**, and cannot be told which.

---

## Credits and licence

MusicIP Mixer is a 2008 application by MusicIP Corporation and is not mine. The
installer, the bundled BASS libraries and the registration key have been
publicly available for about twenty years. This image packages it; it does not
modify it.

Source, minus the binaries: **github.com/gupta-as** — see the repository named
for this image.
