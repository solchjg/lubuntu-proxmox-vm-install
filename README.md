# lubuntu-vm.sh

Builds a Lubuntu 26.04 desktop VM on Proxmox VE 9 with no manual steps. The script starts from the official Ubuntu 26.04 cloud image and uses cloud-init to create the user. It then adds the Lubuntu desktop and the rest of the setup through the QEMU guest agent, so there's no installer to click through and nothing is typed into the VM console.

## Usage

Run as root on the Proxmox host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/solchjg/lubuntu-proxmox-vm-install/main/lubuntu-vm.sh)"
```

The script restarts itself inside a `tmux` session (it offers to install tmux if it's missing). It shows how to reattach and waits 30 seconds, or until you press Enter, so you can read it. If you close the Proxmox shell, the script keeps running, and you can reattach with:

```bash
tmux attach -t lubuntu-vm
```

## What happens

1. **Checks.** Confirms it runs as root on Proxmox VE 9 and that the needed tools exist.
2. **Cloud image.** Downloads `ubuntu-26.04-server-cloudimg-amd64.img` into `/var/lib/vz/template/cache/` and verifies its SHA256. A cached copy is reused if it still matches the newest release; otherwise it is replaced.
3. **Snippets storage.** cloud-init reads its config from a storage with the *snippets* content type. If no storage has it, the script offers to enable snippets on `local`.
4. **Settings.** Plain terminal prompts: the default is shown in brackets and Enter keeps it. Choose *default* or *advanced*.
   - Defaults: q35, UEFI, VirtIO-GPU display, 30 GiB disk on `local-lvm`, cache none, 2 cores, `vmbr0`, and RAM picked from 4/8/12/16 GB or custom (8 GB preselected).
   - Advanced: VM ID, machine type, firmware, disk size, cache, storage, hostname, CPU model, cores, RAM, bridge, MAC, VLAN, MTU, display (VirtIO-GPU, Standard VGA or SPICE), keyboard, verbose mode and start VM.
   - Then: the password for `sadmin`, an optional SSH public key (a file path or the pasted key), optional `PermitRootLogin yes` (with a security warning), an optional root password (asked twice, and it must be different from sadmin's), and xrdp options (sound redirection `-s`, custom login screen `-l`).
5. **Create and first boot.** Imports the cloud image as the VM disk, grows it to the chosen size and attaches a cloud-init drive. On first boot, cloud-init creates `sadmin` and installs `qemu-guest-agent` and `openssh-server`. The script prints a status line every 30 seconds until the guest agent answers, usually within 2 to 5 minutes. If nothing has happened after 15 minutes, it saves a screenshot and asks whether to keep waiting.
6. **Post-install** (through `qm guest exec`, as root in the guest). Each step shows a live line with the elapsed time and the latest line of the guest's log, so you can see it's still working, plus its total time when it finishes:
   - install `lubuntu-desktop` (the same package set the Lubuntu ISO installs, about 1 to 2 GB of downloads) and make the graphical login the default
   - install nala, then `nala upgrade -y`
   - OpenSSH: upload the key to sadmin (and to root if root login is on), add `PermitRootLogin yes` in `/etc/ssh/sshd_config.d/10-permit-root-login.conf` if you chose it, and set the root password if you gave one
   - download the newest `xrdp-installer-X.Y.zip` from c-nergy.be (1.6 is the fallback) and run it as sadmin. sadmin gets passwordless sudo only for this step, and it is removed afterwards. If this step fails, the script warns you and carries on.
   - remove the Firefox snap and snapd, and install Firefox from Mozilla's APT repository (`packages.mozilla.org`, pinned to priority 1000). APT pins block Ubuntu's snap-installing `firefox` package and snapd from coming back.
   - install Brave (`curl -fsS https://dl.brave.com/install.sh | sh`) and Brave Origin (the same script with `FLAVOR=origin`)
   - if the browser or snap steps fail, the script warns you and carries on
7. **Finalize.** Disables cloud-init, switches networking to NetworkManager (as on a normal Lubuntu install), removes the cloud-init drive and the config snippet, reboots once and checks that the graphical login (SDDM) is running and SSH answers.
8. **Snapshot.** Shuts the VM down and takes the snapshot `initial-install`.

## Aborting

Ctrl+C, or answering *n* when asked to keep waiting, asks `Delete VM <id> and all its disks? [y/N]`. Answering yes stops the VM and runs `qm destroy --purge --destroy-unreferenced-disks`. The cached cloud image and the log are kept.

## Security notes

- The cloud-init snippet contains only a SHA-512 hash of the sadmin password. It's mode 600 and is deleted once the VM is set up.
- The root password is set inside the guest through the guest agent's stdin, so it never appears on a command line or in a file on the host.
- **Logs.** Everything shown on screen is logged on the host to `/var/log/lubuntu-vm/lubuntu-vm-<date>.log`. The directory is mode 700 and the files are 600. Prompts are logged but your answers aren't, passwords are typed with echo off, and the script never prints a password, so no password reaches the log. Commands run inside the guest are logged to `/var/log/lubuntu-vm-setup.log` in the VM.
- `PermitRootLogin yes` exposes root to brute-force attempts. Only use it on a trusted network, and prefer key login.

## Notes

- The VM needs internet access (DHCP) on the chosen bridge.
- The c-nergy installer officially lists standard Ubuntu 22.04 to 25.x. It may complain about Lubuntu or 26.04, which is why the xrdp step does not stop the script when it fails.
- If you choose not to start the VM, cloud-init still runs when you start it later, but the desktop, nala, SSH and xrdp steps are skipped.
