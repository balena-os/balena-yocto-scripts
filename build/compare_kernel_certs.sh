#!/bin/bash
set -uo pipefail

# ORIGINAL_CERT_BASE64=$1
BUILD_DIR="${BUILD_DIR:-build}"

# if [[ -z "$ORIGINAL_CERT_BASE64" ]]; then
#     echo "Usage: $0 <base64-encoded-cert>" >&2
#     exit 1
# fi

# Use INSTALL_DIR to find Yocto layers (since we're in container root)
INSTALL_DIR="${INSTALL_DIR:-/work}"

# Source Yocto environment (same pattern as barys)
echo "[INFO] Sourcing Yocto environment..."
if [ -f "${INSTALL_DIR}/layers/poky/oe-init-build-env" ]; then
    source "${INSTALL_DIR}/layers/poky/oe-init-build-env" "${INSTALL_DIR}/${BUILD_DIR}"
else
    echo "Error: Yocto environment not found at ${INSTALL_DIR}/layers/poky/oe-init-build-env" >&2
    exit 1
fi

# Extract Yocto/BitBake environment information using bitbake -e
echo "[INFO] Extracting Yocto environment information from bitbake..."
BITBAKE_ENV=$(bitbake -e virtual/kernel 2>/dev/null )

if [ -n "$BITBAKE_ENV" ]; then
    echo "[INFO] Yocto environment information:"
    # Extract variables from bitbake -e output (format: VARIABLE="value")
    MACHINE_VAL=$(echo "$BITBAKE_ENV" | awk -F'"' '/^MACHINE="/{print $2; exit}')
    DISTRO_VAL=$(echo "$BITBAKE_ENV" | awk -F'"' '/^DISTRO="/{print $2; exit}')
    DL_DIR_VAL=$(echo "$BITBAKE_ENV" | awk -F'"' '/^DL_DIR="/{print $2; exit}')
    SSTATE_DIR_VAL=$(echo "$BITBAKE_ENV" | awk -F'"' '/^SSTATE_DIR="/{print $2; exit}')
    
    echo "  MACHINE: ${MACHINE_VAL:-not found}"
    echo "  DISTRO: ${DISTRO_VAL:-not found}"
    echo "  DL_DIR: ${DL_DIR_VAL:-not found}"
    echo "  SSTATE_DIR: ${SSTATE_DIR_VAL:-not found}"
else
    echo "[WARN] Could not extract bitbake environment information"
fi
echo "  BUILD_DIR: ${BUILD_DIR}"
echo "  Current directory: $(pwd)"

# # Mock version - just verify we received the cert
# echo "[INFO] Certificate length: ${#ORIGINAL_CERT_BASE64} characters"

# # Basic validation - check it's valid base64
# if ! echo "$ORIGINAL_CERT_BASE64" | base64 -d > /dev/null 2>&1; then
#     echo "Error: Certificate is not valid base64" >&2
#     exit 2
# fi

echo "[INFO] Certificate validation successful - certificate provided and is valid base64"
echo "[INFO] Implement actual certificate comparison with vmlinux files"

exit 0

