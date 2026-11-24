#!/usr/bin/env bash
# hosting-manager: create and manage nginx/Apache sites, Let's Encrypt certificates
# and domain changes on a Linux web server.
#
# https://github.com/nano-rex/hosting-manager  (GPL-3.0)

set -Eeuo pipefail

VERSION="0.5.0"
PROG="hosting-manager"

# ---------------------------------------------------------------------------
# Paths (each can be overridden from the environment, mainly for testing)
# ---------------------------------------------------------------------------
ETC="${HM_ETC:-/etc}"
WWW="${HM_WWW:-/var/www}"
STATE_DIR="${HM_STATE:-$ETC/hosting-manager}"
LE_DIR="${HM_LE:-/etc/letsencrypt}"
ACME_ROOT="${HM_ACME:-$WWW/_letsencrypt}"
NGINX_LOGS="${HM_NGINX_LOGS:-/var/log/nginx}"
FAKE="${HM_FAKE:-0}"          # 1 = write files but only print system commands

SITES_DIR="$STATE_DIR/sites"
BACKUP_DIR="$STATE_DIR/backups"
CONFIG_FILE="$STATE_DIR/hosting-manager.conf"

# Defaults, overridable in $CONFIG_FILE
DEFAULT_SERVER=""
EMAIL=""
DRY_RUN=0
DNS_SERVER="${HM_DNS_SERVER:-}"
ASSUME_YES=0
BATCH=0            # 1 = callers test and reload once after many apply_site calls

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLD=""; C_DIM=""; C_RST=""
fi
info() { printf '%s==>%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# Run a system command (printed instead of run in --dry-run or HM_FAKE mode).
run() {
  if (( DRY_RUN )) || [[ $FAKE == 1 ]]; then
    printf '%s+ %s%s\n' "$C_DIM" "$*" "$C_RST"
    return 0
  fi
  "$@"
}

confirm() {
  (( ASSUME_YES )) && return 0
  local reply
  read -r -p "$1 [y/N] " reply || return 1
  [[ $reply =~ ^[Yy] ]]
}

need_root() {
  (( DRY_RUN )) && return 0
  [[ -n ${HM_ETC:-} ]] && return 0
  [[ $EUID -eq 0 ]] || die "this command needs root (try: sudo $PROG $*)"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Write $2 to file $1, backing up any existing file first.
write_file() {
  local path=$1 content=$2
  if (( DRY_RUN )); then
    printf '%s--- would write %s ---%s\n%s\n' "$C_DIM" "$path" "$C_RST" "$content"
    return 0
  fi
  backup_file "$path"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

backup_file() {
  local path=$1
  [[ -f $path ]] || return 0
  local dest="$BACKUP_DIR/$STAMP${path}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$path" "$dest"
}

remove_file() {
  local path=$1
  [[ -e $path || -L $path ]] || return 0
  if (( DRY_RUN )); then echo "${C_DIM}+ rm $path${C_RST}"; return 0; fi
  [[ -L $path ]] || backup_file "$path"
  rm -f "$path"
}

STAMP="$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
valid_domain() {
  local d=${1,,}
  [[ ${#d} -le 253 ]] || return 1
  [[ $d =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]
}

check_domain() { valid_domain "$1" || die "not a valid domain name: $1"; }

# apex domain = exactly one dot (example.com); used for the automatic www alias
is_apex() { [[ $1 =~ ^[^.]+\.[^.]+$ ]]; }

# ---------------------------------------------------------------------------
# Server detection
# ---------------------------------------------------------------------------
nginx_layout() {
  if [[ -d $ETC/nginx/sites-available ]]; then echo debian
  elif [[ -n $(nginx_confd) ]]; then echo confd
  else echo none; fi
}

# nginx's drop-in folder: conf.d on most systems, http.d on Alpine
nginx_confd() {
  local d
  for d in conf.d http.d; do [[ -d $ETC/nginx/$d ]] && { echo "$ETC/nginx/$d"; return; }; done
  [[ -d $ETC/nginx ]] && echo "$ETC/nginx/conf.d"
  return 0
}

apache_layout() {
  if [[ -d $ETC/apache2/sites-available ]]; then echo debian
  elif [[ -n $(apache_confd) ]]; then echo confd
  else echo none; fi
}

# Apache's main folder and drop-in folder on conf.d-style systems:
# /etc/httpd (Fedora/RHEL/Arch), /etc/apache2 (Alpine, Gentoo's vhosts.d), /etc/apache (Void)
apache_confd() {
  local d
  for d in httpd/conf.d apache2/conf.d apache2/vhosts.d apache/conf.d; do
    [[ -d $ETC/$d ]] && { echo "$ETC/$d"; return; }
  done
  # no drop-in folder yet (Arch, Void): use one next to the main config
  [[ -f $ETC/httpd/conf/httpd.conf ]] && { echo "$ETC/httpd/conf.d"; return; }
  [[ -f $ETC/apache/httpd.conf ]] && { echo "$ETC/apache/conf.d"; return; }
  return 0
}

apache_main_conf() {
  local f
  for f in httpd/conf/httpd.conf apache2/httpd.conf apache/httpd.conf; do
    [[ -f $ETC/$f ]] && { echo "$ETC/$f"; return; }
  done
  return 0
}

# ensure_include SERVER: on conf.d-style systems, make sure the main config
# reads the drop-in folder (stock configs on Void and Arch don't), creating
# the folder and adding the include line once.
ensure_include() {
  (( DRY_RUN )) && return 0
  local dir main base
  if [[ $1 == nginx ]]; then
    [[ $(nginx_layout) == confd ]] || return 0
    dir=$(nginx_confd); main=$ETC/nginx/nginx.conf
  else
    [[ $(apache_layout) == confd ]] || return 0
    dir=$(apache_confd); main=$(apache_main_conf)
  fi
  [[ -n $dir && -f $main ]] || return 0
  mkdir -p "$dir"
  base=${dir##*/}
  if [[ $1 == nginx ]]; then
    grep -qE "^[[:space:]]*include[[:space:]]+[^;#]*$base/\*" "$main" && return 0
    grep -qE '^[[:space:]]*http[[:space:]]*\{' "$main" || { warn "$main has no http { } block; include $dir/*.conf yourself"; return 0; }
    backup_file "$main"
    HM_INC="    include $dir/*.conf;   # added by hosting-manager" perl -0pi -e 's{^([ \t]*http[ \t]*\{[^\n]*\n)}{$1$ENV{HM_INC}\n}m' "$main"
  else
    grep -qiE "^[[:space:]]*Include(Optional)?[[:space:]]+\"?[^#]*$base/" "$main" && return 0
    backup_file "$main"
    printf '\n# added by hosting-manager\nIncludeOptional %s/*.conf\n' "$dir" >> "$main"
  fi
  info "$main now reads $dir/*.conf"
}

apache_service() {
  if [[ $(apache_layout) == debian ]]; then echo apache2; return; fi
  case $(apache_confd) in
    "$ETC"/httpd/*) echo httpd ;;
    "$ETC"/apache/*) echo apache ;;
    *) echo apache2 ;;
  esac
}

server_service() {
  case $1 in
    nginx) echo nginx ;;
    apache) apache_service ;;
  esac
}

server_installed() {
  case $1 in
    nginx) [[ $(nginx_layout) != none ]] ;;
    apache) [[ $(apache_layout) != none ]] ;;
  esac
}

pick_server() {
  local s=${1:-$DEFAULT_SERVER}
  if [[ -n $s ]]; then
    [[ $s == apache2 || $s == httpd ]] && s=apache
    [[ $s == nginx || $s == apache ]] || die "unknown server '$s' (use nginx or apache)"
    server_installed "$s" || die "$s does not seem to be installed (try: $PROG install $s)"
    echo "$s"; return
  fi
  local n=0 a=0
  server_installed nginx && n=1
  server_installed apache && a=1
  if (( n && !a )); then echo nginx
  elif (( a && !n )); then echo apache
  elif (( n && a )); then die "both nginx and Apache are installed; choose one with --server nginx|apache"
  else die "no web server found (try: $PROG install nginx)"; fi
}

# Path of the site's config file (the "available" copy on Debian layouts).
conf_path() {
  local server=$1 domain=$2
  case $server in
    nginx)
      if [[ $(nginx_layout) == debian ]]; then echo "$ETC/nginx/sites-available/$domain.conf"
      else echo "$(nginx_confd)/$domain.conf"; fi ;;
    apache)
      if [[ $(apache_layout) == debian ]]; then echo "$ETC/apache2/sites-available/$domain.conf"
      else echo "$(apache_confd)/$domain.conf"; fi ;;
  esac
}

# The default site (answers names no site claims) is loaded first: 000-<domain>.conf
enabled_link() {
  local server=$1 domain=$2 pre=""
  [[ ${3:-${DEFAULT_SITE:-0}} == 1 ]] && pre="000-"
  case $server in
    nginx) echo "$ETC/nginx/sites-enabled/$pre$domain.conf" ;;
    apache) echo "$ETC/apache2/sites-enabled/$pre$domain.conf" ;;
  esac
}

server_layout() { if [[ $1 == nginx ]]; then nginx_layout; else apache_layout; fi; }

# Newest php-fpm socket on this machine, if any.
find_php_sock() {
  local s
  for s in $(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V -r) /run/php-fpm/www.sock /var/run/php-fpm/www.sock /run/php-fpm/php-fpm.sock; do
    [[ -S $s ]] && { echo "$s"; return; }
  done
  return 0
}

web_user() {
  local u
  for u in www-data nginx apache http; do
    id "$u" >/dev/null 2>&1 && { echo "$u"; return; }
  done
  echo root
}

nginx_has_http2_directive() {
  have nginx || return 1
  local v
  v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
  [[ -n $v ]] || return 1
  [[ $(printf '%s\n%s\n' "1.25.1" "$v" | sort -V | head -1) == "1.25.1" ]]
}

# ---------------------------------------------------------------------------
# Site state (one shell-quoted key=value file per site)
# ---------------------------------------------------------------------------
STATE_KEYS=(DOMAIN SERVER TYPE ROOT TARGET PHP_SOCK ALIASES SSL ENABLED MAX_BODY CREATED
            HTTP_ADDR HTTPS_ADDR CERT_FILE CERT_KEY DEFAULT_SITE)

# TYPE=custom (sites taken over with 'adopt') keeps the original directives of
# each <VirtualHost> in BODY_HTTP / BODY_HTTPS, stored next to the state file.
reset_site() {
  DOMAIN=""; SERVER=""; TYPE="static"; ROOT=""; TARGET=""; PHP_SOCK=""
  ALIASES=""; SSL=0; ENABLED=1; MAX_BODY=""; CREATED=""
  HTTP_ADDR=""; HTTPS_ADDR=""; CERT_FILE=""; CERT_KEY=""; DEFAULT_SITE=0
  BODY_HTTP=""; BODY_HTTPS=""
}

site_file() { echo "$SITES_DIR/$1.site"; }

site_exists() { [[ -f $(site_file "$1") ]]; }

load_site() {
  local domain=$1 f
  f=$(site_file "$domain")
  [[ -f $f ]] || die "no managed site named $domain (see: $PROG list)"
  reset_site
  # shellcheck disable=SC1090
  source "$f"
  if [[ $TYPE == custom ]]; then
    [[ -f $SITES_DIR/$domain.http ]] && BODY_HTTP=$(<"$SITES_DIR/$domain.http")
    [[ -f $SITES_DIR/$domain.https ]] && BODY_HTTPS=$(<"$SITES_DIR/$domain.https")
  fi
  return 0
}

save_site() {
  local out="" k
  for k in "${STATE_KEYS[@]}"; do
    out+=$(printf '%s=%q' "$k" "${!k}")$'\n'
  done
  write_file "$(site_file "$DOMAIN")" "# $PROG site state; change it with $PROG, not by hand
${out%$'\n'}"
  if [[ $TYPE == custom ]]; then
    if [[ -n $BODY_HTTP ]]; then write_file "$SITES_DIR/$DOMAIN.http" "$BODY_HTTP"; else remove_file "$SITES_DIR/$DOMAIN.http"; fi
    if [[ -n $BODY_HTTPS ]]; then write_file "$SITES_DIR/$DOMAIN.https" "$BODY_HTTPS"; else remove_file "$SITES_DIR/$DOMAIN.https"; fi
    chmod_private "$SITES_DIR/$DOMAIN.http" "$SITES_DIR/$DOMAIN.https"
  else
    remove_file "$SITES_DIR/$DOMAIN.http"; remove_file "$SITES_DIR/$DOMAIN.https"
  fi
}

# Site records can hold paths and upstream addresses: readable by root only.
chmod_private() {
  (( DRY_RUN )) && return 0
  local f
  for f in "$@"; do [[ -f $f ]] && chmod 600 "$f"; done
  return 0
}

delete_site_record() {
  remove_file "$(site_file "$1")"
  remove_file "$SITES_DIR/$1.http"
  remove_file "$SITES_DIR/$1.https"
}

all_sites() {
  local f
  shopt -s nullglob
  for f in "$SITES_DIR"/*.site; do
    basename "$f" .site
  done
  shopt -u nullglob
}

server_names() { echo "$DOMAIN${ALIASES:+ $ALIASES}"; }

cert_exists() { [[ -f $LE_DIR/live/$1/fullchain.pem ]]; }

cert_file() { echo "${CERT_FILE:-$LE_DIR/live/$DOMAIN/fullchain.pem}"; }
cert_key()  { echo "${CERT_KEY:-$LE_DIR/live/$DOMAIN/privkey.pem}"; }
http_addr()  { echo "${HTTP_ADDR:-*:80}"; }
https_addr() { echo "${HTTPS_ADDR:-*:443}"; }

# ---------------------------------------------------------------------------
# Config rendering
# ---------------------------------------------------------------------------
HEADER="# Managed by $PROG. Manual edits are overwritten the next time this site
# is changed with $PROG; use '$PROG update' instead."

render_nginx_body() {
  local body=""
  [[ -n $MAX_BODY ]] && body+="    client_max_body_size $MAX_BODY;"$'\n'
  case $TYPE in
    static)
      body+="    root $ROOT;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }" ;;
    php)
      body+="    root $ROOT;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        try_files \$fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:$PHP_SOCK;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }" ;;
    proxy)
      body+="    location / {
        proxy_pass $TARGET;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$hm_connection_upgrade;
        proxy_read_timeout 300s;
    }" ;;
    redirect)
      body+="    location / {
        return 301 $TARGET\$request_uri;
    }" ;;
  esac
  printf '%s' "$body"
}

# "listen [::]:80" fails to start nginx on hosts with IPv6 disabled.
has_ipv6() { [[ ${HM_IPV6:-} == 1 ]] || { [[ ${HM_IPV6:-} != 0 ]] && [[ -f /proc/net/if_inet6 ]]; }; }

listen_lines() {
  local port=$1 extra=${2:-}
  printf '    listen %s%s;' "$port" "$extra"
  if has_ipv6; then printf '\n    listen [::]:%s%s;' "$port" "$extra"; fi
}

render_nginx() {
  local names logs acme body l80 l443
  names=$(server_names)
  l80=$(listen_lines 80)
  l443=$(listen_lines 443 " ssl")
  logs="    access_log $NGINX_LOGS/$DOMAIN.access.log;
    error_log $NGINX_LOGS/$DOMAIN.error.log;"
  acme="    location ^~ /.well-known/acme-challenge/ {
        root $ACME_ROOT;
        default_type \"text/plain\";
    }"
  body=$(render_nginx_body)

  if (( SSL )); then
    local http2=""
    nginx_has_http2_directive && http2=$'\n    http2 on;'
    cat <<EOF
$HEADER

server {
$l80
    server_name $names;

$acme

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
$l443$http2
    server_name $names;

    ssl_certificate $(cert_file);
    ssl_certificate_key $(cert_key);
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:hm_ssl:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=31536000" always;

$logs

$body
}
EOF
  else
    cat <<EOF
$HEADER

server {
$l80
    server_name $names;

$logs

$acme

$body
}
EOF
  fi
}

# nginx needs a map at http{} level for websocket upgrades in proxy sites.
ensure_nginx_globals() {
  local f; f="$(nginx_confd)/hosting-manager.conf"
  [[ -f $f ]] && return 0
  write_file "$f" "# Created by $PROG; shared by its proxy sites.
map \$http_upgrade \$hm_connection_upgrade {
    default upgrade;
    ''      close;
}"
}

render_apache_body() {
  local scheme=$1 body=""
  case $TYPE in
    static|php)
      body+="    DocumentRoot $ROOT
    <Directory $ROOT>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>"
      if [[ $TYPE == php ]]; then
        body+="
    DirectoryIndex index.php index.html"
        [[ -n $PHP_SOCK ]] && body+="
    <FilesMatch \"\\.php\$\">
        SetHandler \"proxy:unix:$PHP_SOCK|fcgi://localhost\"
    </FilesMatch>"
      fi ;;
    proxy)
      body+="    ProxyPreserveHost On$( [[ $TARGET == https://* ]] && printf '\n    SSLProxyEngine on' )
    ProxyPass /.well-known/acme-challenge/ !
    ProxyPass / ${TARGET%/}/
    ProxyPassReverse / ${TARGET%/}/
    RequestHeader set X-Forwarded-Proto \"$scheme\"
    ProxyTimeout 300" ;;
    redirect)
      body+="    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/
    RewriteRule ^ ${TARGET%/}%{REQUEST_URI} [L,R=301]" ;;
  esac
  [[ -n $MAX_BODY ]] && body+=$'\n'"    LimitRequestBody $(size_to_bytes "$MAX_BODY")"
  printf '%s' "$body"
}

size_to_bytes() {
  local s=${1^^} n
  n=${s%[KMG]}
  case $s in
    *K) echo $(( n * 1024 )) ;;
    *M) echo $(( n * 1024 * 1024 )) ;;
    *G) echo $(( n * 1024 * 1024 * 1024 )) ;;
    *) echo "$n" ;;
  esac
}

# A site taken over with 'adopt': its own directives, plus the names, the
# certificate and the Let's Encrypt validation path managed here.
render_apache_custom() {
  local names acme excl="" alias_line=""
  [[ -n $ALIASES ]] && alias_line=$'\n'"    ServerAlias $ALIASES"
  names="    ServerName $DOMAIN$alias_line"
  acme_block() {
    local body=$1 out=""
    grep -qiE '^\s*ProxyPass(Match)?\s' <<<"$body" && out+="    ProxyPass /.well-known/acme-challenge/ !"$'\n'
    out+="    Alias /.well-known/acme-challenge/ $ACME_ROOT/.well-known/acme-challenge/
    <Directory $ACME_ROOT>
        Require all granted
    </Directory>"
    printf '%s' "$out"
  }
  echo "$HEADER"
  if [[ -n $BODY_HTTP ]]; then
    cat <<EOF

<VirtualHost $(http_addr)>
$names
$(acme_block "$BODY_HTTP")
$BODY_HTTP
</VirtualHost>
EOF
  fi
  if (( SSL )); then
    local body=${BODY_HTTPS:-$BODY_HTTP} engine=""
    grep -qiE '^\s*(SSLEngine\s+on|Include\s+\S*options-ssl-apache\.conf)' <<<"$body" || engine=$'\n'"    SSLEngine on"
    cat <<EOF

<IfModule mod_ssl.c>
<VirtualHost $(https_addr)>
$names
$(acme_block "$body")
$body$engine
    SSLCertificateFile $(cert_file)
    SSLCertificateKeyFile $(cert_key)
</VirtualHost>
</IfModule>
EOF
  fi
}

render_apache() {
  [[ $TYPE == custom ]] && { render_apache_custom; return; }
  local logdir alias_line="" acme
  if [[ $(apache_layout) == confd ]]; then logdir="logs"; else logdir='${APACHE_LOG_DIR}'; fi
  [[ -n $ALIASES ]] && alias_line="    ServerAlias $ALIASES"
  acme="    Alias /.well-known/acme-challenge/ $ACME_ROOT/.well-known/acme-challenge/
    <Directory $ACME_ROOT>
        Require all granted
    </Directory>"

  local names="    ServerName $DOMAIN${alias_line:+$'\n'$alias_line}"
  local logs="    ErrorLog $logdir/$DOMAIN-error.log
    CustomLog $logdir/$DOMAIN-access.log combined"

  if (( SSL )); then
    cat <<EOF
$HEADER

<VirtualHost $(http_addr)>
$names
$acme
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
</VirtualHost>

<IfModule mod_ssl.c>
<VirtualHost $(https_addr)>
$names
    SSLEngine on
    SSLCertificateFile $(cert_file)
    SSLCertificateKeyFile $(cert_key)
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    Header always set Strict-Transport-Security "max-age=31536000"
$logs
$acme
$(render_apache_body https)
</VirtualHost>
</IfModule>
EOF
  else
    cat <<EOF
$HEADER

<VirtualHost $(http_addr)>
$names
$logs
$acme
$(render_apache_body http)
</VirtualHost>
EOF
  fi
}

# Apache modules the site needs (Debian layout enables them with a2enmod).
apache_modules() {
  local mods=(alias)
  [[ $TYPE == custom ]] || mods+=(rewrite)
  (( SSL )) && mods+=(ssl)
  (( SSL )) && [[ $TYPE != custom ]] && mods+=(headers)
  case $TYPE in
    proxy) mods+=(proxy proxy_http headers) ;;
    php) [[ -n $PHP_SOCK ]] && mods+=(proxy proxy_fcgi setenvif) ;;
  esac
  printf '%s\n' "${mods[@]}" | sort -u
}

# ---------------------------------------------------------------------------
# Applying a site to the web server
# ---------------------------------------------------------------------------
config_test() {
  local server=$1
  if (( DRY_RUN )) || [[ $FAKE == 1 ]]; then
    run "$server-config-test"
    return 0
  fi
  case $server in
    nginx) nginx -t 2>&1 ;;
    apache)
      if have apachectl; then apachectl configtest 2>&1
      elif have apache2ctl; then apache2ctl configtest 2>&1
      else httpd -t 2>&1; fi ;;
  esac
}

# ---------------------------------------------------------------------------
# Init systems: systemd, OpenRC, runit, s6 (plain or s6-rc), dinit, SysV init.
# Everything that starts, stops or rewrites a service goes through svc_*.
# ---------------------------------------------------------------------------
INIT_SYSTEM="${HM_INIT:-}"

init_system() {
  if [[ -z $INIT_SYSTEM ]]; then
    local pid1=""; pid1=$(cat /proc/1/comm 2>/dev/null || true)
    case $pid1 in
      systemd) INIT_SYSTEM=systemd ;;
      runit|runit-init) INIT_SYSTEM=runit ;;
      s6-svscan|s6-linux-init*) INIT_SYSTEM=s6 ;;
      dinit) INIT_SYSTEM=dinit ;;
      openrc-init) INIT_SYSTEM=openrc ;;
      *)
        if [[ -d /run/systemd/system ]] && have systemctl; then INIT_SYSTEM=systemd
        elif have rc-service && [[ -d /run/openrc ]]; then INIT_SYSTEM=openrc
        elif have sv && [[ -n $(runit_dir) ]] && pgrep -x runsvdir >/dev/null 2>&1; then INIT_SYSTEM=runit
        elif have s6-svc && [[ -n $(s6_scandir) ]]; then INIT_SYSTEM=s6
        elif have dinitctl && pgrep -x dinit >/dev/null 2>&1; then INIT_SYSTEM=dinit
        elif [[ -d /etc/init.d ]]; then INIT_SYSTEM=sysv
        else INIT_SYSTEM=none; fi ;;
    esac
  fi
  echo "$INIT_SYSTEM"
}

# runit's folder of running services: Void /var/service, Artix /run/runit/service,
# Debian/Devuan /etc/service
runit_dir() {
  local d
  for d in ${HM_RUNIT_DIR:-} /run/runit/service /var/service /etc/service /service; do
    [[ -d $d ]] && { echo "$d"; return; }
  done
  return 0
}
# where runit service definitions live (linked into runit_dir to enable them)
runit_sources() { local d; for d in "$ETC/sv" "$ETC/runit/sv"; do [[ -d $d ]] && echo "$d"; done; return 0; }

# s6's scan directory (s6-linux-init and s6-overlay v3: /run/service)
s6_scandir() {
  local d
  for d in ${HM_S6_SCANDIR:-} /run/service /var/run/s6/services /service; do
    [[ -d $d ]] && { echo "$d"; return; }
  done
  return 0
}
s6_sources() {
  local d
  for d in "$ETC/s6/sv" "$ETC/s6-rc/source" "$ETC/s6-overlay/s6-rc.d" "$ETC/services.d"; do [[ -d $d ]] && echo "$d"; done
  return 0
}

# svc_names: every service this init system knows about
svc_names() {
  local d f
  case $(init_system) in
    systemd) systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{sub(/\.service$/, "", $1); print $1}' ;;
    openrc|sysv) for f in "$ETC"/init.d/*; do [[ -f $f && -x $f ]] && echo "${f##*/}"; done ;;
    runit) for d in $(runit_sources) "$(runit_dir)"; do for f in "$d"/*/; do [[ -d $f ]] && basename "$f"; done; done ;;
    s6) for d in $(s6_sources) "$(s6_scandir)"; do for f in "$d"/*/; do [[ -d $f ]] && basename "$f"; done; done ;;
    dinit) for f in "$ETC"/dinit.d/*; do [[ -f $f ]] && echo "${f##*/}"; done ;;
  esac 2>/dev/null | sort -u
  return 0
}

svc_active() {
  local n=$1
  [[ $FAKE == 1 ]] && return 0
  case $(init_system) in
    systemd) systemctl is-active --quiet "$n" ;;
    openrc) rc-service "$n" status >/dev/null 2>&1 ;;
    runit) sv status "$(runit_dir)/$n" 2>/dev/null | grep -q '^run:' ;;
    s6) [[ $(s6-svstat -o up "$(s6_scandir)/$n" 2>/dev/null) == true ]] ;;
    dinit) dinitctl status "$n" 2>/dev/null | grep -qi 'state: *started' ;;
    sysv) if have service; then service "$n" status >/dev/null 2>&1; else "$ETC/init.d/$n" status >/dev/null 2>&1; fi ;;
    *) return 1 ;;
  esac
}

