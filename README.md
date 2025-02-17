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
```



## References and docs:
- [Encrypted Btrfs storage setup and maintenance guide](https://gist.github.com/MaxXor/ba1665f47d56c24018a943bb114640d7)
- [mergerfs](https://github.com/trapexit/mergerfs)
- [cryptsetup docs](https://linux.die.net/man/8/cryptsetup)