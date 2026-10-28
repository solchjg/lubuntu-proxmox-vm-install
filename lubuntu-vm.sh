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
#   4. Asks for VM settings with plain terminal prompts ("default" or "advanced",
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
# Rerun the script and choose "Modify an existing VM" to change RAM, cores,
# MAC, display or disk size, rerun setup steps, or roll back / take snapshots.
# At the end it can upload the log and screenshots to a private GitHub repo.
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
XRDP_FLAGS=""             # c-nergy switches: -s sound redirection, -l custom login screen
INSTALL_BROWSERS="no"     # replace Firefox snap with Mozilla deb, remove snapd, add Brave
SHOTS=()                  # screenshots taken in this run (for upload)
GH_CONF_DIR="/root/.config/lubuntu-vm"    # upload settings (repo + token), root only

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
msg_info()  { echo -e " ${YW}…${CL} $*"; }
msg_ok()    { echo -e " ${GN}✓${CL} $*"; }
msg_warn()  { echo -e " ${YW}!${CL} ${YW}$*${CL}"; }
msg_error() { echo -e " ${RD}✗ $*${CL}" >&2; }

cleanup() { rm -rf "$TEMP_DIR"; }

# Copy everything printed to stdout/stderr into LOG_FILE, with colour codes
# stripped. The directory and file are readable by root only. Prompts are
# logged, but what you type is not (the terminal echoes it, not the script),
# passwords are read with echo off, and the script never prints a password.
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
  echo
  echo " The script now runs inside the tmux session '${TMUX_SESSION}'."
  echo " If this shell closes or you leave the page, it keeps running."
  echo " To get back to it later, open a shell on this host and run:"
  echo
  echo "     tmux attach -t ${TMUX_SESSION}"
  echo
  read -r -t 30 -p " Press Enter to continue (continues by itself in 30 seconds)... " _ || true
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
    ask_yn "This script was written for Proxmox VE 9. Continue anyway?" n || exit_script
  fi
  local tool
  for tool in curl sha256sum perl qm pvesm pvesh openssl; do
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

# Plain terminal prompts. Each shows the default in brackets; Enter keeps it.
#   ask VAR "Question" "default"
ask() {
  local _answer
  read -r -p " $2 [$3]: " _answer
  printf -v "$1" '%s' "${_answer:-$3}"
}

#   ask_yn "Question" y|n    -> returns 0 for yes
ask_yn() {
  local a hint
  [[ "$2" == y ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -r -p " $1 [$hint]: " a
    case "${a:-$2}" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO]) return 1 ;;
    esac
    echo " Please answer y or n."
  done
}

