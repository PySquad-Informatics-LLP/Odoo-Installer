#!/usr/bin/env bash
#
# Odoo Installer
# Production-grade, idempotent, resumable installer for Odoo on Debian/Ubuntu.
#
# Tested targets:
#   - Ubuntu 20.04 / 22.04 / 24.04 (and newer LTS); cloud images on
#     AWS / Azure / GCP / DigitalOcean / Hetzner
#   - Debian 11 / 12 / 13 (and newer)
#   - x86_64 (amd64) and aarch64 (arm64)
#
# Highlights:
#   - Multi-version coexistence: install 17 / 18 / 19 side-by-side. Each major
#     gets its own install dir, venv, service, config, ports and nginx site.
#   - Resilient: optional steps that fail do NOT abort the whole run; a report
#     at the end shows exactly what succeeded / failed / was skipped.
#   - Resumable: every step is idempotent, so just re-run after fixing an issue.
#   - Cloud-friendly: waits for apt/dpkg locks and retries flaky network ops
#     (the usual cause of failures on fresh Azure/GCP VMs).
#   - Robust wkhtmltopdf: tries multiple patched builds + deps, verifies the
#     result, and only then falls back to the distro package.
#
# Usage:  sudo ./install_odoo.sh --help

set -Eeuo pipefail

# =============================================================================
# Constants & defaults
# =============================================================================
readonly SCRIPT_VERSION="3.0.1"
readonly STATE_FILE="/etc/odoo-installer.conf"
readonly LEGACY_STATE_FILE="/etc/odoo_installer.conf"
readonly DEFAULT_BASE_DIR="/opt/odoo"
readonly DEFAULT_BRANCH="19.0"
readonly DEFAULT_POSTGRES_USER="odoo"
readonly DEFAULT_SYSTEM_USER="odoo"
readonly PY_MIN_MINOR=10            # Odoo 17/18/19 require Python >= 3.10

LOG_FILE="/var/log/odoo-installer.log"

# Runtime flags
NON_INTERACTIVE=false
ASSUME_YES=false
DO_APT_UPGRADE=false
DO_FAIL2BAN=false
DO_SWAP=false
SWAP_GB=2
SSH_PORT=""
RESET_STATE=false
DEMO=false
WORKERS_OVERRIDE=""
TIME_CPU_OVERRIDE=""
TIME_REAL_OVERRIDE=""

# Detection results
OS_ID=""
OS_LIKE=""
OS_CODENAME=""
OS_VERSION=""
ARCH=""
CPU_COUNT=2
RAM_MB=2048
PYTHON_BIN=""

# Persisted / configurable values
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
HTTP_PORT="${HTTP_PORT:-}"
GEVENT_PORT="${GEVENT_PORT:-}"

# Odoo Enterprise (optional, private repo)
WANT_ENTERPRISE="${WANT_ENTERPRISE:-}"
ENTERPRISE_REPO="${ENTERPRISE_REPO:-}"
ENTERPRISE_REF="${ENTERPRISE_REF:-}"
ENTERPRISE_TOKEN="${ENTERPRISE_TOKEN:-}"
ENTERPRISE_SSH_KEY="${ENTERPRISE_SSH_KEY:-}"

# Step bookkeeping (for the end-of-run report)
STEPS_OK=()
STEPS_FAILED=()

# =============================================================================
# Logging
# =============================================================================
_color() {
  if [ -t 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi
}
_log_to_file() {
  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; } 2>/dev/null || true
}
info() { _color "1;34" "→ $*"; _log_to_file "INFO  $*"; }
warn() { _color "1;33" "⚠ $*"; _log_to_file "WARN  $*"; }
err()  { _color "1;31" "✗ $*"; _log_to_file "ERROR $*"; }
ok()   { _color "1;32" "✓ $*"; _log_to_file "OK    $*"; }
die()  { err "$*"; exit 1; }

on_error() {
  local exit_code=$?
  trap - ERR
  err "Installer aborted at line $1 (exit $exit_code). See $LOG_FILE."
  err "Completed steps are idempotent — fix the issue above and re-run the script."
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
# Generic resilience helpers
# =============================================================================

# with_retries TRIES CMD...  — run CMD, retrying with exponential backoff.
with_retries() {
  local tries="$1"; shift
  local n=1 delay=5
  while true; do
    if "$@"; then return 0; fi
    if [ "$n" -ge "$tries" ]; then return 1; fi
    warn "Attempt ${n}/${tries} failed; retrying in ${delay}s ..."
    sleep "$delay"
    n=$((n + 1)); delay=$((delay * 2))
  done
}

# Wait until no other process holds the apt/dpkg locks (common on cloud boot,
# where unattended-upgrades runs at first login and breaks naive installers).
wait_apt_lock() {
  command -v fuser >/dev/null 2>&1 || return 0
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
              /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ "$waited" -eq 0 ] && info "Waiting for another apt/dpkg process to finish ..."
    sleep 5; waited=$((waited + 5))
    if [ "$waited" -ge 600 ]; then
      warn "apt lock still held after 10 min; proceeding (apt's own lock timeout will apply)."
      return 0
    fi
  done
}

apt_get() {
  wait_apt_lock
  with_retries 3 apt-get \
    -o DPkg::Lock::Timeout=600 \
    -o Acquire::Retries=3 \
    "$@"
}

# Install optional packages; if the batch fails (e.g. one name differs across
# releases), fall back to installing them one at a time and skip the missing.
apt_install_optional() {
  if apt_get install -y -qq "$@" >/dev/null 2>&1; then return 0; fi
  warn "Some optional packages unavailable as a batch; installing individually."
  local p
  for p in "$@"; do
    apt_get install -y -qq "$p" >/dev/null 2>&1 \
      || warn "Skipping unavailable package: $p"
  done
}

# run_step NAME REQUIRED FUNC
#   REQUIRED = "required" → failure aborts the whole installer
#   REQUIRED = "optional" → failure is recorded and the installer continues
# The function runs in a subshell so a failure cannot leave errexit in a weird
# state; only filesystem/system side effects persist (steps never set globals).
run_step() {
  local name="$1" required="$2" fn="$3"
  info "[step] ${name}"
  set +e
  ( trap - ERR; "$fn" )
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    STEPS_OK+=("$name")
    return 0
  fi
  if [ "$required" = required ]; then
    STEPS_FAILED+=("$name (required)")
    die "Required step '${name}' failed (exit ${rc}). Resolve it and re-run."
  fi
  STEPS_FAILED+=("$name")
  warn "Optional step '${name}' failed (exit ${rc}); continuing."
  return 0
}

