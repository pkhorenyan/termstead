# The panes shot: the same commands, typed once with broadcast input on, as
# they read on each server. $1 names the server, after its own demo script.
cd
case "$1" in
web01) p='deploy@prod-web-01:~$ '; os=debian; n=3
       up=' 14:32:07 up 41 days,  3:12,  2 users,  load average: 0.21, 0.18, 0.12' ;;
web02) p='deploy@prod-web-02:~$ '; os=debian; n=3
       up=' 14:32:07 up 27 days,  6:41,  1 user,  load average: 0.34, 0.29, 0.22' ;;
db)    p='postgres@db-primary:~$ '; os=debian; n=2
       up=' 14:32:07 up 63 days, 22:05,  1 user,  load average: 1.12, 0.97, 0.88' ;;
*)     p='ubuntu@staging-app:~$ '; os=ubuntu; n=6
       up=' 14:32:07 up 2 days,  1:47,  1 user,  load average: 0.02, 0.04, 0.01' ;;
esac
say() { printf '%s%s\n' "$p" "$1"; }
say 'uptime'
echo "$up"
say 'sudo apt update'
if [ "$os" = debian ]; then
    printf '%s\n' \
    'Hit:1 http://deb.debian.org/debian bookworm InRelease' \
    'Get:2 http://deb.debian.org/debian bookworm-updates InRelease [55.4 kB]' \
    'Hit:3 http://deb.debian.org/debian-security bookworm-security InRelease' \
    'Fetched 55.4 kB in 1s (79.1 kB/s)'
else
    printf '%s\n' \
    'Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease' \
    'Get:2 http://archive.ubuntu.com/ubuntu noble-updates InRelease [126 kB]' \
    'Hit:3 http://security.ubuntu.com/ubuntu noble-security InRelease' \
    'Fetched 126 kB in 1s (183 kB/s)'
fi
printf '%s\n' 'Reading package lists... Done' 'Building dependency tree... Done' \
    'Reading state information... Done' \
    "$n packages can be upgraded. Run 'apt list --upgradable' to see them."
PS1="$p" exec sh -i