#   choose VAR "Question" default_number value1 "label1" value2 "label2" ...
choose() {
  local var="$1" question="$2" def="$3" n i=1 a
  shift 3
  local values=() labels=()
  while (($#)); do values+=("$1"); labels+=("$2"); shift 2; done
  n=${#values[@]}
  echo " $question"
  for ((i = 1; i <= n; i++)); do
    printf '   %d) %s%s\n' "$i" "${labels[i-1]}" "$([[ $i -eq $def ]] && echo '  (default)')"
  done
  while true; do
    read -r -p " Choice [${def}]: " a
    a="${a:-$def}"
    if [[ "$a" =~ ^[0-9]+$ ]] && ((a >= 1 && a <= n)); then
      printf -v "$var" '%s' "${values[a-1]}"
      return 0
    fi
    echo " Please enter a number from 1 to ${n}."
  done
}

select_ram() {
  local choice
  choose choice "Allocate RAM:" 2 4096 "4 GB" 8192 "8 GB" 12288 "12 GB" 16384 "16 GB" custom "Custom"
  if [[ "$choice" == "custom" ]]; then
    while true; do
      ask choice "RAM in MiB" "$RAM_SIZE"
      [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1024 ]] && break
      echo " RAM must be a number of at least 1024 MiB."
    done
  fi
  RAM_SIZE="$choice"
}

select_storage() {
  local args=() name type def=1 i=0
  while read -r name type; do
    i=$((i + 1))
    args+=("$name" "$name ($type)")
    [[ "$name" == "$STORAGE" ]] && def=$i
  done < <(pvesm status -content images | awk 'NR>1 {print $1, $2}')
  ((i > 0)) || { msg_error "No storage supports VM disk images."; exit 1; }
  choose STORAGE "Storage for the VM disk:" "$def" "${args[@]}"
}

default_settings() {
  VMID="$(get_valid_nextid)"
  # Fall back to the storage picker if local-lvm does not exist on this host.
  pvesm status -storage "$STORAGE" >/dev/null 2>&1 || select_storage
  select_ram
  ask_mac
}

# True if MAC $1 is used by any VM or container in the cluster other than
# VM $2 (pass the VM being modified, or nothing for a new VM).
mac_in_use() {
  local mac="$1" skip="${2:-}" f
  for f in /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf; do
    [[ -e "$f" ]] || continue
    [[ -n "$skip" && "$f" == */qemu-server/"${skip}".conf ]] && continue
    if grep -qi -- "$mac" "$f"; then
      echo "$(basename "$f" .conf) ($(basename "$(dirname "$f")"))"
      return 0
    fi
  done
  return 1
}

# Optionally use a preset MAC address instead of the generated one.
#   ask_mac [VMID being modified]
# Checks the format, that it is a unicast address, that no other guest on
# the cluster uses it, and warns if the address is already seen on the LAN.
ask_mac() {
  local skip="${1:-}" mac used
  if ! ask_yn "Use a preset MAC address? (n = generated ${MAC})" n; then
    return 0
  fi
  while true; do
    ask mac "MAC address (format AA:BB:CC:DD:EE:FF)" ""
    mac="${mac^^}"; mac="${mac//-/:}"
    if [[ ! "$mac" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; then
      echo " That is not a valid MAC address."; continue
    fi
    if (( 0x${mac:0:2} & 1 )); then
      echo " That is a multicast address (first byte is odd); use a unicast address."; continue
    fi
    if [[ "$mac" == "00:00:00:00:00:00" ]]; then
      echo " 00:00:00:00:00:00 is not allowed."; continue
    fi
    if used="$(mac_in_use "$mac" "$skip")"; then
      echo " ${mac} is already used by guest ${used}."; continue
    fi
    if ip neigh show 2>/dev/null | grep -qi -- "$mac" || bridge fdb show 2>/dev/null | grep -qi -- "$mac"; then
      msg_warn "${mac} is currently active on the network (another device may be using it)."
      ask_yn "Use it anyway?" n || continue
    fi
    MAC="$mac"
    msg_ok "Using MAC address ${MAC}"
    return 0
  done
}

# Ask for a positive whole number (with a minimum) until it is valid.
ask_number() {
  local var="$1" question="$2" def="$3" min="$4" v
  while true; do
    ask v "$question" "$def"
    v="${v%[gG]}"
    if [[ "$v" =~ ^[0-9]+$ ]] && ((v >= min)); then printf -v "$var" '%s' "$v"; return 0; fi
    echo " Please enter a whole number of at least ${min}."
  done
}

advanced_settings() {
  local v
  echo
  echo " ${BOLD}Advanced settings${CL} (press Enter to keep the value in brackets)"
  while true; do
    ask VMID "Virtual Machine ID" "$(get_valid_nextid)"
    if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
      echo " The ID must be a number."
    elif [[ -e "/etc/pve/qemu-server/${VMID}.conf" || -e "/etc/pve/lxc/${VMID}.conf" ]]; then
      echo " ID ${VMID} is already in use."
    else
      break
    fi
  done
  choose MACHINE_TYPE "Machine type:" 1 q35 "Q35 (modern, PCIe)" i440fx "i440fx (legacy)"
  choose BIOS "Firmware:" 1 ovmf "UEFI (OVMF)" seabios "Legacy BIOS (SeaBIOS)"
  ask_number DISK_SIZE "Disk size in GiB" "$DISK_SIZE" 15
  choose DISK_CACHE "Disk cache:" 1 none "None" writethrough "Write through" writeback "Write back" directsync "Direct sync"
  select_storage
  ask HN "Hostname" "$HN"
  HN="$(echo "${HN,,}" | tr -d ' ')"
  choose CPU_TYPE "CPU model:" 1 x86-64-v2-AES "x86-64-v2-AES (Proxmox default)" host "host (best performance)" kvm64 "kvm64 (most compatible)"
  ask_number CORE_COUNT "CPU cores" "$CORE_COUNT" 1
  select_ram
  ask BRG "Bridge" "$BRG"
  ask_mac
  ask v "VLAN tag (blank = none)" ""
  VLAN="${v:+,tag=$v}"
  ask v "Interface MTU (blank = default)" ""
  MTU="${v:+,mtu=$v}"
  choose DISPLAY_TYPE "Display:" 1 virtio "VirtIO-GPU" std "Standard VGA" qxl "SPICE (qxl)"
  ask KEYBOARD "Console keyboard layout (blank = Proxmox default)" ""
  if ask_yn "Verbose mode (show command output)?" n; then VERBOSE="yes"; fi
  if ! ask_yn "Start the VM and run the full setup when it is created?" y; then START_VM="no"; fi
  ask_yn "Ready to create the VM with these settings?" y || advanced_settings
}

# Ask for a password twice (typing is hidden) until both entries match.
#   ask_password "Prompt" [password it must differ from]
# The result is left in PASSWORD_RESULT.
ask_password() {
  local prompt="$1" forbidden="${2:-}" p1 p2
  while true; do
    read -r -s -p " ${prompt}: " p1; echo
    read -r -s -p " Confirm password: " p2; echo
    if [[ -z "$p1" ]]; then
      echo " Password cannot be empty."
    elif [[ "$p1" != "$p2" ]]; then
      echo " Passwords do not match; try again."
    elif [[ -n "$forbidden" && "$p1" == "$forbidden" ]]; then
      echo " The root password must be different from ${VM_USER}'s password."
    else
      PASSWORD_RESULT="$p1"; return 0
    fi
  done
}

# Questions about the guest setup (password, SSH, xrdp).
post_install_settings() {
  echo
  echo " ${BOLD}Guest setup${CL}"
  ask_password "Password for user '${VM_USER}'"
  VM_PASSWORD="$PASSWORD_RESULT"
  ask_ssh_and_root
  ask_xrdp_and_browsers
}

# SSH key, PermitRootLogin and root password questions.
ask_ssh_and_root() {
  # Optional public key: a file path on this host, or the key pasted in.
  local key default_key
  default_key="$(ls /root/.ssh/id_*.pub 2>/dev/null | head -n1 || true)"
  ask key "SSH public key file or pasted key (blank = skip)" "$default_key"
  if [[ -n "$key" && -f "$key" ]]; then
    SSH_PUBKEY="$(cat "$key")"
  elif [[ "$key" =~ ^(ssh-|ecdsa-|sk-) ]]; then
    SSH_PUBKEY="$key"
  elif [[ -n "$key" ]]; then
    msg_warn "That input is neither a file nor a public key; skipping key upload."
  fi

  if ask_yn "Set 'PermitRootLogin yes' in the SSH server config?" n; then
    echo
    echo " ${YW}WARNING:${CL} PermitRootLogin yes lets anyone who can reach port 22 try to log in"
    echo " as root. With a password this is a common target for brute-force attacks."
    echo " Only use it on a trusted, isolated network, and prefer key-based login."
    if ask_yn "Enable PermitRootLogin yes anyway?" n; then PERMIT_ROOT="yes"; fi
  fi
  if [[ "$PERMIT_ROOT" == "yes" ]]; then
    msg_warn "PermitRootLogin yes will be enabled. Use only on a trusted network."
  fi

  # Optional root password. Ubuntu leaves root without one (locked).
  if ask_yn "Set a root password? (must be different from ${VM_USER}'s)" n; then
    ask_password "Password for root" "$VM_PASSWORD"
    ROOT_PW="$PASSWORD_RESULT"
  elif [[ "$PERMIT_ROOT" == "yes" && -z "$SSH_PUBKEY" ]]; then
    msg_warn "PermitRootLogin yes without a root password or SSH key: root still cannot log in over SSH."
  fi
}

ask_xrdp_and_browsers() {
  XRDP_FLAGS=""
  if ask_yn "xrdp: enable sound redirection (-s)?" n; then XRDP_FLAGS+="-s "; fi
  if ask_yn "xrdp: customise the login screen (-l)?" n; then XRDP_FLAGS+="-l "; fi
  XRDP_FLAGS="${XRDP_FLAGS% }"

  if ask_yn "Replace the Firefox snap with Mozilla's Firefox, remove snap, and install Brave + Brave Origin?" n; then
    INSTALL_BROWSERS="yes"
  fi
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
  offer_upload
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
    SHOTS+=("$file")
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
  GUEST_PROGRESS_FILE=/var/log/cloud-init-output.log guest_run "Waiting for cloud-init to finish" <<'EOF'
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
# stdin so passwords never appear on a command line. While it runs, a live
# line shows the elapsed time and the latest line of the guest log, so it is
# clear the script has not hung.
#   guest_run "Description" <<'EOF' ... EOF
#   GUEST_PROGRESS_FILE=/path guest_run ...   (log file to show; default GUEST_LOG)
guest_run() {
  local desc="$1" json pid status code out start now elapsed last_peek=-10 latest="" cols
  local progress_file="${GUEST_PROGRESS_FILE:-$GUEST_LOG}"
  msg_info "$desc"
  json="$(qm guest exec "$VMID" --synchronous 0 --pass-stdin 1 -- \
    /usr/bin/env DEBIAN_FRONTEND=noninteractive TERM=dumb \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    bash -s)" || true
  pid="$(perl -MJSON -0777 -ne 'my $j = eval { decode_json($_) } || {}; print $j->{pid} // ""' <<<"$json")"
  if [[ -z "$pid" ]]; then
    msg_error "${desc}: could not start the command in the guest."
    return 1
  fi

  start=$(date +%s)
  cols=$(tput cols 2>/dev/null || echo 80)
  while true; do
    status="$(qm guest exec-status "$VMID" "$pid" 2>/dev/null || echo '{}')"
    if [[ "$(perl -MJSON -0777 -ne 'my $j = eval { decode_json($_) } || {}; print $j->{exited} ? 1 : 0' <<<"$status")" == 1 ]]; then
      break
    fi
    now=$(date +%s); elapsed=$((now - start))
    if ((elapsed > 7200)); then
      printf '\r\033[K' >/dev/tty
      msg_error "${desc}: still running after 2 hours; giving up."
      return 1
    fi
    if ((elapsed - last_peek >= 10)); then
      last_peek=$elapsed
      latest="$(guest_tail "$progress_file")"
    fi
    printf '\r\033[K   [%02d:%02d] %s' $((elapsed / 60)) $((elapsed % 60)) \
      "${latest:0:$((cols - 14))}" >/dev/tty
    sleep 2
  done
  printf '\r\033[K' >/dev/tty
  elapsed=$(( $(date +%s) - start ))

  code="$(perl -MJSON -0777 -ne 'my $j = decode_json($_); print exists $j->{exitcode} ? $j->{exitcode} : "unknown"' <<<"$status")"
  out="$(perl -MJSON -0777 -ne 'my $j = decode_json($_); print $j->{"out-data"} // ""; print $j->{"err-data"} // ""' <<<"$status")"
  if [[ "$VERBOSE" == "yes" && -n "$out" ]]; then echo "$out"; fi
  if [[ "$code" != "0" ]]; then
    msg_error "${desc} failed (exit ${code}). Last output:"
    echo "$out" | tail -n 20 >&2
    return 1
  fi
  msg_ok "${desc} ($((elapsed / 60))m $((elapsed % 60))s)"
}

# Latest non-empty line of a log file inside the guest (apt progress uses
# carriage returns, so those count as line breaks). Empty if unavailable.
guest_tail() {
  qm guest exec "$VMID" --timeout 10 -- sh -c \
    "tail -c 600 '$1' 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*\$' | tail -n 1" 2>/dev/null \
    | perl -MJSON -0777 -ne 'my $j = eval { decode_json($_) } || {}; my $o = $j->{"out-data"} // ""; $o =~ s/[^[:print:]]//g; print $o' \
    || true
}

post_install() {
  install_desktop
  install_nala_upgrade
  configure_ssh
  enable_agent
  install_xrdp || msg_warn "xrdp install failed; see ${GUEST_LOG} in the VM. Continuing."
  if [[ "$INSTALL_BROWSERS" == "yes" ]]; then
    install_browsers
  fi
}

install_browsers() {
  replace_firefox_snap || msg_warn "Firefox/snap replacement failed; see ${GUEST_LOG} in the VM. Continuing."
  install_brave || msg_warn "Brave install failed; see ${GUEST_LOG} in the VM. Continuing."
}

install_desktop() {
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
}

install_nala_upgrade() {
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
}

configure_ssh() {
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
  # Refuse a root password equal to the user's (also catches it on reruns,
  # where the script does not know the user's password).
  H="\$(getent shadow "\$VM_USER" | cut -d: -f2)"
  if [ -n "\$H" ] && [ "\$(ROOT_PW="\$ROOT_PW" perl -e 'print crypt(\$ENV{ROOT_PW}, \$ARGV[0])' "\$H")" = "\$H" ]; then
    echo "ERROR: the root password is the same as \$VM_USER's; root password NOT changed." >&2
    exit 3
  fi
  echo "root:\$ROOT_PW" | chpasswd
fi
systemctl enable --now ssh
systemctl restart ssh
EOF
}

enable_agent() {
  guest_run "Enabling qemu-guest-agent" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
apt-get install -y qemu-guest-agent
systemctl enable qemu-guest-agent || true   # static unit on Ubuntu; started by udev
EOF
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

# Remove the Firefox snap and snapd, and install Firefox from Mozilla's own
# APT repository instead (pinned so Ubuntu's snap-installing transitional
# package and snapd never come back).
replace_firefox_snap() {
  guest_run "Replacing the Firefox snap with Mozilla's Firefox .deb and removing snap" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
# Keep the desktop metapackage installed when firefox/snapd change below.
apt-mark manual lubuntu-desktop >/dev/null 2>&1 || true

if command -v snap >/dev/null 2>&1; then
  snap remove --purge firefox || true
fi

# Block Ubuntu's firefox transitional package (it installs the snap) and snapd.
cat >/etc/apt/preferences.d/firefox-no-snap <<'PIN'
Package: firefox*
Pin: release o=Ubuntu
Pin-Priority: -1
PIN
cat >/etc/apt/preferences.d/no-snapd <<'PIN'
Package: snapd
Pin: release a=*
Pin-Priority: -10
PIN

# Mozilla's repository, preferred over everything else for its packages.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
  >/etc/apt/sources.list.d/mozilla.list
cat >/etc/apt/preferences.d/mozilla <<'PIN'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
PIN

apt-get update
# Ubuntu's transitional package has a higher version (epoch), hence downgrades.
apt-get install -y --allow-downgrades firefox
apt-get purge -y snapd
rm -rf /snap /var/snap /var/lib/snapd /home/*/snap /root/snap
apt-cache policy firefox | head -n 3
EOF
}

# Brave and Brave Origin, with Brave's official install script.
install_brave() {
  guest_run "Installing Brave" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
curl -fsS https://dl.brave.com/install.sh | sh
EOF
  guest_run "Installing Brave Origin" <<EOF
set -e
exec > >(tee -a ${GUEST_LOG}) 2>&1
curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh
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
    --description "Fresh Lubuntu ${LUBUNTU_SERIES} install: nala, upgrades, OpenSSH, qemu-guest-agent, xrdp$([[ "$INSTALL_BROWSERS" == yes ]] && echo ", Firefox (Mozilla deb), Brave, Brave Origin, no snap"). Created $(date '+%F %T')." >/dev/null
  msg_ok "Snapshot '${SNAPSHOT_NAME}' created"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# 8. Optional upload of the log and screenshots to a PRIVATE GitHub repo
# -----------------------------------------------------------------------------
# Settings live in ${GH_CONF_DIR} (mode 700): 'repo' holds owner/name and
# 'token' a fine-grained token with Contents read/write on that repo only.
# The token is sent from a header file, never on a command line, and the
# repo must be private because logs contain IPs, MACs and hostnames.
gh_api() {   # gh_api METHOD PATH [json-body-file]
  local hdr="${TEMP_DIR}/gh-headers"
  ( umask 077; printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' \
      "$(cat "${GH_CONF_DIR}/token")" >"$hdr" )
  if [[ -n "${3:-}" ]]; then
    curl -fsS -X "$1" -H @"$hdr" --data @"$3" "https://api.github.com$2"
  else
    curl -fsS -X "$1" -H @"$hdr" "https://api.github.com$2"
  fi
}

gh_setup() {
  local repo token private
  echo
  echo " Uploads go to a PRIVATE repository you create on GitHub (e.g. lubuntu-vm-logs),"
  echo " with a fine-grained token that has 'Contents: read and write' on that repo only."
  ask repo "Repository (owner/name)" "solchjg/lubuntu-vm-logs"
  read -r -s -p " Token (input hidden): " token; echo
  [[ -n "$token" ]] || { echo " No token given; skipping upload."; return 1; }
  ( umask 077; mkdir -p "$GH_CONF_DIR"; printf '%s\n' "$repo" >"${GH_CONF_DIR}/repo"; printf '%s' "$token" >"${GH_CONF_DIR}/token" )
  private="$(gh_api GET "/repos/${repo}" 2>/dev/null | perl -MJSON -0777 -ne 'print decode_json($_)->{private} ? "yes" : "no"')" || private=""
  if [[ "$private" != "yes" ]]; then
    msg_error "Could not confirm that ${repo} exists and is private with this token. Nothing saved."
    rm -f "${GH_CONF_DIR}/token" "${GH_CONF_DIR}/repo"
    return 1
  fi
  msg_ok "Upload settings saved in ${GH_CONF_DIR} (root only)"
}

upload_file() {   # upload_file local-path repo-path
  local body="${TEMP_DIR}/gh-body.json"
  perl -MJSON -MMIME::Base64 -0777 -e '
    open my $f, "<:raw", $ARGV[0] or die; local $/; my $d = <$f>;
    print encode_json({ message => "Add $ARGV[1]", content => encode_base64($d, "") });' "$1" "$2" >"$body"
  gh_api PUT "/repos/$(cat "${GH_CONF_DIR}/repo")/contents/$2" "$body" >/dev/null
}

offer_upload() {
  local folder f ok=0 total=0
  [[ -n "${LOG_FILE:-}" && -s "$LOG_FILE" ]] || return 0
  echo
  if [[ ! -s "${GH_CONF_DIR}/token" ]]; then
    ask_yn "Upload this log and screenshots to a private GitHub repo? (sets it up now)" n || return 0
    gh_setup || return 0
  else
    ask_yn "Upload this log and screenshots to $(cat "${GH_CONF_DIR}/repo")?" y || return 0
  fi
  folder="runs/$(basename "$LOG_FILE" .log)"
  for f in "$LOG_FILE" "${SHOTS[@]}"; do
    [[ -s "$f" ]] || continue
    total=$((total + 1))
    if upload_file "$f" "${folder}/$(basename "$f")"; then ok=$((ok + 1)); fi
  done
  if ((ok == total)); then
    msg_ok "Uploaded ${ok} file(s) to $(cat "${GH_CONF_DIR}/repo")/${folder}"
  else
    msg_warn "Uploaded ${ok} of ${total} file(s) to $(cat "${GH_CONF_DIR}/repo")/${folder}"
  fi
}

# -----------------------------------------------------------------------------
# 9. Modify an existing VM (rerun the script on a VM it created)
# -----------------------------------------------------------------------------
# Load the settings of an existing VM into the script's variables.
load_vm() {
  local cfg
  cfg="$(qm config "$VMID")"
  HN="$(sed -n 's/^name: //p' <<<"$cfg")"
  RAM_SIZE="$(sed -n 's/^memory: //p' <<<"$cfg")"
  CORE_COUNT="$(sed -n 's/^cores: //p' <<<"$cfg")"
  DISPLAY_TYPE="$(sed -n 's/^vga: \([^,]*\).*/\1/p' <<<"$cfg")"; DISPLAY_TYPE="${DISPLAY_TYPE:-std}"
  NET0="$(sed -n 's/^net0: //p' <<<"$cfg")"
  MAC="$(grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' <<<"$NET0" | head -n1)"
  DISK_SIZE="$(sed -n 's/^scsi0: .*size=\([0-9]*\)G.*/\1/p' <<<"$cfg")"
  VM_CREATED="no"   # never offer to destroy an existing VM on abort
}

# Start the VM if needed and wait for the guest agent.
ensure_running() {
  if [[ "$(qm status "$VMID" | awk '{print $2}')" != "running" ]]; then
    qm start "$VMID"
    msg_ok "Started VM ${VMID}"
  fi
  msg_info "Waiting for the guest agent"
  wait_for_agent 600 || { msg_error "The guest agent did not answer."; return 1; }
}

pending_note() {
  if [[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]]; then
    echo "   The VM is running: this change applies after its next full stop/start."
  fi
}

rerun_steps() {
  local step
  ensure_running || return 0
  while true; do
    echo
    choose step "Run which setup step on VM ${VMID}?" 7 \
      upgrade "Update packages (nala upgrade)" \
      ssh "SSH options and root password (asks again)" \
      password "Change ${VM_USER}'s password" \
      xrdp "Reinstall xrdp" \
      browsers "Firefox from Mozilla, remove snap, Brave + Brave Origin" \
      desktop "Reinstall lubuntu-desktop" \
      back "Back"
    case "$step" in
      upgrade) install_nala_upgrade || true ;;
      ssh)
        SSH_PUBKEY=""; PERMIT_ROOT="no"; ROOT_PW=""; VM_PASSWORD=""
        ask_ssh_and_root
        configure_ssh || true ;;
      password)
        ask_password "New password for '${VM_USER}'"
        guest_run "Changing ${VM_USER}'s password" <<EOF || true
set -e
P=$(printf '%q' "$PASSWORD_RESULT")
echo "${VM_USER}:\$P" | chpasswd
EOF
        ;;
      xrdp)
        XRDP_FLAGS=""
        if ask_yn "xrdp: enable sound redirection (-s)?" n; then XRDP_FLAGS+="-s "; fi
        if ask_yn "xrdp: customise the login screen (-l)?" n; then XRDP_FLAGS+="-l "; fi
        XRDP_FLAGS="${XRDP_FLAGS% }"
        install_xrdp || msg_warn "xrdp install failed." ;;
      browsers) install_browsers ;;
      desktop) install_desktop || true ;;
      back) return 0 ;;
    esac
  done
}

