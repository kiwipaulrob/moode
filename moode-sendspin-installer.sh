#!/bin/bash
#
# moOde SendSpin Integration Installer v4.1.0
# Repository: https://github.com/kiwipaulrob/moode
# Branch: sendspin-advanced
#
# Usage:
#   Full Install:   curl -fsSL ... | sudo bash
#   Minimal Install: curl -fsSL ... | sudo bash -s -- --minimal
#   Uninstall:      curl -fsSL ... | sudo bash -s -- --uninstall
#   Force Install:  curl -fsSL ... | sudo bash -s -- --force
#   Uninstall Force: curl -fsSL ... | sudo bash -s -- --uninstall --force
#   Check Status:   curl -fsSL ... | sudo bash -s -- --check
#   No Backup:      curl -fsSL ... | sudo bash -s -- --no-backup
#
# This script integrates SendSpin Multi-Room Audio Client into moOde 9.4.2+

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_VERSION="4.1.0"
REPO_OWNER="kiwipaulrob"
REPO_NAME="moode"
BRANCH="sendspin-advanced"
BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}"

# File locations on moOde
WWW_DIR="/var/www"
INC_DIR="${WWW_DIR}/inc"
SYSTEMD_DIR="/etc/systemd/system"
DB_PATH="/var/local/www/db/moode-sqlite3.db"

# Feature bitmask for SendSpin
FEAT_SENDSPIN=262144

# Installation modes
INSTALL_MODE="full"  # "minimal" or "full"
SKIP_BACKUP=false
FORCE=false

# Backup directory (set during runtime)
BACKUP_DIR=""

