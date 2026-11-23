#!/usr/bin/env bash
# Generates every kind of site into a throwaway sandbox (no root needed, nothing
# outside the sandbox is touched) and checks the results. When nginx or Apache
# is installed, the generated configs are also checked with `nginx -t` and
# `apache2 -t` against a minimal main config inside the sandbox.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HM="$HERE/../hosting-manager.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export HM_ETC=$T/etc HM_WWW=$T/www HM_LE=$T/le HM_NGINX_LOGS=$T/logs HM_FAKE=1 HM_IPV6=${HM_IPV6:-0}
mkdir -p "$T"/etc/nginx/{sites-available,sites-enabled,conf.d} \
         "$T"/etc/apache2/{sites-available,sites-enabled,mods-enabled} "$T"/www "$T"/logs

fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
hm() { bash "$HM" "$@" >>"$T/out.log" 2>&1; }

# self-signed certificates standing in for Let's Encrypt
cert() {
  mkdir -p "$T/le/live/$1"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$1" \
    -keyout "$T/le/live/$1/privkey.pem" -out "$T/le/live/$1/fullchain.pem" 2>/dev/null
}
for d in static.test php.test proxy.test old.test new.test a-old.test a-static.test a-php.test a-proxy.test a-new.test; do cert $d; done

# nginx sites
hm create static.test --server nginx --ssl
hm create php.test --server nginx --php --php-sock /run/php/php-fpm.sock --ssl --max-body 32M
hm create proxy.test --server nginx --proxy 3000 --ssl
hm create plain.test --server nginx --no-www
hm create old.test --server nginx --ssl
hm rename old.test new.test --redirect
hm create gone.test --server nginx
hm -y remove gone.test
hm create off.test --server nginx --disabled

# Apache sites
hm create a-static.test --server apache --ssl
hm create a-php.test --server apache --php --php-sock /run/php/php-fpm.sock --ssl
hm create a-proxy.test --server apache --proxy https://127.0.0.1:8443 --ssl
hm create a-plain.test --server apache --max-body 10M
hm create a-old.test --server apache --ssl
hm rename a-old.test a-new.test

n=$T/etc/nginx; a=$T/etc/apache2
check "nginx static site enabled"        "[[ -L $n/sites-enabled/static.test.conf ]]"
check "www alias added for apex domain"  "grep -q 'server_name static.test www.static.test;' $n/sites-available/static.test.conf"
check "--no-www respected"               "grep -q 'server_name plain.test;' $n/sites-available/plain.test.conf"
check "https redirect on port 80"        "grep -q 'return 301 https://\$host' $n/sites-available/static.test.conf"
check "php-fpm socket used"              "grep -q 'fastcgi_pass unix:/run/php/php-fpm.sock;' $n/sites-available/php.test.conf"
check "upload limit"                     "grep -q 'client_max_body_size 32M;' $n/sites-available/php.test.conf"
check "proxy port expanded"              "grep -q 'proxy_pass http://127.0.0.1:3000;' $n/sites-available/proxy.test.conf"
check "websocket map written"            "[[ -f $n/conf.d/hosting-manager.conf ]]"
check "rename: new site served"          "grep -q 'server_name new.test www.new.test;' $n/sites-available/new.test.conf"
check "rename: old name redirects"       "grep -q 'return 301 https://new.test\$request_uri;' $n/sites-available/old.test.conf"
check "remove: config gone"              "[[ ! -e $n/sites-available/gone.test.conf && ! -e $n/sites-enabled/gone.test.conf ]]"
check "--disabled: not enabled"          "[[ -f $n/sites-available/off.test.conf && ! -e $n/sites-enabled/off.test.conf ]]"
check "apache site enabled"              "[[ -L $a/sites-enabled/a-static.test.conf ]]"
check "apache php handler"               "grep -q 'proxy:unix:/run/php/php-fpm.sock|fcgi://localhost' $a/sites-available/a-php.test.conf"
check "apache https upstream"            "grep -q 'SSLProxyEngine on' $a/sites-available/a-proxy.test.conf"
check "apache upload limit"              "grep -q 'LimitRequestBody 10485760' $a/sites-available/a-plain.test.conf"
check "apache rename without redirect"   "[[ ! -e $a/sites-available/a-old.test.conf && -f $a/sites-available/a-new.test.conf ]]"
check "list shows 12 sites"              "[[ \$(bash $HM list | grep -c '\.test ') -eq 12 ]]"

NGINX=$(command -v nginx || ls /usr/sbin/nginx 2>/dev/null || true)
if [[ -n $NGINX ]]; then
  cp /etc/nginx/fastcgi_params "$n/" 2>/dev/null || touch "$n/fastcgi_params"
  # copy the enabled sites with unprivileged ports, so the test runs without root
  mkdir -p "$n/test-sites"
  for f in "$n"/sites-enabled/*; do
    sed -E 's/listen (\[::\]:)?80;/listen \118080;/; s/listen (\[::\]:)?443 ssl;/listen \118443 ssl;/' "$f" > "$n/test-sites/$(basename "$f")"
  done
  cat > "$n/nginx.conf" <<CONF
pid $T/nginx.pid;
error_log $T/logs/error.log;
events {}
http {
    access_log $T/logs/access.log;
    include $n/conf.d/*.conf;
    include $n/test-sites/*;
}
CONF
  check "nginx -t accepts the configs" "'$NGINX' -t -q -p '$T' -c '$n/nginx.conf' -e '$T/logs/error.log' 2>'$T/nginx-t.log' || { cat '$T/nginx-t.log'; false; }"
else
  echo "skip nginx -t (nginx not installed)"
fi

APACHE=$(command -v apache2 || ls /usr/sbin/apache2 2>/dev/null || command -v httpd || true)
MODS=/usr/lib/apache2/modules
[[ -d $MODS ]] || MODS=/usr/lib64/httpd/modules
if [[ -n $APACHE && -d $MODS ]]; then
  {
    echo "ServerRoot $T"
    echo "Define APACHE_LOG_DIR $T/logs"
    echo "PidFile $T/apache.pid"
    echo "ErrorLog $T/logs/apache-error.log"
    echo "Listen 127.0.0.1:18080"
    echo "Listen 127.0.0.1:18443"
    echo 'LogFormat "%h %l %u %t \"%r\" %>s %O" combined'
    for m in mpm_event authz_core alias dir rewrite ssl headers proxy proxy_http proxy_fcgi setenvif log_config; do
      [[ -f $MODS/mod_$m.so ]] && echo "LoadModule ${m}_module $MODS/mod_$m.so"
    done
    echo "Include $a/sites-enabled/*.conf"
  } > "$a/apache2.conf"
  check "apache2 -t accepts the configs" "'$APACHE' -t -f '$a/apache2.conf' >'$T/apache-t.log' 2>&1 || { cat '$T/apache-t.log'; false; }"
else
  echo "skip apache -t (Apache not installed)"
fi

if (( fail )); then echo; echo "--- hosting-manager output ---"; cat "$T/out.log"; exit 1; fi
echo "all tests passed"
