#!/bin/bash
# =============================================================================
#  DOS DESKTOP ENVIRONMENT — INSTALL SCRIPT
#  Custom Debian distro base | XLibre X Server | i3-wm | dosemu2
#  Target: Headless Debian (Trixie/Bookworm) — bare VM or physical
#
#  Usage:  sudo bash install.sh
#  Note:   XLibre is the X server. Xorg used only if XLibre unavailable.
#          Wayland is never installed or used.
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YLW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
hdr()  { echo -e "\n${BLD}${CYN}══════ $1 ══════${NC}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root:  sudo bash install.sh"

# ── Determine target user ─────────────────────────────────────────────────────
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
    read -rp "Enter the username to configure this environment for: " TARGET_USER
fi
[[ -z "$TARGET_USER" ]] && err "No target user specified."
id "$TARGET_USER" &>/dev/null || err "User '$TARGET_USER' does not exist."
TARGET_HOME="/home/${TARGET_USER}"
log "Configuring for user: ${TARGET_USER} (home: ${TARGET_HOME})"

# ── Key paths ─────────────────────────────────────────────────────────────────
DOS_ROOT="${TARGET_HOME}/dos_env"
DRIVE_D="${DOS_ROOT}/drive_d"           # Shared D: across all instances
DOSEMU_CFG="${TARGET_HOME}/.dosemu"
I3_CFG="${TARGET_HOME}/.config/i3"
APPS_DIR="${TARGET_HOME}/.local/share/applications"
DESKTOP="${TARGET_HOME}/Desktop"
LAUNCHER="/usr/local/bin/dos_launcher.sh"
SCANNER="/usr/local/bin/dos_scan_apps.sh"
ADD_APP="/usr/local/bin/dos_add_app.sh"
IDENTIFY="/usr/local/bin/dos_identify.sh"
CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-trixie}")
DISPLAY_SERVER="unknown"

# =============================================================================
hdr "PHASE 1 — System Update"
# =============================================================================
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl gpg wget \
    lsb-release apt-transport-https \
    build-essential git nasm file python3 xxd \
    libdrm2 libdrm-common
log "Base system updated."

# =============================================================================
hdr "PHASE 2 — XLibre Repository Setup"
# =============================================================================
# XLibre is the X server of choice here (xorg.freedesktop.org fork, 2025).
# Wayland is explicitly NOT installed. No xwayland either.
# Repo: https://xlibre-deb.github.io/debian/

XLIBRE_KEYRING="/etc/apt/keyrings/xlibre-deb.asc"
XLIBRE_SOURCES="/etc/apt/sources.list.d/xlibre-deb.sources"

install -m 0755 -d /etc/apt/keyrings

if [[ ! -f "$XLIBRE_KEYRING" ]]; then
    log "Fetching XLibre signing key..."
    curl -fsSL https://xlibre-deb.github.io/key.asc | tee "$XLIBRE_KEYRING" > /dev/null
    chmod a+r "$XLIBRE_KEYRING"
fi

if [[ ! -f "$XLIBRE_SOURCES" ]]; then
    log "Adding XLibre apt source for Debian ${CODENAME}..."
    cat > "$XLIBRE_SOURCES" << EOF
Types: deb deb-src
URIs: https://xlibre-deb.github.io/debian/
Suites: ${CODENAME}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: ${XLIBRE_KEYRING}
EOF
fi

# Bookworm may need backports for newer libdrm
if [[ "$CODENAME" == "bookworm" ]]; then
    if [[ ! -f "/etc/apt/sources.list.d/bookworm-backports.list" ]]; then
        echo "deb http://deb.debian.org/debian bookworm-backports main contrib non-free" \
            > /etc/apt/sources.list.d/bookworm-backports.list
        log "Bookworm backports enabled (required for libdrm with XLibre)."
    fi
fi

apt-get update -qq
log "XLibre repository configured."

# =============================================================================
hdr "PHASE 3 — XLibre Installation"
# =============================================================================
# The 'xlibre' meta-package installs:
#   xserver-xlibre-core, xserver-xlibre-input-*, xserver-xlibre-video-*
# It REPLACES xserver-xorg-* packages entirely.
# NO Wayland, NO XWayland, NO Mutter, NO Weston is installed.

