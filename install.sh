#!/bin/bash
# =============================================================================
#  DOS DESKTOP ENVIRONMENT — INSTALL SCRIPT  v8
#  Custom Debian distro base | XLibre X Server | i3-wm | dosemu2
#  Target: Debian Trixie (13) — headless VM or bare metal
#
#  Usage:  sudo bash install.sh
#
#  v8: Complete install with power menu and improved UX
#    - Downloads FreeDOS base packages from ibiblio.org
#    - Downloads essential utilities from archive.org
#    - Creates working C: drive with bootable FreeDOS
#    - Desktop button to fetch more DOS apps from repos
#    - Power Menu for Shutdown/Reboot/Log Out (NEW!)
#    - Larger fonts for better readability (NEW!)
#
#  IDEMPOTENT: Safe to run multiple times.
#  Completed phases are recorded in /var/lib/dos-desktop-install.state
#  and skipped on re-run. To force a full reinstall:
#    rm /var/lib/dos-desktop-install.state && sudo bash install.sh
#
#  Display server: XLibre (https://xlibre-deb.github.io/debian)
#  Wayland:        NEVER installed or used.
# =============================================================================

# No set -e: each phase handles its own errors so one failure doesn't abort.
set -uo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YLW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
hdr()  { echo -e "\n${BLD}${CYN}══════ $1 ══════${NC}"; }

[[ $EUID -ne 0 ]] && err "Run as root:  sudo bash install.sh"

# ── Idempotency: state file ───────────────────────────────────────────────────
STATE="/var/lib/dos-desktop-install.state"
touch "$STATE"

mark_done()  { grep -qxF "$1" "$STATE" 2>/dev/null || echo "$1" >> "$STATE"; }
is_done()    { grep -qxF "$1" "$STATE" 2>/dev/null; }

# save_val KEY VALUE  /  load_val KEY (echoes value)
save_val() { sed -i "/^${1}=/d" "$STATE" 2>/dev/null; echo "${1}=${2}" >> "$STATE"; }
load_val() { grep "^${1}=" "$STATE" 2>/dev/null | cut -d= -f2; }

log "State file: ${STATE}"
log "To force full reinstall: rm ${STATE} && sudo bash install.sh"

# ── Target user ───────────────────────────────────────────────────────────────
TARGET_USER="${SUDO_USER:-}"
[[ -z "$TARGET_USER" ]] && read -rp "Username to configure for: " TARGET_USER
[[ -z "$TARGET_USER" ]] && err "No target user specified."
id "$TARGET_USER" &>/dev/null || err "User '$TARGET_USER' does not exist."
TARGET_HOME="/home/${TARGET_USER}"
log "Target user: ${TARGET_USER}  (home: ${TARGET_HOME})"

# ── Key paths ─────────────────────────────────────────────────────────────────
DOS_ROOT="${TARGET_HOME}/dos_env"
DRIVE_C="${DOS_ROOT}/drive_c"
DRIVE_D="${DOS_ROOT}/drive_d"
FREEDOS_CACHE="${DOS_ROOT}/freedos_cache"
DOSEMU_CFG="${TARGET_HOME}/.dosemu"
I3_CFG="${TARGET_HOME}/.config/i3"
APPS_DIR="${TARGET_HOME}/.local/share/applications"
DESKTOP="${TARGET_HOME}/Desktop"
LAUNCHER="/usr/local/bin/dos_launcher.sh"
SCANNER="/usr/local/bin/dos_scan_apps.sh"
ADD_APP="/usr/local/bin/dos_add_app.sh"
IDENTIFY="/usr/local/bin/dos_identify.sh"
FETCH_APPS="/usr/local/bin/dos_fetch_apps.sh"
FREEDOS_SETUP="/usr/local/bin/dos_setup_freedos.sh"
POWER_MENU="/usr/local/bin/power-menu.sh"
CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-trixie}")

log "Debian codename: ${CODENAME}"

# Restore persisted display server from previous run (if any)
DISPLAY_SERVER=$(load_val DISPLAY_SERVER); DISPLAY_SERVER="${DISPLAY_SERVER:-not-set}"

# =============================================================================
hdr "PHASE 1 — Base packages & backports"
# =============================================================================
if is_done "phase1"; then
    log "SKIP: Base packages (already done)"
else
    apt-get update -qq
    # gawk is required by dosemu2's configure script
    apt-get install -y --no-install-recommends \
        ca-certificates curl gpg wget \
        lsb-release apt-transport-https \
        build-essential git nasm gawk \
        file xxd python3 unzip \
        libdrm2 libdrm-common \
        policykit-1

    if ! grep -rqs "${CODENAME}-backports" \
            /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        cat > /etc/apt/sources.list.d/trixie-backports.sources << EOF
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: ${CODENAME}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        log "Trixie backports added."
    else
        log "Backports already configured."
    fi
    apt-get update -qq
    mark_done "phase1"
    log "Base packages done."
fi

# =============================================================================
hdr "PHASE 2 — XLibre repository"
# =============================================================================
XLIBRE_KEYRING="/etc/apt/keyrings/xlibre-deb.asc"
XLIBRE_SOURCES="/etc/apt/sources.list.d/xlibre-deb.sources"

if is_done "phase2"; then
    log "SKIP: XLibre repository (already done)"
else
    install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f "${XLIBRE_KEYRING}" ]]; then
        log "Importing XLibre GPG key..."
        curl -fsSL https://xlibre-deb.github.io/key.asc \
            | tee "${XLIBRE_KEYRING}" > /dev/null
        chmod a+r "${XLIBRE_KEYRING}"
    else
        log "XLibre key already present."
    fi

    # Always (re)write sources to ensure correct codename
    cat > "${XLIBRE_SOURCES}" << EOF
Types: deb deb-src
URIs: https://xlibre-deb.github.io/debian/
Suites: ${CODENAME}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: ${XLIBRE_KEYRING}
EOF

    apt-get update -qq
    mark_done "phase2"
    log "XLibre repository configured."
fi

# =============================================================================
hdr "PHASE 3 — Install XLibre"
# =============================================================================
if is_done "phase3"; then
    log "SKIP: XLibre install (already done — server: ${DISPLAY_SERVER})"
else
    # Newer libdrm from backports (XLibre needs it on Trixie)
    apt-get install -y -t "${CODENAME}-backports" libdrm2 libdrm-common 2>/dev/null || true

    # Install XLibre — single meta-package replaces xserver-xorg-* entirely.
    # No Wayland, no XWayland, no compositor is pulled in.
    if apt-get install -y --no-install-recommends xlibre; then
        DISPLAY_SERVER="xlibre"
        log "XLibre installed — xserver-xlibre-core is the active X server."
    else
        warn "XLibre install failed. Check network to xlibre-deb.github.io"
        warn "Emergency fallback: xserver-xorg"
        apt-get install -y --no-install-recommends xserver-xorg
        DISPLAY_SERVER="xorg-emergency-fallback"
    fi
    save_val DISPLAY_SERVER "${DISPLAY_SERVER}"

    # X11 utils from Debian main (NOT the XLibre repo)
    # xmessage was dropped in Trixie — zenity is used instead for dialogs
    apt-get install -y --no-install-recommends \
        x11-xserver-utils \
        x11-utils \
        xauth \
        xinit \
        dbus-x11 \
        zenity

    mark_done "phase3"
    log "Display server: ${DISPLAY_SERVER}"
fi

# =============================================================================
hdr "PHASE 4 — Window Manager: i3"
# =============================================================================
if is_done "phase4"; then
    log "SKIP: i3 (already done)"
else
    apt-get install -y --no-install-recommends \
        i3 i3status i3lock dmenu \
        feh picom dunst \
        fonts-dejavu-core fonts-liberation fonts-terminus \
        j4-dmenu-desktop
    mark_done "phase4"
    log "i3 + j4-dmenu-desktop installed."
fi

# =============================================================================
hdr "PHASE 5 — Terminal & Desktop Manager"
# =============================================================================
if is_done "phase5"; then
    log "SKIP: urxvt + PCManFM (already done)"
else
    apt-get install -y --no-install-recommends \
        rxvt-unicode pcmanfm \
        xdg-utils desktop-file-utils shared-mime-info
    mark_done "phase5"
    log "urxvt + PCManFM installed."
fi

# =============================================================================
hdr "PHASE 6 — dosemu2"
# =============================================================================
if is_done "phase6"; then
    log "SKIP: dosemu2 (already done)"
