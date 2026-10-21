#!/bin/sh
# xrdp-sesman starts each login's X server and desktop; xrdp itself speaks RDP.
set -e
rm -f /var/run/xrdp/*.pid
xrdp-sesman
exec xrdp --nodaemon
