#!/bin/sh
# Termstead test lab: SSH servers in Docker to connect to — directly, through
# one jump host, and through two.
#
#   ./lab.sh up      create keys if missing, build, start, wait until ready
#   ./lab.sh down    stop and remove the containers
#   ./lab.sh status  show the containers
#   ./lab.sh forget  drop the lab's entries from ~/.ssh/known_hosts
#
# Login everywhere: user `lab`, password `lab`, or the key ~/.ssh/termstead-lab.
# ~/.ssh/termstead-lab-passphrase is the same idea with the passphrase `lab`.
set -eu
cd "$(dirname "$0")"

KEY="$HOME/.ssh/termstead-lab"
PASSKEY="$HOME/.ssh/termstead-lab-passphrase"
HOSTS="direct bastion app middle db"

prepare() {
    mkdir -p "$HOME/.ssh" .state/hostkeys
    chmod 700 "$HOME/.ssh"
    # Only ever created, never replaced: an existing file is left as it is.
    [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "termstead-lab" -f "$KEY"
    [ -f "$PASSKEY" ] || ssh-keygen -q -t ed25519 -N "lab" -C "termstead-lab-passphrase" -f "$PASSKEY"
    cat "$KEY.pub" "$PASSKEY.pub" > .state/authorized_keys
    # One host key per server, kept across rebuilds so known_hosts stays valid.
    for host in $HOSTS; do
        [ -f ".state/hostkeys/$host" ] || ssh-keygen -q -t ed25519 -N "" -C "$host" -f ".state/hostkeys/$host"
    done
}

wait_for() {
    port=$1
    for _ in $(seq 1 30); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then return 0; fi
        sleep 1
    done
    echo "port $port did not come up" >&2
    return 1
}

case "${1:-}" in
    up)
        prepare
        docker compose up -d --build
        wait_for 2201
        wait_for 2202
        echo
        echo "Lab is up. In Termstead: Debug ▸ Add Test Lab Sessions, or launch with -sb-sample YES."
        echo "  direct   127.0.0.1:2201"
        echo "  bastion  127.0.0.1:2202 ─▶ app"
        echo "  bastion  ─▶ middle ─▶ db"
        echo "User lab, password lab, key $KEY"
        echo "Each home folder holds files to try the Files tab on (see entrypoint.sh)."
        ;;
    down)
        docker compose down
        ;;
    status)
        docker compose ps
        ;;
    forget)
        for host in "[127.0.0.1]:2201" "[127.0.0.1]:2202" app middle db; do
            ssh-keygen -q -R "$host" >/dev/null 2>&1 || true
        done
        echo "Removed the lab's host keys from ~/.ssh/known_hosts."
        ;;
    *)
        sed -n '2,12p' "$0"
        exit 2
        ;;
esac
