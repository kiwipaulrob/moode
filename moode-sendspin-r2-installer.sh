# SendSpin Release 2: Advanced Features Installer
# 
# This script installs the Release 2 advanced features on top of
# an existing Release 1 SendSpin installation.
#
# Prerequisites:
#   - Release 1 (sendspin-integration) must be installed
#   - SendSpin CLI 7.5.0+ must be installed
#   - moOde 9.4.2+
#
# Usage:
#   sudo bash moode-sendspin-r2-installer.sh           # Full install
#   sudo bash moode-sendspin-r2-installer.sh --check    # Check status
#   sudo bash moode-sendspin-r2-installer.sh --uninstall # Remove R2 features
#
# Features installed:
#   1. Now playing metadata display (hooks + PHP + JS)
#   2. Volume synchronisation hooks
#   3. CamillaDSP loopback detection hooks
#   4. Buffer tuning for sync precision
#   5. Version check and update button
# =============================================================================

set -euo pipefail

# --- Configuration ---
HOOKS_DIR="/var/local/www/commandw"
ALSA_CONF_DIR="/etc/alsa/conf.d"
WEB_DIR="/var/www"
DB_FILE="/var/local/www/db/moode-sqlite3.db"
BACKUP_DIR="/var/backups/moode-sendspin-r2-$(date +%Y%m%d-%H%M%S)"

# --- Helper functions ---
log() { echo "[$(date +%H:%M:%S)] $1"; }
err() { echo "ERROR: $1" >&2; exit 1; }

check_r1_installed() {
    if ! grep -q "FEAT_SENDSPIN" "$WEB_DIR/inc/constants.php" 2>/dev/null; then
        err "Release 1 not found. Install sendspin-integration first."
    fi
    log "Release 1 detected: OK"
}

backup_file() {
    local f="$1"
    if [ -f "$f" ]; then
        mkdir -p "$BACKUP_DIR"
        cp "$f" "$BACKUP_DIR/$(basename "$f").r2bak"
        log "Backed up: $f"
    fi
}

# --- Install functions ---

install_hooks() {
    log "Installing hook scripts..."
    mkdir -p "$HOOKS_DIR"

    # Copy hook scripts
    cp hooks/sendspin-metadata.sh "$HOOKS_DIR/"
    cp hooks/sendspin-volume-sync.sh "$HOOKS_DIR/"
    cp hooks/spspre.sh "$HOOKS_DIR/"
    cp hooks/spspost.sh "$HOOKS_DIR/"
    cp hooks/sendspin-version-check.sh "$HOOKS_DIR/"

    # Make executable
    chmod +x "$HOOKS_DIR"/sendspin-*.sh "$HOOKS_DIR"/spspre.sh "$HOOKS_DIR"/spspost.sh
    chown www-data:www-data "$HOOKS_DIR"/sendspin-*.sh "$HOOKS_DIR"/spspre.sh "$HOOKS_DIR"/spspost.sh

    # Create cover art directory
    mkdir -p /var/local/www/imagesw/sendspin-covers
    chown www-data:www-data /var/local/www/imagesw/sendspin-covers

    log "Hook scripts installed: OK"
}

install_alsa_config() {
    log "Installing ALSA config with buffer tuning..."
    backup_file "$ALSA_CONF_DIR/sendspin.conf"
    cp etc/alsa/conf.d/sendspin.conf "$ALSA_CONF_DIR/"
    chmod 644 "$ALSA_CONF_DIR/sendspin.conf"
    log "ALSA config updated with buffer tuning: OK"
}

install_constants() {
    log "Adding Release 2 constants..."
    if ! grep -q "SENDSPINMETA_FILE" "$WEB_DIR/inc/constants.php" 2>/dev/null; then
        # Insert after FEAT_SENDSPIN line
        sed -i '/FEAT_SENDSPIN/a const SENDSPINMETA_FILE = "\/var\/local\/www\/sendspinmeta.txt";' \
            "$WEB_DIR/inc/constants.php"
        log "Constants added: OK"
    else
        log "Constants already present: SKIP"
    fi
}

