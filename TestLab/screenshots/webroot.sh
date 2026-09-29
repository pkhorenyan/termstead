set -e
id deploy >/dev/null 2>&1 || adduser -D -H -u 1001 deploy
r=/srv/www/example.com
mkdir -p $r/assets/css $r/assets/js $r/images $r/fonts
head -c 7412 /dev/urandom > $r/index.html
head -c 3120 /dev/urandom > $r/404.html
printf 'User-agent: *\nAllow: /\nSitemap: https://example.com/sitemap.xml\n' > $r/robots.txt
head -c 15086 /dev/urandom > $r/favicon.ico
head -c 486 /dev/urandom > $r/manifest.json
head -c 2214 /dev/urandom > $r/sitemap.xml
head -c 48211 /dev/urandom > $r/assets/css/app.css
head -c 181377 /dev/urandom > $r/assets/js/app.js
chown -R deploy:deploy /srv/www
chmod -R a+rX /srv/www
