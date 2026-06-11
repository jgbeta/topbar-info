#!/usr/bin/env bash
# LAN IP top-bar installer for Indicator-SysMonitor
# - Installs indicator-sysmonitor on Ubuntu-family systems only when missing
# - Validates apt package candidates before installing missing dependencies
# - Detects an existing indicator-sysmonitor program/package and skips reinstalling it
# - Creates ~/.local/bin/ip-display (prints LAN IPv4)
# - Writes/merges ~/.indicator-sysmonitor.json custom sensor config
# - Optionally creates an XDG autostart .desktop entry for login startup
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

# AUTO_START accepts prompt/true/false:
#   prompt: ask interactively whether to add a login startup entry (default)
#   true:   add/update the login startup entry without asking
#   false:  do not add startup; remove this installer's startup entry if present
AUTO_START="${AUTO_START:-prompt}"
STARTUP_DEFAULT="${STARTUP_DEFAULT:-yes}"      # yes/no default when AUTO_START=prompt
RUN_NOW="${RUN_NOW:-true}"                     # true/false (string)
INSTALL_NETTOOLS="${INSTALL_NETTOOLS:-false}"  # true/false (string) legacy ifconfig/route
APT_SETUP_MODE="${APT_SETUP_MODE:-prompt}"     # prompt/auto/skip
APT_REPAIR_SOURCES="${APT_REPAIR_SOURCES:-true}"   # true/false; write Ubuntu archive sources if candidates are missing
APT_REPAIR_SOURCES_PATH="${APT_REPAIR_SOURCES_PATH:-/etc/apt/sources.list.d/lanip-installer-ubuntu.sources}"
UBUNTU_ARCHIVE_URI="${UBUNTU_ARCHIVE_URI:-}"       # optional override, e.g. http://mirror.example/ubuntu
UBUNTU_SECURITY_URI="${UBUNTU_SECURITY_URI:-}"     # optional override

XDG_CONFIG_HOME_EFFECTIVE="${XDG_CONFIG_HOME:-$HOME/.config}"
AUTOSTART_DESKTOP_PATH="${AUTOSTART_DESKTOP_PATH:-$XDG_CONFIG_HOME_EFFECTIVE/autostart/indicator-sysmonitor.desktop}"

# ---- Apt/package defaults ----
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

INDICATOR_PPA="ppa:fossfreedom/indicator-sysmonitor"
INDICATOR_PACKAGE="indicator-sysmonitor"
NETTOOLS_PACKAGE="net-tools"

APT_COMPONENTS=(
  main
  universe
)

# Packages needed when this installer has to add the PPA and install the app.
APT_REQUIRED_PACKAGES=(
  ca-certificates
  curl
  iproute2
  python3
  software-properties-common
  gir1.2-ayatanaappindicator3-0.1
)

# Packages still needed for user-level configuration when the app is already present.
CONFIG_REQUIRED_PACKAGES=(
  iproute2
  python3
)

MISSING_CANDIDATES=()
MISSING_PACKAGES=()
START_ON_LOGIN="false"

# ---- Helpers ----
info() { printf "\033[1;34m[i]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[x]\033[0m %s\n" "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

lower_trim() {
  local v="${1:-}"
  printf "%s" "$v" | tr '[:upper:]' '[:lower:]' | xargs
}

bool_norm() {
  # Normalize string booleans to "true" or "false" (case-insensitive).
  local v
  v="$(lower_trim "${1:-}")"
  case "$v" in
    true|1|yes|y|on)  printf "true" ;;
    false|0|no|n|off) printf "false" ;;
    *) printf "false" ;;  # safe default
  esac
}

normalize_yes_no_default() {
  local v
  v="$(lower_trim "${1:-}")"
  case "$v" in
    true|1|yes|y|on)  printf "yes" ;;
    false|0|no|n|off) printf "no" ;;
    *) printf "yes" ;;
  esac
}

normalize_auto_start() {
  AUTO_START="$(lower_trim "$AUTO_START")"
  case "$AUTO_START" in
    ""|prompt|ask) AUTO_START="prompt" ;;
    true|1|yes|y|on) AUTO_START="true" ;;
    false|0|no|n|off) AUTO_START="false" ;;
    *) err "AUTO_START must be one of: prompt, true, false." ;;
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

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-no}"
  local choice suffix

  default="$(normalize_yes_no_default "$default")"
  if [[ "$default" == "yes" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  if [[ ! -t 0 ]]; then
    warn "Interactive prompt unavailable; defaulting to '$default' for: $prompt"
    [[ "$default" == "yes" ]]
    return
  fi

  while true; do
    if ! read -r -p "$prompt $suffix " choice; then
      return 1
    fi

    choice="$(lower_trim "$choice")"
    if [[ -z "$choice" ]]; then
      choice="$default"
    fi

    case "$choice" in
      y|yes|true|1|on) return 0 ;;
      n|no|false|0|off) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

