# MusicIP combined image: Mixer (port 10002) + patched Server (port 10003) sharing ONE default.m3lib,
# plus a small refresh service (port 8199). Debian trixie + Wine + Xvfb + noVNC.
# The first part rebuilds the Mixer base image (reconstructed from the published image's history);
# the second part adds the Server and the refresh service.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    WINEARCH=win32 \
    WINEPREFIX=/home/mip/.wine \
    WINEDLLOVERRIDES="mscoree=d;mshtml=d" \
    WINEDEBUG=fixme-all \
    DISPLAY=:99 \
    LANG=C.UTF-8 \
    HOME=/home/mip

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      wine wine32:i386 \
      xvfb xauth x11-utils x11-apps \
      x11vnc websockify novnc openbox \
      procps ca-certificates wmctrl \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* \
      /usr/share/doc/* /usr/share/man/* /usr/share/info/* \
      /usr/share/locale/* /tmp/*

RUN groupadd -g 1000 mip \
 && useradd -u 1000 -g 1000 -m -s /bin/bash mip

# Create the 32-bit Wine prefix as the service user.
USER mip
RUN xvfb-run -a sh -c 'wineboot --init; wineserver -w'

USER root
RUN rm -rf /tmp/* /tmp/.[!.]* 2>/dev/null || true

# MusicIP Mixer program files; user data lives in the persist folder, the install folder only links to it.
COPY --chown=1000:1000 ["mip_install_from_exe/", "/home/mip/.wine/drive_c/Program Files/MusicIP/MusicIP Mixer/"]
RUN R="/home/mip/.wine/drive_c/users/mip/AppData/Roaming/MusicIP/MusicIP Mixer" \
 && mkdir -p "$R" \
 && chown -R 1000:1000 "/home/mip/.wine/drive_c/users/mip" \
 && cd "/home/mip/.wine/drive_c/Program Files/MusicIP/MusicIP Mixer" \
 && rm -rf examples recipes.xml powerwords.txt Moods \
 && ln -s "$R/recipes.xml"    recipes.xml \
 && ln -s "$R/powerwords.txt" powerwords.txt \
 && ln -s "$R/Moods"          Moods

# Server directory = copy of the Mixer install, minus the Mixer exe,
# plus the patched Server exe and the custom index.html.
ENV MIXER_DIR="/home/mip/.wine/drive_c/Program Files/MusicIP/MusicIP Mixer" \
    SERVER_DIR="/home/mip/.wine/drive_c/Program Files/MusicIP/MusicIP Server" \
    ROAMING="/home/mip/.wine/drive_c/users/mip/AppData/Roaming/MusicIP/MusicIP Mixer"

COPY payload/MusicMagicServer.exe /tmp/payload/MusicMagicServer.exe
COPY payload/server/index.html    /tmp/payload/index.html
COPY mmm.ini                      /tmp/payload/mmm.ini

RUN set -e; \
    mkdir -p "$SERVER_DIR"; \
    cp -a "$MIXER_DIR/." "$SERVER_DIR/"; \
    rm -f "$SERVER_DIR/MusicMagicMixer.exe" "$SERVER_DIR/mmm.ini"; \
    cp /tmp/payload/MusicMagicServer.exe "$SERVER_DIR/MusicMagicServer.exe"; \
    mkdir -p "$SERVER_DIR/server"; \
    cp /tmp/payload/index.html "$SERVER_DIR/server/index.html"; \
    cp /tmp/payload/mmm.ini "$SERVER_DIR/mmm.ini"; \
    rm -f "$SERVER_DIR/recipes.xml"; \
    ln -s "$ROAMING/recipes.xml" "$SERVER_DIR/recipes.xml"; \
    rm -rf /tmp/payload; \
    chown -R mip:mip "$SERVER_DIR"

COPY start-display.sh /home/mip/start-display.sh
COPY refresh.py       /home/mip/refresh.py
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY --chown=1000:1000 defaults/ /opt/defaults/

RUN sed -i 's/\r$//' /home/mip/start-display.sh /home/mip/refresh.py /usr/local/bin/entrypoint.sh \
 && chmod 0755 /home/mip/start-display.sh /home/mip/refresh.py /usr/local/bin/entrypoint.sh \
 && chown 1000:1000 /home/mip/start-display.sh /home/mip/refresh.py

# 10002 Mixer API, 10003 Server (Add music UI), 8989 noVNC, 8199 refresh service
EXPOSE 10002 10003 8989 8199
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