# Files modified by FULL installation
FULL_INSTALL_FILES=(
    "${INC_DIR}/constants.php"
    "${INC_DIR}/renderer.php"
    "${WWW_DIR}/js/playerlib.js"
    "${WWW_DIR}/ren-config.php"
    "${WWW_DIR}/templates/ren-config.html"
    "${WWW_DIR}/ssp-config.php"
    "${WWW_DIR}/templates/ssp-config.html"
    "${WWW_DIR}/setup_3rdparty_sendspin.txt"
    "${WWW_DIR}/daemon/worker.php"
    "/var/local/www/commandw/sendspin-spspre.sh"
    "/var/local/www/commandw/sendspin-metadata.sh"
    "/var/local/www/commandw/spspost.sh"
    "/var/local/www/commandw/sendspin-version-check.sh"
    "${WWW_DIR}/command/sendspin-meta.php"
    "${WWW_DIR}/js/sendspin-display.js"
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
    "playerlib.js"
    "ren-config.php"
    "ren-config.html"
    "ssp-config.php"
    "ssp-config.html"
    "setup_3rdparty_sendspin.txt"
    "worker.php"
    "sendspin-spspre.sh"
    "sendspin-metadata.sh"
    "spspost.sh"
    "sendspin-version-check.sh"
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
    if [[ -f "${WWW_DIR}/js/playerlib.js" ]]; then
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

# Detect active PHP-FPM service name
detect_php_fpm() {
    local fpm_service
    fpm_service=$(systemctl list-units --type=service --state=active 2>/dev/null | grep -oP 'php\d+\.\d+-fpm\.service' | head -1)
    echo "${fpm_service:-php8.2-fpm.service}"
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

detect_playerlib_js() {
    [[ -f "${WWW_DIR}/js/playerlib.js" ]] && grep -q "FEAT_SENDSPIN" "${WWW_DIR}/js/playerlib.js" || 
    [[ -f "${WWW_DIR}/js/lib.min.js" ]] && grep -q "FEAT_SENDSPIN" "${WWW_DIR}/js/lib.min.js"
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

detect_ssp_config_php() {
    [[ -f "${WWW_DIR}/ssp-config.php" ]]
}

detect_ssp_config_html() {
    [[ -f "${WWW_DIR}/templates/ssp-config.html" ]]
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
        bitmask=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_system WHERE param='feat_bitmask';" 2>/dev/null | tr -d '\n' || echo "0")
        [[ $((bitmask & FEAT_SENDSPIN)) -ne 0 ]]
    else
        return 1
    fi
}

detect_worker_php() {
    [[ -f "${WWW_DIR}/daemon/worker.php" ]] && grep -q "sendspinsvc\\|sendspinrestart\\|startSendspin\\|stopSendspin" "${WWW_DIR}/daemon/worker.php"
}

detect_sendspin_spspre() {
    [[ -f "/var/local/www/commandw/sendspin-spspre.sh" ]]
}

detect_sendspin_metadata() {
    [[ -f "/var/local/www/commandw/sendspin-metadata.sh" ]]
}

detect_spspost() {
    [[ -f "/var/local/www/commandw/spspost.sh" ]]
}

detect_sendspin_version_check() {
    [[ -f "/var/local/www/commandw/sendspin-version-check.sh" ]]
}

detect_sendspin_metadata_sink() {
    [[ -f "/var/local/www/commandw/sendspin-metadata-sink.py" ]]
}

detect_sendspin_metadata_sink_service() {
    [[ -f "${SYSTEMD_DIR}/sendspin-metadata-sink.service" ]]
}

detect_sendspin_meta_php() {
    [[ -f "${WWW_DIR}/command/sendspin-meta.php" ]] && grep -q "sendspinmeta" "${WWW_DIR}/command/sendspin-meta.php"
}

detect_sendspin_display_js() {
    [[ -f "${WWW_DIR}/js/sendspin-display.js" ]]
}

detect_header_php_meta() {
    [[ -f "${WWW_DIR}/header.php" ]] && grep -q "sendspin-display.js" "${WWW_DIR}/header.php"
}

# ============================================================================
# CHECK / STATUS FUNCTION
# ============================================================================

check_installation() {
    log_section "SendSpin Installation Status"
    
    local installed_count=0
    local total_checks=19
    
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
    check_component "playerlib.js - FEAT_SENDSPIN constant" detect_playerlib_js
    check_component "ren-config.php - Feature handling" detect_ren_config_php
    check_component "ren-config.html - UI section" detect_ren_config_html
    check_component "setup_3rdparty_sendspin.txt - Documentation" detect_setup_txt
    check_component "worker.php - Job handlers" detect_worker_php
    check_component "sendspin.service - Systemd service" detect_systemd_service
    check_component "Database - Config entries" detect_database_entries
    check_component "feat_bitmask - Feature enabled" detect_feat_bitmask
    check_component "commandw/sendspin-spspre.sh - Pre-start hook" detect_sendspin_spspre
    check_component "commandw/sendspin-metadata.sh - Metadata hook" detect_sendspin_metadata
    check_component "commandw/spspost.sh - Post-stop hook" detect_spspost
    check_component "commandw/sendspin-version-check.sh - Version check" detect_sendspin_version_check
    check_component "command/sendspin-meta.php - Metadata endpoint" detect_sendspin_meta_php
    check_component "js/sendspin-display.js - Display JS" detect_sendspin_display_js
    check_component "header.php - JS include" detect_header_php_meta
    check_component "commandw/sendspin-metadata-sink.py - HA metadata sink" detect_sendspin_metadata_sink
    check_component "sendspin-metadata-sink.service - Systemd service" detect_sendspin_metadata_sink_service
    
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
    
    # Check/install system dependencies
    if ! dpkg -l libportaudio2 2>/dev/null | grep -q '^ii'; then
        log_info "  Installing libportaudio2 (audio library)..."
        apt-get update -qq && apt-get install -y -qq libportaudio2
    fi
    
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
    
    # Tune PHP-FPM pool for better responsiveness with SendSpin metadata polling
    local fpm_pool="/etc/php/$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo '8.2')/fpm/pool.d/www.conf"
    if [[ -f "$fpm_pool" ]]; then
        log_info "  Tuning PHP-FPM pool for responsiveness..."
        sed -i 's/^pm.start_servers = .*/pm.start_servers = 8/' "$fpm_pool" 2>/dev/null || true
        sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 4/' "$fpm_pool" 2>/dev/null || true
        sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 12/' "$fpm_pool" 2>/dev/null || true
        log_success "  PHP-FPM pool tuned (more idle children for responsiveness)"
    fi
    
    record_install "prerequisites"
    log_success "Prerequisites installed"
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
ExecStart=/root/.local/share/uv/tools/sendspin/bin/sendspin daemon --audio-device _audioout --audio-format flac:48000:16:2 --name moode-sendspin
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
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('sendspin_mpd_was_playing', '0');
CREATE TABLE IF NOT EXISTS cfg_sendspin (id INTEGER PRIMARY KEY, param CHAR (32), value CHAR (128));
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_codec', 'flac');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_rate', '48000');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_depth', '16');
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
    sed -i '/const FEAT_PEPPYDISPLAY/a const FEAT_SENDSPIN      = 262144;' "$target" 2>/dev/null || true
    
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
	
	// Persist in database (survives PHP-FPM restarts)
	$dbh = sqlConnect();
	sqlUpdate('cfg_system', $dbh, 'sendspin_mpd_was_playing', $mpdWasPlaying ? '1' : '0');
	
	// Also write to session for immediate access
	phpSession('write', 'mpd_was_playing', $mpdWasPlaying ? '1' : '0');

	// Stop MPD to release ALSA device
	sysCmd('mpc stop');

	// Start SendSpin daemon
	sysCmd('systemctl start sendspin');
	sysCmd('systemctl enable sendspin');

	// Set active state
	phpSession('write', 'sspactive', '1');
	$GLOBALS['sspactive'] = '1';
	sendFECmd('sspactive1');

	workerLog('startSendspin(): daemon started (MPD was playing: ' . ($mpdWasPlaying ? 'yes' : 'no') . ')');
}

function stopSendspin() {
	// Stop SendSpin daemon
	sysCmd('systemctl stop sendspin');
	sysCmd('systemctl disable sendspin');

	// Optionally resume MPD if it was playing AND rsmafterss is enabled
	$dbh = sqlConnect();
	$result = sqlQuery("SELECT value FROM cfg_system WHERE param='rsmafterss'", $dbh);
	$rsmafterss = (!empty($result)) ? $result[0]['value'] : 'No';
	
	$mpdWasPlaying = $_SESSION['mpd_was_playing'] ?? '0';
	// Also check database as fallback
	if ($mpdWasPlaying == '0') {
		$result = sqlQuery("SELECT value FROM cfg_system WHERE param='sendspin_mpd_was_playing'", $dbh);
		$mpdWasPlaying = (!empty($result)) ? $result[0]['value'] : '0';
	}

	if ($mpdWasPlaying == '1' && $rsmafterss == 'Yes') {
		sleep(1); // Allow SendSpin to release device
		sysCmd('mpc play');
		phpSession('write', 'mpd_was_playing', '0');
		sqlUpdate('cfg_system', $dbh, 'sendspin_mpd_was_playing', '0');
		workerLog('stopSendspin(): MPD playback resumed (rsmafterss=Yes)');
	} elseif ($mpdWasPlaying == '1') {
		// Clear the flag even if not resuming
		phpSession('write', 'mpd_was_playing', '0');
		sqlUpdate('cfg_system', $dbh, 'sendspin_mpd_was_playing', '0');
		workerLog('stopSendspin(): MPD was playing but rsmafterss=No, not resuming');
	}

	workerLog('stopSendspin(): daemon stopped');

	// Local: restore volume knob
	sysCmd('/var/www/util/vol.sh -restore');
	if (CamillaDSP::isMPD2CamillaDSPVolSyncEnabled()) {
		sysCmd('systemctl restart mpd2cdspvolume');
	}

	// Clear active state
	phpSession('write', 'sspactive', '0');
	$GLOBALS['sspactive'] = '0';
	sendFECmd('sspactive0');
}

// === SendSpin Advanced Functions ===

function getSendspinVersion() {
    $result = sysCmd('sudo /root/.local/share/uv/tools/sendspin/bin/sendspin --version 2>/dev/null');
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
    sysCmd('sudo -u root bash -c \"/root/.local/share/uv/tools/sendspin/bin/python -m uv tool upgrade sendspin 2>&1 && systemctl restart sendspin\" > /tmp/sendspin-update.log 2>&1 &');
    workerLog('updateSendspin(): upgrade launched in background');
    return true;
}

function generateSendspinService($dbh = null) {
    if ($dbh === null) {
        $dbh = sqlConnect();
    }
    $result = sqlRead('cfg_sendspin', $dbh);
    $cfg = array();
    foreach ($result as $row) {
        $cfg[$row['param']] = $row['value'];
    }

    $codec = in_array($cfg['audio_codec'] ?? '', ['flac', 'pcm']) ? $cfg['audio_codec'] : 'flac';
    $rate = in_array($cfg['audio_rate'] ?? '', ['44100', '48000', '96000']) ? $cfg['audio_rate'] : '48000';
    $depth = in_array($cfg['audio_depth'] ?? '', ['16', '24', '32']) ? $cfg['audio_depth'] : '16';
    $log_level = in_array($cfg['log_level'] ?? '', ['DEBUG', 'INFO', 'WARNING', 'ERROR']) ? $cfg['log_level'] : 'INFO';

    $audio_format = \"{$codec}:{$rate}:{$depth}:2\";

    $service = <<<SVC
[Unit]
Description=SendSpin Audio Receiver
After=network-online.target sound.target avahi-daemon.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/var/local/www/commandw/sendspin-spspre.sh
ExecStart=/root/.local/share/uv/tools/sendspin/bin/sendspin daemon --audio-device _audioout --audio-format {$audio_format} --name moode-sendspin \\
    --log-level {$log_level} \\
    --hook-start /var/local/www/commandw/sendspin-metadata.sh \\
    --hook-stop /var/local/www/commandw/sendspin-metadata.sh
ExecStopPost=/var/local/www/commandw/spspost.sh
Restart=on-failure
RestartSec=5
TimeoutStartSec=30
Environment=\"HOME=/root\"

LimitRTPRIO=99
LimitMEMLOCK=8388608

[Install]
WantedBy=multi-user.target
SVC;

    $file = '/etc/systemd/system/sendspin.service';
    $tmpfile = '/tmp/sendspin.service.tmp';
    $result = file_put_contents($tmpfile, $service);
    if ($result !== false) {
        chmod($tmpfile, 0644);
        sysCmd(\"sudo cp {$tmpfile} {$file}\");
        sysCmd('sudo systemctl daemon-reload');
        @unlink($tmpfile);

        workerLog('generateSendspinService(): service regenerated from DB config');
        return true;
    }
    workerLog('generateSendspinService(): failed to write temp service file');
    return false;
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

install_playerlib_js() {
    log_info "Updating JS feature flags..."
    
    # Detect which JS file moOde uses (playerlib.js in newer, lib.min.js in older)
    local target
    if [[ -f "${WWW_DIR}/js/playerlib.js" ]]; then
        target="${WWW_DIR}/js/playerlib.js"
    elif [[ -f "${WWW_DIR}/js/lib.min.js" ]]; then
        target="${WWW_DIR}/js/lib.min.js"
    else
        log_error "Could not find playerlib.js or lib.min.js"
        return 1
    fi
    local js_name=$(basename "$target")
    
    if grep -q "FEAT_SENDSPIN" "$target"; then
        log_warn "FEAT_SENDSPIN already exists in ${js_name}"
        return 0
    fi
    
    backup_file "$target" "$js_name"
    
    # Add FEAT_SENDSPIN after FEAT_PEPPYDISPLAY
    sed -i "/FEAT_PEPPYDISPLAY/a const FEAT_SENDSPIN      = 262144; // x SendSpin multi-room audio" "$target" 2>/dev/null || true
    
    if grep -q "FEAT_SENDSPIN" "$target"; then
        record_install "playerlib_js"
        log_success "${js_name} updated"
    else
        log_error "Failed to update ${js_name}"
        return 1
    fi
}

install_worker_php() {
    log_info "Updating worker.php..."
    
    local target="${WWW_DIR}/daemon/worker.php"
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
    
    # ------------------------------------------------------------------
    # Step 1: Insert the POST handler block BEFORE phpSession('close')
    # This is critical - handlers must run while the session is still open
    # so that phpSession('close') writes the updated session to disk.
    # ------------------------------------------------------------------
    
    local close_line=$(grep -n "phpSession('close')" "$target" | head -1 | cut -d: -f1)
    
    if [[ -z "$close_line" ]]; then
        log_error "Could not find phpSession('close') in ren-config.php"
        return 1
    fi
    
    # Insert POST handler before the blank line before phpSession('close')
    local insert_line=$((close_line - 1))
    
    head -n $((insert_line - 1)) "$target" > /tmp/ren-config-new.php
    
    cat >> /tmp/ren-config-new.php << 'EOF'
// SendSpin Multi-Room Audio POST handler
if (isset($_POST['update_sendspin_settings'])) {
    if (isset($_POST['sendspinsvc']) && $_POST['sendspinsvc'] != $_SESSION['sendspinsvc']) {
        $update = true;
        phpSession('write', 'sendspinsvc', $_POST['sendspinsvc']);
    }
    if (isset($_POST['sendspinname']) && $_POST['sendspinname'] != $_SESSION['sendspinname']) {
        $update = true;
        phpSession('write', 'sendspinname', $_POST['sendspinname']);
    }
    if (isset($_POST['rsmafterss']) && $_POST['rsmafterss'] != $_SESSION['rsmafterss']) {
        $update = true;
        phpSession('write', 'rsmafterss', $_POST['rsmafterss']);
    }
    if (isset($update)) {
        // Worker handles service regeneration + start/stop via submitJob
        submitJob('sendspinsvc');
    }
}
if (isset($_POST['sendspinrestart']) && $_POST['sendspinrestart'] == 1 && $_SESSION['sendspinsvc'] == '1') {
    submitJob('sendspinrestart', '', NOTIFY_TITLE_INFO, 'SendSpin' . NOTIFY_MSG_SVC_MANUAL_RESTART);
}

EOF
    
    tail -n +$insert_line "$target" >> /tmp/ren-config-new.php
    mv /tmp/ren-config-new.php "$target"
    
    # ------------------------------------------------------------------
    # Step 2: Insert the rendering block BEFORE waitWorker('ren-config')
    # This generates the feature display and toggle controls.
    # ------------------------------------------------------------------
    
    local wait_line=$(grep -n "waitWorker('ren-config')" "$target" | head -1 | cut -d: -f1)
    
    if [[ -z "$wait_line" ]]; then
        log_error "Could not find waitWorker in ren-config.php"
        return 1
    fi
    
    head -n $((wait_line - 1)) "$target" > /tmp/ren-config-new.php
    
    cat >> /tmp/ren-config-new.php << 'EOF'
if (($_SESSION['feat_bitmask'] & FEAT_SENDSPIN)) {
    $_feat_sendspin = '';
    $_SESSION['sendspin_installed'] == 'yes' ? $_sendspin_svcbtn_disable = '' : $_sendspin_svcbtn_disable = 'disabled';
    $_SESSION['sendspinsvc'] == '1' ? $_sendspin_btn_disable = '' : $_sendspin_btn_disable = 'disabled';
    $_SESSION['sendspinsvc'] == '1' ? $_sendspin_link_disable = '' : $_sendspin_link_disable = 'onclick="return false;"';
    $autoClick = " onchange=\"autoClick('#btn-set-sendspinsvc');\"";
    $_select['sendspinsvc_on']  = "<input type=\"radio\" name=\"sendspinsvc\" id=\"toggle-sendspinsvc-1\" value=\"1\" " . (($_SESSION['sendspinsvc'] == '1') ? "checked=\"checked\"" : "") . $_sendspin_svcbtn_disable . $autoClick . ">\n";
    $_select['sendspinsvc_off'] = "<input type=\"radio\" name=\"sendspinsvc\" id=\"toggle-sendspinsvc-2\" value=\"0\" " . (($_SESSION['sendspinsvc'] == '0') ? "checked=\"checked\"" : "") . $_sendspin_svcbtn_disable . $autoClick . ">\n";
    $_select["sendspinname"] = $_SESSION["sendspinname"];
} else {
    $_feat_sendspin = 'hide';
}


EOF
    
    tail -n +$wait_line "$target" >> /tmp/ren-config-new.php
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
				<a href="ssp-config.php" $_sendspin_link_disable><button class="btn btn-medium btn-primary config-btn" $_sendspin_btn_disable>Edit</button></a>
				<span class="config-btn-after">SendSpin</span>
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

# ============================================================================
# INSTALLATION FUNCTIONS - SendSpin Settings Page (ssp-config)
# ============================================================================

install_ssp_config_php() {
    log_info "Deploying ssp-config.php..."
    
    local target="${WWW_DIR}/ssp-config.php"
    
    if detect_ssp_config_php; then
        log_warn "ssp-config.php already exists"
        return 0
    fi
    
    if download_from_github "www/ssp-config.php" "$target"; then
        chown www-data:www-data "$target"
        if verify_php_syntax "$target"; then
            record_install "ssp_config_php"
            log_success "ssp-config.php deployed"
        else
            log_error "PHP syntax check failed for ssp-config.php"
            return 1
        fi
    else
        log_error "Failed to download ssp-config.php"
        return 1
    fi
}

install_ssp_config_html() {
    log_info "Deploying ssp-config.html..."
    
    local target="${WWW_DIR}/templates/ssp-config.html"
    
    if detect_ssp_config_html; then
        log_warn "ssp-config.html already exists"
        return 0
    fi
    
    if download_from_github "www/templates/ssp-config.html" "$target"; then
        chown www-data:www-data "$target"
        record_install "ssp_config_html"
        log_success "ssp-config.html deployed"
    else
        log_error "Failed to download ssp-config.html"
        return 1
    fi
}

install_ssp_config() {
    install_ssp_config_php || return 1
    install_ssp_config_html || return 1
}

install_commandw_scripts() {
    log_info "Deploying SendSpin commandw scripts..."
    
    local cmdw_dir="/var/local/www/commandw"
    mkdir -p "$cmdw_dir"
    
    local scripts=(
        "sendspin-spspre.sh"
        "sendspin-metadata.sh"
        "spspost.sh"
        "sendspin-version-check.sh"
    )
    
    local all_ok=true
    for script in "${scripts[@]}"; do
        local target="${cmdw_dir}/${script}"
        if [[ -f "$target" ]]; then
            log_warn "${script} already exists"
            continue
        fi
        
        if download_from_github "www/commandw/${script}" "$target"; then
            chmod 755 "$target"
            chown www-data:www-data "$target"
            log_success "${script} deployed"
        else
            log_error "Failed to download ${script}"
            all_ok=false
        fi
    done
    
    $all_ok
}

install_sendspin_meta_php() {
    log_info "Deploying SendSpin metadata endpoint..."
    
    local target="${WWW_DIR}/command/sendspin-meta.php"
    
    if detect_sendspin_meta_php; then
        log_warn "sendspin-meta.php already exists"
        return 0
    fi
    
    if download_from_github "www/command/sendspin-meta.php" "$target"; then
        chmod 644 "$target"
        chown www-data:www-data "$target"
        record_install "sendspin_meta_php"
        log_success "sendspin-meta.php deployed"
    else
        log_error "Failed to download sendspin-meta.php"
        return 1
    fi
}

install_sendspin_display_js() {
    log_info "Deploying SendSpin display JS..."
    
    local target="${WWW_DIR}/js/sendspin-display.js"
    
    if detect_sendspin_display_js; then
        log_warn "sendspin-display.js already exists"
        return 0
    fi
    
    if download_from_github "www/js/sendspin-display.js" "$target"; then
        chmod 644 "$target"
        chown www-data:www-data "$target"
        record_install "sendspin_display_js"
        log_success "sendspin-display.js deployed"
    else
        log_error "Failed to download sendspin-display.js"
        return 1
    fi
}

install_header_php_meta() {
    log_info "Adding SendSpin JS to header.php..."
    
    local target="${WWW_DIR}/header.php"
    
    if detect_header_php_meta; then
        log_warn "sendspin-display.js already in header.php"
        return 0
    fi
    
    backup_file "$target" "header.php"
    
    # Add script tag before closing </head> tag
    sed -i '/<\/head>/i \    <script src=\"js/sendspin-display.js\" defer></script>' "$target" 2>/dev/null || true
    
    if grep -q "sendspin-display.js" "$target"; then
        record_install "header_php_meta"
        log_success "header.php updated with SendSpin JS"
    else
        log_error "Failed to update header.php"
        return 1
    fi
}

install_sendspin_metadata_sink() {
    log_info "Deploying SendSpin metadata sink daemon..."
    
    local target="/var/local/www/commandw/sendspin-metadata-sink.py"
    
    if detect_sendspin_metadata_sink; then
        log_warn "sendspin-metadata-sink.py already exists"
        return 0
    fi
    
    if download_from_github "www/commandw/sendspin-metadata-sink.py" "$target"; then
        chmod 755 "$target"
        chown www-data:www-data "$target"
        record_install "sendspin_metadata_sink"
        log_success "sendspin-metadata-sink.py deployed"
    else
        log_error "Failed to download sendspin-metadata-sink.py"
        return 1
    fi
}

install_sendspin_metadata_sink_service() {
    log_info "Installing SendSpin metadata sink systemd service..."
    
    local target="${SYSTEMD_DIR}/sendspin-metadata-sink.service"
    
    if detect_sendspin_metadata_sink_service; then
        log_warn "sendspin-metadata-sink.service already exists"
        return 0
    fi
    
    cat > "$target" << 'SINKEOF'
[Unit]
Description=SendSpin Metadata Sink for moOde
After=network-online.target sendspin.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/root/.local/share/uv/tools/sendspin/bin/python /var/local/www/commandw/sendspin-metadata-sink.py
Restart=on-failure
RestartSec=10
Environment="HOME=/root"
Environment="MA_URL=http://192.168.214.159:8095"
Environment="MA_TOKEN="

[Install]
WantedBy=multi-user.target
SINKEOF
    
    chmod 644 "$target"
    systemctl daemon-reload
    record_install "sendspin_metadata_sink_service"
    log_success "sendspin-metadata-sink.service installed"
    log_info "  Configured MA_URL=${MA_URL:-http://192.168.214.30:8095}. Edit $target to change."
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
#  Version: 2.1 (2026-06-29)
#
################################################################################

OVERVIEW

SendSpin is a synchronized multi-room audio protocol. This integration adds
SendSpin as a first-class renderer in moOde's web UI, allowing your Raspberry Pi
to act as an audio endpoint in multi-room systems (Music Assistant, etc.).

The installer handles everything automatically  --  it installs Python 3, uv
(Python package manager), and the sendspin CLI, then patches moOde's web
interface, creates the systemd service, configures the database, and creates
a backup of all modified files.

REQUIREMENTS

- moOde 9.x or later running on a Raspberry Pi 3, 4, or 5
- Network connection to a SendSpin server (e.g., Music Assistant)
- Home Assistant (optional, for now-playing metadata display)

No manual installation of Python, uv, or the sendspin CLI is required  -- 
the installer handles all prerequisites automatically.

INSTALLATION

Full install (all features):

    git clone https://github.com/kiwipaulrob/moode.git
    cd moode && git checkout sendspin-advanced
    sudo bash moode-sendspin-installer.sh

Or install directly from URL:

    curl -fsSL https://raw.githubusercontent.com/kiwipaulrob/moode/sendspin-advanced/moode-sendspin-installer.sh | sudo bash

INSTALLER COMMAND LINE OPTIONS

    sudo bash moode-sendspin-installer.sh           Full install (default)
    sudo bash moode-sendspin-installer.sh --minimal Endpoint only (ON/OFF + Resume MPD, no config page)
    sudo bash moode-sendspin-installer.sh --check   Check installation status
    sudo bash moode-sendspin-installer.sh --uninstall  Remove SendSpin, restore originals
    sudo bash moode-sendspin-installer.sh --no-backup   Skip backup creation
    sudo bash moode-sendspin-installer.sh --help    Show help

USAGE

After installation, open moOde's web UI and navigate to:
  Configure -> Renderers -> SendSpin section

RENDERER CONTROLS

Service toggle (ON/OFF):
    ON   --  SendSpin is active and appears as an available endpoint in controllers
    OFF  --  SendSpin is stopped and does not appear in controllers
    Changes take effect immediately on save.

Name:
    The name that appears in your multi-room audio controller.
    Default: "moode-sendspin"
    Change this to identify your device (e.g., "Kitchen Speaker", "Living Room").

Resume MPD:
    ON   --  MPD playback resumes automatically when SendSpin streaming stops
    OFF  --  MPD remains stopped after SendSpin disconnects

Restart button:
    Restarts the SendSpin service. Use this if the device disappears from
    the controller or audio stops working.

Edit button:
    Opens the SendSpin configuration page (ssp-config.php) with these settings:

    Audio format:
        Codec:       FLAC (lossless, recommended) or PCM (uncompressed)
        Sample rate: 44100, 48000 (default), or 96000 Hz
        Bit depth:   16 (CD quality), 24, or 32 bit
        Changes take effect on next service restart.

    Log level:
        DEBUG (troubleshooting), INFO (normal), WARNING, or ERROR (minimal)
        Controls verbosity of the SendSpin daemon log.

    Version:
        Shows installed and latest available SendSpin CLI version.
        If an update is available, an Update button appears to upgrade
        the CLI in the background via uv.

CONFIGURATION OPTIONS (SSP-CONFIG PAGE)

The Edit button opens a dedicated configuration page with settings for
audio codec, sample rate, bit depth, and log level. All settings are
validated and saved to the database. The SendSpin systemd service file
is regenerated automatically on save.

VOLUME LEVEL

SendSpin uses moOde's standard _audioout ALSA device, the same device used
by AirPlay, Spotify, RoonBridge, and MPD. Volume is controlled by moOde's
integrated volume knob  --  SendSpin matches the level of all other renderers
automatically. No manual attenuation adjustment is needed.

MOODE UPDATES

Re-run the installer after a moOde system update:

    cd moode && git pull && sudo bash moode-sendspin-installer.sh

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

    4. Check that the _audioout ALSA device is available:
       aplay -L | grep _audioout

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

    1. Check that Resume MPD is enabled in the SendSpin section of Renderers
    2. Verify MPD was playing before SendSpin started
    3. Check moOde logs: sudo tail -f /var/log/moode.log

COMMAND REFERENCE

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

    # Check that _audioout is available
    aplay -L | grep _audioout

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
INSERT OR REPLACE INTO cfg_system (param, value) VALUES ('sendspin_mpd_was_playing', '0');
CREATE TABLE IF NOT EXISTS cfg_sendspin (id INTEGER PRIMARY KEY, param CHAR (32), value CHAR (128));
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_codec', 'flac');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_rate', '48000');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('audio_depth', '16');
INSERT OR IGNORE INTO cfg_sendspin (param, value) VALUES ('log_level', 'INFO');
EOF
    
    # Update feat_bitmask
    local current_bitmask
    current_bitmask=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_system WHERE param='feat_bitmask';" 2>/dev/null | tr -d '\n' || echo "0")
    local new_bitmask=$((current_bitmask | 262144))
    sqlite3 "$DB_PATH" "UPDATE cfg_system SET value='${new_bitmask}' WHERE param='feat_bitmask';"
    
    record_install "database_full"
    log_success "Database configured (full)"
}

# ============================================================================
# SERVICE FILE REGENERATION
# ============================================================================

install_regenerate_service() {
    log_info "Regenerating service file from DB defaults..."
    local service_file="/etc/systemd/system/sendspin.service"
    
    # Get audio config from DB with defaults
    local codec rate depth log_level
    codec=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_sendspin WHERE param='audio_codec';" 2>/dev/null || echo "flac")
    rate=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_sendspin WHERE param='audio_rate';" 2>/dev/null || echo "48000")
    depth=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_sendspin WHERE param='audio_depth';" 2>/dev/null || echo "16")
    log_level=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_sendspin WHERE param='log_level';" 2>/dev/null || echo "INFO")
    
    # Validate
    [[ "$codec" =~ ^(flac|pcm)$ ]] || codec="flac"
    [[ "$rate" =~ ^(44100|48000|96000)$ ]] || rate="48000"
    [[ "$depth" =~ ^(16|24|32)$ ]] || depth="16"
    [[ "$log_level" =~ ^(DEBUG|INFO|WARNING|ERROR)$ ]] || log_level="INFO"
    
    local audio_format="${codec}:${rate}:${depth}:2"
    
    cat > "$service_file" << SVCEOF
[Unit]
Description=SendSpin Audio Receiver
After=network-online.target sound.target avahi-daemon.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/var/local/www/commandw/sendspin-spspre.sh
ExecStart=/root/.local/share/uv/tools/sendspin/bin/sendspin daemon --audio-device _audioout --audio-format ${audio_format} --name moode-sendspin \\
    --log-level ${log_level} \\
    --hook-start /var/local/www/commandw/sendspin-metadata.sh \\
    --hook-stop /var/local/www/commandw/sendspin-metadata.sh
ExecStopPost=/var/local/www/commandw/spspost.sh
Restart=on-failure
RestartSec=5
TimeoutStartSec=30
Environment="HOME=/root"

LimitRTPRIO=99
LimitMEMLOCK=8388608

[Install]
WantedBy=multi-user.target
SVCEOF
    
    chmod 644 "$service_file"
    systemctl daemon-reload
    log_success "Service file regenerated from DB defaults"
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
    if [[ "$FORCE" != "true" ]]; then
        echo ""
        read -r -p "Type 'yes' to uninstall, or 'no' to exit: " REPLY
        echo ""
        if [[ ! "$REPLY" =~ ^[Yy]([Ee][Ss])?$ ]]; then
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
        
        # Restore playerlib.js
        if [[ -f "${backup_dir}/playerlib.js" ]]; then
            cp "${backup_dir}/playerlib.js" "${WWW_DIR}/js/playerlib.js"
            log_success "Restored playerlib.js"
        else
            sed -i '/FEAT_SENDSPIN/d' "${WWW_DIR}/js/playerlib.js" 2>/dev/null || true
                sed -i '/FEAT_SENDSPIN/d' "${WWW_DIR}/js/lib.min.js" 2>/dev/null || true
        fi
        
        # Restore worker.php
        if [[ -f "${backup_dir}/worker.php" ]]; then
            cp "${backup_dir}/worker.php" "${WWW_DIR}/daemon/worker.php"
            chown www-data:www-data "${WWW_DIR}/daemon/worker.php"
            log_success "Restored worker.php"
        else
            # Remove SendSpin startup and job handlers
            sed -i '/\/\/ SendSpin startup/,/^\t\}$/d' "${WWW_DIR}/daemon/worker.php" 2>/dev/null || true
            sed -i "/case 'sendspinsvc':/,/break;/d" "${WWW_DIR}/daemon/worker.php" 2>/dev/null || true
            sed -i "/case 'sendspinrestart':/,/break;/d" "${WWW_DIR}/daemon/worker.php" 2>/dev/null || true
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
        
        # Remove ssp-config page
                        rm -f "${WWW_DIR}/ssp-config.php"
                        rm -f "${WWW_DIR}/templates/ssp-config.html"
                        log_success "Removed ssp-config page"
        
                        # Remove commandw scripts
                        rm -f "/var/local/www/commandw/sendspin-spspre.sh"
                        rm -f "/var/local/www/commandw/sendspin-metadata.sh"
                        rm -f "/var/local/www/commandw/spspost.sh"
                        rm -f "/var/local/www/commandw/sendspin-version-check.sh"
                        rmdir "/var/local/www/commandw" 2>/dev/null || true
                        log_success "Removed commandw scripts"
        
                    # Remove database entries
                    if [[ -f "$DB_PATH" ]]; then
                        log_info "Removing database entries..."
                        sqlite3 "$DB_PATH" "DELETE FROM cfg_system WHERE param LIKE 'sendspin%';" 2>/dev/null || true
                        sqlite3 "$DB_PATH" "DROP TABLE IF EXISTS cfg_sendspin;" 2>/dev/null || true
        
                        # Remove feat_bitmask bit
                        local current_bitmask
                        current_bitmask=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_system WHERE param='feat_bitmask';" 2>/dev/null | tr -d '\n' || echo "0")
                        local new_bitmask=$((current_bitmask & ~262144))
                        sqlite3 "$DB_PATH" "UPDATE cfg_system SET value='${new_bitmask}' WHERE param='feat_bitmask';" 2>/dev/null || true
                        log_success "Database cleaned"
                    fi
                else
                    log_warn "No backup found! Attempting manual cleanup..."
    
            # Manual cleanup attempts
            sed -i '/FEAT_SENDSPIN/d' "${INC_DIR}/constants.php" 2>/dev/null || true
            sed -i '/SendSpin Multi-Room Audio/,/^}/d' "${INC_DIR}/renderer.php" 2>/dev/null || true
            sed -i '/FEAT_SENDSPIN/d' "${WWW_DIR}/js/playerlib.js" 2>/dev/null || true
                sed -i '/FEAT_SENDSPIN/d' "${WWW_DIR}/js/lib.min.js" 2>/dev/null || true
            sed -i '/\/\/ SendSpin/,/^}$/d' "${WWW_DIR}/ren-config.php" 2>/dev/null || true
            sed -i '/_feat_sendspin/d' "${WWW_DIR}/ren-config.php" 2>/dev/null || true
            sed -i '/_feat_sendspin/,/\/div>/d' "${WWW_DIR}/templates/ren-config.html" 2>/dev/null || true
            sed -i '/\/\/ SendSpin startup/,/^\t\}$/d' "${WWW_DIR}/daemon/worker.php" 2>/dev/null || true
            sed -i "/case 'sendspinsvc':/,/break;/d" "${WWW_DIR}/daemon/worker.php" 2>/dev/null || true
            sed -i "/case 'sendspinrestart':/,/break;/d" "${WWW_DIR}/daemon/worker.php" 2>/dev/null || true
            rm -f "${WWW_DIR}/setup_3rdparty_sendspin.txt"
            rm -f "${WWW_DIR}/ssp-config.php"
            rm -f "${WWW_DIR}/templates/ssp-config.html"
            # Remove commandw scripts
            rm -f "/var/local/www/commandw/sendspin-spspre.sh"
            rm -f "/var/local/www/commandw/sendspin-metadata.sh"
            rm -f "/var/local/www/commandw/spspost.sh"
            rm -f "/var/local/www/commandw/sendspin-version-check.sh"
            rmdir "/var/local/www/commandw" 2>/dev/null || true
    
            # Remove database entries
            if [[ -f "$DB_PATH" ]]; then
                log_info "Removing database entries..."
                sqlite3 "$DB_PATH" "DELETE FROM cfg_system WHERE param LIKE 'sendspin%';" 2>/dev/null || true
                sqlite3 "$DB_PATH" "DROP TABLE IF EXISTS cfg_sendspin;" 2>/dev/null || true
        
                # Remove feat_bitmask bit
                local current_bitmask
                current_bitmask=$(sqlite3 "$DB_PATH" "SELECT value FROM cfg_system WHERE param='feat_bitmask';" 2>/dev/null | tr -d '\n' || echo "0")
                local new_bitmask=$((current_bitmask & ~262144))
                sqlite3 "$DB_PATH" "UPDATE cfg_system SET value='${new_bitmask}' WHERE param='feat_bitmask';" 2>/dev/null || true
                log_success "Database cleaned"
            fi
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
    
    if detect_playerlib_js; then
        log_warn "Traces found in playerlib.js"
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
    
    if detect_ssp_config_php; then
        log_warn "Traces found in ssp-config.php"
        found_traces=true
    fi
    
    if detect_ssp_config_html; then
        log_warn "Traces found in ssp-config.html"
        found_traces=true
    fi
    
    if detect_sendspin_spspre; then
        log_warn "Traces found in sendspin-spspre.sh"
        found_traces=true
    fi
    
    if detect_sendspin_metadata; then
        log_warn "Traces found in sendspin-metadata.sh"
        found_traces=true
    fi
    
    if detect_spspost; then
        log_warn "Traces found in spspost.sh"
        found_traces=true
    fi
    
    if detect_sendspin_version_check; then
        log_warn "Traces found in sendspin-version-check.sh"
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
    echo "  sudo systemctl restart $(detect_php_fpm)"
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
        log_info "Installation check complete - all 14 components are present and verified."
        echo ""
        log_info "If you are still experiencing issues with SendSpin, reinstalling"
        log_info "will overwrite all components with fresh copies from the installer."
        echo ""
        if [[ "$FORCE" != "true" ]]; then
            read -r -p "Type 'yes' to reinstall, or 'no' to exit: " REPLY
            echo ""
            if [[ ! "$REPLY" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                echo ""
                log_info "Reinstallation skipped."
                log_info "If you continue having issues:"
                log_info "  - Run with --check to verify individual component status"
                log_info "  - Run with --uninstall for a clean removal before reinstalling"
                log_info "  - Check SendSpin service logs: journalctl -u sendspin"
                log_info "  - See README-sendspin.md for troubleshooting"
                echo ""
                exit 0
            fi
        else
            echo ""
            log_info "Skipping confirmation prompt (--force specified)"
        fi
        log_info "Proceeding with reinstallation..."
    elif [[ $install_status -eq 2 ]]; then
        echo ""
        log_warn "Partial installation detected (not all 14 components found)."
        log_warn "Continuing may cause issues if previous installation is incomplete."
        echo ""
        read -r -p "Type 'yes' to continue, or 'no' to exit: " REPLY
        echo ""
        if [[ ! "$REPLY" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            echo ""
            log_info "Installation cancelled."
            log_info "Run with --uninstall first for a clean removal, then reinstall."
            echo ""
            exit 0
        fi
    fi
    
    # Initialize backup
    init_backup
    
    echo ""
    log_section "Starting Installation"
    
    # Enable strict error handling for installation phase
    set -e
    
    # Install prerequisites (Python, uv, sendspin CLI)
    install_prerequisites
    
    # Install based on mode
    if [[ "$INSTALL_MODE" == "minimal" ]]; then
        install_systemd_service
        install_database_entries_minimal
    else
        install_systemd_service
        install_constants_php
        install_renderer_php
        install_playerlib_js
        install_worker_php
        install_ren_config_php
        install_ren_config_html
        install_ssp_config
        install_commandw_scripts
        install_sendspin_meta_php
        install_sendspin_display_js
        install_header_php_meta
        install_sendspin_metadata_sink
        install_sendspin_metadata_sink_service
        install_setup_txt
        install_database_entries_full
    fi
    
    log_section "Post-Installation Verification"
    
    # Verify installation
    local verify_passed=true
    
    if [[ "$INSTALL_MODE" == "full" ]]; then
        detect_constants_php || { log_error "constants.php verification failed"; verify_passed=false; }
        detect_renderer_php || { log_error "renderer.php verification failed"; verify_passed=false; }
        detect_playerlib_js || { log_error "playerlib.js verification failed"; verify_passed=false; }
        detect_worker_php || { log_error "worker.php verification failed"; verify_passed=false; }
        detect_ren_config_php || { log_error "ren-config.php verification failed"; verify_passed=false; }
        detect_ren_config_html || { log_error "ren-config.html verification failed"; verify_passed=false; }
        detect_ssp_config_php || { log_error "ssp-config.php verification failed"; verify_passed=false; }
        detect_ssp_config_html || { log_error "ssp-config.html verification failed"; verify_passed=false; }
        detect_sendspin_spspre || { log_error "sendspin-spspre.sh verification failed"; verify_passed=false; }
        detect_sendspin_metadata || { log_error "sendspin-metadata.sh verification failed"; verify_passed=false; }
        detect_spspost || { log_error "spspost.sh verification failed"; verify_passed=false; }
        detect_sendspin_version_check || { log_error "sendspin-version-check.sh verification failed"; verify_passed=false; }
        detect_sendspin_meta_php || { log_error "sendspin-meta.php verification failed"; verify_passed=false; }
        detect_sendspin_display_js || { log_error "sendspin-display.js verification failed"; verify_passed=false; }
        detect_header_php_meta || { log_warn "header.php JS include may be missing"; }
        detect_sendspin_metadata_sink || { log_warn "sendspin-metadata-sink.py not deployed (HA metadata requires it)"; }
        detect_sendspin_metadata_sink_service || { log_warn "sendspin-metadata-sink.service not installed"; }
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
        echo ""
        echo "============================================================================="
        echo "  INSTALLATION COMPLETE"
        echo "============================================================================="
        echo ""
        echo "  Files installed but SendSpin service is NOT running yet."
        echo ""
        echo "  To activate:"
        echo "    1. Restart PHP:  sudo systemctl restart $(detect_php_fpm)"
        echo "    2. Open moOde web UI → Configure → Renderers"
        echo "    3. Find the \"SendSpin\" section"
        echo "    4. Toggle Service to ON and click the save arrow"
        echo "    5. Your device appears in Music Assistant (etc.) as \"moode-sendspin\""
        echo "       (change the Name field to customise the label)"
        echo ""
        echo "  Optional: Click Edit to configure audio format, log level,"
        echo "  and check for sendspin CLI updates."
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
    echo "  Force Install:    curl -fsSL ... | sudo bash -s -- --force"
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
    echo "  --force            Skip all confirmation prompts (install and uninstall)"
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
            FORCE=true
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