modify_vm() {
  local choice v snaps snap name
  echo
  echo " Lubuntu VMs created by this script:"
  qm list | awk 'NR==1 || $1 ~ /^[0-9]+$/' | while read -r id rest; do
    if [[ "$id" == VMID ]] || grep -q '^tags:.*lubuntu' "/etc/pve/qemu-server/${id}.conf" 2>/dev/null; then
      echo "   $id $rest"
    fi
  done
  while true; do
    ask VMID "VM ID to modify" ""
    [[ -e "/etc/pve/qemu-server/${VMID}.conf" ]] && break
    echo " There is no VM ${VMID} on this node."
  done
  load_vm
  while true; do
    echo
    echo " ${BOLD}VM ${VMID} (${HN})${CL}: ${CORE_COUNT} cores, ${RAM_SIZE} MiB RAM, ${DISK_SIZE:-?} GiB disk, display ${DISPLAY_TYPE}, MAC ${MAC}, $(qm status "$VMID" | awk '{print $2}')"
    choose choice "What do you want to do?" 9 \
      ram "Change RAM" cores "Change CPU cores" mac "Change MAC address" \
      display "Change display" disk "Grow the disk" steps "Rerun setup steps" \
      rollback "Roll back to a snapshot" snapshot "Take a snapshot" finish "Done"
    case "$choice" in
      ram) select_ram; qm set "$VMID" --memory "$RAM_SIZE" >/dev/null; msg_ok "RAM set to ${RAM_SIZE} MiB"; pending_note ;;
      cores) ask_number CORE_COUNT "CPU cores" "$CORE_COUNT" 1; qm set "$VMID" --cores "$CORE_COUNT" >/dev/null; msg_ok "Cores set to ${CORE_COUNT}"; pending_note ;;
      mac)
        ask_mac "$VMID"
        qm set "$VMID" --net0 "$(sed -E "s/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/${MAC}/" <<<"$NET0")" >/dev/null
        NET0="$(qm config "$VMID" | sed -n 's/^net0: //p')"
        msg_ok "net0 is now: ${NET0}"; pending_note ;;
      display)
        choose DISPLAY_TYPE "Display:" 1 virtio "VirtIO-GPU" std "Standard VGA" qxl "SPICE (qxl)"
        qm set "$VMID" --vga "$DISPLAY_TYPE" >/dev/null; msg_ok "Display set to ${DISPLAY_TYPE}"; pending_note ;;
      disk)
        ask_number v "New disk size in GiB (larger than ${DISK_SIZE:-current})" "$(( ${DISK_SIZE:-30} + 10 ))" $(( ${DISK_SIZE:-0} + 1 ))
        if qm disk resize "$VMID" scsi0 "${v}G" >/dev/null; then
          DISK_SIZE="$v"; msg_ok "Disk grown to ${v} GiB (the root partition grows on next boot)"
        else
          msg_error "Resize failed."
        fi ;;
      steps) rerun_steps ;;
      rollback)
        snaps="$(qm listsnapshot "$VMID" | sed -n 's/^[^A-Za-z0-9]*\([A-Za-z0-9_-]*\) .*/\1/p' | grep -v '^current$' || true)"
        if [[ -z "$snaps" ]]; then echo " VM ${VMID} has no snapshots."; continue; fi
        echo " Snapshots: $(echo "$snaps" | tr '\n' ' ')"
        ask snap "Snapshot to roll back to" "$(echo "$snaps" | tail -n1)"
        if ! grep -qx -- "$snap" <<<"$snaps"; then echo " No snapshot called ${snap}."; continue; fi
        if ask_yn "Roll VM ${VMID} back to '${snap}'? Changes made since then are lost." n; then
          if qm rollback "$VMID" "$snap"; then msg_ok "Rolled back to '${snap}'"; load_vm; fi
        fi ;;
      snapshot)
        ask name "Snapshot name" "manual-$(date +%Y%m%d-%H%M)"
        if qm snapshot "$VMID" "$name" --description "Taken with lubuntu-vm.sh on $(date '+%F %T')" >/dev/null; then
          msg_ok "Snapshot '${name}' created"
        else
          msg_error "Snapshot failed (names may use letters, digits, - and _ only)."
        fi ;;
      finish) break ;;
    esac
  done
  offer_upload
  echo "   Log file: ${LOG_FILE}"
}