svc_restart() {
  local n=$1
  case $(init_system) in
    systemd) run systemctl restart "$n" ;;
    openrc) run rc-service "$n" restart ;;
    runit) run sv restart "$(runit_dir)/$n" ;;
    s6) run s6-svc -r "$(s6_scandir)/$n" ;;
    dinit) run dinitctl restart "$n" ;;
    sysv) if have service; then run service "$n" restart; else run "$ETC/init.d/$n" restart; fi ;;
    *) die "no init system found to restart $n; restart it yourself" ;;
  esac
}

# svc_reload NAME SIGNAL: reload a daemon's configuration. Supervisors that
# can't "reload" (runit, s6, dinit) get SIGNAL instead: HUP for nginx, USR1
# (graceful restart) for Apache.
svc_reload() {
  local n=$1 sig=${2:-HUP}
  case $(init_system) in
    systemd) run systemctl reload "$n" || run systemctl restart "$n" ;;
    openrc) run rc-service "$n" reload || run rc-service "$n" restart ;;
    runit) if [[ $sig == USR1 ]]; then run sv 1 "$(runit_dir)/$n"; else run sv hup "$(runit_dir)/$n"; fi ;;
    s6) if [[ $sig == USR1 ]]; then run s6-svc -1 "$(s6_scandir)/$n"; else run s6-svc -h "$(s6_scandir)/$n"; fi ;;
    dinit) run dinitctl signal "$sig" "$n" 2>/dev/null || run dinitctl restart "$n" ;;
    sysv) if have service; then run service "$n" reload || run service "$n" restart
          else run "$ETC/init.d/$n" reload || run "$ETC/init.d/$n" restart; fi ;;
    *) die "no init system found to reload $n; reload it yourself" ;;
  esac
}

