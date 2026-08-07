#!/usr/bin/env bash
set -euo pipefail

ISO_DIR="/workspace/iso"
OUTPUT_DIR="/workspace/output"
TMP_DIR="/workspace/tmp"

: "${ANSWER_URL:?ANSWER_URL must be set}"

mapfile -t ISO_FILES < <(
    find "${ISO_DIR}" \
        -maxdepth 1 \
        -type f \
        -name 'proxmox-ve_*.iso' \
        | sort
)

if [[ "${#ISO_FILES[@]}" -ne 1 ]]; then
    echo "Expected exactly one Proxmox ISO in ${ISO_DIR}." >&2
    echo "Found ${#ISO_FILES[@]} ISO files:" >&2
    printf '  %s\n' "${ISO_FILES[@]:-none}" >&2
    exit 1
fi

ISO_PATH="${ISO_FILES[0]}"

echo "Using ISO:"
echo "  ${ISO_PATH}"
echo
echo "Answer endpoint:"
echo "  ${ANSWER_URL}"
echo
echo "Output directory:"
echo "  ${OUTPUT_DIR}"
echo
echo "Temporary directory:"
echo "  ${TMP_DIR}"
echo

mkdir -p "${OUTPUT_DIR}" "${TMP_DIR}"

find "${OUTPUT_DIR}" \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf -- {} +

find "${TMP_DIR}" \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf -- {} +

FIRST_BOOT_SOURCE="/workspace/builder/first-boot.sh"
FIRST_BOOT_RENDERED="${TMP_DIR}/first-boot.sh"

: "${PROVISION_IP:?PROVISION_IP must be set}"

sed \
    "s|@PROVISION_IP@|${PROVISION_IP}|g" \
    "${FIRST_BOOT_SOURCE}" \
    > "${FIRST_BOOT_RENDERED}"

chmod +x "${FIRST_BOOT_RENDERED}"

if ! proxmox-auto-install-assistant prepare-iso \
    "${ISO_PATH}" \
    --fetch-from http \
    --url "${ANSWER_URL}" \
    --pxe-loader ipxe \
    --on-first-boot "${FIRST_BOOT_RENDERED}" \
    --tmp "${TMP_DIR}" \
    --output "${OUTPUT_DIR}"
then
    echo "Error: PXE artifact generation failed." >&2
    exit 1
fi

echo
echo "Generated PXE artifacts:"

find "${OUTPUT_DIR}" \
    -maxdepth 2 \
    -type f \
    -printf '  %P (%s bytes)\n' \
    | sort
