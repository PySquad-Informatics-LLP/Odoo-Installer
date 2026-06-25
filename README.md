# Odoo Installer — Automated, Production-Grade Script

A single bash script (`install-odoo19.sh`) that installs Odoo from source on any
Debian/Ubuntu server (bare metal or AWS/Azure/GCP/DO/Hetzner cloud images).
It is **idempotent**, **resumable**, and **resilient**: optional steps that fail
don't abort the whole run, network operations are retried, and the script waits
for apt/dpkg locks that commonly break installers on fresh cloud VMs.

## Files

| Path | Description |
| --- | --- |
| `install-odoo19.sh` | The installer (run with `sudo`) |
| `/etc/odoo-installer.conf` | State file, mode `0600`, holds chosen values + secrets |
| `/etc/<service>.conf` | Odoo configuration (e.g. `/etc/odoo19.conf`) |
| `/etc/systemd/system/<service>.service` | Versioned systemd unit (e.g. `odoo19.service`) |
| `/etc/nginx/sites-available/<service>` | nginx vhost (only if a domain is provided) |
| `/etc/logrotate.d/<service>` | Daily log rotation for that version's log |
| `/var/log/odoo-installer.log` | Full installer log (every run is appended) |
| `/usr/local/bin/<service>-install-module` | CLI module install/upgrade (no UI timeout) |
| `/usr/local/bin/<service>-deploy-addons` | Pull custom-addon/enterprise git repos + restart |
| `/usr/local/bin/<service>-backup` | Dump a database + filestore to `<install-dir>/backups` |

`<service>` is derived from the major version (`odoo18`, `odoo19`, …).

## Multi-version coexistence

Each major version is fully independent, so you can run several at once on one
box. With the default layout, branch `18.0` and `19.0` produce:

| | Odoo 18 | Odoo 19 |
| --- | --- | --- |
| Install dir | `/opt/odoo/18` | `/opt/odoo/19` |
| Service | `odoo18.service` | `odoo19.service` |
| Config | `/etc/odoo18.conf` | `/etc/odoo19.conf` |
| HTTP / gevent port | `8059` / `8062` | `8069` / `8072` |
| nginx site | `odoo18` | `odoo19` |
| Helpers | `odoo18-*` | `odoo19-*` |

Ports auto-derive from the major version (v19 keeps the canonical 8069/8072);
override with `--http-port` / `--gevent-port` if you like. The `odoo` system
user and the PostgreSQL role are shared across versions.

```bash
sudo ./install-odoo19.sh --branch 18.0 --domain erp18.example.com --tls --tls-email me@x.com
sudo ./install-odoo19.sh --branch 19.0 --domain erp19.example.com --tls --tls-email me@x.com
```

## Supported environments

* Ubuntu 20.04 / 22.04 / 24.04 (and newer LTS)
* Debian 11 / 12 / 13 (and newer)
* x86_64 (`amd64`) and aarch64 (`arm64`)
* Odoo branches **17.0, 18.0, 19.0** (also 16.0). Config keys auto-select per
  version — modern Odoo uses `http_port` / `gevent_port` / `/websocket`, legacy
  uses `xmlrpc_port` / `longpolling_port` / `/longpolling`.

> Python: Odoo 17+ needs Python ≥ 3.10. On older Ubuntu (e.g. 20.04, which ships
> 3.8) the installer automatically adds the deadsnakes PPA and installs Python
> 3.12. On Debian/unsupported combos it stops with a clear message.

## Reliability features (what makes it survive cloud VMs)

* **Resilient step engine** — each step is `required` or `optional`. An optional
  failure (e.g. certbot before DNS is ready) is recorded and the run continues;
  a per-step **report** is printed at the end so you see exactly what to fix.
* **Resumable** — every step is idempotent, so after fixing an issue you just
  re-run the script; completed work is detected and reused.
