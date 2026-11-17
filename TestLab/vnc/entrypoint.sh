#!/bin/sh
set -eu
mkdir -p /run/sshd /home/lab/.ssh
chmod 700 /home/lab/.ssh
install -m 600 /lab/hostkey /etc/ssh/ssh_host_ed25519_key
install -m 600 -o lab -g lab /lab/authorized_keys /home/lab/.ssh/authorized_keys
chown lab:lab /home/lab/.ssh
/usr/sbin/sshd
mkdir -p /home/lab/.vnc
printf 'lab\n' | tigervncpasswd -f > /home/lab/.vnc/passwd
chmod 600 /home/lab/.vnc/passwd
if [ ! -f /home/lab/.vnc/server.pem ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
        -subj /CN=termstead-vnc-lab -addext 'subjectAltName=DNS:localhost,DNS:vnc,IP:127.0.0.1' \
        -keyout /home/lab/.vnc/server.key -out /home/lab/.vnc/server.pem
    chmod 600 /home/lab/.vnc/server.key
fi
cat > /home/lab/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- xfce4-session
EOF
chmod +x /home/lab/.vnc/xstartup
chown -R lab:lab /home/lab/.vnc
exec su lab -c 'tigervncserver :1 -fg -localhost no -geometry 1280x800 -depth 24 -rfbport 5900 -SecurityTypes VncAuth,X509Vnc -X509Cert /home/lab/.vnc/server.pem -X509Key /home/lab/.vnc/server.key -PasswordFile /home/lab/.vnc/passwd -xstartup /home/lab/.vnc/xstartup'
