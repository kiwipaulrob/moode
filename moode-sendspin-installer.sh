#!/bin/bash
#
# moOde SendSpin Integration Installer v4.0.0
# Repository: https://github.com/kiwipaulrob/moode
# Branch: sendspin-integration
#
# Usage:
#   Full Install:   curl -fsSL ... | sudo bash
#   Minimal Install: curl -fsSL ... | sudo bash -s -- --minimal
#   Uninstall:      curl -fsSL ... | sudo bash -s -- --uninstall
#   Check Status:   curl -fsSL ... | sudo bash -s -- --check
#   No Backup:      curl -fsSL ... | sudo bash -s -- --no-backup
#
# This script integrates SendSpin Multi-Room Audio Client into moOde 9.4.2+

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_VERSION="4.0.0"
REPO_OWNER="kiwipaulrob"
REPO_NAME="moode"
BRANCH="sendspin-integration"
BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}"

# File locations on moOde
WWW_DIR="/var/www"
INC_DIR="${WWW_DIR}/inc"
SYSTEMD_DIR="/etc/systemd/system"
DB_PATH="/var/local/www/db/moode-sqlite3.db"
ALSA_CONF="/etc/alsa/conf.d/_audioout.conf"

# Feature bitmask for SendSpin
FEAT_SENDSPIN=262144

# Installation modes
INSTALL_MODE="full"  # "minimal" or "full"
SKIP_BACKUP=false

# Backup directory (set during runtime)
BACKUP_DIR=""

# Files modified by FULL installation
FULL_INSTALL_FILES=(
    "${INC_DIR}/constants.php"
    "${INC_DIR}/renderer.php"
    "${WWW_DIR}/js/lib.min.js"
    "${WWW_DIR}/ren-config.php"
    "${WWW_DIR}/templates/ren-config.html"
    "${WWW_DIR}/setup_3rdparty_sendspin.txt"
    "${WWW_DIR}/command/queue.php"
    "${WWW_DIR}/worker.php"
    "${SYSTEMD_DIR}/sendspin.service"
)

# Files for MINIMAL installation (endpoint only)
MINIMAL_INSTALL_FILES=(
    "${SYSTEMD_DIR}/sendspin.service"
)

# Files to backup for uninstall
BACKUP_FILES=(
    "constants.php"
    "renderer.php"
    "lib.min.js"
    "ren-config.php"
    "ren-config.html"
    "setup_3rdparty_sendspin.txt"
    "worker.php"
    "queue.php"
)

# Installation tracking
INSTALLED_COMPONENTS=()

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log_info() { echo -e "\e[36m[INFO]\e[0m $1"; }
log_success() { echo -e "\e[32m[OK]\e[0m $1"; }
log_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $1"; }
log_section() { echo -e "\e[35m\n=== $1 ===\e[0m"; }

# Check if running on actual moOde
is_moode() {
    if [[ -f "${WWW_DIR}/inc/constants.php" ]] && \
       [[ -f "${WWW_DIR}/ren-config.php" ]] && \
       command -v moodeutl &>/dev/null; then
        return 0
    fi
    return 1
}

# Check if moOde is production (minified JS)
is_production_moode() {
    if [[ -f "${WWW_DIR}/js/lib.min.js" ]]; then
        return 0
    fi
    return 1
}