# =============================================================================
# Help
# =============================================================================
usage() {
  cat <<EOF
Odoo installer v${SCRIPT_VERSION}

Usage: sudo $0 [OPTIONS]

Core:
  --domain DOMAIN          Domain to serve Odoo on (empty = IP-only access)
  --branch BRANCH          Odoo branch/tag, e.g. 19.0 / 18.0 (default: ${DEFAULT_BRANCH})
  --install-dir PATH       Install directory (default: ${DEFAULT_BASE_DIR}/<major>)
  --postgres-user NAME     PostgreSQL role name (default: ${DEFAULT_POSTGRES_USER})
  --admin-pass PASSWORD    Odoo master/admin password (auto-generated if empty)
  --http-port PORT         Odoo HTTP port (default: auto, 8069 for v19)
  --gevent-port PORT       Odoo gevent/longpolling port (default: http-port + 3)

Tuning:
  --workers N              Number of Odoo workers (default: auto from CPU)
  --limit-time-cpu N       Per-request CPU seconds (default: 60)
  --limit-time-real N      Per-request wall-clock seconds (default: 120)
  --demo                   Demo preset: fewer workers + relaxed timeouts so
                           heavy module installs via the web UI don't get killed

Extras:
  --wkhtmltopdf            Install patched wkhtmltopdf (for crisp PDF reports)
  --tls                    Configure Let's Encrypt TLS (requires --domain)
  --tls-email EMAIL        Email for Let's Encrypt notifications
  --fail2ban               Install and enable fail2ban
  --swap-gb N              Create N GiB swap file if no swap present
  --ssh-port PORT          SSH port to allow in UFW (auto-detected by default)
  --apt-upgrade            Run \`apt upgrade\` first (skipped by default)

Enterprise:
  --enterprise             Enable Odoo Enterprise (clones the private repo)
  --enterprise-repo URL    Enterprise git URL
                           (default: https://github.com/odoo/enterprise.git)
  --enterprise-ref REF     Enterprise branch/tag (defaults to --branch value)
  --enterprise-token TOKEN GitHub PAT for HTTPS clone of the enterprise repo
  --enterprise-ssh-key F   Path to SSH private key for SSH-based enterprise clone

Behavior:
  --non-interactive        Never prompt; use flags / env vars / state file
  --yes, -y                Assume "yes" to confirmation prompts
  --reset                  Ignore previously saved state file
  --help, -h               Show this help and exit
  --version                Show installer version and exit

Examples:
  sudo $0
  sudo $0 --branch 18.0 --domain erp18.example.com --tls --tls-email me@x.com
  sudo $0 --branch 19.0 --domain erp19.example.com --tls --tls-email me@x.com
  sudo ODOO_ADMIN_PASS='s3cret' $0 --non-interactive --yes \\
       --domain erp.example.com --branch 19.0 --wkhtmltopdf
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
      if [[ " $OS_LIKE " == *" debian "* ]] || [[ " $OS_LIKE " == *" ubuntu "* ]]; then
        warn "Distribution '$OS_ID' is unsupported but Debian-like; continuing."
        [[ " $OS_LIKE " == *" ubuntu "* ]] && OS_ID="ubuntu" || OS_ID="debian"
      else
        die "Unsupported distribution '$OS_ID'. This installer targets Debian/Ubuntu."
      fi
      ;;
  esac

  # Some minimal cloud images don't set VERSION_CODENAME; derive a best guess.
  if [ -z "$OS_CODENAME" ] && command -v lsb_release >/dev/null 2>&1; then
    OS_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
  fi
  ok "Detected $OS_ID ${OS_VERSION:-?} (${OS_CODENAME:-unknown codename})"
}

detect_arch() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) ARCH="$m"; warn "Unusual architecture: $m (some binaries may be unavailable)" ;;
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
  p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' \
        /etc/ssh/sshd_config 2>/dev/null || true)"
  if [ -z "$p" ] && [ -d /etc/ssh/sshd_config.d ]; then
    p="$(grep -rhE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config.d 2>/dev/null \
          | awk '{print $2; exit}' || true)"
  fi
  SSH_PORT="${p:-22}"
}

# =============================================================================
# Small helpers
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
  local b="${1:-}"
  if [[ "$b" =~ ^([0-9]+)\.([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [ "$b" = "master" ]; then
    echo "99"
  else
    echo "0"
  fi
}

is_modern_odoo() {
  local maj; maj="$(odoo_major "${ODOO_BRANCH:-}")"
  [ "$maj" -ge 17 ] 2>/dev/null
}

# Deterministic, collision-free default ports per major version.
# v19 keeps the canonical 8069/8072; others offset by ±10 per major.
derive_ports() {
  local maj; maj="$(odoo_major "$ODOO_BRANCH")"
  if [ -z "$HTTP_PORT" ]; then
    if [ "$maj" -ge 1 ] 2>/dev/null; then
      HTTP_PORT=$(( 8069 + (maj - 19) * 10 ))
    else
      HTTP_PORT=8069
    fi
    [ "$HTTP_PORT" -lt 1024 ] && HTTP_PORT=8069
  fi
  [ -z "$GEVENT_PORT" ] && GEVENT_PORT=$(( HTTP_PORT + 3 ))
}

validate_domain() {
  local d="$1"
  [ -z "$d" ] && return 0
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Invalid domain: '$d'"
}

validate_port() {
  local p="$1" what="$2"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] \
    || die "Invalid ${what}: '$p'"
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
HTTP_PORT="${HTTP_PORT}"
GEVENT_PORT="${GEVENT_PORT}"
WANT_WKHTMLTOPDF="${WANT_WKHTMLTOPDF}"
WANT_TLS="${WANT_TLS}"
TLS_EMAIL="${TLS_EMAIL}"
SERVICE_NAME="${SERVICE_NAME}"
WANT_ENTERPRISE="${WANT_ENTERPRISE}"
ENTERPRISE_REPO="${ENTERPRISE_REPO}"
ENTERPRISE_REF="${ENTERPRISE_REF}"
ENTERPRISE_TOKEN="${ENTERPRISE_TOKEN}"
ENTERPRISE_SSH_KEY="${ENTERPRISE_SSH_KEY}"
EOF
  chown root:root "$STATE_FILE"
  chmod 600 "$STATE_FILE"
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
    [ "$p1" = "$p2" ]  || { warn "Passwords didn't match. Try again."; continue; }
    [ -n "$p1" ]       || { warn "Password cannot be empty.";          continue; }
    [ "${#p1}" -ge 8 ] || { warn "Use at least 8 characters.";         continue; }
    printf -v "$var" '%s' "$p1"
    break
  done
}

confirm() {
  $ASSUME_YES      && return 0
  $NON_INTERACTIVE && return 0
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
      --domain)             ODOO_DOMAIN="${2:-}"; shift 2 ;;
      --branch)             ODOO_BRANCH="${2:-}"; shift 2 ;;
      --install-dir)        INSTALL_DIR="${2:-}"; shift 2 ;;
      --postgres-user)      POSTGRES_USER="${2:-}"; shift 2 ;;
      --admin-pass)         ODOO_ADMIN_PASS="${2:-}"; shift 2 ;;
      --http-port)          HTTP_PORT="${2:-}"; shift 2 ;;
      --gevent-port)        GEVENT_PORT="${2:-}"; shift 2 ;;
      --workers)            WORKERS_OVERRIDE="${2:-}"; shift 2 ;;
      --limit-time-cpu)     TIME_CPU_OVERRIDE="${2:-}"; shift 2 ;;
      --limit-time-real)    TIME_REAL_OVERRIDE="${2:-}"; shift 2 ;;
      --demo)               DEMO=true; shift ;;
      --wkhtmltopdf)        WANT_WKHTMLTOPDF="Y"; shift ;;
      --tls)                WANT_TLS="Y"; shift ;;
      --tls-email)          TLS_EMAIL="${2:-}"; shift 2 ;;
      --fail2ban)           DO_FAIL2BAN=true; shift ;;
      --swap-gb)            DO_SWAP=true; SWAP_GB="${2:-2}"; shift 2 ;;
      --ssh-port)           SSH_PORT="${2:-}"; shift 2 ;;
      --apt-upgrade)        DO_APT_UPGRADE=true; shift ;;
      --enterprise)         WANT_ENTERPRISE="Y"; shift ;;
      --enterprise-repo)    ENTERPRISE_REPO="${2:-}"; WANT_ENTERPRISE="Y"; shift 2 ;;
      --enterprise-ref)     ENTERPRISE_REF="${2:-}"; shift 2 ;;
      --enterprise-token)   ENTERPRISE_TOKEN="${2:-}"; WANT_ENTERPRISE="Y"; shift 2 ;;
      --enterprise-ssh-key) ENTERPRISE_SSH_KEY="${2:-}"; WANT_ENTERPRISE="Y"; shift 2 ;;
      --non-interactive)    NON_INTERACTIVE=true; shift ;;
      --yes|-y)             ASSUME_YES=true; shift ;;
      --reset)              RESET_STATE=true; shift ;;
      --help|-h)            usage; exit 0 ;;
      --version)            echo "$SCRIPT_VERSION"; exit 0 ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
  done
}

# =============================================================================
# Collect configuration
# =============================================================================
collect_config() {
  prompt_default ODOO_BRANCH "Git branch/tag for Odoo (e.g. 19.0, 18.0)" \
    "${ODOO_BRANCH:-$DEFAULT_BRANCH}"
  local maj; maj="$(odoo_major "$ODOO_BRANCH")"

  # Versioned default install dir so multiple majors coexist cleanly.
  local default_dir="$DEFAULT_BASE_DIR"
  [ "$maj" -ge 1 ] 2>/dev/null && default_dir="${DEFAULT_BASE_DIR}/${maj}"
  prompt_default INSTALL_DIR "Install directory" "${INSTALL_DIR:-$default_dir}"

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
  prompt_yn WANT_WKHTMLTOPDF "Install patched wkhtmltopdf?" "${WANT_WKHTMLTOPDF:-N}"

  prompt_yn WANT_ENTERPRISE "Install Odoo Enterprise edition?" "${WANT_ENTERPRISE:-N}"
  if [ "$WANT_ENTERPRISE" = "Y" ]; then
    prompt_default ENTERPRISE_REPO "Enterprise git URL" \
      "${ENTERPRISE_REPO:-https://github.com/odoo/enterprise.git}"
    prompt_default ENTERPRISE_REF "Enterprise branch/tag" \
      "${ENTERPRISE_REF:-$ODOO_BRANCH}"
    case "$ENTERPRISE_REPO" in
      https://*)
        if [ -z "$ENTERPRISE_TOKEN" ] && ! $NON_INTERACTIVE; then
          read -rsp "GitHub PAT (Enter to skip if auth is preconfigured): " ENTERPRISE_TOKEN || true
          echo
        fi
        ;;
      git@*|ssh://*)
        prompt_default ENTERPRISE_SSH_KEY \
          "Path to SSH private key (Enter to use odoo user's default keys)" \
          "${ENTERPRISE_SSH_KEY:-}"
        ;;
    esac
  fi

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
  SERVICE_NAME="odoo${maj}"
  [ "$maj" -eq 0 ] && SERVICE_NAME="odoo"
  derive_ports

  # Sanity checks
  [[ "$INSTALL_DIR" = /* ]] || die "INSTALL_DIR must be an absolute path."
  [[ "$POSTGRES_USER" =~ ^[a-z_][a-z0-9_]*$ ]] \
    || die "Invalid PostgreSQL role name: '$POSTGRES_USER'."
  [ -n "$ODOO_ADMIN_PASS" ] || die "Admin password is required."
  validate_port "$HTTP_PORT" "HTTP port"
  validate_port "$GEVENT_PORT" "gevent port"
  [ "$HTTP_PORT" != "$GEVENT_PORT" ] || die "HTTP and gevent ports must differ."

  local ent_summary="N"
  if [ "$WANT_ENTERPRISE" = "Y" ]; then
    ent_summary="Y  (repo: ${ENTERPRISE_REPO}, ref: ${ENTERPRISE_REF:-$ODOO_BRANCH})"
  fi

  cat <<EOF

Configuration summary:
  Odoo branch ....... ${ODOO_BRANCH}  (major: ${maj})
  Install dir ....... ${INSTALL_DIR}
  Service name ...... ${SERVICE_NAME}.service
  HTTP / gevent ..... ${HTTP_PORT} / ${GEVENT_PORT}
  Domain ............ ${ODOO_DOMAIN:-<none>}
  Postgres role ..... ${POSTGRES_USER}
  Enterprise ........ ${ent_summary}
  wkhtmltopdf ....... ${WANT_WKHTMLTOPDF}
  TLS / Certbot ..... ${WANT_TLS}${TLS_EMAIL:+ (email: $TLS_EMAIL)}
  Demo preset ....... $($DEMO && echo Y || echo N)
  Workers ........... ${WORKERS_OVERRIDE:-auto}
  apt upgrade ....... $($DO_APT_UPGRADE && echo Y || echo N)
  fail2ban .......... $($DO_FAIL2BAN && echo Y || echo N)
  Swap file ......... $($DO_SWAP && echo "${SWAP_GB} GiB" || echo N)
  State file ........ ${STATE_FILE}
EOF

  confirm "Proceed with installation?" || die "Aborted by user."
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
  local path="/swapfile" size_kb=$(( SWAP_GB * 1024 * 1024 ))
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
  apt_get update -qq || die "apt-get update failed after retries (network/mirror issue?)."

  if $DO_APT_UPGRADE; then
    info "Running 'apt upgrade' (this may take a while)"
    apt_get upgrade -y -qq || warn "apt upgrade reported errors; continuing."
  fi

  # Required: without these the install cannot proceed.
  local required_pkgs=(
    git build-essential wget curl ca-certificates gnupg
    python3 python3-venv python3-dev python3-pip
    libxml2-dev libxslt1-dev libssl-dev libffi-dev
    libsasl2-dev libldap2-dev libjpeg-dev zlib1g-dev libpq-dev
    postgresql postgresql-contrib
    nodejs npm node-less
  )
  # Optional: nice-to-have or release-specific names (handled one-by-one if the
  # batch fails, so a renamed/missing package never aborts the install).
  # The libwheel/-dev set below covers the headers Odoo's Python wheels need to
  # compile from source when a prebuilt wheel isn't available for the platform.
  local optional_pkgs=(
    lsb-release software-properties-common python3-wheel python3-setuptools
    pkg-config
    libfreetype6-dev liblcms2-dev libwebp-dev libharfbuzz-dev
    libfribidi-dev libxcb1-dev libzip-dev libpng-dev
    libtiff5-dev libtiff-dev
    libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev libgdk-pixbuf2.0-dev
    libpq-dev libmagic1
    rustc cargo
    nginx ufw rsync logrotate
    fontconfig xfonts-base xfonts-75dpi
  )

  info "Installing required packages"
  apt_get install -y -qq "${required_pkgs[@]}" \
    || die "Failed to install required packages. See $LOG_FILE."

  info "Installing optional packages"
  apt_install_optional "${optional_pkgs[@]}"
  ok "System packages installed."
}

# Odoo compiles web assets with:
#   - libsass (Python, from requirements.txt) for SCSS
#   - lessc + less-plugin-clean-css for legacy LESS bundles
#   - rtlcss for right-to-left languages
# Debian's node-less package supplies lessc; npm globals supply the rest.
setup_node_assets() {
  command -v npm >/dev/null 2>&1 || {
    warn "npm not found; attempting to install nodejs/npm ..."
    apt_install_optional nodejs npm node-less || {
      warn "Could not install nodejs/npm — SCSS/LESS asset compilation may fail."
      return 1
    }
  }

  info "Installing Node.js asset compilers (less-plugin-clean-css, rtlcss)"
  # Odoo's official source-install docs require these npm globals.
  with_retries 2 npm install -g less-plugin-clean-css rtlcss >>"$LOG_FILE" 2>&1 \
    || warn "npm global install failed; asset compilation may break for RTL/LESS."

  local missing=0
  if command -v lessc >/dev/null 2>&1; then
    ok "lessc available: $(lessc --version 2>&1 | head -n1)"
  else
    warn "lessc not in PATH — install node-less or: npm install -g less"
    missing=$((missing + 1))
  fi
  if command -v rtlcss >/dev/null 2>&1; then
    ok "rtlcss available: $(rtlcss --version 2>&1 | head -n1)"
  else
    warn "rtlcss not in PATH — run: npm install -g rtlcss"
    missing=$((missing + 1))
  fi
  [ "$missing" -eq 0 ] && ok "Node asset tooling ready." || return 1
}

_find_python() {
  local p
  for p in python3.12 python3.11 python3.10; do
    if command -v "$p" >/dev/null 2>&1; then
      PYTHON_BIN="$(command -v "$p")"
      ok "Using $PYTHON_BIN ($("$p" --version 2>&1))"
      return 0
    fi
  done
  if command -v python3 >/dev/null 2>&1 \
     && python3 -c "import sys; sys.exit(0 if sys.version_info[:2] >= (3, ${PY_MIN_MINOR}) else 1)" 2>/dev/null; then
    PYTHON_BIN="$(command -v python3)"
    ok "Using $PYTHON_BIN ($(python3 --version 2>&1))"
    return 0
  fi
  return 1
}

ensure_python() {
  _find_python && return 0

  warn "No Python >= 3.${PY_MIN_MINOR} found (required for Odoo ${ODOO_BRANCH})."
  if [ "$OS_ID" = ubuntu ]; then
    info "Attempting to install Python 3.12 from the deadsnakes PPA ..."
    apt_get install -y -qq software-properties-common >/dev/null 2>&1 || true
    if command -v add-apt-repository >/dev/null 2>&1; then
      with_retries 3 add-apt-repository -y ppa:deadsnakes/ppa >/dev/null 2>&1 \
        || warn "Could not add deadsnakes PPA."
      apt_get update -qq || true
      apt_install_optional python3.12 python3.12-venv python3.12-dev python3.12-distutils
      _find_python && return 0
    fi
  fi

  die "Python >= 3.${PY_MIN_MINOR} is required but could not be installed automatically.
     Install a suitable Python (e.g. python3.12 + python3.12-venv) and re-run."
}

setup_user_and_dirs() {
  if id -u "$DEFAULT_SYSTEM_USER" >/dev/null 2>&1; then
    info "System user '$DEFAULT_SYSTEM_USER' already exists."
  else
    # Home stays at the base dir so it's shared across versions.
    useradd -m -U -r -d "$DEFAULT_BASE_DIR" -s /bin/bash "$DEFAULT_SYSTEM_USER" \
      2>/dev/null \
      || useradd -U -r -s /bin/bash "$DEFAULT_SYSTEM_USER"
    ok "Created system user '$DEFAULT_SYSTEM_USER'."
  fi
  install -d -m 755 -o "$DEFAULT_SYSTEM_USER" -g "$DEFAULT_SYSTEM_USER" \
    "$DEFAULT_BASE_DIR" "$INSTALL_DIR" "$INSTALL_DIR/custom-addons" /var/log/odoo
  install -d -m 750 -o "$DEFAULT_SYSTEM_USER" -g "$DEFAULT_SYSTEM_USER" \
    "$INSTALL_DIR/backups"
}

setup_postgres() {
  systemctl enable --now postgresql >/dev/null 2>&1 || true
  systemctl is-active --quiet postgresql || die "PostgreSQL service is not running."

  if sudo -u postgres psql -tAc \
       "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'" 2>/dev/null | grep -q 1; then
    info "PostgreSQL role '${POSTGRES_USER}' exists; updating password."
  else
    sudo -u postgres createuser --createdb --no-superuser --no-createrole "${POSTGRES_USER}" \
      || die "Failed to create PostgreSQL role '${POSTGRES_USER}'."
    ok "Created PostgreSQL role '${POSTGRES_USER}'."
  fi
  sudo -u postgres psql -v ON_ERROR_STOP=1 -qc \
    "ALTER ROLE \"${POSTGRES_USER}\" WITH LOGIN PASSWORD '${POSTGRES_PASS//\'/\'\'}';" \
    || die "Failed to set password for PostgreSQL role '${POSTGRES_USER}'."
  ok "PostgreSQL role configured."
}

# Detect a usable git checkout; recover from partial/corrupt directories.
_git_is_healthy() {
  sudo -u "$DEFAULT_SYSTEM_USER" git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

fetch_odoo_source() {
  local src="${INSTALL_DIR}/odoo"
  local url="https://github.com/odoo/odoo.git"

  if [ -d "$src" ] && ! _git_is_healthy "$src"; then
    warn "Existing $src is not a healthy git repo; re-cloning."
    rm -rf "$src"
  fi

  if _git_is_healthy "$src"; then
    info "Updating Odoo source in $src"
    sudo -u "$DEFAULT_SYSTEM_USER" git -C "$src" remote set-url origin "$url"
    with_retries 3 sudo -u "$DEFAULT_SYSTEM_USER" \
      git -C "$src" fetch --depth 1 origin "$ODOO_BRANCH" \
      || die "Failed to fetch branch '$ODOO_BRANCH' from odoo/odoo."
    sudo -u "$DEFAULT_SYSTEM_USER" git -C "$src" reset --hard FETCH_HEAD
  else
    info "Cloning Odoo ${ODOO_BRANCH} into $src"
    rm -rf "$src"
    with_retries 3 sudo -u "$DEFAULT_SYSTEM_USER" \
      git clone --depth 1 --branch "$ODOO_BRANCH" "$url" "$src" \
      || die "git clone failed for branch '$ODOO_BRANCH' (does it exist?)."
  fi
  ok "Odoo source ready."
}

fetch_enterprise_source() {
  [ "${WANT_ENTERPRISE:-N}" = "Y" ] || return 0

  local src="${INSTALL_DIR}/enterprise"
  local repo="${ENTERPRISE_REPO:-https://github.com/odoo/enterprise.git}"
  local ref="${ENTERPRISE_REF:-$ODOO_BRANCH}"
  local odoo_home
  odoo_home="$(getent passwd "$DEFAULT_SYSTEM_USER" | cut -d: -f6 || true)"
  [ -n "$odoo_home" ] || die "Could not resolve home directory for ${DEFAULT_SYSTEM_USER}."
  local -a git_env=("GIT_TERMINAL_PROMPT=0" "HOME=${odoo_home}")

  case "$repo" in
    https://*)
      if [ -n "$ENTERPRISE_TOKEN" ]; then
        local cred_file="${odoo_home}/.git-credentials"
        local host_path="${repo#https://}"
        local host="${host_path%%/*}"
        umask 077
        if [ -f "$cred_file" ]; then
          sed -i.bak "\\#://[^@]*@${host}\$#d" "$cred_file" 2>/dev/null || true
          rm -f "${cred_file}.bak"
        fi
        echo "https://x-access-token:${ENTERPRISE_TOKEN}@${host}" >> "$cred_file"
        chown "$DEFAULT_SYSTEM_USER":"$DEFAULT_SYSTEM_USER" "$cred_file"
        chmod 600 "$cred_file"
        sudo -u "$DEFAULT_SYSTEM_USER" \
          git config --global "credential.https://${host}.helper" \
          "store --file=${cred_file}" >/dev/null
        ok "Stored GitHub credentials for ${host} (mode 0600)."
      fi
      ;;
    git@*|ssh://*)
      if [ -n "$ENTERPRISE_SSH_KEY" ]; then
        [ -r "$ENTERPRISE_SSH_KEY" ] || die "Enterprise SSH key not readable: $ENTERPRISE_SSH_KEY"
        local odoo_ssh_dir="${odoo_home}/.ssh"
        local deployed_key="${odoo_ssh_dir}/enterprise_deploy_key"
        install -d -m 700 -o "$DEFAULT_SYSTEM_USER" -g "$DEFAULT_SYSTEM_USER" "$odoo_ssh_dir"
        install -m 600 -o "$DEFAULT_SYSTEM_USER" -g "$DEFAULT_SYSTEM_USER" \
          "$ENTERPRISE_SSH_KEY" "$deployed_key"
        git_env+=("GIT_SSH_COMMAND=ssh -i ${deployed_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new")
        sudo -u "$DEFAULT_SYSTEM_USER" git config --global core.sshCommand \
          "ssh -i ${deployed_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" >/dev/null
        ok "Installed enterprise SSH deploy key at ${deployed_key}."
      fi
      ;;
    *) warn "Unrecognized enterprise URL scheme: $repo. Trying anyway." ;;
  esac

  if [ -d "$src" ] && ! _git_is_healthy "$src"; then
    warn "Existing $src is not a healthy git repo; re-cloning."
    rm -rf "$src"
  fi

  if _git_is_healthy "$src"; then
    info "Updating Odoo Enterprise source in $src"
    sudo -u "$DEFAULT_SYSTEM_USER" git -C "$src" remote set-url origin "$repo"
    with_retries 3 sudo -u "$DEFAULT_SYSTEM_USER" env "${git_env[@]}" \
        git -C "$src" fetch --depth 1 origin "$ref" \
      || die "Failed to fetch enterprise ref '$ref'. Check credentials/access."
    sudo -u "$DEFAULT_SYSTEM_USER" git -C "$src" reset --hard FETCH_HEAD
  else
    info "Cloning Odoo Enterprise ${ref} into $src"
    rm -rf "$src"
    with_retries 3 sudo -u "$DEFAULT_SYSTEM_USER" env "${git_env[@]}" \
        git clone --depth 1 --branch "$ref" "$repo" "$src" \
      || die "git clone failed for enterprise repo. Verify access to $repo."
  fi
  ok "Enterprise source ready at $src."
}

# Suggest the apt -dev package most likely needed for a failed pip requirement.
_apt_hint_for() {
  local pkg; pkg="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$pkg" in
    *lxml*)                 echo "libxml2-dev libxslt1-dev" ;;
    *psycopg2*)             echo "libpq-dev" ;;
    *ldap*)                 echo "libldap2-dev libsasl2-dev" ;;
    *pillow*)               echo "libjpeg-dev zlib1g-dev libfreetype6-dev liblcms2-dev libwebp-dev libtiff-dev" ;;
    *cryptography*|*pyopenssl*) echo "libssl-dev libffi-dev rustc cargo" ;;
    *cffi*)                 echo "libffi-dev" ;;
    *gevent*|*greenlet*)    echo "build-essential python3-dev" ;;
    *cairo*|*weasyprint*)   echo "libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev pkg-config" ;;
    *python-magic*)         echo "libmagic1" ;;
    *)                      echo "the matching -dev system library (see the pip error in $LOG_FILE)" ;;
  esac
}

# Install Odoo's requirements robustly:
#   1) try the whole file at once (best for version resolution),
#   2) if that fails, install line-by-line so the maximum number succeed,
#   3) report the few that failed with a concrete apt remediation hint.
# Returns 0 if everything installed, 1 if some packages could not be installed
# (the caller warns but does NOT abort — Odoo may still run, and the operator
# gets an exact list of what to fix and how).
install_requirements() {
  local req="$1"
  local venv="${INSTALL_DIR}/venv"
  local pip=("$venv/bin/pip" install --no-input)

  if with_retries 2 sudo -u "$DEFAULT_SYSTEM_USER" "${pip[@]}" -r "$req" >>"$LOG_FILE" 2>&1; then
    return 0
  fi

  warn "Bulk requirements install failed; retrying package-by-package ..."
  local failed=() line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"      # ltrim
    line="${line%"${line##*[![:space:]]}"}"      # rtrim
    [ -z "$line" ] && continue
    case "$line" in -*) continue ;; esac          # skip pip flags / -r includes
    # The log redirect is performed by root (correct: root owns the log file).
    # shellcheck disable=SC2024
    if ! sudo -u "$DEFAULT_SYSTEM_USER" "${pip[@]}" "$line" >>"$LOG_FILE" 2>&1; then
      warn "  ✗ could not install: ${line}"
      failed+=("$line")
    fi
  done < "$req"

  [ "${#failed[@]}" -eq 0 ] && return 0

  local report="/var/log/odoo-installer-pip-failures.txt"
  {
    echo "# Packages that failed to install on $(date)"
    echo "# Install the suggested apt package(s), then re-run the installer or:"
    echo "#   sudo -u ${DEFAULT_SYSTEM_USER} ${venv}/bin/pip install '<package>'"
    echo
    local f
    for f in "${failed[@]}"; do
      printf '%-40s  → apt install %s\n' "$f" "$(_apt_hint_for "$f")"
    done
  } > "$report" 2>/dev/null || true

  warn "${#failed[@]} Python package(s) failed to install. Remediation written to:"
  warn "  $report"
  return 1
}

setup_venv() {
  local venv="${INSTALL_DIR}/venv"

  # Recreate the venv if it's missing or broken (e.g. a half-finished prior run).
  if [ ! -x "$venv/bin/python" ] \
     || ! sudo -u "$DEFAULT_SYSTEM_USER" "$venv/bin/python" -c 'import sys' >/dev/null 2>&1; then
    [ -e "$venv" ] && { warn "Recreating virtualenv at $venv"; rm -rf "$venv"; }
    info "Creating Python virtualenv at $venv"
    sudo -u "$DEFAULT_SYSTEM_USER" "$PYTHON_BIN" -m venv "$venv" \
      || die "Failed to create virtualenv (is python3-venv installed for $PYTHON_BIN?)."
  fi

  # Make sure the dev headers for THIS interpreter are present (the generic
  # python3-dev can point at a different minor version than $PYTHON_BIN, e.g.
  # when python3.12 came from deadsnakes). This is what lets C-extension
  # wheels (gevent, greenlet, …) build from source if no wheel is available.
  local pyver
  pyver="$("$PYTHON_BIN" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
  [ -n "$pyver" ] && apt_install_optional "python${pyver}-dev"

  # A recent pip is the single biggest factor in avoiding source builds — it
  # pulls manylinux wheels for most packages. Upgrade it first.
  with_retries 3 sudo -u "$DEFAULT_SYSTEM_USER" "$venv/bin/pip" install --quiet --upgrade pip wheel \
    || warn "pip/wheel upgrade failed; continuing."

  # setuptools < 81 still ships pkg_resources, which gevent (and others) import.
  # Newer setuptools removed it and breaks Odoo at startup, so pin it here.
  with_retries 3 sudo -u "$DEFAULT_SYSTEM_USER" "$venv/bin/pip" install --quiet 'setuptools<81' \
    || die "Failed to install setuptools<81."

  if [ -f "${INSTALL_DIR}/odoo/requirements.txt" ]; then
    info "Installing Odoo Python requirements (this can take several minutes)"
    if ! install_requirements "${INSTALL_DIR}/odoo/requirements.txt"; then
      warn "Some Python requirements failed to install (see the report above)."
      warn "Odoo may still start; install the listed -dev libs and re-run to finish."
    fi
  fi

  # Restore pkg_resources if a dependency dragged in a too-new setuptools.
  if ! sudo -u "$DEFAULT_SYSTEM_USER" "$venv/bin/python" -c 'import pkg_resources' >/dev/null 2>&1; then
    warn "pkg_resources missing; reinstalling 'setuptools<81'."
    sudo -u "$DEFAULT_SYSTEM_USER" "$venv/bin/pip" install --quiet --force-reinstall 'setuptools<81' \
      || warn "Could not restore setuptools<81; Odoo may fail to start."
  fi

  # libsass compiles SCSS → CSS. Without it you get "Style compilation failed".
  if ! sudo -u "$DEFAULT_SYSTEM_USER" "$venv/bin/python" -c 'import sass' >/dev/null 2>&1; then
    warn "libsass missing from venv; installing ..."
    local libsass_ver="0.22.0"
    "$venv/bin/python" -c 'import sys; sys.exit(0 if sys.version_info < (3, 11) else 1)' 2>/dev/null \
      && libsass_ver="0.20.1"
    sudo -u "$DEFAULT_SYSTEM_USER" "$venv/bin/pip" install --quiet "libsass==${libsass_ver}" \
      || warn "Could not install libsass — SCSS asset compilation will fail."
  fi

  ok "Python environment ready."
}

# Build candidate "version codename" pairs to try, most-preferred first.
_wkhtml_candidates() {
  case "$OS_ID/$OS_CODENAME" in
    ubuntu/focal)    echo "0.12.6.1-2 focal" ;;
    ubuntu/jammy)    echo "0.12.6.1-3 jammy"; echo "0.12.6.1-2 jammy" ;;
    ubuntu/noble)    echo "0.12.6.1-3 jammy" ;;            # no native noble build
    ubuntu/oracular) echo "0.12.6.1-3 jammy" ;;
    debian/bullseye) echo "0.12.6.1-2 bullseye" ;;
    debian/bookworm) echo "0.12.6.1-3 bookworm" ;;
    debian/trixie)   echo "0.12.6.1-3 bookworm" ;;
    *)               echo "0.12.6.1-3 bookworm"; echo "0.12.6.1-3 jammy" ;;
  esac
}

_wkhtml_is_patched() {
  command -v wkhtmltopdf >/dev/null 2>&1 || return 1
  wkhtmltopdf --version 2>&1 | grep -qi 'with patched qt'
}

install_wkhtmltopdf() {
  [ "$WANT_WKHTMLTOPDF" = "Y" ] || return 0

  if _wkhtml_is_patched; then
    info "Patched wkhtmltopdf already present: $(wkhtmltopdf --version 2>&1 | head -n1)"
    return 0
  fi

  local ver codename url deb
  while read -r ver codename; do
    [ -n "$ver" ] || continue
    url="https://github.com/wkhtmltopdf/packaging/releases/download/${ver}/wkhtmltox_${ver}.${codename}_${ARCH}.deb"
    deb="/tmp/wkhtmltox_${ver}.${codename}_${ARCH}.deb"
    info "Trying wkhtmltopdf ${ver} (${codename}/${ARCH})"
    if with_retries 3 wget -q -O "$deb" "$url"; then
      # `apt-get install ./file.deb` resolves the .deb's dependencies too.
      if apt_get install -y -qq "$deb" || { apt-get -f install -y -qq && dpkg -i "$deb"; }; then
        rm -f "$deb"
        if _wkhtml_is_patched; then
          ok "wkhtmltopdf installed: $(wkhtmltopdf --version 2>&1 | head -n1)"
          return 0
        fi
      fi
    fi
    rm -f "$deb"
    warn "Candidate ${ver}/${codename} did not work; trying next."
  done < <(_wkhtml_candidates)

  warn "Could not install a patched wkhtmltopdf; falling back to the distro package."
  warn "PDF reports will still work but rendering may be less precise."
  apt_install_optional wkhtmltopdf
  if _wkhtml_is_patched; then
    ok "Distro wkhtmltopdf is patched: $(wkhtmltopdf --version 2>&1 | head -n1)"
  else
    warn "Installed wkhtmltopdf is the unpatched build (acceptable for most reports)."
  fi
}

write_odoo_config() {
  local conf="/etc/${SERVICE_NAME}.conf"
  local workers max_cron mem_soft mem_hard time_cpu time_real

  if [ -n "$WORKERS_OVERRIDE" ]; then
    workers="$WORKERS_OVERRIDE"
  elif $DEMO; then
    workers=2
  else
    workers=$(( CPU_COUNT * 2 + 1 ))
    [ "$workers" -lt 2 ] && workers=2
    [ "$workers" -gt 16 ] && workers=16
  fi
  max_cron=$(( CPU_COUNT > 2 ? 2 : 1 ))

  # Memory budget: ~75% of RAM split across (workers + cron), with a floor.
  local slots=$(( workers + max_cron )); [ "$slots" -lt 1 ] && slots=1
  local per_worker_mb=$(( RAM_MB * 75 / 100 / slots ))
  local floor=640; $DEMO && floor=1024
  [ "$per_worker_mb" -lt "$floor" ] && per_worker_mb="$floor"
  mem_soft=$(( per_worker_mb * 1024 * 1024 ))
  mem_hard=$(( per_worker_mb * 1024 * 1024 * 5 / 4 ))

  if [ -n "$TIME_CPU_OVERRIDE" ]; then time_cpu="$TIME_CPU_OVERRIDE"
  elif $DEMO; then time_cpu=1800; else time_cpu=60; fi
  if [ -n "$TIME_REAL_OVERRIDE" ]; then time_real="$TIME_REAL_OVERRIDE"
  elif $DEMO; then time_real=3600; else time_real=120; fi

  local http_key gevent_key
  if is_modern_odoo; then http_key="http_port"; gevent_key="gevent_port"
  else http_key="xmlrpc_port"; gevent_key="longpolling_port"; fi

  # Enterprise must precede community so its overrides win.
  local addons_path="${INSTALL_DIR}/odoo/addons,${INSTALL_DIR}/custom-addons"
  if [ -d "${INSTALL_DIR}/enterprise" ]; then
    addons_path="${INSTALL_DIR}/enterprise,${addons_path}"
    ok "Enterprise addons detected; prepended to addons_path."
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
addons_path = ${addons_path}
data_dir = ${INSTALL_DIR}/data
logfile = /var/log/odoo/${SERVICE_NAME}.log
log_level = info
${http_key} = ${HTTP_PORT}
${gevent_key} = ${GEVENT_PORT}
proxy_mode = True

workers = ${workers}
max_cron_threads = ${max_cron}
limit_memory_soft = ${mem_soft}
limit_memory_hard = ${mem_hard}
limit_time_cpu = ${time_cpu}
limit_time_real = ${time_real}
limit_request = 8192
EOF
  chown "$DEFAULT_SYSTEM_USER":"$DEFAULT_SYSTEM_USER" "$conf"
  chmod 640 "$conf"
  install -d -m 750 -o "$DEFAULT_SYSTEM_USER" -g "$DEFAULT_SYSTEM_USER" "${INSTALL_DIR}/data"
  ok "Wrote $conf (workers=${workers}, mem/worker=${per_worker_mb} MiB, time_real=${time_real}s)."
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
/var/log/odoo/${SERVICE_NAME}.log {
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
  command -v nginx >/dev/null 2>&1 || { warn "nginx not installed; skipping site."; return 1; }

  local websock_path="/websocket"
  is_modern_odoo || websock_path="/longpolling"
  local site="/etc/nginx/sites-available/${SERVICE_NAME}"
  info "Writing nginx site $site"

  cat > "$site" <<EOF
# Managed by odoo-installer ${SCRIPT_VERSION}.
upstream ${SERVICE_NAME}_http { server 127.0.0.1:${HTTP_PORT}; }
upstream ${SERVICE_NAME}_chat { server 127.0.0.1:${GEVENT_PORT}; }

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen      80;
    listen      [::]:80;
    server_name ${ODOO_DOMAIN};

    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }

    access_log /var/log/nginx/${SERVICE_NAME}-access.log;
    error_log  /var/log/nginx/${SERVICE_NAME}-error.log;

    client_max_body_size 200m;
    proxy_buffers     16 64k;
    proxy_buffer_size 128k;
    proxy_read_timeout    720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout    720s;

    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types text/plain text/xml text/css text/less application/x-javascript
               application/javascript application/json application/xml image/svg+xml;
    gzip_vary on;

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
  [ -e /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default
  install -d -m 755 /var/www/html
  if ! nginx -t >/dev/null 2>&1; then
    nginx -t || true
    die "nginx configuration test failed."
  fi
  systemctl reload nginx || systemctl restart nginx
  ok "Nginx site ${SERVICE_NAME} enabled."
}

setup_tls() {
  [ "$WANT_TLS" = "Y" ] || return 0
  [ -n "$ODOO_DOMAIN" ] || { warn "TLS requested but no domain; skipping."; return 0; }

  apt_get install -y -qq certbot python3-certbot-nginx || {
    warn "Could not install certbot; skipping TLS."; return 1; }
  local email="${TLS_EMAIL:-admin@${ODOO_DOMAIN}}"
  info "Requesting Let's Encrypt certificate for $ODOO_DOMAIN"
  if certbot --nginx -d "$ODOO_DOMAIN" --non-interactive --agree-tos -m "$email" --redirect; then
    ok "TLS configured for $ODOO_DOMAIN."
  else
    warn "certbot failed (DNS not pointing here yet, or port 80 blocked). Re-run later:"
    warn "  certbot --nginx -d $ODOO_DOMAIN --agree-tos -m $email --redirect"
    return 1
  fi
}

setup_firewall() {
  command -v ufw >/dev/null 2>&1 || { warn "ufw not installed; skipping firewall."; return 0; }
  detect_ssh_port
  info "Configuring UFW (SSH port=${SSH_PORT})"

  ufw allow "${SSH_PORT}/tcp" >/dev/null
  ufw allow OpenSSH >/dev/null 2>&1 || true
  if [ -n "$ODOO_DOMAIN" ]; then
    ufw allow 'Nginx Full' >/dev/null 2>&1 || { ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; }
  fi
  ufw deny "${HTTP_PORT}/tcp" >/dev/null 2>&1 || true
  ufw deny "${GEVENT_PORT}/tcp" >/dev/null 2>&1 || true

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
  apt_get install -y -qq fail2ban || { warn "Could not install fail2ban."; return 1; }
  detect_ssh_port
  cat > "/etc/fail2ban/jail.d/${SERVICE_NAME}.local" <<EOF
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
  local instmod="/usr/local/bin/${SERVICE_NAME}-install-module"
  local regassets="/usr/local/bin/${SERVICE_NAME}-regenerate-assets"
  info "Writing helper scripts"

  cat > "$deploy" <<EOF
#!/usr/bin/env bash
# Update custom addons (and Enterprise, if present) then restart Odoo.
set -euo pipefail
INSTALL_DIR="${INSTALL_DIR}"
SERVICE_NAME="${SERVICE_NAME}"
SYSTEM_USER="${DEFAULT_SYSTEM_USER}"
ADDONS_DIR="\${INSTALL_DIR}/custom-addons"
ENTERPRISE_DIR="\${INSTALL_DIR}/enterprise"

mkdir -p "\$ADDONS_DIR"
chown -R "\$SYSTEM_USER":"\$SYSTEM_USER" "\$ADDONS_DIR"

if [ -d "\$ADDONS_DIR/.git" ]; then
  sudo -u "\$SYSTEM_USER" git -C "\$ADDONS_DIR" pull --rebase --autostash || true
fi
for d in "\$ADDONS_DIR"/*/.git; do
  [ -d "\$d" ] || continue
  repo="\$(dirname "\$d")"; echo "→ updating \$repo"
  sudo -u "\$SYSTEM_USER" git -C "\$repo" pull --rebase --autostash || true
done
if [ -d "\$ENTERPRISE_DIR/.git" ]; then
  echo "→ updating \$ENTERPRISE_DIR"
  sudo -u "\$SYSTEM_USER" git -C "\$ENTERPRISE_DIR" pull --rebase --autostash \\
    || echo "  ⚠ enterprise pull failed (check credentials)"
fi

systemctl restart "\${SERVICE_NAME}.service"
echo "✓ \${SERVICE_NAME}.service restarted."
EOF
  chmod 755 "$deploy"

  cat > "$instmod" <<EOF
#!/usr/bin/env bash
# Install or update Odoo modules from the CLI (avoids web-UI worker timeouts).
set -euo pipefail
INSTALL_DIR="${INSTALL_DIR}"
SERVICE_NAME="${SERVICE_NAME}"
SYSTEM_USER="${DEFAULT_SYSTEM_USER}"

if [ \$# -lt 2 ]; then
  echo "Usage: \$0 <db_name> <module[,module,...]> [--update]"
  echo "  default action installs (-i); pass --update to upgrade (-u)."
  exit 1
fi
DB="\$1"; MODS="\$2"; FLAG="-i"
[ "\${3:-}" = "--update" ] && FLAG="-u"

echo "→ stopping \${SERVICE_NAME}.service"
systemctl stop "\${SERVICE_NAME}.service" || true
echo "→ \${FLAG} \${MODS} on database \${DB}"
sudo -u "\$SYSTEM_USER" "\$INSTALL_DIR/venv/bin/python3" "\$INSTALL_DIR/odoo/odoo-bin" \\
  -c "/etc/\${SERVICE_NAME}.conf" -d "\$DB" "\$FLAG" "\$MODS" --stop-after-init
echo "→ starting \${SERVICE_NAME}.service"
systemctl start "\${SERVICE_NAME}.service"
echo "✓ done."
EOF
  chmod 755 "$instmod"

  cat > "$regassets" <<EOF
#!/usr/bin/env bash
# Regenerate web asset bundles (fixes "Style compilation failed" after a
# database restore or when lessc/rtlcss/libsass were missing at first boot).
set -euo pipefail
INSTALL_DIR="${INSTALL_DIR}"
SERVICE_NAME="${SERVICE_NAME}"
SYSTEM_USER="${DEFAULT_SYSTEM_USER}"

if [ \$# -lt 1 ]; then
  echo "Usage: \$0 <db_name>"
  echo "  Clears cached web assets and upgrades the 'web' module to recompile CSS/JS."
  exit 1
fi
DB="\$1"

echo "→ checking asset compilers"
for cmd in lessc rtlcss; do
  command -v "\$cmd" >/dev/null 2>&1 || { echo "✗ missing: \$cmd"; echo "  fix: sudo npm install -g rtlcss  &&  sudo apt install node-less"; exit 1; }
done
sudo -u "\$SYSTEM_USER" "\$INSTALL_DIR/venv/bin/python" -c 'import sass' 2>/dev/null \\
  || { echo "✗ libsass not installed in venv"; echo "  fix: sudo -u \$SYSTEM_USER \$INSTALL_DIR/venv/bin/pip install libsass"; exit 1; }

echo "→ stopping \${SERVICE_NAME}.service"
systemctl stop "\${SERVICE_NAME}.service" || true

echo "→ clearing cached asset attachments in \${DB}"
sudo -u postgres psql -d "\$DB" -v ON_ERROR_STOP=1 -qc \\
  "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';"

ASSET_CACHE="\${INSTALL_DIR}/data/filestore/\${DB}/assets"
if [ -d "\$ASSET_CACHE" ]; then
  echo "→ removing filestore asset cache"
  rm -rf "\$ASSET_CACHE"
fi

echo "→ upgrading web module (forces SCSS/LESS recompilation)"
sudo -u "\$SYSTEM_USER" "\$INSTALL_DIR/venv/bin/python3" "\$INSTALL_DIR/odoo/odoo-bin" \\
  -c "/etc/\${SERVICE_NAME}.conf" -d "\$DB" -u web --stop-after-init

echo "→ starting \${SERVICE_NAME}.service"
systemctl start "\${SERVICE_NAME}.service"
echo "✓ Asset bundles regenerated. Hard-refresh your browser (Ctrl+Shift+R)."
EOF
  chmod 755 "$regassets"

  cat > "$backup" <<EOF
#!/usr/bin/env bash
# Back up an Odoo database + filestore.
set -euo pipefail
INSTALL_DIR="${INSTALL_DIR}"
SYSTEM_USER="${DEFAULT_SYSTEM_USER}"
BACKUP_DIR="\${BACKUP_DIR:-\${INSTALL_DIR}/backups}"

[ \$# -lt 1 ] && { echo "Usage: \$0 <db_name> [output_dir]"; exit 1; }
DB="\$1"; OUT="\${2:-\$BACKUP_DIR}"; mkdir -p "\$OUT"
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
echo "✓ Backup written:"; echo "    \$DUMP"; [ -f "\$FS" ] && echo "    \$FS"
EOF
  chmod 755 "$backup"

  ok "Helpers: $deploy , $instmod , $regassets , $backup"
}

health_check() {
  info "Running post-install health check"
  sleep 3
  local failures=0

  if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    ok "${SERVICE_NAME}.service is active."
  else
    warn "${SERVICE_NAME}.service is NOT active."; failures=$((failures + 1))
  fi

  if ss -lnt 2>/dev/null | grep -q ":${HTTP_PORT} "; then
    ok "Odoo is listening on port ${HTTP_PORT}."
  else
    warn "Nothing listening on ${HTTP_PORT} yet (it may still be starting)."
    failures=$((failures + 1))
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -fsS -m 10 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/web/database/selector" 2>/dev/null; then
      ok "Odoo HTTP endpoint responded."
    else
      warn "Odoo HTTP endpoint did not respond yet (give it a moment)."
    fi
  fi

  [ -n "$ODOO_DOMAIN" ] && systemctl is-active --quiet nginx && ok "nginx is active."

  if command -v lessc >/dev/null 2>&1 && command -v rtlcss >/dev/null 2>&1; then
    ok "Asset compilers present (lessc, rtlcss)."
  else
    warn "Missing lessc or rtlcss — web style compilation will fail."
    failures=$((failures + 1))
  fi
  if sudo -u "$DEFAULT_SYSTEM_USER" "${INSTALL_DIR}/venv/bin/python" -c 'import sass' >/dev/null 2>&1; then
    ok "libsass importable in venv."
  else
    warn "libsass not importable — SCSS compilation will fail."
    failures=$((failures + 1))
  fi

  if [ "$failures" -gt 0 ]; then
    warn "Health check found ${failures} issue(s):"
    warn "  journalctl -u ${SERVICE_NAME}.service -n 100 --no-pager"
  else
    ok "All health checks passed."
  fi
}

print_report() {
  echo
  echo "----------------------------------------------------------------"
  echo "Step report:"
  local s
  for s in "${STEPS_OK[@]:-}";     do [ -n "$s" ] && printf '  \033[1;32m✓\033[0m %s\n' "$s"; done
  for s in "${STEPS_FAILED[@]:-}"; do [ -n "$s" ] && printf '  \033[1;31m✗\033[0m %s\n' "$s"; done
  echo "----------------------------------------------------------------"
}

print_summary() {
  local access
  if [ -n "$ODOO_DOMAIN" ] && [ "$WANT_TLS" = "Y" ]; then access="https://${ODOO_DOMAIN}"
  elif [ -n "$ODOO_DOMAIN" ]; then access="http://${ODOO_DOMAIN}"
  else access="http://<server-ip>:${HTTP_PORT}"; fi

  cat <<EOF

================================================================
                  INSTALLATION COMPLETE
================================================================
Service        : ${SERVICE_NAME}.service
Config file    : /etc/${SERVICE_NAME}.conf
HTTP / gevent  : ${HTTP_PORT} / ${GEVENT_PORT}
Source code    : ${INSTALL_DIR}/odoo
$([ -d "${INSTALL_DIR}/enterprise" ] && echo "Enterprise     : ${INSTALL_DIR}/enterprise" || echo "Enterprise     : not installed (use --enterprise to enable)")
Virtualenv     : ${INSTALL_DIR}/venv
Custom addons  : ${INSTALL_DIR}/custom-addons
Data dir       : ${INSTALL_DIR}/data
Backups dir    : ${INSTALL_DIR}/backups
State file     : ${STATE_FILE}   (mode 0600, secrets inside)

Useful commands:
  systemctl status ${SERVICE_NAME}.service
  journalctl -u ${SERVICE_NAME}.service -f
  ${SERVICE_NAME}-install-module <db> <module[,module]>   # CLI install (no UI timeout)
  ${SERVICE_NAME}-regenerate-assets <db>                 # fix style/CSS errors after restore
  ${SERVICE_NAME}-deploy-addons                            # pull addons + restart
  ${SERVICE_NAME}-backup <db_name>                         # dump db + filestore

Access:
  ${access}

EOF
}

# =============================================================================
# Main
# =============================================================================
main() {
  parse_args "$@"          # first, so --help / --version work without sudo
  init_log
  require_root

  detect_os
  detect_arch
  detect_resources

  load_state
  : "${POSTGRES_USER:=$DEFAULT_POSTGRES_USER}"
  : "${ODOO_BRANCH:=$DEFAULT_BRANCH}"
  : "${WANT_WKHTMLTOPDF:=N}"
  : "${WANT_TLS:=N}"

  collect_config
  save_state
  detect_ssh_port

  # --- Resilient install phase -------------------------------------------
  run_step "Swap file"            optional maybe_create_swap
  run_step "System packages"      required apt_install
  run_step "Node asset compilers" required setup_node_assets
  ensure_python                                              # sets PYTHON_BIN
  run_step "System user & dirs"   required setup_user_and_dirs
  run_step "PostgreSQL role"      required setup_postgres
  run_step "Odoo source"          required fetch_odoo_source
  run_step "Enterprise source"    required fetch_enterprise_source
  run_step "Python virtualenv"    required setup_venv
  run_step "wkhtmltopdf"          optional install_wkhtmltopdf
  run_step "Odoo config"          required write_odoo_config
  run_step "systemd service"      required write_systemd_service
  run_step "logrotate"            optional write_logrotate
  run_step "nginx site"           optional write_nginx_site
  run_step "TLS (certbot)"        optional setup_tls
  run_step "Firewall (UFW)"       optional setup_firewall
  run_step "fail2ban"             optional setup_fail2ban
  run_step "Helper scripts"       optional write_helper_scripts
  health_check

  print_report
  print_summary

  if [ "${#STEPS_FAILED[@]}" -gt 0 ]; then
    warn "Some optional steps failed (see report above). Odoo itself should be running."
    warn "Fix the listed items and re-run the script — it will resume safely."
  fi
}

main "$@"
