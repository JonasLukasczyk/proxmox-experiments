#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Proxmox smart-PXE provisioning server
#
# Services:
#   dnsmasq  - DHCP, PXE options and TFTP
#   nginx    - Public HTTP endpoint and large static files
#   Node.js  - Dynamic iPXE decisions and Proxmox answer files
###############################################################################

###############################################################################
# 1. Load configuration
###############################################################################

if [[ ! -f .env ]]; then
    echo "Error: .env does not exist." >&2
    exit 1
fi

set -a
source .env
set +a

: "${PROVISION_INTERFACE:?PROVISION_INTERFACE is not set}"
: "${PROVISION_IP:?PROVISION_IP is not set}"
: "${DHCP_START:?DHCP_START is not set}"
: "${DHCP_END:?DHCP_END is not set}"

LINK="${PROVISION_INTERFACE}"
PROVISION_CIDR="${PROVISION_IP}/24"

###############################################################################
# 2. Validate and configure provisioning interface
###############################################################################

if ! ip link show "${LINK}" >/dev/null 2>&1; then
    echo "Error: network interface '${LINK}' does not exist." >&2
    echo "Available interfaces:" >&2
    ip -br link >&2
    exit 1
fi

echo "Configuring provisioning interface '${LINK}'..."

sudo ip link set "${LINK}" up
sudo ip addr flush dev "${LINK}"
sudo ip addr add "${PROVISION_CIDR}" dev "${LINK}"

echo
echo "Provisioning interface:"
ip -br addr show "${LINK}"

echo
echo "Physical-link status:"
sudo ethtool "${LINK}" \
    | grep -E 'Speed:|Duplex:|Link detected:' \
    || true

###############################################################################
# 3. Create required directories
###############################################################################

mkdir -p \
    builder/tmp \
    config/dnsmasq \
    config/ipxe \
    config/nginx \
    app/src \
    data/dnsmasq \
    data/inventory \
    data/tftp \
    data/iso \
    data/http/proxmox \
    data/http/static \
    data/http/answers

touch data/dnsmasq/dnsmasq.leases

if [[ ! -f data/inventory/hosts.json ]]; then
    echo '{}' > data/inventory/hosts.json
fi

###############################################################################
# 4. Generate dnsmasq configuration
###############################################################################

echo "Generating dnsmasq configuration..."

envsubst \
    '${PROVISION_INTERFACE} ${DHCP_START} ${DHCP_END}' \
    < config/dnsmasq/dnsmasq.conf.template \
    > config/dnsmasq/dnsmasq.conf

###############################################################################
# 5. Download iPXE UEFI loader
###############################################################################

IPXE_FILE="data/tftp/ipxe.efi"
IPXE_URL="https://boot.ipxe.org/x86_64-efi/ipxe.efi"

if [[ ! -f "${IPXE_FILE}" ]]; then
    echo "Downloading iPXE UEFI loader..."

    curl --fail --location \
        "${IPXE_URL}" \
        --output "${IPXE_FILE}.tmp"

    mv "${IPXE_FILE}.tmp" "${IPXE_FILE}"
else
    echo "iPXE loader already exists: ${IPXE_FILE}"
fi

echo
echo "iPXE loader:"
file "${IPXE_FILE}"

###############################################################################
# 6. Generate iPXE bootstrap script
###############################################################################

echo
echo "Generating iPXE bootstrap script..."

sed \
    "s|@PROVISION_IP@|${PROVISION_IP}|g" \
    config/ipxe/autoexec.ipxe.template \
    > data/tftp/autoexec.ipxe

###############################################################################
# 7. Download Proxmox ISO
###############################################################################

ISO_FILE="proxmox-ve_9.2-1.iso"
ISO_DIR="data/iso"
ISO_URL="http://download.proxmox.com/iso/${ISO_FILE}"
ISO_PATH="${ISO_DIR}/${ISO_FILE}"

if [[ ! -f "${ISO_PATH}" ]]; then
    echo
    echo "Downloading Proxmox ISO..."

    curl --fail --location \
        "${ISO_URL}" \
        --output "${ISO_PATH}.tmp"

    mv "${ISO_PATH}.tmp" "${ISO_PATH}"
else
    echo
    echo "Proxmox ISO already exists: ${ISO_PATH}"
fi

###############################################################################
# 8. Validate Docker Compose configuration
###############################################################################

echo
echo "Validating Docker Compose configuration..."

sudo docker compose --profile build config >/dev/null

echo "Compose configuration is valid."

###############################################################################
# 9. Stop existing stack
###############################################################################

echo
echo "Stopping existing provisioning stack..."

sudo docker compose down --remove-orphans || true

###############################################################################
# 10. Build PXE artifacts
###############################################################################

echo
echo "Building PXE artifact builder..."

sudo docker compose --profile build build builder

echo
echo "Generating PXE artifacts..."

sudo docker compose --profile build run --rm builder

###############################################################################
# 11. Start provisioning services
###############################################################################

echo
echo "Starting provisioning stack..."

sudo docker compose up --detach --build

###############################################################################
# 12. Verify services
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
# 13. Wait for HTTP service
###############################################################################

echo
echo "Waiting for provisioning server..."

ready=false

for _ in {1..30}; do
    if curl --silent --fail \
        "http://${PROVISION_IP}/health" \
        >/dev/null
    then
        ready=true
        break
    fi

    sleep 1
done

if [[ "${ready}" != true ]]; then
    echo "Error: provisioning server did not become ready." >&2
    echo
    echo "nginx logs:"
    sudo docker compose logs --tail=100 nginx || true
    echo
    echo "API logs:"
    sudo docker compose logs --tail=100 api || true
    exit 1
fi

echo "Provisioning server is ready."

###############################################################################
# 14. Verify HTTP routing
###############################################################################

echo
echo "Checking API health through nginx..."

curl --fail --show-error \
    "http://${PROVISION_IP}/health"

echo
echo
echo "Checking dynamic iPXE response..."

curl --fail --show-error \
    "http://${PROVISION_IP}/ipxe/boot?mac=c4:d6:d3:64:61:3e"

echo

###############################################################################
# 15. Verify bind mounts
###############################################################################

echo
echo "TFTP files visible inside dnsmasq:"

sudo docker compose exec dnsmasq \
    ls -lh /srv/tftp

echo
echo "HTTP files visible inside nginx:"

sudo docker compose exec nginx \
    find /usr/share/nginx/html \
        -maxdepth 3 \
        -type f \
        -print

###############################################################################
# 16. Final status
###############################################################################

cat <<EOF

Provisioning stack is ready.

Provisioning interface: ${LINK}
Provisioning IP:        ${PROVISION_IP}
API health check:       http://${PROVISION_IP}/health
Dynamic iPXE endpoint:  http://${PROVISION_IP}/ipxe/boot?mac=<MAC>

Next PXE boot flow:

  UEFI PXE
    -> dnsmasq DHCP
    -> ipxe.efi over TFTP
    -> autoexec.ipxe over TFTP
    -> nginx on port 80
    -> Node.js /ipxe/boot endpoint

EOF
