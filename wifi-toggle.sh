#!/bin/bash

#-----------------------#
# WiFi Toggle for R36S  #
#-----------------------#

# --- Root privilege check ---
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

set -euo pipefail

# --- Global Variables ---
CURR_TTY="/dev/tty1"

# Path for USB Wi-Fi module removal
WIFI_USB_PATH="/sys/bus/usb/devices/1-1"


# Preferred Wi-Fi modules, tried in this order.
PREFERRED_WIFI_MODULES=("8188eu" "r8188eu")

THEMES_DIR="/roms/themes"
PATCH_MARKER=".wifi_icon_patched"
MAINXML_MARKER=".wifi_icon_patched_mainxml"

WIFI_ICON_POS_X="0.16"
WIFI_ICON_POS_Y="0.025"
WIFI_ICON_SIZE="0.07"

UPDATER_PATH="/usr/local/bin/wifi_icon_state_updater.sh"
SERVICE_PATH="/etc/systemd/system/wifi-icon-updater.service"

UPDATE_INTERVAL=4  # seconds


# --- Initial Setup ---
printf "\033c" > "$CURR_TTY"
printf "\e[?25l" > "$CURR_TTY" # Hide cursor
dialog --clear
export TERM=linux
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
    setfont /usr/share/consolefonts/Lat7-TerminusBold22x11.psf.gz
else
    setfont /usr/share/consolefonts/Lat7-Terminus16.psf.gz
fi

pkill -9 -f gptokeyb || true
pkill -9 -f osk.py || true

printf "\033c" > "$CURR_TTY"
printf "Starting Wifi Toggle.\nPlease wait..." > "$CURR_TTY"
sleep 1

# --- Functions ---
detect_wifi_modules() {
    local modules_found_raw=()
    local module_name
    local modinfo_output

    # Method 1: Via active network interfaces (wlanX)
    local iface module_path
    for iface in $(ls /sys/class/net 2>/dev/null | grep '^wlan' || true); do
        if [[ -L "/sys/class/net/$iface/device/driver/module" ]]; then
            module_path=$(readlink -f "/sys/class/net/$iface/device/driver/module" 2>/dev/null)
            if [[ -n "$module_path" && -e "$module_path" ]]; then
                module_name=$(basename "$module_path")
                [[ -n "$module_name" && ! " ${modules_found_raw[*]} " =~ " $module_name " ]] && modules_found_raw+=("$module_name")
            fi
        fi
    done

    # Method 2: Via lsmod and modinfo to find Wi-Fi related modules
    if command -v lsmod &>/dev/null && command -v modinfo &>/dev/null; then
        while IFS= read -r line; do
            current_mod_name=$(echo "$line" | awk '{print $1}')
            if [[ "$current_mod_name" != "Module" && -n "$current_mod_name" ]]; then
                modinfo_output=$(modinfo "$current_mod_name" 2>/dev/null || continue)
                if echo "$modinfo_output" | grep -qE \
                    -e 'filename:\s*.*drivers/net/wireless/' \
                    -e 'filename:\s*.*net/wireless/' \
                    -e 'depends:\s*([^,]*,)?(cfg80211|mac80211)(,|$)'
                then
                    [[ ! " ${modules_found_raw[*]} " =~ " $current_mod_name " ]] && modules_found_raw+=("$current_mod_name")
                fi
            fi
        done < <(lsmod 2>/dev/null || true)
    fi

    local helpers_to_exclude=("cfg80211" "mac80211" "rfkill" "lib80211" "libarc4")
    local final_modules=()
    local mod_to_check
    local is_helper

    for mod_to_check in "${modules_found_raw[@]}"; do
        is_helper=false
        for helper in "${helpers_to_exclude[@]}"; do
            if [[ "$mod_to_check" == "$helper" ]]; then
                is_helper=true
                break
            fi
        done
        if ! $is_helper; then
            if [[ ! " ${final_modules[*]} " =~ " $mod_to_check " ]]; then
                final_modules+=("$mod_to_check")
            fi
        fi
    done

    echo "${final_modules[@]}"
}

