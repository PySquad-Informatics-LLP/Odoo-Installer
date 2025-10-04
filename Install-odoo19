#!/usr/bin/env bash
set -euo pipefail

STATE_FILE=/etc/odoo_installer.conf
DEFAULT_INSTALL_DIR=/opt/odoo
DEFAULT_BRANCH=19.0

# Function to read state file if exists
load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

# Function to save state file
save_state() {
  cat > "$STATE_FILE" <<EOF
# Odoo installer state file (automatically generated)
ODOO_DOMAIN="$ODOO_DOMAIN"
ODOO_ADMIN_PASS="$ODOO_ADMIN_PASS"
POSTGRES_USER="$POSTGRES_USER"
INSTALL_DIR="$INSTALL_DIR"
ODOO_BRANCH="$ODOO_BRANCH"
WANT_WKHTMLTOPDF="$WANT_WKHTMLTOPDF"
WANT_TLS="$WANT_TLS"
EOF
  chmod 640 "$STATE_FILE"
  chown root:root "$STATE_FILE"
}

# safe prompt with default
prompt() {
  local var_name="$1"; shift
  local prompt_text="$1"; shift
  local default_val="$1"; shift || true
  local silent=${1:-false}

  if [ "$silent" = true ]; then
    # read without echo (for passwords)
    if [ -n "${!var_name:-}" ]; then
      read -rp "$prompt_text [$default_val] (press Enter to keep saved): " input
    else
      read -rsp "$prompt_text: " input
      echo
    fi
  else
    read -rp "$prompt_text [$default_val]: " input
  fi

  if [ -z "$input" ]; then
    # if a variable already set (from state), keep it; otherwise use default
    if [ -n "${!var_name:-}" ]; then
      : # keep existing
    else
      eval "$var_name=\"$default_val\""
    fi
  else
    eval "$var_name=\"$input\""
  fi
}

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root or via sudo. Re-run with sudo." && exit 1
fi

# Load previous answers if present
load_state

# Interactive prompts (prefilling from saved state where available)
prompt ODOO_DOMAIN "Domain to use for Odoo (leave empty to skip domain/nginx)" "${ODOO_DOMAIN:-}" false

# Admin password prompt: if saved value exists, ask whether to keep or change
if [ -n "${ODOO_ADMIN_PASS:-}" ]; then
  read -rp "A saved Odoo admin password exists. Keep it? (Y/n): " resp_keep
  resp_keep=${resp_keep:-Y}
  if [[ "$resp_keep" =~ ^[Nn]$ ]]; then
    read -rsp "Enter new Odoo DB admin password: " ODOO_ADMIN_PASS
    echo
  fi
else
  read -rsp "Odoo DB admin password (will be saved to $STATE_FILE): " ODOO_ADMIN_PASS
  echo
fi

prompt POSTGRES_USER "Postgres DB user to create" "${POSTGRES_USER:-odoo}"
prompt INSTALL_DIR "Local install directory" "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
prompt ODOO_BRANCH "Git branch/tag for Odoo" "${ODOO_BRANCH:-$DEFAULT_BRANCH}"

# wkhtmltopdf option
if [ -n "${WANT_WKHTMLTOPDF:-}" ]; then
  read -rp "Previously selected wkhtmltopdf option is '$WANT_WKHTMLTOPDF'. Change? (y/N): " resp_wk
  resp_wk=${resp_wk:-N}
  if [[ "$resp_wk" =~ ^[Yy]$ ]]; then
    read -rp "Install wkhtmltopdf patched binary? (y/N): " WANT_WKHTMLTOPDF
  fi
else
  read -rp "Install wkhtmltopdf patched binary? (y/N): " WANT_WKHTMLTOPDF
fi
WANT_WKHTMLTOPDF=${WANT_WKHTMLTOPDF:-N}

# TLS option
if [ -n "${WANT_TLS:-}" ]; then
  read -rp "Previously selected TLS option is '$WANT_TLS'. Change? (y/N): " resp_tls
  resp_tls=${resp_tls:-N}
  if [[ "$resp_tls" =~ ^[Yy]$ ]]; then
    read -rp "Configure SSL with Let's Encrypt (certbot)? (y/N): " WANT_TLS
  fi
