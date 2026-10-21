# An RDP server for Termstead's test lab: xrdp with an Xfce desktop, user
# `lab`, password `lab`. xrdp has no NLA: that, and Kerberos, need a real
# Windows machine.
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

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3389
ENTRYPOINT ["/entrypoint.sh"]
