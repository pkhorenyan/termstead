# Reuse the lab's Xfce installation; only the VNC server is new.
FROM termstead-lab-xrdp
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tigervnc-standalone-server tigervnc-tools \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /vnc-entrypoint.sh
RUN chmod +x /vnc-entrypoint.sh
ENTRYPOINT ["/vnc-entrypoint.sh"]