XLIBRE_PKGS=(
    xlibre
    xserver-xlibre-input-libinput
    x11-xserver-utils
    x11-utils
    xauth
    xinit
    dbus-x11
    libx11-6
    libxext6
    xmessage
)

if apt-get install -y --no-install-recommends "${XLIBRE_PKGS[@]}" 2>/dev/null; then
    log "XLibre installed successfully."
    DISPLAY_SERVER="xlibre"
else
    warn "XLibre packages unavailable for Debian ${CODENAME}."
    warn "Falling back to standard xserver-xorg. Replace with XLibre when available."
    apt-get install -y --no-install-recommends \
        xserver-xorg \
        xserver-xorg-core \
        xserver-xorg-input-libinput \
        x11-xserver-utils x11-utils xauth xinit dbus-x11 xmessage
    DISPLAY_SERVER="xorg-fallback"
fi

log "Display server: ${DISPLAY_SERVER}"

# =============================================================================
hdr "PHASE 4 — Window Manager: i3"
# =============================================================================
apt-get install -y --no-install-recommends \
    i3 \
    i3status \
    i3lock \
    dmenu \
    feh \
    picom \
    dunst \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-terminus
log "i3 window manager installed."

# =============================================================================
hdr "PHASE 5 — Terminal & Desktop Manager"
# =============================================================================
apt-get install -y --no-install-recommends \
    rxvt-unicode \
    pcmanfm \
    xdg-utils \
    desktop-file-utils \
    shared-mime-info
log "urxvt terminal and PCManFM desktop manager installed."

# =============================================================================
hdr "PHASE 6 — dosemu2"
# =============================================================================
install_dosemu2() {
    if apt-get install -y dosemu2 2>/dev/null; then
        log "dosemu2 installed from apt."; return 0
    fi
    if apt-get install -y -t "${CODENAME}-backports" dosemu2 2>/dev/null; then
        log "dosemu2 installed from backports."; return 0
    fi
    warn "Building dosemu2 from source..."
    apt-get install -y \
        autoconf automake libtool pkg-config cmake \
        libx11-dev libxext-dev libxt-dev \
        libslang2-dev libgpm-dev libbsd-dev \
        libsndfile1-dev libfluidsynth-dev \
        bison flex
    local TMP; TMP=$(mktemp -d)
    git clone --depth=1 https://github.com/stsp/dosemu2.git "$TMP/dosemu2"
    cd "$TMP/dosemu2"
    autoreconf -fi
    ./configure --prefix=/usr
    make -j"$(nproc)"
    make install
    cd /; rm -rf "$TMP"
    log "dosemu2 built from source."
}
install_dosemu2

# KVM group access for hardware-accelerated emulation
if getent group kvm &>/dev/null; then
    usermod -aG kvm "$TARGET_USER"
    log "${TARGET_USER} added to kvm group."
else
    warn "kvm group not found — dosemu2 will run in software mode."
fi

# =============================================================================
hdr "PHASE 7 — Shared D: Drive"
# =============================================================================
mkdir -p "${DRIVE_D}"/{APPS,GAMES,UTILS,WORK,DOCS}
mkdir -p "${DOS_ROOT}/drive_c_template"

cat > "${DRIVE_D}/README.TXT" << 'EOF'
D: DRIVE — SHARED DOS ENVIRONMENT
===================================
APPS\    General DOS applications
GAMES\   DOS games
UTILS\   Utilities (Norton Cmdr, etc.)
WORK\    User working files
DOCS\    Reference documentation

All dosemu2 instances share this drive.
Files placed here are visible from every open DOS window.
EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${DOS_ROOT}"
log "Shared D: drive created at ${DRIVE_D}"

# =============================================================================
hdr "PHASE 8 — dosemu2 Configuration"
# =============================================================================
mkdir -p "${DOSEMU_CFG}/drives/c"

cat > "${DOSEMU_CFG}/dosemu.conf" << EOF
# dosemu2 configuration — DOS Desktop Environment

# --- CPU ---
\$_cpu_emu = "vm86"
\$_dpmi    = 0x5000
\$_xms     = 8192
\$_ems     = 4096

# --- Display (XLibre/X11) ---
\$_X_font              = "vga"
\$_X_title             = "DOS"
\$_X_title_show_appname = (1)
\$_X_mgrab             = (0)    # No mouse grab — cursor moves freely
\$_X_fullscreen        = (0)

