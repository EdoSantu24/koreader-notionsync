#!/bin/bash
set -e

# Common Style Configs
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Nerd Font icons
ICON_ROCKET=" "
ICON_CHECK=" "
ICON_CROSS=" "
ICON_FOLDER=" "
ICON_FILE=" "
ICON_SYNC=" "
ICON_WARN=" "
ICON_SUCCESS="󰩍 "

# Set your device mount path here or via environment variable.
# KOBO_MOUNT_PATH is accepted as a legacy alias.
DEVICE_MOUNT_PATH="${DEVICE_MOUNT_PATH:-${KOBO_MOUNT_PATH:-}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$DEVICE_MOUNT_PATH" ]; then
    cat << "EOF"

╔═══════════════════════════════════════════════════════════╗
║                   Configuration Required                  ║
╚═══════════════════════════════════════════════════════════╝

EOF
    echo -e "${RED}${ICON_CROSS}${BOLD}Error:${RESET} DEVICE_MOUNT_PATH is not set"
    echo ""
    echo -e "${YELLOW}${ICON_WARN}Please set the DEVICE_MOUNT_PATH environment variable:${RESET}"
    echo ""
    echo -e "  ${CYAN}# Bash/Zsh - For current session:${RESET}"
    echo -e "  ${DIM}export DEVICE_MOUNT_PATH=\"/path/to/your/ereader\"${RESET}"
    echo ""
    echo -e "  ${CYAN}# Bash/Zsh - Add to shell config (~/.bashrc, ~/.zshrc):${RESET}"
    echo -e "  ${DIM}echo 'export DEVICE_MOUNT_PATH=\"/path/to/your/ereader\"' >> ~/.bashrc${RESET}"
    echo ""
    echo -e "  ${CYAN}# Fish - For current session:${RESET}"
    echo -e "  ${DIM}set -x DEVICE_MOUNT_PATH \"/path/to/your/ereader\"${RESET}"
    echo ""
    echo -e "  ${CYAN}# Fish - Add to config (~/.config/fish/config.fish):${RESET}"
    echo -e "  ${DIM}echo 'set -x DEVICE_MOUNT_PATH \"/path/to/your/ereader\"' >> ~/.config/fish/config.fish${RESET}"
    echo ""
    echo -e "${DIM}Example paths:${RESET}"
    echo -e "${DIM}  Kindle, Linux:   /run/media/\$USER/Kindle${RESET}"
    echo -e "${DIM}  Kindle, macOS:   /Volumes/Kindle${RESET}"
    echo -e "${DIM}  Kobo,   Linux:   /run/media/\$USER/KOBOeReader${RESET}"
    echo -e "${DIM}  Kobo,   macOS:   /Volumes/KOBOeReader${RESET}"
    echo -e "${DIM}  Windows (WSL):   /mnt/d/${RESET}"
    echo ""
    exit 1
fi
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║   ███╗   ██╗ ██████╗ ████████╗██╗ ██████╗ ███╗   ██╗      ║
║   ████╗  ██║██╔═══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║      ║
║   ██╔██╗ ██║██║   ██║   ██║   ██║██║   ██║██╔██╗ ██║      ║
║   ██║╚██╗██║██║   ██║   ██║   ██║██║   ██║██║╚██╗██║      ║
║   ██║ ╚████║╚██████╔╝   ██║   ██║╚██████╔╝██║ ╚████║      ║
║   ╚═╝  ╚═══╝ ╚═════╝    ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝      ║
║                                                           ║
║   ███████╗██╗   ██╗███╗   ██╗ ██████╗                     ║
║   ██╔════╝╚██╗ ██╔╝████╗  ██║██╔════╝                     ║
║   ███████╗ ╚████╔╝ ██╔██╗ ██║██║                          ║
║   ╚════██║  ╚██╔╝  ██║╚██╗██║██║                          ║
║   ███████║   ██║   ██║ ╚████║╚██████╗                     ║
║   ╚══════╝   ╚═╝   ╚═╝  ╚═══╝ ╚═════╝                     ║
║                                                           ║
║                  Plugin Deployer                          ║
╚═══════════════════════════════════════════════════════════╝
EOF

echo ""
echo -e "${CYAN}${ICON_ROCKET}${BOLD}Deploying notionsync.koplugin...${RESET}"
echo ""

