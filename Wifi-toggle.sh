#!/bin/bash

#-----------------------#
# WiFi Toggle for R36S  #
#          v3.4         #
#        By Jason       #
#-----------------------#

# --- Vérification des privilèges root ---
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi
set -euo pipefail

# --- Variables globales ---
CURR_TTY="/dev/tty1"

# Chemin pour le module Wi-Fi USB
WIFI_USB_PATH="/sys/bus/usb/devices/1-1"

# Modules Wi-Fi préférés, testés dans cet ordre. Cette liste sera mise à jour dynamiquement.
PREFERRED_WIFI_MODULES=("8188eu" "r8188eu")

THEMES_DIR="/roms/themes"
PATCH_MARKER=".wifi_icon_patched"
MAINXML_MARKER=".wifi_icon_patched_mainxml"
HEADERXML_MARKER=".wifi_icon_patched_headerxml"

WIFI_ICON_POS_X="0.16"
WIFI_ICON_POS_Y="0.025"
WIFI_ICON_SIZE="0.07"

UPDATER_PATH="/usr/local/bin/wifi_icon_state_updater.sh"
SERVICE_PATH="/etc/systemd/system/wifi-icon-updater.service"
SERVICE_FILE="/etc/systemd/system/wifi-wifi-usb-old-scheme.service"

UPDATE_INTERVAL=0.5  # seconds

# --- Configuration initiale ---
printf "\033c" > "$CURR_TTY"
printf "\e[?25l" > "$CURR_TTY"
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
printf "Starting Wifi Toggle v3.4\nPlease wait..." > "$CURR_TTY"
sleep 1

# --- Fonctions pour détecter les modules de noyau Wi-Fi actuellement chargés ---.
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

    # Method 2: Via lsmod et modinfo pour trouver les modules liés au Wi-Fi
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

# --- Fonction pour vérifier si les paquets nécessaires (rfkill, etc.) sont installés et les installe si besoin. ---
check_rfkill() {
    local REQUIRED_PACKAGES=("rfkill" "wpasupplicant" "network-manager")
    local MISSING_PACKAGES=()

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            MISSING_PACKAGES+=("$pkg")
        fi
    done

    if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
            dialog --title "Internet Required" --msgbox "\nAn active internet connection is required to install missing packages.\n\nPlease check your network and try again." 9 60 > "$CURR_TTY"
            ExitMenu
        fi
        dialog --title "Check dependencies" --infobox "\nInstalling missing packages: ${MISSING_PACKAGES[*]}..." 5 60 > "$CURR_TTY"
         
        sleep 1
        apt-get update -y >/dev/null 2>&1
        if apt-get install -y "${MISSING_PACKAGES[@]}" >/dev/null 2>&1; then
            dialog --title "Check dependencies" --infobox "\nInstallation successful: ${MISSING_PACKAGES[*]}." 6 60 > "$CURR_TTY"
    sleep 2
        else
            dialog --title "Check dependencies" --msgbox "\nError: Could not install required packages (${MISSING_PACKAGES[*]}). Check your internet connection and try again." 9 70 > "$CURR_TTY"
            ExitMenu
        fi
    fi
}

# --- Fonction pour récupérer l'état actuel du Wi-Fi et l'afficher dans le menu principal. ---
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
                            status="No connection, please enable Wi-Fi"
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
                    status="OFF - Wi-Fi ejected please enable Wi-Fi "
                 else
                    status="OFF, please enable Wi-Fi"
                 fi
            fi
        fi
    else
        status="rfkill not found"
    fi
    echo "$status"
}

# --- Fonction pour nettoyer le fichier 'blacklist' et supprimer les entrées en double. ---

deduplicate_blacklist() {
    local blacklist_file="/etc/modprobe.d/blacklist.conf"
    [ -f "$blacklist_file" ] || return 0
    awk '!x[$0]++' "$blacklist_file" > "${blacklist_file}.tmp" && mv "${blacklist_file}.tmp" "$blacklist_file"
}

# --- Fonction pour éjecter le wifi ---
EjectWifi() {
    if [[ -d "$WIFI_USB_PATH" ]]; then
        echo 1 > "$WIFI_USB_PATH/remove" || true
    fi
}