install_renderer_functions() {
    log "Adding Release 2 renderer functions..."

    # Check if R2 functions already present
    if grep -q "getSendspinVersion" "$WEB_DIR/inc/renderer.php" 2>/dev/null; then
        log "R2 renderer functions already present: SKIP"
        return
    fi

    # Append R2 functions to renderer.php
    cat >> "$WEB_DIR/inc/renderer.php" << 'R2_PHP'

// === Release 2: Advanced Functions ===

function getSendspinVersion() {
    $result = sysCmd('sendspin --version 2>/dev/null');
    $version = (!empty($result) && isset($result[0])) ? trim($result[0]) : 'unknown';
    return $version;
}

function getSendspinMetadata() {
    if (file_exists(SENDSPINMETA_FILE)) {
        $meta = file_get_contents(SENDSPINMETA_FILE);
        return $meta;
    }
    return '';
}

function checkSendspinUpdate() {
    $result = sysCmd('sendspin-version-check.sh 2>/dev/null');
    $json = (!empty($result) && isset($result[0])) ? $result[0] : '{}';
    return $json;
}

function updateSendspin() {
    sysCmd('uv tool upgrade sendspin 2>&1');
    sleep(2);
    sysCmd('systemctl restart sendspin 2>/dev/null');
    workerLog('updateSendspin(): SendSpin updated and restarted');
    return true;
}
R2_PHP

    log "R2 renderer functions added: OK"
}