* **apt lock-wait + retries** — waits for `unattended-upgrades`/other apt holders
  and retries transient mirror failures (the #1 cause of fresh-VM failures).
* **Optional packages installed one-by-one on failure** — a renamed or missing
  package on a given release never aborts the install.
* **Network retries with backoff** for git clone/fetch, pip, and downloads.
* **Self-healing** — corrupt/half-finished git checkouts and virtualenvs are
  detected and rebuilt instead of erroring out.
* **Robust wkhtmltopdf** — tries multiple patched builds matched to your
  codename+arch (with sensible fallbacks like noble→jammy), pulls in font deps,
  **verifies** the binary is the patched Qt build, and only then falls back to
  the distro package.

## Other features

* **Auto-tuning** — workers ≈ `2·CPU + 1` (capped), per-worker memory from RAM.
* **`--demo` preset** — fewer workers + relaxed timeouts so heavy module
  installs via the web UI don't get killed on small boxes.
* **Hardened systemd unit** — `ProtectSystem=full`, `ProtectHome`, `PrivateTmp`,
  `NoNewPrivileges`, `LimitNOFILE=65536`.
* **Real nginx config** — gzip, 200 MiB uploads, websocket upgrade headers,
  static-asset cache, ACME path, optional Let's Encrypt with HTTP→HTTPS.
* **Safer firewall** — auto-detects the SSH port so UFW can't lock you out;
  denies direct access to the Odoo ports.
* **PostgreSQL password auth** (works with any role name), **logrotate**,
  **Enterprise** support, **backup/deploy/install-module helpers**,
  **health-check** with a real HTTP probe.

## Quick start (interactive)

```bash
chmod +x install-odoo19.sh
sudo ./install-odoo19.sh
```

## Non-interactive / automated install

```bash
sudo ./install-odoo19.sh --non-interactive --yes \
  --domain erp.example.com \
  --branch 19.0 \
  --admin-pass 'change-me-please' \
  --tls --tls-email ops@example.com \
  --wkhtmltopdf --fail2ban --swap-gb 2
```

## All options

```text
Core:
  --domain DOMAIN          Domain to serve Odoo on (empty = IP-only access)
  --branch BRANCH          Odoo branch/tag, e.g. 19.0 / 18.0 (default: 19.0)
  --install-dir PATH       Install directory (default: /opt/odoo/<major>)
  --postgres-user NAME     PostgreSQL role name (default: odoo)
  --admin-pass PASSWORD    Odoo master/admin password (auto-generated if empty)
  --http-port PORT         Odoo HTTP port (default: auto, 8069 for v19)
  --gevent-port PORT       gevent/longpolling port (default: http-port + 3)

Tuning:
  --workers N              Number of Odoo workers (default: auto from CPU)
  --limit-time-cpu N       Per-request CPU seconds (default: 60)
  --limit-time-real N      Per-request wall-clock seconds (default: 120)
  --demo                   Demo preset: fewer workers + relaxed timeouts

Extras:
  --wkhtmltopdf            Install patched wkhtmltopdf
  --tls                    Configure Let's Encrypt TLS (requires --domain)
  --tls-email EMAIL        Email for Let's Encrypt notifications
  --fail2ban               Install and enable fail2ban
  --swap-gb N              Create N GiB swap file if no swap present
  --ssh-port PORT          SSH port to allow in UFW (auto-detected by default)
  --apt-upgrade            Run `apt upgrade` first (skipped by default)

Enterprise:
  --enterprise             Enable Odoo Enterprise (clones the private repo)
  --enterprise-repo URL    Enterprise git URL (default: odoo/enterprise)
  --enterprise-ref REF     Enterprise branch/tag (defaults to --branch value)
  --enterprise-token TOKEN GitHub PAT for HTTPS clone
  --enterprise-ssh-key F   SSH private key for SSH-based clone

Behavior:
  --non-interactive        Never prompt; use flags / env vars / state file
  --yes, -y                Assume "yes" to confirmation prompts
  --reset                  Ignore previously saved state file
  --help, -h / --version
```

## After install

```bash
systemctl status odoo19.service
journalctl -u odoo19.service -f

# Install/upgrade modules from the CLI (recommended — no web-UI worker timeout)
sudo odoo19-install-module <db_name> sale_management,stock          # install
sudo odoo19-install-module <db_name> ps_printing_press_erp --update # upgrade

# Pull custom-addon / enterprise git repos and restart Odoo
sudo odoo19-deploy-addons

# Back up a database (dump + filestore)
sudo odoo19-backup <db_name>
```

Access:

* `https://<domain>` if TLS configured
* `http://<domain>` if only nginx is configured
* `http://<server-ip>:<http-port>` if no domain (UFW blocks the port externally —
  use an SSH tunnel for first login)

## Demo / small servers

Heavy module installs through the **web UI** can exceed the production request
timeouts (`limit_time_cpu` / `limit_time_real`) or the per-worker memory cap and
drop the connection. Two good options:

1. **Install from the CLI** (no timeout at all):
   `sudo odoo19-install-module <db> <module>`.
2. **Use `--demo`** at install time for relaxed timeouts + fewer/heavier workers,
   ideal for single-user demo boxes.

## Odoo Enterprise

Enterprise lives in the private `odoo/enterprise` repo (requires GitHub access
via your Odoo contract). Three credential modes, inferred from the URL:

**HTTPS + PAT** (best for automation):

```bash
sudo ./install-odoo19.sh --enterprise --enterprise-token ghp_xxx
```

The token is stored in `~odoo/.git-credentials` (`0600`, scoped to the host via
a `credential.<URL>.helper` entry) so future pulls work without re-running. It is
never written to any `.git/config` or shown in the process list.

**SSH deploy key**:

```bash
sudo ./install-odoo19.sh --enterprise \
  --enterprise-repo git@github.com:odoo/enterprise.git \
  --enterprise-ssh-key /root/keys/odoo-enterprise.ed25519
```

**Pre-configured auth**: just pass `--enterprise` and the installer uses whatever
`~odoo/.ssh/config` or credential helper you already set up.

In all cases `${INSTALL_DIR}/enterprise` is cloned/updated and **prepended** to
`addons_path` (so Enterprise overrides win, as Odoo requires). A manually-placed
`${INSTALL_DIR}/enterprise` is auto-detected on the next run.

## Custom addons

Drop modules into `<install-dir>/custom-addons/`. The deploy helper handles both
"one git repo for the whole folder" and "one git repo per module" layouts.

## Security notes

* `/etc/odoo-installer.conf` holds the master + generated Postgres passwords
  (`chmod 600`, root-only). Don't commit it. The legacy `0640` file is migrated
  and shredded automatically.
* Direct access to the Odoo ports is denied via UFW; reach Odoo through nginx.
* Use `--fail2ban` on internet-exposed hosts.

## Troubleshooting

* **A step failed but Odoo is up**: check the step report at the end of the run
  and `/var/log/odoo-installer.log`, fix the cause, and re-run (it resumes).
* **certbot failed**: ensure DNS points here and port 80 is open, then re-run.
* **`pip install` / requirements failed**: the installer no longer aborts on a
  single failing package. It retries the whole file, then falls back to
  installing package-by-package so the rest succeed, and writes the ones that
  failed — with the exact `apt install <…-dev>` to fix each — to
  `/var/log/odoo-installer-pip-failures.txt`. Install the suggested libs and
  re-run the script (it resumes), or install a single package manually:
  `sudo -u odoo /opt/odoo/19/venv/bin/pip install '<package>'`.
  The common build headers (lxml, psycopg2, Pillow, python-ldap, cryptography,
  cairo/pango, etc.) are installed up front.
* **`ModuleNotFoundError: No module named 'pkg_resources'`**: modern setuptools
  (≥ 81) dropped it. The installer pins `setuptools<81`. To fix an existing venv:

  ```bash
  sudo systemctl stop odoo19
  sudo -u odoo /opt/odoo/19/venv/bin/pip install --force-reinstall 'setuptools<81'
  sudo systemctl start odoo19
  ```

* **Module install drops the web connection**: timeout/memory limit — use
  `sudo odoo19-install-module <db> <module>` or `--demo`.
* **Service won't start**: `journalctl -u odoo19.service -n 100 --no-pager`.

## Contact

Built and maintained by **PySquad** — questions or improvements:
[vh@pysquad.com](mailto:vh@pysquad.com) · [pysquad.com](https://www.pysquad.com)
