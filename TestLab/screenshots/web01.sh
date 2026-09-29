cd /srv/www/example.com
p='deploy@prod-web-01:/srv/www/example.com$ '
say() { printf '%s%s\n' "$p" "$1"; }
say 'uptime'
echo ' 14:32:07 up 41 days,  3:12,  2 users,  load average: 0.21, 0.18, 0.12'
say 'systemctl status nginx --no-pager -n 0'
printf '%s\n' \
'● nginx.service - A high performance web server and a reverse proxy server' \
'     Loaded: loaded (/lib/systemd/system/nginx.service; enabled; preset: enabled)' \
'     Active: active (running) since Wed 2026-08-19 11:20:31 UTC; 1 month 10 days ago' \
'   Main PID: 1123 (nginx)' \
'      Tasks: 5 (limit: 4557)' \
'     Memory: 18.4M'
say 'tail -n 4 /var/log/nginx/error.log'
printf '%s\n' \
'2026/09/29 14:02:11 [warn] 1124#1124: an upstream response is buffered to a temporary file' \
'2026/09/29 14:18:37 [error] 1125#1125: upstream timed out, client: 203.0.113.24, upstream: "http://10.0.1.20:8080/api/orders"' \
'2026/09/29 14:18:52 [error] 1125#1125: connect() failed (111: Connection refused), client: 198.51.100.7' \
'2026/09/29 14:19:05 [notice] 1123#1123: signal process started'
say 'curl -sI https://example.com | head -4'
printf '%s\n' 'HTTP/2 200' 'server: nginx' 'content-type: text/html; charset=utf-8' 'cache-control: public, max-age=3600'
say 'ls -la'
ls -la --color=always
PS1="$p" exec sh -i
