#!/usr/bin/env bash
# ==============================================================================
# AMNESIAX — Production Qubes OS (dom0) Provisioning Script
# ==============================================================================
# Target: Qubes OS 4.2+ (Run strictly from dom0)
# Purpose: Automates creation of the AMNESIAX compartmentalized infrastructure:
#   - amnesiax-vault:    Air-gapped secure storage (netvm = none)
#   - amnesiax-dvm:      Hardened Disposable Template
#   - disp-browser:      Disposable browser domain (netvm = sys-whonix)
#   - disp-files:        Air-gapped document viewer (netvm = none)
#   - amnesiax-dev:      Isolated development environment
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "${BOLD}${CYAN}  AMNESIAX Production Qubes OS Infrastructure Provisioning (dom0)      ${NC}"
echo -e "${BOLD}${CYAN}======================================================================${NC}"

# Verification: Must run in dom0
if [[ "$(hostname)" != "dom0" ]] && [[ ! -f /etc/qubes-release ]]; then
    echo -e "${RED}[!] Error: This script must be executed strictly inside Qubes OS dom0.${NC}" >&2
    exit 1
fi

BASE_TEMPLATE="${1:-debian-12-xfce}"
WHONIX_WS_TEMPLATE="${2:-whonix-workstation-17}"

echo -e "[*] Using Base Template: ${BASE_TEMPLATE}"
echo -e "[*] Using Whonix Template: ${WHONIX_WS_TEMPLATE}"

# ------------------------------------------------------------------------------
# 1. Provision amnesiax-vault (Air-Gapped Cold Storage)
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[1/4] Provisioning amnesiax-vault (Air-Gapped)...${NC}"
if qvm-check amnesiax-vault &>/dev/null; then
    echo "  - amnesiax-vault already exists. Ensuring netvm is none..."
else
    qvm-create --class AppVM --template "${BASE_TEMPLATE}" --label black amnesiax-vault
fi
# Enforce absolute air-gap: Zero network interfaces
qvm-prefs amnesiax-vault netvm ""
qvm-prefs amnesiax-vault memory 1024
qvm-prefs amnesiax-vault maxmem 2048
echo -e "${GREEN}[+] amnesiax-vault configured (netvm = none, label = black).${NC}"

# ------------------------------------------------------------------------------
# 2. Provision amnesiax-dvm (Disposable VM Template)
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[2/4] Provisioning amnesiax-dvm (Disposable Template)...${NC}"
if qvm-check amnesiax-dvm &>/dev/null; then
    echo "  - amnesiax-dvm already exists."
else
    qvm-create --class AppVM --template "${WHONIX_WS_TEMPLATE}" --label red amnesiax-dvm
fi
qvm-prefs amnesiax-dvm template_for_dispvms True
qvm-prefs amnesiax-dvm netvm sys-whonix
echo -e "${GREEN}[+] amnesiax-dvm created and marked as Disposable Template.${NC}"

# ------------------------------------------------------------------------------
# 3. Provision amnesiax-files (Air-Gapped Document Inspector)
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[3/4] Provisioning amnesiax-files (Air-Gapped Document Sandbox)...${NC}"
if qvm-check amnesiax-files &>/dev/null; then
    echo "  - amnesiax-files already exists."
else
    qvm-create --class AppVM --template "${BASE_TEMPLATE}" --label orange amnesiax-files
fi
# Strictly non-networked for untrusted PDF/Office inspection
qvm-prefs amnesiax-files netvm ""
echo -e "${GREEN}[+] amnesiax-files configured (Air-Gapped document isolation).${NC}"

# ------------------------------------------------------------------------------
# 4. Provision amnesiax-dev (Isolated Development Domain)
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[4/4] Provisioning amnesiax-dev (Development Compartment)...${NC}"
if qvm-check amnesiax-dev &>/dev/null; then
    echo "  - amnesiax-dev already exists."
else
    qvm-create --class AppVM --template "${BASE_TEMPLATE}" --label blue amnesiax-dev
fi
# Connected through sys-firewall or sys-whonix
qvm-prefs amnesiax-dev netvm sys-firewall
echo -e "${GREEN}[+] amnesiax-dev configured (label = blue, netvm = sys-firewall).${NC}"

# ------------------------------------------------------------------------------
# 5. Apply Hardened qrexec Policies
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[*] Installing AMNESIAX qrexec policies into /etc/qubes/policy.d/...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="${SCRIPT_DIR}/30-amnesiax.policy"

if [[ -f "${POLICY_FILE}" ]]; then
    cp "${POLICY_FILE}" /etc/qubes/policy.d/30-amnesiax.policy
    chmod 644 /etc/qubes/policy.d/30-amnesiax.policy
    echo -e "${GREEN}[+] 30-amnesiax.policy successfully installed.${NC}"
else
    echo -e "${RED}[!] Warning: 30-amnesiax.policy not found in script directory.${NC}"
fi

echo -e "\n${BOLD}${GREEN}======================================================================${NC}"
echo -e "${BOLD}${GREEN}  AMNESIAX Bare-Metal Qubes OS Provisioning Complete!                ${NC}"
echo -e "${BOLD}${GREEN}======================================================================${NC}"
echo -e "Domains created:"
echo -e "  - ${BOLD}amnesiax-vault${NC} : Cold storage, private keys (Air-Gapped)"
echo -e "  - ${BOLD}amnesiax-dvm${NC}   : Disposable Template (Routes via sys-whonix)"
echo -e "  - ${BOLD}amnesiax-files${NC} : Untrusted document viewer (Air-Gapped)"
echo -e "  - ${BOLD}amnesiax-dev${NC}   : Development workspace (Isolated)"
