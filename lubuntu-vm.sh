#!/usr/bin/env bash
# =============================================================================
# lubuntu-vm.sh - Build a Lubuntu 26.04 desktop VM on Proxmox VE 9
# =============================================================================
#
# Run as root on the Proxmox host:   bash lubuntu-vm.sh
#
# Fully unattended: no installer to click through and no console typing.
#
# What it does, in order:
#   1. Restarts itself inside a tmux session (if not already in one), so it
#      keeps running when you close the Proxmox shell. Reattach with
#      'tmux attach -t lubuntu-vm'.
#   2. Pre-flight checks (root, Proxmox VE 9, required tools).
#   3. Downloads the official Ubuntu 26.04 server cloud image (or reuses the
#      cached copy when its SHA256 still matches the newest release).
#   4. Asks for VM settings with whiptail menus ("default" or "advanced",
#      modelled on community-scripts' ubuntu-vm.sh), the 'sadmin' password,
#      SSH options, an optional root password and xrdp options.
#   5. Creates the VM from the cloud image. cloud-init creates 'sadmin' and
#      installs qemu-guest-agent + openssh-server on first boot.
#   6. Through the guest agent (qm guest exec) it installs lubuntu-desktop
#      (the package set the Lubuntu ISO installs), nala, runs nala upgrade,
#      configures OpenSSH (optional key, optional PermitRootLogin yes, root
#      password) and runs the newest c-nergy xrdp installer.
#   7. Disables cloud-init, removes its config, reboots once to check the
#      desktop login comes up, shuts down and takes the snapshot
#      'initial-install'.
#
# Assumptions / limits:
#   * The VM needs internet access through the chosen bridge (DHCP).
#   * cloud-init reads its config from a "snippets" storage; if none exists
#     the script offers to enable snippets on the 'local' storage. The
#     snippet holds only a SHA-512 hash of the sadmin password, is mode 0600
#     and is deleted once the VM is set up.
#   * Everything that runs inside the guest is logged to
#     /var/log/lubuntu-vm-setup.log in the guest.
#   * Everything shown on screen is also logged on the host to
#     /var/log/lubuntu-vm/lubuntu-vm-<date>.log (root-only, 0600). Passwords
#     are never printed, so they never reach the log.
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
LUBUNTU_SERIES="26.04"
UBUNTU_CODENAME="resolute"
CLOUD_IMAGE_BASE="https://cloud-images.ubuntu.com/releases/server/${UBUNTU_CODENAME}/release"
CLOUD_IMAGE_NAME="ubuntu-${LUBUNTU_SERIES}-server-cloudimg-amd64.img"
IMAGE_CACHE_DIR="/var/lib/vz/template/cache"   # where the cloud image is cached
TMUX_SESSION="lubuntu-vm"
SCRIPT_URL="https://raw.githubusercontent.com/solchjg/lubuntu-proxmox-vm-install/main/lubuntu-vm.sh"
XRDP_PRODUCTS_URL="https://www.c-nergy.be/products.html"
XRDP_FALLBACK_URL="https://c-nergy.be/downloads/xRDP/xrdp-installer-1.6.zip"
VM_USER="sadmin"
SNAPSHOT_NAME="initial-install"
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
DISPLAY_TYPE="virtio"     # VirtIO-GPU (std VGA showed no console in testing)
VERBOSE="no"
START_VM="yes"
VM_CREATED="no"           # set once qm create succeeds; lets abort clean up
SNIPPET_STORAGE=""        # storage holding the cloud-init user-data snippet
SNIPPET_PATH=""

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
  umask 022   # back to normal for the image and anything else the script writes
}
trap cleanup EXIT
trap 'msg_error "Failed at line $LINENO: $BASH_COMMAND"' ERR
trap 'trap - INT; abort_install "Interrupted (Ctrl+C)."' INT

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
# 0. Keep running when the shell closes
# -----------------------------------------------------------------------------
# Closing the Proxmox web shell kills whatever runs in it. Unless we are
# already inside tmux, start a tmux session that runs this script and attach
# to it. If the shell closes, the session keeps going:
#   tmux attach -t lubuntu-vm
ensure_tmux() {
  local ans cmd
  [[ -n "${TMUX:-}" || "${LUBUNTU_VM_NO_TMUX:-0}" == "1" ]] && return 0
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo " A '${TMUX_SESSION}' session is already running; attaching to it."
    exec tmux attach -t "$TMUX_SESSION"
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    echo " tmux keeps this script running if the Proxmox shell is closed."
    read -r -p " Install tmux now (apt-get install tmux)? [Y/n]: " ans
    if [[ "${ans,,}" == n* ]]; then
      echo " Continuing without tmux: keep this shell open until the script ends."
      return 0
    fi
    apt-get install -y tmux >/dev/null || { echo " Could not install tmux; continuing without it."; return 0; }
  fi
  # Run from this file if we have one, otherwise fetch the script again
  # (it was started with: bash -c "$(curl ...)").
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    cmd="bash $(printf '%q' "$(readlink -f "${BASH_SOURCE[0]}")")"
  else
    cmd="bash -c \"\$(curl -fsSL ${SCRIPT_URL})\""
  fi
  tmux new-session -d -s "$TMUX_SESSION" \
    "${cmd}; echo; read -r -p ' Script finished. Press Enter to close this tmux session. ' _"
  echo " Started tmux session '${TMUX_SESSION}'. If this shell closes, reattach with:"
  echo "   tmux attach -t ${TMUX_SESSION}"
  sleep 2
  exec tmux attach -t "$TMUX_SESSION"
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
  for tool in curl whiptail sha256sum perl qm pvesm pvesh openssl; do
    command -v "$tool" >/dev/null 2>&1 || { msg_error "Missing required tool: $tool"; exit 1; }
  done
}

