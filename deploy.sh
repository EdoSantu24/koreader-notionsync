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

# Set your Kobo mount path here or via environment variable
KOBO_MOUNT_PATH="${KOBO_MOUNT_PATH:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$KOBO_MOUNT_PATH" ]; then
    cat << "EOF"

╔═══════════════════════════════════════════════════════════╗
║                   Configuration Required                  ║
╚═══════════════════════════════════════════════════════════╝

EOF
    echo -e "${RED}${ICON_CROSS}${BOLD}Error:${RESET} KOBO_MOUNT_PATH is not set"
    echo ""
    echo -e "${YELLOW}${ICON_WARN}Please set the KOBO_MOUNT_PATH environment variable:${RESET}"
    echo ""
    echo -e "  ${CYAN}# Bash/Zsh - For current session:${RESET}"
    echo -e "  ${DIM}export KOBO_MOUNT_PATH=\"/path/to/your/kobo\"${RESET}"
    echo ""
    echo -e "  ${CYAN}# Bash/Zsh - Add to shell config (~/.bashrc, ~/.zshrc):${RESET}"
    echo -e "  ${DIM}echo 'export KOBO_MOUNT_PATH=\"/path/to/your/kobo\"' >> ~/.bashrc${RESET}"
    echo ""
    echo -e "  ${CYAN}# Fish - For current session:${RESET}"
    echo -e "  ${DIM}set -x KOBO_MOUNT_PATH \"/path/to/your/kobo\"${RESET}"
    echo ""
    echo -e "  ${CYAN}# Fish - Add to config (~/.config/fish/config.fish):${RESET}"
    echo -e "  ${DIM}echo 'set -x KOBO_MOUNT_PATH \"/path/to/your/kobo\"' >> ~/.config/fish/config.fish${RESET}"
    echo ""
    echo -e "${DIM}Example paths:${RESET}"
    echo -e "${DIM}  Linux:   /run/media/\$USER/KOBOeReader${RESET}"
    echo -e "${DIM}  macOS:   /Volumes/KOBOeReader${RESET}"
    echo -e "${DIM}  Windows: /mnt/d/KOBOeReader (WSL)${RESET}"
    echo ""
    exit 1
fi

PLUGIN_DEST="$KOBO_MOUNT_PATH/.adds/koreader/plugins/notionsync.koplugin"
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
echo -e "${CYAN}${ICON_ROCKET}${BOLD}Deploying notionsync.koplugin to Kobo...${RESET}"
echo ""

if [ ! -d "$KOBO_MOUNT_PATH" ]; then
    echo -e "${RED}${ICON_CROSS}${BOLD}Error:${RESET} Kobo not found at ${YELLOW}$KOBO_MOUNT_PATH${RESET}"
    echo -e "${DIM}        Please ensure your Kobo is connected and mounted.${RESET}"
    exit 1
fi

echo -e "${GREEN}${ICON_CHECK}Kobo detected at ${CYAN}$KOBO_MOUNT_PATH${RESET}"

PLUGINS_DIR="$KOBO_MOUNT_PATH/.adds/koreader/plugins"
if [ ! -d "$PLUGINS_DIR" ]; then
    echo -e "${RED}${ICON_CROSS}${BOLD}Error:${RESET} KOReader plugins directory not found"
    echo -e "${DIM}        Please ensure KOReader is installed on your Kobo.${RESET}"
    exit 1
fi

echo -e "${GREEN}${ICON_CHECK}KOReader installation verified${RESET}"
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
echo -e "${GREEN}${ICON_CHECK}Plugin files synced to Kobo${RESET}"

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
print_box_line "  ${DIM}to safely disconnect the Kobo${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${GREEN}${BOLD}${ICON_ROCKET}Deployment complete!${RESET}"
echo ""
