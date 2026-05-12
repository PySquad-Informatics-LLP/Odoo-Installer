#!/usr/bin/env bash
#
# Odoo Installer
# Production-grade, idempotent installer for Odoo on Debian/Ubuntu servers.
#
# Tested on:
#   - Ubuntu 20.04 / 22.04 / 24.04 (and newer LTS)
#   - Debian 11 / 12 (and newer)
#   - x86_64 (amd64) and aarch64 (arm64)
#
# Supports Odoo 16.0, 17.0, 18.0, 19.0 (config keys auto-selected by version).
# Safe to re-run: loads previous answers, updates code, refreshes the venv,
# and reconciles configuration without recreating users or databases.
#
# Usage: see  sudo ./install-odoo19.sh --help

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Constants & defaults
# =============================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly STATE_FILE="/etc/odoo-installer.conf"
readonly LEGACY_STATE_FILE="/etc/odoo_installer.conf"
readonly DEFAULT_INSTALL_DIR="/opt/odoo"
readonly DEFAULT_BRANCH="19.0"
readonly DEFAULT_POSTGRES_USER="odoo"
readonly DEFAULT_SYSTEM_USER="odoo"

LOG_FILE="/var/log/odoo-installer.log"

# Runtime flags (set by parse_args / detection)
NON_INTERACTIVE=false
ASSUME_YES=false
DO_APT_UPGRADE=false
DO_FAIL2BAN=false
DO_SWAP=false
SWAP_GB=2
SSH_PORT=""
RESET_STATE=false

# Detection results
OS_ID=""
OS_LIKE=""
OS_CODENAME=""
OS_VERSION=""
ARCH=""
CPU_COUNT=2
RAM_MB=2048
PYTHON_BIN=""

# Persisted / configurable values (populated from state file, args, or prompts)
ODOO_DOMAIN="${ODOO_DOMAIN:-}"
ODOO_ADMIN_PASS="${ODOO_ADMIN_PASS:-}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_PASS="${POSTGRES_PASS:-}"
INSTALL_DIR="${INSTALL_DIR:-}"
ODOO_BRANCH="${ODOO_BRANCH:-}"
WANT_WKHTMLTOPDF="${WANT_WKHTMLTOPDF:-}"
WANT_TLS="${WANT_TLS:-}"
TLS_EMAIL="${TLS_EMAIL:-}"
SERVICE_NAME="${SERVICE_NAME:-}"

# =============================================================================
# Logging
# =============================================================================
_color() {
  if [ -t 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi
}
_log_to_file() {
  # The braces ensure shell-level redirect errors are silenced too,
  # not just printf's own stderr.
  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; } 2>/dev/null || true
}
info() { _color "1;34" "→ $*"; _log_to_file "INFO  $*"; }
warn() { _color "1;33" "⚠ $*"; _log_to_file "WARN  $*"; }
err()  { _color "1;31" "✗ $*"; _log_to_file "ERROR $*"; }
ok()   { _color "1;32" "✓ $*"; _log_to_file "OK    $*"; }
die()  { err "$*"; exit 1; }