# The same reload as a command line, for certbot's --deploy-hook.
svc_reload_cmd() {
  local n=$1 sig=${2:-HUP}
  case $(init_system) in
    systemd) echo "systemctl reload $n" ;;
    openrc) echo "rc-service $n reload" ;;
    runit) [[ $sig == USR1 ]] && echo "sv 1 $(runit_dir)/$n" || echo "sv hup $(runit_dir)/$n" ;;
    s6) [[ $sig == USR1 ]] && echo "s6-svc -1 $(s6_scandir)/$n" || echo "s6-svc -h $(s6_scandir)/$n" ;;
    dinit) echo "dinitctl signal $sig $n" ;;
    *) if have service; then echo "service $n reload"; else echo "$ETC/init.d/$n reload"; fi ;;
  esac
}

# svc_enable_now NAME: start NAME now and at every boot
svc_enable_now() {
  local n=$1 src="" d
  case $(init_system) in
    systemd) run systemctl enable --now "$n" ;;
    openrc) run rc-update add "$n" default; run rc-service "$n" start ;;
    runit)
      for d in $(runit_sources); do [[ -d $d/$n ]] && { src=$d/$n; break; }; done
      [[ -n $src ]] || { warn "no runit service '$n' in $(runit_sources | tr '\n' ' '); start it yourself"; return 0; }
      run ln -sfn "$src" "$(runit_dir)/$n"
      # runsvdir notices new services every few seconds
      local i
      for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        (( DRY_RUN )) || [[ $FAKE == 1 ]] || [[ -e $(runit_dir)/$n/supervise/ok ]] && break
        sleep 1
      done
      run sv up "$(runit_dir)/$n" || true ;;
    s6)
      if have s6-service; then run s6-service add default "$n"; run s6-db-reload; run s6-rc -u change "$n"
      elif have s6-rc && [[ -d /run/s6-rc ]]; then
        run s6-rc -u change "$n"
        warn "add $n to your s6-rc default bundle (then s6-rc-compile) so it starts at boot"
      else
        for d in $(s6_sources); do [[ -d $d/$n ]] && { src=$d/$n; break; }; done
        [[ -n $src ]] || { warn "no s6 service '$n' found; start it yourself"; return 0; }
        run ln -sfn "$src" "$(s6_scandir)/$n"; run s6-svscanctl -a "$(s6_scandir)"
      fi ;;
    dinit) run dinitctl enable "$n" ;;
    sysv)
      if have update-rc.d; then run update-rc.d "$n" defaults
      elif have chkconfig; then run chkconfig "$n" on; fi
      if have service; then run service "$n" start; else run "$ETC/init.d/$n" start; fi ;;
    *) warn "no init system found; start $n yourself" ;;
  esac
}

# Re-read service definitions after editing them (only systemd caches them).
svc_reread() { [[ $(init_system) == systemd ]] && run systemctl daemon-reload; return 0; }

# svc_files: "service<TAB>file" for every file that defines how a service runs
svc_files() {
  local f d
  case $(init_system) in
    systemd)
      for f in "$ETC"/systemd/system/*.service; do [[ -f $f ]] && printf '%s\t%s\n' "$(basename "$f" .service)" "$f"; done
      for f in "$ETC"/systemd/system/*.service.d/*.conf; do [[ -f $f ]] && printf '%s\t%s\n' "$(basename "$(dirname "$f")" .service.d)" "$f"; done ;;
    openrc|sysv)
      for f in "$ETC"/init.d/* "$ETC"/conf.d/* "$ETC"/default/*; do [[ -f $f ]] && printf '%s\t%s\n' "${f##*/}" "$f"; done ;;
    runit|s6)
      local srcs; if [[ $(init_system) == runit ]]; then srcs=$(runit_sources); else srcs=$(s6_sources); fi
      for d in $srcs; do
        for f in "$d"/*/run "$d"/*/up "$d"/*/conf "$d"/*/env/*; do
          [[ -f $f ]] || continue
          local rel=${f#"$d"/}; printf '%s\t%s\n' "${rel%%/*}" "$f"
        done
      done
      for f in "$ETC"/s6/config/*.conf; do [[ -f $f ]] && printf '%s\t%s\n' "$(basename "$f" .conf)" "$f"; done ;;
    dinit)
      for f in "$ETC"/dinit.d/* "$ETC"/dinit.d/*/*; do [[ -f $f ]] && printf '%s\t%s\n' "$(basename "$f")" "$f"; done ;;
  esac
  return 0
}

# svc_runtime_change OLD_FILE NEW_TEXT: does the change touch how the service
# runs (so it needs a restart)? For systemd only Exec/Environment/WorkingDirectory
# lines count; for script-based inits any change does.
svc_runtime_change() {
  if [[ $(init_system) == systemd ]]; then
    diff <(cat "$1") <(printf '%s\n' "$2") | grep -qE '^[<>] *(Exec|Environment|WorkingDirectory)'
  else
    [[ $(<"$1") != "$2" ]]
  fi
}

reload_server() {
  local svc sig=HUP
  svc=$(server_service "$1")
  [[ $1 == apache ]] && sig=USR1
  svc_reload "$svc" "$sig"
}

prepare_dirs() {
  if (( DRY_RUN )); then return 0; fi
  mkdir -p "$SITES_DIR"
  if [[ ! -d $ACME_ROOT/.well-known/acme-challenge ]]; then
    mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
    chmod -R 755 "$ACME_ROOT"
  fi
}

# Write the config file for the loaded site, enable/disable it, test, reload.
# On a failed config test the previous file is restored.
apply_site() {
  local server=$SERVER path content layout link prev=""
  path=$(conf_path "$server" "$DOMAIN")
  layout=$(server_layout "$server")
  prepare_dirs
  ensure_include "$server"

  if [[ $server == nginx ]]; then
    [[ $TYPE == custom ]] && die "$DOMAIN is a custom (adopted) site; those are Apache only"
    [[ $TYPE == proxy ]] && ensure_nginx_globals
    content=$(render_nginx)
  else
    content=$(render_apache)
    if [[ $(apache_layout) == debian ]]; then
      local m
      for m in $(apache_modules); do
        [[ -e $ETC/apache2/mods-enabled/$m.load ]] || run a2enmod -q "$m"
      done
    fi
  fi

  # remember the current file so a bad config can be rolled back
  local live=$path
  [[ $layout == confd && ! -f $path && -f $path.disabled ]] && live=$path.disabled
  if [[ -f $live ]] && ! (( DRY_RUN )); then
    prev=$(mktemp); cp -a "$live" "$prev"
  fi

  if [[ $layout == debian ]]; then
    write_file "$path" "$content"
    link=$(enabled_link "$server" "$DOMAIN")
    remove_file "$(enabled_link "$server" "$DOMAIN" $(( 1 - DEFAULT_SITE )))"
    if (( ENABLED )); then
      if (( DRY_RUN )); then echo "${C_DIM}+ ln -sfn $path $link${C_RST}"
      else ln -sfn "$path" "$link"; fi
    else
      remove_file "$link"
    fi
  else
    if (( ENABLED )); then
      write_file "$path" "$content"; remove_file "$path.disabled"
    else
      write_file "$path.disabled" "$content"; remove_file "$path"
    fi
  fi

  (( BATCH )) && return 0
  local out
  if ! out=$(config_test "$server"); then
    printf '%s\n' "$out" >&2
    warn "the $server configuration test failed; restoring the previous state"
    if [[ -n $prev ]]; then cp -a "$prev" "$live"; rm -f "$prev"
    else
      rm -f "$path" "$path.disabled"
      [[ $layout == debian ]] && rm -f "$(enabled_link "$server" "$DOMAIN")"
    fi
    die "no changes were made to $DOMAIN"
  fi
  [[ -n $prev ]] && rm -f "$prev"
  reload_server "$server"
}

# Remove the site's config from its server (state file untouched).
unapply_site() {
  local server=$SERVER path
  path=$(conf_path "$server" "$DOMAIN")
  if [[ $(server_layout "$server") == debian ]]; then
    remove_file "$(enabled_link "$server" "$DOMAIN" 0)"
    remove_file "$(enabled_link "$server" "$DOMAIN" 1)"
  fi
  remove_file "$path"
  remove_file "$path.disabled"
}

# ---------------------------------------------------------------------------
# Certificates
# ---------------------------------------------------------------------------
# lookup NAME [4]: the addresses NAME resolves to (IPv4 only with 4), one per
# line, from the system resolver or from --dns-server when given (useful when
# the local resolver still caches an old "no such name" answer).
lookup() {
  if [[ -n $DNS_SERVER ]]; then
    { dig +short A "$1" @"$DNS_SERVER"; [[ ${2:-} == 4 ]] || dig +short AAAA "$1" @"$DNS_SERVER"; } 2>/dev/null |
      grep -E '^([0-9]+\.){3}[0-9]+$|:' | sort -u || true
  else
    getent "ahosts${2:+v4}" "$1" 2>/dev/null | awk '{print $1}' | sort -u || true
  fi
}