# --- Sound ---
\$_sound = (0)

# --- Misc ---
\$_hogthreshold = 1
\$_cli_timeout  = (1000)
EOF

cat > "${DOSEMU_CFG}/drives/c/autoexec.bat" << EOF
@ECHO OFF
PROMPT \$P\$G
PATH C:\\;D:\\UTILS

REM Mount shared Linux path as D:
LREDIR D: LINUX\\FS${DRIVE_D}

D:
ECHO.
ECHO FreeDOS Environment Ready
ECHO D: = ${DRIVE_D}
ECHO.
EOF

cat > "${DOSEMU_CFG}/drives/c/config.sys" << 'EOF'
DOS=HIGH,UMB
FILES=40
BUFFERS=20
EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${DOSEMU_CFG}"
log "dosemu2 configured."

# =============================================================================
hdr "PHASE 9 — Binary Format Identifier (dos_identify.sh)"
# =============================================================================
# Inspects magic bytes and header structures to classify legacy executables.
#
# Handled formats:
#   DOS MZ EXE       — 0x4D5A header, no PE/NE/LE extension → runnable
#   FreeDOS EXE      — same MZ format, fully compatible     → runnable
#   DOS COM          — raw x86 binary (no header)           → runnable (x86 only)
#   DOS BAT          — batch script                         → runnable
#   Windows PE32/64  — MZ + PE\0\0 sig @ e_lfanew           → BLOCKED
#   Win16 NE         — MZ + NE sig                          → BLOCKED
#   OS/2 LE/LX       — MZ + LE/LX sig                      → BLOCKED
#   CP/M-3 COM       — first byte 0xC9 + header marker     → BLOCKED (Z80/8080)
#   CP/M-80 COM      — 8080 bytecode, not x86              → BLOCKED
#
# Exit codes:  0=runnable  1=not runnable  2=ambiguous

cat > "$IDENTIFY" << 'IDENTIFY_EOF'
#!/bin/bash
# dos_identify.sh — Identify legacy executable binary format
# Usage: dos_identify.sh <filepath>
# stdout: human-readable format description
# exit 0: DOS-compatible (safe for dosemu2)
# exit 1: Not DOS-compatible
# exit 2: Ambiguous (raw COM — likely DOS but unverifiable)

FILE_PATH="$1"
[[ -z "$FILE_PATH" ]] && { echo "Usage: dos_identify.sh <file>"; exit 1; }
[[ ! -f "$FILE_PATH" ]] && { echo "ERROR: Not found: $FILE_PATH"; exit 1; }

BASENAME=$(basename "$FILE_PATH")
EXT=$(echo "${BASENAME##*.}" | tr '[:lower:]' '[:upper:]')
FILESIZE=$(stat -c%s "$FILE_PATH")

# Read magic bytes
read_hex() { xxd -p -s "$1" -l "$2" "$FILE_PATH" 2>/dev/null | tr '[:lower:]' '[:upper:]'; }
MAGIC2=$(read_hex 0 2)
MAGIC4=$(read_hex 0 4)