# -----------------------------------------------------------------------------
# 2. Cloud image
# -----------------------------------------------------------------------------
# Download the newest Ubuntu 26.04 cloud image into the cache, or reuse the
# cached copy if it still matches the published SHA256. Sets IMAGE_PATH.
ensure_image() {
  local sha
  msg_info "Checking the newest Ubuntu ${LUBUNTU_SERIES} cloud image"
  sha="$(curl -fsSL "${CLOUD_IMAGE_BASE}/SHA256SUMS" | awk -v f="*${CLOUD_IMAGE_NAME}" '$2==f {print $1}')"
  if [[ -z "$sha" ]]; then
    msg_error "No checksum published for ${CLOUD_IMAGE_NAME} at ${CLOUD_IMAGE_BASE}"
    exit 1
  fi
  mkdir -p "$IMAGE_CACHE_DIR"
  IMAGE_PATH="${IMAGE_CACHE_DIR}/${CLOUD_IMAGE_NAME}"
  if [[ -f "$IMAGE_PATH" ]] && echo "${sha}  ${IMAGE_PATH}" | sha256sum -c --status; then
    msg_ok "Cached cloud image is the newest release: ${IMAGE_PATH}"
    return 0
  fi
  [[ -f "$IMAGE_PATH" ]] && msg_info "Cached image is outdated; downloading the new release"
  msg_info "Downloading ${CLOUD_IMAGE_BASE}/${CLOUD_IMAGE_NAME}"
  curl -fL --progress-bar -o "${IMAGE_PATH}.part" "${CLOUD_IMAGE_BASE}/${CLOUD_IMAGE_NAME}" 2>/dev/tty
  if ! echo "${sha}  ${IMAGE_PATH}.part" | sha256sum -c --status; then
    rm -f "${IMAGE_PATH}.part"
    msg_error "Checksum mismatch for ${CLOUD_IMAGE_NAME}; download removed."
    exit 1
  fi
  mv -f "${IMAGE_PATH}.part" "$IMAGE_PATH"   # replaces the older image
  msg_ok "Downloaded and verified ${CLOUD_IMAGE_NAME}"
}

# Find a storage that can hold cloud-init snippets. If there is none, offer
# to add 'snippets' to the content types of the 'local' storage.
ensure_snippet_storage() {
  local ans content
  SNIPPET_STORAGE="$(pvesm status -content snippets 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')"
  if [[ -z "$SNIPPET_STORAGE" ]]; then
    echo
    echo " cloud-init needs a storage with the 'snippets' content type, and none has it."
    read -r -p " Enable snippets on the 'local' storage? [Y/n]: " ans
    if [[ "${ans,,}" == n* ]]; then
      msg_error "Cannot continue without snippets storage."
      exit 1
    fi
    content="$(pvesh get /storage/local --output-format json | perl -MJSON -0777 -ne 'print decode_json($_)->{content}')"
    pvesm set local --content "${content},snippets"
    SNIPPET_STORAGE="local"
    msg_ok "Enabled snippets on 'local'"
  fi
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

  DISPLAY_TYPE="$(wt --title "DISPLAY" --radiolist \
    "Graphic card for the VM console." 12 70 3 \
    "virtio" "VirtIO-GPU (default)" ON "std" "Standard VGA" OFF "qxl" "SPICE (qxl)" OFF)" || exit_script

  KEYBOARD="$(wt --title "KEYBOARD" --inputbox \
    "Console keyboard layout (blank = Proxmox default)." 9 58 "")" || exit_script

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
    elif [[ -n "$forbidden" && "$p1" == "$forbidden" ]]; then
      wt --title "ERROR" --msgbox "The root password must be different from ${VM_USER}'s password." 8 64
    else
      PASSWORD_RESULT="$p1"; return 0
    fi
  done
}