check_dns() {
  [[ $FAKE == 1 ]] && return 0
  local name bad=()
  for name in "$@"; do
    [[ -n $(lookup "$name") ]] || bad+=("$name")
  done
  if (( ${#bad[@]} )); then
    warn "these names do not resolve in DNS yet: ${bad[*]}"
    warn "point an A/AAAA record at this server first (or drop the name with 'alias remove' / --no-www)"
    return 1
  fi
}

# issue_cert [--staging] : get/refresh a certificate for the loaded site
issue_cert() {
  local staging=${1:-0} args=() name
  have certbot || (( DRY_RUN )) || [[ $FAKE == 1 ]] || die "certbot is not installed (try: $PROG install certbot)"
  # shellcheck disable=SC2046
  local names=() skipped=()
  for name in $(server_names); do
    # ssl --expect-ip: leave out names that don't point at this server yet
    if [[ -n ${CERT_IP:-} ]] && ! names_resolve "$CERT_IP" "$name"; then skipped+=("$name"); else names+=("$name"); fi
  done
  if (( ${#skipped[@]} )); then
    warn "left out of the certificate (not pointing at $CERT_IP yet): ${skipped[*]}"
    warn "run '$PROG ssl $DOMAIN' again once they do, to add them"
  fi
  (( ${#names[@]} )) || { warn "none of the names point at $CERT_IP yet"; return 1; }
  check_dns "${names[@]}" || return 1
  for name in "${names[@]}"; do args+=(-d "$name"); done
  if [[ -n $EMAIL ]]; then args+=(--email "$EMAIL")
  else args+=(--register-unsafely-without-email); fi
  (( staging )) && args+=(--staging)
  info "requesting a Let's Encrypt certificate for: ${names[*]}"
  [[ $FAKE == 1 && -n ${HM_FAKE_CERT_FAIL:-} ]] && { warn "(test) certbot failed"; return 1; }
  run certbot certonly --webroot -w "$ACME_ROOT" --cert-name "$DOMAIN" \
    --non-interactive --agree-tos --keep-until-expiring \
    --deploy-hook "$(svc_reload_cmd "$(server_service "$SERVER")" "$([[ $SERVER == apache ]] && echo USR1 || echo HUP)")" "${args[@]}" || return 1
  CERT_FILE=""; CERT_KEY=""
}

# ---------------------------------------------------------------------------
# Option parsing shared by create/update
# ---------------------------------------------------------------------------
parse_site_opts() {
  O_SERVER=""; O_TYPE=""; O_ROOT=""; O_TARGET=""; O_PHP=""; O_ALIASES=(); O_NOWWW=0
  O_SSL=0; O_STAGING=0; O_MAXBODY=""; O_DISABLED=0
  while (($#)); do
    case $1 in
      --server|-s) O_SERVER=$2; shift ;;
      --root|-r) O_ROOT=$2; shift ;;
      --static) O_TYPE=static ;;
      --php) O_TYPE=php ;;
      --php-sock) O_TYPE=php; O_PHP=$2; shift ;;
      --proxy|-p) O_TYPE=proxy; O_TARGET=$2; shift ;;
      --redirect-to) O_TYPE=redirect; O_TARGET=$2; shift ;;
      --alias|-a) O_ALIASES+=("$2"); shift ;;
      --no-www) O_NOWWW=1 ;;
      --ssl) O_SSL=1 ;;
      --staging) O_STAGING=1 ;;
      --email) EMAIL=$2; shift ;;
      --max-body) O_MAXBODY=$2; shift ;;
      --disabled) O_DISABLED=1 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

