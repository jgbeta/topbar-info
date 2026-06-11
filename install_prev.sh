#!/usr/bin/env bash
# LAN IP top-bar installer for Indicator-SysMonitor
# - Installs indicator-sysmonitor (Ubuntu-family systems via PPA)
# - Validates apt package candidates before installing dependencies
# - Creates ~/.local/bin/ip-display (prints LAN IPv4)
# - Writes/merges ~/.indicator-sysmonitor.json custom sensor config
# - Optionally launches indicator-sysmonitor

# ---- Re-exec under bash if run via sh/dash ----
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -Eeuo pipefail

# ---- Defaults (override via env vars) ----
SENSOR_NAME="${SENSOR_NAME:-lanip}"
SENSOR_DESC="${SENSOR_DESC:-LAN IP}"
INTERVAL="${INTERVAL:-2}"                      # seconds
CUSTOM_TEXT="${CUSTOM_TEXT:-{lanip}}"          # panel format
SCRIPT_PATH="${SCRIPT_PATH:-$HOME/.local/bin/ip-display}"
CONFIG_PATH="${CONFIG_PATH:-$HOME/.indicator-sysmonitor.json}"

AUTO_START="${AUTO_START:-true}"               # true/false (string)
RUN_NOW="${RUN_NOW:-true}"                     # true/false (string)
INSTALL_NETTOOLS="${INSTALL_NETTOOLS:-false}"  # true/false (string) legacy ifconfig/route
APT_SETUP_MODE="${APT_SETUP_MODE:-prompt}"      # prompt/auto/skip
APT_REPAIR_SOURCES="${APT_REPAIR_SOURCES:-true}"   # true/false; write Ubuntu archive sources if candidates are missing
APT_REPAIR_SOURCES_PATH="${APT_REPAIR_SOURCES_PATH:-/etc/apt/sources.list.d/lanip-installer-ubuntu.sources}"
UBUNTU_ARCHIVE_URI="${UBUNTU_ARCHIVE_URI:-}"       # optional override, e.g. http://mirror.example/ubuntu
UBUNTU_SECURITY_URI="${UBUNTU_SECURITY_URI:-}"     # optional override

# ---- Apt/package defaults ----
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

INDICATOR_PPA="ppa:fossfreedom/indicator-sysmonitor"
INDICATOR_PACKAGE="indicator-sysmonitor"
NETTOOLS_PACKAGE="net-tools"

APT_COMPONENTS=(
  main
  universe
)

APT_REQUIRED_PACKAGES=(
  ca-certificates
  curl
  iproute2
  python3
  software-properties-common
  gir1.2-ayatanaappindicator3-0.1
)

MISSING_CANDIDATES=()

