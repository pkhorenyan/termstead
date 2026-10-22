# The RDP shot's desktop, in the lab's xrdp container: a user of its own,
# so the lab and lab2 sessions the tests use stay as they are. Xfce at 2x,
# as a Retina tab draws it, and the default panel — without one, the first
# start asks which panel to use.
id dev >/dev/null 2>&1 && exit 0
set -e
useradd -m -s /bin/bash dev
echo dev:dev | chpasswd
echo xfce4-session > /home/dev/.xsession
conf=/home/dev/.config/xfce4/xfconf/xfce-perchannel-xml
mkdir -p $conf
cat > $conf/xsettings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Gdk" type="empty">
    <property name="WindowScalingFactor" type="int" value="2"/>
  </property>
</channel>
EOF
cp /etc/xdg/xfce4/panel/default.xml $conf/xfce4-panel.xml
cd /home/dev
mkdir -p Projects/api-gateway/src Projects/billing-service/src Projects/web-dashboard/src \
    Projects/infra/terraform Documents Downloads
for p in api-gateway billing-service web-dashboard; do printf '# %s\n' $p > Projects/$p/README.md; done
printf 'version: "3.9"\n' > Projects/docker-compose.yml
chown -R dev:dev /home/dev
