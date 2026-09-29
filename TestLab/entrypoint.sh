#!/bin/sh
# Host keys and authorized_keys come in read-only from TestLab/.state, so a
# rebuilt container keeps the same host key and known_hosts stays valid.
set -e
install -m 600 /lab/hostkey /etc/ssh/ssh_host_ed25519_key
install -m 600 -o lab -g lab /lab/authorized_keys /home/lab/.ssh/authorized_keys

cat > /etc/motd <<MOTD

  Termstead test lab — you are on: $(hostname)
  $LAB_ROLE

MOTD
printf 'export PS1="lab@%s:\\w\\$ "\n' "$(hostname)" > /home/lab/.bashrc
chown lab:lab /home/lab/.bashrc
printf '[ -f ~/.bashrc ] && . ~/.bashrc\n' > /home/lab/.bash_profile
chown lab:lab /home/lab/.bash_profile

# Something to browse in Termstead's Files tab. Seeded once per container, so
# files uploaded while testing survive a restart (not a `./lab.sh down`).
if [ ! -f /home/lab/.lab-seeded ]; then
    cd /home/lab
    echo "You are on $(hostname). $LAB_ROLE" > whoami.txt

    mkdir -p logs/nginx
    for i in $(seq 1 200); do
        echo "2026-09-29 08:$(printf %02d $((i % 60))):00 INFO request $i served in $((i * 7 % 300)) ms"
    done > logs/app.log
    echo "2026-09-29 08:12:00 [error] upstream timed out" > logs/nginx/error.log
    # Big enough to watch a download's progress bar move.
    dd if=/dev/urandom of=logs/big-20MB.bin bs=1M count=20 2>/dev/null

    mkdir -p etc/nginx/sites-available etc/nginx/sites-enabled
    printf 'worker_processes auto;\nevents { worker_connections 1024; }\n' > etc/nginx/nginx.conf
    printf 'server {\n    listen 80;\n    root /var/www;\n}\n' > etc/nginx/sites-available/default
    ln -s ../sites-available/default etc/nginx/sites-enabled/default

    mkdir -p "projects/web app" empty-folder .config
    echo "# Web app" > "projects/web app/README.md"
    echo "spaces in the name" > "file with spaces.txt"
    echo "не только ASCII" > "кириллица.txt"
    echo 'quotes, brackets and a star' > 'q"uote [1] *.txt'
    echo "hidden" > .hidden-file
    echo "setting=1" > .config/app.conf

    # Symlinks to a folder and to a file: double-click opens each correctly.
    ln -s logs link-to-logs
    ln -s etc/nginx/nginx.conf link-to-nginx.conf

    # For the error paths: a file that cannot be saved back, a folder that
    # cannot be opened.
    echo "you cannot overwrite this" > read-only.txt
    mkdir -p locked && echo secret > locked/secret.txt

    chown -R lab:lab /home/lab
    chmod 444 read-only.txt
    chmod 000 locked
    touch .lab-seeded
fi

exec /usr/sbin/sshd -D -e
