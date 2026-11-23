# hosting-manager

Host websites on a Linux server without hand-writing web server configs.
One command creates an nginx or Apache site, gets a Let's Encrypt certificate,
moves a site to a new domain, or adds a `www.` name.

- Static sites, PHP sites (php-fpm), reverse proxies to an app (Node, Python, Docker…) and redirects
- HTTPS with Let's Encrypt, including automatic renewal
- Rename a site to a new domain, optionally keeping the old one as a redirect
- Works with nginx and Apache, on Debian/Ubuntu and RHEL/Fedora/Rocky style layouts
- Every change is checked with `nginx -t` / `apachectl configtest` first; if the check fails,
  the previous config is put back and nothing is reloaded
- `--dry-run` shows exactly what would be written and run

## Setup

### 1. Install the script

It's a single Bash script with nothing to build:

```bash
git clone https://github.com/nano-rex/hosting-manager.git
cd hosting-manager
sudo install -m 755 hosting-manager.sh /usr/local/bin/hosting-manager
```

### 2. Install a web server and certbot

If they aren't installed yet, hosting-manager can do it (apt, dnf, yum or pacman). It also
starts the services and opens ports 80/443 if `ufw` is active:

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

Update DNS for the new name **before** renaming, so its certificate can be issued.

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

### Preview a change

Put `--dry-run` anywhere in the command to print the config files and commands without
changing anything (root is not needed):

```bash
hosting-manager --dry-run create example.com --php --ssl
```

## Usage reference

```
hosting-manager [--dry-run] [-y] <command> [arguments]
```

| Command | What it does |
|---|---|
| `create <domain> [options]` | Add a site (static unless `--php`, `--proxy` or `--redirect-to` is given) |
| `update <domain> [options]` | Change a site; same options as `create` |
| `rename <old> <new> [--redirect] [--keep-root] [--delete-old-cert]` | Move a site to a new domain |
| `alias <domain> add\|remove <name>...` | Add or remove extra names |
| `enable <domain>` / `disable <domain>` | Serve / stop serving a site, keeping its config |
| `remove <domain> [--purge] [--delete-cert]` | Delete a site (`--purge` also deletes its web root) |
| `list` | All managed sites |
| `info <domain>` | Settings, config file path, certificate expiry |
| `show <domain>` | Print the generated nginx/Apache config |
| `ssl <domain> [--staging] [--email ADDR]` | Get a certificate and enable HTTPS |
| `ssl <domain> --off` | Disable HTTPS (certificate kept) |
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

Global options: `--dry-run` (change nothing, print everything), `-y` / `--yes` (don't ask
for confirmation).

## Where things are

| Path | Contents |
|---|---|
| `/etc/nginx/sites-available/<domain>.conf` (+ link in `sites-enabled`) | nginx site on Debian/Ubuntu |
| `/etc/nginx/conf.d/<domain>.conf` | nginx site on RHEL-style systems (`.conf.disabled` when disabled) |
| `/etc/apache2/sites-available/<domain>.conf` | Apache site on Debian/Ubuntu |
| `/etc/httpd/conf.d/<domain>.conf` | Apache site on RHEL-style systems |
| `/etc/hosting-manager/sites/<domain>.site` | hosting-manager's record of each site |
| `/etc/hosting-manager/backups/<time>/` | copies of every file before it was changed |
| `/etc/hosting-manager/hosting-manager.conf` | defaults set with `config` |
| `/var/www/_letsencrypt` | shared folder for certificate validation |

Generated configs are regenerated from the site record on every change, so make changes
with hosting-manager rather than editing them by hand. Sites you configured yourself are left
alone; hosting-manager only touches the sites it created.

## Testing

`tests/run-tests.sh` builds every kind of site in a temporary sandbox (no root, nothing
outside the sandbox is touched) and checks the output. If nginx and/or Apache are installed,
it also runs `nginx -t` and `apache2 -t` on the generated configs.

```bash
bash tests/run-tests.sh
```

## License

GPL-3.0, see [LICENSE](LICENSE).