normalize_target() {
  local t=$1
  case $TYPE in
    proxy)
      [[ $t =~ ^[0-9]+$ ]] && t="http://127.0.0.1:$t"
      [[ $t =~ ^[^/]+:[0-9]+$ && ! $t =~ ^https?: ]] && t="http://$t"
      [[ $t =~ ^https?:// ]] || die "--proxy wants a port or URL, e.g. 3000 or http://127.0.0.1:3000"
      ;;
    redirect)
      [[ $t =~ ^https?:// ]] || t="https://$t"
      t=${t%/}
      ;;
  esac
  echo "$t"
}

resolve_php_sock() {
  [[ $TYPE == php ]] || { PHP_SOCK=""; return; }
  [[ -n $PHP_SOCK ]] && return
  PHP_SOCK=$(find_php_sock)
  if [[ -z $PHP_SOCK ]]; then
    if [[ $SERVER == nginx ]]; then
      PHP_SOCK=/run/php/php-fpm.sock
      warn "no php-fpm socket found; using $PHP_SOCK (install php-fpm or pass --php-sock PATH)"
    else
      warn "no php-fpm socket found; relying on mod_php"
    fi
  fi
}

placeholder_page() {
  local root=$1 domain=$2
  (( DRY_RUN )) && { echo "${C_DIM}+ create $root with a placeholder page${C_RST}"; return; }
  [[ -d $root ]] || { mkdir -p "$root"; chmod 755 "$root"; }
  if [[ -z $(ls -A "$root") ]]; then
    if [[ $TYPE == php ]]; then
      printf '<?php echo "<h1>%s</h1><p>PHP ", PHP_VERSION, " is working.</p>";\n' "$domain" > "$root/index.php"
    else
      printf '<!doctype html><title>%s</title><h1>%s</h1><p>This site is ready for its content.</p>\n' "$domain" "$domain" > "$root/index.html"
    fi
    [[ $FAKE == 1 ]] || chown -R "$(web_user):$(web_user)" "$root"
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_create() {
  [[ $# -ge 1 ]] || die "usage: $PROG create <domain> [options]"
  local domain=${1,,}; shift
  check_domain "$domain"
  parse_site_opts "$@"
  need_root create
  site_exists "$domain" && die "$domain already exists (use '$PROG update $domain ...')"

  reset_site
  DOMAIN=$domain
  SERVER=$(pick_server "$O_SERVER")
  TYPE=${O_TYPE:-static}
  [[ -n $O_TARGET ]] && TARGET=$(normalize_target "$O_TARGET")
  PHP_SOCK=$O_PHP
  resolve_php_sock
  if [[ $TYPE == static || $TYPE == php ]]; then ROOT=${O_ROOT:-$WWW/$DOMAIN}; fi
  local a list=()
  if (( ! O_NOWWW )) && is_apex "$DOMAIN"; then list+=("www.$DOMAIN"); fi
  for a in "${O_ALIASES[@]}"; do check_domain "$a"; list+=("${a,,}"); done
  ALIASES="${list[*]}"
  MAX_BODY=$O_MAXBODY
  (( O_DISABLED )) && ENABLED=0
  CREATED=$(date -Iseconds)

  # domains already used by another managed site?
  local other n
  for other in $(all_sites); do
    for n in $(server_names); do
      ( load_site "$other"; [[ " $(server_names) " == *" $n "* ]] ) && die "$n is already served by $other"
    done
  done

  info "creating $TYPE site $DOMAIN on $SERVER${ALIASES:+ (aliases: $ALIASES)}"
  [[ -n $ROOT ]] && placeholder_page "$ROOT" "$DOMAIN"
  apply_site
  save_site

  if (( O_SSL )); then
    if issue_cert "$O_STAGING"; then
      SSL=1; apply_site; save_site
    else
      warn "the site is up on plain HTTP; run '$PROG ssl $DOMAIN' once DNS is ready"
    fi
  fi
  info "done: $(site_url)"
}

site_url() { if (( SSL )); then echo "https://$DOMAIN"; else echo "http://$DOMAIN"; fi; }

cmd_update() {
  [[ $# -ge 1 ]] || die "usage: $PROG update <domain> [options]"
  local domain=${1,,}; shift
  parse_site_opts "$@"
  need_root update
  load_site "$domain"
  local old_server=$SERVER old_names
  old_names=$(server_names)

  [[ -n $O_SERVER ]] && SERVER=$(pick_server "$O_SERVER")
  if [[ $TYPE == custom && -n $O_ROOT && -n $ROOT ]]; then
    BODY_HTTP=$(replace_path "$BODY_HTTP" "$ROOT" "$O_ROOT")
    BODY_HTTPS=$(replace_path "$BODY_HTTPS" "$ROOT" "$O_ROOT")
  fi
  if [[ $TYPE == custom && -n $O_TYPE ]]; then
    BODY_HTTP=""; BODY_HTTPS=""; HTTP_ADDR=""; HTTPS_ADDR=""
  fi
  if [[ -n $O_TYPE ]]; then
    TYPE=$O_TYPE
    [[ $TYPE == static || $TYPE == php ]] && ROOT=${ROOT:-$WWW/$DOMAIN}
    [[ $TYPE == proxy || $TYPE == redirect ]] && ROOT=""
    [[ $TYPE == static || $TYPE == php ]] && TARGET=""
  fi
  [[ -n $O_TARGET ]] && TARGET=$(normalize_target "$O_TARGET")
  [[ -n $O_ROOT ]] && ROOT=$O_ROOT
  [[ -n $O_PHP ]] && PHP_SOCK=$O_PHP
  [[ -n $O_TYPE && -z $O_PHP ]] && PHP_SOCK=""
  resolve_php_sock
  [[ -n $O_MAXBODY ]] && MAX_BODY=$O_MAXBODY
  [[ $O_MAXBODY == none ]] && MAX_BODY=""
  local a
  for a in "${O_ALIASES[@]}"; do
    check_domain "$a"
    [[ " $ALIASES " == *" ${a,,} "* ]] || ALIASES="${ALIASES:+$ALIASES }${a,,}"
  done
  if (( O_NOWWW )); then ALIASES=$(words_without "$ALIASES" "www.$DOMAIN"); fi
  [[ ( $TYPE == proxy || $TYPE == redirect ) && -z $TARGET ]] && die "$TYPE sites need a target (--proxy / --redirect-to)"

  if [[ $SERVER != "$old_server" ]]; then
    info "moving $DOMAIN from $old_server to $SERVER"
    ( SERVER=$old_server; unapply_site; reload_server "$old_server" )
  fi
  [[ -n $ROOT && $TYPE != custom ]] && placeholder_page "$ROOT" "$DOMAIN"
  info "updating $DOMAIN"
  apply_site
  save_site

  if (( SSL )) && [[ $(server_names) != "$old_names" ]]; then
    reissue_or_warn
  elif (( O_SSL && !SSL )); then
    if issue_cert "$O_STAGING"; then SSL=1; apply_site; save_site; fi
  fi
  info "done: $(site_url)"
}

# The site's names changed while it has HTTPS: get a matching certificate.
reissue_or_warn() {
  if ! issue_cert; then
    warn "could not update the certificate; $DOMAIN keeps its old certificate, which does not cover every name"
  else
    reload_server "$SERVER"
  fi
}

# replace_path TEXT OLD NEW: replace the directory OLD (and paths under it) with NEW.
replace_path() {
  local old=${2%/} new=${3%/}
  printf '%s' "$1" | HM_OLD=$old HM_NEW=$new perl -0777 -pe 's{\Q$ENV{HM_OLD}\E(?=[/"\x27 :;>]|$)}{$ENV{HM_NEW}}gm'
}

# replace_domain TEXT OLD NEW: replace the host name OLD (also as the end of a
# longer name like www.OLD), but not inside other names such as my-OLD, and not
# inside file paths such as /var/www/OLD or /var/log/apache2/OLD-error.log
# (URLs like https://OLD/ are still replaced). Paths are left to replace_path,
# so a site whose files stay put keeps working.
replace_domain() {
  printf '%s' "$1" | HM_OLD=$2 HM_NEW=$3 perl -0777 -pe 's{(?<![A-Za-z0-9-])(?<![^/]/)(?<!^/)\Q$ENV{HM_OLD}\E(?![A-Za-z0-9-])}{$ENV{HM_NEW}}gm'
}

words_without() {
  local w out=()
  for w in $1; do [[ $w == "$2" ]] || out+=("$w"); done
  echo "${out[*]}"
}

cmd_list() {
  local d any=0
  printf '%s%-32s %-7s %-9s %-5s %-8s %s%s\n' "$C_BLD" DOMAIN SERVER TYPE SSL STATE "ROOT / TARGET" "$C_RST"
  for d in $(all_sites); do
    any=1
    ( load_site "$d"
      local ssl=no st=enabled
      (( SSL )) && ssl=yes
      (( ENABLED )) || st=disabled
      local where=${ROOT:-$TARGET}
      [[ -z $where && $TYPE == custom ]] && where=$(grep -m1 -oiE 'ProxyPass\s+/\s+\S+' <<<"$BODY_HTTPS$BODY_HTTP" | awk '{print "-> " $3}' || true)
      [[ -n $HTTP_ADDR && $HTTP_ADDR != "*:80" ]] && where="[$HTTP_ADDR] $where"
      printf '%-32s %-7s %-9s %-5s %-8s %s\n' "$DOMAIN" "$SERVER" "$TYPE" "$ssl" "$st" "$where"
      [[ -n $ALIASES ]] && printf '  %saliases: %s%s\n' "$C_DIM" "$ALIASES" "$C_RST"
      true )
  done
  (( any )) || echo "(no sites yet; create one with: $PROG create example.com)"
}

cmd_info() {
  [[ $# -eq 1 ]] || die "usage: $PROG info <domain>"
  load_site "${1,,}"
  local k
  for k in "${STATE_KEYS[@]}"; do printf '%-9s %s\n' "$k" "${!k}"; done
  printf '%-9s %s\n' CONFIG "$(conf_path "$SERVER" "$DOMAIN")"
  if cert_exists "$DOMAIN" && have openssl; then
    printf '%-9s %s\n' CERT "$(openssl x509 -in "$LE_DIR/live/$DOMAIN/fullchain.pem" -noout -enddate 2>/dev/null | sed 's/notAfter=/expires /')"
  fi
}

cmd_show() {
  [[ $# -eq 1 ]] || die "usage: $PROG show <domain>"
  load_site "${1,,}"
  local p; p=$(conf_path "$SERVER" "$DOMAIN")
  [[ -f $p ]] || p=$p.disabled
  cat "$p"
}

cmd_enable_disable() {
  local want=$1; shift
  [[ $# -eq 1 ]] || die "usage: $PROG enable|disable <domain>"
  need_root
  load_site "${1,,}"
  ENABLED=$want
  apply_site
  save_site
  if (( want )); then info "$DOMAIN enabled"; else info "$DOMAIN disabled (config kept)"; fi
}

cmd_remove() {
  [[ $# -ge 1 ]] || die "usage: $PROG remove <domain> [--purge] [--delete-cert]"
  local domain=${1,,} purge=0 delcert=0; shift
  while (($#)); do
    case $1 in
      --purge) purge=1 ;;
      --delete-cert) delcert=1 ;;
      *) die "unknown option: $1" ;;
    esac; shift
  done
  need_root
  load_site "$domain"
  confirm "Remove $DOMAIN from $SERVER?" || die "aborted"
  unapply_site
  reload_server "$SERVER"
  delete_site_record "$DOMAIN"
  if (( delcert )) && cert_exists "$DOMAIN"; then run certbot delete --non-interactive --cert-name "$DOMAIN"; fi
  if (( purge )) && [[ -n $ROOT && -d $ROOT ]]; then
    [[ $ROOT == / || $ROOT == "$WWW" ]] && die "refusing to delete $ROOT"
    if confirm "Delete the web root $ROOT and all its files?"; then
      run rm -rf -- "$ROOT"
    fi
  fi
  info "removed $DOMAIN${ROOT:+ (files in $ROOT kept unless --purge)}"
}

# rename <old> <new>: move a site to a new domain name
cmd_rename() {
  [[ $# -ge 2 ]] || die "usage: $PROG rename <old-domain> <new-domain> [--redirect] [--keep-root] [--delete-old-cert] [--drop-aliases] [--rewrite-units] [--wait-dns [--expect-ip IP] [--timeout DAYS]] [--force]"
  local args=("$@")
  local old=${1,,} new=${2,,} redirect=0 keep_root=0 delcert=0 force=0 drop=0 units=0 wait=0 expect="" timeout_days=14; shift 2
  while (($#)); do
    case $1 in
      --redirect) redirect=1 ;;
      --force) force=1 ;;
      --keep-root) keep_root=1 ;;
      --delete-old-cert) delcert=1 ;;
      --drop-aliases) drop=1 ;;
      --rewrite-units) units=1 ;;
      --wait-dns) wait=1 ;;
      --expect-ip) expect=$2; shift ;;
      --timeout) timeout_days=$2; shift ;;
      --email) EMAIL=$2; shift ;;
      *) die "unknown option: $1" ;;
    esac; shift
  done
  check_domain "$new"
  need_root
  load_site "$old"
  site_exists "$new" && die "$new already exists"

  local old_ssl=$SSL old_root=$ROOT old_aliases=$ALIASES a new_aliases=()
  if (( ! drop )); then
    for a in $old_aliases; do
      if [[ $a == "www.$old" ]]; then new_aliases+=("www.$new")
      elif [[ $a == *".$old" ]]; then new_aliases+=("${a%".$old"}.$new")
      else new_aliases+=("$a"); fi
    done
  fi

  # --wait-dns: keep the site as it is until every new name resolves (to
  # --expect-ip when given), then rename; a failed certificate is undone and
  # tried again an hour later.
  if (( wait )); then
    local deadline=$(( $(date +%s) + timeout_days * 86400 )) told=0
    until names_resolve "$expect" $new ${new_aliases[*]}; do
      (( $(date +%s) < deadline )) || die "gave up: $new did not resolve within $timeout_days days"
      (( told )) || { info "waiting for DNS: $new ${new_aliases[*]}${expect:+ -> $expect} (checking every 5 minutes)"; told=1; }
      sleep "${HM_DNS_POLL:-300}"
    done
    info "$new resolves; renaming"
  fi
  # one change at a time when several renames run side by side
  take_lock
  if (( wait )); then load_site "$old"; fi

  # An HTTPS site must not lose its old name before the new one can get a
  # certificate, so the new names have to resolve first.
  if (( old_ssl && !force && !wait )); then
    # shellcheck disable=SC2086
    check_dns $new ${new_aliases[*]} || die "fix DNS for the new names first (or pass --wait-dns, or --force to rename anyway and stay on plain HTTP)"
  fi
  info "renaming $old -> $new"
  # 1. the new site, plain HTTP first so certbot can validate it
  DOMAIN=$new; ALIASES="${new_aliases[*]}"; SSL=0; CERT_FILE=""; CERT_KEY=""
  local moved_root=""
  if [[ -n $old_root && $old_root == "$WWW/$old" && $keep_root == 0 ]]; then
    ROOT="$WWW/$new"
    if [[ -d $old_root ]]; then
      [[ -e $ROOT ]] && die "$ROOT already exists; use --keep-root or move it away"
      if (( redirect )); then run cp -a "$old_root" "$ROOT"; else run mv "$old_root" "$ROOT"; moved_root=1; fi
    fi
  fi
  if [[ $TYPE == custom ]]; then
    BODY_HTTP=$(replace_domain "$BODY_HTTP" "$old" "$new")
    BODY_HTTPS=$(replace_domain "$BODY_HTTPS" "$old" "$new")
    # the kept directives name the web root themselves; follow it only if it moved
    if [[ -n $old_root && $ROOT != "$old_root" ]]; then
      BODY_HTTP=$(replace_path "$BODY_HTTP" "$old_root" "$ROOT")
      BODY_HTTPS=$(replace_path "$BODY_HTTPS" "$old_root" "$ROOT")
    fi
  fi
  apply_site
  save_site

  if (( old_ssl )); then
    if issue_cert; then SSL=1; apply_site; save_site
    elif (( wait || !force )); then
      # undo: the old site stays exactly as it was
      unapply_site; delete_site_record "$new"; reload_server "$SERVER"
      [[ -n $moved_root ]] && run mv "$ROOT" "$old_root"
      if (( wait )); then
        warn "no certificate for $new yet (does it point at this server?); trying again in an hour"
        release_lock
        sleep "${HM_CERT_RETRY:-3600}"
        exec "$0" rename "${args[@]}"
      fi
      die "no certificate for $new; nothing was changed"
    else
      warn "$new is on plain HTTP for now; run '$PROG ssl $new' once its DNS points here"
    fi
  fi
  local new_url
  new_url=$(site_url)

  # 2. the old name: redirect to the new one, or remove it
  ( load_site "$old"
    unapply_site
    if (( redirect )); then
      TYPE=redirect; TARGET=$new_url; ROOT=""; PHP_SOCK=""; BODY_HTTP=""; BODY_HTTPS=""
      apply_site; save_site
      info "$old now redirects to $new_url"
    else
      delete_site_record "$old"
      reload_server "$SERVER"
      if (( delcert )) && cert_exists "$old"; then run certbot delete --non-interactive --cert-name "$old"; fi
    fi )
  if (( redirect )) && [[ $old_root == "$WWW/$old" && $keep_root == 0 && -d $old_root ]]; then
    info "the old files are still in $old_root (remove them when you no longer need them)"
  fi
  (( units )) && rename_in_units "$old" "$new"
  info "done: $new_url"
}

take_lock() {
  (( DRY_RUN )) && return 0
  have flock || return 0
  local f=/run/lock/hosting-manager.lock
  [[ -n ${HM_ETC:-} ]] && f=$STATE_DIR/.lock
  mkdir -p "$(dirname "$f")"
  exec 9>"$f"
  flock 9
}
release_lock() { exec 9>&- 2>/dev/null || true; }

# names_resolve EXPECTED-IP NAME...: every name has an address (EXPECTED-IP among them, if given)
names_resolve() {
  local want=$1 n addrs; shift
  [[ $FAKE == 1 && -z ${HM_FAKE_DNS:-} ]] && return 0
  for n in "$@"; do
    if [[ -n ${HM_FAKE_DNS:-} ]]; then addrs=$(grep -F "$n " "$HM_FAKE_DNS" 2>/dev/null | awk '{print $2}' || true)
    else addrs=$(lookup "$n" 4); fi
    [[ -n $addrs ]] || return 1
    [[ -z $want ]] || grep -qxF "$want" <<<"$addrs" || return 1
  done
}

# rename_in_units OLD NEW: replace the host name in service definitions (systemd
# units, OpenRC/SysV scripts and conf.d/default files, runit/s6 run scripts,
# dinit services; not inside paths such as /var/www/OLD), then restart the
# running services whose command or environment changed.
rename_in_units() {
  local old=$1 new=$2 f svc changed=() keep="$BACKUP_DIR/$STAMP-units"
  while IFS=$'\t' read -r svc f; do
    [[ -f $f ]] || continue
    local t; t=$(HM_OLD=$old HM_NEW=$new perl -0777 -pe 's{(?<![A-Za-z0-9./_-])\Q$ENV{HM_OLD}\E(?![A-Za-z0-9-])}{$ENV{HM_NEW}}g' "$f")
    [[ $t == "$(<"$f")" ]] && continue
    if (( DRY_RUN )); then echo "${C_DIM}+ rewrite $f${C_RST}"; continue; fi
    mkdir -p "$keep"; cp -a "$f" "$keep/${f//\//_}"
    local restart=0
    svc_runtime_change "$f" "$t" && restart=1
    printf '%s\n' "$t" > "$f"
    info "updated $svc ($f)"
    (( restart )) && [[ " ${changed[*]} " != *" $svc "* ]] && changed+=("$svc")
  done < <(svc_files)
  (( DRY_RUN )) && return 0
  svc_reread
  local v
  for v in "${changed[@]}"; do
    if svc_active "$v"; then svc_restart "$v"; info "restarted $v"; fi
  done
  return 0
}

cmd_alias() {
  [[ $# -ge 3 ]] || die "usage: $PROG alias <domain> add|remove <name>..."
  local domain=${1,,} action=$2; shift 2
  need_root
  load_site "$domain"
  local n
  for n in "$@"; do
    n=${n,,}; check_domain "$n"
    case $action in
      add) [[ " $ALIASES " == *" $n "* ]] || ALIASES="${ALIASES:+$ALIASES }$n" ;;
      remove|rm) ALIASES=$(words_without "$ALIASES" "$n") ;;
      *) die "alias action must be add or remove" ;;
    esac
  done
  # The existing certificate keeps HTTPS working while the new names are
  # validated over HTTP; afterwards the certificate covers every name.
  apply_site; save_site
  if (( SSL )); then reissue_or_warn; fi
  info "$DOMAIN aliases: ${ALIASES:-(none)}"
}

cmd_ssl() {
  [[ $# -ge 1 ]] || die "usage: $PROG ssl <domain> [--off] [--staging] [--email ADDR] [--expect-ip IP]"
  local domain=${1,,} off=0 staging=0; shift
  while (($#)); do
    case $1 in
      --off) off=1 ;;
      --staging) staging=1 ;;
      --email) EMAIL=$2; shift ;;
      --expect-ip) CERT_IP=$2; shift ;;
      *) die "unknown option: $1" ;;
    esac; shift
  done
  need_root
  load_site "$domain"
  if (( off )); then
    SSL=0; apply_site; save_site
    info "HTTPS turned off for $DOMAIN (certificate kept; '$PROG remove --delete-cert' deletes it)"
    return
  fi
  issue_cert "$staging" || die "could not get a certificate for $DOMAIN"
  SSL=1; apply_site; save_site
  info "done: $(site_url)"
}

cmd_renew() {
  need_root
  local args=()
  [[ ${1:-} == --test ]] && args+=(--dry-run)
  run certbot renew "${args[@]}"
}

cmd_certs() { run certbot certificates; }

cmd_test() {
  local s
  for s in nginx apache; do
    server_installed "$s" || continue
    info "testing $s"
    config_test "$s" || true
  done
}

cmd_reload() {
  need_root
  local s
  for s in nginx apache; do
    server_installed "$s" || continue
    # an installed but stopped server (e.g. nginx next to Apache) is left alone
    if svc_active "$(server_service "$s")"; then reload_server "$s"
    else info "$s is installed but not running; not reloaded"; fi
  done
  return 0
}

cmd_doctor() {
  local s ok="${C_GRN}ok${C_RST}" no="${C_YLW}missing${C_RST}"
  echo "${C_BLD}$PROG $VERSION${C_RST}"
  printf '%-10s %s\n' init "$(init_system)"
  for s in nginx apache; do
    if server_installed "$s"; then
      local v=""
      [[ $s == nginx ]] && have nginx && v=$(nginx -v 2>&1 | sed 's/.*: //')
      [[ $s == apache ]] && { v=$( (apachectl -v || apache2ctl -v || httpd -v) 2>/dev/null | sed -n 's/^Server version: //p' | head -1) || true; }
      printf '%-10s %s (%s layout) %s\n' "$s" "$ok" "$(server_layout "$s")" "$v"
    else
      printf '%-10s %s\n' "$s" "$no"
    fi
  done
  if have certbot; then printf '%-10s %s %s\n' certbot "$ok" "$(certbot --version 2>&1)"
  else printf '%-10s %s\n' certbot "$no"; fi
  local sock; sock=$(find_php_sock)
  if [[ -n $sock ]]; then printf '%-10s %s %s\n' php-fpm "$ok" "$sock"
  else printf '%-10s %s\n' php-fpm "$no (only needed for --php sites)"; fi
  if have ss; then
    echo "listening on 80/443:"
    ss -ltnpH 2>/dev/null | awk '$4 ~ /:(80|443)$/ {print "  " $4, $6}' || true
  fi
  if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    echo "ufw is active; allowed web rules:"
    ufw status | grep -E '80|443|Nginx|Apache|WWW' | sed 's/^/  /' || echo "  none: run 'sudo ufw allow 80,443/tcp'"
  fi
  printf 'sites      %s managed (%s)\n' "$(all_sites | wc -l)" "$SITES_DIR"
}

cmd_install() {
  [[ $# -ge 1 ]] || die "usage: $PROG install nginx|apache|certbot|php"
  need_root
  local pm pkgs=() what
  if have apt-get; then pm=apt
  elif have dnf; then pm=dnf
  elif have yum; then pm=yum
  elif have pacman; then pm=pacman
  elif have apk; then pm=apk
  elif have xbps-install; then pm=xbps
  elif have zypper; then pm=zypper
  elif have emerge; then pm=emerge
  else die "no supported package manager (apt, dnf, yum, pacman, apk, xbps, zypper, emerge)"; fi
  for what in "$@"; do
    case $pm:$what in
      apt:nginx) pkgs+=(nginx) ;;
      apt:apache) pkgs+=(apache2) ;;
      apt:certbot) pkgs+=(certbot) ;;
      apt:php) pkgs+=(php-fpm) ;;
      dnf:nginx|yum:nginx) pkgs+=(nginx) ;;
      dnf:apache|yum:apache) pkgs+=(httpd mod_ssl) ;;
      dnf:certbot|yum:certbot) pkgs+=(certbot) ;;
      dnf:php|yum:php) pkgs+=(php-fpm) ;;
      pacman:nginx) pkgs+=(nginx) ;;
      pacman:apache) pkgs+=(apache) ;;
      pacman:certbot) pkgs+=(certbot) ;;
      pacman:php) pkgs+=(php-fpm) ;;
      apk:nginx) pkgs+=(nginx) ;;
      apk:apache) pkgs+=(apache2 apache2-ssl apache2-proxy) ;;
      apk:certbot) pkgs+=(certbot) ;;
      apk:php) pkgs+=(php-fpm) ;;
      xbps:nginx) pkgs+=(nginx) ;;
      xbps:apache) pkgs+=(apache) ;;
      xbps:certbot) pkgs+=(certbot) ;;
      xbps:php) pkgs+=(php-fpm) ;;
      zypper:nginx) pkgs+=(nginx) ;;
      zypper:apache) pkgs+=(apache2) ;;
      zypper:certbot) pkgs+=(python3-certbot) ;;
      zypper:php) pkgs+=(php-fpm) ;;
      emerge:nginx) pkgs+=(www-servers/nginx) ;;
      emerge:apache) pkgs+=(www-servers/apache) ;;
      emerge:certbot) pkgs+=(app-crypt/certbot) ;;
      emerge:php) pkgs+=(dev-lang/php) ;;
      *) die "don't know how to install '$what' (choose nginx, apache, certbot, php)" ;;
    esac
  done
  case $pm in
    apt) run apt-get update; run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
    dnf|yum) run "$pm" install -y "${pkgs[@]}" ;;
    pacman) run pacman -S --needed --noconfirm "${pkgs[@]}" ;;
    apk) run apk add "${pkgs[@]}" ;;
    xbps) run xbps-install -Sy "${pkgs[@]}" ;;
    zypper) run zypper --non-interactive install "${pkgs[@]}" ;;
    emerge) run emerge --noreplace "${pkgs[@]}" ;;
  esac
  for what in "$@"; do
    case $what in
      nginx) svc_enable_now nginx ;;
      apache) svc_enable_now "$(apache_service)" ;;
      php) local u; u=$(svc_names | grep -E '^php.*fpm' | sort -V | tail -1 || true)
           if [[ -n $u ]]; then svc_enable_now "$u"; else warn "no php-fpm service found; start it yourself"; fi ;;
    esac
  done
  if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    info "ufw is active; opening ports 80 and 443"
    run ufw allow 80,443/tcp
  fi
}

