#!/bin/sh
# The README's screenshots: the sample sessions, minus the test lab, with four
# tabs open on what look like real servers. `prefix.conf` points each sample
# address at a lab container, and every demo script prints plausible output
# before handing over to a shell with the matching prompt.
#
#   TestLab/screenshots/shoot.sh stage   # needs ./lab.sh up; copies the scripts in
#   TestLab/screenshots/shoot.sh open    # a separate copy of the Release build
#   TestLab/screenshots/shoot.sh panes   # the same in four panes, broadcasting (fleet.sh)
#   TestLab/screenshots/shoot.sh desktop # dev-desktop, a remote desktop through bastion-01
#   TestLab/screenshots/shoot.sh clean   # removes the staging from the containers
#
# Capture the window by id (see CLAUDE.md), downscale to 1600 px wide with
# `sips -Z 1600`, and save into docs/images/. Extra arguments go to the app:
# `open -sb-sidebar files` for the SFTP shot (the sidebar stays on Sessions
# otherwise: it does not turn to SFTP on login here), and
# `open -sb-route sessionSettings -sb-session staging-app` for the form.
#
# The desktop logs in as `dev` (password `dev`, made by `stage`) and needs
# that password in the Keychain for its session, readable by the Release
# build without asking; delete it once the shot is taken:
#   security add-generic-password -s com.pavelkhorenyan.Termstead \
#       -a session:dev-desktop:password -w dev -T "$PWD/$APP"
#   security delete-generic-password -s com.pavelkhorenyan.Termstead \
#       -a session:dev-desktop:password
# Its certificate must be trusted for rdp:3389 already: connect
# lab-rdp-via-bastion once.
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
    for c in direct app db; do put termstead-lab-$c-1 fleet.sh; done
    docker exec -i termstead-lab-rdp-1 sh -s < desktop.sh
    ;;
open|panes)
    mode=$1
    shift
    store=$(mktemp -t termstead-shots).json
    cp sessions.json "$store"
    prefix=$PWD/prefix.conf
    if [ "$mode" = panes ]; then
        # Every server runs fleet.sh, named after its own demo script.
        prefix=$(mktemp -t termstead-shots).conf
        sed -E 's|RemoteCommand sh /tmp/demo/([a-z0-9]+)\.sh|RemoteCommand sh /tmp/demo/fleet.sh \1|' \
            prefix.conf > "$prefix"
        set -- -sb-layout grid -sb-broadcast YES "$@"
    fi
    open -n "$APP" --args -sb-store "$store" \
        -sb-connect prod-web-01,prod-web-02,db-primary,staging-app \
        -sb-ssh-prefix "$prefix" \
        -appearance.theme graphite -appearance.followSystem NO \
        -files.showAfterLogin NO "$@"
    ;;
desktop)
    shift
    store=$(mktemp -t termstead-shots).json
    cp sessions.json "$store"
    open -n "$APP" --args -sb-store "$store" \
        -sb-connect dev-desktop,prod-web-01,db-primary \
        -sb-ssh-prefix "$PWD/prefix.conf" \
        -appearance.theme graphite -appearance.followSystem NO \
        -files.showAfterLogin NO "$@"
    # Once dev is logged in, a file manager and a terminal on its desktop.
    display=
    for _ in $(seq 60); do
        display=$(docker exec termstead-lab-rdp-1 sh -c "ps -o args= -u dev | grep -o 'Xorg :[0-9]*' | head -n 1 | cut -c6-")
        [ -n "$display" ] && break
        sleep 1
    done
    [ -n "$display" ] || { echo "dev never logged in" >&2; exit 1; }
    sleep 5
    docker exec -d termstead-lab-rdp-1 su dev -c "cd ~/Projects && DISPLAY=$display thunar ~/Projects"
    sleep 2
    docker exec -d termstead-lab-rdp-1 su dev -c "cd ~/Projects && DISPLAY=$display xfce4-terminal --geometry=56x8+860+780 -x bash -c 'ls --color=auto; echo; python3 --version; exec bash'"
    ;;
clean)
    docker exec termstead-lab-direct-1 sh -c 'rm -rf /srv/www; deluser deploy 2>/dev/null; rm -rf /tmp/demo' || true
    for c in app db; do docker exec termstead-lab-$c-1 rm -rf /tmp/demo || true; done
    docker exec termstead-lab-rdp-1 sh -c 'pkill -u dev; sleep 1; userdel -r dev 2>/dev/null' || true
    ;;
*)
    echo "usage: $0 stage | open | panes | desktop | clean" >&2
    exit 1
    ;;
esac
