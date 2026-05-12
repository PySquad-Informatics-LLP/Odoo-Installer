# Odoo Installer — Automated, Production-Grade Script

A single bash script (`install-odoo19.sh`) that installs Odoo from source on any
Debian/Ubuntu server. It is safe to re-run, supports unattended/CI installs,
auto-detects the host (OS, architecture, CPU, RAM), and writes a hardened
configuration tuned to that host.

## Files

| Path | Description |
| --- | --- |
| `install-odoo19.sh` | The installer (run with `sudo`) |
| `/etc/odoo-installer.conf` | Auto-generated state file, mode `0600`, holds chosen values + secrets |
| `/etc/<service>.conf` | Odoo configuration (e.g. `/etc/odoo19.conf`) |
| `/etc/systemd/system/<service>.service` | Versioned systemd unit (e.g. `odoo19.service`) |
| `/etc/nginx/sites-available/<service>` | nginx vhost (only if a domain is provided) |
| `/etc/logrotate.d/<service>` | Daily log rotation for `/var/log/odoo/*.log` |
| `/usr/local/bin/<service>-deploy-addons` | Pulls custom-addon git repos + restarts Odoo |
| `/usr/local/bin/<service>-backup` | Dumps a database + filestore to `<install-dir>/backups` |

`<service>` is derived from the major version (e.g. `odoo19` for branch `19.0`),
so multiple Odoo versions can co-exist on one server.

## Supported environments

* Ubuntu 20.04 / 22.04 / 24.04 (and newer LTS releases)
* Debian 11 / 12 (and newer)
* x86_64 (`amd64`) and aarch64 (`arm64`)
* Odoo branches **16.0, 17.0, 18.0, 19.0** (config keys are auto-selected
  per version — modern Odoo uses `http_port` / `gevent_port` / `/websocket`,
  legacy Odoo uses `xmlrpc_port` / `longpolling_port` / `/longpolling`)

## Features

* **Auto-tuning** — workers ≈ `2·CPU + 1` (capped), per-worker memory budget
  derived from total RAM, sane `limit_*` defaults
* **Versioned everything** — `odoo19.service`, `/etc/odoo19.conf`,
  `odoo19-deploy-addons`, … so you can run 17 + 19 side-by-side
* **Hardened systemd unit** — `ProtectSystem=full`, `ProtectHome=true`,
  `NoNewPrivileges=true`, `PrivateTmp=true`, `LimitNOFILE=65536`
* **Real nginx config** — gzip, 200 MiB upload limit, websocket upgrade
  headers, static-asset cache, ACME challenge path, optional Let's Encrypt
* **Safer firewall** — auto-detects the SSH port from `sshd_config` so UFW
  never locks the operator out; denies direct access to ports 8069/8072
* **PostgreSQL with password auth** (not peer auth), so any role name works
* **Logrotate** for `/var/log/odoo/*.log` (daily, 14-day retention, compressed)
* **Backup + deploy helpers** generated on the fly with the right paths baked in
* **Idempotent re-runs** — saved answers prefill prompts, source is updated
  with `git fetch`+`reset --hard`, services are restarted, users/dbs are reused
* **Non-interactive mode** for cloud-init, Ansible, GitHub Actions, etc.
* **Optional fail2ban** and **optional swap-file creation** for low-RAM hosts
* **Patched wkhtmltopdf 0.12.6.1-2** for the right codename **and**
  architecture, with a graceful fallback to the distro package
* **Health-check** at the end of every run

## Quick start (interactive)

```bash
chmod +x install-odoo19.sh
sudo ./install-odoo19.sh
```

The installer prompts for domain, admin password, branch, Postgres role,
install path, and TLS/wkhtmltopdf preferences. Defaults are pre-filled from
the previous run.

## Non-interactive / automated install

