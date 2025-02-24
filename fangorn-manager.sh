#!/bin/bash
set -euo pipefail

HDD_ENCRYPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HDD_ENCRYPT_DIR/.env"

# Constants
VAULT_MANAGER="$HDD_ENCRYPT_DIR/vault-manager.sh"



# Log function with color-coded output
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    case "$level" in
        "INFO")
            printf "\e[32m[%s] [INFO] %s\e[0m\n" "$timestamp" "$message"  # Green
            ;;
        "WARN")
            printf "\e[33m[%s] [WARN] %s\e[0m\n" "$timestamp" "$message"  # Yellow
            ;;
        "ERROR")
            printf "\e[31m[%s] [ERROR] %s\e[0m\n" "$timestamp" "$message" # Red
            ;;
        *)
            printf "\e[34m[%s] [%s] %s\e[0m\n" "$timestamp" "$level" "$message" # Blue for custom levels
            ;;
    esac
}

# Check if a value exists in an array
array_contains() {
    local value="$1"
    shift
    local array=("$@")
    for item in "${array[@]}"; do
        [ "$item" = "$value" ] && return 0
    done
    return 1
}

# Check and mount the vault storage system
unlock_vault() {
    log INFO "Checking vault storage system status"
    set +e
    "$VAULT_MANAGER" "check-storage-system"
    local status=$?
    set -e

    if [ "$status" -ne 0 ]; then
        log WARN "Storage system not mounted, attempting to mount"
        "$VAULT_MANAGER" "setup-storage-system"

        set +e
        "$VAULT_MANAGER" "check-storage-system"
        status=$?
        set -e

        if [ "$status" -ne 0 ]; then
            log ERROR "Storage system still not mounted after attempt"
            return 1
        fi
        log INFO "Vault storage system mounted successfully"
        sleep 1
        restart_vault_dependent_vms
    else
        log INFO "Vault storage system is already mounted"
    fi
    return 0
}

lock_vault() {
    log INFO "Shutting down vault dependent VMs"
    shut_down_vault_dependent_vms

    log INFO "Locking vault storage system"
    "$VAULT_MANAGER" "close-storage-system"
}

# Restart VMs that depend on the vault
restart_vault_dependent_vms() {
    log INFO "Rebooting VMs that rely on vault"
    for vmid in "${VM_TO_RESTART_AFTER_VAULT[@]}"; do
        local name=$($qm config "$vmid" 2>/dev/null | grep '^name:' | awk '{print $2}' || echo "VM-$vmid")
        log INFO "Shutting down VM $name (ID: $vmid)"
        $qm stop "$vmid" 2>/dev/null || log WARN "Failed to stop VM $name (ID: $vmid), continuing..."
        log INFO "Starting VM $name (ID: $vmid)"
        $qm start "$vmid" 2>/dev/null || log ERROR "Failed to start VM $name (ID: $vmid)"
    done
}

shut_down_vault_dependent_vms() {
    log INFO "Shutting down VMs that rely on vault"
    for vmid in "${VM_TO_RESTART_AFTER_VAULT[@]}"; do
        local name=$($qm config "$vmid" 2>/dev/null | grep '^name:' | awk '{print $2}' || echo "VM-$vmid")
        log INFO "Shutting down VM $name (ID: $vmid)"
        $qm stop "$vmid" 2>/dev/null || log WARN "Failed to stop VM $name (ID: $vmid), continuing..."
    done
}

# Ensure specified VMs are running
ensure_vms_running() {
    json_data=$($pvesh get /cluster/resources --type vm --output-format json)

    # Check if json_data is empty or invalid
    if [ -z "$json_data" ]; then
        log ERROR "Failed to retrieve VM data from $pvesh"
        exit 1
    fi
    log INFO "Checking status of target VMs"

    echo "$json_data" | $jq -r '.[] | [.vmid, .name, .status, .node] | join("\t")' | while IFS=$'\t' read -r vmid name status node; do
        if array_contains "$vmid" "${VM_TO_START[@]}"; then
            case "$status" in
                "running")
                    log INFO "VM $vmid ($name) on $node is already running"
                    ;;
                "stopped")
                    log INFO "VM $vmid ($name) on $node is stopped, starting it"
                    $pvesh create "/nodes/$node/qemu/$vmid/status/start" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        log INFO "VM $vmid ($name) started successfully"
                    else
                        log ERROR "Failed to start VM $vmid ($name) on $node"
                    fi
                    ;;
                *)
                    log WARN "VM $vmid ($name) on $node has status '$status', skipping"
                    ;;
            esac
        else
            log INFO "VM $vmid ($name) not in target list, skipping"
        fi
    done
}