check_rfkill() {
    local REQUIRED_PACKAGES=("rfkill" "wpasupplicant" "network-manager")
    local MISSING_PACKAGES=()

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            MISSING_PACKAGES+=("$pkg")
        fi
    done

    if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
        dialog --infobox "Installing missing packages: ${MISSING_PACKAGES[*]}..." 5 60 > "$CURR_TTY"
        sleep 1
        apt-get update -y >/dev/null 2>&1
        if apt-get install -y "${MISSING_PACKAGES[@]}" >/dev/null 2>&1; then
            dialog --infobox "Installation successful: ${MISSING_PACKAGES[*]}." 5 60 > "$CURR_TTY"
        else
            dialog --msgbox "Error: Could not install required packages (${MISSING_PACKAGES[*]}). Check your internet connection and try again." 8 70 > "$CURR_TTY"
            ExitMenu
        fi
    fi
}

get_wifi_status() {
    local status="N/A"
    local iface
    if command -v rfkill &> /dev/null; then
        if rfkill list wifi | grep -q "Soft blocked: yes"; then
            status="OFF (Soft Blocked)"
        else
            iface=$(ip link show | awk '/wlan[0-9]+:/ {gsub(":", ""); print $2; exit}' || true)
            if [[ -n "$iface" ]]; then
                if ip link show "$iface" | grep -q "state UP"; then
                    status="ON (Interface UP, Connected)"
                else
                    local loaded_preferred_module=""
                    for mod in "${PREFERRED_WIFI_MODULES[@]}"; do
                        if lsmod | grep -qw "$mod"; then
                            loaded_preferred_module="$mod"
                            break
                        fi
                    done
                    if [[ -n "$loaded_preferred_module" ]]; then
                        if systemctl is-active --quiet wpa_supplicant; then
                            status="ON (Connecting...)"
                        else
                            status="WARNING ($loaded_preferred_module: Interface DOWN, wpa_supplicant inactive)"
                        fi
                    else
                        status="UNKNOWN (Interface DOWN, no preferred module loaded)"
                    fi
                fi
            else
                 local loaded_preferred_module=""
                 for mod in "${PREFERRED_WIFI_MODULES[@]}"; do
                    if lsmod | grep -qw "$mod"; then
                        loaded_preferred_module="$mod"
                        break
                    fi
                 done
                 if [[ -n "$loaded_preferred_module" ]]; then
                    status="OFF - OTG Port in use! Reboot to enable connection "
                 else
                    status="OFF (No interface / Modules not loaded)"
                 fi
            fi
        fi
    else
        status="rfkill not found"
    fi
    echo "$status"
}


