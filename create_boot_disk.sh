#!/bin/bash
# Debian packages: curl ca-certificates unzip python3 util-linux mount parted
#                  dosfstools ntfs-3g udev
set -euo pipefail

chainloader_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
original_args=("$@")
requested_device=""
check_only=0
work_dir=""
efi_mount=""
ntfs_mount=""
completed=0

# Keep the binaries compatible with the supplied config.plist schema.
opencore_version="1.0.5"
opencore_sha256="2608743afe81001114a85b6fba6555edbc43813b82538e1f70220aeb0662d8be"
minimum_disk_bytes=250000000

usage() {
    cat <<'EOF'
Usage: ./create_boot_disk.sh [--device /dev/sdX]
       ./create_boot_disk.sh --check

Detect a USB disk, ask for confirmation, then erase its existing partitions.
Create GPT with a 200 MiB FAT32 EFI partition and a 32 MiB NTFS partition.
Install OpenCore 1.0.5 and the required config.plist beside this script.
Create the empty file Windows/System32/ntdll.dll on the NTFS partition.
Unmount both partitions when finished.

--device  Select a whole USB disk explicitly. A confirmation is still required.
--check   Download and verify OpenCore/config only; never access or erase disks.
-h, --help  Show this help.

The normal mode needs root; it invokes sudo if necessary.
Minimum disk size: 250 MB (250,000,000 bytes).
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$?
    local mount_dir
    local still_mounted=0
    trap - EXIT INT TERM

    if [[ -n "$work_dir" ]]; then
        for mount_dir in "$ntfs_mount" "$efi_mount"; do
            if [[ -n "$mount_dir" ]] && mountpoint -q -- "$mount_dir"; then
                if ! umount -- "$mount_dir"; then
                    printf 'Error: could not unmount %s.\n' "$mount_dir" >&2
                    still_mounted=1
                    status=1
                fi
            fi
        done
        # Never remove a staging directory while it contains a mounted disk.
        if (( still_mounted )); then
            printf 'Temporary directory retained at %s.\n' "$work_dir" >&2
        elif ! rm -rf -- "$work_dir"; then
            status=1
        fi
    fi

    if (( status == 0 && completed )); then
        printf 'Done. Both USB partitions are unmounted.\n'
    fi
    exit "$status"
}

