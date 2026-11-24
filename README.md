# hosting-manager

Host websites on a Linux server without hand-writing web server configs.
One command creates an nginx or Apache site, gets a Let's Encrypt certificate,
moves a site to a new domain, or adds a `www.` name.

- Static sites, PHP sites (php-fpm), reverse proxies to an app (Node, Python, Docker…) and redirects
- HTTPS with Let's Encrypt, including automatic renewal
- Rename a site to a new domain, optionally keeping the old one as a redirect
- Works with nginx and Apache, on Debian/Ubuntu, RHEL/Fedora/Rocky, Arch, Alpine, Void,
  openSUSE and Gentoo style layouts
- Works with any common init system: systemd, OpenRC, runit, s6 (plain or s6-rc), dinit and
  SysV init (see [Init systems](#init-systems))
- Every change is checked with `nginx -t` / `apachectl configtest` first; if the check fails,
  the previous config is put back and nothing is reloaded
- `--dry-run` shows exactly what would be written and run
- Takes over sites you configured by hand (`adopt`): one file per site, directives kept as they are
- Moves web files to another folder (e.g. out of `/home`) and switches every site that uses them
  (`relocate`), checking that each site answers the same before and after

## Setup

### 1. Install the script

It's a single Bash script with nothing to build:

```bash
git clone https://github.com/nano-rex/hosting-manager.git
cd hosting-manager
sudo install -m 755 hosting-manager.sh /usr/local/bin/hosting-manager
```

### 2. Install a web server and certbot

If they aren't installed yet, hosting-manager can do it (apt, dnf, yum, pacman, apk, xbps,
zypper or emerge). It also enables and starts the services with your init system and opens
ports 80/443 if `ufw` is active:

```bash
sudo hosting-manager install nginx certbot        # or: apache certbot
sudo hosting-manager install php                  # only for PHP sites
hosting-manager doctor                            # check what's installed and listening
```

### 3. Point your domain at the server

In your DNS provider, create an `A` record (and `AAAA` for IPv6) for `example.com` **and**
`www.example.com` pointing at the server's public IP. Certificates can only be issued once
DNS points here; hosting-manager checks this before calling certbot.

### 4. (Optional) set defaults

```bash
sudo hosting-manager config email you@example.com   # used for Let's Encrypt expiry notices
sudo hosting-manager config server nginx            # needed only if nginx AND Apache are installed
```

## How-to guides

### Host a static website

```bash
sudo hosting-manager create example.com --ssl
```

This creates `/var/www/example.com` with a placeholder `index.html`, serves it for
`example.com` and `www.example.com`, gets a certificate and redirects HTTP to HTTPS.
Upload your files into `/var/www/example.com`.

Use another folder with `--root /srv/mysite`. Leave out `www.` with `--no-www`.
Subdomains (`blog.example.com`) don't get a `www.` name automatically.

### Host a PHP site (WordPress, Laravel, …)

```bash
sudo hosting-manager install php
sudo hosting-manager create blog.example.com --php --ssl --max-body 64M
```

The newest php-fpm socket on the machine is found automatically; pick one with
`--php-sock /run/php/php8.2-fpm.sock`. `--max-body` raises the upload limit
(also raise `upload_max_filesize` / `post_max_size` in php.ini). Laravel users:
`--root /var/www/myapp/public`.

### Put an app behind the web server (reverse proxy)

Your app listens on a local port, the web server handles the domain and HTTPS:

```bash
sudo hosting-manager create app.example.com --proxy 3000 --ssl
sudo hosting-manager create api.example.com --proxy http://10.0.0.5:8080 --ssl
```

WebSockets work on nginx. The app receives `X-Forwarded-For` and `X-Forwarded-Proto` headers.

### Turn on HTTPS later

```bash
sudo hosting-manager ssl example.com
sudo hosting-manager ssl example.com --staging   # test against Let's Encrypt staging first
sudo hosting-manager ssl example.com --off       # back to plain HTTP
```

Certificates are issued with certbot's webroot method through a shared folder
(`/var/www/_letsencrypt`), so it works the same for every site type, including proxies.
certbot's own timer renews them and reloads the web server; check with
`sudo hosting-manager renew --test`.

### Change a site's domain name

```bash
sudo hosting-manager rename example.com example.org --redirect
```

- creates `example.org` with the same settings (and `www.example.org` if the old site had `www.`)
- moves `/var/www/example.com` to `/var/www/example.org` (keep it in place with `--keep-root`)
- gets a certificate for the new name if the old site had HTTPS
- with `--redirect`, `example.com` keeps working and sends visitors to `https://example.org`
  (the old files are copied instead of moved); without it the old site is removed
  (`--delete-old-cert` also deletes its certificate)

To switch as soon as DNS is ready, start the rename in the background with `--wait-dns`: it
checks every 5 minutes (until `--timeout DAYS`, default 14) and renames once every new name
resolves, to `--expect-ip IP` if given. If the certificate can't be issued, the new site is removed
again, the old one is left exactly as it was, and it tries again an hour later.

```bash
sudo systemd-run --unit hm-rename-shop hosting-manager rename shop.example.com shop.example.org --wait-dns --delete-old-cert
journalctl -u hm-rename-shop -f
# without systemd:
sudo nohup hosting-manager rename shop.example.com shop.example.org --wait-dns > /var/log/hm-rename-shop.log 2>&1 &
```

`--drop-aliases` leaves the extra names behind; `--rewrite-units` also replaces the host name in
service definitions (e.g. a server that advertises its own name; see [Init systems](#init-systems)),
but not inside paths such as
`/var/www/<old>`, and restarts the running services whose command changed.

Update DNS for the new name **before** renaming, so its certificate can be issued. For an HTTPS
site, `rename` checks that the new names resolve and stops if they don't, so the old name isn't
removed before the new one has a certificate (`--force` renames anyway and leaves the new name on
plain HTTP until `hosting-manager ssl <new>` succeeds). For adopted sites the old name is also
replaced inside their own directives (redirect targets, certbot's `RewriteCond %{SERVER_NAME}`).

### Add or remove extra names

```bash
sudo hosting-manager alias example.com add shop.example.com example.net
sudo hosting-manager alias example.com remove example.net
```

For HTTPS sites the certificate is re-issued to cover the new list of names.

### Redirect a domain somewhere else

```bash
sudo hosting-manager create old-brand.com --redirect-to https://new-brand.com --ssl
```

Paths are kept: `old-brand.com/about` → `https://new-brand.com/about` (301).

### Change a site's settings

`update` takes the same options as `create`:

```bash
sudo hosting-manager update app.example.com --proxy 4000
sudo hosting-manager update example.com --php
sudo hosting-manager update example.com --server apache    # move the site to Apache
sudo hosting-manager update example.com --max-body none
```

### Take a site offline or delete it

```bash
sudo hosting-manager disable example.com    # config kept, site not served
sudo hosting-manager enable example.com
sudo hosting-manager remove example.com                      # files in /var/www are kept
sudo hosting-manager remove example.com --purge --delete-cert  # also delete files and certificate
```

### Take over sites you set up by hand (Apache)

If your Apache sites grew by hand (certbot's `-le-ssl.conf` twins, many sites in one file,
vhosts hidden in `conf-enabled/`), `adopt` gives every site its own file,
`sites-available/<domain>.conf`, holding both its HTTP and HTTPS blocks:

```bash
sudo hosting-manager --dry-run adopt --all     # see the plan first
sudo hosting-manager adopt --all               # or: adopt example.com shop.example.com
```

- The directives inside each `<VirtualHost>` are kept exactly, including its port, so the site
  behaves as before. hosting-manager takes over the names (`ServerName`/`ServerAlias`), the
  certificate lines and the Let's Encrypt validation path.
- The old files are taken out of service and kept in `/etc/hosting-manager/backups/<time>-adopted/`.
- A file that also holds other directives (not just `<VirtualHost>` blocks) is left alone, and so
  are the sites in it. Sites sharing a file are adopted together.
- Before anything is reloaded, `apache2ctl configtest` must pass and `apache2ctl -S` must list
  the same names on the same addresses. After the reload, every site must answer as it did before
  (status code and redirect target, asked through 127.0.0.1). If any check fails, the whole
  `/etc/apache2` tree is restored from a backup taken first.
- The site that answered unknown names before stays the default (its link is named
  `000-<domain>.conf`). Change that later with `hosting-manager default <domain>`.

Adopted sites show up as type `custom`. `alias`, `ssl`, `rename`, `enable`/`disable`, `remove`
and `update --root` work on them; `update --php` / `--proxy` replaces their directives.

To change an adopted site's directives, edit `/etc/hosting-manager/sites/<domain>.http`
(or `.https`) and run `sudo hosting-manager update <domain>`: it rewrites the config,
runs the config test and puts the old file back if the test fails. A redirect to HTTPS that
should work for every name of the site uses the name the visitor asked for, and lets
certificate checks through:

```apache
RewriteEngine on
RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [R=301,L,NE]
```

### Move site files to another folder

`relocate` copies a folder, switches every site whose config mentions it, and checks the sites
answer the same afterwards:

```bash
sudo hosting-manager --dry-run relocate /home/olduser/public_html /var/www/olduser/public_html --fix-app-paths
sudo hosting-manager relocate /home/olduser/public_html /var/www/olduser/public_html --fix-app-paths
```

- Files are copied with `rsync -aHAX` (owners, permissions, ACLs and links kept), then copied
  once more just before the switch to pick up changes made in the meantime.
- Paths are replaced in the site configs, including `open_basedir` and `<Directory>` lines.
- `--fix-app-paths` also replaces the path inside app files in the copy (`.php`, `.ini`,
  `.user.ini`, `.htaccess`, `.env`, `.json`, `.yml`, `.xml`, ...; `uploads/` and `cache/` are skipped).
  The originals are kept in `/etc/hosting-manager/backups/<time>-app-files/`.
- `--rewrite-confs` also updates other Apache files that mention the folder (shown in the dry run).
- `--rewrite-units` also updates the services that run from the folder (systemd
  `WorkingDirectory`/`ExecStart`, OpenRC and runit scripts, ...; see [Init systems](#init-systems))
  and restarts them; if one doesn't come back up, everything is put back.
- If the configuration test fails or a site answers differently, the configs are restored and the
  copy is removed. The old folder is kept until you delete it (or pass `--delete-old`).

### Check that every site still answers

```bash
sudo hosting-manager check --save /root/sites-before.txt
# ... change things ...
sudo hosting-manager check --compare /root/sites-before.txt
```

### Preview a change

Put `--dry-run` anywhere in the command to print the config files and commands without
changing anything (root is not needed):

```bash
hosting-manager --dry-run create example.com --php --ssl
```

## Usage reference

`hosting-manager help` lists every command; `hosting-manager help examples` walks through
real-world scenarios (first site, WordPress, an app behind a proxy, moving domains, DNS that
isn't ready yet, taking over a panel-migrated server, ...), and `hosting-manager help <command>`
shows one command's options together with the scenarios that use it:

```console
$ hosting-manager help alias
Usage
  alias <domain> add|remove NAME..  add or remove extra names

Add www, a second domain or a typo domain to a site
  sudo hosting-manager alias example.com add example.net www.example.net
  sudo hosting-manager alias example.com remove example.net www.example.net
  # HTTPS sites get a certificate covering the new names right away

A site on two domains, only one of which points here yet
  ...
```

```
hosting-manager [--dry-run] [-y] <command> [arguments]
```

| Command | What it does |
|---|---|
| `create <domain> [options]` | Add a site (static unless `--php`, `--proxy` or `--redirect-to` is given) |
| `update <domain> [options]` | Change a site; same options as `create` |
| `rename <old> <new> [--redirect] [--keep-root] [--delete-old-cert] [--drop-aliases] [--rewrite-units] [--wait-dns [--expect-ip IP] [--timeout DAYS]] [--force]` | Move a site to a new domain |
| `alias <domain> add\|remove <name>...` | Add or remove extra names |
| `enable <domain>` / `disable <domain>` | Serve / stop serving a site, keeping its config |
| `remove <domain> [--purge] [--delete-cert]` | Delete a site (`--purge` also deletes its web root) |
| `list` | All managed sites |
| `info <domain>` | Settings, config file path, certificate expiry |
| `show <domain>` | Print the generated nginx/Apache config |
| `adopt --all \| <domain>...` | Take over existing Apache sites: one file per site (Apache only) |
| `relocate <old-dir> <new-dir> [--fix-app-paths] [--rewrite-confs] [--rewrite-units] [--delete-old]` | Copy web files elsewhere and switch the sites using them |
| `check [--save FILE] [--compare FILE] [<domain>...]` | Status and redirect of each site, or compare with a saved run |
| `default <domain>` | The site that answers names no other site claims |
| `ssl <domain> [--staging] [--email ADDR]` | Get a certificate and enable HTTPS |
| `ssl <domain> --off` | Disable HTTPS (certificate kept) |
| `ssl <domain> --expect-ip IP` | Certificate for only the names that already point at IP; the others (e.g. a second domain whose DNS isn't fixed yet) are left out until `ssl` is run again |
| `renew [--test]` | Run `certbot renew` (`--test` = certbot `--dry-run`) |
| `certs` | List certificates |
| `install nginx\|apache\|certbot\|php` | Install packages and start services |
| `doctor` | Show installed servers, certbot, php-fpm, ports 80/443, firewall |
| `test` | Test the web server configuration |
| `reload` | Reload nginx and/or Apache |
| `config [server\|email [VALUE]]` | Show or set defaults |

Options for `create` and `update`:

| Option | Meaning |
|---|---|
| `--server nginx\|apache` | Web server (auto-detected when only one is installed) |
| `--root DIR` | Web root (default `/var/www/<domain>`) |
| `--php` | PHP through php-fpm |
| `--php-sock PATH` | php-fpm socket to use (implies `--php`) |
| `--proxy PORT\|HOST:PORT\|URL` | Reverse proxy; a bare port means `http://127.0.0.1:PORT` |
| `--redirect-to URL` | 301-redirect everything to URL, keeping the path |
| `--alias NAME` | Extra name, repeatable |
| `--no-www` | Don't add `www.<domain>` (on `update`: remove it) |
| `--ssl` | Get a Let's Encrypt certificate and enable HTTPS |
| `--staging` | Use the Let's Encrypt staging server (with `--ssl`) |
| `--email ADDR` | Email for Let's Encrypt |
| `--max-body SIZE` | Upload size limit, e.g. `64M` (`none` clears it on `update`) |
| `--disabled` | Write the config without enabling it (`create` only) |

Global options (before the command): `--dry-run` (change nothing, print everything),
`-y` / `--yes` (don't ask for confirmation), `--dns-server IP` (check DNS with that server,
e.g. `1.1.1.1`, instead of the system resolver: useful right after a DNS change, when the
local resolver or router still remembers the old answer; needs `dig`).

## Where things are

| Path | Contents |
|---|---|
| `/etc/nginx/sites-available/<domain>.conf` (+ link in `sites-enabled`) | nginx site on Debian/Ubuntu |
| `/etc/nginx/conf.d/<domain>.conf` | nginx site on RHEL-style systems (`.conf.disabled` when disabled) |
| `/etc/apache2/sites-available/<domain>.conf` | Apache site on Debian/Ubuntu |
| `/etc/nginx/http.d/<domain>.conf` | nginx site on Alpine |
| `/etc/httpd/conf.d/<domain>.conf` | Apache site on RHEL/Fedora/Arch |
| `/etc/apache2/conf.d/`, `/etc/apache2/vhosts.d/`, `/etc/apache/conf.d/` | Apache site on Alpine, Gentoo, Void |
| `/etc/hosting-manager/sites/<domain>.site` | hosting-manager's record of each site |
| `/etc/hosting-manager/sites/<domain>.http`, `.https` | the kept directives of an adopted site |
| `/etc/hosting-manager/backups/<time>/` | copies of every file before it was changed |
| `/etc/hosting-manager/hosting-manager.conf` | defaults set with `config` |
| `/var/www/_letsencrypt` | shared folder for certificate validation |

If the main `nginx.conf` / `httpd.conf` doesn't read the drop-in folder yet (stock configs on
Void and Arch), hosting-manager adds one `include` line to it, after backing it up.

Generated configs are regenerated from the site record on every change, so make changes
with hosting-manager rather than editing them by hand. Sites you configured yourself are left
alone until you `adopt` them; hosting-manager only touches the sites it manages.

## Init systems

hosting-manager finds the init system from process 1 (override with `HM_INIT=systemd|openrc|
runit|s6|dinit|sysv`; `hosting-manager doctor` shows what it found) and uses it to reload the
web server, to enable and start services in `install`, for certbot's renewal hook, and to
restart the services `--rewrite-units` changes:

| Init | Reload web server | Restart a service | Enable at boot | Service files `--rewrite-units` edits |
|---|---|---|---|---|
| systemd | `systemctl reload` | `systemctl restart` | `systemctl enable --now` | `/etc/systemd/system/*.service`, `*.service.d/*.conf` |
| OpenRC | `rc-service X reload` | `rc-service X restart` | `rc-update add X default` | `/etc/init.d/*`, `/etc/conf.d/*` |
| SysV init | `service X reload` | `service X restart` | `update-rc.d` / `chkconfig` | `/etc/init.d/*`, `/etc/default/*` |
| runit | `sv hup` (nginx), `sv 1` (Apache graceful) | `sv restart` | link `/etc/sv/X` (or `/etc/runit/sv/X`) into the service dir | `run`, `conf`, `env/*` of each service |
| s6 / s6-rc | `s6-svc -h` (nginx), `s6-svc -1` (Apache) | `s6-svc -r` | `s6-service add default X` (Artix), s6-rc or a scandir link | `run`/`up` in `/etc/s6/sv`, `/etc/s6-rc/source`, `/etc/s6-overlay/s6-rc.d`, `/etc/services.d`; `/etc/s6/config/*.conf` |
| dinit | `dinitctl signal HUP/USR1` | `dinitctl restart` | `dinitctl enable` | `/etc/dinit.d/*` |

runit's service dir is found at `/run/runit/service` (Artix), `/var/service` (Void) or
`/etc/service`; s6's scan dir at `/run/service` or `/var/run/s6/services` (`HM_RUNIT_DIR` and
`HM_S6_SCANDIR` override them). With systemd, only `Exec*`/`Environment`/`WorkingDirectory`
changes trigger a restart; with script-based inits any change does.

## Testing

`tests/run-tests.sh` builds every kind of site, adopts hand-made Apache configs and relocates a
web folder, all in a temporary sandbox (no root, nothing
outside the sandbox is touched) and checks the output. If nginx and/or Apache are installed,
it also runs `nginx -t` and `apache2 -t` on the generated configs.

```bash
bash tests/run-tests.sh
```

The sandbox also covers every init system's commands and service files. To run it for real,
`tests/init-systems.sh` (needs Docker) installs nginx, creates a site and adds an alias inside
throwaway Alpine (OpenRC and s6), Debian (SysV init) and Void (runit) containers:

```bash
sudo bash tests/init-systems.sh            # or: ... openrc runit
```

## License

GPL-3.0, see [LICENSE](LICENSE).