# Read DWORD at offset 0x3C (little-endian) → decimal offset to extended header
ext_header_offset() {
    local raw; raw=$(read_hex 60 4)
    [[ ${#raw} -lt 8 ]] && echo 0 && return
    local b1="${raw:0:2}" b2="${raw:2:2}" b3="${raw:4:2}" b4="${raw:6:2}"
    printf "%d" "0x${b4}${b3}${b2}${b1}" 2>/dev/null || echo 0
}

# ── BAT files ─────────────────────────────────────────────────────────────────
if [[ "$EXT" == "BAT" ]]; then
    echo "FORMAT: DOS/FreeDOS Batch Script — fully compatible"
    exit 0
fi

# ── MZ header (EXE and all derivatives) ──────────────────────────────────────
if [[ "$MAGIC2" == "4D5A" || "$MAGIC2" == "5A4D" ]]; then
    EXT_OFF=$(ext_header_offset)
    EXT_SIG=""
    if [[ $EXT_OFF -gt 63 && $EXT_OFF -lt $FILESIZE ]]; then
        EXT_SIG=$(read_hex "$EXT_OFF" 4)
    fi

    # Windows PE (32 or 64-bit) — NOT runnable in dosemu2
    if [[ "$EXT_SIG" == "50450000" ]]; then
        # Subsystem: PE_offset + COFF(20) + optional_magic(2) + skip_to_subsystem
        # IMAGE_OPTIONAL_HEADER.Subsystem is at offset 68 from optional header start
        # Optional header starts at PE_offset + 4 + 20 = PE_offset + 24
        SUBSYS_OFF=$(( EXT_OFF + 24 + 68 ))
        SUBSYS=$(read_hex "$SUBSYS_OFF" 2)
        # Check bitness: optional header magic at PE+24
        OPT_MAGIC=$(read_hex $(( EXT_OFF + 24 )) 2)
        BITS="32-bit"
        [[ "$OPT_MAGIC" == "0B02" ]] && BITS="64-bit"
        case "$SUBSYS" in
            "0200") echo "FORMAT: Windows PE ${BITS} GUI — NOT DOS-compatible (use Wine)"; exit 1 ;;
            "0300") echo "FORMAT: Windows PE ${BITS} Console — NOT DOS-compatible (use Wine)"; exit 1 ;;
            *)      echo "FORMAT: Windows PE ${BITS} [subsys=0x${SUBSYS}] — NOT DOS-compatible"; exit 1 ;;
        esac
    fi

    # NE — 16-bit Windows 3.x / OS/2 1.x
    if [[ "${EXT_SIG:0:4}" == "4E45" ]]; then
        echo "FORMAT: NE 16-bit Windows/OS2 executable — NOT directly DOS-runnable"
        echo "NOTE:   Some NE apps run under dosemu2 with DPMI; most do not"
        exit 1
    fi

    # LE/LX — 32-bit OS/2 or Windows 9x VxD
    if [[ "${EXT_SIG:0:4}" == "4C45" || "${EXT_SIG:0:4}" == "4C58" ]]; then
        echo "FORMAT: LE/LX OS/2 or Win9x VxD — NOT standard DOS-compatible"
        exit 1
    fi

    # Plain DOS MZ — no PE/NE/LE extension header → genuine DOS EXE
    echo "FORMAT: DOS MZ EXE — compatible with dosemu2 / FreeDOS / MS-DOS"
    exit 0
fi

# ── COM files — raw binary (DOS x86 or CP/M-80 8080) ─────────────────────────
if [[ "$EXT" == "COM" ]]; then
    BYTE0=$(read_hex 0 1)

    # CP/M-3 RSX header: first byte is 0xC9 (8080 RET — acts as self-terminating
    # stub on older CP/M versions). Byte 1 = 0x80 confirms RSX attribute flag.
    if [[ "$BYTE0" == "C9" ]]; then
        BYTE1=$(read_hex 1 1)
        if [[ "$BYTE1" == "80" || "$BYTE1" == "00" ]]; then
            echo "FORMAT: CP/M-3 COM (RSX extended header) — NOT x86 DOS compatible"
            echo "NOTE:   Contains 8080/Z80 machine code. Use RunCPM or similar."
            exit 1
        fi
    fi

    # Size limit: COM files are capped at 65,280 bytes (0xFF00)
    if [[ $FILESIZE -gt 65280 ]]; then
        echo "FORMAT: Oversized COM (${FILESIZE} bytes > 65280) — likely misnamed EXE or corrupt"
        exit 2
    fi

    # Common x86 DOS COM entry-point opcodes:
    #   0xE9 JMP near   0xEB JMP short   0xCD INT xx (syscall)
    #   0xB8 MOV AX     0xFA CLI         0xFC CLD
    #   0x33 XOR AX     0x8C MOV sreg    0x55 PUSH BP
    case "$BYTE0" in
        "E9"|"EB"|"B8"|"CD"|"FA"|"FC"|"33"|"8C"|"50"|"55"|"B4"|"31"|"F3")
            echo "FORMAT: DOS/FreeDOS COM — raw x86 binary, dosemu2-compatible"
            exit 0
            ;;
        *)
            echo "FORMAT: COM file (first byte=0x${BYTE0}) — probable DOS x86, verify manually"
            echo "NOTE:   Could be CP/M-80 (8080 code). If it crashes dosemu2, it is 8080-only."
            exit 2
            ;;
    esac
fi

