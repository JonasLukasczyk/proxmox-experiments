#!/usr/bin/env bash

# Stop immediately on errors, unset variables, or failed pipeline commands.
set -euo pipefail

###############################################################################
# Proxmox smart-PXE provisioning server
#
# Services:
#   dnsmasq  - DHCP, PXE options and TFTP
#   nginx    - Public HTTP endpoint and large static files
#   Node.js  - Dynamic iPXE decisions and Proxmox answer files
#
# Network:
#   Provisioning host: 192.168.50.1/24
#   DHCP clients:       192.168.50.100-150
###############################################################################

###############################################################################
# 1. Configuration
###############################################################################

set -a
source .env
set +a

LINK="${PROVISION_INTERFACE}"
PROVISION_CIDR="${PROVISION_IP}/24"

# Confirm that the selected interface exists before changing anything.
if ! ip link show "${LINK}" >/dev/null 2>&1; then
    echo "Error: network interface '${LINK}' does not exist." >&2
    echo "Available interfaces:" >&2
    ip -br link >&2
    exit 1
fi

###############################################################################
# 2. Configure the dedicated provisioning interface
###############################################################################

# Bring the interface up and assign the provisioning address.
#
# The address is temporary and will disappear after reboot. It can later be
# made persistent with NetworkManager, systemd-networkd or another host network
# configuration system.
sudo ip link set "${LINK}" up
sudo ip addr flush dev "${LINK}"
sudo ip addr add "${PROVISION_CIDR}" dev "${LINK}"

echo "Provisioning interface:"
ip -br addr show "${LINK}"

# A working cable and powered target should cause LOWER_UP to appear.
echo
echo "Physical-link status:"
sudo ethtool "${LINK}" | grep -E 'Speed:|Duplex:|Link detected:' || true

###############################################################################
# 3. Create the project directories
###############################################################################

mkdir -p \
    builder \
    builder/tmp \
    config/dnsmasq \
    config/nginx \
    app/src \
    data/dnsmasq \
    data/inventory \
    data/tftp \
    data/iso \
    data/http/proxmox \
    data/http/static \
    data/http/answers


# dnsmasq writes leases into this bind-mounted directory.
touch data/dnsmasq/dnsmasq.leases

###############################################################################
# 9. Configure DHCP, TFTP and PXE
###############################################################################

envsubst \
    '${PROVISION_INTERFACE} ${DHCP_START} ${DHCP_END}' \
    < config/dnsmasq/dnsmasq.conf.template \
    > config/dnsmasq/dnsmasq.conf

###############################################################################
# 10. Download the UEFI iPXE loader
###############################################################################

curl --fail --location \
    https://boot.ipxe.org/x86_64-efi/ipxe.efi \
    --output data/tftp/ipxe.efi

# Confirm that the downloaded file is an EFI executable.
file data/tftp/ipxe.efi

###############################################################################
# 11. Create the iPXE bootstrap script
###############################################################################
sed \
    "s|@PROVISION_IP@|${PROVISION_IP}|g" \
    config/ipxe/autoexec.ipxe.template \
    > data/tftp/autoexec.ipxe

# step download iso
ISO_FILE="proxmox-ve_9.2-1.iso"
ISO_DIR="./data/iso"
ISO_URL="http://download.proxmox.com/iso/${ISO_FILE}"

if [[ ! -f "${ISO_DIR}/${ISO_FILE}" ]]; then
    echo "Downloading Proxmox ISO..."
    curl --fail --location \
        "${ISO_URL}" \
        --output "${ISO_DIR}/${ISO_FILE}"
else
    echo "Proxmox ISO already exists: ${ISO_DIR}/${ISO_FILE}"
fi



###############################################################################
# 14. Validate the generated configuration
###############################################################################

echo
echo "Validating Docker Compose configuration..."
sudo docker compose config >/dev/null

echo "Compose configuration is valid."

mkdir -p builder/tmp

echo "Stopping existing provisioning stack..."
sudo docker compose down --remove-orphans
sudo docker rm -f \
    proxmox-dnsmasq \
    proxmox-nginx \
    proxmox-api \
    proxmox-builder \
    2>/dev/null || true

echo "Building PXE artifacts..."
sudo docker compose --profile build build builder
sudo docker compose --profile build run --rm builder

echo "Starting provisioning stack..."
sudo docker compose up --detach --build

###############################################################################
# 16. Verify the services
###############################################################################

echo
echo "Container status:"
sudo docker compose ps

echo
echo "dnsmasq startup log:"
sudo docker compose logs --tail=30 dnsmasq

echo
echo "Node.js API startup log:"
sudo docker compose logs --tail=30 api

echo
echo "nginx startup log:"
sudo docker compose logs --tail=30 nginx

###############################################################################
# 17. Verify HTTP routing
###############################################################################

echo "Waiting for provisioning server..."

for i in {1..30}; do
    if curl --silent --fail http://192.168.50.1/health >/dev/null; then
        echo "Provisioning server is ready."
        break
    fi

    sleep 1
done

echo
echo "Checking API health through nginx..."
curl --fail --show-error http://192.168.50.1/health
echo

echo
echo "Checking nginx landing page..."
curl --fail --show-error http://192.168.50.1/
echo

echo
echo "Checking dynamic iPXE response..."
curl --fail --show-error \
    'http://192.168.50.1/ipxe/boot?mac=c4:d6:d3:64:61:3e'
echo

###############################################################################
# 18. Verify bind mounts
###############################################################################

echo
echo "TFTP files visible inside dnsmasq:"
sudo docker exec proxmox-dnsmasq ls -lh /srv/tftp

echo
echo "HTTP files visible inside nginx:"
sudo docker exec proxmox-nginx find /usr/share/nginx/html \
    -maxdepth 3 -type f -print

###############################################################################
# 19. Final status
###############################################################################

cat <<EOF
Provisioning stack is ready.

Provisioning interface: ${LINK}
Provisioning address:   http://${PROVISION_IP}/
API health check:       http://${PROVISION_IP}/health
Dynamic iPXE endpoint:  http://${PROVISION_IP}/ipxe/boot?mac=<MAC>

Next PXE boot flow:

  Dell UEFI
    -> dnsmasq DHCP
    -> ipxe.efi over TFTP
    -> autoexec.ipxe over TFTP
    -> nginx on port 80
    -> Node.js /ipxe/boot endpoint
EOF

