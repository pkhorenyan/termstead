#!/bin/sh
set -eu
mkdir -p /home/lab/.vnc
printf 'lab\n' | tigervncpasswd -f > /home/lab/.vnc/passwd
chmod 600 /home/lab/.vnc/passwd
cat > /home/lab/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- xfce4-session
EOF
chmod +x /home/lab/.vnc/xstartup
chown -R lab:lab /home/lab/.vnc
exec su lab -c 'tigervncserver :1 -fg -localhost no -geometry 1280x800 -depth 24 -rfbport 5900 -SecurityTypes VncAuth -PasswordFile /home/lab/.vnc/passwd -xstartup /home/lab/.vnc/xstartup'
