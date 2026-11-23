#!/usr/bin/env bash
# hosting-manager: create and manage nginx/Apache sites, Let's Encrypt certificates
# and domain changes on a Linux web server.
#
# https://github.com/nano-rex/hosting-manager  (GPL-3.0)

set -Eeuo pipefail

VERSION="0.1.0"
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
ASSUME_YES=0

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
  elif [[ -d $ETC/nginx/conf.d ]]; then echo confd
  else echo none; fi
}

apache_layout() {
  if [[ -d $ETC/apache2 ]]; then echo debian
  elif [[ -d $ETC/httpd ]]; then echo confd
  else echo none; fi
}

apache_service() { [[ $(apache_layout) == confd ]] && echo httpd || echo apache2; }

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
      else echo "$ETC/nginx/conf.d/$domain.conf"; fi ;;
    apache)
      if [[ $(apache_layout) == debian ]]; then echo "$ETC/apache2/sites-available/$domain.conf"
      else echo "$ETC/httpd/conf.d/$domain.conf"; fi ;;
  esac
}

enabled_link() {
  local server=$1 domain=$2
  case $server in
    nginx) echo "$ETC/nginx/sites-enabled/$domain.conf" ;;
    apache) echo "$ETC/apache2/sites-enabled/$domain.conf" ;;
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
STATE_KEYS=(DOMAIN SERVER TYPE ROOT TARGET PHP_SOCK ALIASES SSL ENABLED MAX_BODY CREATED)

reset_site() {
  DOMAIN=""; SERVER=""; TYPE="static"; ROOT=""; TARGET=""; PHP_SOCK=""
  ALIASES=""; SSL=0; ENABLED=1; MAX_BODY=""; CREATED=""
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
}