post_install_settings() {
  ask_password "PASSWORD FOR ${VM_USER}" "Password for user '${VM_USER}'."
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

  # The system disk is imported from the cloud image, then grown to size.
  # shellcheck disable=SC2086  # optional flags are intentionally word-split
  qm create "$VMID" --name "$HN" --ostype l26 $machine_opt --bios "$BIOS" \
    --cpu "$CPU_TYPE" --cores "$CORE_COUNT" --memory "$RAM_SIZE" \
    --net0 "virtio,bridge=${BRG},macaddr=${MAC}${VLAN}${MTU}" \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:0,import-from=${IMAGE_PATH},discard=on,ssd=1,iothread=1${cache_opt}" \
    --boot order=scsi0 \
    --agent enabled=1 --vga "$DISPLAY_TYPE" --serial0 socket --tablet 1 --onboot 0 \
    --tags lubuntu --description "Lubuntu ${LUBUNTU_SERIES} desktop, created by lubuntu-vm.sh" \
    $kb_opt >/dev/null
  VM_CREATED="yes"

  if [[ "$BIOS" == "ovmf" ]]; then
    qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=1" >/dev/null
  fi
  qm disk resize "$VMID" scsi0 "${DISK_SIZE}G" >/dev/null
  msg_ok "Created VM ${BL}${VMID}${CL} (${HN}) with a ${DISK_SIZE} GiB disk from the cloud image"

  write_cloud_init
}

# cloud-init first-boot config: create sadmin (password stored as a SHA-512
# hash only), allow SSH password login, install the guest agent + SSH server.
# Everything else is done later through the guest agent.
write_cloud_init() {
  local hash snippet_dir
  msg_info "Writing the cloud-init configuration"
  hash="$(printf '%s' "$VM_PASSWORD" | openssl passwd -6 -stdin)"
  snippet_dir="$(dirname "$(pvesm path "${SNIPPET_STORAGE}:snippets/x.yaml")")"
  mkdir -p "$snippet_dir"
  SNIPPET_PATH="${snippet_dir}/lubuntu-vm-${VMID}-user.yaml"
  (
    umask 077
    cat >"$SNIPPET_PATH" <<EOF
#cloud-config
hostname: ${HN}
users:
  - name: ${VM_USER}
    gecos: ${VM_USER}
    groups: [adm, sudo, plugdev, audio, video]
    shell: /bin/bash
    lock_passwd: false
    passwd: '${hash}'
ssh_pwauth: true
package_update: true
packages:
  - qemu-guest-agent
  - openssh-server
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
EOF
  )
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit" \
    --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$SNIPPET_PATH")" \
    --ipconfig0 ip=dhcp >/dev/null
  msg_ok "cloud-init will create ${VM_USER} and install the guest agent on first boot"
}

# -----------------------------------------------------------------------------
# 5. First boot: wait for cloud-init and the guest agent
# -----------------------------------------------------------------------------
# Abort: optionally stop and destroy the VM this script created (with its
# disks), then exit. The cached image and the log are kept.
abort_install() {
  local reason="$1" ans
  echo
  msg_warn "$reason"
  if [[ -n "${VMID:-}" && -e "/etc/pve/qemu-server/${VMID}.conf" && "${VM_CREATED:-no}" == "yes" ]]; then
    read -r -p " Delete VM ${VMID} (${HN}) and all its disks? [y/N]: " ans
    if [[ "${ans,,}" == y || "${ans,,}" == yes ]]; then
      msg_info "Stopping VM ${VMID}"
      qm stop "$VMID" >/dev/null 2>&1 || true
      msg_info "Destroying VM ${VMID} and its disks"
      if qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1; then
        msg_ok "VM ${VMID} and its disks were removed"
      else
        msg_error "Could not destroy VM ${VMID}; remove it in the web UI."
      fi
    else
      msg_ok "VM ${VMID} was left as it is."
    fi
  fi
  [[ -n "$SNIPPET_PATH" ]] && rm -f "$SNIPPET_PATH"
  echo "   The cached cloud image stays in ${IMAGE_CACHE_DIR}. Log: ${LOG_FILE}"
  exit 1
}

guest_agent_up() { qm guest cmd "$VMID" ping >/dev/null 2>&1; }

# Save a PNG screenshot of the VM console into the log directory, so a
# problem can be diagnosed afterwards. Never fatal.
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

