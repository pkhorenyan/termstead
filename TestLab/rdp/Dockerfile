# An RDP server for Termstead's test lab: xrdp with an Xfce desktop, user
# `lab`, password `lab`. xrdp has no NLA: that, and Kerberos, need a real
# Windows machine. xclip lets the tests read and set the session's clipboard.
FROM debian:bookworm-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      xrdp xorgxrdp xfce4 xfce4-terminal dbus-x11 ssl-cert \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash lab \
 && echo "lab:lab" | chpasswd \
 && adduser xrdp ssl-cert \
 && echo "xfce4-session" > /home/lab/.xsession \
 && chown lab:lab /home/lab/.xsession

# A layer of its own, so adding it reused the one above: the desktop's
# packages are a slow download.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xclip \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3389
ENTRYPOINT ["/entrypoint.sh"]