cmd_config() {
  # config [key [value]] : show or set defaults (server, email)
  if [[ $# -eq 0 ]]; then
    printf 'server  %s\nemail   %s\n' "${DEFAULT_SERVER:-(auto)}" "${EMAIL:-(none)}"
    return
  fi
  need_root
  local key=$1 val=${2:-}
  case $key in
    server) [[ -z $val || $val == nginx || $val == apache ]] || die "server must be nginx or apache"; DEFAULT_SERVER=$val ;;
    email) EMAIL=$val ;;
    *) die "unknown setting '$key' (server, email)" ;;
  esac
  write_file "$CONFIG_FILE" "# $PROG defaults
DEFAULT_SERVER=$(printf '%q' "$DEFAULT_SERVER")
EMAIL=$(printf '%q' "$EMAIL")"
  info "$key set to ${val:-(unset)}"
}

# ---------------------------------------------------------------------------
# Safety net for changes to many sites: whole-tree backup, probes before/after
# ---------------------------------------------------------------------------
apache_dir() { if [[ $(apache_layout) == confd ]]; then dirname "$(apache_confd)"; else echo "$ETC/apache2"; fi; }

# Archive the Apache tree and the site records; restore_tree puts both back.
backup_tree() {
  TREE_BACKUP="$BACKUP_DIR/$STAMP-$1.tgz"
  (( DRY_RUN )) && return 0
  mkdir -p "$BACKUP_DIR"
  local dirs=("$(basename "$(apache_dir)")")
  [[ -d $STATE_DIR ]] && dirs+=("$(basename "$STATE_DIR")")
  tar czf "$TREE_BACKUP" -C "$ETC" --exclude="$(basename "$STATE_DIR")/backups" "${dirs[@]}"
  chmod 600 "$TREE_BACKUP"
  info "backup: $TREE_BACKUP"
}

restore_tree() {
  [[ -n ${TREE_BACKUP:-} && -f $TREE_BACKUP ]] || return 0
  warn "restoring $TREE_BACKUP"
  rm -rf "$(apache_dir)"
  find "$SITES_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  tar xzf "$TREE_BACKUP" -C "$ETC"
  if [[ $FAKE != 1 ]] && config_test apache >/dev/null 2>&1; then reload_server apache || true; fi
}

