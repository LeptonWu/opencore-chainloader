# opencore-chainloader

Minimal OpenCore configuration and a Debian USB creation script for booting native macOS Recovery and other UEFI bootloaders on Intel Macs.

## Purpose

This project is intended for a MacBook with a firmware password where selecting a USB directly with the Option-key Startup Manager requires that password. The proposed workaround is to select this USB from **Startup Disk in an already running macOS installation**, restart into OpenCore, and choose Recovery or another UEFI bootloader from its picker.

The USB includes a small NTFS partition with an empty `Windows/System32/ntdll.dll` marker. Its purpose is to encourage macOS Startup Disk to recognize the USB as a Windows startup disk, while the EFI partition actually launches OpenCore. The marker is a placeholder, not a Windows installation or executable DLL. Recognition depends on the Mac and macOS version; it has not been verified across models.

This workflow requires access to a working macOS installation and permission to change its startup disk. It does not remove or recover a firmware password, and it is not a guaranteed way to boot every firmware-locked Mac. Apple documents that a firmware password restricts booting from disks other than the designated startup disk; this project relies on being able to designate the USB through macOS. If that selection is blocked or still requires the firmware password, this workflow cannot proceed.

Apple references: [Firmware password](https://support.apple.com/en-us/102384), [what a firmware password protects](https://support.apple.com/en-gb/guide/mac-help/mchl126463db/27/mac/27), and [T2 Startup Security Utility](https://support.apple.com/en-us/102522).

## Create the USB on Debian

**The script erases every existing partition and file on the selected USB disk.** It requires at least **250 MB (250,000,000 bytes)** and 512-byte logical sectors. Store the script and config on another disk.

Put `config.plist` and `create_boot_disk.sh` together in a directory. These two files are sufficient for normal use; the script locates the config beside itself.

Install dependencies:

```sh
sudo apt-get update
sudo apt-get install curl ca-certificates unzip python3 util-linux mount parted dosfstools ntfs-3g udev
```

From the directory containing the files:

```sh
chmod +x create_boot_disk.sh
./create_boot_disk.sh --check
./create_boot_disk.sh
```

`--check` downloads OpenCore, verifies the archive checksum, and checks plist syntax without modifying disks. The supplied configuration is fixed; the script does not run OpenCore's configuration validator.

Normal mode requests sudo when needed, detects USB disks, and prompts for a choice if several are present. To select a disk explicitly:

```sh
./create_boot_disk.sh --device /dev/sda
```

Use the whole-disk path, not a partition such as `/dev/sda1`. Verify the displayed disk identity, then type its exact device path at the confirmation prompt. The script prints progress, downloads and verifies OpenCore before erasing, refuses system mounts and active swap/mapped devices, and unmounts both new partitions when finished.

## USB layout

The script creates a GPT partition table:

| Partition | Size | Format/type | Contents |
| --- | --- | --- | --- |
| `OPENCORE` | 200 MiB | FAT32 EFI System Partition | OpenCore and `config.plist` |
| `DUMMY_WINDOWS` | 32 MiB | NTFS, Microsoft Basic Data | Empty `Windows/System32/ntdll.dll` |

The remaining space is unallocated. The installed files are:

```text
EFI partition:
  EFI/BOOT/BOOTx64.efi
  EFI/OC/OpenCore.efi
  EFI/OC/config.plist

NTFS partition:
  Windows/System32/ntdll.dll
```

## Boot workflow

1. Boot the existing macOS installation normally and connect the prepared USB. Connect any other USB you want to boot before restarting.
2. Open **Startup Disk** in System Preferences or System Settings and authenticate if requested.
3. If the USB appears as a Windows startup disk, select it and restart. If it does not appear, the marker-based recognition step has not worked on this system.
4. In OpenCore's text picker, select the native Recovery entry or another detected UEFI loader.

Selecting the USB changes the default startup disk. To return to ordinary internal-disk booting, select the internal macOS volume again in Startup Disk before removing the USB.
