#!/bin/bash
set -euo pipefail

# Global variables
HDD_ENCRYPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HDD_ENCRYPT_DIR/.env"

crypt_uuids=()
crypt_names=()

# Logging function
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    case $level in
        INFO)
            printf "\e[32m[%s] [INFO] %s\e[0m\n" "$timestamp" "$message"
            ;;
        WARN)
            printf "\e[33m[%s] [WARN] %s\e[0m\n" "$timestamp" "$message"
            ;;
        ERROR)
            printf "\e[31m[%s] [ERROR] %s\e[0m\n" "$timestamp" "$message"
            ;;
        *)
            printf "\e[34m[%s] [%s] %s\e[0m\n" "$timestamp" "$level" "$message"
            ;;
    esac
}

# Help message
show_help() {
    echo "Usage: $0 [command] [options]"
    echo
    echo "If no command it just checks crypttab"
    echo
    echo "Commands:"
    echo "  encrypt <input_file> <output_file>    Encrypt a file"
    echo "  decrypt <input_file> <output_file>    Decrypt a file"
    echo "  hdd-lock                              Lock all encrypted drives"
    echo "  hdd-unlock                            Unlock all encrypted drives"
    echo "  mount-drives                          Mount individual encrypted drives"
    echo "  umount-drives                         Unmount individual encrypted drives"
    echo "  mount-fs                              Mount the combined filesystem"
    echo "  umount-fs                             Unmount the combined filesystem"
    echo "  setup-storage-system                  Setup and initialize the complete storage system"
    echo "  close-storage-system                  Safely close and lock the storage system"
    echo "  init-drive <block-dev>                Initialises the drive"
    echo "  check-storage-system                  Check if storage system is mounted and operational"
    echo
    echo "Options:"
    echo "  -h, --help                            Show this help message"
    echo
    echo "Examples:"
    echo "  $0 encrypt secret.txt secret.txt.enc"
    echo "  $0 hdd-unlock"
    echo "  $0 mount-fs"
    exit 1
}

remove_cryptkey() {
    if [ -f "$KEY_FILE" ]; then
        log INFO "Removing unlocked $KEY_FILE."
        shred -u "$KEY_FILE"
    fi
}
trap 'remove_cryptkey' EXIT

backup_crypttab() {
    log INFO "Removing old crypttab backup at $CRYPTTAB.bak"
    rm -f $CRYPTTAB.bak
    log INFO "Backing up crypttab to $CRYPTTAB.bak"
    cp $CRYPTTAB $CRYPTTAB.bak
}