else
  read -rp "Configure SSL with Let's Encrypt (certbot)? (y/N): " WANT_TLS
fi
WANT_TLS=${WANT_TLS:-N}

# Save answers for next run
save_state

# Confirm
cat <<EOF

Configuration summary (saved to $STATE_FILE):
  Domain: ${ODOO_DOMAIN:-<none>}
  Install dir: ${INSTALL_DIR}
  Odoo branch: ${ODOO_BRANCH}
  Postgres user: ${POSTGRES_USER}
  Install wkhtmltopdf: ${WANT_WKHTMLTOPDF}
  Configure TLS (certbot): ${WANT_TLS}
EOF

read -rp "Proceed with installation? (Y/n): " proceed
proceed=${proceed:-Y}
if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
  echo "Aborted by user."; exit 0
fi

# --- Begin installation ---
export DEBIAN_FRONTEND=noninteractive
apt update
apt upgrade -y

apt install -y git build-essential wget curl \
    python3 python3-venv python3-pip python3-dev python3-wheel \
    libxml2-dev libxslt1-dev libzip-dev libpq-dev libsasl2-dev \
    libldap2-dev libjpeg-dev zlib1g-dev libfreetype6-dev libssl-dev \
    nodejs npm nginx ufw postgresql postgresql-contrib

# Optionally install certbot if TLS requested
if [[ "$WANT_TLS" =~ ^[Yy]$ ]]; then
  apt install -y certbot python3-certbot-nginx
fi

# Create system user 'odoo' if not exists
if id -u odoo &>/dev/null; then
  echo "User 'odoo' exists."
else
  useradd -m -U -r -s /bin/bash odoo
  echo "Created user 'odoo'."
fi

# Create directories
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/custom-addons"
chown -R odoo:odoo "$INSTALL_DIR"

# PostgreSQL user creation
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'" | grep -q 1 || {
  sudo -u postgres createuser --createdb --username postgres --no-createrole --no-superuser "${POSTGRES_USER}"
  echo "Created postgres user ${POSTGRES_USER}."
}

# Clone or update Odoo source
if [ -d "${INSTALL_DIR}/odoo" ]; then
  echo "Updating existing Odoo source in ${INSTALL_DIR}/odoo"
  sudo -u odoo git -C "${INSTALL_DIR}/odoo" fetch --depth 1 origin "$ODOO_BRANCH" || true
  sudo -u odoo git -C "${INSTALL_DIR}/odoo" reset --hard "origin/$ODOO_BRANCH" || true
else
  sudo -u odoo git clone https://github.com/odoo/odoo.git --depth 1 --branch "$ODOO_BRANCH" "${INSTALL_DIR}/odoo"
fi

# Python venv
python3 -m venv "${INSTALL_DIR}/venv"
"${INSTALL_DIR}/venv/bin/python" -m pip install --upgrade pip setuptools wheel
if [ -f "${INSTALL_DIR}/odoo/requirements.txt" ]; then
  "${INSTALL_DIR}/venv/bin/pip" install -r "${INSTALL_DIR}/odoo/requirements.txt" || {
    echo "pip install failed. Check missing -dev packages and retry."; exit 1
  }
fi

# wkhtmltopdf optional install
if [[ "$WANT_WKHTMLTOPDF" =~ ^[Yy]$ ]]; then
  WK_DEB="/tmp/wkhtmltox_0.12.6-1.bionic_amd64.deb"
  if [ ! -f "$WK_DEB" ]; then
    wget -O "$WK_DEB" "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.bullseye_amd64.deb"
  fi
  dpkg -i "$WK_DEB" || apt-get -f install -y
  if command -v wkhtmltopdf &>/dev/null; then
    echo "wkhtmltopdf installed: $(wkhtmltopdf --version)"
  else
    echo "wkhtmltopdf isn't available; you may need to install a distro-appropriate patched binary."
  fi
fi

# Create log dir and config
mkdir -p /var/log/odoo
chown -R odoo:odoo /var/log/odoo

