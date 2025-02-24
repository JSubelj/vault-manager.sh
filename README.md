# vault-manager.sh
### Creating a media vault with LUKS and mergerFS.

This script was created for personal use. Backup all your data!

Before use you should:
- Basic install (clone, move env to .env and chmod +x)
- Create encryption key
- Edit .env at least for MOUNT_POINT

## Script installation
### Cloning and initial setup
```
git clone https://github.com/JSubelj/vault-manager.sh.git vault-manager
cd vault-manager
cp env .env
chmod +x vault-manager.sh
```
You can also add to your path. You can also source `_vault-manager.sh_completions` file to have autocompletion.
### Creating an encryption key 
```
dd bs=64 count=1 if=/dev/random of=/tmp/cryptkey iflag=fullblock
# encrypt it (and it also removes /tmp/cryptkey) REMEMBER YOUR PASSWORD!!!
./vault-manager.sh encrypt /tmp/cryptkey ./cryptkey_encrypted
```

## vault-manager.sh -h
```
Usage: /root/lock-and-loaded/vault-manager.sh [command] [options]

If no command it just checks crypttab

Primary commands:
  check-storage-system                  Check if storage system is mounted and operational
  setup-storage-system                  Setup and initialize the complete storage system
  close-storage-system                  Safely close and lock the storage system

Initialisation commands:
  init-drive <block-dev>                Initialises the drive

Debug commands:
  encrypt <input_file> <output_file>    Encrypt a file
  decrypt <input_file> <output_file>    Decrypt a file
  hdd-lock                              Lock all encrypted drives
  hdd-unlock                            Unlock all encrypted drives
  mount-drives                          Mount individual encrypted drives
  umount-drives                         Unmount individual encrypted drives
  mount-fs                              Mount the combined filesystem
  umount-fs                             Unmount the combined filesystem

Options:
  -h, --help                            Show this help message

Examples:
  /root/lock-and-loaded/vault-manager.sh encrypt secret.txt secret.txt.enc
  /root/lock-and-loaded/vault-manager.sh hdd-unlock
  /root/lock-and-loaded/vault-manager.sh mount-fs
```


## Using
### Adding harddisk
```
vault-manager.sh init-drive <block-dev>
``` 
### Mounting vault
```
vault-manager.sh setup-storage-system
``` 

### Unmount vault
```
vault-manager.sh close-storage-system
``` 

## Settings
Dot env file is the one that manager uses!\
`.env:`
```
# HDD_ENCRYPT_DIR is setup inside the vault-manager.sh and points to location of the script
# ENCRYPTED_KEY points to an encrypted key used for LUKS encryption
ENCRYPTED_KEY="$HDD_ENCRYPT_DIR/cryptkey_encrypted" 
# CRYPTTAB points to a file (it auto generated) where info about drives is stored
CRYPTTAB="$HDD_ENCRYPT_DIR/crypttab"
# KEY_FILE points to where encrypted key should get decripted and used
KEY_FILE="/tmp/cryptkey"
# TARGET_BASE_NAME base name of drives opened by LUKS
TARGET_BASE_NAME="crypt"
# HEADERS_BACKUP_DIR points to header backup files directory 
HEADERS_BACKUP_DIR="$HDD_ENCRYPT_DIR/header-backup-files"
# Options for merger fs
MERGERFS_OPTIONS="cache.files=off,dropcacheonclose=false,category.create=lus"

# Where individual drives should be mounted
INDIVIDUAL_DRIVE_MOUNT_DIR="/mnt/crypt_fs"
# Where filesystem should be mounted
MOUNT_POINT="/mnt/vault"
...
```

## Fangorn manager
Fangorn manager is used to manipulate proxmox with vault. It's named after my server, fangorn, but should work with your system as well, but I hadn't put all that time into it so... there be dragons!

## fangorn-manager.sh -h
```
Usage: /root/lock-and-loaded/fangorn-manager.sh [command]

Commands:
  unlock-vault                  Runs when no argument. Unlock the vault storage system and restarts VMs dependant on vault.
  lock-vault                    Lock the vault storage system
  send-mail                     Sends mail if vault is locked
  stop-nonessential-vms         Stops all VMs that are not essential.
  shutdown-vault-dependent-vms  Shut down VMs that depend on the vault
  restart-vault-dependent-vms   Restart VMs that depend on the vault
  ensure-vms                    Ensure specified VMs are running
  -h|--help                     Display this help message
```

## References and docs:
- [Encrypted Btrfs storage setup and maintenance guide](https://gist.github.com/MaxXor/ba1665f47d56c24018a943bb114640d7)
- [mergerfs](https://github.com/trapexit/mergerfs)
- [cryptsetup docs](https://linux.die.net/man/8/cryptsetup)