# Reuse the lab's Xfce installation; only the VNC server is new.
FROM termstead-lab-xrdp
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tigervnc-standalone-server tigervnc-tools openssh-server python3-gi gir1.2-gtk-3.0 xdotool \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /vnc-entrypoint.sh
COPY sshd_config /etc/ssh/sshd_config
RUN chmod +x /vnc-entrypoint.sh
ENTRYPOINT ["/vnc-entrypoint.sh"]
