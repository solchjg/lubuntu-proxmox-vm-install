#!/usr/bin/env bash
# =============================================================================
# lubuntu-vm.sh - Build a Lubuntu 26.04 desktop VM on Proxmox VE 9
# =============================================================================
#
# Run as root on the Proxmox host:   bash lubuntu-vm.sh
#
# What it does, in order:
#   1. Pre-flight checks (root, Proxmox VE 9, required tools).
#   2. Makes sure the newest Lubuntu 26.04.x desktop ISO is in ISO storage
#      (downloads + verifies it if missing, removes older 26.04 ISOs that no
#      VM is using).
#   3. Asks for VM settings with whiptail menus ("default" or "advanced",
#      modelled on community-scripts' ubuntu-vm.sh) and the password for the
#      'sadmin' user.
#   4. Creates and starts the VM booted from the ISO. YOU click through the
#      Lubuntu installer in the Proxmox console, creating user 'sadmin' with
#      the password you gave the script.
#   5. Ejects the ISO, reboots the VM, then types into the VM console
#      (qm sendkey) to log in, open a terminal and install the QEMU guest
#      agent + OpenSSH server.
#   6. Through the guest agent (qm guest exec) it then: installs nala, runs
#      nala upgrade, configures OpenSSH (optional public key, optional
#      PermitRootLogin yes), and runs the newest c-nergy xrdp installer.
#   7. Shuts the VM down and takes a snapshot named 'initial-install'.
#
# Assumptions / limits:
#   * The VM console keyboard layout is US English (qm sendkey sends US
#     scancodes, so other layouts would mistype the password).
#   * The VM needs internet access through the chosen bridge.
#   * Everything that runs inside the guest is logged to
#     /var/log/lubuntu-vm-setup.log in the guest.
#   * Everything shown on screen is also logged on the host to
#     /var/log/lubuntu-vm/lubuntu-vm-<date>.log (root-only, 0600), together
#     with console screenshots taken during the auto-login step. Passwords
#     are never printed, so they never reach the log.
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
LUBUNTU_SERIES="26.04"
LUBUNTU_RELEASES_URL="https://cdimage.ubuntu.com/lubuntu/releases"
XRDP_PRODUCTS_URL="https://www.c-nergy.be/products.html"
XRDP_FALLBACK_URL="https://c-nergy.be/downloads/xRDP/xrdp-installer-1.6.zip"
VM_USER="sadmin"
SNAPSHOT_NAME="initial-install"
ISO_STORAGE="local"                       # Proxmox storage that holds ISOs
GUEST_LOG="/var/log/lubuntu-vm-setup.log" # log file inside the guest
LOG_DIR="/var/log/lubuntu-vm"              # host log directory (root only)
LOG_FILE="${LOG_DIR}/lubuntu-vm-$(date +%Y%m%d-%H%M%S).log"
TEMP_DIR="$(mktemp -d)"

# Colours for status messages
YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; BL=$'\033[36m'; CL=$'\033[m'
BOLD=$'\033[1m'

# Values filled in by the menus (defaults match the requested spec)
VMID=""
MACHINE_TYPE="q35"
DISK_SIZE="30"            # GiB
DISK_CACHE="none"
STORAGE="local-lvm"
HN="lubuntu"
BIOS="ovmf"
CPU_TYPE="x86-64-v2-AES"
CORE_COUNT="2"
RAM_SIZE="8192"           # MiB
BRG="vmbr0"
MAC="02:$(openssl rand -hex 5 | tr '[:lower:]' '[:upper:]' | sed 's/\(..\)/\1:/g; s/:$//')"
VLAN=""
MTU=""
KEYBOARD=""
VERBOSE="no"
START_VM="yes"

# Post-install choices
VM_PASSWORD=""
SSH_PUBKEY=""
PERMIT_ROOT="no"
ROOT_PW=""                # optional root password; must differ from VM_PASSWORD
XRDP_FLAGS="-s"           # c-nergy switches: -s sound redirection, -l custom login screen

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
msg_info()  { echo -e " ${YW}…${CL} $*"; }
msg_ok()    { echo -e " ${GN}✓${CL} $*"; }
msg_warn()  { echo -e " ${YW}!${CL} ${YW}$*${CL}"; }
msg_error() { echo -e " ${RD}✗ $*${CL}" >&2; }

cleanup() { rm -rf "$TEMP_DIR"; }

# Copy everything printed to stdout/stderr into LOG_FILE, with colour codes
# stripped. The directory and file are readable by root only. whiptail draws
# straight on /dev/tty (see wt), so menus and password boxes never reach the
# log, and the script never echoes a password.
start_logging() {
  umask 077
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  : >"$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee >(sed -u -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b[()][A-Z0-9]//g' >>"$LOG_FILE")) 2>&1
  echo "=== lubuntu-vm.sh started $(date '+%F %T') on $(hostname) ==="
  umask 022   # back to normal for the ISO and anything else the script writes
}
trap cleanup EXIT
trap 'msg_error "Failed at line $LINENO: $BASH_COMMAND"' ERR