# Wait up to $1 seconds for the guest agent, printing a status line every
# 30 seconds (elapsed time and packets received from the VM).
wait_for_agent() {
  local timeout="$1" start now rx last=-30
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    if guest_agent_up; then
      msg_ok "Guest agent is answering after $((now - start))s"
      return 0
    fi
    if ((now - start >= timeout)); then return 1; fi
    if ((now - start - last >= 30)); then
      last=$((now - start))
      rx=$(cat "/sys/class/net/tap${VMID}i0/statistics/rx_packets" 2>/dev/null || echo 0)
      printf ' [%02d:%02d] VM %s | packets from VM: %s | waiting for cloud-init + guest agent\n' \
        $((last / 60)) $((last % 60)) "$(qm status "$VMID" | awk '{print $2}')" "$rx"
    fi
    sleep 5
  done
}

first_boot() {
  local ans
  qm start "$VMID"
  msg_ok "Started VM ${VMID}"
  msg_info "First boot: cloud-init creates ${VM_USER} and installs the guest agent (usually 2-5 minutes)"
  while ! wait_for_agent 900; do
    screenshot no-agent
    msg_warn "The guest agent has not answered after 15 minutes."
    echo "   Check the VM console (or the screenshot above) for errors, e.g. no network."
    read -r -p " Keep waiting another 15 minutes? [Y/n]: " ans
    [[ "${ans,,}" == n* ]] && abort_install "Stopped waiting for the guest agent."
  done
  # cloud-init may still be finishing package installs; let it complete.
  guest_run "Waiting for cloud-init to finish" <<'EOF'
cloud-init status --wait >/dev/null || true
EOF
}

# Reboot and wait for the agent again (used to confirm the desktop boots).
reboot_and_wait() {
  msg_info "Rebooting VM ${VMID}"
  qm reboot "$VMID" --timeout 180 >/dev/null 2>&1 || { qm stop "$VMID" >/dev/null; qm start "$VMID"; }
  wait_for_agent 600 || abort_install "The VM did not come back after the reboot."
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
  json="$(qm guest exec "$VMID" --timeout 7200 --pass-stdin 1 -- \
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
  guest_run "Installing the Lubuntu desktop (lubuntu-desktop, about 1-2 GB of downloads)" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
apt-get update
apt-get install -y lubuntu-desktop linux-generic
systemctl set-default graphical.target
# Groups the Lubuntu installer gives the first user (they exist only now).
for g in lpadmin sambashare dip; do
  if getent group "\$g" >/dev/null; then usermod -aG "\$g" ${VM_USER}; fi
done
EOF

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

# Stop cloud-init from running again (it would reset hostname/users on
# clones), switch networking to NetworkManager, remove the cloud-init drive
# and the snippet with the password hash, then reboot once and check that the
# graphical login (SDDM) starts.
finalize() {
  guest_run "Disabling cloud-init for future boots" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
touch /etc/cloud/cloud-init.disabled
# Hand the network to NetworkManager (as on a normal Lubuntu install) instead
# of the systemd-networkd config cloud-init wrote.
rm -f /etc/netplan/50-cloud-init.yaml
printf 'network:\n  version: 2\n  renderer: NetworkManager\n' >/etc/netplan/01-network-manager-all.yaml
chmod 600 /etc/netplan/01-network-manager-all.yaml
EOF
  qm set "$VMID" --delete cicustom,ide2 >/dev/null
  rm -f "$SNIPPET_PATH"
  msg_ok "Removed the cloud-init drive and config snippet"

  reboot_and_wait
  if guest_run "Checking that the graphical login is running" <<'EOF'
systemctl is-active --quiet display-manager
EOF
  then
    screenshot desktop-login
  else
    msg_warn "The display manager is not active; check the VM console."
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
  ensure_tmux
  header_info
  preflight
  start_logging
  msg_ok "Logging to ${BL}${LOG_FILE}${CL}"
  ensure_image
  ensure_snippet_storage

  if wt --title "SETTINGS" --yesno \
"Use default settings?

  Machine q35, UEFI, VirtIO-GPU, 2 CPU cores, 30 GiB disk (cache none)
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
  echo -e " Image: ${CLOUD_IMAGE_NAME} + lubuntu-desktop"
  echo -e " SSH:   key $([[ -n "$SSH_PUBKEY" ]] && echo yes || echo no), PermitRootLogin ${PERMIT_ROOT}"
  echo -e " Root:  password $([[ -n "$ROOT_PW" ]] && echo set || echo "not set")"
  echo -e " xrdp:  flags '${XRDP_FLAGS:-none}'   Display: ${DISPLAY_TYPE}"
  echo

  create_vm
  if [[ "$START_VM" != "yes" ]]; then
    msg_ok "VM created but not started (as requested). cloud-init runs when you start it;"
    echo "   the desktop, nala, SSH and xrdp steps of this script are skipped."
    exit 0
  fi

  first_boot
  post_install
  finalize
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
