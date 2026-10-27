#!/usr/bin/env bash
# ==============================================================================
# AMNESIAX — Linux Gateway VM Fail-Closed Isolation & Routing Script
# Target Interface: eth1 (Internal: 10.10.10.0/24) -> eth0 (External WAN)
# Defensive Principle: Absolute Fail-Closed (Zero Direct Routing, Complete IPv6 Drop)
# ==============================================================================
set -euo pipefail

# --- Configuration ---
LAN_IF="${1:-eth1}"
WAN_IF="${2:-eth0}"
INTERNAL_SUBNET="10.10.10.0/24"
TOR_TRANS_PORT="9040"
TOR_DNS_PORT="5353"
TOR_SOCKS_PORT="9050"

# --- Privileges Check ---
if [[ $EUID -ne 0 ]]; then
    echo "[!] Error: Must run as root (sudo)." >&2
    exit 1
fi

# Detect Tor Service User & UID
TOR_USER=""
for candidate in debian-tor tor _tor; do
    if id "$candidate" &>/dev/null; then
        TOR_USER="$candidate"
        break
    fi
done

if [[ -z "$TOR_USER" ]]; then
    echo "[!] Error: No Tor daemon user found. Please install tor (e.g., apt install tor)." >&2
    exit 1
fi
TOR_UID=$(id -u "$TOR_USER")
echo "[*] Detected Tor service account: ${TOR_USER} (UID: ${TOR_UID})"

# ==============================================================================
# 1. KERNEL HARDENING (sysctl)
# ==============================================================================
echo "[*] Configuring kernel: Disabling IP forward & blackholing IPv6..."

# CRITICAL: Forwarding must be 0 so no packet ever transits between NICs at layer 3
sysctl -w net.ipv4.ip_forward=0 >/dev/null

# Disable IPv6 stack across all interfaces
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null

# Anti-Spoofing & Broadcast Protections
sysctl -w net.ipv4.conf.all.rp_filter=1 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=1 >/dev/null
sysctl -w net.ipv4.conf.all.accept_redirects=0 >/dev/null
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1 >/dev/null

# ==============================================================================
# 2. COMPLETE IPv6 FLUSH & DEFAULT DROP
# ==============================================================================
echo "[*] Locking down IPv6 tables..."
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -X
    ip6tables -t raw -F 2>/dev/null || true
    ip6tables -t mangle -F 2>/dev/null || true
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
fi

# ==============================================================================
# 3. FIREWALL RULES (iptables / nftables compatible)
# ==============================================================================
echo "[*] Applying fail-closed IPv4 iptables ruleset..."

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# --- DEFAULT POLICIES: DROP EVERYTHING ---
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# --- LOOPBACK TRAFFIC ---
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# --- STATEFUL ESTABLISHED/RELATED CONNECTIONS ---
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Drop invalid state packets immediately
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A OUTPUT -m conntrack --ctstate INVALID -j DROP

# ==============================================================================
# 4. NAT PREROUTING: TRANSPARENT INTERCEPTION TO TOR
# ==============================================================================
# Only process traffic arriving from internal LAN from authorized subnet
# Redirect DNS (UDP & TCP 53) to Tor DNSPort 5353
iptables -t nat -A PREROUTING -i "${LAN_IF}" -s "${INTERNAL_SUBNET}" -p udp --dport 53 -j REDIRECT --to-ports "${TOR_DNS_PORT}"
iptables -t nat -A PREROUTING -i "${LAN_IF}" -s "${INTERNAL_SUBNET}" -p tcp --dport 53 -j REDIRECT --to-ports "${TOR_DNS_PORT}"

# Redirect all TCP (HTTP, HTTPS, SSH, etc.) to Tor TransPort 9040
iptables -t nat -A PREROUTING -i "${LAN_IF}" -s "${INTERNAL_SUBNET}" -p tcp --syn -j REDIRECT --to-ports "${TOR_TRANS_PORT}"

# Drop any non-DNS UDP packets (blocks raw UDP, QUIC, WebRTC bypass)
iptables -t nat -A PREROUTING -i "${LAN_IF}" -s "${INTERNAL_SUBNET}" -p udp ! --dport 53 -j DROP

# ==============================================================================
# 5. FILTER INPUT: PERMIT ONLY AUTHORIZED REDIRECTED PORTS
# ==============================================================================
# Allow internal subnet traffic to connect only to Tor local listener ports
iptables -A INPUT -i "${LAN_IF}" -s "${INTERNAL_SUBNET}" -p udp --dport "${TOR_DNS_PORT}" -j ACCEPT
iptables -A INPUT -i "${LAN_IF}" -s "${INTERNAL_SUBNET}" -p tcp -m multiport --dports "${TOR_DNS_PORT},${TOR_TRANS_PORT},${TOR_SOCKS_PORT}" -j ACCEPT

# Inbound ping/ICMP echo from LAN (limited rate for reachability verification)
iptables -A INPUT -i "${LAN_IF}" -s "${INTERNAL_SUBNET}" -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT

# Reject any other incoming packet on internal interface with ICMP port unreachable
iptables -A INPUT -i "${LAN_IF}" -j REJECT --reject-with icmp-port-unreachable

# ==============================================================================
# 6. FILTER FORWARD: STRICT PERMANENT DROP
# ==============================================================================
# ABSOLUTE FAIL-CLOSED: No packet ever forwards between interfaces.
iptables -A FORWARD -j DROP

# ==============================================================================
# 7. FILTER OUTPUT: FAIL-CLOSED EGRESS (TOR USER ONLY)
# ==============================================================================
# Only packets generated by the Tor daemon (matched by UID) may exit via WAN
iptables -A OUTPUT -o "${WAN_IF}" -m owner --uid-owner "${TOR_UID}" -p tcp -j ACCEPT

# If Tor crashes, no process can match the rule above. Output remains entirely DROPPED.
# Explicit drop on everything else
iptables -A OUTPUT -j DROP

# ==============================================================================
# 8. STATUS CONFIRMATION
# ==============================================================================
echo "======================================================================"
echo "  AMNESIAX FAIL-CLOSED GATEWAY ISOLATION: ACTIVE"
echo "======================================================================"
echo " - IPv4 Forwarding: $(sysctl -n net.ipv4.ip_forward) (FAIL-CLOSED: 0)"
echo " - IPv6 Disabled:   $(sysctl -n net.ipv6.conf.all.disable_ipv6) (LOCKED: 1)"
echo " - Internal Subnet: ${INTERNAL_SUBNET} on ${LAN_IF}"
echo " - Redirection:     TCP -> Tor :${TOR_TRANS_PORT} | DNS -> Tor :${TOR_DNS_PORT}"
echo " - Outbound Egress: Exclusively locked to UID ${TOR_UID} (${TOR_USER})"
echo "======================================================================"