# ---- Helpers ----
info() { printf "\033[1;34m[i]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[x]\033[0m %s\n" "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

lower_trim() {
  local v="${1:-}"
  printf "%s" "$v" | tr '[:upper:]' '[:lower:]' | xargs
}

print_system_diagnostics() {
  printf "\nOS info:\n" >&2
  cat /etc/os-release >&2 2>/dev/null || true

  printf "\nArchitecture:\n" >&2
  if need_cmd dpkg; then
    dpkg --print-architecture >&2 || true
  else
    uname -m >&2 || true
  fi

  if (($# > 0)); then
    printf "\nAPT candidates:\n" >&2
    local pkg
    for pkg in "$@"; do
      printf "\napt-cache policy %s:\n" "$pkg" >&2
      apt-cache policy "$pkg" >&2 || true
    done
  fi
}

is_ubuntu_family() {
  local os_id="" os_id_like=""

  if [[ -r /etc/os-release ]]; then
    # /etc/os-release is shell-compatible key/value data provided by the OS.
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_id_like="${ID_LIKE:-}"
  fi

  [[ "$os_id" == "ubuntu" || " $os_id_like " == *" ubuntu "* ]]
}

require_ubuntu_family() {
  if is_ubuntu_family; then
    return 0
  fi

  warn "This installer supports Ubuntu-family apt systems."
  print_system_diagnostics
  err "Unsupported OS detected."
}

require_apt_commands() {
  need_cmd sudo || err "sudo is required to install apt packages."
  need_cmd apt-get || err "apt-get is required to install apt packages."
  need_cmd apt-cache || err "apt-cache is required to validate apt packages."
}

apt_update() {
  info "Updating apt package lists..."
  sudo apt-get update
}

apt_update_or_warn() {
  if ! apt_update; then
    warn "apt-get update failed. Continuing to candidate recovery; if it still fails, inspect the apt errors above."
  fi
}

apt_candidate_available() {
  local pkg="$1"
  local candidate=""

  candidate="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}' || true)"
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

collect_missing_candidates() {
  MISSING_CANDIDATES=()

  local pkg
  for pkg in "$@"; do
    if ! apt_candidate_available "$pkg"; then
      MISSING_CANDIDATES+=("$pkg")
    fi
  done
}

print_manual_setup_commands() {
  local include_nettools="${1:-false}"
  local packages=("${APT_REQUIRED_PACKAGES[@]}")
  local pkg codename archive_uri security_uri components sources_path signed_by_line

  if [[ "$include_nettools" == "true" ]]; then
    packages+=("$NETTOOLS_PACKAGE")
  fi

  codename="$(get_ubuntu_codename 2>/dev/null || printf "noble")"
  archive_uri="$(get_ubuntu_archive_uri)"
  security_uri="$(get_ubuntu_security_uri)"
  components="${APT_COMPONENTS[*]}"
  sources_path="$APT_REPAIR_SOURCES_PATH"
  signed_by_line=""
  if [[ -r /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
    signed_by_line="Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
  fi

  printf "\nManual apt setup commands:\n"
  printf "  sudo install -d -m 0755 /etc/apt/sources.list.d\n"
  printf "  sudo tee %q >/dev/null <<'EOF'\n" "$sources_path"
  printf "Types: deb\n"
  printf "URIs: %s\n" "$archive_uri"
  printf "Suites: %s %s-updates\n" "$codename" "$codename"
  printf "Components: %s\n" "$components"
  if [[ -n "$signed_by_line" ]]; then
    printf "%s\n" "$signed_by_line"
  fi
  printf "\n"
  printf "Types: deb\n"
  printf "URIs: %s\n" "$security_uri"
  printf "Suites: %s-security\n" "$codename"
  printf "Components: %s\n" "$components"
  if [[ -n "$signed_by_line" ]]; then
    printf "%s\n" "$signed_by_line"
  fi
  printf "EOF\n"
  printf "  sudo apt-get update\n"
  printf "  sudo apt-get install -y --no-install-recommends"
  for pkg in "${packages[@]}"; do
    printf " %s" "$pkg"
  done
  printf "\n"
  printf "  sudo add-apt-repository -y %s\n" "$INDICATOR_PPA"
  printf "  sudo apt-get update\n"
  printf "  sudo apt-get install -y %s\n" "$INDICATOR_PACKAGE"
  printf "  APT_SETUP_MODE=skip ./install.sh\n"
}

print_apt_setup_plan() {
  info "APT setup plan:"
  printf "  - Enable Ubuntu archive components if needed: %s\n" "${APT_COMPONENTS[*]}"
  if [[ "$APT_REPAIR_SOURCES" == "true" ]]; then
    printf "  - Repair Ubuntu archive source file if candidates are missing: %s\n" "$APT_REPAIR_SOURCES_PATH"
  fi
  printf "  - Install required packages: %s\n" "${APT_REQUIRED_PACKAGES[*]}"
  printf "  - Add Indicator-SysMonitor PPA: %s\n" "$INDICATOR_PPA"
  printf "  - Install app package: %s\n" "$INDICATOR_PACKAGE"

  if [[ "$INSTALL_NETTOOLS" == "true" ]]; then
    printf "  - Install optional package: %s\n" "$NETTOOLS_PACKAGE"
  fi
}

prompt_for_apt_setup() {
  if [[ ! -t 0 ]]; then
    warn "APT_SETUP_MODE=prompt requires an interactive terminal."
    print_manual_setup_commands "$INSTALL_NETTOOLS"
    err "Re-run with APT_SETUP_MODE=auto to let the installer use apt, or APT_SETUP_MODE=skip after manual setup."
  fi

  local choice=""
  while true; do
    printf "\nChoose how to handle system packages:\n"
    printf "  [i] Install using apt now\n"
    printf "  [m] Print manual commands and exit\n"
    printf "  [s] Skip apt setup and continue (only if already installed)\n"

    if ! read -r -p "Selection [i/m/s]: " choice; then
      err "No selection received. Re-run with APT_SETUP_MODE=auto or APT_SETUP_MODE=skip."
    fi

    choice="$(lower_trim "$choice")"
    case "$choice" in
      i|install|a|auto|y|yes)
        APT_SETUP_MODE="auto"
        return 0
        ;;
      m|manual)
        print_manual_setup_commands "$INSTALL_NETTOOLS"
        exit 1
        ;;
      s|skip)
        APT_SETUP_MODE="skip"
        info "Skipping apt setup. Continuing with user-level configuration only."
        return 1
        ;;
      *)
        warn "Please enter i, m, or s."
        ;;
    esac
  done
}

should_run_apt_setup() {
  if [[ "$APT_SETUP_MODE" == "skip" ]]; then
    info "APT_SETUP_MODE=skip; skipping apt repository and package setup."
    return 1
  fi

  print_apt_setup_plan

  if [[ "$APT_SETUP_MODE" == "auto" ]]; then
    return 0
  fi

  prompt_for_apt_setup
}

ensure_add_apt_repository() {
  if need_cmd add-apt-repository; then
    return 0
  fi

  if ! apt_candidate_available software-properties-common; then
    warn "Cannot install software-properties-common, so add-apt-repository is unavailable."
    return 1
  fi

  info "Installing software-properties-common for add-apt-repository..."
  sudo apt-get install -y --no-install-recommends software-properties-common
}

get_ubuntu_codename() {
  local codename=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  fi

  if [[ -z "$codename" ]] && need_cmd lsb_release; then
    codename="$(lsb_release -cs 2>/dev/null || true)"
  fi

  [[ -n "$codename" ]] || return 1
  printf "%s" "$codename"
}

get_ubuntu_archive_uri() {
  if [[ -n "${UBUNTU_ARCHIVE_URI:-}" ]]; then
    printf "%s" "$UBUNTU_ARCHIVE_URI"
    return 0
  fi

  local arch=""
  if need_cmd dpkg; then
    arch="$(dpkg --print-architecture 2>/dev/null || true)"
  fi

  case "$arch" in
    amd64|i386|"") printf "http://archive.ubuntu.com/ubuntu" ;;
    *)              printf "http://ports.ubuntu.com/ubuntu-ports" ;;
  esac
}