# Check if PHP syntax is valid
verify_php_syntax() {
    local file="$1"
    if php -l "$file" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Download file from GitHub with retry
download_from_github() {
    local remote_path="$1"
    local local_path="$2"
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if curl -fsSL "${BASE_URL}/${remote_path}" -o "$local_path" 2>/dev/null; then
            return 0
        fi
        ((retry++))
        log_warn "Download failed, retrying... ($retry/$max_retries)"
        sleep 2
    done
    
    return 1
}

# Initialize backup directory
init_backup() {
    if [[ "$SKIP_BACKUP" == "true" ]]; then
        log_info "Backup skipped (--no-backup specified)"
        return 0
    fi
    
    BACKUP_DIR="/var/backups/moode-sendspin-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    log_info "Backup directory: ${BACKUP_DIR}"
}

# Backup a single file
backup_file() {
    local src="$1"
    local name="$2"
    
    if [[ "$SKIP_BACKUP" == "true" ]]; then
        return 0
    fi
    
    if [[ -f "$src" ]]; then
        cp "$src" "${BACKUP_DIR}/${name}"
        return 0
    fi
    return 1
}

# Record installed component for tracking
record_install() {
    local component="$1"
    INSTALLED_COMPONENTS+=("$component")
}

# ============================================================================
# DETECTION FUNCTIONS
# ============================================================================

detect_constants_php() {
    [[ -f "${INC_DIR}/constants.php" ]] && grep -q "FEAT_SENDSPIN" "${INC_DIR}/constants.php"
}

detect_renderer_php() {
    [[ -f "${INC_DIR}/renderer.php" ]] && grep -q "function.*Sendspin\|startSendspin\|stopSendspin" "${INC_DIR}/renderer.php"
}

detect_lib_min_js() {
    [[ -f "${WWW_DIR}/js/lib.min.js" ]] && grep -q "FEAT_SENDSPIN=262144" "${WWW_DIR}/js/lib.min.js"
}

detect_ren_config_php() {
    [[ -f "${WWW_DIR}/ren-config.php" ]] && grep -q "feat_sendspin\|FEAT_SENDSPIN" "${WWW_DIR}/ren-config.php"
}

detect_ren_config_html() {
    [[ -f "${WWW_DIR}/templates/ren-config.html" ]] && grep -qi "sendspin" "${WWW_DIR}/templates/ren-config.html"
}

detect_setup_txt() {
    [[ -f "${WWW_DIR}/setup_3rdparty_sendspin.txt" ]]
}

detect_systemd_service() {
    [[ -f "${SYSTEMD_DIR}/sendspin.service" ]]
}

detect_database_entries() {
    [[ -f "$DB_PATH" ]] && [[ $(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM cfg_system WHERE param LIKE 'sendspin%';" 2>/dev/null || echo "0") -gt 0 ]]
}

detect_feat_bitmask() {
    if [[ -f "$DB_PATH" ]]; then
        local bitmask
        bitmask=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_system WHERE param='feat_bitmask';" 2>/dev/null || echo "0")
        [[ $((bitmask & FEAT_SENDSPIN)) -ne 0 ]]
    else
        return 1
    fi
}

detect_worker_php() {
    [[ -f "${WWW_DIR}/worker.php" ]] && grep -q "sendspinsvc\|sendspinrestart\|startSendspin\|stopSendspin" "${WWW_DIR}/worker.php"
}

detect_queue_php() {
    [[ -f "${WWW_DIR}/command/queue.php" ]] && grep -q "sendspinsvc\|sendspinrestart" "${WWW_DIR}/command/queue.php"
}

detect_alsa_dmix() {
    [[ -f "$ALSA_CONF" ]] && grep -q "type dmix" "$ALSA_CONF"
}

# ============================================================================
# CHECK / STATUS FUNCTION
# ============================================================================

check_installation() {
    log_section "SendSpin Installation Status"
    
    local installed_count=0
    local total_checks=11
    
    check_component() {
        local name="$1"
        local check_fn="$2"
        if $check_fn; then
            echo "  [OK] $name"
            ((installed_count++))
            return 0
        else
            echo "  [  ] $name"
            return 1
        fi
    }
    
    check_component "constants.php - FEAT_SENDSPIN constant" detect_constants_php
    check_component "renderer.php - SendSpin control functions" detect_renderer_php
    check_component "lib.min.js - FEAT_SENDSPIN constant" detect_lib_min_js
    check_component "ren-config.php - Feature handling" detect_ren_config_php
    check_component "ren-config.html - UI section" detect_ren_config_html
    check_component "setup_3rdparty_sendspin.txt - Documentation" detect_setup_txt
    check_component "worker.php - Job handlers" detect_worker_php
    check_component "queue.php - Job queue" detect_queue_php
    check_component "sendspin.service - Systemd service" detect_systemd_service
    check_component "Database - Config entries" detect_database_entries
    check_component "feat_bitmask - Feature enabled" detect_feat_bitmask
    
    echo ""
    echo "Result: ${installed_count}/${total_checks} components installed"
    
    if [[ $installed_count -eq 0 ]]; then
        log_info "SendSpin is NOT installed."
        return 1
    elif [[ $installed_count -eq $total_checks ]]; then
        log_success "SendSpin is FULLY installed."
        return 0
    else
        log_warn "SendSpin is PARTIALLY installed (${installed_count}/${total_checks})."
        return 2
    fi
}

# ============================================================================
# PREREQUISITES (Python, uv, sendspin CLI)
# ============================================================================

install_prerequisites() {
    log_info "Checking and installing prerequisites..."
    
    # Check/install Python 3
    if ! command -v python3 &>/dev/null; then
        log_info "  Installing Python 3..."
        apt-get update -qq && apt-get install -y -qq python3 python3-pip
    fi
    
    # Check/install uv
    if ! command -v uv &>/dev/null; then
        log_info "  Installing uv (Python package manager)..."
        pip3 install uv --break-system-packages -q
    fi
    
    # Check/install sendspin CLI
    if ! command -v sendspin &>/dev/null; then
        log_info "  Installing sendspin CLI via uv..."
        uv tool install sendspin -q
        log_success "  sendspin CLI installed ($(sendspin --version 2>/dev/null || echo 'unknown'))"
    else
        log_info "  sendspin CLI already installed ($(sendspin --version 2>/dev/null || echo 'unknown'))"
    fi
    
    record_install "prerequisites"
    log_success "Prerequisites installed"
}

# ============================================================================
# ALSA CONFIG
# ============================================================================

install_alsa_config() {
    log_info "Installing ALSA volume attenuation config..."
    
    local alsa_conf="/etc/alsa/conf.d/sendspin.conf"
    
    cat > "$alsa_conf" << 'EOF'
# SendSpin audio output
# Uses plug plugin for format conversion, direct hardware access for stability
# The _audioout device has IPC key issues with dmix, so we use hw:0,0 directly

pcm.sendspin {
    type plug
    slave {
        pcm {
            type hw
            card 0
            device 0
        }
    }
}

# Alias for compatibility
pcm._sendspin {
    type copy
    slave.pcm "sendspin"
}
EOF
    
    record_install "alsa_config"
    log_success "ALSA configuration installed"
}

install_systemd_service() {
    log_info "Installing SendSpin systemd service..."
    
    local service_file="${SYSTEMD_DIR}/sendspin.service"
    
    # Backup existing service file
    if [[ -f "$service_file" ]]; then
        backup_file "$service_file" "sendspin.service"
    fi
    
    cat > "$service_file" << 'EOF'
[Unit]
Description=SendSpin Multi-Room Audio Client
After=network.target sound.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/root/.local/share/uv/tools/sendspin/bin/sendspin daemon --audio-device sendspin --audio-format flac:48000:16:2 --name moode-sendspin
Restart=on-failure
RestartSec=5
TimeoutStartSec=30
Environment="PATH=/root/.local/share/uv/tools/sendspin/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONUNBUFFERED=1"
Environment="HOME=/root"

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 644 "$service_file"
    systemctl daemon-reload
    record_install "systemd_service"
    log_success "Systemd service installed"
}

# ============================================================================
# MOODE WORKER SERVICE
# ============================================================================

install_moode_worker_service() {
    log_info "Installing moOde worker systemd service..."
    local service_file="${SYSTEMD_DIR}/moode-worker.service"
    
    # Backup existing service file
    if [[ -f "$service_file" ]]; then
        log_info "  Backing up existing moode-worker.service"
        backup_file "$service_file" "moode-worker.service"
    fi
    
    cat > "$service_file" << 'EOF'
[Unit]
Description=moOde Worker Daemon
After=network-online.target php8.2-fpm.service
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/worker.pid
ExecStartPre=/bin/rm -f /run/worker.pid
ExecStart=/usr/bin/php /var/www/daemon/worker.php
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 644 "$service_file"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable moode-worker.service 2>/dev/null || true
    record_install "moode_worker_service"
    log_success "moOde worker service installed and enabled"
}

install_database_entries_minimal() {
    log_info "Configuring database (minimal)..."
    
    if [[ ! -f "$DB_PATH" ]]; then
        log_error "Database not found at ${DB_PATH}"
        return 1
    fi
    
    # Backup database
    backup_file "$DB_PATH" "moode-sqlite3.db"
    
    # Add minimal database entries
    sqlite3 "$DB_PATH" << 'EOF'
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('sendspinsvc', '0');
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('sendspin_installed', 'yes');
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('sendspinname', 'moode-sendspin');
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('rsmafterss', 'No');
CREATE TABLE IF NOT EXISTS cfg_sendspin (id INTEGER PRIMARY KEY, param CHAR (32), value CHAR (128));
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_codec', 'flac');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_rate', '48000');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_depth', '16');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('static_delay_ms', '0');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('log_level', 'INFO');
EOF
    
    record_install "database_minimal"
    log_success "Database configured (minimal)"
}

# ============================================================================
# INSTALLATION FUNCTIONS - FULL (UI Integration)
# ============================================================================

install_constants_php() {
    log_info "Updating constants.php..."
    
    local target="${INC_DIR}/constants.php"
    
    if detect_constants_php; then
        log_warn "FEAT_SENDSPIN already exists in constants.php"
        return 0
    fi
    
    backup_file "$target" "constants.php"
    
    # Add FEAT_SENDSPIN after FEAT_PEPPYDISPLAY
    sed -i '/const FEAT_PEPPYDISPLAY/a const FEAT_SENDSPIN      = 262144;' "$target"
    
    if verify_php_syntax "$target"; then
        record_install "constants_php"
        log_success "constants.php updated"
    else
        log_error "PHP syntax check failed for constants.php"
        return 1
    fi
}

install_renderer_php() {
    log_info "Updating renderer.php..."
    
    local target="${INC_DIR}/renderer.php"
    local tmp_file="/tmp/renderer_sendspin_patch.php"
    
    if detect_renderer_php; then
        log_warn "SendSpin functions already exist in renderer.php"
        return 0
    fi
    
    backup_file "$target" "renderer.php"
    
    # Add SendSpin renderer functions at end of file
    cat >> "$target" << 'EOF'

// SendSpin Multi-Room Audio renderer functions

function getSendspinStatus() {
	// Check systemd service status safely
	$result = sysCmd('systemctl is-active sendspin 2>/dev/null');
	$status = (!empty($result) && isset($result[0])) ? $result[0] : 'inactive';
	if ($status === 'active') {
		// Check if actually streaming (process using audio)
		$sndResult = sysCmd('fuser /dev/snd/pcmC0D0p 2>/dev/null');
		if (!empty($sndResult)) {
			// Check if sendspin is using the device
			$sendspinPids = sysCmd('pgrep -f sendspin 2>/dev/null');
			foreach ($sendspinPids as $pid) {
				if (strpos($sndResult[0], $pid) !== false) {
					return 'streaming';
				}
			}
		}
		return 'ready';
	}
	return 'inactive';
}

function startSendspin() {
	// Save MPD state before starting
	$mpdStatus = sysCmd('mpc status')[0];
	$mpdWasPlaying = strpos($mpdStatus, 'playing') !== false;
	phpSession('write', 'mpd_was_playing', $mpdWasPlaying ? '1' : '0');

	// Stop MPD to release ALSA device
	sysCmd('mpc stop');

	// Note: Using direct hardware access, dmix has IPC issues
	configureAlsaForSendspin(true);

	// Start SendSpin daemon
	sysCmd('systemctl start sendspin');

	workerLog('startSendspin(): daemon started (MPD was playing: ' . ($mpdWasPlaying ? 'yes' : 'no') . ')');
}

function stopSendspin() {
	// Stop SendSpin daemon
	sysCmd('systemctl stop sendspin');

	// Note: Using direct hardware access
	configureAlsaForSendspin(false);

	// Optionally resume MPD if it was playing
	if ($_SESSION['mpd_was_playing'] == '1') {
		sleep(1); // Allow SendSpin to release device
		sysCmd('mpc play');
		phpSession('write', 'mpd_was_playing', '0');
		workerLog('stopSendspin(): MPD playback resumed');
	}

	workerLog('stopSendspin(): daemon stopped');
}

function configureAlsaForSendspin($enable) {
	// NOTE: SendSpin uses direct hardware access via sendspin.conf
	// The dmix approach has IPC key issues with moOde's _audioout configuration
	// Using type plug with hw:0,0 provides reliable operation
	workerLog('configureAlsaForSendspin(): ' . ($enable ? 'shared' : 'exclusive') . ' mode (direct hw)');
	return true;
}
EOF
    
    if verify_php_syntax "$target"; then
        record_install "renderer_php"
        log_success "renderer.php updated"
    else
        log_error "PHP syntax check failed for renderer.php"
        return 1
    fi
}

install_lib_min_js() {
    log_info "Updating lib.min.js..."
    
    local target="${WWW_DIR}/js/lib.min.js"
    
    if detect_lib_min_js; then
        log_warn "FEAT_SENDSPIN already exists in lib.min.js"
        return 0
    fi
    
    backup_file "$target" "lib.min.js"
    
    # Add FEAT_SENDSPIN after FEAT_PEPPYDISPLAY
    sed -i 's/FEAT_PEPPYDISPLAY=131072/FEAT_PEPPYDISPLAY=131072,FEAT_SENDSPIN=262144/g' "$target"
    
    if grep -q "FEAT_SENDSPIN=262144" "$target"; then
        record_install "lib_min_js"
        log_success "lib.min.js updated"
    else
        log_error "Failed to update lib.min.js"
        return 1
    fi
}

install_worker_php() {
    log_info "Updating worker.php..."
    
    local target="${WWW_DIR}/worker.php"
    local tmp_file="/tmp/worker_sendspin_patch.php"
    
    if detect_worker_php; then
        log_warn "SendSpin code already exists in worker.php"
        return 0
    fi
    
    backup_file "$target" "worker.php"
    
    # Get the worker.php content
    cp "$target" "$tmp_file"
    
    # Add sendspin startup code after RoonBridge startup check
    # Look for the pattern checking roonbridge service and insert after that block
    python3 << 'PYEOF'
import re

with open('/tmp/worker_sendspin_patch.php', 'r') as f:
    content = f.read()

# Find the RoonBridge startup code and add SendSpin after it
sendspin_startup = '''
	// SendSpin
	if ($_SESSION['sendspinsvc'] == '1') {
		startSendspin();
	}
'''

# Find RoonBridge startup pattern and insert after it
pattern = r"(// RoonBridge.*?if \(\$_SESSION\['roonbridge_svc'\] == '1'\) \{[^}]+\})"
match = re.search(pattern, content, re.DOTALL)

if match:
    insert_pos = match.end()
    content = content[:insert_pos] + sendspin_startup + content[insert_pos:]

# Now add the case statements for job handling
# Find the case 'rbrestart': block and add sendspin cases after it
sendspin_cases = '''
	case 'sendspinsvc':
		if ($_SESSION['sendspinsvc'] == '1') {
			startSendspin();
		}
		else {
			stopSendspin();
		}
		break;
	case 'sendspinrestart':
		// Save MPD state before stopping
		$mpdStatus = sysCmd('mpc status');
		$mpdWasPlaying = (!empty($mpdStatus) && strpos($mpdStatus[0], 'playing') !== false);
		phpSession('write', 'mpd_was_playing', $mpdWasPlaying ? '1' : '0');
		sysCmd('mpc stop');
		stopSendspin();
		if ($_SESSION['sendspinsvc'] == '1') {
			startSendspin();
		}
		break;
'''

# Find case 'rbrestart' and insert after the break
rb_pattern = r"(case 'rbrestart':.*?break;)"
rb_match = re.search(rb_pattern, content, re.DOTALL)

if rb_match:
    insert_pos = rb_match.end()
    content = content[:insert_pos] + sendspin_cases + content[insert_pos:]

with open('/tmp/worker_sendspin_patch.php', 'w') as f:
    f.write(content)

print("worker.php patched successfully")
PYEOF
    
    mv "$tmp_file" "$target"
    chown www-data:www-data "$target"
    
    if verify_php_syntax "$target"; then
        record_install "worker_php"
        log_success "worker.php updated"
    else
        log_error "PHP syntax check failed for worker.php"
        return 1
    fi
}

install_ren_config_php() {
    log_info "Updating ren-config.php..."
    
    local target="${WWW_DIR}/ren-config.php"
    
    if detect_ren_config_php; then
        log_warn "SendSpin code already exists in ren-config.php"
        return 0
    fi
    
    backup_file "$target" "ren-config.php"
    
    # Find line with waitWorker and insert before it
    local line=$(grep -n "waitWorker('ren-config')" "$target" | head -1 | cut -d: -f1)
    
    if [[ -z "$line" ]]; then
        log_error "Could not find insertion point in ren-config.php"
        return 1
    fi
    
    # Create temp file with SendSpin code inserted
    head -n $((line-1)) "$target" > /tmp/ren-config-new.php
    
    cat >> /tmp/ren-config-new.php << 'EOF'
// SendSpin Multi-Room Audio
if (isset($_POST['update_sendspin_settings'])) {
	if (isset($_POST['sendspinsvc']) && $_POST['sendspinsvc'] != $_SESSION['sendspinsvc']) {
		$update = true;
		phpSession('write', 'sendspinsvc', $_POST['sendspinsvc'])

... [OUTPUT TRUNCATED - 12 chars omitted out of 50012 total] ...

set($_POST['sendspinname']) && $_POST['sendspinname'] != $_SESSION['sendspinname']) {
		$update = true;
		phpSession('write', 'sendspinname', $_POST['sendspinname']);
		sysCmd("sed -i 's/--name .*/--name " . $_POST['sendspinname'] . "/' /etc/systemd/system/sendspin.service");
		sysCmd('systemctl daemon-reload');
	}
	if (isset($update)) {
		submitJob('sendspinsvc');
	}
}
if (isset($_POST['sendspinrestart']) && $_POST['sendspinrestart'] == 1 && $_SESSION['sendspinsvc'] == '1') {
	submitJob('sendspinrestart', '', NOTIFY_TITLE_INFO, 'SendSpin' . NOTIFY_MSG_SVC_MANUAL_RESTART);
}

if (($_SESSION['feat_bitmask'] & FEAT_SENDSPIN)) {
	$_feat_sendspin = '';
	$_SESSION['sendspin_installed'] == 'yes' ? $_sendspin_svcbtn_disable = '' : $_sendspin_svcbtn_disable = 'disabled';
	$_SESSION['sendspinsvc'] == '1' ? $_sendspin_btn_disable = '' : $_sendspin_btn_disable = 'disabled';
	$_SESSION['sendspinsvc'] == '1' ? $_sendspin_link_disable = '' : $_sendspin_link_disable = 'onclick=\"return false;\"';
	$autoClick = " onchange=\\\"autoClick('#btn-set-sendspinsvc');\\\"";
	$_select['sendspinsvc_on']  = "<input type=\"radio\" name=\"sendspinsvc\" id=\"toggle-sendspinsvc-1\" value=\"1\" " . (($_SESSION['sendspinsvc'] == '1') ? "checked=\"checked\"" : "") . $_sendspin_svcbtn_disable . $autoClick . \">\\n\";
	$_select['sendspinsvc_off'] = "<input type=\"radio\" name=\"sendspinsvc\" id=\"toggle-sendspinsvc-2\" value=\"0\" " . (($_SESSION['sendspinsvc'] == '0') ? "checked=\"checked\"" : "") . $_sendspin_svcbtn_disable . $autoClick . \">\\n\";
	$_select["sendspinname"] = $_SESSION["sendspinname"];
} else {
	$_feat_sendspin = 'hide';
}

EOF
    
    tail -n +$line "$target" >> /tmp/ren-config-new.php
    mv /tmp/ren-config-new.php "$target"
    
    if verify_php_syntax "$target"; then
        record_install "ren_config_php"
        log_success "ren-config.php updated"
    else
        log_error "PHP syntax check failed for ren-config.php"
        return 1
    fi
}

install_ren_config_html() {
    log_info "Updating ren-config.html..."
    
    local target="${WWW_DIR}/templates/ren-config.html"
    
    if detect_ren_config_html; then
        log_warn "SendSpin UI already exists in ren-config.html"
        return 0
    fi
    
    backup_file "$target" "ren-config.html"
    
    # Find the RoonBridge section end and insert after it
    local line=$(grep -n '_feat_roonbridge' "$target" | tail -1 | cut -d: -f1)
    
    if [[ -z "$line" ]]; then
        # Try to find the closing </form> after RoonBridge
        line=$(grep -n '</form>' "$target" | head -3 | tail -1 | cut -d: -f1)
    fi
    
    if [[ -z "$line" ]]; then
        log_error "Could not find insertion point in ren-config.html"
        return 1
    fi
    
    # Insert SendSpin UI section
    head -n $((line)) "$target" > /tmp/ren-config-new.html
    
    cat >> /tmp/ren-config-new.html << 'EOF'

		<div class="control-group $_feat_sendspin">
			<legend>SendSpin</legend>
			<p class="sub-legend">
				Requires sendspin-cli, view the <a href="./setup_3rdparty_sendspin.txt" class="target-blank-link" target="_blank">setup guide</a>.
			</p>
			<label class="control-label">Service</label>
			<div class="controls">
				<div class="toggle">
					<label class="toggle-radio toggle-sendspinsvc" for="toggle-sendspinsvc-2">ON </label>$_select[sendspinsvc_on]
					<label class="toggle-radio toggle-sendspinsvc" for="toggle-sendspinsvc-1">OFF</label>$_select[sendspinsvc_off]
				</div>
				<button id="btn-set-sendspinsvc" class="hide btn btn-primary btn-small config-btn-set btn-submit" type="submit" name="update_sendspin_settings" value="novalue"><i class="fa fa-solid fa-sharp fa-arrow-turn-down-left"></i></button>
				<a aria-label="Help" class="config-info-toggle" data-cmd="info-sendspinsvc" href="#notarget"><i class="fa-regular fa-sharp fa-info-circle"></i></a>
				<span id="info-sendspinsvc" class="config-help-info">
					SendSpin Multi-Room Audio Client.
                </span>
			</div>

			<label class="control-label">Name</label>
			<div class="controls">
				<input class="config-input-large" type="text" id="sendspinname" name="sendspinname" value="$_select[sendspinname]" onchange="autoClick('#btn-set-sendspinname');">
				<button id="btn-set-sendspinname" class="hide btn btn-primary btn-small config-btn-set btn-submit" type="submit" name="update_sendspin_settings" value="novalue"><i class="fa fa-solid fa-sharp fa-arrow-turn-down-left"></i></button>
				<a aria-label="Help" class="config-info-toggle" data-cmd="info-sendspinname" href="#notarget"><i class="fa-regular fa-sharp fa-info-circle"></i></a>
				<span id="info-sendspinname" class="config-help-info">
					The name that appears in multi-room controller.
                </span>
			</div>

			<div class="controls">
				<a data-toggle="modal" href="#sendspin-restart" $_sendspin_link_disable><button class="btn btn-medium btn-primary config-btn" $_sendspin_btn_disable>Restart</button></a>
				<span class="config-btn-after">SendSpin</span>
			</div>
		</div>
EOF
    
    tail -n +$((line+1)) "$target" >> /tmp/ren-config-new.html
    
    # Also add the restart modal at the end
    cat >> /tmp/ren-config-new.html << 'EOF'

<form class="form-horizontal" method="post">
	<div id="sendspin-restart" class="modal hide" tabindex="-1" role="dialog" aria-labelledby="sendspin-restart-label" aria-hidden="true">
		<div class="modal-header"><button type="button" class="close" data-dismiss="modal" aria-hidden="true">&times;</button>
			<h3>Restart SendSpin renderer?</h3>
		</div>
		<div class="modal-body"></div>
		<div class="modal-footer">
			<button class="btn" data-dismiss="modal" aria-hidden="true">Cancel</button>
			<button class="btn btn-primary btn-submit" type="submit" name="sendspinrestart" value="1">Yes</button>
		</div>
	</div>
</form>
EOF
    
    mv /tmp/ren-config-new.html "$target"
    
    record_install "ren_config_html"
    log_success "ren-config.html updated"
}

install_setup_txt() {
    log_info "Installing setup documentation..."
    
    local target="${WWW_DIR}/setup_3rdparty_sendspin.txt"
    
    if detect_setup_txt; then
        log_warn "setup_3rdparty_sendspin.txt already exists"
        return 0
    fi
    
    cat > "$target" << 'EOF'
################################################################################
#
#  Setup Guide for SendSpin Multi-Room Audio Renderer
#
#  Version: 1.2 (2026-06-21)
#
################################################################################

OVERVIEW

This document provides setup instructions for using SendSpin with moOde. SendSpin
is a synchronized multi-room audio protocol that allows moOde to act as an audio
endpoint in a multi-room audio system.

With SendSpin integration, moOde becomes a multi-room audio endpoint that can:
- Receive synchronized audio from a SendSpin server (e.g., Music Assistant)
- Play audio simultaneously with other SendSpin clients
- Resume MPD playback when SendSpin streaming stops

REQUIREMENTS

- moOde 9.x or later
- SendSpin CLI (sendspin) installed
- Raspberry Pi 3/4/5 or compatible Linux system
- Network connection to SendSpin server

INSTALLATION

Step 1: Install SendSpin CLI

SSH to your moOde device and install SendSpin:

    # Install uv (Python package manager)
    pip3 install uv --break-system-packages

    # Install sendspin-cli
    uv tool install sendspin

Verify installation:
    sendspin --version    # Should show 7.5.0 or later

Step 2: Enable SendSpin in moOde

1. Open moOde web UI
2. Go to Configure → Renderers
3. Find the "SendSpin" section
4. Set the Name field (this appears in your controller)
5. Toggle the Service switch to ON
6. Click the arrow button to save

Step 3: Verify in Your Controller

1. Open your multi-room audio controller (e.g., Music Assistant)
2. Your moOde device should appear with the name you configured
3. Select it as an audio output and start playback
4. Audio should stream to moOde

CONFIGURATION OPTIONS

Name:
    The name that appears in your multi-room audio controller.
    Default: "moode-sendspin"
    Change this to identify your device (e.g., "Kitchen Speaker", "Living Room")

Service Toggle:
    ON  - SendSpin is active and appears as an available endpoint
    OFF - SendSpin is stopped and does not appear in the controller

Restart Button:
    Restarts the SendSpin service. Use this if the device disappears from
    the controller or audio stops working.

VOLUME LEVEL

SendSpin output is attenuated by approximately 3dB to match the level of other
moOde audio sources. This ensures consistent volume when switching between MPD
playback and SendSpin streaming.

If you need to adjust this:
- Edit /etc/alsa/conf.d/sendspin.conf
- Change the ttable values (0.707 = -3dB, 1.0 = 0dB, 0.5 = -6dB)
- Restart SendSpin: sudo systemctl restart sendspin

TROUBLESHOOTING

"Device in Use" error [PaErrorCode -9985]:

    This error occurs when SendSpin cannot open the audio device because MPD
    is currently using it.

    SOLUTION: Enable the SendSpin service in moOde UI first. The integration
    handles ALSA device sharing automatically. If you start SendSpin manually
    via SSH, stop MPD first:

        mpc stop
        sudo systemctl start sendspin

No audio when streaming starts:

    1. Check SendSpin service status:
       sudo systemctl status sendspin

    2. View SendSpin logs:
       sudo journalctl -u sendspin -f

    3. Verify the daemon is running:
       pgrep -f "sendspin daemon"

    4. Check ALSA configuration:
       aplay -L | grep sendspin

moOde device not appearing in controller:

    1. Check that Service is toggled ON in moOde UI
    2. Verify mDNS discovery is working:
       sendspin --list-servers
    3. Ensure your controller is on the same network
    4. Check firewall settings (port 44556/UDP for mDNS)
    5. Restart SendSpin service

Audio dropouts or stuttering:

    1. Check CPU usage during playback: top
    2. Ensure adequate power supply (especially for Pi 4/5)
    3. Try a wired network connection instead of WiFi
    4. Lower the audio quality in your controller settings

MPD does not resume after SendSpin stops:

    1. Check that Resume MPD is enabled in moOde settings
    2. Verify MPD was playing before SendSpin started
    3. Check moOde logs: sudo tail -f /var/log/moode.log

Command Reference

    # Check SendSpin status
    sudo systemctl status sendspin

    # View SendSpin logs
    sudo journalctl -u sendspin -f

    # List available SendSpin servers on network
    sendspin --list-servers

    # List audio devices
    sendspin --list-audio-devices

    # Restart SendSpin
    sudo systemctl restart sendspin

    # Check ALSA configuration
    cat /etc/alsa/conf.d/sendspin.conf
    aplay -L | grep -A2 sendspin

VERSION HISTORY

v1.2 (2026-06-21)
  - Added volume level information
  - Fixed spelling and grammar
  - Updated troubleshooting section
  - Added command reference section

v1.1 (2026-06-19)
  - Updated for moOde UI integration
  - Auto-configuration documentation

v1.0 (2026-02-28)
  - Initial release

################################################################################
#  For support, visit https://github.com/kiwipaulrob/moode/issues
################################################################################
EOF
    
    chown www-data:www-data "$target"
    chmod 644 "$target"
    
    record_install "setup_txt"
    log_success "Documentation installed"
}

install_database_entries_full() {
    log_info "Configuring database (full)..."
    
    if [[ ! -f "$DB_PATH" ]]; then
        log_error "Database not found at ${DB_PATH}"
        return 1
    fi
    
    backup_file "$DB_PATH" "moode-sqlite3.db"
    
    # Add full database entries
    sqlite3 "$DB_PATH" << 'EOF'
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('sendspinsvc', '0');
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('sendspin_installed', 'yes');
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('sendspinname', 'moode-sendspin');
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('rsmafterss', 'No');
CREATE TABLE IF NOT EXISTS cfg_sendspin (id INTEGER PRIMARY KEY, param CHAR (32), value CHAR (128));
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_codec', 'flac');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_rate', '48000');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_depth', '16');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('static_delay_ms', '0');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('log_level', 'INFO');
EOF
    
    # Update feat_bitmask
    local current_bitmask
    current_bitmask=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_system WHERE param='feat_bitmask';" 2>/dev/null || echo "0")
    local new_bitmask=$((current_bitmask | 262144))
    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('feat_bitmask', '${new_bitmask}');"
    
    record_install "database_full"
    log_success "Database configured (full)"
}

# ============================================================================
# SERVICE FILE REGENERATION
# ============================================================================

install_regenerate_service() {
    log_info "Regenerating service file from DB defaults..."
    local php_script="/tmp/ssp-regenerate.php"
    cat > "$php_script" << 'PHPEOF'
<?php
require_once '/var/www/inc/renderer.php';
require_once '/var/www/inc/sql.php';
$dbh = sqlConnect();
$result = generateSendspinService($dbh);
echo $result ? "Service file regenerated.\n" : "Failed to regenerate service file.\n";
PHPEOF
    local output
    output=$(php "$php_script" 2>&1) || true
    rm -f "$php_script"
    echo "$output"
    if echo "$output" | grep -q "regenerated"; then
        log_success "Service file regenerated from DB"
    else
        log_warn "Could not regenerate service file (renderer.php may not be deployed yet)"
    fi
}

# ============================================================================
# UNINSTALL FUNCTIONS
# ============================================================================

find_and_restore_backup() {
    log_info "Searching for backup files..."
    
    local backup_dirs=(/var/backups/moode-sendspin-*/)
    
    if [[ ${#backup_dirs[@]} -eq 0 ]]; then
        log_warn "No backup directories found"
        return 1
    fi
    
    # Sort by modification time, get the most recent
    local latest_backup=""
    for dir in "${backup_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            if [[ -z "$latest_backup" ]] || [[ "$dir" -nt "$latest_backup" ]]; then
                latest_backup="$dir"
            fi
        fi
    done
    
    if [[ -n "$latest_backup" ]]; then
        log_info "Using backup: $latest_backup"
        echo "$latest_backup"
        return 0
    fi
    
    return 1
}

uninstall_sendspin() {
    log_section "SendSpin Uninstallation"
    
    if [[ $EUID -ne 0 ]]; then
        log_error "Uninstall must be run as root"
        exit 1
    fi
    
    # Confirm uninstallation
    if [[ "${FORCE_UNINSTALL:-}" != "true" ]]; then
        echo ""
        read -p "Are you sure you want to uninstall SendSpin? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Uninstallation cancelled"
            exit 0
        fi
    fi
    
    log_info "This will completely remove SendSpin integration..."
    
    # Find backup
    local backup_dir
    backup_dir=$(find_and_restore_backup)
    
    # Stop and disable service
    log_info "Stopping SendSpin service..."
    systemctl stop sendspin 2>/dev/null || true
    systemctl disable sendspin 2>/dev/null || true
    
    # Remove systemd service
    if [[ -f "${SYSTEMD_DIR}/sendspin.service" ]]; then
        rm -f "${SYSTEMD_DIR}/sendspin.service"
        systemctl daemon-reload
        log_success "Removed sendspin.service"
    fi
    
    # Restore files from backup if available
    if [[ -n "$backup_dir" ]]; then
        log_info "Restoring original files from backup..."
        
        # Restore constants.php
        if [[ -f "${backup_dir}/constants.php" ]]; then
            cp "${backup_dir}/constants.php" "${INC_DIR}/constants.php"
            chown www-data:www-data "${INC_DIR}/constants.php"
            log_success "Restored constants.php"
        else
            sed -i '/FEAT_SENDSPIN/d' "${INC_DIR}/constants.php" 2>/dev/null || true
        fi
        
        # Restore renderer.php
        if [[ -f "${backup_dir}/renderer.php" ]]; then
            cp "${backup_dir}/renderer.php" "${INC_DIR}/renderer.php"
            chown www-data:www-data "${INC_DIR}/renderer.php"
            log_success "Restored renderer.php"
        else
            sed -i '/SendSpin Multi-Room Audio/,/^}/d' "${INC_DIR}/renderer.php" 2>/dev/null || true
        fi
        
        # Restore lib.min.js
        if [[ -f "${backup_dir}/lib.min.js" ]]; then
            cp "${backup_dir}/lib.min.js" "${WWW_DIR}/js/lib.min.js"
            log_success "Restored lib.min.js"
        else
            sed -i 's/,FEAT_SENDSPIN=262144//g' "${WWW_DIR}/js/lib.min.js" 2>/dev/null || true
        fi
        
        # Restore worker.php
        if [[ -f "${backup_dir}/worker.php" ]]; then
            cp "${backup_dir}/worker.php" "${WWW_DIR}/worker.php"
            chown www-data:www-data "${WWW_DIR}/worker.php"
            log_success "Restored worker.php"
        else
            # Remove SendSpin startup and job handlers
            sed -i '/\/\/ SendSpin startup/,/^\t\}$/d' "${WWW_DIR}/worker.php" 2>/dev/null || true
            sed -i "/case 'sendspinsvc':/,/break;/d" "${WWW_DIR}/worker.php" 2>/dev/null || true
            sed -i "/case 'sendspinrestart':/,/break;/d" "${WWW_DIR}/worker.php" 2>/dev/null || true
        fi
        
        # Restore ren-config.php
        if [[ -f "${backup_dir}/ren-config.php" ]]; then
            cp "${backup_dir}/ren-config.php" "${WWW_DIR}/ren-config.php"
            chown www-data:www-data "${WWW_DIR}/ren-config.php"
            log_success "Restored ren-config.php"
        else
            # Remove SendSpin code blocks
            sed -i '/\/\/ SendSpin Multi-Room Audio/,/^}$/d' "${WWW_DIR}/ren-config.php" 2>/dev/null || true
            sed -i '/\$_feat_sendspin/d' "${WWW_DIR}/ren-config.php" 2>/dev/null || true
        fi
        
        # Restore ren-config.html
        if [[ -f "${backup_dir}/ren-config.html" ]]; then
            cp "${backup_dir}/ren-config.html" "${WWW_DIR}/templates/ren-config.html"
            log_success "Restored ren-config.html"
        else
            # Remove SendSpin sections
            sed -i '/_feat_sendspin/,/\/div>/d' "${WWW_DIR}/templates/ren-config.html" 2>/dev/null || true
            sed -i '/sendspin-restart/,/\/form>/d' "${WWW_DIR}/templates/ren-config.html" 2>/dev/null || true
        fi
        
        # Remove setup documentation
        rm -f "${WWW_DIR}/setup_3rdparty_sendspin.txt"
        log_success "Removed documentation"
    else
        log_warn "No backup found! Attempting manual cleanup..."
        
        # Manual cleanup attempts
        sed -i '/FEAT_SENDSPIN/d' "${INC_DIR}/constants.php" 2>/dev/null || true
        sed -i '/SendSpin Multi-Room Audio/,/^}/d' "${INC_DIR}/renderer.php" 2>/dev/null || true
        sed -i 's/,FEAT_SENDSPIN=262144//g' "${WWW_DIR}/js/lib.min.js" 2>/dev/null || true
        sed -i '/\/\/ SendSpin/,/^}$/d' "${WWW_DIR}/ren-config.php" 2>/dev/null || true
        sed -i '/_feat_sendspin/,/\/div>/d' "${WWW_DIR}/templates/ren-config.html" 2>/dev/null || true
        sed -i '/\/\/ SendSpin startup/,/^\t\}$/d' "${WWW_DIR}/worker.php" 2>/dev/null || true
        sed -i "/case 'sendspinsvc':/,/break;/d" "${WWW_DIR}/worker.php" 2>/dev/null || true
        sed -i "/case 'sendspinrestart':/,/break;/d" "${WWW_DIR}/worker.php" 2>/dev/null || true
        rm -f "${WWW_DIR}/setup_3rdparty_sendspin.txt"
    fi
    
    # Remove database entries
    if [[ -f "$DB_PATH" ]]; then
        log_info "Removing database entries..."
        sqlite3 "$DB_PATH" "DELETE FROM cfg_system WHERE param LIKE 'sendspin%';" 2>/dev/null || true
        
        # Remove feat_bitmask bit
        local current_bitmask
        current_bitmask=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_system WHERE param='feat_bitmask';" 2>/dev/null || echo "0")
        local new_bitmask=$((current_bitmask & ~262144))
        sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('feat_bitmask', '${new_bitmask}');" 2>/dev/null || true
        log_success "Database cleaned"
    fi
    
    # Clear PHP sessions
    log_info "Clearing PHP sessions..."
    rm -f /var/lib/php/sessions/sess_* 2>/dev/null || true
    
    # Final verification
    log_section "Verification"
    
    local found_traces=false
    
    if detect_constants_php; then
        log_warn "Traces found in constants.php"
        found_traces=true
    fi
    
    if detect_renderer_php; then
        log_warn "Traces found in renderer.php"
        found_traces=true
    fi
    
    if detect_lib_min_js; then
        log_warn "Traces found in lib.min.js"
        found_traces=true
    fi
    
    if detect_worker_php; then
        log_warn "Traces found in worker.php"
        found_traces=true
    fi
    
    if detect_ren_config_php; then
        log_warn "Traces found in ren-config.php"
        found_traces=true
    fi
    
    if detect_ren_config_html; then
        log_warn "Traces found in ren-config.html"
        found_traces=true
    fi
    
    if detect_systemd_service; then
        log_warn "Systemd service still exists"
        found_traces=true
    fi
    
    if detect_database_entries; then
        log_warn "Database entries still exist"
        found_traces=true
    fi
    
    echo ""
    if [[ "$found_traces" == "true" ]]; then
        log_warn "Some traces may remain. Manual cleanup may be required."
    else
        log_success "SendSpin completely uninstalled!"
    fi
    
    echo ""
    log_info "Restart services to complete cleanup:"
    echo "  sudo systemctl restart php7.4-fpm"
    echo "  sudo systemctl restart moode-worker"
}

# ============================================================================
# MAIN INSTALLATION
# ============================================================================

run_installation() {
    log_section "moOde SendSpin Integration Installer v${SCRIPT_VERSION}"
    
    # Check for root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo "Usage: curl -fsSL ... | sudo bash"
        exit 1
    fi
    
    # Check if running on moOde
    if ! is_moode; then
        log_error "This does not appear to be a moOde installation"
        log_error "Expected files not found at ${WWW_DIR}"
        exit 1
    fi
    
    log_success "Detected moOde installation"
    
    # Check if production (minified)
    if is_production_moode; then
        log_info "Detected production moOde (minified JS)"
    else
        log_info "Detected development moOde"
    fi
    
    # Display installation mode
    if [[ "$INSTALL_MODE" == "minimal" ]]; then
        log_info "Installation mode: MINIMAL (endpoint only)"
    else
        log_info "Installation mode: FULL (UI integration)"
    fi
    
    # Check current installation status
    local install_status
    check_installation
    install_status=$?
    
    if [[ $install_status -eq 0 ]]; then
        echo ""
        log_warn "SendSpin appears to already be fully installed!"
        echo ""
        read -p "Do you want to reinstall anyway? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
        log_info "Proceeding with reinstallation..."
    elif [[ $install_status -eq 2 ]]; then
        echo ""
        log_warn "Partial installation detected. Continuing may cause issues."
        echo ""
        read -p "Do you want to continue? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled. Run with --uninstall first to clean up."
            exit 0
        fi
    fi
    
    # Initialize backup
    init_backup
    
    echo ""
    log_section "Starting Installation"
    
    # Install prerequisites (Python, uv, sendspin CLI)
    install_prerequisites
    
    # Install based on mode
    if [[ "$INSTALL_MODE" == "minimal" ]]; then
        install_alsa_config
        install_systemd_service
        install_moode_worker_service
        install_database_entries_minimal
    else
        install_alsa_config
        install_systemd_service
        install_moode_worker_service
        install_constants_php
        install_renderer_php
        install_lib_min_js
        install_worker_php
        install_ren_config_php
        install_ren_config_html
        install_setup_txt
        install_database_entries_full
    fi
    
    log_section "Post-Installation Verification"
    
    # Verify installation
    local verify_passed=true
    
    if [[ "$INSTALL_MODE" == "full" ]]; then
        detect_constants_php || { log_error "constants.php verification failed"; verify_passed=false; }
        detect_renderer_php || { log_error "renderer.php verification failed"; verify_passed=false; }
        detect_lib_min_js || { log_error "lib.min.js verification failed"; verify_passed=false; }
        detect_worker_php || { log_error "worker.php verification failed"; verify_passed=false; }
        detect_ren_config_php || { log_error "ren-config.php verification failed"; verify_passed=false; }
        detect_ren_config_html || { log_error "ren-config.html verification failed"; verify_passed=false; }
    fi
    
    detect_systemd_service || { log_error "systemd service verification failed"; verify_passed=false; }
    detect_database_entries || { log_error "database verification failed"; verify_passed=false; }
    detect_feat_bitmask || { log_warn "feat_bitmask may need manual refresh"; }
    
    echo ""
    if [[ "$verify_passed" == "true" ]]; then
        log_success "SendSpin installation completed successfully!"
        # Regenerate service file from DB defaults so it stays in sync
        install_regenerate_service
    else
        log_warn "Installation completed with some verification failures."
    fi
    
    log_section "Next Steps"
    
    if [[ "$INSTALL_MODE" == "minimal" ]]; then
        echo "Minimal installation complete. SendSpin endpoint is ready."
        echo ""
        echo "To upgrade to full UI integration, run:"
        echo "  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/moode-sendspin-installer.sh | sudo bash"
    else
        echo "1. Restart services:"
        echo "     sudo systemctl restart php7.4-fpm"
        echo "     sudo systemctl restart moode-worker"
        echo ""
        echo "2. Open moOde UI and go to: Configure > Renderers"
        echo ""
        echo "3. Enable SendSpin and enjoy multi-room audio!"
        echo ""
        echo "4. To change the endpoint name, edit the 'Name' field in SendSpin settings"
    fi
    
    echo ""
    if [[ "$SKIP_BACKUP" != "true" ]]; then
        echo "Backup location: ${BACKUP_DIR}"
    fi
    echo "To uninstall: curl -fsSL ... | sudo bash -s -- --uninstall"
    echo ""
}

# ============================================================================
# COMMAND LINE PARSING
# ============================================================================

print_help() {
    echo "moOde SendSpin Integration Installer v${SCRIPT_VERSION}"
    echo ""
    echo "Usage:"
    echo "  Full Install:     curl -fsSL ... | sudo bash"
    echo "  Minimal Install:  curl -fsSL ... | sudo bash -s -- --minimal"
    echo "  Check Status:     curl -fsSL ... | sudo bash -s -- --check"
    echo "  Uninstall:        curl -fsSL ... | sudo bash -s -- --uninstall"
    echo "  Force Uninstall:  curl -fsSL ... | sudo bash -s -- --uninstall --force"
    echo "  No Backup:        curl -fsSL ... | sudo bash -s -- --no-backup"
    echo ""
    echo "Options:"
    echo "  --minimal, -m      Minimal installation (endpoint only, no UI changes)"
    echo "  --full, -f         Full installation with UI integration (default)"
    echo "  --check, -c        Check installation status"
    echo "  --uninstall, -u    Uninstall SendSpin and restore original files"
    echo "  --force            Skip confirmation prompts"
    echo "  --no-backup        Skip backup creation"
    echo "  --help, -h         Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Full install with UI integration"
    echo "  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/moode-sendspin-installer.sh | sudo bash"
    echo ""
    echo "  # Minimal install (endpoint only)"
    echo "  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/moode-sendspin-installer.sh | sudo bash -s -- --minimal"
    echo ""
    echo "  # Check installation status"
    echo "  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/moode-sendspin-installer.sh | sudo bash -s -- --check"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --minimal|-m)
            INSTALL_MODE="minimal"
            shift
            ;;
        --full|-f)
            INSTALL_MODE="full"
            shift
            ;;
        --check|-c)
            check_installation
            exit $?
            ;;
        --uninstall|-u)
            uninstall_sendspin
            exit $?
            ;;
        --force)
            FORCE_UNINSTALL=true
            export FORCE_UNINSTALL
            shift
            ;;
        --no-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --help|-h)
            print_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

# Run installation
run_installation