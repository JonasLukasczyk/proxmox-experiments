#!/usr/bin/env bash
set -euo pipefail

PROVISION_SERVER="@PROVISION_IP@"

echo "Confirming Proxmox installation with provisioning server..."

mapfile -t MACS < <(
    ip -o link show \
        | awk '/link\/ether/ {print $17}' \
        | tr '[:upper:]' '[:lower:]' \
        | sort -u
)

if [[ "${#MACS[@]}" -eq 0 ]]; then
    echo "Error: no Ethernet MAC addresses found." >&2
    exit 1
fi

for mac in "${MACS[@]}"; do
    echo "Trying MAC: ${mac}"

    if curl --fail --silent --show-error \
        --request POST \
        "http://${PROVISION_SERVER}/confirmInstalled?mac=${mac}"
    then
        echo
        echo "Installation confirmed using MAC ${mac}."
        exit 0
    fi
done

echo "Error: provisioning server did not recognize any local MAC address." >&2
exit 1
