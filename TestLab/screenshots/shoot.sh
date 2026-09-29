#!/bin/sh
# The README's screenshots: the sample sessions, minus the test lab, with four
# tabs open on what look like real servers. `prefix.conf` points each sample
# address at a lab container, and every demo script prints plausible output
# before handing over to a shell with the matching prompt.
#
#   TestLab/screenshots/shoot.sh stage   # needs ./lab.sh up; copies the scripts in
#   TestLab/screenshots/shoot.sh open    # a separate copy of the Release build
#   TestLab/screenshots/shoot.sh clean   # removes the staging from the containers
#
# Capture the window by id (see CLAUDE.md), downscale to 1600 px wide with
# `sips -Z 1600`, and save into docs/images/. Extra arguments go to the app:
# `open -sb-sidebar files` for the SFTP shot (the sidebar stays on Sessions
# otherwise: it does not turn to SFTP on login here), and
# `open -sb-route sessionSettings -sb-session staging-app` for the form.
set -e
cd "$(dirname "$0")"
APP=../../build/Build/Products/Release/Termstead.app

put() { docker exec -i "$1" sh -c "mkdir -p /tmp/demo && cat > /tmp/demo/$2" < "$2"; }

case "$1" in
stage)
    put termstead-lab-direct-1 webroot.sh
    docker exec termstead-lab-direct-1 sh /tmp/demo/webroot.sh
    put termstead-lab-direct-1 web01.sh
    put termstead-lab-app-1 staging.sh
    put termstead-lab-app-1 db.sh
    put termstead-lab-db-1 web02.sh
    ;;
open)
    shift
    store=$(mktemp -t termstead-shots).json
    cp sessions.json "$store"
    open -n "$APP" --args -sb-store "$store" \
        -sb-connect prod-web-01,prod-web-02,db-primary,staging-app \
        -sb-ssh-prefix "$PWD/prefix.conf" \
        -appearance.theme graphite -appearance.followSystem NO \
        -files.showAfterLogin NO "$@"
    ;;
clean)
    docker exec termstead-lab-direct-1 sh -c 'rm -rf /srv/www; deluser deploy 2>/dev/null; rm -rf /tmp/demo' || true
    for c in app db; do docker exec termstead-lab-$c-1 rm -rf /tmp/demo || true; done
    ;;
*)
    echo "usage: $0 stage | open | clean" >&2
    exit 1
    ;;
esac