save_site() {
  local out="" k
  for k in "${STATE_KEYS[@]}"; do
    out+=$(printf '%s=%q' "$k" "${!k}")$'\n'
  done
  write_file "$(site_file "$DOMAIN")" "# $PROG site state; change it with $PROG, not by hand
${out%$'\n'}"
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

    ssl_certificate $LE_DIR/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key $LE_DIR/live/$DOMAIN/privkey.pem;
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
  local f="$ETC/nginx/conf.d/hosting-manager.conf"
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

render_apache() {
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

<VirtualHost *:80>
$names
$acme
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
</VirtualHost>

<IfModule mod_ssl.c>
<VirtualHost *:443>
$names
    SSLEngine on
    SSLCertificateFile $LE_DIR/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile $LE_DIR/live/$DOMAIN/privkey.pem
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

<VirtualHost *:80>
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
  local mods=(rewrite alias)
  (( SSL )) && mods+=(ssl headers)
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

reload_server() {
  local svc
  svc=$(server_service "$1")
  if have systemctl && [[ -d /run/systemd/system ]]; then
    run systemctl reload "$svc" || run systemctl restart "$svc"
  else
    run service "$svc" reload
  fi
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

  if [[ $server == nginx ]]; then
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
    remove_file "$(enabled_link "$server" "$DOMAIN")"
  fi
  remove_file "$path"
  remove_file "$path.disabled"
}

# ---------------------------------------------------------------------------
# Certificates
# ---------------------------------------------------------------------------
check_dns() {
  [[ $FAKE == 1 ]] && return 0
  local name bad=()
  for name in "$@"; do
    getent ahosts "$name" >/dev/null 2>&1 || bad+=("$name")
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
  check_dns $(server_names) || return 1
  for name in $(server_names); do args+=(-d "$name"); done
  if [[ -n $EMAIL ]]; then args+=(--email "$EMAIL")
  else args+=(--register-unsafely-without-email); fi
  (( staging )) && args+=(--staging)
  info "requesting a Let's Encrypt certificate for: $(server_names)"
  run certbot certonly --webroot -w "$ACME_ROOT" --cert-name "$DOMAIN" \
    --non-interactive --agree-tos --keep-until-expiring \
    --deploy-hook "systemctl reload $(server_service "$SERVER")" "${args[@]}"
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
  [[ -n $ROOT ]] && placeholder_page "$ROOT" "$DOMAIN"
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
      printf '%-32s %-7s %-9s %-5s %-8s %s\n' "$DOMAIN" "$SERVER" "$TYPE" "$ssl" "$st" "${ROOT:-$TARGET}"
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
  remove_file "$(site_file "$DOMAIN")"
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
  [[ $# -ge 2 ]] || die "usage: $PROG rename <old-domain> <new-domain> [--redirect] [--keep-root] [--delete-old-cert]"
  local old=${1,,} new=${2,,} redirect=0 keep_root=0 delcert=0; shift 2
  while (($#)); do
    case $1 in
      --redirect) redirect=1 ;;
      --keep-root) keep_root=1 ;;
      --delete-old-cert) delcert=1 ;;
      --email) EMAIL=$2; shift ;;
      *) die "unknown option: $1" ;;
    esac; shift
  done
  check_domain "$new"
  need_root
  load_site "$old"
  site_exists "$new" && die "$new already exists"

  local old_ssl=$SSL old_root=$ROOT old_aliases=$ALIASES a new_aliases=()
  for a in $old_aliases; do
    if [[ $a == "www.$old" ]]; then new_aliases+=("www.$new")
    elif [[ $a == *".$old" ]]; then new_aliases+=("${a%".$old"}.$new")
    else new_aliases+=("$a"); fi
  done

  info "renaming $old -> $new"
  # 1. the new site, plain HTTP first so certbot can validate it
  DOMAIN=$new; ALIASES="${new_aliases[*]}"; SSL=0
  if [[ -n $old_root && $old_root == "$WWW/$old" && $keep_root == 0 ]]; then
    ROOT="$WWW/$new"
    if [[ -d $old_root ]]; then
      [[ -e $ROOT ]] && die "$ROOT already exists; use --keep-root or move it away"
      if (( redirect )); then run cp -a "$old_root" "$ROOT"; else run mv "$old_root" "$ROOT"; fi
    fi
  fi
  apply_site
  save_site

  if (( old_ssl )); then
    if issue_cert; then SSL=1; apply_site; save_site
    else warn "$new is on plain HTTP for now; run '$PROG ssl $new' once its DNS points here"; fi
  fi
  local new_url
  new_url=$(site_url)

  # 2. the old name: redirect to the new one, or remove it
  ( load_site "$old"
    unapply_site
    if (( redirect )); then
      TYPE=redirect; TARGET=$new_url; ROOT=""; PHP_SOCK=""
      apply_site; save_site
      info "$old now redirects to $new_url"
    else
      remove_file "$(site_file "$old")"
      reload_server "$SERVER"
      if (( delcert )) && cert_exists "$old"; then run certbot delete --non-interactive --cert-name "$old"; fi
    fi )
  if (( redirect )) && [[ $old_root == "$WWW/$old" && $keep_root == 0 && -d $old_root ]]; then
    info "the old files are still in $old_root (remove them when you no longer need them)"
  fi
  info "done: $new_url"
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
  [[ $# -ge 1 ]] || die "usage: $PROG ssl <domain> [--off] [--staging] [--email ADDR]"
  local domain=${1,,} off=0 staging=0; shift
  while (($#)); do
    case $1 in
      --off) off=1 ;;
      --staging) staging=1 ;;
      --email) EMAIL=$2; shift ;;
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
  for s in nginx apache; do server_installed "$s" && reload_server "$s"; done
  return 0
}

cmd_doctor() {
  local s ok="${C_GRN}ok${C_RST}" no="${C_YLW}missing${C_RST}"
  echo "${C_BLD}$PROG $VERSION${C_RST}"
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
  else die "no supported package manager (apt, dnf, yum, pacman)"; fi
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
      *) die "don't know how to install '$what' (choose nginx, apache, certbot, php)" ;;
    esac
  done
  case $pm in
    apt) run apt-get update; run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
    dnf|yum) run "$pm" install -y "${pkgs[@]}" ;;
    pacman) run pacman -S --needed --noconfirm "${pkgs[@]}" ;;
  esac
  if have systemctl; then
    for what in "$@"; do
      case $what in
        nginx) run systemctl enable --now nginx ;;
        apache) run systemctl enable --now "$(apache_service)" ;;
        php) local u; u=$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | sort -V | tail -1)
             if [[ -n $u ]]; then run systemctl enable --now "$u"; fi ;;
      esac
    done
  fi
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
      --keep-root                 don't move $WWW/<old> to $WWW/<new>
      --delete-old-cert           delete <old>'s certificate
  alias <domain> add|remove NAME..  add or remove extra names
  enable <domain> | disable <domain>
  remove <domain> [--purge] [--delete-cert]
  list                            all managed sites
  info <domain>                   settings, config path, certificate expiry
  show <domain>                   print the generated server config

Certificates (Let's Encrypt via certbot)
  ssl <domain> [--staging] [--email ADDR]   enable HTTPS
  ssl <domain> --off              back to plain HTTP
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
  while (($#)); do
    case $1 in
      --dry-run|-n) DRY_RUN=1; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      *) break ;;
    esac
  done
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
    doctor|check) cmd_doctor ;;
    test) cmd_test ;;
    reload) cmd_reload ;;
    config) cmd_config "$@" ;;
    help|-h|--help) usage ;;
    version|-V|--version) echo "$PROG $VERSION" ;;
    *) die "unknown command '$cmd' (see: $PROG help)" ;;
  esac
}

main "$@"