# ── Unknown ───────────────────────────────────────────────────────────────────
echo "FORMAT: Unknown (ext=${EXT}, magic=${MAGIC4}, size=${FILESIZE})"
echo "NOTE:   Run 'file ${FILE_PATH}' for more detail."
exit 2
IDENTIFY_EOF

chmod +x "$IDENTIFY"
log "Binary format identifier installed at ${IDENTIFY}"

# =============================================================================
hdr "PHASE 10 — Universal DOS Launcher"
# =============================================================================
cat > "$LAUNCHER" << LAUNCHER_EOF
#!/bin/bash
# dos_launcher.sh — Launch a DOS application in a new XLibre/X11 window
# Usage: dos_launcher.sh [EXE_PATH] [Window Title]
#   EXE_PATH can be:
#     a DOS path  →  "D:\\APPS\\APP.EXE"
#     a Linux path → /home/user/dos_env/drive_d/APPS/APP.EXE (auto-converted)
#     empty       → opens interactive FreeDOS shell

EXE_PATH="\${1:-}"
WIN_TITLE="\${2:-DOS}"
DRIVE_D="${DRIVE_D}"

# If a Linux filesystem path was given, identify and convert to DOS D: path
if [[ -n "\$EXE_PATH" && -f "\$EXE_PATH" ]]; then
    IDENT=\$("${IDENTIFY}" "\$EXE_PATH" 2>&1)
    ECODE=\$?
    if [[ \$ECODE -eq 1 ]]; then
        xmessage -center "Cannot launch in DOS:\\n\\n\${IDENT}\\n\\nFile: \${EXE_PATH}" 2>/dev/null \
          || urxvt -e bash -c "echo 'Not DOS-compatible:'; echo '\$IDENT'; read -p 'Press Enter...'"
        exit 1
    fi
    # Convert Linux path to DOS D: relative path
    if [[ "\$EXE_PATH" == \${DRIVE_D}* ]]; then
        REL="\${EXE_PATH#\${DRIVE_D}/}"
        EXE_PATH="D:\\\\\$(echo "\$REL" | tr '/' '\\\\')"
    fi
fi

# No path: interactive FreeDOS shell
if [[ -z "\$EXE_PATH" ]]; then
    exec dosemu -X -title "FreeDOS Shell"
fi

# Launch app: mount D:, change to it, run the exe
CMD="lredir d: linux\\\\fs\${DRIVE_D}; d:; \${EXE_PATH}"
exec dosemu -X -title "\${WIN_TITLE}" -E "\${CMD}"
LAUNCHER_EOF

chmod +x "$LAUNCHER"
log "Launcher installed at ${LAUNCHER}"

# =============================================================================
hdr "PHASE 11 — dos_add_app.sh"
# =============================================================================
cat > "$ADD_APP" << 'ADDAPP_EOF'
#!/bin/bash
# dos_add_app.sh — Create a desktop shortcut for a DOS application
# Usage: dos_add_app.sh "App Name" "D:\\PATH\\APP.EXE" [/path/to/icon]