else
    # Try apt first, then backports, then build from source
    DOSEMU_INSTALLED=0

    if command -v dosemu &>/dev/null || command -v dosemu2 &>/dev/null; then
        log "dosemu2 binary already in PATH — skipping install."
        DOSEMU_INSTALLED=1
    fi

    if [[ $DOSEMU_INSTALLED -eq 0 ]]; then
        if apt-get install -y dosemu2 2>/dev/null; then
            log "dosemu2 installed from apt."; DOSEMU_INSTALLED=1
        fi
    fi

    if [[ $DOSEMU_INSTALLED -eq 0 ]]; then
        if apt-get install -y -t "${CODENAME}-backports" dosemu2 2>/dev/null; then
            log "dosemu2 installed from backports."; DOSEMU_INSTALLED=1
        fi
    fi

    if [[ $DOSEMU_INSTALLED -eq 0 ]]; then
        warn "dosemu2 not in apt or backports — building from source..."

        # All build deps including gawk (required by configure)
        apt-get install -y \
            autoconf automake libtool pkg-config cmake \
            gawk bison flex nasm \
            libx11-dev libxext-dev libxt-dev \
            libslang2-dev libgpm-dev libbsd-dev \
            libsndfile1-dev libfluidsynth-dev \
            libreadline-dev zlib1g-dev

        # Kernel headers (best-effort — needed for some dosemu2 features)
        apt-get install -y "linux-headers-$(uname -r)" 2>/dev/null \
            || apt-get install -y linux-headers-generic 2>/dev/null \
            || warn "Could not install kernel headers — dosemu2 will still build."

        TMPDIR=$(mktemp -d)
        trap 'rm -rf "$TMPDIR"' EXIT

        log "Cloning dosemu2..."
        git clone --depth=1 https://github.com/stsp/dosemu2.git "$TMPDIR/dosemu2"

        cd "$TMPDIR/dosemu2"
        log "autoreconf..."
        autoreconf -fi

        log "configure..."
        ./configure --prefix=/usr

        log "make ($(nproc) jobs)..."
        make -j"$(nproc)"

        log "make install..."
        make install

        cd /
        trap - EXIT
        rm -rf "$TMPDIR"
        log "dosemu2 built and installed from source."
        DOSEMU_INSTALLED=1
    fi

    if [[ $DOSEMU_INSTALLED -eq 1 ]]; then
        mark_done "phase6"
    else
        warn "Phase 6: dosemu2 install failed — re-run to retry."
    fi
fi

# KVM group (idempotent — always check regardless of phase state)
if getent group kvm &>/dev/null; then
    if ! groups "$TARGET_USER" 2>/dev/null | grep -qw kvm; then
        usermod -aG kvm "$TARGET_USER"
        log "${TARGET_USER} added to kvm group (hardware acceleration)."
    else
        log "${TARGET_USER} already in kvm group."
    fi
else
    warn "kvm group not found — dosemu2 will use software emulation."
fi

# =============================================================================
hdr "PHASE 7 — FreeDOS System Download (NEW!)"
# =============================================================================
# Downloads FreeDOS base packages from ibiblio.org and sets up C: drive
FREEDOS_BASE_URL="https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages"
FREEDOS_13_URL="https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.3/repos"

if is_done "phase7"; then
    log "SKIP: FreeDOS system download (already done)"
