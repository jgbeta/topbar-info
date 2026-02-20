#!/usr/bin/env bash
# LAN IP top-bar installer for Indicator-SysMonitor
# - Installs indicator-sysmonitor (Ubuntu/Debian via PPA)
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

# ---- Helpers ----
info() { printf "\033[1;34m[i]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[x]\033[0m %s\n" "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

bool_norm() {
  # normalize string booleans to "true" or "false" (case-insensitive)
  local v="${1:-}"
  v="$(printf "%s" "$v" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$v" in
    true|1|yes|y|on)  printf "true" ;;
    false|0|no|n|off) printf "false" ;;
    *) printf "false" ;;  # safe default
  esac
}

AUTO_START="$(bool_norm "$AUTO_START")"
RUN_NOW="$(bool_norm "$RUN_NOW")"
INSTALL_NETTOOLS="$(bool_norm "$INSTALL_NETTOOLS")"

# ---- Basic checks ----
need_cmd sudo || err "sudo is required."
need_cmd python3 || err "python3 is required."

# ---- Install indicator-sysmonitor (apt + PPA) ----
install_indicator_sysmonitor() {
  need_cmd apt-get || err "This installer currently supports apt-based distros (Ubuntu/Debian)."

  info "Installing indicator-sysmonitor via PPA (fossfreedom/indicator-sysmonitor)…"
  sudo apt-get update -y
  sudo apt-get install -y software-properties-common

  # Add PPA (idempotent-ish: add-apt-repository may re-add, that's fine)
  sudo add-apt-repository -y ppa:fossfreedom/indicator-sysmonitor
  sudo apt-get update -y
  sudo apt-get install -y indicator-sysmonitor
}

maybe_install_nettools() {
  if [[ "$INSTALL_NETTOOLS" == "true" ]]; then
    info "Installing net-tools (provides ifconfig/route for legacy fallback)…"
    sudo apt-get update -y
    sudo apt-get install -y net-tools
  fi
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