exit_script() {
  clear
  echo -e "\n ${YW}User exited script${CL}\n"
  exit 0
}

# Run a command, hiding its output unless VERBOSE=yes.
run() {
  if [[ "$VERBOSE" == "yes" ]]; then "$@"; else "$@" >/dev/null 2>&1; fi
}

header_info() {
  clear
  cat <<'EOF'
    __    __  __               __
   / /   / / / /_  __  _______/ /___  __
  / /   / / / / / / / / / __ \/ __/ / / /
 / /___/ /_/ / /_/ / /_/ / / / /_/ /_/ /
/_____/\____/_.___/\__,_/_/ /_/\__/\__,_/  26.04 VM for Proxmox VE 9

EOF
}

# -----------------------------------------------------------------------------
# 1. Pre-flight checks
# -----------------------------------------------------------------------------
preflight() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Run this script as root on the Proxmox host."
    exit 1
  fi
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "pveversion not found; this does not look like a Proxmox VE host."
    exit 1
  fi
  local pve_major
  pve_major="$(pveversion | sed -n 's#^pve-manager/\([0-9]\+\).*#\1#p')"
  if [[ "$pve_major" != "9" ]]; then
    msg_warn "This script targets Proxmox VE 9 (found: $(pveversion))."
    whiptail --backtitle "Proxmox VE Helper" --title "UNTESTED VERSION" --yesno \
      "This script was written for Proxmox VE 9.\nContinue anyway?" 9 50 || exit_script
  fi
  local tool
  for tool in curl whiptail sha256sum perl qm pvesm pvesh; do
    command -v "$tool" >/dev/null 2>&1 || { msg_error "Missing required tool: $tool"; exit 1; }
  done
}

# -----------------------------------------------------------------------------
# 2. ISO management
# -----------------------------------------------------------------------------
# Finds the newest 26.04 point release on cdimage.ubuntu.com, e.g. 26.04.1,
# and sets ISO_NAME, ISO_URL, ISO_SHA256.
find_latest_iso() {
  msg_info "Looking up the newest Lubuntu ${LUBUNTU_SERIES} release"
  local release
  release="$(curl -fsSL "${LUBUNTU_RELEASES_URL}/" \
    | grep -oE "href=\"${LUBUNTU_SERIES//./\\.}(\.[0-9]+)?/\"" \
    | sed 's/href="//; s#/"##' | sort -V | tail -n1)"
  if [[ -z "$release" ]]; then
    msg_error "Could not find a Lubuntu ${LUBUNTU_SERIES} release on ${LUBUNTU_RELEASES_URL}"
    exit 1
  fi
  local base="${LUBUNTU_RELEASES_URL}/${release}/release"
  ISO_NAME="lubuntu-${release}-desktop-amd64.iso"
  ISO_URL="${base}/${ISO_NAME}"
  ISO_SHA256="$(curl -fsSL "${base}/SHA256SUMS" | awk -v f="*${ISO_NAME}" '$2==f {print $1}')"
  if [[ -z "$ISO_SHA256" ]]; then
    msg_error "No SHA256 checksum published for ${ISO_NAME}"
    exit 1
  fi
  msg_ok "Newest release is ${BL}${ISO_NAME}${CL}"
}