else
    log "Creating FreeDOS directory structure..."
    mkdir -p "${DRIVE_C}" "${DRIVE_D}"/{APPS,GAMES,UTILS,WORK,DOCS}
    mkdir -p "${FREEDOS_CACHE}"/{base,utils,games}
    
    # Essential FreeDOS packages for a working system
    # These are the minimum needed to boot and have a usable shell
    FREEDOS_PACKAGES=(
        "kernel"           # FreeDOS kernel
        "command"          # FreeCOM shell
        "himem"            # XMS driver
        "emm386"           # EMS driver
        "edit"             # Text editor
        "format"           # Disk formatter
        "sys"              # System transfer
        "fdisk"            # Partition tool
        "mode"             # Device mode
        "more"             # Text pager
        "find"             # Search utility
        "sort"             # Sort utility
        "xcopy"            # Extended copy
        "choice"           # Choice utility
        "move"             # Move files
        "deltree"          # Delete tree
        "debug"            # Debugger
        "display"          # Display utilities
        "keyb"             # Keyboard utilities
    )
    
    # Download FreeDOS packages
    log "Downloading FreeDOS base packages from ibiblio.org..."
    DOWNLOAD_SUCCESS=0
    DOWNLOAD_FAILED=0
    
    for pkg in "${FREEDOS_PACKAGES[@]}"; do
        log "  Downloading ${pkg}..."
        if curl -fsSL "${FREEDOS_BASE_URL}/base/${pkg}.zip" -o "${FREEDOS_CACHE}/base/${pkg}.zip" 2>/dev/null; then
            DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
        else
            # Try alternative location
            if curl -fsSL "${FREEDOS_BASE_URL}/${pkg}.zip" -o "${FREEDOS_CACHE}/base/${pkg}.zip" 2>/dev/null; then
                DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            else
                warn "  Could not download ${pkg} (will try alternate source)"
                DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
            fi
        fi
    done
    
    log "Downloaded ${DOWNLOAD_SUCCESS} packages, ${DOWNLOAD_FAILED} failed."
    
    # Extract packages to C: drive
    log "Extracting FreeDOS packages to C: drive..."
    mkdir -p "${DRIVE_C}"/{BIN,SYS,TEMP,HELP}
    
    for pkgzip in "${FREEDOS_CACHE}"/base/*.zip; do
        [[ -f "$pkgzip" ]] || continue
        pkgname=$(basename "$pkgzip" .zip)
        log "  Extracting ${pkgname}..."
        unzip -q -o "$pkgzip" -d "${DRIVE_C}" 2>/dev/null || true
    done
    
    # Try to get FreeDOS kernel directly if packages failed
    if [[ ! -f "${DRIVE_C}/BIN/KERNEL.SYS" && ! -f "${DRIVE_C}/KERNEL.SYS" ]]; then
        log "Attempting direct kernel download..."
        # Try FreeDOS kernel from alternative sources
        curl -fsSL "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/kernel.zip" \
            -o "${FREEDOS_CACHE}/base/kernel.zip" 2>/dev/null
        
        if [[ -f "${FREEDOS_CACHE}/base/kernel.zip" ]]; then
            unzip -q -o "${FREEDOS_CACHE}/base/kernel.zip" -d "${DRIVE_C}" 2>/dev/null || true
        fi
    fi
    
    # Create FreeDOS directory structure
    mkdir -p "${DRIVE_C}"/{DOS,TEMP}
    
    # If we didn't get kernel, try to create a minimal bootable setup
    if [[ ! -f "${DRIVE_C}/BIN/KERNEL.SYS" && ! -f "${DRIVE_C}/KERNEL.SYS" ]]; then
        warn "Could not download FreeDOS kernel from primary source."
        warn "Will attempt dosemu2 built-in FreeDOS or alternative source later."
    else
        log "FreeDOS kernel found and extracted successfully."
    fi
    
    mark_done "phase7"
    log "FreeDOS system setup complete."
fi

# =============================================================================
hdr "PHASE 8 — DOS Utilities from Archive.org (NEW!)"
# =============================================================================
# Downloads essential DOS utilities from archive.org

if is_done "phase8"; then
    log "SKIP: DOS utilities download (already done)"
else
    log "Downloading DOS utilities from archive.org..."
    
    # Archive.org URLs for essential DOS software
    # These are verified working archive.org items
    
    # Create utils directory
    mkdir -p "${DRIVE_D}/UTILS"
    
    # Download archive utilities collection (PKZIP, ARJ, LHARC, etc.)
    log "  Downloading archive utilities (PKZIP, ARJ, etc.)..."
    if curl -fsSL "https://archive.org/download/archiveutilities/archiveutilities.zip" \
            -o "${FREEDOS_CACHE}/utils/archive_utilities.zip" 2>/dev/null; then
        unzip -q -o "${FREEDOS_CACHE}/utils/archive_utilities.zip" -d "${DRIVE_D}/UTILS" 2>/dev/null || true
        log "    Archive utilities downloaded."
    else
        warn "    Could not download archive utilities collection."
    fi
    
    # Download Norton Commander 5.0 (classic file manager)
    log "  Downloading Norton Commander..."
    if curl -fsSL "https://archive.org/download/norton-commander-5.0-de/nc5de.zip" \
            -o "${FREEDOS_CACHE}/utils/nc5.zip" 2>/dev/null; then
        mkdir -p "${DRIVE_D}/UTILS/NC"
        unzip -q -o "${FREEDOS_CACHE}/utils/nc5.zip" -d "${DRIVE_D}/UTILS/NC" 2>/dev/null || true
        log "    Norton Commander downloaded."
    else
        warn "    Could not download Norton Commander."
    fi
    
    # Try alternative NC source
    if [[ ! -f "${DRIVE_D}/UTILS/NC/NC.EXE" ]]; then
        if curl -fsSL "https://archive.org/download/nc50/nc50.zip" \
                -o "${FREEDOS_CACHE}/utils/nc50.zip" 2>/dev/null; then
            mkdir -p "${DRIVE_D}/UTILS/NC"
            unzip -q -o "${FREEDOS_CACHE}/utils/nc50.zip" -d "${DRIVE_D}/UTILS/NC" 2>/dev/null || true
        fi
    fi
    
    # Download some classic DOS games from archive.org
    log "  Downloading classic DOS games..."
    mkdir -p "${DRIVE_D}/GAMES"
    
    # Prince of Persia
    if curl -fsSL "https://archive.org/download/0mhz-dos/Prince%20of%20Persia.zip" \
            -o "${FREEDOS_CACHE}/games/pop.zip" 2>/dev/null; then
        mkdir -p "${DRIVE_D}/GAMES/PRINCE"
        unzip -q -o "${FREEDOS_CACHE}/games/pop.zip" -d "${DRIVE_D}/GAMES/PRINCE" 2>/dev/null || true
        log "    Prince of Persia downloaded."
    fi
    
    # Download DOS text editor collection
    log "  Downloading DOS text editors..."
    if curl -fsSL "https://archive.org/download/dos-text-editors/DOS%20Text%20Editors.zip" \
            -o "${FREEDOS_CACHE}/utils/editors.zip" 2>/dev/null; then
        unzip -q -o "${FREEDOS_CACHE}/utils/editors.zip" -d "${DRIVE_D}/UTILS" 2>/dev/null || true
        log "    Text editors downloaded."
    fi
    
    # Download misc DOS utilities
    log "  Downloading misc DOS utilities..."
    if curl -fsSL "https://archive.org/download/Misc-MS-DOS-1_25-Utilities/MSDOS125.ZIP" \
            -o "${FREEDOS_CACHE}/utils/msdos_utils.zip" 2>/dev/null; then
        unzip -q -o "${FREEDOS_CACHE}/utils/msdos_utils.zip" -d "${DRIVE_D}/UTILS" 2>/dev/null || true
        log "    MS-DOS 1.25 utilities downloaded."
    fi
    
    mark_done "phase8"
    log "DOS utilities download complete."
fi

# =============================================================================
hdr "PHASE 9 — Shared D: Drive"
# =============================================================================
if is_done "phase9"; then
    log "SKIP: D: drive (already done)"
else
    # Ensure directory structure exists
    mkdir -p "${DRIVE_D}"/{APPS,GAMES,UTILS,WORK,DOCS}
    
    cat > "${DRIVE_D}/README.TXT" << 'EOF'
D: DRIVE - SHARED DOS ENVIRONMENT
===================================
APPS\    General DOS applications
GAMES\   DOS games (Prince of Persia, etc.)
UTILS\   Utilities (PKZIP, ARJ, NC, editors)
WORK\    Working files
DOCS\    Documentation

All dosemu2 instances share this drive.
Files here are accessible from every open DOS window.

QUICK START:
1. Run "Scan D: for DOS Apps" on the desktop to create shortcuts
2. Or use "Get DOS Apps" to download more software
3. Double-click any DOS icon to run!

FREE DOWNLOADS:
- archive.org/details/softwarelibrary_msdos_games (2400+ games)
- freedos.org/download (FreeDOS packages)
EOF
    chown -R "${TARGET_USER}:${TARGET_USER}" "${DOS_ROOT}"
    mark_done "phase9"
    log "D: drive created: ${DRIVE_D}"
fi

# =============================================================================
hdr "PHASE 10 — dosemu2 Configuration with FreeDOS"
# =============================================================================
if is_done "phase10"; then
    log "SKIP: dosemu2 config (already done)"
else
    mkdir -p "${DOSEMU_CFG}/drives/c"
    
    # Determine if we have FreeDOS kernel
    KERNEL_PATH=""
    if [[ -f "${DRIVE_C}/BIN/KERNEL.SYS" ]]; then
        KERNEL_PATH='$_bootdrive = "C"'
    elif [[ -f "${DRIVE_C}/KERNEL.SYS" ]]; then
        KERNEL_PATH='$_bootdrive = "C"'
    fi

    cat > "${DOSEMU_CFG}/dosemu.conf" << EOF
# dosemu2 configuration — DOS Desktop Environment
# FreeDOS-ready setup

# CPU / Memory
\$_cpu_emu = "vm86"
\$_dpmi    = 0x5000
\$_xms     = 8192
\$_ems     = 4096

# Boot from C: drive if we have FreeDOS kernel
${KERNEL_PATH:-\$_bootdrive = "C"}

# Display — XLibre/X11 windowed mode
# Each process opens its own X window.
# Mouse grab OFF — cursor moves freely between Linux and DOS.
\$_X_font               = "vga"
\$_X_title              = "DOS"
\$_X_title_show_appname = (1)
\$_X_mgrab              = (0)
\$_X_fullscreen         = (0)

# Sound (disabled — enable if you have audio hardware)
\$_sound = (0)

# Performance
\$_hogthreshold = 1
\$_cli_timeout  = (1000)

# Drive mappings
# C: = Primary boot drive (FreeDOS)
# D: = Shared data drive
\$_lredir_paths = "${DRIVE_D}"
EOF

    # Create autoexec.bat for FreeDOS
    cat > "${DOSEMU_CFG}/drives/c/autoexec.bat" << AUTOEXEC_EOF
@ECHO OFF
PROMPT \$P\$G

REM Set up path
PATH C:\\BIN;C:\\DOS;D:\\UTILS;D:\\UTILS\\NC

REM Mount shared Linux path as D: drive
LREDIR D: LINUX\\FS${DRIVE_D}

REM Display welcome message
CLS
ECHO.
ECHO ╔════════════════════════════════════════════════════════════╗
ECHO ║          FreeDOS Desktop Environment                       ║
ECHO ║                                                            ║
ECHO ║  D: drive = ${DRIVE_D}
ECHO ║                                                            ║
ECHO ║  Type HELP for commands, EDIT to edit files               ║
ECHO ║  Type NC for Norton Commander (if installed)              ║
ECHO ╚════════════════════════════════════════════════════════════╝
ECHO.

D:
AUTOEXEC_EOF

    # Create config.sys for FreeDOS
    cat > "${DOSEMU_CFG}/drives/c/config.sys" << 'CONFIG_EOF'
!COUNTRY=001,437,C:\BIN\COUNTRY.SYS
DOS=HIGH,UMB
FILES=60
BUFFERS=40
LASTDRIVE=Z

REM Memory managers
DEVICE=HIMEM.SYS
DEVICE=EMM386.EXE NOEMS

REM Shell
SHELL=COMMAND.COM /E:1024 /P

REM CD-ROM support (if available)
REM DEVICE=D:\UTILS\OAKCDROM.SYS /D:MSCD001
CONFIG_EOF

    chown -R "${TARGET_USER}:${TARGET_USER}" "${DOSEMU_CFG}"
    mark_done "phase10"
    log "dosemu2 configured with FreeDOS support."
fi

# =============================================================================
hdr "PHASE 11 — Binary Format Identifier (dos_identify.sh)"
# =============================================================================
if is_done "phase11"; then
    log "SKIP: dos_identify.sh (already done)"
else
    cat > "$IDENTIFY" << 'IDENTIFY_SCRIPT'
#!/bin/bash
# dos_identify.sh  —  Identify legacy executable format
# Usage: dos_identify.sh <filepath>
# exit 0: DOS-compatible   exit 1: not compatible   exit 2: ambiguous
FILE_PATH="$1"
[[ -z "$FILE_PATH" ]] && { echo "Usage: dos_identify.sh <file>"; exit 1; }
[[ ! -f "$FILE_PATH" ]] && { echo "ERROR: Not found: $FILE_PATH"; exit 1; }
BASENAME=$(basename "$FILE_PATH")
EXT=$(echo "${BASENAME##*.}" | tr '[:lower:]' '[:upper:]')
FILESIZE=$(stat -c%s "$FILE_PATH")
rhex() { xxd -p -s "$1" -l "$2" "$FILE_PATH" 2>/dev/null | tr '[:lower:]' '[:upper:]'; }
MAGIC2=$(rhex 0 2)
MAGIC4=$(rhex 0 4)
e_lfanew() {
    local r; r=$(rhex 60 4)
    [[ ${#r} -lt 8 ]] && echo 0 && return
    printf "%d" "0x${r:6:2}${r:4:2}${r:2:2}${r:0:2}" 2>/dev/null || echo 0
}
[[ "$EXT" == "BAT" ]] && {
    echo "FORMAT: DOS/FreeDOS Batch Script (.BAT) — fully compatible"; exit 0; }
if [[ "$MAGIC2" == "4D5A" || "$MAGIC2" == "5A4D" ]]; then
    OFF=$(e_lfanew); SIG=""
    [[ $OFF -gt 63 && $OFF -lt $FILESIZE ]] && SIG=$(rhex "$OFF" 4)
    if [[ "$SIG" == "50450000" ]]; then
        OM=$(rhex $(( OFF + 24 )) 2)
        BITS="32-bit"; [[ "$OM" == "0B02" ]] && BITS="64-bit"
        SS=$(rhex $(( OFF + 24 + 68 )) 2)
        case "$SS" in
            "0200") echo "FORMAT: Windows PE ${BITS} GUI — NOT DOS-compatible (use Wine)"; exit 1 ;;
            "0300") echo "FORMAT: Windows PE ${BITS} Console — NOT DOS-compatible (use Wine)"; exit 1 ;;
            *) echo "FORMAT: Windows PE ${BITS} [subsys=0x${SS}] — NOT DOS-compatible"; exit 1 ;;
        esac
    fi
    [[ "${SIG:0:4}" == "4E45" ]] && {
        echo "FORMAT: NE 16-bit Windows/OS2 — NOT DOS-runnable in dosemu2"; exit 1; }
    [[ "${SIG:0:4}" == "4C45" || "${SIG:0:4}" == "4C58" ]] && {
        echo "FORMAT: LE/LX OS/2 or Win9x VxD — NOT DOS-compatible"; exit 1; }
    echo "FORMAT: DOS MZ EXE — compatible with dosemu2 / FreeDOS / MS-DOS"; exit 0
fi
if [[ "$EXT" == "COM" ]]; then
    B0=$(rhex 0 1)
    if [[ "$B0" == "C9" ]]; then
        B1=$(rhex 1 1)
        if [[ "$B1" == "80" || "$B1" == "00" ]]; then
            echo "FORMAT: CP/M-3 COM (RSX header, 8080/Z80 code) — NOT x86 DOS"
            echo "NOTE:   Use RunCPM, z88dk, or MAME CP/M driver."; exit 1
        fi
    fi
    [[ $FILESIZE -gt 65280 ]] && {
        echo "FORMAT: Oversized COM (${FILESIZE} bytes > 65280) — misnamed EXE or corrupt"
        exit 2; }
    case "$B0" in
        "E9"|"EB"|"B8"|"CD"|"FA"|"FC"|"33"|"8C"|"50"|"55"|"B4"|"31"|"F3"|"0E"|"1E")
            echo "FORMAT: DOS/FreeDOS COM — raw x86 binary, dosemu2-compatible"; exit 0 ;;
        *) echo "FORMAT: COM (byte0=0x${B0}) — probable x86 DOS, verify manually"
           echo "NOTE:   Could be CP/M-80 (8080/Z80). If dosemu2 crashes it is 8080-only."
           exit 2 ;;
    esac
fi
echo "FORMAT: Unknown (ext=${EXT}, magic=${MAGIC4}, size=${FILESIZE} bytes)"
echo "NOTE:   Run 'file ${FILE_PATH}' for more detail."; exit 2
IDENTIFY_SCRIPT
    chmod +x "$IDENTIFY"
    mark_done "phase11"
    log "dos_identify.sh installed."
fi

# =============================================================================
hdr "PHASE 12 — DOS Launcher (dos_launcher.sh)"
# =============================================================================
if is_done "phase12"; then
    log "SKIP: dos_launcher.sh (already done)"
else
    LAUNCHER_DRIVE_D="${DRIVE_D}"
    LAUNCHER_DRIVE_C="${DRIVE_C}"
    LAUNCHER_IDENTIFY="${IDENTIFY}"

    cat > "$LAUNCHER" << LAUNCHER_SCRIPT
#!/bin/bash
# dos_launcher.sh — Launch a DOS app in a new XLibre/X11 window
# Usage:
#   dos_launcher.sh                             → interactive FreeDOS shell
#   dos_launcher.sh "D:\\\\APPS\\\\APP.EXE"       → launch specific app
#   dos_launcher.sh /linux/path/to/app.exe      → auto-identify + launch
EXE_PATH="\${1:-}"
WIN_TITLE="\${2:-DOS}"
DRIVE_D="${LAUNCHER_DRIVE_D}"
DRIVE_C="${LAUNCHER_DRIVE_C}"

show_error() {
    if command -v zenity &>/dev/null && [[ -n "\${DISPLAY:-}" ]]; then
        zenity --error --title="DOS Launcher" --text="\$1" 2>/dev/null
    else
        echo "ERROR: \$1" >&2
    fi
}
if [[ -n "\$EXE_PATH" && -f "\$EXE_PATH" ]]; then
    IDENT=\$("${LAUNCHER_IDENTIFY}" "\$EXE_PATH" 2>&1); ECODE=\$?
    if [[ \$ECODE -eq 1 ]]; then
        show_error "Cannot run in dosemu2:\\n\\n\${IDENT}\\n\\nFile: \${EXE_PATH}"; exit 1
    fi
    if [[ "\$EXE_PATH" == "\${DRIVE_D}"* ]]; then
        REL="\${EXE_PATH#\${DRIVE_D}/}"
        EXE_PATH="D:\\\\\$(echo "\$REL" | tr '/' '\\\\')"
    elif [[ "\$EXE_PATH" == "\${DRIVE_C}"* ]]; then
        REL="\${EXE_PATH#\${DRIVE_C}/}"
        EXE_PATH="C:\\\\\$(echo "\$REL" | tr '/' '\\\\')"
    fi
fi
if [[ -z "\$EXE_PATH" ]]; then
    exec dosemu -X -title "FreeDOS Shell"
fi
CMD="lredir d: linux\\\\fs\${DRIVE_D}; d:; \${EXE_PATH}"
exec dosemu -X -title "\${WIN_TITLE}" -E "\${CMD}"
LAUNCHER_SCRIPT
    chmod +x "$LAUNCHER"
    mark_done "phase12"
    log "dos_launcher.sh installed."
fi

# =============================================================================
hdr "PHASE 13 — Add App Helper (dos_add_app.sh)"
# =============================================================================
if is_done "phase13"; then
    log "SKIP: dos_add_app.sh (already done)"
else
    cat > "$ADD_APP" << 'ADDAPP_SCRIPT'
#!/bin/bash
# dos_add_app.sh — Create a .desktop shortcut for a DOS application
# Usage: dos_add_app.sh "App Name" "D:\\PATH\\APP.EXE" [icon]
APP_NAME="$1"; EXE_INPUT="$2"; ICON="${3:-application-x-executable}"
[[ -z "$APP_NAME" || -z "$EXE_INPUT" ]] && {
    echo "Usage: dos_add_app.sh \"App Name\" \"D:\\PATH\\APP.EXE\" [icon]"; exit 1; }
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
DRIVE_D="/home/${TARGET_USER}/dos_env/drive_d"
DRIVE_C="/home/${TARGET_USER}/dos_env/drive_c"
APPS_DIR="/home/${TARGET_USER}/.local/share/applications"
DESKTOP_DIR="/home/${TARGET_USER}/Desktop"
SAFE=$(echo "$APP_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
mkdir -p "$APPS_DIR" "$DESKTOP_DIR"
EXE_DOS="$EXE_INPUT"; IDENT_MSG="(not checked)"
if [[ -f "$EXE_INPUT" ]]; then
    IDENT_MSG=$(/usr/local/bin/dos_identify.sh "$EXE_INPUT" 2>&1); ECODE=$?
    [[ $ECODE -eq 1 ]] && echo "WARNING ${APP_NAME}: ${IDENT_MSG}"
    if [[ "$EXE_INPUT" == "${DRIVE_D}"* ]]; then
        REL="${EXE_INPUT#${DRIVE_D}/}"
        EXE_DOS="D:\\$(echo "$REL" | tr '/' '\\')"
    elif [[ "$EXE_INPUT" == "${DRIVE_C}"* ]]; then
        REL="${EXE_INPUT#${DRIVE_C}/}"
        EXE_DOS="C:\\$(echo "$REL" | tr '/' '\\')"
    fi
fi
DFILE="${APPS_DIR}/dos-${SAFE}.desktop"
cat > "$DFILE" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${APP_NAME}
Comment=DOS Application — ${EXE_DOS}
Exec=/usr/local/bin/dos_launcher.sh "${EXE_DOS}" "${APP_NAME}"
Icon=${ICON}
Terminal=false
Categories=Application;DOSApplication;
EOF
chmod +x "$DFILE"
ln -sf "$DFILE" "${DESKTOP_DIR}/dos-${SAFE}.desktop"
chown "${TARGET_USER}:${TARGET_USER}" "$DFILE"
echo "Created: ${APP_NAME}  →  ${EXE_DOS}  (${IDENT_MSG})"
ADDAPP_SCRIPT
    chmod +x "$ADD_APP"
    mark_done "phase13"
    log "dos_add_app.sh installed."
fi

# =============================================================================
hdr "PHASE 14 — D: Drive Scanner (dos_scan_apps.sh)"
# =============================================================================
if is_done "phase14"; then
    log "SKIP: dos_scan_apps.sh (already done)"
else
    cat > "$SCANNER" << 'SCANNER_SCRIPT'
#!/bin/bash
# dos_scan_apps.sh — Scan D: drive, classify executables, create shortcuts

# Auto-launch in terminal if not already in one
if [[ ! -t 0 ]]; then
    exec urxvt -e bash -c "/usr/local/bin/dos_scan_apps.sh; read -p 'Done. Press Enter...'"
fi

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
DRIVE_D="/home/${TARGET_USER}/dos_env/drive_d"
DRIVE_C="/home/${TARGET_USER}/dos_env/drive_c"
echo ""; echo "══ Scanning D: at ${DRIVE_D} ══"; echo ""
DOS_OK=0; WIN_SKIP=0; CPM_SKIP=0; AMBIG=0; TOTAL=0
while IFS= read -r -d '' FP; do
    TOTAL=$((TOTAL+1))
    BN=$(basename "$FP"); AN="${BN%.*}"
    ID=$(/usr/local/bin/dos_identify.sh "$FP" 2>&1); EC=$?
    case $EC in
        0) /usr/local/bin/dos_add_app.sh "$AN" "$FP" >/dev/null
           printf "  %-32s  ✓  %s\n" "$BN" "$ID"; DOS_OK=$((DOS_OK+1)) ;;
        1) printf "  %-32s  ✗  %s\n" "$BN" "$ID"
           echo "$ID" | grep -qi "CP/M\|8080\|Z80" \
               && CPM_SKIP=$((CPM_SKIP+1)) || WIN_SKIP=$((WIN_SKIP+1)) ;;
        2) /usr/local/bin/dos_add_app.sh "$AN" "$FP" >/dev/null
           printf "  %-32s  ?  %s\n" "$BN" "$ID"; AMBIG=$((AMBIG+1)) ;;
    esac
done < <(find "$DRIVE_D" "$DRIVE_C" -maxdepth 4 \
    \( -iname "*.exe" -o -iname "*.com" -o -iname "*.bat" \) -print0 2>/dev/null)
echo ""; echo "══ Results ══"
printf "  Total scanned       : %d\n" "$TOTAL"
printf "  Shortcuts created   : %d  (DOS: %d  Ambiguous: %d)\n" \
    "$((DOS_OK+AMBIG))" "$DOS_OK" "$AMBIG"
printf "  Skipped (Windows)   : %d\n" "$WIN_SKIP"
printf "  Skipped (CP/M-80)   : %d\n" "$CPM_SKIP"; echo ""
[[ $WIN_SKIP -gt 0 ]] && echo "  TIP: Windows PE → use Wine or a VM"
[[ $CPM_SKIP -gt 0 ]] && echo "  TIP: CP/M-80   → use RunCPM or MAME"; echo ""
SCANNER_SCRIPT
    chmod +x "$SCANNER"
    mark_done "phase14"
    log "dos_scan_apps.sh installed."
fi

# =============================================================================
hdr "PHASE 15 — DOS App Fetcher (dos_fetch_apps.sh) — NEW!"
# =============================================================================
# Script to download DOS apps from archive.org and FreeDOS repos

if is_done "phase15"; then
    log "SKIP: dos_fetch_apps.sh (already done)"
else
    cat > "$FETCH_APPS" << 'FETCH_SCRIPT'
#!/bin/bash
# dos_fetch_apps.sh — Download DOS applications from archive.org and FreeDOS repos
# Usage: dos_fetch_apps.sh [category]
# Categories: games, utils, freedos, all

# Auto-launch in terminal if not already in one
if [[ ! -t 0 && -z "$DISPLAY" ]]; then
    exec urxvt -e "$0" "$@"
fi
if [[ ! -t 0 && -n "$DISPLAY" ]]; then
    exec urxvt -e bash -c "$0 \"\$@\"; read -p 'Press Enter to close...'" _ "$@"
fi

set -uo pipefail

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
DOS_ROOT="/home/${TARGET_USER}/dos_env"
DRIVE_D="${DOS_ROOT}/drive_d"
FREEDOS_CACHE="${DOS_ROOT}/freedos_cache"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YLW}[!]${NC} $1"; }

CATEGORY="${1:-menu}"
mkdir -p "${DRIVE_D}"/{GAMES,APPS,UTILS}
mkdir -p "${FREEDOS_CACHE}"/{games,utils,freedos}

# ── Archive.org DOS Games Library ─────────────────────────────────────────────
GAMES=(
    # Format: "Name|Archive.org path"
    "Prince of Persia|0mhz-dos/Prince of Persia.zip"
    "Prince of Persia 2|0mhz-dos/Prince of Persia 2.zip"
    "Doom|doom-play/doom-play.zip"
    "Wolfenstein 3D|Wolfenstein_3d_1992_id_Software_inc"
    "Commander Keen|Commander_Keen_Invasion_of_the_Vorticons_v1.4_1990"
    "Lemmings|lemmings_1020"
    "SimCity|SimCity_EN_1989_Maxis_Software_Inc"
    "Tetris|msdos_TETRIS_1987_Spectrum_HoloByte"
    "Alley Cat|msdos_Alley_Cat_1984_IBM"
    "Digger|msdos_Digger_1983_Windmill_Software"
    "Dave|msdos_Dangerous_Dave_1990_Softdisk"
    "Skyroads|msdos_Skyroads_1993_Blue_Moon_Software"
)

# ── Archive.org DOS Utilities ─────────────────────────────────────────────────
UTILITIES=(
    "Archive Utilities|archiveutilities/archiveutilities.zip"
    "Norton Commander 5|norton-commander-5.0-de/nc5de.zip"
    "DOS Text Editors|dos-text-editors/DOS Text Editors.zip"
    "MS-DOS 1.25 Utils|Misc-MS-DOS-1_25-Utilities/MSDOS125.ZIP"
    "Norton Utils 8|symantec-norton-utilities-8.0-for-windows-and-dos/norton80.zip"
)

# ── FreeDOS Packages (from ibiblio) ───────────────────────────────────────────
FREEDOS_PACKAGES=(
    "kernel|https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/kernel.zip"
    "command|https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/command.zip"
    "edit|https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/edit.zip"
    "games|https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/games.zip"
    "utils|https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/util.zip"
)

download_from_archive() {
    local NAME="$1" ARCHIVE_PATH="$2" DEST="$3"
    local URL="https://archive.org/download/${ARCHIVE_PATH}"
    local ZIPFILE="${FREEDOS_CACHE}/games/${NAME// /_}.zip"
    
    log "  Downloading ${NAME}..."
    if curl -fsSL "$URL" -o "$ZIPFILE" 2>/dev/null; then
        local DESTDIR="${DEST}/${NAME// /_}"
        mkdir -p "$DESTDIR"
        unzip -q -o "$ZIPFILE" -d "$DESTDIR" 2>/dev/null || true
        log "    ✓ ${NAME} installed to ${DESTDIR}"
        return 0
    else
        warn "    ✗ Could not download ${NAME}"
        return 1
    fi
}

download_games() {
    log "\n${BLD}${CYN}══ Downloading DOS Games from Archive.org ══${NC}"
    SUCCESS=0; FAILED=0
    for ENTRY in "${GAMES[@]}"; do
        NAME="${ENTRY%%|*}"
        PATH="${ENTRY#*|}"
        if download_from_archive "$NAME" "$PATH" "${DRIVE_D}/GAMES"; then
            SUCCESS=$((SUCCESS + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    done
    log "\nGames: ${SUCCESS} downloaded, ${FAILED} failed"
}

download_utils() {
    log "\n${BLD}${CYN}══ Downloading DOS Utilities ══${NC}"
    SUCCESS=0; FAILED=0
    for ENTRY in "${UTILITIES[@]}"; do
        NAME="${ENTRY%%|*}"
        PATH="${ENTRY#*|}"
        if download_from_archive "$NAME" "$PATH" "${DRIVE_D}/UTILS"; then
            SUCCESS=$((SUCCESS + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    done
    log "\nUtilities: ${SUCCESS} downloaded, ${FAILED} failed"
}

download_freedos() {
    log "\n${BLD}${CYN}══ Downloading FreeDOS Packages ══${NC}"
    SUCCESS=0; FAILED=0
    for ENTRY in "${FREEDOS_PACKAGES[@]}"; do
        NAME="${ENTRY%%|*}"
        URL="${ENTRY#*|}"
        ZIPFILE="${FREEDOS_CACHE}/freedos/${NAME}.zip"
        
        log "  Downloading ${NAME}..."
        if curl -fsSL "$URL" -o "$ZIPFILE" 2>/dev/null; then
            unzip -q -o "$ZIPFILE" -d "${DRIVE_D}/APPS/FreeDOS_${NAME}" 2>/dev/null || true
            log "    ✓ ${NAME} downloaded"
            SUCCESS=$((SUCCESS + 1))
        else
            warn "    ✗ Could not download ${NAME}"
            FAILED=$((FAILED + 1))
        fi
    done
    log "\nFreeDOS packages: ${SUCCESS} downloaded, ${FAILED} failed"
}

show_menu() {
    echo ""
    echo -e "${BLD}${CYN}════════════════════════════════════════════════${NC}"
    echo -e "${BLD}         DOS APP DOWNLOADER - MAIN MENU${NC}"
    echo -e "${BLD}${CYN}════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1) Download Classic DOS Games (12 games)"
    echo "  2) Download DOS Utilities (PKZIP, NC, editors)"
    echo "  3) Download FreeDOS Packages"
    echo "  4) Download EVERYTHING (all of the above)"
    echo ""
    echo "  A) About archive.org DOS collection"
    echo "  Q) Quit"
    echo ""
    read -rp "  Choice [1-4/A/Q]: " CHOICE
    
    case "${CHOICE^^}" in
        1) download_games ;;
        2) download_utils ;;
        3) download_freedos ;;
        4) download_games; download_utils; download_freedos ;;
        A) show_about ;;
        Q) echo "Bye!"; exit 0 ;;
        *) echo "Invalid choice"; show_menu ;;
    esac
}

show_about() {
    echo ""
    echo -e "${BLD}About Archive.org DOS Collection:${NC}"
    echo ""
    echo "  The Internet Archive hosts over 2,400 playable MS-DOS games"
    echo "  and hundreds of DOS utilities in their Software Library."
    echo ""
    echo "  Browse the full collection at:"
    echo "  https://archive.org/details/softwarelibrary_msdos_games"
    echo ""
    echo "  All software is preserved for historical and educational purposes."
    echo ""
    read -rp "Press Enter to continue..."
    show_menu
}

# ── Main ─────────────────────────────────────────────────────────────────────
case "$CATEGORY" in
    games)  download_games ;;
    utils)  download_utils ;;
    freedos) download_freedos ;;
    all)    download_games; download_utils; download_freedos ;;
    *)      show_menu ;;
esac

# Scan for new apps
echo ""
log "Scanning for new DOS applications..."
/usr/local/bin/dos_scan_apps.sh 2>/dev/null

echo ""
log "${BLD}Done! Check your desktop for new shortcuts.${NC}"
FETCH_SCRIPT
    chmod +x "$FETCH_APPS"
    mark_done "phase15"
    log "dos_fetch_apps.sh installed."
fi

# =============================================================================
hdr "PHASE 16 — FreeDOS Setup Script (dos_setup_freedos.sh) — NEW!"
# =============================================================================
# Interactive script to set up or repair FreeDOS installation

if is_done "phase16"; then
    log "SKIP: dos_setup_freedos.sh (already done)"
else
    cat > "$FREEDOS_SETUP" << 'SETUP_SCRIPT'
#!/bin/bash
# dos_setup_freedos.sh — Set up or repair FreeDOS installation
# Downloads FreeDOS base system if not present

set -uo pipefail

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
DOS_ROOT="/home/${TARGET_USER}/dos_env"
DRIVE_C="${DOS_ROOT}/drive_c"
FREEDOS_CACHE="${DOS_ROOT}/freedos_cache"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YLW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; }

# FreeDOS 1.4 direct download URLs
FREEDOS_ISO="https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/FD14-LiveCD.zip"
FREEDOS_USB="https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/FD14-FullUSB.zip"

# Mirror at freedos.org
FREEDOS_OFFICIAL="https://www.freedos.org/download/"

echo ""
echo -e "${BLD}${CYN}════════════════════════════════════════════════${NC}"
echo -e "${BLD}         FreeDOS SETUP UTILITY${NC}"
echo -e "${BLD}${CYN}════════════════════════════════════════════════${NC}"
echo ""

# Check if FreeDOS kernel exists
check_kernel() {
    if [[ -f "${DRIVE_C}/BIN/KERNEL.SYS" ]] || [[ -f "${DRIVE_C}/KERNEL.SYS" ]]; then
        return 0
    fi
    return 1
}

echo "Checking FreeDOS installation..."
if check_kernel; then
    log "FreeDOS kernel found!"
    echo ""
    echo "  C: drive: ${DRIVE_C}"
    ls -la "${DRIVE_C}/BIN/" 2>/dev/null | head -10 || ls -la "${DRIVE_C}/" 2>/dev/null | head -10
    echo ""
else
    warn "FreeDOS kernel not found."
    echo ""
    echo "  Would you like to download FreeDOS now?"
    echo ""
    read -rp "  Download FreeDOS? [y/N]: " DL
    case "${DL^^}" in
        Y|YES)
            log "Downloading FreeDOS 1.4..."
            mkdir -p "${FREEDOS_CACHE}/freedos"
            
            # Try to download the Full USB image (contains all packages)
            log "Downloading FreeDOS Full USB image..."
            if curl -fsSL "$FREEDOS_USB" -o "${FREEDOS_CACHE}/freedos/FD14-FullUSB.zip" 2>/dev/null; then
                log "Extracting FreeDOS..."
                unzip -q -o "${FREEDOS_CACHE}/freedos/FD14-FullUSB.zip" -d "${FREEDOS_CACHE}/freedos/" 2>/dev/null || true
                
                # Find and extract the packages
                for img in "${FREEDOS_CACHE}/freedos/"*.img; do
                    [[ -f "$img" ]] || continue
                    log "Found disk image: $(basename "$img")"
                    # Mount and copy files (requires root)
                    MNT=$(mktemp -d)
                    if mount -o loop "$img" "$MNT" 2>/dev/null; then
                        cp -r "$MNT"/* "${DRIVE_C}/" 2>/dev/null || true
                        umount "$MNT"
                        rmdir "$MNT"
                        log "Extracted files from $(basename "$img")"
                    fi
                done
            else
                warn "Could not download USB image. Trying individual packages..."
                
                # Download essential packages individually
                PACKAGES=(
                    "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/kernel.zip"
                    "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/command.zip"
                    "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/edit.zip"
                    "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/himem.zip"
                    "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/format.zip"
                    "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/packages/base/sys.zip"
                )
                
                mkdir -p "${DRIVE_C}"/{BIN,SYS,DOS}
                
                for URL in "${PACKAGES[@]}"; do
                    PKG=$(basename "$URL")
                    log "  Downloading ${PKG}..."
                    curl -fsSL "$URL" -o "/tmp/${PKG}" 2>/dev/null
                    unzip -q -o "/tmp/${PKG}" -d "${DRIVE_C}" 2>/dev/null || true
                    rm -f "/tmp/${PKG}"
                done
            fi
            
            # Verify
            if check_kernel; then
                log "${GRN}FreeDOS installed successfully!${NC}"
            else
                warn "FreeDOS may not be fully installed."
                warn "dosemu2 will use its built-in DOS instead."
            fi
            ;;
        *)
            echo "Skipping FreeDOS download."
            echo "dosemu2 will use its built-in DOS."
            ;;
    esac
fi

echo ""
echo -e "${BLD}Configuration:${NC}"
echo "  C: drive = ${DRIVE_C}"
echo "  dosemu2 config = /home/${TARGET_USER}/.dosemu/dosemu.conf"
echo ""
echo -e "${BLD}To test:${NC}"
echo "  Run 'dos_launcher.sh' or click 'FreeDOS Shell' on the desktop"
echo ""
SETUP_SCRIPT
    chmod +x "$FREEDOS_SETUP"
    mark_done "phase16"
    log "dos_setup_freedos.sh installed."
fi

# =============================================================================
hdr "PHASE 17 — Power Menu Script (power-menu.sh) — NEW!"
# =============================================================================
# Graphical power menu for Shutdown/Reboot/Log Out/Lock

if is_done "phase17"; then
    log "SKIP: power-menu.sh (already done)"
else
    cat > "$POWER_MENU" << 'POWER_SCRIPT'
#!/bin/bash
# power-menu.sh — Graphical power menu using zenity
# Provides Shutdown, Reboot, Log Out, Lock Screen options

CHOICE=$(zenity --list --title="Power Menu" --text="What would you like to do?" \
    --column="Action" --column="Description" \
    "Shutdown" "Turn off the computer completely" \
    "Reboot" "Restart the computer" \
    "Log Out" "Exit to login screen" \
    "Lock Screen" "Lock the screen" \
    "Cancel" "Do nothing" \
    --height=320 --width=400 2>/dev/null)

case "$CHOICE" in
    "Shutdown")
        zenity --question --title="Confirm Shutdown" --text="Are you sure you want to shut down?" --default-cancel 2>/dev/null && \
        systemctl poweroff
        ;;
    "Reboot")
        zenity --question --title="Confirm Reboot" --text="Are you sure you want to restart?" --default-cancel 2>/dev/null && \
        systemctl reboot
        ;;
    "Log Out")
        i3-msg exit 2>/dev/null || pkill -u $USER
        ;;
    "Lock Screen")
        i3lock -c 1a1a2e 2>/dev/null || xlock 2>/dev/null || xscreensaver-command -lock 2>/dev/null
        ;;
    "Cancel"|"")
        exit 0
        ;;
esac
POWER_SCRIPT
    chmod +x "$POWER_MENU"
    
    # Allow shutdown/reboot without password for users in sudo group
    cat > /etc/sudoers.d/dos-power << 'SUDOERS'
# Allow users in sudo group to shutdown/reboot without password
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/shutdown, /usr/bin/systemctl poweroff, /usr/bin/systemctl reboot, /usr/bin/systemctl suspend
SUDOERS
    chmod 440 /etc/sudoers.d/dos-power
    
    mark_done "phase17"
    log "power-menu.sh installed."
fi

# =============================================================================
hdr "PHASE 18 — i3 Configuration"
# =============================================================================
sed -i '/^phase18$/d' "$STATE" 2>/dev/null || true

if is_done "phase18"; then
    log "SKIP: i3 config (already done)"
else
    mkdir -p "${I3_CFG}"

    mkdir -p "${TARGET_HOME}/.config/i3status"
    cat > "${TARGET_HOME}/.config/i3status/config" << 'I3STATUS'
general {
    colors = true
    interval = 5
    color_good     = "#00cc88"
    color_degraded = "#ffaa00"
    color_bad      = "#ff4444"
}

order += "disk /"
order += "memory"
order += "cpu_usage"
order += "tztime local"

disk "/" {
    format = "  %avail"
    low_threshold = 10
    threshold_type = gbytes_avail
}
memory {
    format = "  %used / %total"
    threshold_degraded = "10%"
}
cpu_usage {
    format = " CPU: %usage"
}
tztime local {
    format = " %d/%m/%Y  %H:%M"
}
I3STATUS

    if ! command -v j4-dmenu-desktop &>/dev/null; then
        if ! apt-get install -y j4-dmenu-desktop 2>/dev/null; then
            warn "j4-dmenu-desktop not in apt — building from source..."
            apt-get install -y cmake libxinerama-dev scdoc 2>/dev/null || true
            JTMP=$(mktemp -d)
            git clone --depth=1 https://github.com/enkore/j4-dmenu-desktop.git "$JTMP/j4"
            cmake -S "$JTMP/j4" -B "$JTMP/j4/build" -DWITH_TESTS=NO
            cmake --build "$JTMP/j4/build" -j"$(nproc)"
            install -m755 "$JTMP/j4/build/j4-dmenu-desktop" /usr/local/bin/
            rm -rf "$JTMP"
            log "j4-dmenu-desktop built from source."
        fi
    fi

    cat > "${I3_CFG}/config" << 'I3CONF'
# i3 window manager — DOS Desktop Environment
# XLibre/X11 native. No Wayland.

set $mod Mod4

font pango:DejaVu Sans 16

default_border pixel 3
default_floating_border pixel 2
hide_edge_borders smart

# ── Autostart ──────────────────────────────────────────────────────────────
exec --no-startup-id dbus-launch --sh-syntax --exit-with-session &
exec --no-startup-id dunst &
exec --no-startup-id feh --bg-fill ~/.config/i3/wallpaper.png 2>/dev/null \
     || xsetroot -solid "#0a0a1e"
exec --no-startup-id picom -b

# ── DOS window rules ───────────────────────────────────────────────────────
for_window [class="dosemu"]  floating enable, resize set 800 600, border pixel 2
for_window [class="Dosemu"]  floating enable, resize set 800 600, border pixel 2
for_window [class="dosemu2"] floating enable, resize set 800 600, border pixel 2

# ── Application Key bindings ───────────────────────────────────────────────
bindsym $mod+Return exec urxvt
bindsym $mod+e exec pcmanfm

bindsym $mod+space exec --no-startup-id \
    j4-dmenu-desktop --dmenu="dmenu -i -fn 'DejaVu Sans-16' -nb '#0a0a1e' -nf '#c0c0d0' -sb '#2a2a5e' -sf '#ffffff' -l 20 -p 'Launch:'"

bindsym $mod+d exec --no-startup-id dmenu_run \
    -fn 'DejaVu Sans-16' -nb '#0a0a1e' -nf '#c0c0d0' -sb '#2a2a5e' -sf '#ffffff'

bindsym $mod+F1 exec /usr/local/bin/dos_launcher.sh

# ── Power Menu Key bindings ────────────────────────────────────────────────
bindsym $mod+Escape exec /usr/local/bin/power-menu.sh
bindsym $mod+Shift+Delete exec systemctl poweroff
bindsym $mod+Ctrl+r exec systemctl reboot
bindsym $mod+Shift+l exec i3lock -c 0a0a1e 2>/dev/null || xlock

# ── Window Management ──────────────────────────────────────────────────────
bindsym $mod+q            kill
bindsym $mod+f            fullscreen toggle
bindsym $mod+Shift+space  floating toggle

bindsym $mod+h     focus left
bindsym $mod+j     focus down
bindsym $mod+k     focus up
bindsym $mod+l     focus right
bindsym $mod+Left  focus left
bindsym $mod+Down  focus down
bindsym $mod+Up    focus up
bindsym $mod+Right focus right

bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5

bindsym $mod+Shift+r restart
bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exec \
    "i3-nagbar -t warning -m 'Exit desktop?' -B 'Yes, exit' 'i3-msg exit'"

floating_modifier $mod

# ── Power Mode (Super+Pause) ───────────────────────────────────────────────
set $mode_power Power: (l)ock (e)xit (s)uspend (h)ibernate (r)eboot (p)oweroff
mode "$mode_power" {
    bindsym l exec --no-startup-id i3lock -c 0a0a1e, mode "default"
    bindsym e exec --no-startup-id i3-msg exit, mode "default"
    bindsym s exec --no-startup-id systemctl suspend, mode "default"
    bindsym h exec --no-startup-id systemctl hibernate, mode "default"
    bindsym r exec --no-startup-id systemctl reboot, mode "default"
    bindsym p exec --no-startup-id systemctl poweroff, mode "default"
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym $mod+Pause mode "$mode_power"

# ── Status Bar ─────────────────────────────────────────────────────────────
bar {
    status_command i3status --config ~/.config/i3status/config
    position bottom
    height 48
    font pango:DejaVu Sans 16

    # Left-click for launcher, right-click for power menu
    bindsym button1 exec --no-startup-id \
        j4-dmenu-desktop --dmenu="dmenu -i -fn 'DejaVu Sans-16' \
        -nb '#0a0a1e' -nf '#c0c0d0' -sb '#2a2a5e' -sf '#ffffff' -l 20 -p 'Launch:'"
    bindsym button3 exec /usr/local/bin/power-menu.sh

    colors {
        background         #0a0a1e
        statusline         #c0c0d0
        separator          #444466
        focused_workspace  #2a2a5e #2a2a5e #ffffff
        active_workspace   #1a1a3e #1a1a3e #aaaacc
        inactive_workspace #0a0a1e #0a0a1e #888899
        urgent_workspace   #8b0000 #8b0000 #ffffff
        binding_mode       #3a6e3a #3a6e3a #ffffff
    }
}
I3CONF

    chown -R "${TARGET_USER}:${TARGET_USER}" "${I3_CFG}"
    chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config/i3status"
    mark_done "phase18"
    log "i3 configured."
fi

# =============================================================================
hdr "PHASE 19 — .xinitrc"
# =============================================================================
if is_done "phase19"; then
    log "SKIP: .xinitrc (already done)"
else
    cat > "${TARGET_HOME}/.xinitrc" << 'XINITRC'
#!/bin/bash
xrdb -merge << 'XRESOURCES'
Xft.dpi: 96
URxvt.font:        xft:Terminus:size=11
URxvt.scrollBar:   false
URxvt.background:  #0a0a1e
URxvt.foreground:  #c0c0d0
URxvt.cursorColor: #00cc88
XRESOURCES
pcmanfm --desktop &
exec i3
XINITRC
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.xinitrc"
    mark_done "phase19"
    log ".xinitrc written."
fi

# =============================================================================
hdr "PHASE 20 — Auto-login (tty1) + Auto-startx"
# =============================================================================
if is_done "phase20"; then
    log "SKIP: Auto-login (already done)"
else
    mkdir -p /etc/systemd/system/getty@tty1.service.d/
    cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${TARGET_USER} --noclear %I \$TERM
EOF
    BASH_PROFILE="${TARGET_HOME}/.bash_profile"
    if ! grep -q "startx" "$BASH_PROFILE" 2>/dev/null; then
        cat >> "$BASH_PROFILE" << 'PROFILE'

if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx 2>/tmp/startx.log
fi
PROFILE
    fi
    chown "${TARGET_USER}:${TARGET_USER}" "$BASH_PROFILE"
    systemctl daemon-reload
    mark_done "phase20"
    log "Auto-login + auto-startx configured."
fi

# =============================================================================
hdr "PHASE 21 — Desktop Shortcuts"
# =============================================================================
sed -i '/^phase21$/d' "$STATE" 2>/dev/null || true

if is_done "phase21"; then
    log "SKIP: Desktop shortcuts (already done)"
else
    mkdir -p "${APPS_DIR}" "${DESKTOP}"

    write_desktop() {
        local FILE="$1" NAME="$2" COMMENT="$3" EXEC="$4"
        local ICON="${5:-application-x-executable}"
        local CATS="${6:-Application;}"

        cat > "$FILE" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${NAME}
Comment=${COMMENT}
Exec=${EXEC}
Icon=${ICON}
Terminal=false
Categories=${CATS}
StartupNotify=true
EOF
        chmod +x "$FILE"
    }

    # ── FreeDOS Shell ───────────────────────────────────────────────────────
    write_desktop \
        "${DESKTOP}/DOS-Prompt.desktop" \
        "FreeDOS Shell" \
        "Open an interactive FreeDOS prompt" \
        "/usr/local/bin/dos_launcher.sh" \
        "utilities-terminal" \
        "System;"

    # ── Get DOS Apps (NEW!) ──────────────────────────────────────────────────
    write_desktop \
        "${DESKTOP}/Get-DOS-Apps.desktop" \
        "Get DOS Apps" \
        "Download DOS games and utilities from archive.org" \
        "/usr/local/bin/dos_fetch_apps.sh" \
        "system-software-install" \
        "System;"

    # ── Setup FreeDOS (NEW!) ─────────────────────────────────────────────────
    write_desktop \
        "${DESKTOP}/Setup-FreeDOS.desktop" \
        "Setup FreeDOS" \
        "Install or repair FreeDOS system files" \
        "urxvt -e sudo /usr/local/bin/dos_setup_freedos.sh" \
        "system-software-update" \
        "System;"

    # ── Scan D: drive ───────────────────────────────────────────────────────
    write_desktop \
        "${DESKTOP}/Scan-D-Drive.desktop" \
        "Scan D: for DOS Apps" \
        "Auto-detect executables on D: drive and create desktop shortcuts" \
        "/usr/local/bin/dos_scan_apps.sh" \
        "system-search" \
        "System;"

    # ── File Manager ────────────────────────────────────────────────────────
    write_desktop \
        "${DESKTOP}/FileManager.desktop" \
        "File Manager" \
        "Browse D: drive files" \
        "pcmanfm ${DRIVE_D}" \
        "system-file-manager" \
        "System;"

    # ── Terminal ────────────────────────────────────────────────────────────
    write_desktop \
        "${DESKTOP}/Terminal.desktop" \
        "Terminal" \
        "Open a Linux terminal" \
        "urxvt" \
        "utilities-terminal" \
        "System;"

    # ── Power Menu (NEW!) ───────────────────────────────────────────────────
    write_desktop \
        "${DESKTOP}/Power-Menu.desktop" \
        "Power Menu" \
        "Shutdown, Reboot, Log Out, Lock Screen" \
        "/usr/local/bin/power-menu.sh" \
        "system-shutdown" \
        "System;"

    # ── Shutdown (NEW!) ─────────────────────────────────────────────────────
    write_desktop \
        "${DESKTOP}/Shutdown.desktop" \
        "Shutdown" \
        "Turn off the computer" \
        "systemctl poweroff" \
        "system-shutdown" \
        "System;"

    # ── Reboot (NEW!) ───────────────────────────────────────────────────────
    write_desktop \
        "${DESKTOP}/Reboot.desktop" \
        "Reboot" \
        "Restart the computer" \
        "systemctl reboot" \
        "system-reboot" \
        "System;"

    # ── Classic DOS app placeholders ────────────────────────────────────────
    declare -A CLASSIC_APPS=(
        ["Norton Commander"]="D:\\\\UTILS\\\\NC\\\\NC.EXE"
        ["Prince of Persia"]="D:\\\\GAMES\\\\PRINCE\\\\PRINCE.EXE"
        ["Turbo C++"]="D:\\\\BORLAND\\\\TC.EXE"
        ["Borland Pascal"]="D:\\\\BP\\\\BP.EXE"
        ["WordPerfect 6"]="D:\\\\WP\\\\WP.EXE"
        ["Lotus 1-2-3"]="D:\\\\123\\\\123.EXE"
        ["QBasic"]="D:\\\\UTILS\\\\QBASIC.EXE"
        ["DOS Edit"]="D:\\\\UTILS\\\\EDIT.COM"
    )
    for APP_NAME in "${!CLASSIC_APPS[@]}"; do
        EXE="${CLASSIC_APPS[$APP_NAME]}"
        SAFE=$(echo "$APP_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
        DFILE="${DESKTOP}/dos-${SAFE}.desktop"
        write_desktop \
            "$DFILE" \
            "$APP_NAME" \
            "DOS Application - ${EXE}" \
            "/usr/local/bin/dos_launcher.sh ${EXE} ${APP_NAME}" \
            "application-x-executable" \
            "Application;DOSApplication;"
        cp "$DFILE" "${APPS_DIR}/dos-${SAFE}.desktop"
    done

    for F in DOS-Prompt Get-DOS-Apps Setup-FreeDOS Scan-D-Drive FileManager Terminal; do
        SRC="${DESKTOP}/${F}.desktop"
        [[ -f "$SRC" ]] && cp "$SRC" "${APPS_DIR}/${F}.desktop" || true
    done

    # Set ownership BEFORE trust (required for gio to work)
    chown -R "${TARGET_USER}:${TARGET_USER}" "${APPS_DIR}" "${DESKTOP}"
    
    # Mark all desktop files as trusted (PCManFM requirement)
    # This must happen AFTER chown for gio to work properly
    for DFILE in "${DESKTOP}"/*.desktop "${APPS_DIR}"/*.desktop; do
        [[ -f "$DFILE" ]] || continue
        chmod +x "$DFILE"
        if command -v gio &>/dev/null; then
            su -s /bin/bash "${TARGET_USER}" -c \
                "gio set '${DFILE}' metadata::trusted true" 2>/dev/null || true
        fi
    done
    
    update-desktop-database "${APPS_DIR}" 2>/dev/null || true

    mark_done "phase21"
    log "Desktop shortcuts written and trusted."
fi

# =============================================================================
hdr "PHASE 22 — Final permissions"
# =============================================================================
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}"
chown -R "${TARGET_USER}:${TARGET_USER}" "${DOS_ROOT}"
log "Permissions set."

# =============================================================================
hdr "DONE"
# =============================================================================
DISPLAY_SERVER=$(load_val DISPLAY_SERVER); DISPLAY_SERVER="${DISPLAY_SERVER:-unknown}"

echo ""
echo -e "${BLD}${GRN}══ Phase completion status ══${NC}"
for P in phase{1..22}; do
    is_done "$P" \\
        && echo -e "  ${GRN}✓${NC} ${P}" \\
        || echo -e "  ${RED}✗${NC} ${P}  ← INCOMPLETE"
done

echo ""
echo -e "${BLD}${GRN}══ DOS Desktop Environment v8 ══${NC}"
echo ""
echo -e "  Display server  :  ${BLD}${DISPLAY_SERVER}${NC}"
echo -e "  C: drive        :  ${DRIVE_C} (FreeDOS system)"
echo -e "  D: drive        :  ${DRIVE_D} (Applications)"
echo -e "  FreeDOS cache   :  ${FREEDOS_CACHE}"
echo -e "  dosemu config   :  ${DOSEMU_CFG}/dosemu.conf"
echo ""
echo -e "  ${YLW}v8 Features:${NC}"
echo "    - FreeDOS base system + utilities downloaded"
echo "    - Power Menu for Shutdown/Reboot/Log Out (NEW!)"
echo "    - Larger fonts (16pt) for better readability"
echo "    - Right-click status bar for power menu"
echo ""
echo -e "  ${BLD}Desktop Icons:${NC}"
echo "    FreeDOS Shell     → Interactive DOS prompt"
echo "    Get DOS Apps      → Download games/utilities"
echo "    Scan D: Drive     → Create shortcuts"
echo "    Power Menu        → Shutdown/Reboot/Log Out (NEW!)"
echo "    Shutdown          → Turn off computer (NEW!)"
echo "    Reboot            → Restart computer (NEW!)"
echo ""
echo -e "  ${BLD}Keyboard Shortcuts:${NC}"
echo "    Super+Space       → App launcher (dmenu)"
echo "    Super+F1          → FreeDOS Shell"
echo "    Super+Escape      → Power Menu (NEW!)"
echo "    Super+Pause       → Power mode"
echo "    Super+e           → File Manager"
echo "    Right-click bar   → Power Menu (NEW!)"
echo ""
echo -e "  ${BLD}CLI tools:${NC}"
echo "    dos_fetch_apps.sh        → Download DOS apps (menu-driven)"
echo "    dos_setup_freedos.sh     → Set up FreeDOS"
echo "    dos_scan_apps.sh         → Scan D:, build shortcuts"
echo "    dos_add_app.sh \"Name\" \"D:\\X.EXE\""
echo "    dos_launcher.sh \"D:\\X.EXE\""
echo "    power-menu.sh            → Graphical power menu (NEW!)"
echo ""
echo -e "  ${BLD}Download sources:${NC}"
echo "    archive.org/details/softwarelibrary_msdos_games"
echo "    archive.org/details/archiveutilities"
echo "    freedos.org/download"
echo "    ibiblio.org/pub/micro/pc-stuff/freedos/"
echo ""
if [[ "$DISPLAY_SERVER" == "xorg-emergency-fallback" ]]; then
    echo -e "  ${RED}WARNING: XLibre install failed — xserver-xorg in use.${NC}"
fi
echo ""