on_error() {
  local exit_code=$?
  err "Installer failed at line $1 (exit $exit_code). See $LOG_FILE."
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

init_log() {
  mkdir -p "$(dirname "$LOG_FILE")" >/dev/null 2>&1 || true
  if ! ( : >>"$LOG_FILE" ) 2>/dev/null; then
    LOG_FILE="/tmp/odoo-installer.log"
    ( : >>"$LOG_FILE" ) 2>/dev/null || LOG_FILE="/dev/null"
  fi
  _log_to_file "=== odoo-installer ${SCRIPT_VERSION} started ($(date)) ==="
}

# =============================================================================
# Help
# =============================================================================
usage() {
  cat <<EOF
Odoo installer v${SCRIPT_VERSION}

Usage: sudo $0 [OPTIONS]

Options:
  --domain DOMAIN          Domain to serve Odoo on (empty = IP-only access)
  --branch BRANCH          Odoo branch/tag (default: ${DEFAULT_BRANCH})
  --install-dir PATH       Install directory (default: ${DEFAULT_INSTALL_DIR})
  --postgres-user NAME     PostgreSQL role name (default: ${DEFAULT_POSTGRES_USER})
  --admin-pass PASSWORD    Odoo master/admin password (auto-generated if empty)
  --wkhtmltopdf            Install patched wkhtmltopdf 0.12.6.1-2
  --tls                    Configure Let's Encrypt TLS (requires --domain)
  --tls-email EMAIL        Email for Let's Encrypt notifications
  --apt-upgrade            Run \`apt upgrade -y\` (skipped by default)
  --fail2ban               Install and enable fail2ban
  --swap-gb N              Create N GiB swap file if no swap present
  --ssh-port PORT          SSH port to allow in UFW (auto-detected by default)
  --non-interactive        Never prompt; use flags / env vars / state file
  --yes, -y                Assume "yes" to confirmation prompts
  --reset                  Ignore previously saved state file
  --help, -h               Show this help and exit
  --version                Show installer version and exit

Environment variables (alternative to flags):
  ODOO_DOMAIN, ODOO_BRANCH, INSTALL_DIR, POSTGRES_USER, ODOO_ADMIN_PASS,
  WANT_WKHTMLTOPDF (Y/N), WANT_TLS (Y/N), TLS_EMAIL

Examples:
  sudo $0
  sudo $0 --domain erp.example.com --tls --tls-email ops@example.com
  sudo ODOO_ADMIN_PASS='s3cret' $0 --non-interactive --yes \\
       --domain erp.example.com --branch 19.0 --tls --tls-email ops@example.com
EOF
}

# =============================================================================
# Detection
# =============================================================================
require_root() {
  [ "$EUID" -eq 0 ] || die "This script must run as root. Re-run with sudo."
}

detect_os() {
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release; unsupported OS."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_VERSION="${VERSION_ID:-}"

  case "$OS_ID" in
    ubuntu|debian) ;;
    linuxmint|pop|elementary|zorin|neon) OS_ID="ubuntu" ;;
    *)
      if [[ " $OS_LIKE " == *" debian "* ]]; then
        warn "Distribution '$OS_ID' is not officially supported but looks Debian-like; continuing."
      else
        die "Unsupported distribution '$OS_ID'. This installer targets Debian/Ubuntu."
      fi
      ;;
  esac
  ok "Detected $OS_ID $OS_VERSION (${OS_CODENAME:-unknown codename})"
}

detect_arch() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) ARCH="$m"; warn "Unusual architecture: $m" ;;
  esac
  ok "Architecture: $ARCH"
}

detect_resources() {
  CPU_COUNT="$(nproc 2>/dev/null || echo 2)"
  RAM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 2048)"
  ok "Resources: ${CPU_COUNT} CPU cores, ${RAM_MB} MiB RAM"
}

detect_ssh_port() {
  [ -n "$SSH_PORT" ] && return
  local p
  p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  if [ -z "$p" ] && [ -d /etc/ssh/sshd_config.d ]; then
    p="$(grep -rhE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config.d 2>/dev/null \
          | awk '{print $2; exit}')"
  fi
  SSH_PORT="${p:-22}"
}

# =============================================================================
# Helpers
# =============================================================================
random_password() {
  local len="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$len"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
  fi
}

odoo_major() {
  # Extract leading major number from a branch like "19.0" / "17.0" / "master".
  local b="${1:-}"
  if [[ "$b" =~ ^([0-9]+)\.([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [ "$b" = "master" ]; then
    echo "99"
  else
    echo "0"
  fi
}

# Returns 0 if Odoo >= 17 (modern config keys, /websocket, gevent)
is_modern_odoo() {
  local maj; maj="$(odoo_major "${ODOO_BRANCH:-}")"
  [ "$maj" -ge 17 ] 2>/dev/null
}

validate_domain() {
  local d="$1"
  [ -z "$d" ] && return 0
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "Invalid domain: '$d'"
}

# =============================================================================
# State file
# =============================================================================
load_state() {
  if $RESET_STATE; then
    info "--reset given: ignoring existing state file."
    return 0
  fi
  local f=""
  if [ -f "$STATE_FILE" ]; then f="$STATE_FILE"
  elif [ -f "$LEGACY_STATE_FILE" ]; then f="$LEGACY_STATE_FILE"
  fi
  if [ -n "$f" ]; then
    info "Loading saved answers from $f"
    # shellcheck disable=SC1090
    . "$f"
  fi
}

save_state() {
  umask 077
  cat > "$STATE_FILE" <<EOF
# Odoo installer state — auto-generated. Root-only (0600).
# Contains secrets; do NOT commit to source control.
ODOO_DOMAIN="${ODOO_DOMAIN}"
ODOO_ADMIN_PASS="${ODOO_ADMIN_PASS}"
POSTGRES_USER="${POSTGRES_USER}"
POSTGRES_PASS="${POSTGRES_PASS}"
INSTALL_DIR="${INSTALL_DIR}"
ODOO_BRANCH="${ODOO_BRANCH}"
WANT_WKHTMLTOPDF="${WANT_WKHTMLTOPDF}"
WANT_TLS="${WANT_TLS}"
TLS_EMAIL="${TLS_EMAIL}"
SERVICE_NAME="${SERVICE_NAME}"
EOF
  chown root:root "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  # Remove the legacy file if present (had loose 0640 perms).
  if [ -f "$LEGACY_STATE_FILE" ] && [ "$LEGACY_STATE_FILE" != "$STATE_FILE" ]; then
    shred -u "$LEGACY_STATE_FILE" 2>/dev/null || rm -f "$LEGACY_STATE_FILE"
  fi
}

# =============================================================================
# Prompts
# =============================================================================
prompt_default() {
  local var="$1" text="$2" default="${3:-}"
  if $NON_INTERACTIVE; then
    if [ -z "${!var:-}" ]; then printf -v "$var" '%s' "$default"; fi
    return
  fi
  local current="${!var:-$default}"
  local input
  read -rp "$text [$current]: " input || true
  if [ -n "$input" ]; then printf -v "$var" '%s' "$input"
  else                    printf -v "$var" '%s' "$current"; fi
}

prompt_yn() {
  local var="$1" text="$2" default="${3:-N}"
  if $NON_INTERACTIVE; then
    if [ -z "${!var:-}" ]; then printf -v "$var" '%s' "$default"; fi
    return
  fi
  local current="${!var:-$default}"
  current="${current:0:1}"
  local hint="y/N"; [[ "$current" =~ [Yy] ]] && hint="Y/n"
  local input
  read -rp "$text ($hint): " input || true
  input="${input:-$current}"
  case "$input" in
    [Yy]*) printf -v "$var" '%s' "Y" ;;
    *)     printf -v "$var" '%s' "N" ;;
  esac
}

prompt_password() {
  local var="$1" text="$2"
  if $NON_INTERACTIVE; then return; fi
  if [ -n "${!var:-}" ]; then
    local resp
    read -rp "A saved password exists. Re-enter? (y/N): " resp || true
    [[ "$resp" =~ ^[Yy]$ ]] || return
  fi
  local p1 p2
  while true; do
    read -rsp "$text: " p1; echo
    read -rsp "Confirm: " p2; echo
    [ "$p1" = "$p2" ] || { warn "Passwords didn't match. Try again."; continue; }
    [ -n "$p1" ]      || { warn "Password cannot be empty.";         continue; }
    [ "${#p1}" -ge 8 ] || { warn "Use at least 8 characters.";        continue; }
    printf -v "$var" '%s' "$p1"
    break
  done
}

confirm() {
  $ASSUME_YES        && return 0
  $NON_INTERACTIVE   && return 0
  local resp
  read -rp "${1:-Proceed?} (y/N): " resp || true
  [[ "$resp" =~ ^[Yy]$ ]]
}

# =============================================================================
# Argument parsing
# =============================================================================
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)         ODOO_DOMAIN="${2:-}"; shift 2 ;;
      --branch)         ODOO_BRANCH="${2:-}"; shift 2 ;;
      --install-dir)    INSTALL_DIR="${2:-}"; shift 2 ;;
      --postgres-user)  POSTGRES_USER="${2:-}"; shift 2 ;;
      --admin-pass)     ODOO_ADMIN_PASS="${2:-}"; shift 2 ;;
      --wkhtmltopdf)    WANT_WKHTMLTOPDF="Y"; shift ;;
      --tls)            WANT_TLS="Y"; shift ;;
      --tls-email)      TLS_EMAIL="${2:-}"; shift 2 ;;
      --apt-upgrade)    DO_APT_UPGRADE=true; shift ;;
      --fail2ban)       DO_FAIL2BAN=true; shift ;;
      --swap-gb)        DO_SWAP=true; SWAP_GB="${2:-2}"; shift 2 ;;
      --ssh-port)       SSH_PORT="${2:-}"; shift 2 ;;
      --non-interactive) NON_INTERACTIVE=true; shift ;;
      --yes|-y)         ASSUME_YES=true; shift ;;
      --reset)          RESET_STATE=true; shift ;;
      --help|-h)        usage; exit 0 ;;
      --version)        echo "$SCRIPT_VERSION"; exit 0 ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
  done
}

# =============================================================================
# Collect configuration
# =============================================================================
collect_config() {
  prompt_default ODOO_DOMAIN \
    "Domain for Odoo (leave empty to skip nginx/TLS)" "${ODOO_DOMAIN:-}"
  validate_domain "$ODOO_DOMAIN"

  if [ -z "$ODOO_ADMIN_PASS" ]; then
    if $NON_INTERACTIVE; then
      ODOO_ADMIN_PASS="$(random_password 32)"
      warn "Generated random admin password (saved to $STATE_FILE)."
    else
      prompt_password ODOO_ADMIN_PASS "Odoo master/admin password"
    fi
  else
    prompt_password ODOO_ADMIN_PASS "Odoo master/admin password (saved exists)"
  fi

  prompt_default POSTGRES_USER "PostgreSQL role for Odoo" \
    "${POSTGRES_USER:-$DEFAULT_POSTGRES_USER}"
  prompt_default INSTALL_DIR   "Install directory" \
    "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
  prompt_default ODOO_BRANCH   "Git branch/tag for Odoo" \
    "${ODOO_BRANCH:-$DEFAULT_BRANCH}"
  prompt_yn      WANT_WKHTMLTOPDF "Install patched wkhtmltopdf?" \
    "${WANT_WKHTMLTOPDF:-N}"

  if [ -n "$ODOO_DOMAIN" ]; then
    prompt_yn WANT_TLS "Configure TLS with Let's Encrypt?" "${WANT_TLS:-N}"
    if [ "$WANT_TLS" = "Y" ]; then
      prompt_default TLS_EMAIL "Email for Let's Encrypt notifications" \
        "${TLS_EMAIL:-admin@${ODOO_DOMAIN}}"
    fi
  else
    WANT_TLS="N"
  fi

  # Derived values
  [ -z "$POSTGRES_PASS" ] && POSTGRES_PASS="$(random_password 32)"
  local maj; maj="$(odoo_major "$ODOO_BRANCH")"
  SERVICE_NAME="odoo${maj}"
  [ "$maj" -eq 0 ] && SERVICE_NAME="odoo"

  # Sanity checks
  [[ "$INSTALL_DIR" = /* ]]  || die "INSTALL_DIR must be an absolute path."
  [[ "$POSTGRES_USER" =~ ^[a-z_][a-z0-9_]*$ ]] \
    || die "Invalid PostgreSQL role name: '$POSTGRES_USER'."
  [ -n "$ODOO_ADMIN_PASS" ]  || die "Admin password is required."

  cat <<EOF

Configuration summary:
  Domain ............ ${ODOO_DOMAIN:-<none>}
  Install dir ....... ${INSTALL_DIR}
  Odoo branch ....... ${ODOO_BRANCH}  (major: $(odoo_major "$ODOO_BRANCH"))
  Service name ...... ${SERVICE_NAME}.service
  Postgres role ..... ${POSTGRES_USER}
  wkhtmltopdf ....... ${WANT_WKHTMLTOPDF}
  TLS / Certbot ..... ${WANT_TLS}${TLS_EMAIL:+ (email: $TLS_EMAIL)}
  apt upgrade ....... $($DO_APT_UPGRADE && echo Y || echo N)
  fail2ban .......... $($DO_FAIL2BAN && echo Y || echo N)
  Swap file ......... $($DO_SWAP && echo "${SWAP_GB} GiB" || echo N)
  SSH port (UFW) .... ${SSH_PORT}
  State file ........ ${STATE_FILE}
EOF

  confirm "Proceed with installation?" \
    || die "Aborted by user."
}

# =============================================================================
# Installation steps
# =============================================================================
maybe_create_swap() {
  $DO_SWAP || return 0
  if awk '/^SwapTotal:/ {exit ($2>0?0:1)}' /proc/meminfo; then
    info "Swap already present; skipping creation."
    return 0
  fi
  local path="/swapfile" size_kb=$((SWAP_GB*1024*1024))
  info "Creating ${SWAP_GB} GiB swap at ${path}"
  fallocate -l "${SWAP_GB}G" "$path" 2>/dev/null \
    || dd if=/dev/zero of="$path" bs=1024 count="$size_kb" status=none
  chmod 600 "$path"
  mkswap "$path" >/dev/null
  swapon "$path"
  grep -q "^${path} " /etc/fstab || echo "${path} none swap sw 0 0" >>/etc/fstab
  ok "Swap enabled."
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  info "Updating apt index"
  apt-get update -qq

  if $DO_APT_UPGRADE; then
    info "Running 'apt upgrade' (this may take a while)"
    apt-get upgrade -y -qq
  fi

  info "Installing system packages"
  # Build the package list dynamically; some package names differ across releases.
  local pkgs=(
    git build-essential wget curl ca-certificates gnupg lsb-release
    python3 python3-venv python3-pip python3-dev python3-wheel
    libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev libssl-dev
    libjpeg-dev libpq-dev libffi-dev zlib1g-dev libfreetype6-dev
    libtiff5-dev liblcms2-dev libwebp-dev libharfbuzz-dev libfribidi-dev
    libxcb1-dev libzip-dev libpng-dev
    node-less npm nodejs
    postgresql postgresql-contrib
    nginx ufw rsync logrotate
  )
  apt-get install -y -qq "${pkgs[@]}"
  ok "System packages installed."
}

detect_python() {
  for p in python3.12 python3.11 python3.10 python3; do
    if command -v "$p" >/dev/null 2>&1; then
      PYTHON_BIN="$(command -v "$p")"
      ok "Using $PYTHON_BIN ($("$p" --version 2>&1))"
      return
    fi
  done
  die "No python3 binary found (expected python3.10 or newer)."
}

setup_user_and_dirs() {
  if id -u "$DEFAULT_SYSTEM_USER" >/dev/null 2>&1; then
    info "System user '$DEFAULT_SYSTEM_USER' already exists."
  else
    useradd -m -U -r -d "$INSTALL_DIR" -s /bin/bash "$DEFAULT_SYSTEM_USER"
    ok "Created system user '$DEFAULT_SYSTEM_USER'."
  fi
  install -d -m 755 -o "$DEFAULT_SYSTEM_USER" -g "$DEFAULT_SYSTEM_USER" \
    "$INSTALL_DIR" "$INSTALL_DIR/custom-addons"
  install -d -m 755 -o "$DEFAULT_SYSTEM_USER" -g "$DEFAULT_SYSTEM_USER" \
    /var/log/odoo
  install -d -m 750 -o "$DEFAULT_SYSTEM_USER" -g "$DEFAULT_SYSTEM_USER" \
    "$INSTALL_DIR/backups"
}

setup_postgres() {
  systemctl enable --now postgresql >/dev/null 2>&1 || true

  if sudo -u postgres psql -tAc \
       "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'" | grep -q 1; then
    info "PostgreSQL role '${POSTGRES_USER}' exists; updating password."
  else
    sudo -u postgres createuser --createdb --no-superuser --no-createrole "${POSTGRES_USER}"
    ok "Created PostgreSQL role '${POSTGRES_USER}'."
  fi
  # Always (re)set password so the state file matches reality.
  sudo -u postgres psql -v ON_ERROR_STOP=1 -qc \
    "ALTER ROLE \"${POSTGRES_USER}\" WITH LOGIN PASSWORD '${POSTGRES_PASS//\'/\'\'}';"
  ok "PostgreSQL role configured."
}

fetch_odoo_source() {
  local src="${INSTALL_DIR}/odoo"
  if [ -d "$src/.git" ]; then
    info "Updating Odoo source in $src"
    sudo -u "$DEFAULT_SYSTEM_USER" git -C "$src" remote set-url origin \
      https://github.com/odoo/odoo.git
    sudo -u "$DEFAULT_SYSTEM_USER" git -C "$src" fetch --depth 1 origin "$ODOO_BRANCH" \
      || die "Failed to fetch branch '$ODOO_BRANCH' from odoo/odoo."
    sudo -u "$DEFAULT_SYSTEM_USER" git -C "$src" reset --hard "FETCH_HEAD"
  else
    info "Cloning Odoo ${ODOO_BRANCH} into $src"
    sudo -u "$DEFAULT_SYSTEM_USER" git clone \
      --depth 1 --branch "$ODOO_BRANCH" \
      https://github.com/odoo/odoo.git "$src" \
      || die "git clone failed for branch '$ODOO_BRANCH'."
  fi
  ok "Odoo source ready."
}

setup_venv() {
  local venv="${INSTALL_DIR}/venv"
  if [ ! -x "$venv/bin/python" ]; then
    info "Creating Python virtualenv at $venv"
    sudo -u "$DEFAULT_SYSTEM_USER" "$PYTHON_BIN" -m venv "$venv"
  fi
  sudo -u "$DEFAULT_SYSTEM_USER" "$venv/bin/pip" install --quiet --upgrade \
    pip setuptools wheel
  if [ -f "${INSTALL_DIR}/odoo/requirements.txt" ]; then
    info "Installing Odoo Python requirements (this can take several minutes)"
    sudo -u "$DEFAULT_SYSTEM_USER" "$venv/bin/pip" install --quiet \
      -r "${INSTALL_DIR}/odoo/requirements.txt" \
      || die "pip install failed. Inspect $LOG_FILE; you may be missing dev libraries."
  fi
  ok "Python environment ready."
}

install_wkhtmltopdf() {
  [ "$WANT_WKHTMLTOPDF" = "Y" ] || return 0

  if command -v wkhtmltopdf >/dev/null 2>&1; then
    info "wkhtmltopdf already installed: $(wkhtmltopdf --version 2>&1 | head -n1)"
    return 0
  fi

  # The official patched releases only ship for a fixed set of codenames.
  local codename="${OS_CODENAME}"
  case "$OS_ID/$codename" in
    ubuntu/focal|ubuntu/jammy|ubuntu/noble) ;;
    debian/bullseye|debian/bookworm) ;;
    *)
      warn "No patched wkhtmltopdf available for $OS_ID/$codename."
      warn "Falling back to distro 'wkhtmltopdf' (PDF rendering may be limited)."
      apt-get install -y -qq wkhtmltopdf || warn "Distro wkhtmltopdf install failed."
      return 0
      ;;
  esac

  local ver="0.12.6.1-2"
  local url="https://github.com/wkhtmltopdf/packaging/releases/download/${ver}/wkhtmltox_${ver}.${codename}_${ARCH}.deb"
  local deb="/tmp/wkhtmltox_${ver}.${codename}_${ARCH}.deb"

  info "Downloading wkhtmltopdf $ver for ${codename}/${ARCH}"
  if ! wget -q -O "$deb" "$url"; then
    warn "Download failed ($url). Falling back to distro wkhtmltopdf."
    apt-get install -y -qq wkhtmltopdf || true
    return 0
  fi
  if ! apt-get install -y -qq "$deb"; then
    warn "Patched wkhtmltopdf install failed; falling back to distro package."
    apt-get install -y -qq wkhtmltopdf || true
  fi
  rm -f "$deb"
  ok "wkhtmltopdf installed: $(wkhtmltopdf --version 2>&1 | head -n1)"
}

write_odoo_config() {
  local conf="/etc/${SERVICE_NAME}.conf"
  local workers max_cron mem_soft mem_hard

  # workers ≈ 2N+1 with a sane floor/ceiling; 0 means single-process (dev only).
  workers=$(( CPU_COUNT * 2 + 1 ))
  [ "$workers" -lt 2 ] && workers=2
  [ "$workers" -gt 16 ] && workers=16
  max_cron=$(( CPU_COUNT > 2 ? 2 : 1 ))

  # Memory limits: budget ~70 % of RAM split across (workers + cron).
  local slots=$(( workers + max_cron ))
  local per_worker_mb=$(( RAM_MB * 7 / 10 / slots ))
  [ "$per_worker_mb" -lt 512 ] && per_worker_mb=512
  mem_soft=$(( per_worker_mb * 1024 * 1024 ))
  mem_hard=$(( per_worker_mb * 1024 * 1024 * 5 / 4 ))

  local http_key gevent_key
  if is_modern_odoo; then
    http_key="http_port"
    gevent_key="gevent_port"
  else
    http_key="xmlrpc_port"
    gevent_key="longpolling_port"
  fi

  info "Writing Odoo configuration to $conf"
  umask 077
  cat > "$conf" <<EOF
[options]
; Auto-generated by odoo-installer ${SCRIPT_VERSION}. Edit with care.
admin_passwd = ${ODOO_ADMIN_PASS}
db_host = 127.0.0.1
db_port = 5432
db_user = ${POSTGRES_USER}
db_password = ${POSTGRES_PASS}
addons_path = ${INSTALL_DIR}/odoo/addons,${INSTALL_DIR}/custom-addons
data_dir = ${INSTALL_DIR}/data
logfile = /var/log/odoo/${SERVICE_NAME}.log
log_level = info
${http_key} = 8069
${gevent_key} = 8072
proxy_mode = True

workers = ${workers}
max_cron_threads = ${max_cron}
limit_memory_soft = ${mem_soft}
limit_memory_hard = ${mem_hard}
limit_time_cpu = 60
limit_time_real = 120
limit_request = 8192
EOF
  chown "$DEFAULT_SYSTEM_USER":"$DEFAULT_SYSTEM_USER" "$conf"
  chmod 640 "$conf"
  install -d -m 750 -o "$DEFAULT_SYSTEM_USER" -g "$DEFAULT_SYSTEM_USER" \
    "${INSTALL_DIR}/data"
  ok "Wrote $conf (workers=${workers}, mem/worker=${per_worker_mb} MiB)."
}

write_systemd_service() {
  local svc="/etc/systemd/system/${SERVICE_NAME}.service"
  local conf="/etc/${SERVICE_NAME}.conf"
  info "Writing systemd unit $svc"
  cat > "$svc" <<EOF
[Unit]
Description=Odoo $(odoo_major "$ODOO_BRANCH") (${SERVICE_NAME})
Documentation=https://www.odoo.com/documentation
Requires=postgresql.service
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${DEFAULT_SYSTEM_USER}
Group=${DEFAULT_SYSTEM_USER}
SyslogIdentifier=${SERVICE_NAME}
Environment=LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/odoo/odoo-bin -c ${conf}
KillMode=mixed
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
# Hardening
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true
ReadWritePaths=${INSTALL_DIR} /var/log/odoo

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service" >/dev/null
  systemctl restart "${SERVICE_NAME}.service" \
    || warn "Service failed to start; check 'journalctl -u ${SERVICE_NAME}.service'."
  ok "Service ${SERVICE_NAME}.service enabled and started."
}

write_logrotate() {
  local f="/etc/logrotate.d/${SERVICE_NAME}"
  cat > "$f" <<EOF
/var/log/odoo/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su ${DEFAULT_SYSTEM_USER} ${DEFAULT_SYSTEM_USER}
    create 0640 ${DEFAULT_SYSTEM_USER} ${DEFAULT_SYSTEM_USER}
}
EOF
  ok "Wrote logrotate config $f."
}

write_nginx_site() {
  [ -n "$ODOO_DOMAIN" ] || { info "No domain — skipping nginx site."; return 0; }

  local websock_path="/websocket"
  is_modern_odoo || websock_path="/longpolling"

  local site="/etc/nginx/sites-available/${SERVICE_NAME}"
  info "Writing nginx site $site"

  # NOTE: nginx variables are escaped (\$var) so bash doesn't expand them.
  cat > "$site" <<EOF
# Managed by odoo-installer ${SCRIPT_VERSION}.

upstream ${SERVICE_NAME}_http {
    server 127.0.0.1:8069;
}
upstream ${SERVICE_NAME}_chat {
    server 127.0.0.1:8072;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen      80;
    listen      [::]:80;
    server_name ${ODOO_DOMAIN};

    # Required for certbot http-01 challenge.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Logs
    access_log /var/log/nginx/${SERVICE_NAME}-access.log;
    error_log  /var/log/nginx/${SERVICE_NAME}-error.log;

    # Upload size for attachments / imports
    client_max_body_size 200m;

    # Proxy buffer settings
    proxy_buffers     16 64k;
    proxy_buffer_size 128k;
    proxy_read_timeout    720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout    720s;

    # Compression
    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types text/plain text/xml text/css text/less application/x-javascript
               application/javascript application/json application/xml image/svg+xml;
    gzip_vary on;

    # Long-polling / websocket (path differs per Odoo version).
    location ${websock_path} {
        proxy_pass http://${SERVICE_NAME}_chat;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location / {
        proxy_pass http://${SERVICE_NAME}_http;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;

        # Cache long-lived web assets
        location ~* /web/(static|content|image)/ {
            proxy_pass http://${SERVICE_NAME}_http;
            proxy_cache_valid 200 60m;
            proxy_buffering on;
            expires 864000;
        }
    }
}
EOF

  ln -sfn "$site" "/etc/nginx/sites-enabled/${SERVICE_NAME}"
  # Remove the stock default if it's still active to avoid host name clashes.
  if [ -e /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  install -d -m 755 /var/www/html
  if ! nginx -t >/dev/null 2>&1; then
    nginx -t || true
    die "nginx configuration test failed."
  fi
  systemctl reload nginx
  ok "Nginx site ${SERVICE_NAME} enabled."
}

setup_tls() {
  [ "$WANT_TLS" = "Y" ] || return 0
  [ -n "$ODOO_DOMAIN" ] || { warn "TLS requested but no domain; skipping."; return 0; }

  apt-get install -y -qq certbot python3-certbot-nginx
  local email="${TLS_EMAIL:-admin@${ODOO_DOMAIN}}"
  info "Requesting Let's Encrypt certificate for $ODOO_DOMAIN"
  if certbot --nginx -d "$ODOO_DOMAIN" \
       --non-interactive --agree-tos -m "$email" \
       --redirect; then
    ok "TLS configured for $ODOO_DOMAIN."
  else
    warn "certbot failed. Ensure DNS resolves and port 80 is reachable, then run:"
    warn "  certbot --nginx -d $ODOO_DOMAIN --agree-tos -m $email --redirect"
  fi
}

setup_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  detect_ssh_port
  info "Configuring UFW (SSH port=${SSH_PORT})"

  ufw allow "${SSH_PORT}/tcp" >/dev/null
  ufw allow OpenSSH >/dev/null 2>&1 || true

  if [ -n "$ODOO_DOMAIN" ]; then
    ufw allow 'Nginx Full' >/dev/null 2>&1 || {
      ufw allow 80/tcp  >/dev/null
      ufw allow 443/tcp >/dev/null
    }
  fi
  # Lock down direct Odoo ports so only the proxy hits them.
  ufw deny 8069/tcp >/dev/null 2>&1 || true
  ufw deny 8072/tcp >/dev/null 2>&1 || true

  if ! ufw status | grep -q "Status: active"; then
    yes | ufw enable >/dev/null
    ok "UFW enabled."
  else
    ufw reload >/dev/null
    ok "UFW already active; rules updated."
  fi
}

setup_fail2ban() {
  $DO_FAIL2BAN || return 0
  apt-get install -y -qq fail2ban
  local jail="/etc/fail2ban/jail.d/${SERVICE_NAME}.local"
  cat > "$jail" <<EOF
[sshd]
enabled = true
port = ${SSH_PORT:-22}
maxretry = 5
findtime = 10m
bantime = 1h

[odoo-auth]
enabled  = true
port     = http,https
filter   = odoo-auth
logpath  = /var/log/odoo/${SERVICE_NAME}.log
maxretry = 10
findtime = 10m
bantime  = 1h
EOF
  cat > /etc/fail2ban/filter.d/odoo-auth.conf <<'EOF'
[Definition]
failregex = ^.*Login failed for db:.* login:.* from <HOST>.*$
ignoreregex =
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || true
  ok "fail2ban configured."
}

write_helper_scripts() {
  local deploy="/usr/local/bin/${SERVICE_NAME}-deploy-addons"
  local backup="/usr/local/bin/${SERVICE_NAME}-backup"

  info "Writing helper scripts"

  cat > "$deploy" <<EOF
#!/usr/bin/env bash
# Update custom addons and restart Odoo. Generated by odoo-installer.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR}"
SERVICE_NAME="${SERVICE_NAME}"
SYSTEM_USER="${DEFAULT_SYSTEM_USER}"
ADDONS_DIR="\${INSTALL_DIR}/custom-addons"

mkdir -p "\$ADDONS_DIR"
chown -R "\$SYSTEM_USER":"\$SYSTEM_USER" "\$ADDONS_DIR"

# If the custom-addons folder is itself a git repo, pull latest.
if [ -d "\$ADDONS_DIR/.git" ]; then
  sudo -u "\$SYSTEM_USER" git -C "\$ADDONS_DIR" pull --rebase --autostash || true
fi
# Or pull every sub-repo individually.
for d in "\$ADDONS_DIR"/*/.git; do
  [ -d "\$d" ] || continue
  repo="\$(dirname "\$d")"
  echo "→ updating \$repo"
  sudo -u "\$SYSTEM_USER" git -C "\$repo" pull --rebase --autostash || true
done

systemctl restart "\${SERVICE_NAME}.service"
echo "✓ \${SERVICE_NAME}.service restarted."
echo
echo "To upgrade a module in a specific DB:"
echo "  sudo -u \$SYSTEM_USER \$INSTALL_DIR/venv/bin/python3 \\"
echo "       \$INSTALL_DIR/odoo/odoo-bin -c /etc/\${SERVICE_NAME}.conf \\"
echo "       -d <db_name> -u <module_name> --stop-after-init"
EOF
  chmod 755 "$deploy"

  cat > "$backup" <<EOF
#!/usr/bin/env bash
# Back up an Odoo database + filestore. Generated by odoo-installer.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR}"
SERVICE_NAME="${SERVICE_NAME}"
SYSTEM_USER="${DEFAULT_SYSTEM_USER}"
POSTGRES_USER="${POSTGRES_USER}"
BACKUP_DIR="\${BACKUP_DIR:-\${INSTALL_DIR}/backups}"

if [ \$# -lt 1 ]; then
  echo "Usage: \$0 <db_name> [output_dir]"; exit 1
fi
DB="\$1"
OUT="\${2:-\$BACKUP_DIR}"
mkdir -p "\$OUT"
STAMP="\$(date +%Y%m%d-%H%M%S)"

DUMP="\$OUT/\${DB}-\${STAMP}.sql.gz"
FS="\$OUT/\${DB}-\${STAMP}-filestore.tar.gz"

echo "→ dumping database \$DB"
sudo -u postgres pg_dump -Fp "\$DB" | gzip -9 > "\$DUMP"

FILESTORE="\${INSTALL_DIR}/data/filestore/\$DB"
if [ -d "\$FILESTORE" ]; then
  echo "→ archiving filestore"
  tar -C "\$(dirname "\$FILESTORE")" -czf "\$FS" "\$(basename "\$FILESTORE")"
fi

chown "\$SYSTEM_USER":"\$SYSTEM_USER" "\$DUMP" "\$FS" 2>/dev/null || true
echo "✓ Backup written:"
echo "    \$DUMP"
[ -f "\$FS" ] && echo "    \$FS"
EOF
  chmod 755 "$backup"

  ok "Helpers: $deploy , $backup"
}

health_check() {
  info "Running post-install health check"
  sleep 3
  local failures=0

  if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    ok "${SERVICE_NAME}.service is active."
  else
    warn "${SERVICE_NAME}.service is NOT active."
    failures=$((failures+1))
  fi

  if ss -lnt 2>/dev/null | grep -q ":8069 "; then
    ok "Odoo is listening on port 8069."
  else
    warn "Nothing is listening on 8069 yet (give it a few seconds, then re-check)."
    failures=$((failures+1))
  fi

  if [ -n "$ODOO_DOMAIN" ] && systemctl is-active --quiet nginx; then
    ok "nginx is active."
  fi

  if [ "$failures" -gt 0 ]; then
    warn "Health check found ${failures} issue(s). Inspect:"
    warn "  journalctl -u ${SERVICE_NAME}.service -n 100 --no-pager"
  else
    ok "All health checks passed."
  fi
}

print_summary() {
  local access
  if [ -n "$ODOO_DOMAIN" ] && [ "$WANT_TLS" = "Y" ]; then
    access="https://${ODOO_DOMAIN}"
  elif [ -n "$ODOO_DOMAIN" ]; then
    access="http://${ODOO_DOMAIN}"
  else
    access="http://<server-ip>:8069"
  fi
  cat <<EOF

================================================================
                  INSTALLATION COMPLETE
================================================================
Service        : ${SERVICE_NAME}.service
Config file    : /etc/${SERVICE_NAME}.conf
Source code    : ${INSTALL_DIR}/odoo
Virtualenv     : ${INSTALL_DIR}/venv
Custom addons  : ${INSTALL_DIR}/custom-addons
Data dir       : ${INSTALL_DIR}/data
Backups dir    : ${INSTALL_DIR}/backups
State file     : ${STATE_FILE}   (mode 0600, secrets inside)

Useful commands:
  systemctl status ${SERVICE_NAME}.service
  journalctl -u ${SERVICE_NAME}.service -f
  /usr/local/bin/${SERVICE_NAME}-deploy-addons
  /usr/local/bin/${SERVICE_NAME}-backup <db_name>

Access:
  ${access}

EOF
}

# =============================================================================
# Main
# =============================================================================
main() {
  # Parse args first so --help / --version work without sudo.
  parse_args "$@"
  init_log
  require_root

  detect_os
  detect_arch
  detect_resources

  load_state

  # Apply defaults for anything still empty after state load.
  : "${INSTALL_DIR:=$DEFAULT_INSTALL_DIR}"
  : "${POSTGRES_USER:=$DEFAULT_POSTGRES_USER}"
  : "${ODOO_BRANCH:=$DEFAULT_BRANCH}"
  : "${WANT_WKHTMLTOPDF:=N}"
  : "${WANT_TLS:=N}"

  collect_config
  save_state

  maybe_create_swap
  apt_install
  detect_python
  setup_user_and_dirs
  setup_postgres
  fetch_odoo_source
  setup_venv
  install_wkhtmltopdf
  write_odoo_config
  write_systemd_service
  write_logrotate
  write_nginx_site
  setup_tls
  setup_firewall
  setup_fail2ban
  write_helper_scripts
  health_check
  print_summary
}

main "$@"