stop_nonessential_vms() {
    json_data=$($pvesh get /cluster/resources --type vm --output-format json)

    # Check if json_data is empty or invalid
    if [ -z "$json_data" ]; then
        log ERROR "Failed to retrieve VM data from pvesh"
        exit 1
    fi
    log INFO "Checking status of target VMs"

    echo "$json_data" | $jq -r '.[] | [.vmid, .name, .status, .node] | join("\t")' | while IFS=$'\t' read -r vmid name status node; do
        if array_contains "$vmid" "${VM_TO_START[@]}"; then
           log INFO "VM $vmid ($name) not in essential list, skipping"
        else
             case "$status" in
                "running")
                    log INFO "VM $vmid ($name) on $node is running. Stopping it."
                    $qm stop "$vmid" 2>/dev/null || log WARN "Failed to stop VM $name (ID: $vmid), continuing..."
                    ;;
                "stopped")
                    log INFO "VM $vmid ($name) on $node is stopped."
                    ;;
                *)
                    log WARN "VM $vmid ($name) on $node has status '$status', skipping"
                    ;;
            esac
        fi
    done
}

send_mail_if_vault_locked() {
    # Check the vault status
    local vault_status
    set +e
    vault_status=$("$VAULT_MANAGER" "check-storage-system")
    local vault_check_exit_code=$?
    set -e

    # If vault is locked (non-zero exit code), proceed with email notification
    if [ "$vault_check_exit_code" -ne 0 ]; then
        log INFO "Storage system is not mounted, preparing to send email."

        # Get the current time
        local current_time
        current_time=$(date +"%Y-%m-%d %H:%M:%S")

        # Check if an email has already been sent recently
        if [ -f "$MAIL_SENT_FILE" ]; then
            local last_sent_time
            last_sent_time=$(cat "$MAIL_SENT_FILE")
            local last_sent_timestamp
            last_sent_timestamp=$(date -d "$last_sent_time" +%s)
            local current_timestamp
            current_timestamp=$(date -d "$current_time" +%s)
            local time_difference
            time_difference=$(((current_timestamp - last_sent_timestamp) / 60))

            # Skip sending if less than MIN_INTERVAL minutes have passed
            if [ "$time_difference" -lt "$MIN_INTERVAL" ]; then
                log INFO "Email was sent less than $MIN_INTERVAL minutes ago, skipping."
                exit 0
            fi
        fi

        log INFO "Sending email notification to $MAILTO"

        # Compose a formatted email body
        local email_subject="Fangorn Vault Locked - Action Required"
        local email_body
        email_body=$(printf "Dear Administrator,\n\nThe storage vault on Fangorn is currently locked as of %s.\nPlease log into Fangorn to unlock it.\n\nDetails:\n%s\n\nRegards,\nVault Monitoring System" "$current_time" "$vault_status")

        # Send the email
        echo "$email_body" | mail -s "$email_subject" "$MAILTO"

        # Update the timestamp file with the current time
        echo "$current_time" > "$MAIL_SENT_FILE"
    else
        log INFO "Vault is mounted, not sending email."
    fi
}

# Help function to display usage information
help() {
    echo "Usage: $0 [command]"
    echo
    echo "Commands:"
    echo "  unlock-vault                  Runs when no argument. Unlock the vault storage system and restarts VMs dependant on vault."
    echo "  lock-vault                    Lock the vault storage system"
    echo "  send-mail                     Sends mail if vault is locked"
    echo "  stop-nonessential-vms         Stops all VMs that are not essential."
    echo "  shutdown-vault-dependent-vms  Shut down VMs that depend on the vault"
    echo "  restart-vault-dependent-vms   Restart VMs that depend on the vault"
    echo "  ensure-vms                    Ensure specified VMs are running"
    echo "  -h|--help                     Display this help message"
}

# Main execution
main() {
    log INFO "Starting VM management script"
    if ! unlock_vault; then
        log ERROR "Vault management failed, exiting"
        exit 1
    fi
    ensure_vms_running
    log INFO "VM management script completed"
}

# Run the script
# Argument handling
if [ "$#" -eq 0 ]; then
    main
else
    case "$1" in
        "unlock-vault")
            main
            ;;
        "lock-vault")
            lock_vault
            ;;
        "send-mail")
            send_mail_if_vault_locked
            ;;
        "stop-nonessential-vms")
            stop_nonessential_vms
            ;;
        "shutdown-vault-dependent-vms")
            shut_down_vault_dependent_vms
            ;;
        "restart-vault-dependent-vms")
            restart_vault_dependent_vms
            ;;
        "ensure-vms")
            ensure_vms_running
            ;;
        -h | --help)
            help
            ;;
        *)
            log ERROR "Unknown argument: $1"
            help
            exit 1
            ;;
    esac
fi