install_systemd_service() {
    log "Updating systemd service with hooks..."

    SVC_FILE="/etc/systemd/system/sendspin.service"
    backup_file "$SVC_FILE"

    # Get current ExecStart to preserve audio device config
    CURRENT_EXEC=$(grep "^ExecStart" "$SVC_FILE" | head -1)

    # Write updated service file with hooks and hardening
    cat > "$SVC_FILE" << SVC_EOF
[Unit]
Description=SendSpin Audio Receiver
After=network-online.target sound.target avahi-daemon.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/var/local/www/commandw/spspre.sh
ExecStart=${CURRENT_EXEC#ExecStart=} \\
    --hook-start /var/local/www/commandw/sendspin-metadata.sh \\
    --hook-stop /var/local/www/commandw/sendspin-metadata.sh \\
    --hook-set-volume /var/local/www/commandw/sendspin-volume-sync.sh
ExecStopPost=/var/local/www/commandw/spspost.sh
Restart=on-failure
RestartSec=5
TimeoutStartSec=30
Environment="HOME=/root"

# Real-time priority for sub-ms sync
LimitRTPRIO=99
LimitMEMLOCK=8388608

[Install]
WantedBy=multi-user.target
SVC_EOF

    systemctl daemon-reload
    log "Systemd service updated with hooks: OK"
}

install_php_handlers() {
    log "Adding PHP command handlers..."

    # Add get_sendspinmeta case to command/renderer.php if it exists
    RENDERER_CMD="$WEB_DIR/command/renderer.php"
    if [ -f "$RENDERER_CMD" ] && ! grep -q "get_sendspinmeta" "$RENDERER_CMD"; then
        backup_file "$RENDERER_CMD"
        # Insert before the closing default case
        sed -i '/default:/i \
    case "get_sendspinmeta":\
        echo json_encode(getSendspinMetadata());\
        break;\
    case "get_sendspin_version":\
        echo json_encode(getSendspinVersion());\
        break;\
    case "check_sendspin_update":\
        echo checkSendspinUpdate();\
        break;' "$RENDERER_CMD"
        log "PHP handlers added: OK"
    else
        log "PHP handlers already present or file not found: SKIP"
    fi
}

verify_syntax() {
    log "Verifying PHP syntax..."
    local errors=0
    for f in "$WEB_DIR/inc/constants.php" "$WEB_DIR/inc/renderer.php"; do
        if ! php -l "$f" 2>&1 | grep -q "No syntax errors"; then
            echo "  SYNTAX ERROR in $f"
            php -l "$f"
            errors=$((errors + 1))
        fi
    done
    if [ $errors -gt 0 ]; then
        err "PHP syntax errors found. Check backups in $BACKUP_DIR"
    fi
    log "PHP syntax: OK"
}

# --- Check mode ---
do_check() {
    log "=== SendSpin Release 2 Status Check ==="
    echo ""

    echo "Hook scripts:"
    for f in sendspin-metadata.sh sendspin-volume-sync.sh spspre.sh spspost.sh sendspin-version-check.sh; do
        if [ -x "$HOOKS_DIR/$f" ]; then
            echo "  [x] $f"
        else
            echo "  [ ] $f (not installed)"
        fi
    done

    echo ""
    echo "Constants:"
    grep -q "SENDSPINMETA_FILE" "$WEB_DIR/inc/constants.php" 2>/dev/null && \
        echo "  [x] SENDSPINMETA_FILE" || echo "  [ ] SENDSPINMETA_FILE"

    echo ""
    echo "Renderer functions:"
    grep -q "getSendspinVersion" "$WEB_DIR/inc/renderer.php" 2>/dev/null && \
        echo "  [x] getSendspinVersion()" || echo "  [ ] getSendspinVersion()"
    grep -q "getSendspinMetadata" "$WEB_DIR/inc/renderer.php" 2>/dev/null && \
        echo "  [x] getSendspinMetadata()" || echo "  [ ] getSendspinMetadata()"

    echo ""
    echo "Systemd hooks:"
    grep -q "hook-start" /etc/systemd/system/sendspin.service 2>/dev/null && \
        echo "  [x] --hook-start" || echo "  [ ] --hook-start"
    grep -q "hook-stop" /etc/systemd/system/sendspin.service 2>/dev/null && \
        echo "  [x] --hook-stop" || echo "  [ ] --hook-stop"
    grep -q "hook-set-volume" /etc/systemd/system/sendspin.service 2>/dev/null && \
        echo "  [x] --hook-set-volume" || echo "  [ ] --hook-set-volume"
    grep -q "spspre.sh" /etc/systemd/system/sendspin.service 2>/dev/null && \
        echo "  [x] ExecStartPre (DSP detection)" || echo "  [ ] ExecStartPre"
    grep -q "spspost.sh" /etc/systemd/system/sendspin.service 2>/dev/null && \
        echo "  [x] ExecStopPost (cleanup)" || echo "  [ ] ExecStopPost"

    echo ""
    echo "ALSA buffer tuning:"
    grep -q "period_time" /etc/alsa/conf.d/sendspin.conf 2>/dev/null && \
        echo "  [x] Buffer tuning active" || echo "  [ ] Buffer tuning not configured"

    echo ""
    echo "Service hardening:"
    grep -q "LimitRTPRIO" /etc/systemd/system/sendspin.service 2>/dev/null && \
        echo "  [x] LimitRTPRIO" || echo "  [ ] LimitRTPRIO"
    grep -q "LimitMEMLOCK" /etc/systemd/system/sendspin.service 2>/dev/null && \
        echo "  [x] LimitMEMLOCK" || echo "  [ ] LimitMEMLOCK"
}

# --- Uninstall mode ---
do_uninstall() {
    log "Uninstalling Release 2 features..."

    # Remove hook scripts
    for f in sendspin-metadata.sh sendspin-volume-sync.sh spspre.sh spspost.sh sendspin-version-check.sh; do
        rm -f "$HOOKS_DIR/$f"
    done

    # Restore backups if available
    for bak in /var/backups/moode-sendspin-r2-*/; do
        if [ -d "$bak" ]; then
            for f in "$bak"/*.r2bak; do
                [ -f "$f" ] && cp "$f" "${f%.r2bak}" 2>/dev/null
            done
        fi
    done

    # Remove R2 constants
    sed -i '/SENDSPINMETA_FILE/d' "$WEB_DIR/inc/constants.php" 2>/dev/null

    # Restore original service file (remove hooks)
    if [ -f /etc/systemd/system/sendspin.service ]; then
        sed -i '/--hook-start/d; /--hook-stop/d; /--hook-set-volume/d; /spspre/d; /spspost/d; /LimitRTPRIO/d; /LimitMEMLOCK/d; /ExecStartPre/d; /ExecStopPost/d' \
            /etc/systemd/system/sendspin.service
        systemctl daemon-reload
    fi

    log "Release 2 features removed. Release 1 core remains intact."
}

# --- Main ---
case "${1:-}" in
    --check)
        do_check
        ;;
    --uninstall)
        do_uninstall
        ;;
    *)
        log "=== SendSpin Release 2 Installer ==="
        check_r1_installed
        install_hooks
        install_alsa_config
        install_constants
        install_renderer_functions
        install_systemd_service
        install_php_handlers
        verify_syntax
        log ""
        log "=== Installation Complete ==="
        log "Restart SendSpin service to activate:"
        log "  sudo systemctl restart sendspin"
        log ""
        log "Verify with: sudo bash $0 --check"
        ;;
esac