path_exists_for_write() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]]
}

confirm_existing_path_write() {
  local path="$1"
  local purpose="$2"

  if ! path_exists_for_write "$path"; then
    return 0
  fi

  if [[ -d "$path" ]]; then
    err "Cannot write $purpose because the target path is an existing directory: $path"
  fi

  if [[ ! -f "$path" && ! -L "$path" ]]; then
    err "Cannot write $purpose because the target path already exists and is not a regular file or symlink: $path"
  fi

  if [[ ! -t 0 ]]; then
    err "Refusing to overwrite existing $purpose at $path without an interactive prompt. Remove it, choose a different path, or rerun interactively."
  fi

  if ! prompt_yes_no "Existing $purpose found at $path. Overwrite it?" "no"; then
    err "Refusing to overwrite existing $purpose: $path"
  fi
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

  if (($# > 0)) && need_cmd apt-cache; then
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

is_deb_package_installed() {
  local pkg="$1"
  local status=""

  need_cmd dpkg-query || return 1
  status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  [[ "$status" == "install ok installed" ]]
}

package_requirement_present() {
  # Prefer command/functionality detection where a package mainly provides a command.
  # Fall back to dpkg status for libraries/data packages that do not have a simple command.
  local pkg="$1"

  case "$pkg" in
    curl) need_cmd curl || is_deb_package_installed "$pkg" ;;
    iproute2) need_cmd ip || is_deb_package_installed "$pkg" ;;
    python3) need_cmd python3 || is_deb_package_installed "$pkg" ;;
    software-properties-common) need_cmd add-apt-repository || is_deb_package_installed "$pkg" ;;
    net-tools) nettools_present ;;
    *) is_deb_package_installed "$pkg" ;;
  esac
}

collect_missing_installed_packages() {
  MISSING_PACKAGES=()

  local pkg
  for pkg in "$@"; do
    if ! package_requirement_present "$pkg"; then
      MISSING_PACKAGES+=("$pkg")
    fi
  done
}

indicator_program_exists() {
  need_cmd indicator-sysmonitor || is_deb_package_installed "$INDICATOR_PACKAGE"
}

nettools_present() {
  is_deb_package_installed "$NETTOOLS_PACKAGE" || { need_cmd ifconfig && need_cmd route; }
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
  printf "  APT_SETUP_MODE=skip ./%s\n" "$(basename "$0")"
}