APP_NAME="$1"
EXE_INPUT="$2"
ICON="${3:-application-x-executable}"
[[ -z "$APP_NAME" || -z "$EXE_INPUT" ]] && {
    echo "Usage: dos_add_app.sh \"App Name\" \"D:\\PATH\\APP.EXE\" [icon]"
    exit 1
}

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
DRIVE_D="/home/${TARGET_USER}/dos_env/drive_d"
APPS_DIR="/home/${TARGET_USER}/.local/share/applications"
DESKTOP_DIR="/home/${TARGET_USER}/Desktop"
SAFE=$(echo "$APP_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
mkdir -p "$APPS_DIR" "$DESKTOP_DIR"

EXE_DOS="$EXE_INPUT"
IDENT_MSG=""

# If Linux path given: identify + convert to DOS path
if [[ -f "$EXE_INPUT" ]]; then
    IDENT_MSG=$(/usr/local/bin/dos_identify.sh "$EXE_INPUT" 2>&1)
    ECODE=$?
    [[ $ECODE -eq 1 ]] && echo "WARNING: ${APP_NAME}: ${IDENT_MSG}"
    if [[ "$EXE_INPUT" == "${DRIVE_D}"* ]]; then
        REL="${EXE_INPUT#${DRIVE_D}/}"
        EXE_DOS="D:\\$(echo "$REL" | tr '/' '\\')"
    fi
fi

DFILE="${APPS_DIR}/dos-${SAFE}.desktop"
cat > "$DFILE" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${APP_NAME}
Comment=DOS App — ${EXE_DOS}
Exec=/usr/local/bin/dos_launcher.sh "${EXE_DOS}" "${APP_NAME}"
Icon=${ICON}
Terminal=false
Categories=Application;DOSApplication;
EOF

chmod +x "$DFILE"
ln -sf "$DFILE" "${DESKTOP_DIR}/dos-${SAFE}.desktop"
chown "${TARGET_USER}:${TARGET_USER}" "$DFILE"
echo "Shortcut created: ${APP_NAME} → ${EXE_DOS}"
[[ -n "$IDENT_MSG" ]] && echo "  Format: ${IDENT_MSG}"
ADDAPP_EOF

chmod +x "$ADD_APP"
log "dos_add_app.sh installed."

# =============================================================================
hdr "PHASE 12 — dos_scan_apps.sh"
# =============================================================================
cat > "$SCANNER" << SCANNER_EOF
#!/bin/bash
# dos_scan_apps.sh — Scan D: drive, identify all executables, create shortcuts
# Skips Windows PE, CP/M-80, and other non-DOS-runnable formats.
# Creates shortcuts for DOS MZ, COM, and BAT files.

TARGET_USER="\${SUDO_USER:-\$(logname 2>/dev/null || whoami)}"
DRIVE_D="/home/\${TARGET_USER}/dos_env/drive_d"

echo ""
echo "══ Scanning \${DRIVE_D} ══"
echo ""

DOS_OK=0; WIN_SKIP=0; CPM_SKIP=0; AMBIGUOUS=0; TOTAL=0

while IFS= read -r -d '' FILEPATH; do
    TOTAL=\$((TOTAL+1))
    BNAME=\$(basename "\$FILEPATH")
    APPNAME="\${BNAME%.*}"
    IDENT=\$(/usr/local/bin/dos_identify.sh "\$FILEPATH" 2>&1)
    ECODE=\$?

    case \$ECODE in
        0)
            /usr/local/bin/dos_add_app.sh "\$APPNAME" "\$FILEPATH" >/dev/null
            printf "  %-30s  ✓  %s\n" "\$BNAME" "\$IDENT"
            DOS_OK=\$((DOS_OK+1))
            ;;
        1)
            printf "  %-30s  ✗  %s\n" "\$BNAME" "\$IDENT"
            echo "\$IDENT" | grep -qi "CP/M\|8080\|Z80" \
                && CPM_SKIP=\$((CPM_SKIP+1)) \
                || WIN_SKIP=\$((WIN_SKIP+1))
            ;;
        2)
            /usr/local/bin/dos_add_app.sh "\$APPNAME" "\$FILEPATH" >/dev/null
            printf "  %-30s  ?  %s\n" "\$BNAME" "\$IDENT"
            AMBIGUOUS=\$((AMBIGUOUS+1))
            ;;
    esac

done < <(find "\$DRIVE_D" -maxdepth 4 \
    \( -iname "*.exe" -o -iname "*.com" -o -iname "*.bat" \) -print0)

echo ""
echo "══ Results ══"
printf "  Total scanned       : %d\n" "\$TOTAL"
printf "  Shortcuts created   : %d\n" "\$((DOS_OK + AMBIGUOUS))"
printf "  DOS/FreeDOS         : %d\n" "\$DOS_OK"
printf "  Ambiguous (COM)     : %d\n" "\$AMBIGUOUS"
printf "  Skipped (Windows)   : %d\n" "\$WIN_SKIP"
printf "  Skipped (CP/M-80)   : %d\n" "\$CPM_SKIP"
echo ""
[[ \$WIN_SKIP -gt 0 ]]  && echo "  Windows PE files require Wine or a VM, not dosemu2."
[[ \$CPM_SKIP -gt 0 ]]  && echo "  CP/M-80 files need a Z80/8080 emulator (RunCPM, MAME etc.)."
echo ""
SCANNER_EOF

chmod +x "$SCANNER"
log "dos_scan_apps.sh installed."