```bash
sudo ./install-odoo19.sh --non-interactive --yes \
  --domain erp.example.com \
  --branch 19.0 \
  --admin-pass 'change-me-please' \
  --tls --tls-email ops@example.com \
  --wkhtmltopdf \
  --fail2ban \
  --swap-gb 2
```

Or via environment variables:

```bash
sudo ODOO_DOMAIN=erp.example.com \
     ODOO_ADMIN_PASS='change-me-please' \
     WANT_TLS=Y TLS_EMAIL=ops@example.com \
     ./install-odoo19.sh --non-interactive --yes
```

## All options

```text
--domain DOMAIN          Domain to serve Odoo on (empty = IP-only access)
--branch BRANCH          Odoo branch/tag (default: 19.0)
--install-dir PATH       Install directory (default: /opt/odoo)
--postgres-user NAME     PostgreSQL role name (default: odoo)
--admin-pass PASSWORD    Odoo master/admin password (auto-generated if empty)
--wkhtmltopdf            Install patched wkhtmltopdf 0.12.6.1-2
--tls                    Configure Let's Encrypt TLS (requires --domain)
--tls-email EMAIL        Email for Let's Encrypt notifications
--apt-upgrade            Run `apt upgrade -y` (skipped by default)
--fail2ban               Install and enable fail2ban
--swap-gb N              Create N GiB swap file if no swap is present
--ssh-port PORT          SSH port to allow in UFW (auto-detected by default)
--non-interactive        Never prompt; use flags / env vars / state file
--yes, -y                Assume "yes" to confirmation prompts
--reset                  Ignore previously saved state file
--help, -h               Show help and exit
--version                Show installer version and exit
```

## After install

```bash
# Status / logs
systemctl status odoo19.service
journalctl -u odoo19.service -f

# Pull custom-addon git repos and restart Odoo
sudo odoo19-deploy-addons

# Back up a database (dump + filestore)
sudo odoo19-backup <db_name>

# Upgrade a module
sudo -u odoo /opt/odoo/venv/bin/python3 /opt/odoo/odoo/odoo-bin \
  -c /etc/odoo19.conf -d <db_name> -u <module_name> --stop-after-init
```

Access:

* `https://<domain>` if TLS configured
* `http://<domain>` if only nginx is configured
* `http://<server-ip>:8069` if no domain was provided (UFW will block the
  port externally — use SSH tunneling for first login in that case)

## Custom addons

Drop your modules into `<install-dir>/custom-addons/` (default
`/opt/odoo/custom-addons`). The deploy helper supports two layouts:

1. The whole `custom-addons` directory is one git repository.
2. Each module/group is its own git repository inside `custom-addons/`.

Either way, running `sudo odoo19-deploy-addons` pulls every repo it finds and
restarts the service.

## Security notes

* `/etc/odoo-installer.conf` contains the master password and the generated
  Postgres password. It is `chmod 600` root-only; do **not** commit it.
* The legacy `/etc/odoo_installer.conf` (mode 0640) from older versions is
  migrated and shredded automatically.
* The installer denies external access to ports `8069` / `8072` via UFW so
  Odoo is only reachable through nginx.
* Use `--fail2ban` on internet-exposed hosts to throttle brute-force logins.

## Troubleshooting

* `pip install -r requirements.txt` failed: check `/var/log/odoo-installer.log`
  for the missing system header; you usually need an extra `-dev` package.
* `certbot` failed: ensure DNS for your domain points to the host and port 80
  is reachable, then re-run `sudo ./install-odoo19.sh` (the state file
  remembers your answers) or run certbot manually as shown in the warning.
* `wkhtmltopdf` unavailable for your codename: the installer falls back to
  the distro package. PDF reports work but may look slightly different.
* Service won't start: `journalctl -u odoo19.service -n 100 --no-pager`.

## Contact

Built and maintained by **PySquad** — questions or improvements:
[vh@pysquad.com](mailto:vh@pysquad.com) · [pysquad.com](https://www.pysquad.com)