disable_wifi() {
    dialog --infobox "Disabling Wi-Fi..." 3 30 > "$CURR_TTY"
    rfkill block wifi
    if command -v nmcli &>/dev/null; then
        nmcli radio wifi off
    fi
    systemctl stop wpa_supplicant 2>/dev/null || true
    sleep 0.5
    
    local modules_to_process_for_disable=($(detect_wifi_modules) "${PREFERRED_WIFI_MODULES[@]}")
    local unique_modules_to_disable=($(echo "${modules_to_process_for_disable[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    if [[ ${#unique_modules_to_disable[@]} -gt 0 ]]; then
        for mod in "${unique_modules_to_disable[@]}"; do
            if [[ -z "$mod" ]]; then continue; fi
            modprobe -r -q "$mod" 2>/dev/null || true
            if ! grep -qxF "blacklist $mod" /etc/modprobe.d/blacklist.conf 2>/dev/null ; then
                 echo "blacklist $mod" | tee -a /etc/modprobe.d/blacklist.conf > /dev/null
            fi
        done
    fi
    dialog --msgbox "Wi-Fi disabled." 5 20 > "$CURR_TTY"
}

enable_wifi_core() {
    local module_loaded_successfully=false
    local module_actually_loaded=""

    rfkill unblock wifi
    if command -v nmcli &>/dev/null; then
        nmcli radio wifi on
    fi

    for mod_to_unblacklist in "${PREFERRED_WIFI_MODULES[@]}"; do
        sed -i "/^blacklist\s\+$mod_to_unblacklist\b/d" /etc/modprobe.d/blacklist.conf 2>/dev/null || true
    done

    for preferred_mod in "${PREFERRED_WIFI_MODULES[@]}"; do
        if modprobe "$preferred_mod" 2>/dev/null; then
            module_loaded_successfully=true
            module_actually_loaded="$preferred_mod"
            for other_mod in "${PREFERRED_WIFI_MODULES[@]}"; do
                if [[ "$other_mod" != "$module_actually_loaded" ]]; then
                    echo "blacklist $other_mod" >> /etc/modprobe.d/blacklist.conf
                fi
            done
            break
        fi
    done

    if $module_loaded_successfully; then
        systemctl restart wpa_supplicant >/dev/null 2>&1 || systemctl start wpa_supplicant >/dev/null 2>&1
        sleep 0.5
        local iface_check
        iface_check=$(ip link show | awk '/wlan[0-9]+:/ {gsub(":", ""); print $2; exit}' || true)
        if [[ -n "$iface_check" ]]; then
            ip link set "$iface_check" down 2>/dev/null || true
            sleep 0.5
            ip link set "$iface_check" up 2>/dev/null || true
        fi
    else
        systemctl stop wpa_supplicant >/dev/null 2>&1 || true
    fi
}

enable_wifi() {
    dialog --infobox "Enabling Wi-Fi..." 3 30 > "$CURR_TTY"
    enable_wifi_core

    local iface_check
    iface_check=$(ip link show | awk '/wlan[0-9]+:/ {gsub(":", ""); print $2; exit}' || true)
    if [[ -n "$iface_check" ]] && ip link show "$iface_check" | grep -q "state UP"; then
        dialog --msgbox "Wi-Fi enabled. Connection established." 5 50 > "$CURR_TTY"
    else
        dialog --msgbox "Wi-Fi enabled." 5 20 > "$CURR_TTY"
    fi

    enable_wifi_core
    
    dialog --infobox "Restarting EmulationStation...." 3 40 > $CURR_TTY
  sleep 2 

  sudo systemctl restart emulationstation & 

  exit 0
}

    # Remove USB Wi-Fi module if path exists
EjectWifi() {
    if [[ -d "$WIFI_USB_PATH" ]]; then
        dialog --infobox "Ejecting Wi-Fi module..." 3 30 > "$CURR_TTY"
        echo 1 > "$WIFI_USB_PATH/remove" || true
        sleep 2
        dialog --msgbox "Wi-Fi module ejected." 5 30 > "$CURR_TTY"
    else
        dialog --msgbox "Wi-Fi module already ejected." 5 40 > "$CURR_TTY"
    fi
}

RebootSystem() {
    dialog --infobox "Rebooting system..." 3 30 > "$CURR_TTY"
    sleep 2
    printf "\033c" > "$CURR_TTY" 
    printf "\e[?25h" > "$CURR_TTY" # Show cursor
    pkill -f "gptokeyb -1 wifi-toggle.sh" || true
    if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
        setfont /usr/share/consolefonts/Lat7-Terminus20x10.psf.gz # Restore a common font
    fi    
    exec systemctl reboot
}

ExitMenu() {
    printf "\033c" > "$CURR_TTY"
    printf "\e[?25h" > "$CURR_TTY" # Show cursor
    pkill -f "gptokeyb -1 wifi-toggle.sh" || true
    if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
        setfont /usr/share/consolefonts/Lat7-Terminus20x10.psf.gz # Restore a common font
    fi
    exit 0
}

restart_es_and_exit() {
    dialog --title "Restarting" --infobox "\nEmulationStation will now restart to apply changes..." 4 55 > "$CURR_TTY"
    sleep 2
    systemctl restart emulationstation &
    ExitMenu
}

create_updater_script() {
    cat > "$UPDATER_PATH" << 'EOF'
#!/bin/bash
THEMES_DIR="/roms/themes"
UPDATE_INTERVAL=4

prev_wifi_enabled=""

while true; do
    wifi_enabled=$(nmcli radio wifi)

    if [[ "$wifi_enabled" != "$prev_wifi_enabled" ]]; then
        for theme_path in "$THEMES_DIR"/*; do
            [ -d "$theme_path" ] || continue
            art_dir="$theme_path/_art"
            [ -d "$art_dir" ] || art_dir="$theme_path/art"
            [ -d "$art_dir" ] || continue

            icon_file="$art_dir/wifi.svg"
            on_bak="$art_dir/wifi_on.bak.svg"
            off_bak="$art_dir/wifi_off.bak.svg"

            if [[ "$wifi_enabled" == enabled* ]]; then
                [[ -f "$on_bak" ]] && cp "$on_bak" "$icon_file"
            else
                [[ -f "$off_bak" ]] && cp "$off_bak" "$icon_file"
            fi
        done

        systemctl restart emulationstation
        prev_wifi_enabled="$wifi_enabled"
    fi

    sleep "$UPDATE_INTERVAL"
done
EOF
    chmod +x "$UPDATER_PATH"
}

create_systemd_service() {
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Wi-Fi Icon State Updater
After=network.target

[Service]
ExecStart=$UPDATER_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now wifi-icon-updater.service
}

themes_already_patched() {
    local all_patched=true
    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        theme_xml_file="$theme_path/theme.xml"
        [ ! -f "$theme_xml_file" ] && continue
        if [ ! -f "$theme_path/$PATCH_MARKER" ]; then
            all_patched=false
            break
        fi
    done

    # Vérifie aussi NES-box
    NESBOX_PATH="$THEMES_DIR/es-theme-nes-box"
    if [ -d "$NESBOX_PATH" ] && [ ! -f "$NESBOX_PATH/$MAINXML_MARKER" ]; then
        all_patched=false
    fi

    $all_patched
}

install_icons() {
    dialog --title "Installing Icons" --infobox "Installing Wi-Fi icons in themes.\nBackups will be created." 5 55 > "$CURR_TTY"
    sleep 2
    
        if themes_already_patched; then
        dialog --title "Already Patched" --msgbox "All themes are already patched.\nNo changes necessary." 6 50 > "$CURR_TTY"
        return
    fi

    local progress_text=""

    # Patch for all theme.xml themes
    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        theme_xml_file="$theme_path/theme.xml"
        [ ! -f "$theme_xml_file" ] && continue
        [ -f "$theme_path/$PATCH_MARKER" ] && continue

        cp "$theme_xml_file" "${theme_xml_file}.bak"

        art_dir="$theme_path/_art"
        [ -d "$art_dir" ] || art_dir="$theme_path/art"
        mkdir -p "$art_dir"
        icon_path_prefix=$(realpath --relative-to="$theme_path" "$art_dir")

        # Crée les fichiers SVG
        cat > "$art_dir/wifi_on.bak.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36" stroke="#28a745" fill="none" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
  <path d="M4 16 C12 8, 24 8, 32 16" />
  <path d="M8 20 C14 14, 22 14, 28 20" />
  <path d="M12 24 C16 20, 20 20, 24 24" />
  <circle cx="18" cy="28" r="1.5" fill="#28a745" />
</svg>
EOF

        cat > "$art_dir/wifi_off.bak.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36" stroke="#dc3545" fill="none" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
  <path d="M4 16 C12 8, 24 8, 32 16" />
  <path d="M8 20 C14 14, 22 14, 28 20" />
  <path d="M12 24 C16 20, 20 20, 24 24" />
  <circle cx="18" cy="28" r="1.5" fill="#dc3545" />
  <line x1="6" y1="6" x2="30" y2="30" stroke="#dc3545" />
</svg>
EOF

        # Par défaut, active l'icône "on"
        cp "$art_dir/wifi_on.bak.svg" "$art_dir/wifi.svg"

        xml_block="
    <image name=\"wifi_icon\" extra=\"true\">
        <path>./$icon_path_prefix/wifi.svg</path>
        <pos>${WIFI_ICON_POS_X} ${WIFI_ICON_POS_Y}</pos>
        <origin>0.5 0.5</origin>
        <maxSize>${WIFI_ICON_SIZE} ${WIFI_ICON_SIZE}</maxSize>
        <zIndex>150</zIndex>
        <visible>true</visible>
    </image>"

        awk -v block="$xml_block" '/<view / { print; print block; next } { print }' "$theme_xml_file" > "${theme_xml_file}.tmp" && mv "${theme_xml_file}.tmp" "$theme_xml_file"
        touch "$theme_path/$PATCH_MARKER"
        progress_text+="Patched: $(basename "$theme_path")\n"
    done

    # Patch spécifique pour es-theme-nes-box/main.xml
    NESBOX_PATH="$THEMES_DIR/es-theme-nes-box"
    if [ -d "$NESBOX_PATH" ] && [ ! -f "$NESBOX_PATH/$MAINXML_MARKER" ]; then
        nesbox_xml="$NESBOX_PATH/main.xml"
        [ -f "$nesbox_xml" ] || return

        cp "$nesbox_xml" "${nesbox_xml}.bak"
        art_dir="$NESBOX_PATH/_art"
        mkdir -p "$art_dir"
        icon_path_prefix=$(realpath --relative-to="$NESBOX_PATH" "$art_dir")

        cp "$art_dir/wifi_on.bak.svg" "$art_dir/wifi.svg"

        xml_block="
    <image name=\"wifi_icon\" extra=\"true\">
        <path>./$icon_path_prefix/wifi.svg</path>
        <pos>${WIFI_ICON_POS_X} ${WIFI_ICON_POS_Y}</pos>
        <origin>0.5 0.5</origin>
        <maxSize>${WIFI_ICON_SIZE} ${WIFI_ICON_SIZE}</maxSize>
        <zIndex>150</zIndex>
        <visible>true</visible>
    </image>"

        awk -v block="$xml_block" '
            /<view name="system">/ || /<view name="detailed,video">/ || /<view name="basic">/ {
                print;
                print block;
                next;
            }
            { print }
        ' "$nesbox_xml" > "${nesbox_xml}.tmp" && mv "${nesbox_xml}.tmp" "$nesbox_xml"

        touch "$NESBOX_PATH/$MAINXML_MARKER"
        progress_text+="Patched: es-theme-nes-box\n"
    fi

    dialog --title "Done" --msgbox "Installation complete.\n\n$progress_text" 0 0 > "$CURR_TTY"
    create_updater_script
    create_systemd_service
    restart_es_and_exit
}

uninstall_icons() {
    dialog --title "Uninstalling Icons" --infobox "Restoring themes..." 4 45 > "$CURR_TTY"
    sleep 2
    local progress_text=""

    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue

        xml="$theme_path/theme.xml"
        [ -f "$theme_path/$PATCH_MARKER" ] && [ -f "$xml.bak" ] && mv "$xml.bak" "$xml" && rm -f "$theme_path/$PATCH_MARKER"

        xml="$theme_path/main.xml"
        [ -f "$theme_path/$MAINXML_MARKER" ] && [ -f "$xml.bak" ] && mv "$xml.bak" "$xml" && rm -f "$theme_path/$MAINXML_MARKER"

        rm -f "$theme_path"/{art,_art}/wifi_*.svg

        progress_text+="Cleaned: $(basename "$theme_path")\n"
    done

    rm -f "$UPDATER_PATH"
    rm -f "$SERVICE_PATH"
    systemctl daemon-reload

    dialog --title "Uninstall Complete" --msgbox "$progress_text" 0 0 > "$CURR_TTY"
    restart_es_and_exit
}

MainMenu() {
    check_rfkill
    while true; do
        local WIFI_STATUS
        WIFI_STATUS=$(get_wifi_status)
        local CHOICE
        CHOICE=$(dialog --output-fd 1 \
            --backtitle "Wi-Fi Management v2.0 - R36S - By Jason" \
            --title "Wi-Fi Manager" \
            --menu "\nCurrent Wi-Fi Status: $WIFI_STATUS" 16 50 7 \
            1 "Install Wi-Fi icons" \
            2 "Enable Wi-Fi" \
            3 "Disable Wi-Fi" \
            4 "Eject Wi-Fi" \
            5 "Uninstall Wi-Fi icons" \
            6 "Reboot System" \
            7 "Exit" \
        2>"$CURR_TTY")

        case $CHOICE in
            1) install_icons ;;
            2) enable_wifi ;;        
            3) disable_wifi ;;
            4) EjectWifi ;;
            5) uninstall_icons;;
            6) RebootSystem ;;
            7) ExitMenu ;;
            *) ExitMenu ;;
        esac
    done
}

# --- Main Execution ---
trap ExitMenu EXIT SIGINT SIGTERM # Clean up on exit

# gptokeyb setup for joystick control in dialog
if command -v /opt/inttools/gptokeyb &> /dev/null; then
    if [[ -e /dev/uinput ]]; then
        chmod 666 /dev/uinput 2>/dev/null || true # Ensure gptokeyb can access uinput
    fi
    export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"
    pkill -f "gptokeyb -1 wifi-toggle.sh" || true # Kill previous instances
    # Start gptokeyb in background, mapping joystick to keyboard for dialog navigation
    /opt/inttools/gptokeyb -1 "wifi-toggle.sh" -c "/opt/inttools/keys.gptk" >/dev/null 2>&1 &
else
    dialog --infobox "gptokeyb not found. Joystick control disabled." 5 65 > "$CURR_TTY"
    sleep 2
fi

printf "\033c" > "$CURR_TTY" # Clear screen before showing menu
MainMenu