# =============================================================================
hdr "PHASE 13 — i3 Configuration"
# =============================================================================
mkdir -p "${I3_CFG}"

cat > "${I3_CFG}/config" << 'I3EOF'
# i3 window manager config — DOS Desktop Environment
# X11/XLibre native. No Wayland.

set $mod Mod4

font pango:DejaVu Sans Mono 10

default_border pixel 2
default_floating_border pixel 2
hide_edge_borders smart

# ── Autostart ─────────────────────────────────────────────────────────────────
exec --no-startup-id dbus-launch --sh-syntax --exit-with-session &
exec --no-startup-id dunst &
exec --no-startup-id feh --bg-fill ~/.config/i3/wallpaper.png 2>/dev/null || xsetroot -solid "#0a0a1e"
exec --no-startup-id picom -b

# ── DOS windows: float by default, 800×600 ────────────────────────────────────
for_window [class="dosemu"]  floating enable, resize set 800 600, border pixel 2
for_window [class="Dosemu"]  floating enable, resize set 800 600, border pixel 2
for_window [class="dosemu2"] floating enable, resize set 800 600, border pixel 2

# ── Key bindings ──────────────────────────────────────────────────────────────
bindsym $mod+Return       exec urxvt
bindsym $mod+F1           exec /usr/local/bin/dos_launcher.sh
bindsym $mod+d            exec --no-startup-id dmenu_run
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
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4

bindsym $mod+Shift+r restart
bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit?' -B 'Yes' 'i3-msg exit'"

floating_modifier $mod

bar {
    status_command i3status
    position bottom
    colors {
        background #0a0a1e
        statusline #c0c0d0
        separator  #444466
        focused_workspace   #2a2a5e #2a2a5e #ffffff
        active_workspace    #1a1a3e #1a1a3e #aaaacc
        inactive_workspace  #0a0a1e #0a0a1e #666688
        urgent_workspace    #8b0000 #8b0000 #ffffff
    }
}
I3EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${I3_CFG}"
log "i3 configured."

# =============================================================================
hdr "PHASE 14 — .xinitrc"
# =============================================================================
cat > "${TARGET_HOME}/.xinitrc" << 'XINITRC_EOF'
#!/bin/bash
# .xinitrc — XLibre/X11 session startup
# PCManFM handles the desktop (double-click .desktop files)
# i3 is the window manager

xrdb -merge << 'XRESOURCES'
Xft.dpi: 96
URxvt.font:       xft:Terminus:size=11
URxvt.scrollBar:  false
URxvt.background: #0a0a1e
URxvt.foreground: #c0c0d0
URxvt.cursorColor: #00cc88
XRESOURCES

pcmanfm --desktop &
exec i3
XINITRC_EOF

chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.xinitrc"
log ".xinitrc written."

# =============================================================================
hdr "PHASE 15 — Auto-login (tty1) + Auto-startx"
# =============================================================================
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${TARGET_USER} --noclear %I \$TERM
EOF

BASH_PROFILE="${TARGET_HOME}/.bash_profile"
if ! grep -q "startx" "$BASH_PROFILE" 2>/dev/null; then
    cat >> "$BASH_PROFILE" << 'PROFILE_EOF'

# Auto-start XLibre/X11 desktop when logging in on tty1
if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx 2>/tmp/startx.log
fi
PROFILE_EOF
fi

chown "${TARGET_USER}:${TARGET_USER}" "$BASH_PROFILE"
systemctl daemon-reload
log "Auto-login and auto-startx configured."

# =============================================================================
hdr "PHASE 16 — Desktop Shortcuts"
# =============================================================================
mkdir -p "${APPS_DIR}" "${DESKTOP}"

cat > "${DESKTOP}/DOS-Prompt.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=FreeDOS Shell
Comment=Interactive FreeDOS prompt
Exec=/usr/local/bin/dos_launcher.sh
Icon=utilities-terminal
Terminal=false
Categories=System;
EOF
chmod +x "${DESKTOP}/DOS-Prompt.desktop"

cat > "${DESKTOP}/Scan-D-Drive.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Scan D: for DOS Apps
Comment=Auto-detect and create shortcuts for all DOS apps on D:
Exec=urxvt -e bash -c "sudo ${SCANNER}; read -p 'Done. Press Enter...'"
Icon=system-search
Terminal=false
Categories=System;
EOF
chmod +x "${DESKTOP}/Scan-D-Drive.desktop"

