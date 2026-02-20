# Info in Top Bar (Indicator-SysMonitor Installer)

This project installs and configures **Indicator-SysMonitor** to display
your **local LAN IPv4 address**, **CPU load**, **Memory load** and **GPU load** directly in your Linux top bar /
taskbar.

It automates everything:

-   Installs `indicator-sysmonitor`
-   Creates a LAN IP detection script
-   Writes/merges Indicator-SysMonitor configuration
-   Optionally launches it immediately

No manual GUI configuration required.

------------------------------------------------------------------------

# What This Does

After running:

``` bash
chmod +x install.sh
./install.sh
```

You will see your LAN IP in the top panel, for example:

    lan: 192.168.1.42 | cpu: 15% | mem: 23% | gpu 69%

------------------------------------------------------------------------

# How It Works

## 1️⃣ Installs Indicator-SysMonitor

Uses the official PPA:

    ppa:fossfreedom/indicator-sysmonitor

Provides a lightweight panel indicator capable of running custom
commands and displaying their output.

------------------------------------------------------------------------

## 2️⃣ Creates a LAN IP Script

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

## 3️⃣ Configures Indicator-SysMonitor

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
  SCRIPT_PATH        \~/.local/bin/ip-display        LAN IP script location
  CONFIG_PATH        \~/.indicator-sysmonitor.json   Config file location

Boolean values are case-insensitive:

    true / false
    yes / no
    1 / 0

------------------------------------------------------------------------

# 🔥 Extended Panel Mode (LAN + CPU + Memory + GPU)

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

## ⚠️ Panel Space Warning

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