main() {
  ensure_tmux
  header_info
  preflight
  start_logging
  msg_ok "Logging to ${BL}${LOG_FILE}${CL}"

  local mode
  choose mode "What do you want to do?" 1 new "Create a new Lubuntu VM" modify "Modify an existing VM (rerun steps, hardware, snapshots)"
  if [[ "$mode" == modify ]]; then
    modify_vm
    return 0
  fi

  ensure_image
  ensure_snippet_storage

  echo
  echo " Default settings: q35, UEFI, VirtIO-GPU, 2 CPU cores, 30 GiB disk (cache none)"
  echo " on ${STORAGE}, bridge ${BRG}. You pick the RAM size."
  if ask_yn "Use the default settings? (n = advanced settings)" y; then
    default_settings
  else
    advanced_settings
  fi
  post_install_settings

  header_info
  echo -e " ${BOLD}VM ${VMID}${CL}: ${HN}, ${MACHINE_TYPE}/${BIOS}, ${CORE_COUNT} cores (${CPU_TYPE}), ${RAM_SIZE} MiB RAM,"
  echo -e "        ${DISK_SIZE} GiB on ${STORAGE} (cache ${DISK_CACHE}), ${BRG} ${MAC}${VLAN}${MTU}"
  echo -e " Image: ${CLOUD_IMAGE_NAME} + lubuntu-desktop"
  echo -e " SSH:   key $([[ -n "$SSH_PUBKEY" ]] && echo yes || echo no), PermitRootLogin ${PERMIT_ROOT}"
  echo -e " Root:  password $([[ -n "$ROOT_PW" ]] && echo set || echo "not set")"
  echo -e " xrdp:  flags '${XRDP_FLAGS:-none}'   Display: ${DISPLAY_TYPE}   Browsers/no snap: ${INSTALL_BROWSERS}"
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
  offer_upload
  echo "   Log file: ${LOG_FILE}"
}

main "$@"
