# lubuntu-vm.sh

Builds a Lubuntu 26.04 desktop VM on Proxmox VE 9. You click through the Lubuntu installer yourself, and the script handles everything before and after that.

## Usage

Copy the script to the Proxmox host and run it as root:

```bash
bash lubuntu-vm.sh
```

## What happens

1. **Checks.** Confirms it runs as root on Proxmox VE 9 and that the needed tools exist.
2. **ISO.** Looks up the newest Lubuntu 26.04.x release on cdimage.ubuntu.com. If that ISO is not already in `local` ISO storage, it downloads it and verifies the SHA256 checksum. Older `lubuntu-26.04*` ISOs are deleted unless a VM still has them attached.
3. **Settings.** Choose *default* or *advanced*.
   - Defaults: q35, UEFI, 30 GiB disk on `local-lvm`, cache none, 2 cores, `vmbr0`, and RAM picked from 4/8/12/16 GB or custom (8 GB preselected).
   - Advanced: VM ID, machine type, firmware, disk size, cache, storage, hostname, CPU model, cores, RAM, bridge, MAC, VLAN, MTU, keyboard, verbose mode and start VM.
   - Then: the password for `sadmin`, an optional SSH public key (a file path or the pasted key), optional `PermitRootLogin yes` (with a security warning), an optional root password (asked twice, and it must be different from sadmin's), and xrdp options (sound redirection `-s`, custom login screen `-l`).
4. **Manual install.** The VM boots the ISO. In the Proxmox console, install Lubuntu with username **sadmin** and the same password. When the installer finishes, **don't click Restart**. Go back to the script and press Enter.
5. **Console bootstrap.** The script ejects the ISO and reboots the VM. Using `qm sendkey`, it then logs in at the console, opens a terminal (Ctrl+Alt+T) and installs `qemu-guest-agent` and `openssh-server`. If that fails twice, it shows you the command to run by hand.
6. **Post-install** (through `qm guest exec`, as root in the guest):
   - install nala, then `nala upgrade -y`
   - OpenSSH: upload the key to sadmin (and to root if root login is on), add `PermitRootLogin yes` in `/etc/ssh/sshd_config.d/10-permit-root-login.conf` if you chose it, and set the root password if you gave one
   - enable qemu-guest-agent
   - download the newest `xrdp-installer-X.Y.zip` from c-nergy.be (1.6 is the fallback) and run it as sadmin. sadmin gets passwordless sudo only for this step, and it is removed afterwards. If this step fails, the script warns you and carries on.
   - check that SSH answers on the VM's IP
7. **Snapshot.** Shuts the VM down and takes the snapshot `initial-install`.

## Notes and limitations

- `qm sendkey` types using a US keyboard layout. Keep the guest keyboard set to English (US) in the installer, or the password will be mistyped.
- If you tick *Log in automatically* in the installer, the script asks about it and skips typing the password.
- Everything that runs inside the guest is logged to `/var/log/lubuntu-vm-setup.log`.
- The c-nergy installer officially lists standard Ubuntu 22.04 to 25.x. It may complain about Lubuntu or 26.04, which is why the xrdp step does not stop the script when it fails.
- `PermitRootLogin yes` exposes root to brute-force attempts. Only use it on a trusted network, and prefer key login.
