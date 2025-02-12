#!/bin/bash

# Configuration
RESOURCE_GROUP=""  # Your resource group name
VM_NAME=""        # Your VM name
LOCATION=""       # Your Azure region (e.g., eastus)

# SSH Configuration
SSH_USER=""
SSH_HOST=""
SSH_PASS=""
SSH_TIMEOUT=60  # Timeout in seconds for SSH connection attempts

# Function to check if sshpass is installed
check_sshpass() {
    if ! command -v sshpass &> /dev/null
    then
        echo "Error: sshpass is not installed"
        echo "Install the package: sshpass"
        exit 1
    fi
}

# Function to check if azure-cli is installed
check_prerequisites() {
    if ! command -v az &> /dev/null
    then
        echo "Error: azure-cli is not installed"
        echo "Install the package: azure-cli"
        exit 1
    fi
    check_sshpass
}

# Function to check if user is logged in to Azure
check_azure_login() {
    if ! az account show &> /dev/null
    then
        echo "You are not logged in to Azure"
        echo "Please login using: az login"
        exit 1
    fi
}

# Function to get VM status with error handling
get_vm_status() {
    local status
    status=$(az vm get-instance-view \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "instanceView.statuses[1].displayStatus" \
        -o tsv 2>/dev/null)

    if [[ -z "$status" ]]
    then
        echo "unknown"
    else
        echo "$status"
    fi
}

# Function to test SSH connection
test_ssh_connection() {
    local max_attempts=6  # Try for 1 minute (6 * 10 seconds)
    local attempt=1

    while [[ $attempt -le $max_attempts ]]
    do
        echo "Testing SSH connection (attempt $attempt of $max_attempts)..."
        if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST" 'exit' 2>/dev/null
        then
            echo "SSH connection successful!"
            return 0
        fi
        ((attempt++))
        sleep 10
    done

    echo "Error: Could not establish SSH connection after $max_attempts attempts"
    return 1
}

# Function to connect via SSH
connect_ssh() {
    echo "Connecting to VM via SSH..."
    if test_ssh_connection
    then
        exec sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST"
    else
        exit 1
    fi
}

# Function to start VM
start_vm() {
    echo "Starting VM: $VM_NAME"

    # Check if VM exists
    if ! az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" &> /dev/null
    then
        echo "Error: VM '$VM_NAME' not found in resource group '$RESOURCE_GROUP'"
        exit 1
    fi

    # Get current VM status
    local STATUS
    STATUS=$(get_vm_status)
    echo "Initial status: $STATUS"

    if [[ "$STATUS" == "VM running" ]]
    then
        echo "VM is already running"
        connect_ssh
        return 0
    fi

    # Start the VM
    if ! az vm start \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --no-wait
    then
        echo "Error: Failed to initiate VM start command"
        exit 1
    fi

    echo "VM start command initiated"

    # Monitor VM status
    local retry_count=0
    local max_retries=30  # 5 minutes with 10-second intervals

    while [[ $retry_count -lt $max_retries ]]
    do
        STATUS=$(get_vm_status)
        echo "Current status: $STATUS"

        case "$STATUS" in
            "VM running")
                echo "VM is now running"
                connect_ssh
                return 0
                ;;
            "VM stopped")
                echo "Error: VM is stopped. Start operation may have failed."
                return 1
                ;;
            "unknown")
                echo "Warning: Unable to get VM status, retrying..."
                ;;
        esac

        ((retry_count++))
        sleep 10
    done

    echo "Error: Timed out waiting for VM to start after $((max_retries * 10)) seconds"
    return 1
}

# Main script execution
main() {
    check_prerequisites
    check_azure_login

    # Validate configuration
    if [[ -z "$VM_NAME" ]]
    then
        echo "Error: Please configure the script with your Azure details"
        echo "Edit the script and fill in:"
        echo "  - VM_NAME"
        exit 1
    fi

    if ! start_vm
    then
        echo "Failed to start VM"
        exit 1
    fi
}

main