while (( $# )); do
    case "$1" in
        --device)
            (( $# >= 2 )) || die '--device requires a whole-disk path.'
            [[ -z "$requested_device" ]] || die 'Specify --device only once.'
            requested_device=$2
            [[ -n "$requested_device" ]] || die '--device requires a whole-disk path.'
            shift 2
            ;;
        --check) check_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (use --help)." ;;
    esac
done
(( !check_only )) || [[ -z "$requested_device" ]] || die '--check cannot be combined with --device.'

[[ $(uname -s) == Linux ]] || die 'Run this script on Linux (Debian).'
PATH="$PATH:/usr/sbin:/sbin"
export PATH

required_commands=(curl unzip python3 sha256sum mktemp cp rm mountpoint)
if (( !check_only )); then
    required_commands+=(lsblk blockdev readlink findmnt wipefs parted partprobe
                        udevadm mkfs.fat mkfs.ntfs ntfs-3g mount umount sync sleep)
fi
missing_commands=()
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done
if (( ${#missing_commands[@]} )); then
    printf 'Missing commands: %s\n' "${missing_commands[*]}" >&2
    printf 'Install the Debian dependencies with:\n' >&2
    printf '  sudo apt-get install curl ca-certificates unzip python3 util-linux mount parted dosfstools ntfs-3g udev\n' >&2
    exit 1
fi

[[ -f "$chainloader_dir/config.plist" ]] || die 'Missing config.plist; place it beside create_boot_disk.sh.'

if (( !check_only && EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die 'Run this script as root (sudo is unavailable).'
    exec sudo -- "$chainloader_dir/create_boot_disk.sh" "${original_args[@]}"
fi

verify_disk() {
    [[ -b "$device" ]] || die "$device is not a block device."
    [[ $(lsblk --nodeps --noheadings --output TYPE "$device") == disk ]] || die 'Select a whole disk, not a partition.'
    [[ $(lsblk --nodeps --noheadings --output TRAN "$device") == usb ]] || die "$device is not a USB disk."
    [[ $(lsblk --nodeps --noheadings --output RO "$device") == 0 ]] || die "$device is read-only."
    disk_bytes=$(blockdev --getsize64 "$device")
    [[ "$disk_bytes" =~ ^[0-9]+$ ]] || die 'Unable to read disk size.'
    (( disk_bytes >= minimum_disk_bytes )) || die "USB disk $device is too small ($disk_bytes bytes); at least 250 MB is required."
    # A 200 MiB FAT32 ESP does not have enough clusters with 4 KiB sectors.
    [[ $(blockdev --getss "$device") == 512 ]] || die 'This 200 MiB FAT32 layout requires a USB disk with 512-byte logical sectors.'

    lsblk --json --paths --output PATH,TYPE,MOUNTPOINTS "$device" |
        python3 -c '
import json
import os
import sys

script_dir = os.path.realpath(sys.argv[1])
working_dir = os.path.realpath(sys.argv[2])
protected_dirs = {"/", "/boot", "/boot/efi", "/usr", "/etc", "/var", "/home", "/root", "/opt"}

def reject(message):
    print("Error: " + message, file=sys.stderr)
    sys.exit(1)

def inspect(node):
    if node["type"] not in ("disk", "part"):
        reject("USB disk contains an active mapped device: " + node["path"])
    for mount in node.get("mountpoints") or []:
        if not mount:
            continue
        if mount == "[SWAP]":
            reject("USB disk contains active swap.")
        if mount in protected_dirs or mount.startswith(("/boot/", "/usr/", "/etc/", "/var/", "/root/")):
            reject("USB disk contains a system mount: " + mount)
        for path in (script_dir, working_dir):
            if path == mount or path.startswith(mount.rstrip("/") + "/"):
                reject("USB disk contains this script or its working directory: " + mount)
    for child in node.get("children", []):
        inspect(child)

for node in json.load(sys.stdin)["blockdevices"]:
    inspect(node)
' "$chainloader_dir" "${work_dir:-$chainloader_dir}"
}

if (( !check_only )); then
    usb_disk_list=$(lsblk --json --bytes --nodeps --output PATH,TYPE,TRAN |
        python3 -c 'import json,sys; print("\n".join(d["path"] for d in json.load(sys.stdin)["blockdevices"] if d["type"] == "disk" and d.get("tran") == "usb"))')
    [[ -n "$usb_disk_list" ]] || die 'No USB disk found. Plug in a USB disk and try again.'
    mapfile -t usb_disks <<< "$usb_disk_list"

    if [[ -n "$requested_device" ]]; then
        device=$(readlink -f -- "$requested_device") || die 'Unable to resolve the device path.'
        found=0
        for usb_device in "${usb_disks[@]}"; do
            [[ "$device" != "$usb_device" ]] || found=1
        done
        (( found )) || die "$requested_device is not a whole USB disk."
    elif (( ${#usb_disks[@]} == 1 )); then
        device=${usb_disks[0]}
    else
        printf 'USB disks:\n'
        for index in "${!usb_disks[@]}"; do
            printf '%d) ' "$((index + 1))"
            lsblk --nodeps --noheadings --output PATH,SIZE,MODEL "${usb_disks[index]}"
        done
        read -r -p 'Select the disk number: ' selection || die 'Cancelled.'
        [[ "$selection" =~ ^[1-9][0-9]*$ && ${#selection} -le 6 ]] || die 'Invalid disk number.'
        (( selection <= ${#usb_disks[@]} )) || die 'Invalid disk number.'
        device=${usb_disks[selection - 1]}
    fi
    verify_disk
    disk_identity=$(lsblk --bytes --nodeps --noheadings --output MAJ:MIN,SIZE,SERIAL "$device")
    printf 'Selected USB disk:\n'
    lsblk --nodeps --output PATH,SIZE,MODEL "$device"
fi

umask 077
work_dir=$(mktemp -d -t opencore-boot-disk.XXXXXXXX)
efi_mount="$work_dir/efi"
ntfs_mount="$work_dir/ntfs"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

archive="$work_dir/OpenCore.zip"
staging_dir="$work_dir/staging"
mkdir -p "$staging_dir/EFI/BOOT" "$staging_dir/EFI/OC" "$efi_mount" "$ntfs_mount"
printf 'Downloading OpenCore %s...\n' "$opencore_version"
curl --fail --location --show-error --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 180 --retry 3 \
    --output "$archive" \
    "https://github.com/acidanthera/OpenCorePkg/releases/download/$opencore_version/OpenCore-$opencore_version-RELEASE.zip"
printf '%s  %s\n' "$opencore_sha256" "$archive" | sha256sum --check --status || die 'OpenCore archive checksum does not match the pinned release.'
unzip -tq "$archive"
unzip -p "$archive" X64/EFI/BOOT/BOOTx64.efi > "$staging_dir/EFI/BOOT/BOOTx64.efi"
unzip -p "$archive" X64/EFI/OC/OpenCore.efi > "$staging_dir/EFI/OC/OpenCore.efi"

cp -- "$chainloader_dir/config.plist" "$staging_dir/EFI/OC/config.plist"
python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1], "rb"))' "$staging_dir/EFI/OC/config.plist"

if (( check_only )); then
    printf 'OpenCore download and config checks passed. No disk was modified.\n'
    exit 0
fi

printf '\nAll partitions and data on %s will be erased.\n' "$device"
read -r -p "Type $device to continue: " confirmation || die 'Cancelled.'
[[ "$confirmation" == "$device" ]] || die 'Cancelled; disk was not erased.'
verify_disk
[[ $(lsblk --bytes --nodeps --noheadings --output MAJ:MIN,SIZE,SERIAL "$device") == "$disk_identity" ]] || die 'The selected USB disk changed. Run the script again.'

disk_nodes_output=$(lsblk --list --noheadings --paths --output PATH "$device")
mapfile -t disk_nodes <<< "$disk_nodes_output"
printf 'Unmounting existing USB filesystems...\n'
for ((index=${#disk_nodes[@]} - 1; index >= 0; index--)); do
    if findmnt --noheadings --source "${disk_nodes[index]}" >/dev/null; then
        umount --all-targets -- "${disk_nodes[index]}"
    fi
done

printf 'Erasing signatures and creating GPT partitions...\n'
for ((index=${#disk_nodes[@]} - 1; index >= 0; index--)); do
    wipefs --all -- "${disk_nodes[index]}"
done
parted --script --align optimal "$device" \
    mklabel gpt \
    mkpart OPENCORE fat32 1MiB 201MiB \
    set 1 esp on \
    mkpart DUMMY_WINDOWS ntfs 201MiB 233MiB \
    set 2 msftdata on
partprobe "$device"
udevadm settle --timeout=10

partition_prefix="$device"
[[ ! "$device" =~ [0-9]$ ]] || partition_prefix="${device}p"
efi_partition="${partition_prefix}1"
ntfs_partition="${partition_prefix}2"
for ((attempt=0; attempt<20; attempt++)); do
    [[ -b "$efi_partition" && -b "$ntfs_partition" ]] && break
    sleep 0.25
done
[[ -b "$efi_partition" && -b "$ntfs_partition" ]] || die 'New USB partition devices did not appear.'
[[ $(blockdev --getsize64 "$efi_partition") == $((200 * 1024 * 1024)) ]] || die 'EFI partition has an unexpected size.'
[[ $(blockdev --getsize64 "$ntfs_partition") == $((32 * 1024 * 1024)) ]] || die 'NTFS partition has an unexpected size.'

# Desktop automounters may have opened a new partition after the kernel rescan.
for partition in "$efi_partition" "$ntfs_partition"; do
    if findmnt --noheadings --source "$partition" >/dev/null; then
        umount --all-targets -- "$partition"
    fi
    wipefs --all -- "$partition"
done
printf 'Formatting the EFI and NTFS partitions...\n'
mkfs.fat -F 32 -n OPENCORE "$efi_partition"
mkfs.ntfs -F -Q -L DUMMY_WINDOWS "$ntfs_partition"

mount -t vfat -o rw,nodev,nosuid,noexec "$efi_partition" "$efi_mount"
printf 'Installing EFI/BOOT/BOOTx64.efi, EFI/OC/OpenCore.efi and EFI/OC/config.plist...\n'
cp -R -- "$staging_dir/EFI" "$efi_mount/"
mount -t ntfs-3g -o rw,nodev,nosuid,noexec "$ntfs_partition" "$ntfs_mount"
printf 'Creating Windows/System32/ntdll.dll on the NTFS partition...\n'
mkdir -p "$ntfs_mount/Windows/System32"
: > "$ntfs_mount/Windows/System32/ntdll.dll"
sync

printf 'Unmounting both USB partitions...\n'
umount --all-targets -- "$ntfs_partition"
umount --all-targets -- "$efi_partition"
completed=1