# True if any VM config references the given ISO file name.
iso_in_use() {
  grep -qs -- "$1" /etc/pve/qemu-server/*.conf /etc/pve/nodes/*/qemu-server/*.conf
}

ensure_iso() {
  find_latest_iso
  local iso_dir
  iso_dir="$(dirname "$(pvesm path "${ISO_STORAGE}:iso/${ISO_NAME}")")"
  ISO_PATH="${iso_dir}/${ISO_NAME}"

  if [[ -f "$ISO_PATH" ]] && echo "${ISO_SHA256}  ${ISO_PATH}" | sha256sum -c --status; then
    msg_ok "ISO already present and verified: ${ISO_PATH}"
  else
    msg_info "Downloading ${ISO_URL}"
    curl -fL --progress-bar -o "${ISO_PATH}.part" "$ISO_URL" 2>/dev/tty
    msg_info "Verifying SHA256 checksum"
    if ! echo "${ISO_SHA256}  ${ISO_PATH}.part" | sha256sum -c --status; then
      rm -f "${ISO_PATH}.part"
      msg_error "Checksum mismatch for ${ISO_NAME}; download removed."
      exit 1
    fi
    mv -f "${ISO_PATH}.part" "$ISO_PATH"
    msg_ok "Downloaded and verified ${ISO_NAME}"
  fi

  # Remove older Lubuntu 26.04 ISOs, but never one that a VM still uses.
  local old
  for old in "${iso_dir}"/lubuntu-"${LUBUNTU_SERIES}"*-desktop-amd64.iso; do
    [[ -e "$old" && "$old" != "$ISO_PATH" ]] || continue
    if iso_in_use "$(basename "$old")"; then
      msg_warn "Keeping $(basename "$old"): it is still attached to a VM."
    else
      rm -f "$old"
      msg_ok "Removed older ISO $(basename "$old")"
    fi
  done
}

# -----------------------------------------------------------------------------
# 3. Settings menus
# -----------------------------------------------------------------------------
get_valid_nextid() {
  local id
  id="$(pvesh get /cluster/nextid)"
  while [[ -e "/etc/pve/qemu-server/${id}.conf" || -e "/etc/pve/lxc/${id}.conf" ]]; do
    id=$((id + 1))
  done
  echo "$id"
}

# Wrapper so every menu has the same backtitle and exits cleanly on Cancel.
# whiptail draws on /dev/tty (so menus stay out of the log) and returns the
# selection on stdout.
wt() { whiptail --backtitle "Proxmox VE Helper - Lubuntu ${LUBUNTU_SERIES} VM" "$@" 3>&1 1>/dev/tty 2>&3; }

select_ram() {
  local choice
  choice="$(wt --title "RAM" --radiolist "Allocate RAM" 14 50 5 \
    "4096"   "4 GB"   OFF \
    "8192"   "8 GB"   ON \
    "12288"  "12 GB"  OFF \
    "16384"  "16 GB"  OFF \
    "custom" "Custom" OFF)" || exit_script
  if [[ "$choice" == "custom" ]]; then
    choice="$(wt --title "RAM" --inputbox "Allocate RAM in MiB" 8 50 "$RAM_SIZE")" || exit_script
    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1024 ]] || { msg_error "RAM must be a number >= 1024 MiB"; exit 1; }
  fi
  RAM_SIZE="$choice"
}

select_storage() {
  local menu=() name type
  while read -r name type _; do
    menu+=("$name" "$type" "$([[ "$name" == "$STORAGE" ]] && echo ON || echo OFF)")
  done < <(pvesm status -content images | awk 'NR>1 {print $1, $2}')
  [[ ${#menu[@]} -gt 0 ]] || { msg_error "No storage supports VM disk images."; exit 1; }
  STORAGE="$(wt --title "STORAGE" --radiolist "Storage pool for the VM disk" 15 60 6 "${menu[@]}")" || exit_script
}

default_settings() {
  VMID="$(get_valid_nextid)"
  # Fall back to the storage picker if local-lvm does not exist on this host.
  pvesm status -storage "$STORAGE" >/dev/null 2>&1 || select_storage
  select_ram
}

advanced_settings() {
  local v
  VMID="$(wt --title "VIRTUAL MACHINE ID" --inputbox "Set Virtual Machine ID" 8 58 "$(get_valid_nextid)")" || exit_script
  if [[ -e "/etc/pve/qemu-server/${VMID}.conf" || -e "/etc/pve/lxc/${VMID}.conf" ]]; then
    msg_error "ID ${VMID} is already in use."; exit 1
  fi

  MACHINE_TYPE="$(wt --title "MACHINE TYPE" --radiolist "Choose machine type" 10 58 2 \
    "q35" "Q35 (modern, PCIe)" ON "i440fx" "i440fx (legacy)" OFF)" || exit_script

  BIOS="$(wt --title "FIRMWARE" --radiolist "Choose firmware" 10 58 2 \
    "ovmf" "UEFI (OVMF)" ON "seabios" "Legacy BIOS (SeaBIOS)" OFF)" || exit_script

  DISK_SIZE="$(wt --title "DISK SIZE" --inputbox "Set Disk Size in GiB" 8 58 "$DISK_SIZE")" || exit_script
  DISK_SIZE="${DISK_SIZE%[gG]}"
  [[ "$DISK_SIZE" =~ ^[0-9]+$ && "$DISK_SIZE" -ge 15 ]] || { msg_error "Disk size must be a number >= 15"; exit 1; }

  DISK_CACHE="$(wt --title "DISK CACHE" --radiolist "Choose disk cache mode" 12 58 4 \
    "none" "None (default)" ON "writethrough" "Write through" OFF \
    "writeback" "Write back" OFF "directsync" "Direct sync" OFF)" || exit_script

  select_storage

  HN="$(wt --title "HOSTNAME" --inputbox "Set Hostname" 8 58 "$HN")" || exit_script
  HN="$(echo "${HN,,}" | tr -d ' ')"

  CPU_TYPE="$(wt --title "CPU MODEL" --radiolist "Choose CPU model" 11 58 3 \
    "x86-64-v2-AES" "Proxmox default" ON "host" "Host (best performance)" OFF \
    "kvm64" "KVM64 (most compatible)" OFF)" || exit_script

  CORE_COUNT="$(wt --title "CORE COUNT" --inputbox "Allocate CPU Cores" 8 58 "$CORE_COUNT")" || exit_script
  [[ "$CORE_COUNT" =~ ^[0-9]+$ && "$CORE_COUNT" -ge 1 ]] || { msg_error "Core count must be a positive number"; exit 1; }

  select_ram

  BRG="$(wt --title "BRIDGE" --inputbox "Set a Bridge" 8 58 "$BRG")" || exit_script
  MAC="$(wt --title "MAC ADDRESS" --inputbox "Set a MAC Address" 8 58 "$MAC")" || exit_script

  v="$(wt --title "VLAN" --inputbox "Set a VLAN tag (leave blank for default)" 8 58 "")" || exit_script
  VLAN="${v:+,tag=$v}"
  v="$(wt --title "MTU SIZE" --inputbox "Set interface MTU (leave blank for default)" 8 58 "")" || exit_script
  MTU="${v:+,mtu=$v}"

  KEYBOARD="$(wt --title "KEYBOARD" --inputbox \
    "Console keyboard layout (blank = Proxmox default).\nNote: the auto-login step types with a US layout." 10 58 "")" || exit_script

  if wt --title "VERBOSE MODE" --defaultno --yesno "Show command output (verbose mode)?" 8 58; then VERBOSE="yes"; fi
  if ! wt --title "START VIRTUAL MACHINE" --yesno "Start VM and continue with the install when done?" 8 58; then START_VM="no"; fi

  wt --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create a Lubuntu ${LUBUNTU_SERIES} VM?" 8 58 \
    || { header_info; advanced_settings; }
}

# Questions about the guest setup (password, SSH, xrdp).
# Ask for a password twice until both entries match and pass the checks.
#   ask_password <title> <prompt> [password it must differ from]
# The result is left in PASSWORD_RESULT.
ask_password() {
  local title="$1" prompt="$2" forbidden="${3:-}" p1 p2
  while true; do
    p1="$(wt --title "$title" --passwordbox "$prompt" 10 64)" || exit_script
    p2="$(wt --title "$title" --passwordbox "Confirm password" 8 64)" || exit_script
    if [[ -z "$p1" ]]; then
      wt --title "ERROR" --msgbox "Password cannot be empty." 8 40
    elif [[ "$p1" != "$p2" ]]; then
      wt --title "ERROR" --msgbox "Passwords do not match." 8 40
    elif ! typeable "$p1"; then
      wt --title "ERROR" --msgbox "Use only letters, digits, spaces and US-keyboard symbols:\nthe script types this password into the VM console." 9 64
    elif [[ -n "$forbidden" && "$p1" == "$forbidden" ]]; then
      wt --title "ERROR" --msgbox "The root password must be different from ${VM_USER}'s password." 8 64
    else
      PASSWORD_RESULT="$p1"; return 0
    fi
  done
}

post_install_settings() {
  ask_password "PASSWORD FOR ${VM_USER}" \
    "Password for user '${VM_USER}'.\nUse the same password when the Lubuntu installer asks."
  VM_PASSWORD="$PASSWORD_RESULT"

  # Optional public key: a file path on this host, or the key pasted in.
  local key
  key="$(wt --title "SSH PUBLIC KEY" --inputbox \
    "Optional: path to a public key file on this host, or paste the key.\nLeave blank to skip." 10 70 \
    "$(ls /root/.ssh/id_*.pub 2>/dev/null | head -n1)")" || exit_script
  if [[ -n "$key" && -f "$key" ]]; then
    SSH_PUBKEY="$(cat "$key")"
  elif [[ "$key" =~ ^(ssh-|ecdsa-|sk-) ]]; then
    SSH_PUBKEY="$key"
  elif [[ -n "$key" ]]; then
    msg_warn "That input is neither a file nor a public key; skipping key upload."
  fi

  if wt --title "PERMIT ROOT LOGIN" --defaultno --yesno \
    "Set 'PermitRootLogin yes' in the SSH server config?" 8 60; then
    wt --title "SECURITY WARNING" --defaultno --yesno \
"WARNING: PermitRootLogin yes lets anyone who can reach port 22 try to log
in as root. Combined with a password this is a common target for
brute-force attacks. Only use it on a trusted, isolated network, and
prefer key-based login.

Enable PermitRootLogin yes anyway?" 14 76 && PERMIT_ROOT="yes"
  fi
  if [[ "$PERMIT_ROOT" == "yes" ]]; then
    msg_warn "PermitRootLogin yes will be enabled. Use only on a trusted network."
  fi

  # Optional root password. Ubuntu leaves root without one (locked).
  if wt --title "ROOT PASSWORD" --defaultno --yesno \
    "Ubuntu's root account has no password by default.\n\nSet a root password? It must be different from ${VM_USER}'s." 11 70; then
    ask_password "ROOT PASSWORD" "Password for root (must differ from ${VM_USER}'s)." "$VM_PASSWORD"
    ROOT_PW="$PASSWORD_RESULT"
  elif [[ "$PERMIT_ROOT" == "yes" && -z "$SSH_PUBKEY" ]]; then
    msg_warn "PermitRootLogin yes without a root password or SSH key: root still cannot log in over SSH."
  fi

  # whiptail treats tags starting with '-' as its own options and exits, so
  # the menu uses plain words and they are mapped to installer switches.
  local flags
  flags="$(wt --title "XRDP OPTIONS" --checklist "c-nergy xrdp installer options" 11 64 2 \
    "sound" "Enable sound redirection (-s)" ON \
    "login" "Customise the xrdp login screen (-l)" OFF)" || exit_script
  XRDP_FLAGS=""
  [[ "$flags" == *sound* ]] && XRDP_FLAGS+="-s "
  [[ "$flags" == *login* ]] && XRDP_FLAGS+="-l "
  XRDP_FLAGS="${XRDP_FLAGS% }"
}

# -----------------------------------------------------------------------------
# 4. Create the VM
# -----------------------------------------------------------------------------
create_vm() {
  msg_info "Creating Lubuntu ${LUBUNTU_SERIES} VM ${VMID} (${HN})"
  local machine_opt="" cache_opt="" kb_opt=""
  [[ "$MACHINE_TYPE" == "q35" ]] && machine_opt="--machine q35"
  [[ "$DISK_CACHE" != "none" ]] && cache_opt=",cache=${DISK_CACHE}"
  [[ -n "$KEYBOARD" ]] && kb_opt="--keyboard ${KEYBOARD}"

  # shellcheck disable=SC2086  # optional flags are intentionally word-split
  qm create "$VMID" --name "$HN" --ostype l26 $machine_opt --bios "$BIOS" \
    --cpu "$CPU_TYPE" --cores "$CORE_COUNT" --memory "$RAM_SIZE" \
    --net0 "virtio,bridge=${BRG},macaddr=${MAC}${VLAN}${MTU}" \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:${DISK_SIZE},discard=on,ssd=1,iothread=1${cache_opt}" \
    --ide2 "${ISO_STORAGE}:iso/${ISO_NAME},media=cdrom" \
    --boot "order=ide2;scsi0" \
    --agent enabled=1 --vga std --tablet 1 --onboot 0 \
    --tags lubuntu --description "Lubuntu ${LUBUNTU_SERIES} desktop, created by lubuntu-vm.sh" \
    $kb_opt >/dev/null

  if [[ "$BIOS" == "ovmf" ]]; then
    qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=1" >/dev/null
  fi
  msg_ok "Created VM ${BL}${VMID}${CL} (${HN})"
}

# -----------------------------------------------------------------------------
# 5. Manual install handoff and console bootstrap
# -----------------------------------------------------------------------------
manual_install_handoff() {
  qm start "$VMID"
  msg_ok "Started VM ${VMID} from the installer ISO"
  local node; node="$(hostname)"
  cat <<EOF

 ${BOLD}Now install Lubuntu in the VM console:${CL}
   Proxmox web UI  ->  ${node}  ->  VM ${VMID} (${HN})  ->  Console

   * Choose "Install Lubuntu" and click through the installer.
   * Your name / username:  ${BOLD}${VM_USER}${CL}
   * Computer name:         ${BOLD}${HN}${CL}
   * Password:              the password you just entered in this script
   * Keyboard layout:       English (US)
   * When it says the installation is complete, ${BOLD}do NOT click Restart${CL}.
     Come back here instead.

EOF
  read -r -p " Press Enter once the installer reports it has finished... " _
}

eject_and_reboot() {
  msg_info "Removing the installer ISO and switching boot to the disk"
  qm set "$VMID" --ide2 none,media=cdrom --boot order=scsi0 >/dev/null
  msg_ok "ISO removed"

  msg_info "Rebooting VM ${VMID} into the installed system"
  # A clean ACPI shutdown of the live session; force it off if it ignores us.
  qm shutdown "$VMID" --timeout 90 >/dev/null 2>&1 || qm stop "$VMID" >/dev/null
  qm start "$VMID"
  msg_ok "VM ${VMID} is booting from disk"
}

# Map one character to a qm sendkey key name (US keyboard layout).
key_for_char() {
  local c="$1"
  case "$c" in
    [a-z0-9]) echo "$c" ;;
    [A-Z])    echo "shift-${c,,}" ;;
    ' ')  echo "spc" ;;
    '-')  echo "minus" ;;        '_')  echo "shift-minus" ;;
    '=')  echo "equal" ;;        '+')  echo "shift-equal" ;;
    '[')  echo "bracket_left" ;; '{')  echo "shift-bracket_left" ;;
    ']')  echo "bracket_right" ;; '}') echo "shift-bracket_right" ;;
    ';')  echo "semicolon" ;;    ':')  echo "shift-semicolon" ;;
    "'")  echo "apostrophe" ;;   '"')  echo "shift-apostrophe" ;;
    '`')  echo "grave_accent" ;; '~')  echo "shift-grave_accent" ;;
    '\')  echo "backslash" ;;    '|')  echo "shift-backslash" ;;
    ',')  echo "comma" ;;        '<')  echo "shift-comma" ;;
    '.')  echo "dot" ;;          '>')  echo "shift-dot" ;;
    '/')  echo "slash" ;;        '?')  echo "shift-slash" ;;
    '!')  echo "shift-1" ;; '@') echo "shift-2" ;; '#') echo "shift-3" ;;
    '$')  echo "shift-4" ;; '%') echo "shift-5" ;; '^') echo "shift-6" ;;
    '&')  echo "shift-7" ;; '*') echo "shift-8" ;; '(') echo "shift-9" ;;
    ')')  echo "shift-0" ;;
    *) return 1 ;;
  esac
}

# Type a string into the VM console, one key at a time.
type_text() {
  local text="$1" i key
  for ((i = 0; i < ${#text}; i++)); do
    key="$(key_for_char "${text:i:1}")" || { msg_error "Text contains a character sendkey cannot type"; return 1; }
    qm sendkey "$VMID" "$key"
  done
}

# True if every character of $1 can be typed with qm sendkey.
typeable() {
  local text="$1" i
  for ((i = 0; i < ${#text}; i++)); do
    key_for_char "${text:i:1}" >/dev/null || return 1
  done
}

guest_agent_up() { qm guest cmd "$VMID" ping >/dev/null 2>&1; }

# Save a PNG screenshot of the VM console into the log directory, so a
# failed auto-login can be diagnosed afterwards. Never fatal.
SHOT_NO=0
screenshot() {
  SHOT_NO=$((SHOT_NO + 1))
  local file
  file="${LOG_DIR}/vm${VMID}-$(date +%H%M%S)-${SHOT_NO}-$1.png"
  if pvesh create "/nodes/$(hostname)/qemu/${VMID}/monitor" \
    --command "screendump ${file} -f png" >/dev/null 2>&1 && [[ -s "$file" ]]; then
    chmod 600 "$file"
    echo "   screenshot: ${file}"
  fi
  return 0
}

# Sleep up to $1 seconds showing a countdown; Enter skips the rest.
countdown() {
  local secs="$1" msg="$2"
  while ((secs > 0)); do
    printf '\r   %s: %3ss left (Enter to skip) ' "$msg" "$secs" >/dev/tty
    if read -r -t 1 _ </dev/tty; then break; fi
    secs=$((secs - 1))
  done
  printf '\r%*s\r' 70 '' >/dev/tty
}

# Seconds since the guest booted, as reported through the guest agent.
guest_uptime() {
  qm guest exec "$VMID" --timeout 15 -- cat /proc/uptime 2>/dev/null \
    | perl -MJSON -0777 -ne 'my $j = decode_json($_); my ($u) = split / /, ($j->{"out-data"} // ""); print int($u || 0)'
}

# Wait up to $1 seconds for the guest agent to answer *after* the reboot
# that ends the bootstrap command typed at epoch second $2. Shows progress.
wait_for_agent_after_reboot() {
  local timeout="$1" typed_at="$2" start now up
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    ((now - start < timeout)) || { echo >/dev/tty; return 1; }
    printf '\r   waiting for the guest agent: %4ss elapsed ' "$((now - start))" >/dev/tty
    if guest_agent_up; then
      up="$(guest_uptime || true)"
      # Booted after the command was typed: the install and reboot are done.
      if [[ -n "$up" && "$up" -gt 0 && "$up" -lt $((now - typed_at)) ]]; then
        echo >/dev/tty
        return 0
      fi
    fi
    sleep 10
  done
}

# Log in at the console, open a terminal and type a command that installs
# the guest agent + SSH server and then reboots the VM. The script does not
# wait for the agent inside that session: it checks for it after the reboot,
# when the agent starts normally at boot.
BOOTSTRAP_CMD="sudo apt-get update && sudo apt-get install -y qemu-guest-agent openssh-server && sudo reboot"

type_bootstrap() {
  countdown 120 "Waiting for the login screen"
  screenshot login-screen

  # Log in. If auto-login was ticked in the installer this just types into
  # the empty desktop, which is harmless.
  msg_info "Logging in as ${VM_USER} at the console"
  qm sendkey "$VMID" ctrl            # wake the screen / focus the password box
  sleep 2
  type_text "$VM_PASSWORD"
  qm sendkey "$VMID" ret
  countdown 60 "Waiting for the desktop"
  screenshot desktop

  msg_info "Opening a terminal (Ctrl+Alt+T)"
  qm sendkey "$VMID" ctrl-alt-t
  sleep 10
  screenshot terminal

  msg_info "Typing: ${BOOTSTRAP_CMD}"
  TYPED_AT=$(date +%s)
  type_text "$BOOTSTRAP_CMD"
  qm sendkey "$VMID" ret
  sleep 5
  type_text "$VM_PASSWORD"           # answers the sudo prompt
  qm sendkey "$VMID" ret
  sleep 15
  screenshot after-sudo
  msg_ok "Command sent. The VM will install the packages and reboot by itself."
}

console_bootstrap() {
  local choice
  type_bootstrap
  while true; do
    msg_info "Checking for the guest agent after the VM reboots (up to 15 minutes)"
    if wait_for_agent_after_reboot 900 "$TYPED_AT"; then
      msg_ok "Guest agent is running after the reboot"
      return 0
    fi
    msg_warn "The guest agent has not answered yet."
    screenshot no-agent
    choice="$(wt --title "GUEST AGENT NOT FOUND" --menu \
"The guest agent did not answer within 15 minutes.
Look at the VM console to see what happened. Screenshots are in ${LOG_DIR}." 16 76 4 \
      "wait"   "Keep waiting another 15 minutes" \
      "retry"  "Reboot the VM and type the command again" \
      "manual" "I will run the command in the console myself" \
      "abort"  "Stop the script (the VM is left as it is)")" || choice="abort"
    case "$choice" in
      wait) ;;
      retry)
        msg_info "Rebooting VM ${VMID} and trying again"
        qm reboot "$VMID" --timeout 120 >/dev/null 2>&1 || { qm stop "$VMID" >/dev/null; qm start "$VMID"; }
        type_bootstrap ;;
      manual)
        cat <<EOF

 In the VM console, log in as ${VM_USER}, open a terminal (Ctrl+Alt+T) and run:

   ${BOLD}${BOOTSTRAP_CMD}${CL}

EOF
        TYPED_AT=$(date +%s)
        msg_info "Waiting for you to run it; the VM reboots when it finishes" ;;
      *)
        msg_error "Stopped at the guest agent step. Log: ${LOG_FILE}"
        exit 1 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# 6. Post-install through the guest agent
# -----------------------------------------------------------------------------
# Run a bash script inside the guest as root. The script text is sent on
# stdin so passwords never appear on a command line.
#   guest_run "Description" <<'EOF' ... EOF
guest_run() {
  local desc="$1" json code out
  msg_info "$desc"
  json="$(qm guest exec "$VMID" --timeout 3600 --pass-stdin 1 -- \
    /usr/bin/env DEBIAN_FRONTEND=noninteractive TERM=dumb \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    bash -s)" || true
  code="$(perl -MJSON -0777 -ne 'my $j = decode_json($_); print exists $j->{exitcode} ? $j->{exitcode} : "timeout"' <<<"$json")"
  out="$(perl -MJSON -0777 -ne 'my $j = decode_json($_); print $j->{"out-data"} // ""; print $j->{"err-data"} // ""' <<<"$json")"
  if [[ "$VERBOSE" == "yes" && -n "$out" ]]; then echo "$out"; fi
  if [[ "$code" != "0" ]]; then
    msg_error "${desc} failed (exit ${code}). Last output:"
    echo "$out" | tail -n 20 >&2
    return 1
  fi
  msg_ok "$desc"
}

post_install() {
  guest_run "Installing nala" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
apt-get update
apt-get install -y nala
EOF

  guest_run "Upgrading the system with nala (this can take a while)" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
nala upgrade -y
EOF

  # OpenSSH: key upload and optional PermitRootLogin. Values are passed in as
  # shell variables at the top of the script so quoting stays safe.
  guest_run "Configuring OpenSSH server" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
VM_USER=$(printf '%q' "$VM_USER")
SSH_PUBKEY=$(printf '%q' "$SSH_PUBKEY")
PERMIT_ROOT=$(printf '%q' "$PERMIT_ROOT")
ROOT_PW=$(printf '%q' "$ROOT_PW")

apt-get install -y openssh-server
add_key() {   # add_key <home> <owner>
  install -d -m 700 -o "\$2" -g "\$2" "\$1/.ssh"
  grep -qxF "\$SSH_PUBKEY" "\$1/.ssh/authorized_keys" 2>/dev/null || echo "\$SSH_PUBKEY" >>"\$1/.ssh/authorized_keys"
  chown "\$2:\$2" "\$1/.ssh/authorized_keys"; chmod 600 "\$1/.ssh/authorized_keys"
}
if [ -n "\$SSH_PUBKEY" ]; then
  add_key "/home/\$VM_USER" "\$VM_USER"
  [ "\$PERMIT_ROOT" = yes ] && add_key /root root
fi
if [ "\$PERMIT_ROOT" = yes ]; then
  echo "PermitRootLogin yes" >/etc/ssh/sshd_config.d/10-permit-root-login.conf
fi
if [ -n "\$ROOT_PW" ]; then
  echo "root:\$ROOT_PW" | chpasswd
fi
systemctl enable --now ssh
systemctl restart ssh
EOF

  guest_run "Enabling qemu-guest-agent" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
apt-get install -y qemu-guest-agent
systemctl enable qemu-guest-agent || true   # static unit on Ubuntu; started by udev
EOF

  install_xrdp || msg_warn "xrdp install failed; see ${GUEST_LOG} in the VM. Continuing."
}

# Find the newest xrdp-installer-X.Y.zip on c-nergy.be (fallback: 1.6).
latest_xrdp_url() {
  local url
  url="$(curl -fsSL "$XRDP_PRODUCTS_URL" 2>/dev/null \
    | grep -oE 'https?://(www\.)?c-nergy\.be/downloads/xRDP/xrdp-installer-[0-9.]+\.zip' \
    | sort -uV | tail -n1)" || true
  echo "${url:-$XRDP_FALLBACK_URL}"
}

install_xrdp() {
  local url; url="$(latest_xrdp_url)"
  msg_ok "Using xrdp installer ${BL}${url}${CL}"
  # The c-nergy installer refuses to run as root and calls sudo itself, so
  # sadmin gets passwordless sudo for the duration of this step only.
  guest_run "Installing xrdp with the c-nergy installer" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
VM_USER=$(printf '%q' "$VM_USER")
URL=$(printf '%q' "$url")
FLAGS=$(printf '%q' "$XRDP_FLAGS")
SUDOERS=/etc/sudoers.d/99-xrdp-installer-temp
trap 'rm -f "\$SUDOERS"' EXIT

apt-get install -y unzip wget
echo "\$VM_USER ALL=(ALL) NOPASSWD:ALL" >"\$SUDOERS"; chmod 440 "\$SUDOERS"

WORK="/home/\$VM_USER/xrdp-installer"
rm -rf "\$WORK"; install -d -o "\$VM_USER" -g "\$VM_USER" "\$WORK"
cd "\$WORK"
sudo -u "\$VM_USER" wget -q "\$URL" -O xrdp-installer.zip
sudo -u "\$VM_USER" unzip -o -q xrdp-installer.zip
SCRIPT="\$(ls xrdp-installer-*.sh | sort -V | tail -n1)"
chmod +x "\$SCRIPT"
# shellcheck disable=SC2086
sudo -u "\$VM_USER" -H env XDG_CURRENT_DESKTOP=LXQt bash "./\$SCRIPT" \$FLAGS </dev/null
systemctl enable xrdp
EOF
}

# Show the VM's IPv4 address and check that SSH answers.
check_ssh() {
  local ip
  ip="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null \
    | perl -MJSON -0777 -ne 'for my $i (@{decode_json($_)}) { next if $i->{name} eq "lo";
        for my $a (@{$i->{"ip-addresses"} || []}) { if ($a->{"ip-address-type"} eq "ipv4") { print $a->{"ip-address"}; exit } } }')" || true
  if [[ -z "$ip" ]]; then
    msg_warn "Could not read the VM's IP address from the guest agent."
    return 0
  fi
  VM_IP="$ip"
  if timeout 5 bash -c "</dev/tcp/${ip}/22" 2>/dev/null; then
    msg_ok "SSH is reachable: ${BL}ssh ${VM_USER}@${ip}${CL}"
  else
    msg_warn "SSH port 22 on ${ip} is not answering yet."
  fi
}

# -----------------------------------------------------------------------------
# 7. Shut down and snapshot
# -----------------------------------------------------------------------------
shutdown_and_snapshot() {
  msg_info "Shutting down VM ${VMID}"
  qm shutdown "$VMID" --timeout 180 >/dev/null 2>&1 || {
    msg_warn "Clean shutdown timed out; forcing stop."
    qm stop "$VMID" >/dev/null
  }
  msg_ok "VM ${VMID} is stopped"

  msg_info "Taking snapshot '${SNAPSHOT_NAME}'"
  qm snapshot "$VMID" "$SNAPSHOT_NAME" \
    --description "Fresh Lubuntu ${LUBUNTU_SERIES} install: nala, upgrades, OpenSSH, qemu-guest-agent, xrdp. Created $(date '+%F %T')." >/dev/null
  msg_ok "Snapshot '${SNAPSHOT_NAME}' created"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  header_info
  preflight
  start_logging
  msg_ok "Logging to ${BL}${LOG_FILE}${CL}"
  ensure_iso

  if wt --title "SETTINGS" --yesno \
"Use default settings?

  Machine q35, UEFI, 2 CPU cores, 30 GiB disk (cache none)
  on ${STORAGE}, bridge ${BRG}. You pick the RAM size.

Choose No for advanced settings." 13 64; then
    default_settings
  else
    header_info
    advanced_settings
  fi
  post_install_settings

  header_info
  echo -e " ${BOLD}VM ${VMID}${CL}: ${HN}, ${MACHINE_TYPE}/${BIOS}, ${CORE_COUNT} cores (${CPU_TYPE}), ${RAM_SIZE} MiB RAM,"
  echo -e "        ${DISK_SIZE} GiB on ${STORAGE} (cache ${DISK_CACHE}), ${BRG} ${MAC}${VLAN}${MTU}"
  echo -e " ISO:   ${ISO_NAME}"
  echo -e " SSH:   key $([[ -n "$SSH_PUBKEY" ]] && echo yes || echo no), PermitRootLogin ${PERMIT_ROOT}"
  echo -e " Root:  password $([[ -n "$ROOT_PW" ]] && echo set || echo "not set")"
  echo -e " xrdp:  flags '${XRDP_FLAGS:-none}'"
  echo

  create_vm
  if [[ "$START_VM" != "yes" ]]; then
    msg_ok "VM created but not started (as requested). Start it and install Lubuntu manually."
    exit 0
  fi

  manual_install_handoff
  eject_and_reboot
  console_bootstrap
  post_install
  check_ssh
  shutdown_and_snapshot

  echo
  msg_ok "${GN}Done.${CL} Lubuntu ${LUBUNTU_SERIES} VM ${VMID} (${HN}) is ready, with snapshot '${SNAPSHOT_NAME}'."
  [[ -z "${VM_IP:-}" ]] || echo -e "   Start it, then connect with ${BL}ssh ${VM_USER}@${VM_IP}${CL} or RDP to ${BL}${VM_IP}:3389${CL}"
  if [[ "$PERMIT_ROOT" == "yes" ]]; then
    msg_warn "Reminder: PermitRootLogin yes is enabled. Keep this VM on a trusted network."
  fi
  echo "   Log file: ${LOG_FILE}"
}

main "$@"