get_ubuntu_security_uri() {
  if [[ -n "${UBUNTU_SECURITY_URI:-}" ]]; then
    printf "%s" "$UBUNTU_SECURITY_URI"
    return 0
  fi

  local arch=""
  if need_cmd dpkg; then
    arch="$(dpkg --print-architecture 2>/dev/null || true)"
  fi

  case "$arch" in
    amd64|i386|"") printf "http://security.ubuntu.com/ubuntu" ;;
    *)              printf "http://ports.ubuntu.com/ubuntu-ports" ;;
  esac
}

write_ubuntu_archive_sources() {
  if [[ "$APT_REPAIR_SOURCES" != "true" ]]; then
    warn "APT_REPAIR_SOURCES=false; not writing Ubuntu archive sources."
    return 1
  fi

  local codename archive_uri security_uri components sources_path sources_dir tmp signed_by_line

  if ! codename="$(get_ubuntu_codename)"; then
    warn "Could not determine Ubuntu codename for apt source repair."
    return 1
  fi

  archive_uri="$(get_ubuntu_archive_uri)"
  security_uri="$(get_ubuntu_security_uri)"
  components="${APT_COMPONENTS[*]}"
  sources_path="$APT_REPAIR_SOURCES_PATH"
  sources_dir="$(dirname "$sources_path")"
  signed_by_line=""

  if [[ -r /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
    signed_by_line="Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
  else
    warn "Ubuntu archive keyring was not found at /usr/share/keyrings/ubuntu-archive-keyring.gpg; writing sources without Signed-By."
  fi

  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Created by $(basename "$0") because required Ubuntu package candidates were missing.
Types: deb
URIs: $archive_uri
Suites: $codename $codename-updates
Components: $components
$signed_by_line

Types: deb
URIs: $security_uri
Suites: $codename-security
Components: $components
$signed_by_line
EOF

  info "Writing Ubuntu archive source recovery file: $sources_path"
  sudo install -d -m 0755 "$sources_dir"

  if sudo test -e "$sources_path"; then
    local backup="${sources_path}.bak.$(date +%Y%m%d%H%M%S)"
    warn "Backing up existing recovery source file to: $backup"
    sudo cp -a "$sources_path" "$backup"
  fi

  sudo install -m 0644 "$tmp" "$sources_path"
  rm -f "$tmp"
}

try_add_apt_repository_components() {
  if ! is_ubuntu_family; then
    return 1
  fi

  if ! ensure_add_apt_repository; then
    return 1
  fi

  local component
  for component in "${APT_COMPONENTS[@]}"; do
    info "Enabling Ubuntu apt component: $component"
    if ! sudo add-apt-repository -y --no-update --component "$component"; then
      warn "Failed to enable Ubuntu apt component: $component"
      return 1
    fi
  done

  if ! apt_update; then
    warn "apt-get update failed after enabling apt components."
    return 1
  fi
}

try_recover_ubuntu_archive_sources() {
  local packages=("$@")

  if try_add_apt_repository_components; then
    collect_missing_candidates "${packages[@]}"
    if ((${#MISSING_CANDIDATES[@]} == 0)); then
      return 0
    fi
    warn "Candidates still missing after enabling components: ${MISSING_CANDIDATES[*]}"
  fi

  if write_ubuntu_archive_sources; then
    if apt_update; then
      collect_missing_candidates "${packages[@]}"
      if ((${#MISSING_CANDIDATES[@]} == 0)); then
        return 0
      fi
      warn "Candidates still missing after writing Ubuntu archive sources: ${MISSING_CANDIDATES[*]}"
    else
      warn "apt-get update failed after writing Ubuntu archive sources."
    fi
  fi

  return 1
}

fail_missing_candidates() {
  printf "\033[1;31m[x]\033[0m No install candidate found for: %s\n" "$*" >&2
  printf "Check your Ubuntu version, enabled repositories, apt sources, and architecture.\n" >&2

  local pkg
  for pkg in "$@"; do
    if [[ "$pkg" == "curl" ]]; then
      printf "On Ubuntu 24.04, curl missing a candidate usually means the base Ubuntu archive sources are disabled, stale, or broken.\n" >&2
      break
    fi
  done

  print_system_diagnostics "$@"
  print_manual_setup_commands "$INSTALL_NETTOOLS" >&2
  exit 1
}

ensure_apt_candidates() {
  local allow_component_recovery="$1"
  shift

  collect_missing_candidates "$@"
  if ((${#MISSING_CANDIDATES[@]} == 0)); then
    return 0
  fi

  warn "Missing apt install candidate(s): ${MISSING_CANDIDATES[*]}"

  if [[ "$allow_component_recovery" == "true" ]]; then
    if try_recover_ubuntu_archive_sources "$@"; then
      return 0
    fi
  fi

  fail_missing_candidates "${MISSING_CANDIDATES[@]}"
}

bool_norm() {
  # normalize string booleans to "true" or "false" (case-insensitive)
  local v
  v="$(lower_trim "${1:-}")"
  case "$v" in
    true|1|yes|y|on)  printf "true" ;;
    false|0|no|n|off) printf "false" ;;
    *) printf "false" ;;  # safe default
  esac
}

normalize_apt_setup_mode() {
  APT_SETUP_MODE="$(lower_trim "$APT_SETUP_MODE")"
  case "$APT_SETUP_MODE" in
    "") APT_SETUP_MODE="prompt" ;;
    prompt|auto|skip) ;;
    *) err "APT_SETUP_MODE must be one of: prompt, auto, skip." ;;
  esac
}

AUTO_START="$(bool_norm "$AUTO_START")"
RUN_NOW="$(bool_norm "$RUN_NOW")"
INSTALL_NETTOOLS="$(bool_norm "$INSTALL_NETTOOLS")"
APT_REPAIR_SOURCES="$(bool_norm "$APT_REPAIR_SOURCES")"
normalize_apt_setup_mode

# ---- Install indicator-sysmonitor (apt + PPA) ----
install_indicator_sysmonitor() {
  require_ubuntu_family

  if ! should_run_apt_setup; then
    return 0
  fi

  require_apt_commands
  apt_update_or_warn
  ensure_apt_candidates true "${APT_REQUIRED_PACKAGES[@]}"

  info "Installing required apt packages: ${APT_REQUIRED_PACKAGES[*]}"
  sudo apt-get install -y --no-install-recommends "${APT_REQUIRED_PACKAGES[@]}"

  ensure_add_apt_repository || err "add-apt-repository is unavailable after installing software-properties-common."

  info "Adding Indicator-SysMonitor PPA: $INDICATOR_PPA"
  if ! sudo add-apt-repository -y "$INDICATOR_PPA"; then
    err "Failed to add $INDICATOR_PPA."
  fi

  apt_update
  ensure_apt_candidates false "$INDICATOR_PACKAGE"

  info "Installing $INDICATOR_PACKAGE..."
  sudo apt-get install -y "$INDICATOR_PACKAGE"
}

maybe_install_nettools() {
  if [[ "$INSTALL_NETTOOLS" != "true" ]]; then
    return 0
  fi

  if [[ "$APT_SETUP_MODE" == "skip" ]]; then
    warn "INSTALL_NETTOOLS=true ignored because APT_SETUP_MODE=skip."
    return 0
  fi

  require_apt_commands
  ensure_apt_candidates true "$NETTOOLS_PACKAGE"
  info "Installing $NETTOOLS_PACKAGE (provides ifconfig/route for legacy fallback)..."
  sudo apt-get install -y --no-install-recommends "$NETTOOLS_PACKAGE"
}

# ---- Write the LAN IP script ----
write_ip_script() {
  info "Writing IP script: $SCRIPT_PATH"
  mkdir -p "$(dirname "$SCRIPT_PATH")"

  cat > "$SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Prefer iproute2; fallback to net-tools if present.

ip_address=""

if command -v ip >/dev/null 2>&1; then
  # Use a route lookup to find the default interface
  default_interface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -n "${default_interface:-}" ]]; then
    ip_address="$(ip -o -4 addr show dev "$default_interface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  fi
fi

if [[ -z "${ip_address:-}" ]] && command -v route >/dev/null 2>&1 && command -v ifconfig >/dev/null 2>&1; then
  default_interface="$(route -n 2>/dev/null | awk '$1 == "0.0.0.0" {print $8; exit}' || true)"
  if [[ -n "${default_interface:-}" ]]; then
    # Support both old and newer ifconfig output variants
    ip_address="$(ifconfig "$default_interface" 2>/dev/null \
      | awk '
        $0 ~ /inet (addr:)?/ {
          for(i=1;i<=NF;i++){
            if($i ~ /^addr:/){sub(/^addr:/,"",$i); print $i; exit}
            if($i == "inet"){print $(i+1); exit}
          }
        }' \
      | head -n1 || true)"
  fi
fi

# Last resort: first global IPv4 found
if [[ -z "${ip_address:-}" ]] && command -v ip >/dev/null 2>&1; then
  ip_address="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
fi

echo "${ip_address:- (no ip)}"
EOF

  chmod +x "$SCRIPT_PATH"
}

# ---- Merge/update ~/.indicator-sysmonitor.json ----
configure_indicator_sysmonitor() {
  need_cmd python3 || err "python3 is required. Re-run with APT_SETUP_MODE=auto, or install python3 manually."

  info "Configuring Indicator-SysMonitor: $CONFIG_PATH"

  python3 - <<PY
import json, os, sys

cfg_path = os.path.expanduser("${CONFIG_PATH}")
script_path = os.path.expanduser("${SCRIPT_PATH}")

sensor_name = "${SENSOR_NAME}".strip()
sensor_desc = "${SENSOR_DESC}".strip()
try:
    interval = int("${INTERVAL}")
except Exception:
    interval = 2

custom_text = "${CUSTOM_TEXT}"
auto_start = "${AUTO_START}".strip().lower() == "true"

# Load existing config if present
cfg = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f) or {}
    except Exception:
        cfg = {}

cfg.setdefault("sensors", {})

# Sensor format: name -> [description, command]
cfg["sensors"][sensor_name] = [sensor_desc, script_path]

# If user kept default token {lanip}, map it to {<sensor_name>}
cfg["custom_text"] = custom_text.replace("{lanip}", "{%s}" % sensor_name)

cfg["interval"] = interval
cfg["on_startup"] = auto_start

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f)

print("[i] Wrote:", cfg_path)
print("[i] Sensor:", sensor_name, "->", script_path)
print("[i] Panel text format:", cfg["custom_text"])
print("[i] Interval:", cfg["interval"], "seconds")
print("[i] Start on login:", cfg["on_startup"])
PY
}

# ---- Launch indicator-sysmonitor now (optional) ----
launch_indicator() {
  if [[ "$RUN_NOW" != "true" ]]; then
    info "RUN_NOW=false; skipping launch."
    return 0
  fi

  if ! need_cmd indicator-sysmonitor; then
    warn "indicator-sysmonitor not found in PATH yet. Try logging out/in."
    return 0
  fi

  # Avoid duplicates
  if pgrep -x indicator-sysmonitor >/dev/null 2>&1; then
    info "indicator-sysmonitor already running."
    return 0
  fi

  info "Launching indicator-sysmonitor…"
  nohup indicator-sysmonitor >/dev/null 2>&1 &
}

# ---- Main ----
main() {
  info "Starting install…"
  install_indicator_sysmonitor
  maybe_install_nettools
  write_ip_script
  configure_indicator_sysmonitor
  launch_indicator

  info "Done."
  info "Test script output with: $SCRIPT_PATH"
  info "If you don't see the icon on GNOME, you may need AppIndicator support enabled."
}

main "$@"