# Classic DOS app placeholders
declare -A CLASSIC_APPS=(
    ["Norton Commander"]="D:\\UTILS\\NC.EXE"
    ["Turbo C++"]="D:\\BORLAND\\TC.EXE"
    ["Borland Pascal"]="D:\\BP\\BP.EXE"
    ["WordPerfect 6"]="D:\\WP\\WP.EXE"
    ["Lotus 1-2-3"]="D:\\123\\123.EXE"
    ["QBasic"]="D:\\UTILS\\QBASIC.EXE"
    ["DOS Edit"]="D:\\UTILS\\EDIT.COM"
    ["AutoCAD R12"]="D:\\ACAD\\ACAD.EXE"
)
for APP_NAME in "${!CLASSIC_APPS[@]}"; do
    EXE="${CLASSIC_APPS[$APP_NAME]}"
    SAFE=$(echo "$APP_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    cat > "${DESKTOP}/dos-${SAFE}.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${APP_NAME}
Comment=Place EXE at ${EXE} on D: drive
Exec=/usr/local/bin/dos_launcher.sh "${EXE}" "${APP_NAME}"
Icon=application-x-executable
Terminal=false
Categories=Application;DOSApplication;
EOF
    chmod +x "${DESKTOP}/dos-${SAFE}.desktop"
done

chown -R "${TARGET_USER}:${TARGET_USER}" "${APPS_DIR}" "${DESKTOP}"
update-desktop-database "${APPS_DIR}" 2>/dev/null || true
log "Desktop shortcuts created."

# =============================================================================
hdr "PHASE 17 — Final Permissions"
# =============================================================================
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}"

# =============================================================================
hdr "INSTALLATION COMPLETE"
# =============================================================================
echo ""
echo -e "${BLD}${GRN}══ DOS Desktop Environment installed ══${NC}"
echo ""
echo -e "  Display server:   ${BLD}${DISPLAY_SERVER}${NC}"
echo -e "  D: drive:         ${DRIVE_D}"
echo -e "  dosemu config:    ${DOSEMU_CFG}/dosemu.conf"
echo ""
echo -e "${YLW}  Reboot to auto-start the XLibre desktop.${NC}"
echo "  (tty1 autologin → startx → XLibre → i3 → PCManFM desktop)"
echo ""
echo -e "  ${BLD}Keyboard shortcuts (in i3):${NC}"
echo "    Super+F1          → Interactive FreeDOS shell"
echo "    Super+Return      → Terminal (urxvt)"
echo "    Super+d           → App launcher (dmenu)"
echo "    Double-click icon → Launch DOS app"
echo ""
echo -e "  ${BLD}CLI tools:${NC}"
echo "    dos_identify.sh <file>           → Detect binary format"
echo "    dos_scan_apps.sh                 → Scan D:, auto-create shortcuts"
echo "    dos_add_app.sh \"Name\" \"D:\\X.EXE\" → Add single shortcut"
echo "    dos_launcher.sh \"D:\\X.EXE\"       → Launch directly"
echo ""
echo -e "  ${BLD}Binary classifier output:${NC}"
echo "    ✓  DOS MZ EXE          → dosemu2"
echo "    ✓  FreeDOS EXE (MZ)    → dosemu2"
echo "    ✓  DOS/FreeDOS COM     → dosemu2"
echo "    ✓  DOS Batch .BAT      → dosemu2"
echo "    ✗  Windows PE 32/64    → blocked (suggest Wine)"
echo "    ✗  Win16 NE            → blocked"
echo "    ✗  OS/2 LE/LX          → blocked"
echo "    ✗  CP/M-3 RSX COM      → blocked (needs Z80 emulator)"
echo "    ?  Raw COM (unverified) → shortcut with caveat"
echo ""
if [[ "$DISPLAY_SERVER" == "xorg-fallback" ]]; then
    echo -e "  ${YLW}NOTE: XLibre not yet packaged for Debian ${CODENAME}.${NC}"
    echo "  xserver-xorg used as fallback. Once XLibre packages are available:"
    echo "    apt install xlibre"
    echo "  The rest of the system is XLibre-ready and will switch transparently."
fi
echo ""