ODOO_CONF=/etc/odoo.conf
cat > "$ODOO_CONF" <<EOF
[options]
admin_passwd = ${ODOO_ADMIN_PASS}
db_host = False
db_port = False
db_user = ${POSTGRES_USER}
db_password = False
addons_path = ${INSTALL_DIR}/odoo/addons,${INSTALL_DIR}/custom-addons
logfile = /var/log/odoo/odoo.log
xmlrpc_port = 8069
longpolling_port = 8072
proxy_mode = True

workers = 2
limit_memory_soft = 2147483648
limit_memory_hard = 2684354560
limit_time_cpu = 60
limit_time_real = 120
max_cron_threads = 1
EOF

chmod 640 "$ODOO_CONF"
chown odoo:odoo "$ODOO_CONF"

# systemd service
OD_SERVICE=/etc/systemd/system/odoo.service
cat > "$OD_SERVICE" <<'EOF'
[Unit]
Description=Odoo19
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=odoo19
PermissionsStartOnly=true
User=odoo
Group=odoo
Environment=LANG=en_US.UTF-8
ExecStart=/opt/odoo/venv/bin/python3 /opt/odoo/odoo/odoo-bin -c /etc/odoo.conf
StandardOutput=journal+console
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now odoo.service || echo "Check journalctl -u odoo.service for issues."

# Nginx config (only if domain provided)
if [ -n "${ODOO_DOMAIN}" ]; then
  NGINX_SITE=/etc/nginx/sites-available/odoo
  cat > "$NGINX_SITE" <<EOF
upstream odoo {
    server 127.0.0.1:8069;
}

upstream odoo_longpoll {
    server 127.0.0.1:8072;
}

server {
    listen 80;
    server_name ${ODOO_DOMAIN};

    proxy_buffers 16 64k;
    proxy_buffer_size 128k;

    location /longpolling {
        proxy_pass http://odoo_longpoll;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://odoo;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 720s;
        proxy_connect_timeout 720s;
        proxy_send_timeout 720s;
    }
}
EOF
  ln -fs "$NGINX_SITE" /etc/nginx/sites-enabled/odoo
  nginx -t && systemctl reload nginx

  if [[ "$WANT_TLS" =~ ^[Yy]$ ]]; then
    certbot --nginx -d "$ODOO_DOMAIN" --non-interactive --agree-tos -m "admin@${ODOO_DOMAIN}" || echo "certbot failed. Run manually when DNS resolves."
  fi
else
  echo "No domain configured; skipping nginx site creation and TLS."
fi

# UFW
if command -v ufw &>/dev/null; then
  ufw allow OpenSSH || true
  if [ -n "${ODOO_DOMAIN}" ]; then
    ufw allow 'Nginx Full' || true
  fi
  yes | ufw enable || true
  ufw deny 8069 || true
  ufw deny 8072 || true
fi

# Deploy helper
DEPLOY_SCRIPT="/usr/local/bin/odoo-deploy-addons.sh"
cat > "$DEPLOY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ADDONS_DIR="/opt/odoo/custom-addons"
if [ -d "$ADDONS_DIR/.git" ]; then
  cd "$ADDONS_DIR"
  git pull --rebase || true
fi
chown -R odoo:odoo "$ADDONS_DIR"
systemctl restart odoo.service
echo "Odoo restarted. To update modules in DB run:"
echo " sudo -u odoo /opt/odoo/venv/bin/python3 /opt/odoo/odoo/odoo-bin -c /etc/odoo.conf -d <your_db> -u <module_name>"
EOF
chmod +x "$DEPLOY_SCRIPT"

# Final messages
cat <<EOF

INSTALL COMPLETE
 - Odoo service: systemctl status odoo.service
 - Odoo config: $ODOO_CONF
 - Odoo code: ${INSTALL_DIR}/odoo
 - Virtualenv: ${INSTALL_DIR}/venv
 - Custom addons dir: ${INSTALL_DIR}/custom-addons
 - Deploy helper: $DEPLOY_SCRIPT

Access:
EOF
if [ -n "${ODOO_DOMAIN}" ]; then
  echo "  https://${ODOO_DOMAIN} (after DNS & certbot)"
else
  echo "  http://<server-ip>:8069"
fi

echo
echo "Useful commands: journalctl -u odoo.service -f" 

echo "Done."
