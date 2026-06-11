# Info in Top Bar (Indicator-SysMonitor Installer)

This project installs and configures **Indicator-SysMonitor** to display
your **local LAN IPv4 address** directly in your Linux top bar / taskbar,
with optional CPU, memory and GPU indicators.

It automates everything:

-   Installs `indicator-sysmonitor`
-   Creates a LAN IP detection script
-   Writes/merges Indicator-SysMonitor configuration
-   Optionally launches it immediately

No manual GUI configuration required.

------------------------------------------------------------------------

# What Gets Installed

The installer uses `sudo` for apt operations and installs/configures:

-   PPA: `ppa:fossfreedom/indicator-sysmonitor`
-   Required apt packages: `ca-certificates`, `curl`, `iproute2`,
    `python3`, `software-properties-common`,
    `gir1.2-ayatanaappindicator3-0.1`
-   App package: `indicator-sysmonitor`
-   Optional apt package: `net-tools` when `INSTALL_NETTOOLS=true`
-   Optional apt source repair file:
    `/etc/apt/sources.list.d/lanip-installer-ubuntu.sources`
-   User script: `~/.local/bin/ip-display`
-   User config: `~/.indicator-sysmonitor.json`

By default, the installer shows an apt setup plan and asks whether to
install packages, print manual commands, or skip apt setup. If a required
package has no candidate, it tries enabling the Ubuntu `main` and
`universe` components first. If candidates are still missing, it can write
a dedicated Ubuntu archive source file, refresh apt, and check again before
installing.

------------------------------------------------------------------------

# What This Does

After running:

``` bash
chmod +x install.sh
./install.sh
```

You will see your LAN IP in the top panel, for example:

    192.168.1.42

------------------------------------------------------------------------

# How It Works

## 1️Installs Indicator-SysMonitor

Uses apt with this PPA:

    ppa:fossfreedom/indicator-sysmonitor

Before installing, the script updates apt package lists and verifies that
required packages have install candidates. If a required package is
missing on an Ubuntu-family system, it tries enabling `main` and
`universe`, then can write a dedicated Ubuntu archive `.sources` file and
check again.

Provides a lightweight panel indicator capable of running custom
commands and displaying their output.

------------------------------------------------------------------------

## 2️Creates a LAN IP Script

The installer writes:

    ~/.local/bin/ip-display

This script:

-   Detects the default network interface
-   Extracts its IPv4 address
-   Prints it as a single line

Test it manually:

``` bash
~/.local/bin/ip-display
```

------------------------------------------------------------------------

## 3️Configures Indicator-SysMonitor

The installer writes/updates:

    ~/.indicator-sysmonitor.json

It:

-   Adds a custom sensor named `lanip`
-   Points it to your `ip-display` script
-   Sets refresh interval
-   Configures panel output format
-   Enables start-on-login

------------------------------------------------------------------------

# Quick Install

``` bash
chmod +x install.sh
./install.sh
```

The default install mode is interactive. The script prints the apt changes
it plans to make and lets you choose whether to install with apt, print
manual commands and exit, or skip apt setup if you already installed the
system packages.

------------------------------------------------------------------------

# APT Setup Modes

Interactive default:

``` bash
./install.sh
```

Unattended apt install:

``` bash
APT_SETUP_MODE=auto ./install.sh
```

Manual package setup example for Ubuntu 24.04 Noble. The installer
detects the codename automatically; adjust `noble` if running these
commands by hand on another Ubuntu release.

``` bash
sudo install -d -m 0755 /etc/apt/sources.list.d
sudo tee /etc/apt/sources.list.d/lanip-installer-ubuntu.sources >/dev/null <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: noble-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
sudo apt-get update
sudo apt-get install -y --no-install-recommends ca-certificates curl iproute2 python3 software-properties-common gir1.2-ayatanaappindicator3-0.1
sudo add-apt-repository -y ppa:fossfreedom/indicator-sysmonitor
sudo apt-get update
sudo apt-get install -y indicator-sysmonitor
APT_SETUP_MODE=skip ./install.sh
```