remove_uuid_from_crypttab() {
    local uuid="$1"
    line_number_of_old_uuid=$(grep -n "$uuid" "$CRYPTTAB" | cut -d: -f1 | head -1 || true)

    if [ ! -z "$line_number_of_old_uuid" ]; then
        comment_line_number=$((line_number_of_old_uuid - 1))
        log INFO "This will be removed:"
        echo "----------------------------------------------------------------"
        if [ $comment_line_number -ge 1 ]; then
            comment_line=$(cat $CRYPTTAB | head -$comment_line_number | tail -1)
            if  [[ "$comment_line" =~ ^#.* ]]; then
                remove_comment="YES"
                echo "$comment_line"
            fi
        fi
        uuid_line=$(sed -n "${line_number_of_old_uuid}p" "$CRYPTTAB")
        echo "$uuid_line"
        echo "----------------------------------------------------------------"
        read -p "Do you want to remove UUID and comment? ([yes]/no): " remove_confirmation  < /dev/tty
        if [ "$remove_confirmation" == "no" ]; then
            log WARN "UUID $uuid has to be removed from crypttab otherwise errors will be thrown when mounting."
        else
            if [ "$remove_comment" == "YES" ]; then
                sed -i "${comment_line_number},${line_number_of_old_uuid}d" "$CRYPTTAB"
            else
                sed -i "${line_number_of_old_uuid}d" "$CRYPTTAB"
            fi
        fi
    fi
}



check_and_init_crypttab_devices() {
    if [ ! -f "$CRYPTTAB" ]; then
        log WARN "Crypttab does not exist. Creating empty crypttab"
        touch $CRYPTTAB
    else
        backup_crypttab
    fi

    while IFS=$' ' read -r target_name uuid; do
        if [[ -z "$uuid" || $target_name == \#* ]]; then
            continue
        fi
        uuid="${uuid#UUID=}"

        if blkid -U $uuid  >/dev/null 2>&1; then
            crypt_names+=($target_name)
            crypt_uuids+=($uuid)
        else
            remove_uuid_from_crypttab $uuid    
        fi
    done <"$CRYPTTAB"

}

# Encrypt function
encrypt() {
    if [ $# -ne 2 ]; then
        log ERROR "Usage: $0 encrypt <input_file> <output_file>"
        exit 1
    fi

    input_file="$1"
    output_file="$2"

    if [ ! -f "$input_file" ]; then
        log ERROR "Input file '$input_file' does not exist or is not readable."
        exit 1
    fi

    if [ -e "$output_file" ]; then
        log ERROR "Output file '$output_file' already exists. Please choose a different name."
        exit 1
    fi

    if ! openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter 1000000 -salt -in "$input_file" -out "$output_file"; then
        log ERROR "Encryption failed."
        exit 1
    fi

    log INFO "File encrypted and saved as $output_file"
}

# Decrypt function
decrypt() {
    if [ $# -ne 2 ]; then
        log ERROR "Usage: $0 decrypt <encrypted_file> <decrypted_file>"
        exit 1
    fi

    encrypted_file="$1"
    decrypted_file="$2"

    if ! openssl enc -aes-256-cbc -d -salt -md sha512 -pbkdf2 -iter 1000000 -in "$encrypted_file" -out "$decrypted_file"; then
        log ERROR "Decryption failed."
        exit 1
    fi

    log INFO "File decrypted and saved as $decrypted_file"
}

# HDD Lock function
hdd_lock() {
    if [ ! -f "$CRYPTTAB" ]; then
        log ERROR "Crypttab not found: $CRYPTTAB"
        exit 1
    fi

    for index in "${!crypt_names[@]}"; do
        local uuid="${crypt_uuids[$index]}"
        local target_name="${crypt_names[$index]}"

        log INFO "Locking: $target_name UUID=$uuid"

        if cryptsetup status "$target_name" >/dev/null 2>&1; then
            log INFO "Closing $target_name"
            cryptsetup close "$target_name"
        else
            log WARN "Target $target_name already closed"
        fi
    done
}

# HDD Unlock function
hdd_unlock() {
    if [ ! -f "$CRYPTTAB" ]; then
        log ERROR "Crypttab not found: $CRYPTTAB"
        exit 1
    fi

    log INFO "Unlocking media vault"
    decrypt "$ENCRYPTED_KEY" "$KEY_FILE"

    for index in "${!crypt_names[@]}"; do
        local uuid="${crypt_uuids[$index]}"
        local target_name="${crypt_names[$index]}"

        log INFO "Unlocking: $target_name UUID=$uuid"

        if blkid -U $uuid >/dev/null 2>&1; then
            if ! cryptsetup status "$target_name" >/dev/null 2>&1; then
                log INFO "Opening $target_name..."
                cryptsetup open --key-file="$KEY_FILE" --type luks "/dev/disk/by-uuid/$uuid" "$target_name"
            else
                log WARN "$target_name is already opened, skipping."
            fi
        else
            log WARN "Device with uuid $uuid and name $target_name that is in crypttab DOES NOT EXIST!"
        fi
    done 

    remove_cryptkey
}

mount_drives() {
    hdd_unlock

    for index in "${!crypt_names[@]}"; do
        local uuid="${crypt_uuids[$index]}"
        local target_name="${crypt_names[$index]}"

        if [[ -z "$uuid" || $target_name == \#* ]]; then
            continue
        fi
        mount_point_indv="$INDIVIDUAL_DRIVE_MOUNT_DIR/$target_name"

        if [ ! -d "$mount_point_indv" ]; then
            log INFO "Creating $mount_point_indv folder..."
            mkdir -p "$mount_point_indv"
        fi

        blockdev="/dev/mapper/$target_name"

        if mountpoint -q "$mount_point_indv"; then
            log INFO "Unmounting $mount_point_indv"
            umount "$mount_point_indv"
        fi

        log INFO "Mounting $blockdev on $mount_point_indv"
        mount "$blockdev" "$mount_point_indv"
    done 
}

umount_drives() {
    for index in "${!crypt_names[@]}"; do
        local uuid="${crypt_uuids[$index]}"
        local target_name="${crypt_names[$index]}"

        if [[ -z "$uuid" || $target_name == \#* ]]; then
            continue
        fi
        mount_point_indv="$INDIVIDUAL_DRIVE_MOUNT_DIR/$target_name"

        if mountpoint -q "$mount_point_indv"; then
            log INFO "Unmounting $mount_point_indv"
            umount "$mount_point_indv"
        fi
    done
}

# Mount Filesystem function
mount_fs() {
    if mountpoint -q "$MOUNT_POINT"; then
        log WARN "Media vault is already mounted"
        exit 0
    fi

    mount_drives

    if [ ! -d "$MOUNT_POINT" ]; then
        log INFO "Creating $MOUNT_POINT folder..."
        mkdir -p "$MOUNT_POINT"
    fi

    log INFO "Mounting with mergerfs on $MOUNT_POINT"
    mergerfs -o "$MERGERFS_OPTIONS" "$INDIVIDUAL_DRIVE_MOUNT_DIR/$TARGET_BASE_NAME*" "$MOUNT_POINT"
}

# Unmount Filesystem function
umount_fs() {
    log INFO "Killing mergerfs"
    killall mergerfs >/dev/null 2>&1 || true

    log INFO "Unmounting & locking disks"

    umount_drives

    hdd_lock
}

# Run all steps (unlock, mount)
setup_storage_system() {
    set +e
    check_storage_system
    if [ $? -eq  0 ]; then
        log WARN "Storage system is already up and running. If you want to remount, first do close_storage_system."
        exit 1
    fi
    set -e

    mount_fs
}

# Run all steps to lock (unmount, lock)
close_storage_system() {
    umount_fs
}

check_storage_system() {
    log INFO "Checking storage system status..."

    # Check if crypttab file exists
    if [ ! -f "$CRYPTTAB" ]; then
        log WARN "Crypttab not found: $CRYPTTAB"
        return 1
    fi

    all_drives_ok=true

    for index in "${!crypt_names[@]}"; do
        local uuid="${crypt_uuids[$index]}"
        local target_name="${crypt_names[$index]}"

        blockdev="/dev/mapper/$target_name"
        mount_point_indv="$INDIVIDUAL_DRIVE_MOUNT_DIR/$target_name"

        # Check if the cryptsetup device is open
        if ! cryptsetup status "$target_name" >/dev/null 2>&1; then
            log WARN "Target $target_name is not open."
            all_drives_ok=false
            continue
        fi

        # Check if the device is mounted
        if ! mountpoint -q "$mount_point_indv"; then
            log WARN "Mount point $mount_point_indv is not mounted."
            all_drives_ok=false
            continue
        fi

        log INFO "Target $target_name (UUID=$uuid) is open and mounted at $mount_point_indv"
    done 

    # Check if the combined filesystem is mounted
    if ! mountpoint -q "$MOUNT_POINT"; then
        log WARN "Combined filesystem is not mounted at $MOUNT_POINT"
        all_drives_ok=false
    else
        log INFO "Combined filesystem is mounted at $MOUNT_POINT"
    fi

    if $all_drives_ok; then
        log INFO "Storage system is up and running correctly."
    else
        log WARN "Storage system has issues. Please check the logs above."
        return 1
    fi

    return 0
}

init_drive() {
    if [ $# -ne 1 ]; then
        log ERROR "Usage: $0 init-drive <block-dev>"
        exit 1
    fi


    set +e
    check_storage_system
    if [ $? -eq  0 ]; then
        log WARN "Storage system is up and running. It would be better to stop it before running init-drive."
        log WARN "You can stop the storage system using the 'close-storage-system' command."
        read -p "Do you want to continue with init-drive? (yes/[no]): " confirmation

        if [ "\$confirmation" != "yes" ]; then
            log INFO "Operation canceled by user."
            exit 1
        fi
    fi
    set -e

    block_dev="$1"

    if [ ! -b "$block_dev" ]; then
        log ERROR "Device '$block_dev' does not exist or is not a block device."
        exit 1
    fi

    log INFO "Device $block_dev is:"
    smartctl -a $block_dev | grep "Device Model\|Model Family\|User Capacity"
    log WARN "WARNING: This will erase all data on $block_dev!"
    read -p "Type yes in all caps to proceed: " confirmation

    if [ "$confirmation" != "YES" ]; then
        log ERROR "Operation canceled by user."
        exit 1
    fi

    log INFO "Initializing drive $block_dev..."
    log INFO "Checking for header file..."

    if [ ! -d "$HEADERS_BACKUP_DIR" ]; then
        log WARN "Directory at $HEADERS_BACKUP_DIR does not exist. Creating it."
        mkdir -p $HEADERS_BACKUP_DIR
    fi
    name_and_serial=$(smartctl $block_dev -a | awk '/Device Model/{sub(/.*Device Model:[ \t]*/, ""); gsub(/ /, "-"); model=$0} /Serial Number/{printf "%s.%s\n", model, $3}')
    header_file="$HEADERS_BACKUP_DIR/$name_and_serial.header.bak"

    if [ -f "$header_file" ]; then
        log ERROR "Header backup file '$header_file' already exists. Remove it and then run init-drive again."
        exit 1
    fi
    log INFO "Header file does not exist."

    old_uuid=$(blkid -s UUID -o value $block_dev)
    log INFO "Checking if current $block_dev is in crypttab (UUID=$old_uuid)"
    remove_uuid_from_crypttab "$old_uuid"

    decrypt "$ENCRYPTED_KEY" "$KEY_FILE"

    log INFO "Formating the device $block_dev"
    cryptsetup -v -c aes-xts-plain64 -h sha512 -s 512 luksFormat --pbkdf pbkdf2 --key-file $KEY_FILE "$block_dev"
    log INFO "Device $block_dev successfully formated"

    log INFO "Generating header backup file"
    cryptsetup luksHeaderBackup --header-backup-file $header_file $block_dev
    log INFO "Header succesfully generated."

    uuid=$(blkid -s UUID -o value $block_dev)
    log INFO "Device uuid is $uuid"

    new_device_number=$(grep -oP "$TARGET_BASE_NAME\K\d+" $CRYPTTAB | sort -n | tail -n 1 || echo "0")
    new_device_number=$((new_device_number + 1))
    new_device_name=$TARGET_BASE_NAME$new_device_number

    log INFO "Your new device will be called '$new_device_name'"
    read -p "Type a short comment about this new device: " comment



    echo "# $comment" | tee -a $CRYPTTAB
    echo "$new_device_name UUID=$uuid" | tee -a $CRYPTTAB

    log INFO "Crypttab ($CRYPTTAB) updated with new device"

    if cryptsetup status "$new_device_name" >/dev/null 2>&1; then
        log WARN "Device $new_device_name is already open."

        read -p "Do you want to close the device $new_device_name? ([yes]/no): " close_confirmation

            if [ "$close_confirmation" == "no" ]; then
                exit 1;
            else
                log INFO "Closing device $new_device_name as requested."
                cryptsetup close "$new_device_name"
            fi
    fi

    log INFO "Opening new device to create a filesystem"
    cryptsetup open --key-file="/tmp/cryptkey" --type luks "/dev/disk/by-uuid/$uuid" "$new_device_name"

    mapped_device="/dev/mapper/$new_device_name"
    log INFO "Device opened and can be accessed on $mapped_device"
    
    read -p "Enter the filesystem type (default: xfs): " filesystem < /dev/tty
    if [ -z $filesystem ]; then
        filesystem="xfs"
    fi

    log INFO "Formatting device $mapped_device with $filesystem"
    mkfs."$filesystem" "$mapped_device"
    sleep 1 # this has to be here otherwise it throws an error
    log INFO "Device successfully formated."
    log INFO "Closing the device."
    cryptsetup close $mapped_device

    remove_cryptkey

    log INFO "Drive $block_dev initialized successfully. On next setup-storage-system, your device will be added to mergerfs array."
}

# Main script logic
check_and_init_crypttab_devices

if [ $# -eq 0 ]; then
    show_help
fi

command="$1"
shift

case "$command" in
check_crypttab)
;;
encrypt)
    encrypt "$@"
    ;;
decrypt)
    decrypt "$@"
    ;;
hdd-lock)
    hdd_lock
    ;;
hdd-unlock)
    hdd_unlock
    ;;
mount_drives)
    mount_drives
    ;;
umount-drives)
    umount_drives
    ;;
mount-fs)
    mount_fs
    ;;
umount-fs)
    umount_fs
    ;;
setup-storage-system)
    setup_storage_system
    ;;
close-storage-system)
    close_storage_system
    ;;
check-storage-system)
    check_storage_system
    ;;
init-drive)
    init_drive "$@"
    ;;
-h | --help)
    show_help
    ;;
*)
    log ERROR "Unknown command: $command"
    show_help
    ;;
esac
