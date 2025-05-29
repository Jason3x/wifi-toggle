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

# Preferred Wi-Fi modules, tried in this order.
PREFERRED_WIFI_MODULES=("8188eu" "r8188eu")

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
printf "Starting Wifi Toggle. Please wait..." > "$CURR_TTY"
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
    if ! command -v rfkill &> /dev/null; then
        dialog --infobox "Installing rfkill..." 5 50 > "$CURR_TTY"
        sleep 1

        if apt-get update >/dev/null 2>&1 && apt-get install -y rfkill >/dev/null 2>&1; then
            dialog --infobox "rfkill installed successfully." 5 50 > "$CURR_TTY"
            sleep 1
        else
            dialog --msgbox "Error: Could not install rfkill. Please check your internet connection and try again." 8 70 > "$CURR_TTY"
            ExitMenu
        fi

        if ! command -v rfkill &> /dev/null; then
            dialog --msgbox "Error: rfkill could not be installed. The script cannot continue." 8 70 > "$CURR_TTY"
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
    systemctl stop wpa_supplicant 2>/dev/null || true
    sleep 0.5

    local modules_to_process_for_disable=($(detect_wifi_modules) "${PREFERRED_WIFI_MODULES[@]}")
    local unique_modules_to_disable=($(echo "${modules_to_process_for_disable[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    if [[ ${#unique_modules_to_disable[@]} -gt 0 ]]; then
        for mod in "${unique_modules_to_disable[@]}"; do
            if [[ -z "$mod" ]]; then continue; fi
            modprobe -r "$mod" 2>/dev/null || true
            if ! grep -qxF "blacklist $mod" /etc/modprobe.d/blacklist.conf 2>/dev/null ; then
                 echo "blacklist $mod" | tee -a /etc/modprobe.d/blacklist.conf > /dev/null
            fi
        done
    fi
    dialog --msgbox "Wi-Fi disabled." 5 30 > "$CURR_TTY"
}

enable_wifi() {
    dialog --infobox "Enabling Wi-Fi..." 3 30 > "$CURR_TTY"

    local module_loaded_successfully=false
    local module_actually_loaded=""
    rfkill unblock wifi

    for mod_to_unblacklist in "${PREFERRED_WIFI_MODULES[@]}"; do
        sed -i "/^blacklist\s\+$mod_to_unblacklist\b/d" /etc/modprobe.d/blacklist.conf 2>/dev/null || true
    done

    for preferred_mod in "${PREFERRED_WIFI_MODULES[@]}"; do
        if modprobe "$preferred_mod" 2>/dev/null; then
            module_loaded_successfully=true
            module_actually_loaded="$preferred_mod"
            # Blacklist other preferred modules if this one loaded successfully
            for other_mod in "${PREFERRED_WIFI_MODULES[@]}"; do
                if [[ "$other_mod" != "$module_actually_loaded" ]]; then
                    if ! grep -qxF "blacklist $other_mod" /etc/modprobe.d/blacklist.conf 2>/dev/null ; then
                         echo "blacklist $other_mod" | tee -a /etc/modprobe.d/blacklist.conf > /dev/null
                    fi
                fi
            done
            break
        else # If modprobe failed, ensure it's blacklisted to prevent auto-load issues
            if ! grep -qxF "blacklist $preferred_mod" /etc/modprobe.d/blacklist.conf 2>/dev/null ; then
                 echo "blacklist $preferred_mod" | tee -a /etc/modprobe.d/blacklist.conf > /dev/null
            fi
        fi
    done

    if $module_loaded_successfully; then
        if ! systemctl restart wpa_supplicant >/dev/null 2>&1; then
            systemctl start wpa_supplicant >/dev/null 2>&1 || true
        fi

        sleep 2 # Give time for interface to come up and connect

        local iface_check
        iface_check=$(ip link show | awk '/wlan[0-9]+:/ {gsub(":", ""); print $2; exit}' || true)

        if [[ -n "$iface_check" ]] && ip link show "$iface_check" | grep -q "state UP"; then
            dialog --msgbox "Wi-Fi enabled. Connection established." 5 50 > "$CURR_TTY"
        else
            dialog --msgbox "Wi-Fi enabled. Module $module_actually_loaded loaded." 5 50 > "$CURR_TTY"
            # Attempt to restart wpa_supplicant again if not connected
            if ! systemctl restart wpa_supplicant >/dev/null 2>&1; then
                systemctl start wpa_supplicant >/dev/null 2>&1 || true
            fi
    
            # If interface exists but not UP, try bringing it down (might be a reset attempt)
            if [[ -n "$iface_check" ]]; then
                ip link set "$iface_check" down 2>/dev/null || true
            fi
        fi
    else
        systemctl stop wpa_supplicant >/dev/null 2>&1 || true # Ensure wpa_supplicant is stopped if no module loaded
        dialog --msgbox "Failed to enable Wi-Fi. No compatible module could be loaded." 6 50 > "$CURR_TTY"
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

MainMenu() {
    check_rfkill
    while true; do
        local WIFI_STATUS
        WIFI_STATUS=$(get_wifi_status)
        local CHOICE
        CHOICE=$(dialog --output-fd 1 \
            --backtitle "Wi-Fi Management - R36S - By Jason" \
            --title "Wi-Fi Manager" \
            --menu "Select an action:\n\nCurrent Wi-Fi Status: $WIFI_STATUS" 14 47 4 \
            1 "Enable Wi-Fi" \
            2 "Disable Wi-Fi" \
            3 "Reboot System" \
            4 "Exit" \
        2>"$CURR_TTY")

        case "$CHOICE" in
            1) enable_wifi ;;
            2) disable_wifi ;;
            3) RebootSystem ;;
            4) ExitMenu ;;
            *) ExitMenu ;; # Handles ESC or Cancel
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