Use `APT_SETUP_MODE=skip` only after the required packages and
`indicator-sysmonitor` are already installed. In skip mode, the script only
writes the user-level LAN IP script and Indicator-SysMonitor config.

------------------------------------------------------------------------

# Configuration Options

Example:

``` bash
SENSOR_NAME=lanip INTERVAL=1 CUSTOM_TEXT="{lanip}" ./install.sh
```

  Variable           Default                         Description
  ------------------ ------------------------------- ------------------------------------
  SENSOR_NAME        lanip                           Internal name of the custom sensor
  SENSOR_DESC        LAN IP                          Display name in config
  INTERVAL           2                               Refresh interval in seconds
  CUSTOM_TEXT        {lanip}                         What appears in the panel
  AUTO_START         true                            Start indicator on login
  RUN_NOW            true                            Launch immediately after install
  INSTALL_NETTOOLS   false                           Installs ifconfig/route fallback
  APT_SETUP_MODE     prompt                          prompt, auto, or skip apt setup
  APT_REPAIR_SOURCES true                            Write Ubuntu source repair file if needed
  APT_REPAIR_SOURCES_PATH /etc/apt/sources.list.d/lanip-installer-ubuntu.sources  Repair source file path
  UBUNTU_ARCHIVE_URI empty                           Override Ubuntu archive URI
  UBUNTU_SECURITY_URI empty                          Override Ubuntu security URI
  SCRIPT_PATH        \~/.local/bin/ip-display        LAN IP script location
  CONFIG_PATH        \~/.indicator-sysmonitor.json   Config file location

Boolean configuration values are case-insensitive:

    true / false
    yes / no
    1 / 0

`APT_SETUP_MODE` is also case-insensitive and accepts `prompt`, `auto` or
`skip`. `APT_REPAIR_SOURCES` uses the same boolean values.

------------------------------------------------------------------------

# Extended Panel Mode (LAN + CPU + Memory + GPU)

You can enable a more detailed system panel display:

    lan: {lanip} | cpu: {cpu} | mem: {mem} | gpu: {nvgpu}

Enable it with:

``` bash
CUSTOM_TEXT="lan: {lanip} | cpu: {cpu} | mem: {mem} | gpu: {nvgpu}" ./install.sh
```

Uses built-in sensors:

-   `{cpu}` -- CPU usage
-   `{mem}` -- Memory usage
-   `{nvgpu}` -- NVIDIA GPU usage (requires NVIDIA drivers)

------------------------------------------------------------------------

## Panel Space Warning

On smaller screens, extended panel output can quickly consume available
taskbar space.

Possible issues:

-   Truncated display
-   Overlapping indicators
-   Hidden system tray icons

If needed, revert to minimal mode:

``` bash
CUSTOM_TEXT="{lanip}" ./install.sh
```

Or shorten it:

``` bash
CUSTOM_TEXT="{lanip} | {cpu}" ./install.sh
```

------------------------------------------------------------------------

# GNOME Users

If the indicator does not appear, enable AppIndicator support in GNOME
Shell and log out/in.

------------------------------------------------------------------------

# Troubleshooting Missing Packages

If the installer reports `No install candidate found`, it stops before
installing Indicator-SysMonitor and prints OS, architecture, apt policy
information and manual setup commands for the missing package.

On Ubuntu 24.04, `curl` should have an apt candidate. If it does not, the
base Ubuntu archive sources are disabled, stale or broken. The installer
tries enabling `main` and `universe`; if that is not enough and
`APT_REPAIR_SOURCES=true`, it writes a dedicated recovery source file at
`/etc/apt/sources.list.d/lanip-installer-ubuntu.sources`.

Common causes are disabled or stale apt repositories, broken apt sources,
an unsupported Ubuntu derivative, or an architecture mismatch.

------------------------------------------------------------------------

# Testing

Test LAN IP script:

``` bash
~/.local/bin/ip-display
```

Validate installer syntax:

``` bash
bash -n install.sh
```

------------------------------------------------------------------------

# Uninstall

``` bash
sudo apt-get remove -y indicator-sysmonitor
rm -f ~/.indicator-sysmonitor.json
rm -f ~/.local/bin/ip-display
```

------------------------------------------------------------------------

# License

Free to use and modify.
