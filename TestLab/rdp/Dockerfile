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

# xrdp keeps one session per user and hands it to the next login, dropping
# the one before. A second user, lab2 (password lab), lets two desktops be
# open together — lab-rdp-via-bastion logs in as lab2. A session per
# connection (Policy=UBC) was tried: this xrdp never ends a disconnected
# Xorg session, KillDisconnected or not, and every test run left a desktop
# behind until the 50-session limit refused logins.
RUN useradd -m -s /bin/bash lab2 \
 && echo "lab2:lab" | chpasswd \
 && echo "xfce4-session" > /home/lab2/.xsession \
 && chown lab2:lab2 /home/lab2/.xsession

# Files copied on the client reach the session through xrdp's FUSE
# filesystem (~/thinclient_drives/.clipboard), which needs fusermount; the
# compose file hands the container /dev/fuse.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fuse \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3389
ENTRYPOINT ["/entrypoint.sh"]