if [ ! -d "$DEVICE_MOUNT_PATH" ]; then
    echo -e "${RED}${ICON_CROSS}${BOLD}Error:${RESET} Device not found at ${YELLOW}$DEVICE_MOUNT_PATH${RESET}"
    echo -e "${DIM}        Please ensure your eReader is connected and mounted.${RESET}"
    exit 1
fi

echo -e "${GREEN}${ICON_CHECK}Device detected at ${CYAN}$DEVICE_MOUNT_PATH${RESET}"

# KOReader lives in a different place depending on the device:
#   Kobo   -> <mount>/.adds/koreader
#   Kindle -> <mount>/koreader
# Detect rather than assume, so one script covers both.
if [ -d "$DEVICE_MOUNT_PATH/.adds/koreader/plugins" ]; then
    KOREADER_DIR="$DEVICE_MOUNT_PATH/.adds/koreader"
    DEVICE_KIND="Kobo"
elif [ -d "$DEVICE_MOUNT_PATH/koreader/plugins" ]; then
    KOREADER_DIR="$DEVICE_MOUNT_PATH/koreader"
    DEVICE_KIND="Kindle"
else
    echo -e "${RED}${ICON_CROSS}${BOLD}Error:${RESET} KOReader plugins directory not found"
    echo -e "${DIM}        Looked for:${RESET}"
    echo -e "${DIM}          $DEVICE_MOUNT_PATH/.adds/koreader/plugins  (Kobo)${RESET}"
    echo -e "${DIM}          $DEVICE_MOUNT_PATH/koreader/plugins        (Kindle)${RESET}"
    echo -e "${DIM}        Please ensure KOReader is installed on your device.${RESET}"
    exit 1
fi

PLUGINS_DIR="$KOREADER_DIR/plugins"
PLUGIN_DEST="$PLUGINS_DIR/notionsync.koplugin"

echo -e "${GREEN}${ICON_CHECK}KOReader ($DEVICE_KIND layout) verified at ${CYAN}$KOREADER_DIR${RESET}"
echo ""

if [ -d "$PLUGIN_DEST" ]; then
    echo -e "${YELLOW}${ICON_FOLDER}Removing existing plugin...${RESET}"
    rm -rf "$PLUGIN_DEST"
fi

echo -e "${BLUE}${ICON_FOLDER}Creating plugin directory...${RESET}"
mkdir -p "$PLUGIN_DEST"

echo -e "${BLUE}${ICON_FILE}Copying plugin files...${RESET}"
cp -r "$SCRIPT_DIR"/notionsync.koplugin/*.lua "$PLUGIN_DEST/"

FILE_COUNT=$(ls -1 "$SCRIPT_DIR"/notionsync.koplugin/*.lua 2>/dev/null | wc -l)
echo -e "${DIM}    Copied ${FILE_COUNT} Lua files${RESET}"

if [ -f "$PLUGIN_DEST/main.lua" ]; then
    echo ""
    echo -e "${GREEN}${ICON_SUCCESS}${BOLD}Plugin deployed successfully!${RESET}"
    echo -e "${DIM}          Location: ${CYAN}$PLUGIN_DEST${RESET}"
else
    echo -e "${RED}${ICON_CROSS}${BOLD}Error:${RESET} Deployment verification failed"
    exit 1
fi

echo ""

echo -e "${MAGENTA}${ICON_SYNC}Syncing filesystem...${RESET}"
sync
echo -e "${GREEN}${ICON_CHECK}Plugin files synced to device${RESET}"

echo ""

print_box_line() {
    local text="$1"
    local width=58
    local stripped=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local text_len=${#stripped}
    local padding=$((width - text_len - 1))
    printf "${CYAN}║${RESET} %b" "$text"
    printf "%*s" "$padding" ""
    printf "${CYAN}║${RESET}\n"
}

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
print_box_line "${YELLOW}${ICON_WARN}${BOLD}Next Steps:${RESET}"
print_box_line "  ${DIM}Use the eject button in your file manager${RESET}"
print_box_line "  ${DIM}to safely disconnect the device${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${GREEN}${BOLD}${ICON_ROCKET}Deployment complete!${RESET}"
echo ""