# --- Fonction pour éjecter le module ---
EjectModule() {
    local disabled_list_file="/etc/wifi_disabled_modules.list"
    
    > "$disabled_list_file"

    local modules_to_process_for_disable=($(detect_wifi_modules) "${PREFERRED_WIFI_MODULES[@]}")
    local unique_modules_to_disable=($(echo "${modules_to_process_for_disable[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    if [[ ${#unique_modules_to_disable[@]} -gt 0 ]]; then
        for mod in "${unique_modules_to_disable[@]}"; do
            if [[ -z "$mod" ]]; then continue; fi
            
            echo "$mod" >> "$disabled_list_file"

            modprobe -r -q "$mod" 2>/dev/null || true
            if ! grep -qxF "blacklist $mod" /etc/modprobe.d/blacklist.conf 2>/dev/null ; then
                 echo "# WIFI-TOGGLE START" >> /etc/modprobe.d/blacklist.conf
                 echo "blacklist $mod" >> /etc/modprobe.d/blacklist.conf
                 echo "# WIFI-TOGGLE END" >> /etc/modprobe.d/blacklist.conf
            fi
        done
    fi
    deduplicate_blacklist
}

# --- Fonction pour configurer le port USB pour le mode OTG --( 
OTG() {
if [[ -w /sys/module/usbcore/parameters/old_scheme_first ]]; then
        echo "1" > /sys/module/usbcore/parameters/old_scheme_first || true
    fi

    SERVICE_FILE="/etc/systemd/system/wifi-usb-old-scheme.service"

if [[ ! -f "$SERVICE_FILE" ]]; then
    cat <<'EOF' > "$SERVICE_FILE"
[Unit]
Description=Enable old USB enumeration scheme for OTG compatibility and restart dwc2
After=multi-user.target
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/bin/bash -c '
echo "1" > /sys/module/usbcore/parameters/old_scheme_first || true
if grep -q "^dwc2 " /proc/modules; then
    modprobe -r dwc2 || true
    sleep 1
    modprobe dwc2 || true
else
    if [[ -e /sys/bus/platform/devices/ff300000.usb ]]; then
        if [[ -e /sys/bus/platform/drivers/dwc2/unbind ]]; then
            echo ff300000.usb > /sys/bus/platform/drivers/dwc2/unbind || true
            sleep 1
            echo ff300000.usb > /sys/bus/platform/drivers/dwc2/bind || true
        fi
    fi
fi
'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable wifi-usb-old-scheme.service >/dev/null 2>&1
fi
    
    if grep -q "^dwc2 " /proc/modules; then
        modprobe -r dwc2 || true
        sleep 1
        modprobe dwc2 || true
    else
        if [[ -e /sys/bus/platform/devices/ff300000.usb ]]; then
            if [[ -e /sys/bus/platform/drivers/dwc2/unbind ]]; then
                echo ff300000.usb > /sys/bus/platform/drivers/dwc2/unbind || true
                sleep 1
                echo ff300000.usb > /sys/bus/platform/drivers/dwc2/bind || true
            else
                dialog --title "Error" --msgbox "\nCould not access unbind/bind interface for dwc2 driver." 6 60 > "$CURR_TTY"
            fi
        else
            dialog --title "Error" --msgbox "\nUSB controller ff300000.usb not found in /sys." 6 60 > "$CURR_TTY"
        fi
    fi
    udevadm settle && sleep 2
}    

# --- Fonction pour désactiver le wifi ---
disable_wifi() {
systemctl stop wifi-icon-updater.service || true

    dialog --title "Wi-Fi" --infobox "\nDisabling Wi-Fi..." 5 30 > "$CURR_TTY"
    rfkill block wifi
    if command -v nmcli &>/dev/null; then
        nmcli radio wifi off
    fi
    systemctl stop wpa_supplicant 2>/dev/null || true
    sleep 1
    
    EjectModule

    sleep 1
    EjectWifi
    sleep 1
    OTG
    sleep 2
    
    dialog --title "Wi-Fi & OTG port" --msgbox "\nWi-Fi disabled.\nOTG port is now ready..." 8 30 > "$CURR_TTY"
    
systemctl start wifi-icon-updater.service || true
    
    ExitMenu
}

# --- Fonction première pour activer le wifi ---
enable_wifi_core() {
    local module_loaded_successfully=false
    local module_actually_loaded=""
    local disabled_list_file="/etc/wifi_disabled_modules.list"

    sed -i '/# WIFI-TOGGLE START/,/# WIFI-TOGGLE END/d' /etc/modprobe.d/blacklist.conf
    for mod_to_unblacklist in "${PREFERRED_WIFI_MODULES[@]}"; do
        sed -i "/^blacklist\s\+$mod_to_unblacklist\b/d" /etc/modprobe.d/blacklist.conf 2>/dev/null || true
    done

    rfkill unblock wifi 2>/dev/null || true
    if command -v nmcli &>/dev/null; then
        nmcli radio wifi on 2>/dev/null || true
    fi

    if [ -f "$disabled_list_file" ]; then
        while read -r mod; do
            [[ -n "$mod" ]] && modprobe "$mod" 2>/dev/null || true
        done < "$disabled_list_file"
        rm -f "$disabled_list_file"
    fi

    for preferred_mod in "${PREFERRED_WIFI_MODULES[@]}"; do
        if modprobe "$preferred_mod" 2>/dev/null; then
            module_loaded_successfully=true
            module_actually_loaded="$preferred_mod"
        fi
    done

    update-initramfs -u 2>/dev/null || true

    if $module_loaded_successfully; then
        systemctl restart wpa_supplicant >/dev/null 2>&1 || systemctl start wpa_supplicant >/dev/null 2>&1
        local iface_check
        iface_check=$(ip link show | awk '/wlan[0-9]+:/ {gsub(":", ""); print $2; exit}' || true)
        if [[ -n "$iface_check" ]]; then
            ip link set "$iface_check" down 2>/dev/null || true
            ip link set "$iface_check" up 2>/dev/null || true
        fi
    else
        systemctl stop wpa_supplicant >/dev/null 2>&1 || true
    fi
    systemctl restart wifi-icon-updater.service >/dev/null 2>&1 || true
}

# --- Fonction pour activer le wifi ---
enable_wifi() {
    
    if command -v nmcli &>/dev/null && [[ "$(nmcli radio wifi)" == "enabled" ]]; then
    dialog --title "Wi-Fi" --msgbox "\nWi-Fi already connected." 7 30 > "$CURR_TTY"
    return
fi
    
    dialog --title "Wi-Fi" --infobox "\nEnabling Wi-Fi..." 5 30 > "$CURR_TTY"
    OTG
    enable_wifi_core
    sleep 1
    systemctl stop wifi-icon-updater.service

    local iface_check
    iface_check=$(ip link show | awk '/wlan[0-9]+:/ {gsub(":", ""); print $2; exit}' || true)
    if [[ -n "$iface_check" ]] && nmcli -t -f DEVICE,STATE dev | grep -qE "^$iface_check:connected$"; then
    dialog --title "Wi-Fi" --msgbox "\nWi-Fi enabled. Connection established." 6 50 > "$CURR_TTY"
else
    dialog --title "Wi-Fi" --infobox "\nWi-Fi enabled\nWaiting for connection..." 6 30 > "$CURR_TTY"
fi

    systemctl start wifi-icon-updater.service
    
    sleep 3
    systemctl start wifi-usb-old-scheme.service

    ExitMenu
}

# --- Fonction Exit ---
ExitMenu() {
    printf "\033c" > "$CURR_TTY"
    printf "\e[?25h" > "$CURR_TTY" # Show cursor
    pkill -f "gptokeyb -1 Wifi-toggle.sh" || true
    if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
        setfont /usr/share/consolefonts/Lat7-Terminus20x10.psf.gz
    fi
    exit 0
}

# --- Fonction pour redémarrer EmulationStation ---
restart_es_and_exit() {
    dialog --title "Restarting" --infobox "\nEmulationStation will now restart to apply changes..." 6 55 > "$CURR_TTY"
    sleep 2
    systemctl restart emulationstation &
    ExitMenu
}

# --- Fonction pour créer le script en arrière-plan ---
create_updater_script() {
    cat > "$UPDATER_PATH" << 'EOF'
#!/bin/bash
THEMES_DIR="/roms/themes"
UPDATE_INTERVAL=0.5
prev_state=""
while true; do
    current_state="disconnected"
    if nmcli -t -f DEVICE,STATE dev | grep -qE "^wlan.*:connected$"; then
        current_state="connected"
    elif ip link show | grep -qE "wlan[0-9]+.*state UP"; then
        current_state="connecting"
    fi
    if [[ "$current_state" != "$prev_state" ]]; then
        need_restart=false
        for theme_path in "$THEMES_DIR"/*; do
            [ -d "$theme_path" ] || continue
            art_dir="$theme_path/_art"
            [ -d "$art_dir" ] || art_dir="$theme_path/art"
            [ -d "$art_dir" ] || continue
            icon_file="$art_dir/wifi.svg"
            on_bak="$art_dir/wifi_on.bak.svg"
            off_bak="$art_dir/wifi_off.bak.svg"
            if [[ "$current_state" == "connected" ]]; then
                if [[ -f "$on_bak" ]]; then
                    if [[ ! -f "$icon_file" ]] || ! cmp -s "$on_bak" "$icon_file"; then
                        cp "$on_bak" "$icon_file"
                        need_restart=true
                    fi
                fi
            else
                if [[ -f "$off_bak" ]]; then
                    if [[ ! -f "$icon_file" ]] || ! cmp -s "$off_bak" "$icon_file"; then
                        cp "$off_bak" "$icon_file"
                        need_restart=true
                    fi
                fi
            fi
        done
        if [ "$need_restart" = true ]; then
            systemctl restart emulationstation
        fi
        prev_state="$current_state"
    fi
    sleep "$UPDATE_INTERVAL"
done
EOF
    chmod +x "$UPDATER_PATH"
}

# --- Fonction pour créer et activer le service systemd ---
create_systemd_service() {
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Wi-Fi Icon State Updater
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$UPDATER_PATH
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now "$(basename "$SERVICE_PATH")"
}

# --- Fonction pour vérifier si les thèmes ont déjà été patché ---
themes_already_patched() {
    local all_patched=true
    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        if [ ! -f "$theme_path/$PATCH_MARKER" ]; then
            return 1  
        fi
    done
    return 0  
}

# --- Function to install Wi-Fi icons in all themes ---
install_icons() {
    if themes_already_patched; then
        dialog --title "Already Patched" --msgbox "\nAll themes are already patched.\nNo changes are necessary." 8 50 > "$CURR_TTY"
        return
    fi
    
    dialog --title "Installing Icons" --infobox "\nProcessing themes, please wait...\nThis may take a moment." 7 55 > "$CURR_TTY"
    sleep 2

    # List of XML files to patch in each theme
    local target_xml_files=("theme.xml" "main.xml" "header.xml" "rgb30.xml" "ogs.xml" "503.xml" "fullscreen.xml" "fullscreenv.xml")
    local progress_text=""
    
    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        # If a theme is already marked as patched, skip it
        [ -f "$theme_path/$PATCH_MARKER" ] && continue

        local theme_was_patched=false
        local art_dir=""
        local xml_block=""

        # Loop through the list of target XML files
        for xml_file in "${target_xml_files[@]}"; do
            local theme_xml_file="$theme_path/$xml_file"

            # If the XML file exists, process it
            if [ -f "$theme_xml_file" ]; then

                # One-time initialization per theme (create SVGs, etc.)
                if [[ -z "$art_dir" ]]; then
                    art_dir="$theme_path/_art"
                    [ -d "$art_dir" ] || art_dir="$theme_path/art"
                    mkdir -p "$art_dir"

                    # Create SVG icons
                    cat > "$art_dir/wifi_on.bak.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36" stroke="#28a745" fill="none" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
  <path d="M4 16 C12 8, 24 8, 32 16" /><path d="M8 20 C14 14, 22 14, 28 20" /><path d="M12 24 C16 20, 20 20, 24 24" /><circle cx="18" cy="28" r="1.5" fill="#28a745" />
</svg>
EOF
                    cat > "$art_dir/wifi_off.bak.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36" stroke="#dc3545" fill="none" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
  <path d="M4 16 C12 8, 24 8, 32 16" /><path d="M8 20 C14 14, 22 14, 28 20" /><path d="M12 24 C16 20, 20 20, 24 24" /><circle cx="18" cy="28" r="1.5" fill="#dc3545" /><line x1="6" y1="6" x2="30" y2="30" stroke="#dc3545" />
</svg>
EOF
                    cp "$art_dir/wifi_on.bak.svg" "$art_dir/wifi.svg"

                    # Prepare the XML block to be inserted
                    local icon_path_prefix=$(realpath --relative-to="$theme_path" "$art_dir")
                    xml_block="
    <image name=\"wifi_icon\" extra=\"true\">
        <path>./$icon_path_prefix/wifi.svg</path>
        <pos>${WIFI_ICON_POS_X} ${WIFI_ICON_POS_Y}</pos>
        <origin>0.5 0.5</origin>
        <maxSize>${WIFI_ICON_SIZE} ${WIFI_ICON_SIZE}</maxSize>
        <zIndex>150</zIndex>
        <visible>true</visible>
    </image>"
                fi

                # Patch the XML file
                cp "$theme_xml_file" "${theme_xml_file}.bak"
                # This awk command is generic enough to work with most views
                awk -v block="$xml_block" '/<view / { print; print block; next } { print }' "$theme_xml_file" > "${theme_xml_file}.tmp" && mv "${theme_xml_file}.tmp" "$theme_xml_file"
                theme_was_patched=true
            fi
        done

        # If at least one file was patched in this theme, mark it
        if [ "$theme_was_patched" = true ]; then
            touch "$theme_path/$PATCH_MARKER"
            progress_text+="Patched: $(basename "$theme_path")\n"
        fi
    done

    dialog --title "Installation Complete" --msgbox "\n$progress_text" 0 0 > "$CURR_TTY"
    create_updater_script
    create_systemd_service
    restart_es_and_exit
}

# --- Function to uninstall Wi-Fi icons ---
uninstall_icons() {
    dialog --title "Uninstalling Icons" --infobox "\nRestoring themes..." 5 45 > "$CURR_TTY"
    sleep 2
    local progress_text=""
    
    # List of XML files that could have been patched
    local target_xml_files=("theme.xml" "main.xml" "header.xml" "rgb30.xml" "ogs.xml" "503.xml" "fullscreen.xml" "fullscreenv.xml")

    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue

        # Only clean up if the patch marker is present
        if [ -f "$theme_path/$PATCH_MARKER" ]; then
            # Restore backups for all potential XML files
            for xml_file in "${target_xml_files[@]}"; do
                local theme_xml_file="$theme_path/$xml_file"
                if [ -f "${theme_xml_file}.bak" ]; then
                    mv "${theme_xml_file}.bak" "$theme_xml_file"
                fi
            done
            
            # Remove added files
            rm -f "$theme_path/$PATCH_MARKER"
            rm -f "$theme_path"/{art,_art}/wifi_*.svg

            progress_text+="Cleaned: $(basename "$theme_path")\n"
        fi
    done

    # System cleanup
    rm -f "$UPDATER_PATH"
    rm -f "$SERVICE_PATH"
    rm -f /etc/wifi_disabled_modules.list
    systemctl stop wifi-icon-updater.service >/dev/null 2>&1 || true
    systemctl disable wifi-icon-updater.service >/dev/null 2>&1 || true
    systemctl daemon-reload

    dialog --title "Uninstall Complete" --msgbox "\n$progress_text" 0 0 > "$CURR_TTY"
    restart_es_and_exit
}
# --- Fonction pour mettre à jour la liste des modules Wi-Fi. ---
update_preferred_modules() {
    detected_modules_array=($(detect_wifi_modules))
    if [ ${#detected_modules_array[@]} -gt 0 ]; then
        declare -A unique_modules
        for module in "${PREFERRED_WIFI_MODULES[@]}" "${detected_modules_array[@]}"; do
            if [[ -n "$module" ]]; then
                unique_modules["$module"]=1
            fi
        done
        PREFERRED_WIFI_MODULES=("${!unique_modules[@]}")
    fi
}

#
# --- Menu principal ---
MainMenu() {
    check_rfkill
    while true; do
        local WIFI_STATUS
        WIFI_STATUS=$(get_wifi_status)
        local CHOICE
        CHOICE=$(dialog --output-fd 1 \
            --backtitle "Wi-Fi Management v3.4 - R36S - By Jason" \
            --title "Wi-Fi Manager" \
            --menu "\nCurrent Wi-Fi Status: $WIFI_STATUS" 16 50 7 \
            1 "Install Wi-Fi icons" \
            2 "Enable Wi-Fi" \
            3 "Disable Wi-Fi & Detect Usb Media" \
            4 "Uninstall Wi-Fi icons" \
            5 "Exit" \
        2>"$CURR_TTY")

        case $CHOICE in
            1) install_icons ;;
            2) enable_wifi ;;        
            3) disable_wifi ;;
            4) uninstall_icons;;
            5) ExitMenu ;;
            *) ExitMenu ;;
        esac
    done
}

# --- EXÉCUTION PRINCIPALE ---
trap ExitMenu EXIT SIGINT SIGTERM

# Met à jour la liste des modules avant d'afficher le menu
update_preferred_modules

if command -v /opt/inttools/gptokeyb &> /dev/null; then
    if [[ -e /dev/uinput ]]; then
        chmod 666 /dev/uinput 2>/dev/null || true
    fi
    export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"
    pkill -f "gptokeyb -1 Wifi-toggle.sh" || true
    /opt/inttools/gptokeyb -1 "Wifi-toggle.sh" -c "/opt/inttools/keys.gptk" >/dev/null 2>&1 &
else
    dialog --infobox "gptokeyb not found. Joystick control disabled." 5 65 > "$CURR_TTY"
    sleep 2
fi

printf "\033c" > "$CURR_TTY"
MainMenu
