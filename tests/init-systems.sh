#!/usr/bin/env bash
# Runs hosting-manager for real under OpenRC (Alpine), s6 (Alpine), SysV init
# (Debian) and runit (Void) in throwaway Docker containers: installs nginx,
# creates a site, adds an alias, and checks both names answer.
#   sudo bash tests/init-systems.sh [openrc|s6|sysv|runit ...]
# Images that weren't on the machine before are removed afterwards.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
command -v docker >/dev/null || { echo "docker is needed" >&2; exit 2; }
declare -A IMAGE=([openrc]=alpine:3.20 [s6]=alpine:3.20 [sysv]=debian:12-slim [runit]=ghcr.io/void-linux/void-glibc:latest)
inits=("$@"); (( ${#inits[@]} )) || inits=(openrc s6 sysv runit)
before=$(docker images --format '{{.Repository}}:{{.Tag}}')

inside=$(cat <<'SH'
set -e
init=$1
case $init in
  openrc) apk add -q bash perl openssl curl openrc procps >/dev/null
          mkdir -p /run/openrc; touch /run/openrc/softlevel; openrc default >/dev/null 2>&1 || true ;;
  s6)     apk add -q bash perl openssl curl s6 procps nginx >/dev/null
          mkdir -p /run/service /etc/s6/sv/nginx /run/nginx
          printf '#!/bin/sh\nexec nginx -g "daemon off;"\n' > /etc/s6/sv/nginx/run; chmod +x /etc/s6/sv/nginx/run
          (s6-svscan /run/service >/dev/null 2>&1 &); sleep 1 ;;
  sysv)   export DEBIAN_FRONTEND=noninteractive
          apt-get -qq update >/dev/null; apt-get -qq install -y perl openssl curl procps >/dev/null 2>&1 ;;
  runit)  xbps-install -Syu xbps >/dev/null 2>&1 || true
          xbps-install -Sy bash perl openssl curl procps-ng runit shadow >/dev/null 2>&1
          mkdir -p /run/runit; [ -d /var/service ] || { rm -f /var/service; mkdir -p /var/service; }
          (runsvdir /var/service >/dev/null 2>&1 &); sleep 1 ;;
esac
hm() { bash /hm/hosting-manager.sh "$@"; }
echo "detected: $(hm doctor | sed -n 's/^init *//p')"
hm install nginx >/dev/null 2>&1 || { [ "$init" = s6 ] || exit 1; }
sleep 2
hm -y create a.test --no-www
mkdir -p /var/www/a.test; echo "hello-$init" > /var/www/a.test/index.html
hm alias a.test add b.test
sleep 2
for h in a.test b.test; do
  r=$(curl -s -m 5 -H "Host: $h" http://127.0.0.1/)
  [ "$r" = "hello-$init" ] || { echo "$h answered: $r"; exit 1; }
done
SH
)
fail=0
for i in "${inits[@]}"; do
  img=${IMAGE[$i]:?unknown init $i}
  if out=$(timeout 900 docker run --rm -v "$HERE:/hm:ro" "$img" sh -c "$inside" sh "$i" 2>&1); then
    echo "ok   $i ($img): $(grep -m1 '^detected' <<<"$out")"
  else
    echo "FAIL $i ($img)"; tail -15 <<<"$out" | sed 's/^/     /'; fail=1
  fi
done
for img in $(printf '%s\n' "${inits[@]}" | while read -r i; do echo "${IMAGE[$i]}"; done | sort -u); do
  grep -qxF "$img" <<<"$before" || docker rmi "$img" >/dev/null 2>&1 || true
done
exit $fail