print_apt_setup_plan() {
  info "APT setup plan (only missing items will be installed):"

  if ((${#MISSING_PACKAGES[@]} > 0)); then
    printf "  - Install missing required packages: %s\n" "${MISSING_PACKAGES[*]}"
  else
    printf "  - Required support packages already detected\n"
  fi

  if indicator_program_exists; then
    printf "  - %s already detected; skip app package install/PPA\n" "$INDICATOR_PACKAGE"
  else
    printf "  - Add Indicator-SysMonitor PPA if the app package candidate is not already available: %s\n" "$INDICATOR_PPA"
    printf "  - Install app package: %s\n" "$INDICATOR_PACKAGE"
  fi

  if [[ "$INSTALL_NETTOOLS" == "true" ]] && ! nettools_present; then
    printf "  - Install optional missing package: %s\n" "$NETTOOLS_PACKAGE"
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
    printf "\nMissing system packages or app install work were detected.\n"
    printf "Choose how to handle system packages:\n"
    printf "  [i] Install only the missing items using apt now\n"
    printf "  [m] Print manual commands and exit\n"
    printf "  [s] Skip apt setup and continue (only if already installed another way)\n"

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

  sudo install -d -m 0755 "$sources_dir"

  if sudo test -e "$sources_path" || sudo test -L "$sources_path"; then
    local backup
    confirm_existing_path_write "$sources_path" "Ubuntu archive source repair file"
    backup="${sources_path}.bak.$(date +%Y%m%d%H%M%S)"
    warn "Backing up existing recovery source file to: $backup"
    sudo cp -a "$sources_path" "$backup"
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

  if (($# == 0)); then
    return 0
  fi

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

AUTO_START="$(lower_trim "$AUTO_START")"
STARTUP_DEFAULT="$(normalize_yes_no_default "$STARTUP_DEFAULT")"
RUN_NOW="$(bool_norm "$RUN_NOW")"
INSTALL_NETTOOLS="$(bool_norm "$INSTALL_NETTOOLS")"
APT_REPAIR_SOURCES="$(bool_norm "$APT_REPAIR_SOURCES")"
normalize_auto_start
normalize_apt_setup_mode

# ---- Install indicator-sysmonitor (apt + PPA) ----
install_indicator_sysmonitor() {
  local indicator_present="false"
  local packages_to_check=()

  if indicator_program_exists; then
    indicator_present="true"
    info "$INDICATOR_PACKAGE already detected; skipping app package install and PPA setup."
    packages_to_check=("${CONFIG_REQUIRED_PACKAGES[@]}")
  else
    packages_to_check=("${APT_REQUIRED_PACKAGES[@]}")
  fi

  collect_missing_installed_packages "${packages_to_check[@]}"

  if [[ "$indicator_present" == "true" && ${#MISSING_PACKAGES[@]} -eq 0 ]]; then
    info "All required packages are already detected; no apt setup needed."
    return 0
  fi

  if ! should_run_apt_setup; then
    return 0
  fi

  require_ubuntu_family
  require_apt_commands
  apt_update_or_warn

  if ((${#MISSING_PACKAGES[@]} > 0)); then
    ensure_apt_candidates true "${MISSING_PACKAGES[@]}"
    info "Installing missing required apt packages: ${MISSING_PACKAGES[*]}"
    sudo apt-get install -y --no-install-recommends "${MISSING_PACKAGES[@]}"
  else
    info "Required support packages already installed."
  fi

  if [[ "$indicator_present" == "true" ]]; then
    return 0
  fi

  if apt_candidate_available "$INDICATOR_PACKAGE"; then
    info "$INDICATOR_PACKAGE package candidate already available; not adding PPA again."
  else
    ensure_add_apt_repository || err "add-apt-repository is unavailable after installing software-properties-common."

    info "Adding Indicator-SysMonitor PPA: $INDICATOR_PPA"
    if ! sudo add-apt-repository -y "$INDICATOR_PPA"; then
      err "Failed to add $INDICATOR_PPA."
    fi

    apt_update
  fi

  ensure_apt_candidates false "$INDICATOR_PACKAGE"

  info "Installing $INDICATOR_PACKAGE..."
  sudo apt-get install -y "$INDICATOR_PACKAGE"

  if indicator_program_exists; then
    info "$INDICATOR_PACKAGE installed/detected successfully."
  else
    warn "$INDICATOR_PACKAGE install completed, but the program was not detected in PATH yet. Try logging out/in if launch fails."
  fi
}

maybe_install_nettools() {
  if [[ "$INSTALL_NETTOOLS" != "true" ]]; then
    return 0
  fi

  if nettools_present; then
    info "$NETTOOLS_PACKAGE already detected; skipping optional net-tools install."
    return 0
  fi

  if [[ "$APT_SETUP_MODE" == "skip" ]]; then
    warn "INSTALL_NETTOOLS=true ignored because APT_SETUP_MODE=skip and $NETTOOLS_PACKAGE is not detected."
    return 0
  fi

  if [[ "$APT_SETUP_MODE" == "prompt" ]]; then
    if ! prompt_yes_no "Install optional package '$NETTOOLS_PACKAGE' for legacy ifconfig/route fallback?" "no"; then
      info "Skipping optional package: $NETTOOLS_PACKAGE"
      return 0
    fi
  fi

  require_ubuntu_family
  require_apt_commands
  apt_update_or_warn
  ensure_apt_candidates true "$NETTOOLS_PACKAGE"
  info "Installing $NETTOOLS_PACKAGE (provides ifconfig/route for legacy fallback)..."
  sudo apt-get install -y --no-install-recommends "$NETTOOLS_PACKAGE"
}

# ---- Write the LAN IP script ----
write_ip_script() {
  confirm_existing_path_write "$SCRIPT_PATH" "LAN IP script"
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

# ---- Startup/autostart configuration ----
indicator_command_for_desktop() {
  if need_cmd indicator-sysmonitor; then
    command -v indicator-sysmonitor
  elif [[ -x /usr/bin/indicator-sysmonitor ]]; then
    printf "%s" "/usr/bin/indicator-sysmonitor"
  else
    printf "%s" "indicator-sysmonitor"
  fi
}

autostart_entry_exists() {
  [[ -f "$AUTOSTART_DESKTOP_PATH" ]]
}

autostart_entry_enabled() {
  autostart_entry_exists || return 1
  if grep -Eiq '^[[:space:]]*Hidden[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$AUTOSTART_DESKTOP_PATH"; then
    return 1
  fi
  if grep -Eiq '^[[:space:]]*X-GNOME-Autostart-enabled[[:space:]]*=[[:space:]]*false[[:space:]]*$' "$AUTOSTART_DESKTOP_PATH"; then
    return 1
  fi
  return 0
}

choose_startup_preference() {
  if ! indicator_program_exists; then
    START_ON_LOGIN="false"
    warn "Cannot configure startup because $INDICATOR_PACKAGE is not detected."
    return 0
  fi

  case "$AUTO_START" in
    true)
      START_ON_LOGIN="true"
      ;;
    false)
      START_ON_LOGIN="false"
      ;;
    prompt)
      if autostart_entry_enabled; then
        START_ON_LOGIN="true"
        info "Startup entry already exists and is enabled: $AUTOSTART_DESKTOP_PATH"
      elif [[ ! -t 0 ]]; then
        START_ON_LOGIN="false"
        warn "AUTO_START=prompt but no interactive terminal is available; not adding a startup entry. Set AUTO_START=true to force it."
      elif prompt_yes_no "Add Indicator-SysMonitor to startup when you log in?" "$STARTUP_DEFAULT"; then
        START_ON_LOGIN="true"
      else
        START_ON_LOGIN="false"
      fi
      ;;
  esac
}

write_autostart_entry() {
  local desktop_dir command_path

  if ! indicator_program_exists; then
    warn "Not writing startup entry because $INDICATOR_PACKAGE is not detected."
    return 1
  fi

  desktop_dir="$(dirname "$AUTOSTART_DESKTOP_PATH")"
  command_path="$(indicator_command_for_desktop)"

  confirm_existing_path_write "$AUTOSTART_DESKTOP_PATH" "startup entry"
  info "Writing startup entry: $AUTOSTART_DESKTOP_PATH"
  mkdir -p "$desktop_dir"

  cat > "$AUTOSTART_DESKTOP_PATH" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Indicator SysMonitor
Comment=Show LAN IP in the top bar with Indicator-SysMonitor
Exec=$command_path
TryExec=$command_path
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
X-LANIP-Installer=true
EOF

  chmod 0644 "$AUTOSTART_DESKTOP_PATH"
}

remove_autostart_entry() {
  if ! autostart_entry_exists; then
    info "No startup entry to remove at: $AUTOSTART_DESKTOP_PATH"
    return 0
  fi

  if grep -Eiq '^[[:space:]]*X-LANIP-Installer[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$AUTOSTART_DESKTOP_PATH" \
    || grep -Eiq '^[[:space:]]*Exec[[:space:]]*=.*indicator-sysmonitor' "$AUTOSTART_DESKTOP_PATH"; then
    info "Removing startup entry: $AUTOSTART_DESKTOP_PATH"
    rm -f "$AUTOSTART_DESKTOP_PATH"
  else
    warn "Startup file exists but does not look like this installer's entry; leaving it unchanged: $AUTOSTART_DESKTOP_PATH"
  fi
}

apply_startup_configuration() {
  if [[ "$START_ON_LOGIN" == "true" ]]; then
    if ! write_autostart_entry; then
      START_ON_LOGIN="false"
    fi
    return 0
  fi

  if [[ "$AUTO_START" == "false" ]]; then
    remove_autostart_entry
  else
    info "Start on login not enabled."
  fi
}

# ---- Merge/update ~/.indicator-sysmonitor.json ----
configure_indicator_sysmonitor() {
  need_cmd python3 || err "python3 is required. Re-run with APT_SETUP_MODE=auto, or install python3 manually."

  confirm_existing_path_write "$CONFIG_PATH" "Indicator-SysMonitor config"
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
start_on_login = "${START_ON_LOGIN}".strip().lower() == "true"

cfg = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f) or {}
    except Exception as exc:
        print("[x] Refusing to overwrite invalid JSON config: %s" % cfg_path, file=sys.stderr)
        print("[x] JSON error: %s" % exc, file=sys.stderr)
        sys.exit(1)

if not isinstance(cfg, dict):
    print("[x] Refusing to overwrite config because JSON root is not an object: %s" % cfg_path, file=sys.stderr)
    sys.exit(1)

cfg.setdefault("sensors", {})
if not isinstance(cfg["sensors"], dict):
    print("[x] Refusing to overwrite config because sensors is not an object: %s" % cfg_path, file=sys.stderr)
    sys.exit(1)

# Sensor format: name -> [description, command]
cfg["sensors"][sensor_name] = [sensor_desc, script_path]

# If user kept default token {lanip}, map it to {<sensor_name>}
cfg["custom_text"] = custom_text.replace("{lanip}", "{%s}" % sensor_name)

cfg["interval"] = interval
cfg["on_startup"] = start_on_login

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

  info "Launching indicator-sysmonitor..."
  nohup indicator-sysmonitor >/dev/null 2>&1 &
}

# ---- Main ----
main() {
  info "Starting install..."
  install_indicator_sysmonitor
  maybe_install_nettools
  write_ip_script
  choose_startup_preference
  apply_startup_configuration
  configure_indicator_sysmonitor
  launch_indicator

  info "Done."
  info "Test script output with: $SCRIPT_PATH"
  if [[ "$START_ON_LOGIN" == "true" ]]; then
    info "Startup entry enabled at: $AUTOSTART_DESKTOP_PATH"
  fi
  info "If you don't see the icon on GNOME, you may need AppIndicator support enabled."
}

main "$@"