# URLs of the loaded site: "url port name"
site_urls() {
  local port
  if [[ $TYPE != custom || -n $BODY_HTTP ]]; then
    port=$(http_addr); port=${port##*:}
    echo "http://$DOMAIN:$port/ $port $DOMAIN"
  fi
  if (( SSL )); then
    port=$(https_addr); port=${port##*:}
    echo "https://$DOMAIN:$port/ $port $DOMAIN"
  fi
}

# Read "url port name" lines; print "url status redirect" for each, asking this
# server directly (127.0.0.1) so DNS doesn't matter.
probe_urls() {
  [[ $FAKE == 1 ]] && { cat >/dev/null; return 0; }
  have curl || die "curl is needed for the checks"
  xargs -r -P 16 -L 1 sh -c 'printf "%s %s\n" "$1" "$(curl -sk -o /dev/null -m 20 -w "%{http_code} %{redirect_url}" --resolve "$3:$2:127.0.0.1" "$1")"' _ | sort
}

# compare_probes BEFORE AFTER: differences are probed once more before failing.
compare_probes() {
  local before=$1 after=$2 diffs
  diffs=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> //p' | awk '{print $1}')
  [[ -z $diffs ]] && return 0
  sleep 3
  local again url bad=0
  again=$(while read -r url; do
    local port host
    host=${url#*://}; host=${host%%[:/]*}
    port=${url#*://*:}; port=${port%%/*}
    echo "$url $port $host"
  done <<<"$diffs" | probe_urls)
  while read -r url; do
    local b a
    b=$(grep -F "$url " <<<"$before" | head -1 || true)
    a=$(grep -F "$url " <<<"$again" | head -1 || true)
    if [[ $b != "$a" ]]; then warn "changed: ${b:-$url (new)}  ->  ${a#"$url "}"; bad=1; fi
  done <<<"$diffs"
  return $bad
}

# Names served on each address, from apache2ctl -S (for before/after comparison).
vhost_names() {
  local cmd=${HM_APACHE_S:-}    # test hook: command printing apache2ctl -S output
  if [[ -z $cmd ]]; then
    [[ $FAKE == 1 ]] && return 0
    cmd=apachectl; have apache2ctl && cmd=apache2ctl
    cmd="$cmd -S"
  fi
  eval "$cmd" 2>/dev/null | awk '
    /^[^ ]+:[0-9]+ +is a NameVirtualHost/ {addr=$1; next}
    /^[^ ]+:[0-9]+ +[^ ]+ +\(/            {print $1, $2; next}
    /port [0-9]+ namevhost/               {print addr, $4; next}
    /default server /                     {print addr, "default", $3; next}
    /^ +alias /                           {print addr, "alias", $2}' | sort -u
}

# default <domain>: make it the site that answers names nobody else claims
cmd_default() {
  [[ $# -eq 1 ]] || die "usage: $PROG default <domain>"
  need_root
  local d target=${1,,}
  site_exists "$target" || die "no managed site named $target"
  BATCH=1
  for d in $(all_sites); do
    load_site "$d"
    local want=0; [[ $d == "$target" ]] && want=1
    [[ $DEFAULT_SITE == "$want" ]] && continue
    DEFAULT_SITE=$want; apply_site; save_site
  done
  BATCH=0
  local out; out=$(config_test "$SERVER") || { printf '%s\n' "$out" >&2; die "configuration test failed"; }
  reload_server "$SERVER"
  info "$target now answers requests for unknown names"
}

cmd_check() {
  local save="" compare="" names=() d
  while (($#)); do
    case $1 in
      --save) save=$2; shift ;;
      --compare) compare=$2; shift ;;
      -*) die "unknown option: $1" ;;
      *) names+=("${1,,}") ;;
    esac; shift
  done
  (( ${#names[@]} )) || mapfile -t names < <(all_sites)
  local out
  out=$(for d in "${names[@]}"; do ( load_site "$d"; (( ENABLED )) && site_urls; true ); done | probe_urls)
  if [[ -n $save ]]; then printf '%s\n' "$out" > "$save"; info "saved $(wc -l <<<"$out") results to $save"; fi
  if [[ -n $compare ]]; then
    [[ -f $compare ]] || die "no such file: $compare"
    if compare_probes "$(<"$compare")" "$out"; then info "every site answers as in $compare"
    else die "some sites answer differently"; fi
  fi
  [[ -n $save || -n $compare ]] || printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# adopt: take existing Apache vhosts over, one file per site
# ---------------------------------------------------------------------------
# Enabled config files, in Apache's load order: "kind link realpath"
apache_sources() {
  local d f
  if [[ $(apache_layout) == confd ]]; then
    for f in "$(apache_confd)"/*.conf; do [[ -f $f ]] && echo "conf.d $f $f"; done
    return 0
  fi
  for d in conf-enabled sites-enabled; do
    for f in "$ETC/apache2/$d"/*.conf; do
      [[ -e $f ]] || continue
      echo "$d $f $(readlink -f "$f")"
    done
  done
}

# Parse one config file into vhost records (see adopt_scan).
parse_vhosts() {
  awk -v F="$1" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    BEGIN { inv = 0; other = 0 }
    {
      line = $0; sub(/\r$/, "", line); l = tolower(trim(line))
      if (!inv) {
        if (l ~ /^<virtualhost[ \t>]/) {
          inv = 1; addr = trim(line); sub(/^<[Vv][Ii][Rr][Tt][Uu][Aa][Ll][Hh][Oo][Ss][Tt][ \t]+/, "", addr); sub(/>.*$/, "", addr)
          name = ""; aliases = ""; ssl = (addr ~ /:443$/); cert = ""; key = ""; doc = ""; nb = 0
          next
        }
        if (l ~ /^<ifmodule[ \t]+mod_ssl\.c>$/ || l ~ /^<\/ifmodule>$/) next
        if (l == "" || l ~ /^#/) next
        other++; next
      }
      if (l ~ /^<\/virtualhost>/) {
        inv = 0
        printf "V\037%s\037%s\037%s\037%s\037%d\037%s\037%s\037%s\n", F, addr, name, trim(aliases), ssl, cert, key, doc
        for (i = 1; i <= nb; i++) print "B\t" body[i]
        print "E"
        next
      }
      n = split(trim(line), w, /[ \t]+/)
      k = tolower(w[1])
      if (k == "servername") { name = tolower(w[2]); sub(/:[0-9]+$/, "", name); sub(/^https?:\/\//, "", name); next }
      if (k == "serveralias") { for (i = 2; i <= n; i++) aliases = aliases " " tolower(w[i]); next }
      if (k == "sslcertificatefile") { cert = w[2]; ssl = 1; next }
      if (k == "sslcertificatekeyfile") { key = w[2]; next }
      if (k == "sslengine" && tolower(w[2]) == "on") ssl = 1
      if (k == "documentroot") { doc = w[2]; gsub(/"/, "", doc) }
      body[++nb] = line
    }
    END { if (inv) other++; printf "O\t%s\t%d\n", F, other }' "$1"
}

cmd_adopt() {
  local all=0 want=() a
  for a in "$@"; do
    case $a in
      --all) all=1 ;;
      -*) die "unknown option: $a" ;;
      *) check_domain "$a"; want+=("${a,,}") ;;
    esac
  done
  (( all || ${#want[@]} )) || die "usage: $PROG adopt --all | <domain>..."
  [[ $(apache_layout) != none ]] || die "adopt works with Apache configs; Apache was not found"
  need_root

  # --- scan
  local -A src_of=() src_other=() links_of=() mode_of=()
  local -A h_addr=() h_body=() h_n=() s_addr=() s_body=() s_n=() s_cert=() s_key=() aliases_of=() root_of=() vh_of_src=()
  local names=() kind link real rec
  local adir; adir=$(apache_dir)
  while read -r kind link real; do
    if [[ $real != "$adir"/* ]]; then
      warn "$link points outside $adir ($real); left alone"
      continue
    fi
    links_of[$real]+="$link "
    [[ -n ${src_other[$real]+x} ]] && continue
    src_other[$real]=0
    mode_of[$real]=$(stat -c %a "$real" 2>/dev/null || echo 644)
    local cur="" curssl=0 body=""
    while IFS= read -r rec; do
      case ${rec:0:1} in
        V)
          IFS=$'\037' read -r _ _ v_addr v_name v_alias v_ssl v_cert v_key v_doc <<<"$rec"
          cur=$v_name; curssl=$v_ssl; body="" ;;
        B) body+=${rec#B$'\t'}$'\n' ;;
        E)
          if [[ -z $cur ]]; then
            warn "${real}: a <VirtualHost $v_addr> without ServerName is left alone"
            src_other[$real]=$(( src_other[$real] + 1 )); continue
          fi
          vh_of_src[$real]+="$cur "
          [[ " ${names[*]} " == *" $cur "* ]] || names+=("$cur")
          src_of[$cur]+="$real "
          [[ -n $v_alias ]] && aliases_of[$cur]=$(printf '%s\n' ${aliases_of[$cur]:-} $v_alias | awk '!seen[$0]++' | paste -sd' ')
          [[ -n $v_doc && -z ${root_of[$cur]:-} ]] && root_of[$cur]=$v_doc
          if (( curssl )); then
            s_n[$cur]=$(( ${s_n[$cur]:-0} + 1 )); s_addr[$cur]=$v_addr; s_body[$cur]=${body%$'\n'}
            s_cert[$cur]=$v_cert; s_key[$cur]=$v_key
          else
            h_n[$cur]=$(( ${h_n[$cur]:-0} + 1 )); h_addr[$cur]=$v_addr; h_body[$cur]=${body%$'\n'}
          fi ;;
        O) src_other[$real]=$(( src_other[$real] + ${rec##*$'\t'} )) ;;
      esac
    done < <(parse_vhosts "$real")
  done < <(apache_sources)

  # --- choose
  local pick=() n f bad
  if (( all )); then pick=("${names[@]}"); else pick=("${want[@]}"); fi
  local -A chosen=()
  for n in "${pick[@]}"; do
    [[ -n ${src_of[$n]:-} ]] || { warn "$n: no enabled <VirtualHost> with that ServerName"; continue; }
    if site_exists "$n"; then warn "$n is already managed; skipped"; continue; fi
    if (( ${h_n[$n]:-0} > 1 || ${s_n[$n]:-0} > 1 )); then warn "$n has more than one HTTP or HTTPS block; skipped (merge them by hand first)"; continue; fi
    bad=""
    for f in ${src_of[$n]}; do (( src_other[$f] )) && bad=$f; done
    if [[ -n $bad ]]; then warn "$n: $bad also holds other directives; skipped (move them out first)"; continue; fi
    chosen[$n]=1
  done
  # a file can only be retired when every site in it is adopted
  local again=1
  while (( again )); do
    again=0
    for n in "${!chosen[@]}"; do
      for f in ${src_of[$n]}; do
        local m
        for m in ${vh_of_src[$f]}; do
          if [[ -z ${chosen[$m]:-} ]]; then
            warn "$n shares $f with $m, which is not being adopted; skipped (adopt them together)"
            unset "chosen[$n]"; again=1; continue 3
          fi
        done
      done
    done
  done
  (( ${#chosen[@]} )) || die "nothing to adopt"
  local sel; sel=$(printf '%s\n' "${!chosen[@]}" | sort)
  local files; files=$(for n in $sel; do printf '%s\n' ${src_of[$n]}; done | sort -u)

  info "adopting $(wc -l <<<"$sel") site(s) from $(wc -l <<<"$files") file(s):"
  for n in $sel; do
    local what="" port
    [[ -n ${h_addr[$n]:-} ]] && what+="http(${h_addr[$n]}) "
    [[ -n ${s_addr[$n]:-} ]] && what+="https(${s_addr[$n]}) "
    printf '  %-45s %s%s\n' "$n" "$what" "${aliases_of[$n]:+ aliases: ${aliases_of[$n]}}"
  done
  echo "files taken out of service (kept in $BACKUP_DIR/$STAMP-adopted/):"
  printf '  %s\n' $files

  # --- before
  local before_names="" before=""
  if ! (( DRY_RUN )); then
    before_names=$(vhost_names)
    before=$(for n in $sel; do
      if [[ -n ${h_addr[$n]:-} ]]; then echo "http://$n:${h_addr[$n]##*:}/ ${h_addr[$n]##*:} $n"; fi
      if [[ -n ${s_addr[$n]:-} ]]; then echo "https://$n:${s_addr[$n]##*:}/ ${s_addr[$n]##*:} $n"; fi
    done | probe_urls)
  fi
  backup_tree adopt
  trap 'restore_tree' ERR

  # --- take the old files out of service
  local keep="$BACKUP_DIR/$STAMP-adopted"
  for f in $files; do
    for link in ${links_of[$f]}; do
      [[ $link == "$f" ]] && continue
      if (( DRY_RUN )); then echo "${C_DIM}+ rm $link${C_RST}"; else rm -f "$link"; fi
    done
    if (( DRY_RUN )); then echo "${C_DIM}+ mv $f $keep/${C_RST}"
    else mkdir -p "$keep"; mv "$f" "$keep/$(basename "$(dirname "$f")")--$(basename "$f")"; fi
  done

  # --- one managed file per site
  BATCH=1
  for n in $sel; do
    reset_site
    DOMAIN=$n; SERVER=apache; TYPE=custom; CREATED=$(date -Iseconds)
    ALIASES=${aliases_of[$n]:-}
    ROOT=${root_of[$n]:-}
    BODY_HTTP=${h_body[$n]:-}; [[ -n ${h_addr[$n]:-} ]] && HTTP_ADDR=${h_addr[$n]}
    [[ -n ${h_addr[$n]:-} && -z $BODY_HTTP ]] && BODY_HTTP="    # (no directives)"
    if [[ -n ${s_addr[$n]:-} ]]; then
      SSL=1; HTTPS_ADDR=${s_addr[$n]}; BODY_HTTPS=${s_body[$n]}
      CERT_FILE=${s_cert[$n]}; CERT_KEY=${s_key[$n]}
      [[ $CERT_FILE == "$LE_DIR/live/$n/fullchain.pem" ]] && CERT_FILE=""
      [[ $CERT_KEY == "$LE_DIR/live/$n/privkey.pem" ]] && CERT_KEY=""
    fi
    grep -qE " default $n\$" <<<"$before_names" && DEFAULT_SITE=1
    [[ $HTTP_ADDR == "*:80" ]] && HTTP_ADDR=""
    [[ $HTTPS_ADDR == "*:443" ]] && HTTPS_ADDR=""
    apply_site
    save_site
    local m=644 sf
    for sf in ${src_of[$n]}; do [[ ${mode_of[$sf]} == 640 || ${mode_of[$sf]} == 600 ]] && m=640; done
    (( DRY_RUN )) || chmod "$m" "$(conf_path apache "$n")"
  done
  BATCH=0

  if (( DRY_RUN )); then trap - ERR; info "dry run: nothing was changed"; return 0; fi
  local out
  if ! out=$(config_test apache); then
    printf '%s\n' "$out" >&2; restore_tree; trap - ERR; die "configuration test failed; everything was put back"
  fi
  local after_names; after_names=$(vhost_names)
  # one name list per site: an alias that was on only one of a site's blocks
  # (e.g. HTTP) is now on both; that is the only difference allowed
  local known; known=$(for n in $sel; do printf '%s\n' ${aliases_of[$n]:-}; done)
  local extra; extra=$(diff <(echo "$before_names") <(echo "$after_names") | sed -n 's/^> //p' |
    awk -v k="$known" 'BEGIN{split(k,a,"\n"); for(i in a) ok[a[i]]=1} !($2=="alias" && ok[$3])' || true)
  local missing; missing=$(diff <(echo "$before_names") <(echo "$after_names") | sed -n 's/^< //p' || true)
  if [[ -n $extra || -n $missing ]]; then
    [[ -n $missing ]] && printf 'no longer served: %s\n' $missing >&2
    [[ -n $extra ]] && printf '%s\n' "$extra" | sed 's/^/newly served: /' >&2
    restore_tree; trap - ERR; die "Apache would serve a different set of names; everything was put back"
  fi
  reload_server apache
  sleep 2
  local after; after=$(for n in $sel; do ( load_site "$n"; site_urls ); done | probe_urls)
  if ! compare_probes "$before" "$after"; then
    restore_tree; trap - ERR; die "some sites answered differently; everything was put back"
  fi
  trap - ERR
  info "adopted $(wc -l <<<"$sel") site(s); each is now $(dirname "$(conf_path apache x)")/<domain>.conf"
}

# ---------------------------------------------------------------------------
# relocate: move web files to another directory and update every site using them
# ---------------------------------------------------------------------------
APP_FILE_GLOBS=(--include='*.php' --include='*.inc' --include='*.ini' --include='.user.ini' --include='.htaccess'
                --include='*.json' --include='.env' --include='*.env' --include='*.conf' --include='*.yml' --include='*.yaml'
                --include='*.xml' --include='*.cfg' --include='*.config')

app_files_with() {   # app_files_with DIR PREFIX
  grep -rlIF "${APP_FILE_GLOBS[@]}" --exclude-dir=uploads --exclude-dir=cache -e "$2" "$1" 2>/dev/null || true
}

cmd_relocate() {
  [[ $# -ge 2 ]] || die "usage: $PROG relocate <old-dir> <new-dir> [--fix-app-paths] [--rewrite-confs] [--rewrite-units] [--delete-old]"
  local old=${1%/} new=${2%/} fix=0 confs=0 units=0 del=0; shift 2
  while (($#)); do
    case $1 in
      --rewrite-units) units=1 ;;
      --fix-app-paths) fix=1 ;;
      --rewrite-confs) confs=1 ;;
      --delete-old) del=1 ;;
      *) die "unknown option: $1" ;;
    esac; shift
  done
  [[ $old == /* && $new == /* ]] || die "use absolute paths"
  [[ -d $old ]] || die "$old is not a directory"
  [[ -e $new ]] && die "$new already exists"
  [[ $new == "$old"/* ]] && die "$new is inside $old"
  need_root

  local sites=() d
  for d in $(all_sites); do
    ( load_site "$d"; [[ $(replace_path "$ROOT$BODY_HTTP$BODY_HTTPS" "$old" "$new") != "$ROOT$BODY_HTTP$BODY_HTTPS" ]] ) && sites+=("$d")
  done
  local others=() f
  while read -r _ _ f; do
    [[ -f $f ]] || continue
    grep -qF "$old" "$f" && others+=("$f")
  done < <(apache_sources)
  for d in "${sites[@]}"; do others=("${others[@]/"$(conf_path apache "$d")"}"); done
  mapfile -t others < <(printf '%s\n' "${others[@]}" | grep . | sort -u)

  info "relocating $old -> $new ($(du -sh "$old" 2>/dev/null | cut -f1))"
  echo "sites using it (${#sites[@]}):"; printf '  %s\n' "${sites[@]:-(none)}"
  if (( ${#others[@]} )); then
    if (( confs )); then echo "other Apache files to update:"; else echo "other Apache files that mention it (not changed; add --rewrite-confs):"; fi
    printf '  %s\n' "${others[@]}"
  fi
  local unit_files=() unit_names=() u un
  while IFS=$'\t' read -r un u; do
    grep -qF "$old" "$u" 2>/dev/null || continue
    unit_files+=("$u"); unit_names+=("$un")
  done < <(svc_files)
  if (( ${#unit_files[@]} )); then
    if (( units )); then echo "services that run from it (rewritten and restarted):"
    else echo "services that run from it (not changed; add --rewrite-units):"; fi
    printf '  %s\n' "${unit_files[@]}"
  fi
  local apps; apps=$(app_files_with "$old" "$old")
  if [[ -n $apps ]]; then
    if (( fix )); then echo "app files with the path written in them, fixed in the copy:"
    else echo "app files with the path written in them (not changed; add --fix-app-paths):"; fi
    sed "s|^$old|  $new|" <<<"$apps"
  fi
  (( DRY_RUN )) && { info "dry run: nothing was changed"; return 0; }
  (( ${#sites[@]} + ${#others[@]} )) || warn "no site uses $old; only copying"
  confirm "Copy $old to $new and switch the sites over?" || die "aborted"

  # services restarted from the new place may sit behind any site: check them all
  local probe_sites=("${sites[@]}")
  if (( units && ${#unit_files[@]} )); then mapfile -t probe_sites < <(all_sites); fi
  local before; before=$(for d in "${probe_sites[@]}"; do ( load_site "$d"; (( ENABLED )) && site_urls; true ); done | probe_urls)

  local parent; parent=$(dirname "$new")
  [[ -d $parent ]] || { mkdir -p "$parent"; chmod 755 "$parent"; }
  copy_tree() {
    if have rsync; then rsync -aHAX --numeric-ids --delete "$old/" "$new/"
    else mkdir -p "$new"; cp -a "$old/." "$new/"; fi
  }
  info "copying files"
  copy_tree
  info "copying changes made meanwhile"
  copy_tree
  chmod --reference="$old" "$new"

  if (( fix )) && [[ -n $apps ]]; then
    local rel
    while read -r f; do
      rel=${f#"$old"/}
      mkdir -p "$BACKUP_DIR/$STAMP-app-files/$(dirname "$rel")"
      cp -a "$new/$rel" "$BACKUP_DIR/$STAMP-app-files/$rel"
      HM_OLD=$old HM_NEW=$new perl -pi -e 's{\Q$ENV{HM_OLD}\E(?=[/"\x27 :;>]|$)}{$ENV{HM_NEW}}g' "$new/$rel"
    done <<<"$apps"
    info "fixed $(wc -l <<<"$apps") app file(s); originals in $BACKUP_DIR/$STAMP-app-files/"
  fi

  backup_tree relocate
  local unit_keep="$BACKUP_DIR/$STAMP-units" services=()
  for un in "${unit_names[@]}"; do
    [[ " ${services[*]} " == *" $un "* ]] || services+=("$un")
  done
  restore_units() {
    (( units )) || return 0
    local f
    for f in "${unit_files[@]}"; do [[ -f $unit_keep/${f//\//_} ]] && cp -a "$unit_keep/${f//\//_}" "$f"; done
    if (( ${#unit_files[@]} )) && [[ $FAKE != 1 ]]; then
      svc_reread; local v; for v in "${services[@]}"; do svc_restart "$v" || true; done
    fi
  }
  fail_back() { restore_tree; restore_units; rm -rf -- "$new"; die "$1; everything was put back and $new removed"; }
  BATCH=1
  for d in "${sites[@]}"; do
    load_site "$d"
    ROOT=$(replace_path "$ROOT" "$old" "$new")
    BODY_HTTP=$(replace_path "$BODY_HTTP" "$old" "$new")
    BODY_HTTPS=$(replace_path "$BODY_HTTPS" "$old" "$new")
    apply_site || fail_back "could not update $d"
    save_site
  done
  BATCH=0
  if (( confs )); then
    for f in "${others[@]}"; do
      backup_file "$f"
      local t; t=$(replace_path "$(<"$f")" "$old" "$new")
      printf '%s\n' "$t" > "$f"
    done
  fi
  local out
  out=$(config_test apache) || { printf '%s\n' "$out" >&2; fail_back "configuration test failed"; }
  reload_server apache
  if (( units && ${#unit_files[@]} )); then
    mkdir -p "$unit_keep"
    for u in "${unit_files[@]}"; do
      cp -a "$u" "$unit_keep/${u//\//_}"
      local t; t=$(replace_path "$(<"$u")" "$old" "$new")
      printf '%s\n' "$t" > "$u"
    done
    svc_reread
    local v
    for v in "${services[@]}"; do
      svc_restart "$v" || fail_back "$v did not restart"
    done
    sleep 3
    if [[ $FAKE != 1 ]]; then
      for v in "${services[@]}"; do svc_active "$v" || fail_back "$v is not running after the move"; done
    fi
    info "services moved: ${services[*]}"
  fi
  sleep 2
  # restarted apps can take a while to start: keep checking for up to HM_WAIT seconds
  local waited=0 limit=${HM_WAIT:-90} after
  while :; do
    after=$(for d in "${probe_sites[@]}"; do ( load_site "$d"; (( ENABLED )) && site_urls; true ); done | probe_urls)
    compare_probes "$before" "$after" 2>/dev/null && break
    if (( ! units || ${#unit_files[@]} == 0 || waited >= limit )); then
      compare_probes "$before" "$after" || true
      fail_back "some sites answered differently"
    fi
    sleep 5; waited=$(( waited + 8 ))
    info "waiting for the restarted services to answer (${waited}s)"
  done
  info "done: ${#sites[@]} site(s) now use $new"
  if (( del )); then
    run rm -rf -- "$old"; info "removed $old"
  else
    info "the old copy is still in $old; remove it once you're happy (or rerun with --delete-old)"
  fi
}

usage() {
  cat <<EOF
$PROG $VERSION - easy nginx/Apache hosting on a Linux server

Usage: $PROG [--dry-run] [-y] <command> [arguments]

Sites
  create <domain> [options]       add a site (static by default)
      --server nginx|apache       web server (auto-detected when only one is installed)
      --root DIR                  web root (default $WWW/<domain>)
      --php                       PHP site through php-fpm   (--php-sock PATH to choose the socket)
      --proxy PORT|URL            reverse proxy to an app, e.g. --proxy 3000
      --redirect-to URL           redirect every request to another site
      --alias NAME                extra name (repeatable); www.<domain> is added for apex domains
      --no-www                    don't add www.<domain>
      --ssl [--email ADDR]        get a Let's Encrypt certificate and enable HTTPS
      --max-body SIZE             upload limit, e.g. 64M
      --disabled                  write the config but don't enable it
  update <domain> [options]       change a site (same options as create; --max-body none clears it)
  rename <old> <new>              move a site to a new domain name
      --redirect                  keep <old> as a permanent redirect to <new>
      --wait-dns                  wait until the new names resolve, then rename (run it in the
                                  background); --expect-ip IP, --timeout DAYS (default 14)
      --drop-aliases              don't carry the extra names over
      --rewrite-units             also replace the host name in service definitions
                                  (systemd, OpenRC, SysV, runit, s6, dinit), restart them
      --keep-root                 don't move $WWW/<old> to $WWW/<new>
      --delete-old-cert           delete <old>'s certificate
  alias <domain> add|remove NAME..  add or remove extra names
  enable <domain> | disable <domain>
  remove <domain> [--purge] [--delete-cert]
  list                            all managed sites
  info <domain>                   settings, config path, certificate expiry
  show <domain>                   print the generated server config
  adopt --all | <domain>...       take over existing (hand-made) Apache sites: one file per
                                  site, directives kept as they are (Apache only)
  relocate <old-dir> <new-dir>    copy web files elsewhere and switch every site using them
      --fix-app-paths             also rewrite the path inside app files (.php, .ini, .env, ...)
      --rewrite-confs             also rewrite other Apache files that mention it
      --rewrite-units             also rewrite services that run from it (any init), restart them
      --delete-old                delete <old-dir> after a successful switch
  check [--save F] [--compare F]  how each site answers (status, redirect), or compare with F
  default <domain>                the site that answers names no other site claims

Certificates (Let's Encrypt via certbot)
  ssl <domain> [--staging] [--email ADDR]   enable HTTPS
  ssl <domain> --off              back to plain HTTP
      --expect-ip IP              only certify the names that already resolve to IP
                                  (the rest are added by running ssl again later)
  renew [--test]                  renew certificates (certbot also does this on a timer)
  certs                           list certificates

Server
  install nginx|apache|certbot|php  install packages
  doctor                          check what is installed and listening
  test                            test the server configuration
  reload                          reload the web servers
  config [server|email [VALUE]]   show or set defaults

Global options
  --dry-run                       show what would change, change nothing
  -y, --yes                       don't ask for confirmation
  --dns-server IP                 check DNS with this server (e.g. 1.1.1.1) instead of the
                                  system resolver, when that still remembers an old answer

Examples
  sudo $PROG create example.com --ssl --email me@example.com
  sudo $PROG create app.example.com --proxy 3000 --ssl
  sudo $PROG create blog.example.com --php --server apache
  sudo $PROG rename example.com example.org --redirect
EOF
}

main() {
  # shellcheck disable=SC1090
  [[ -r $CONFIG_FILE ]] && source "$CONFIG_FILE"
  init_system >/dev/null   # detect once; later $(init_system) calls reuse it
  export HM_INIT=$INIT_SYSTEM
  while (($#)); do
    case $1 in
      --dry-run|-n) DRY_RUN=1; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      --dns-server) [[ -n ${2:-} ]] || die "--dns-server needs an address"
        DNS_SERVER=$2; export HM_DNS_SERVER=$2; shift 2 ;;
      *) break ;;
    esac
  done
  if [[ -n $DNS_SERVER ]] && ! have dig; then die "--dns-server needs dig (apt install bind9-dnsutils)"; fi
  local cmd=${1:-help}; shift || true
  # allow global options after the command too
  local args=() a
  for a in "$@"; do
    case $a in
      --dry-run) DRY_RUN=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      *) args+=("$a") ;;
    esac
  done
  set -- "${args[@]+"${args[@]}"}"
  case $cmd in
    create|add|new) cmd_create "$@" ;;
    update|edit|set) cmd_update "$@" ;;
    rename|move|mv) cmd_rename "$@" ;;
    alias|aliases) cmd_alias "$@" ;;
    enable) cmd_enable_disable 1 "$@" ;;
    disable) cmd_enable_disable 0 "$@" ;;
    remove|rm|delete) cmd_remove "$@" ;;
    list|ls) cmd_list ;;
    info) cmd_info "$@" ;;
    show|cat) cmd_show "$@" ;;
    ssl|https|cert) cmd_ssl "$@" ;;
    renew) cmd_renew "$@" ;;
    certs|certificates) cmd_certs ;;
    install) cmd_install "$@" ;;
    doctor) cmd_doctor ;;
    test) cmd_test ;;
    reload) cmd_reload ;;
    config) cmd_config "$@" ;;
    adopt|import) cmd_adopt "$@" ;;
    relocate) cmd_relocate "$@" ;;
    check) cmd_check "$@" ;;
    default) cmd_default "$@" ;;
    help|-h|--help) usage ;;
    version|-V|--version) echo "$PROG $VERSION" ;;
    *) die "unknown command '$cmd' (see: $PROG help)" ;;
  esac
}

main "$@"
