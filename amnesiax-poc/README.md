# AMNESIAX Isolation & Leak-Prevention PoC Suite

An automated, defensive engineering proof-of-concept harness verifying the **AMNESIAX** compartmentalized network gateway architecture.

---

## 1. Directory Structure

```text
amnesiax-poc/
├── gateway/
│   └── setup_gateway.sh      # Hardened bash script applying fail-closed iptables/sysctl
├── appvm/
│   └── leak_test.py          # Standalone Python unittest suite executed inside AppVM
├── host/
│   ├── run_simulation.py     # Multi-state orchestrator (Normal, Crash, Leak audit)
│   └── run_simulation.ps1    # Native Windows PowerShell runner
├── production/
│   └── qubes/
│       ├── provision_amnesiax_qubes.sh  # dom0 automated provisioning script
│       └── 30-amnesiax.policy           # Hardened qrexec inter-VM mediation policy
├── docs/
│   └── PRODUCTION_DEPLOYMENT.md         # Hardware, Xen IOMMU & Bare-Metal Hardening Guide
└── README.md                 # Architecture, Virtual Switch Setup & Verification Guide
```

---

## 2. Architecture & Virtual Switch Setup

The test harness uses two lightweight virtual machines on an isolated virtual network:

```
[ Public Internet / Host WAN ]
              │
          [ eth0 ] (NAT or Bridged)
   ┌─────────────────────────────────────┐
   │     AMNESIAX Gateway VM             │
   │  - net.ipv4.ip_forward = 0          │
   │  - IPv6 = Disabled & Dropped        │
   │  - Tor TransPort :9040              │
   │  - Tor DNSPort   :5353              │
   │  - Output: meta skuid debian-tor    │
   └─────────────────────────────────────┘
          [ eth1 ] (10.10.10.1/24)
              │
    ====================== Internal Virtual Switch ======================
    (Hyper-V "Private Switch" / VirtualBox "Internal Network: amnesiax-lan")
              │
          [ eth0 ] (10.10.10.2/24)
   ┌─────────────────────────────────────┐
   │       AMNESIAX AppVM                │
   │  - Gateway: 10.10.10.1              │
   │  - DNS:     10.10.10.1              │
   │  - ZERO direct connection to WAN    │
   └─────────────────────────────────────┘
```

### Virtual Switch Configuration Steps

#### Option A: VirtualBox
1. **Gateway VM:**
   * Adapter 1: `NAT` (uplink internet) $\rightarrow$ becomes `eth0`.
   * Adapter 2: `Internal Network`, Name: `amnesiax-lan` $\rightarrow$ becomes `eth1`.
2. **AppVM:**
   * Adapter 1: `Internal Network`, Name: `amnesiax-lan` $\rightarrow$ becomes `eth0`.
   * **Do NOT add any other adapters.**

#### Option B: Hyper-V (Windows Pro / Enterprise)
1. In Hyper-V Virtual Switch Manager, create a new **Private Virtual Switch** named `AMNESIAX-Internal`.
2. Assign Gateway VM's second network adapter and AppVM's sole network adapter to `AMNESIAX-Internal`.

---

## 3. Step-by-Step Execution Guide

### Step 1: Provision the Gateway VM
On the Linux Gateway VM (Debian 12 / Ubuntu minimal):

```bash
# 1. Install prerequisites
sudo apt-get update && sudo apt-get install -y tor iptables iproute2 dnsutils

# 2. Configure Tor (/etc/tor/torrc)
sudo cat << 'EOF' > /etc/tor/torrc
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 0.0.0.0:9040
DNSPort 0.0.0.0:5353
SafeLogging 1
RunAsDaemon 1
EOF
sudo systemctl restart tor

# 3. Apply the AMNESIAX fail-closed firewall
chmod +x gateway/setup_gateway.sh
sudo ./gateway/setup_gateway.sh eth1 eth0
```

### Step 2: Configure the AppVM
On the AppVM:
1. Assign static IP address:
   ```bash
   sudo ip addr add 10.10.10.2/24 dev eth0
   sudo ip link set eth0 up
   sudo ip route add default via 10.10.10.1
   echo "nameserver 10.10.10.1" | sudo tee /etc/resolv.conf
   ```

### Step 3: Run the Verification Suite
Inside the AppVM, execute:

```bash
python3 appvm/leak_test.py
```

To test the **Fail-Closed Guarantee** (stopping Tor to ensure zero unencrypted fallback):
```bash
# On Gateway VM:
sudo systemctl stop tor

# On AppVM:
python3 appvm/leak_test.py --simulate-crash
```

---

## 4. Pass / Fail Acceptance Criteria

| Check | Test ID | Target Action | Pass Criteria | Fail Criteria |
| :--- | :--- | :--- | :--- | :--- |
| **Direct IP Bypass** | `TEST-NET-01` | Raw UDP probe to `1.1.1.1:12345` | `TimeoutError` or socket reject. Packet dropped fail-closed. | Packet leaves WAN or response returned. |
| **DNS Leak** | `TEST-NET-02` | Raw DNS packet to `8.8.8.8:53` | Intercepted by Tor DNSPort (`5353`) or dropped. | Query reaches Google DNS un-proxied. |
| **IPv6 Leak** | `TEST-NET-03` | Socket to `[2606:4700:4700::1111]:80` | `Network is unreachable` / `Address family disabled`. | Connection established. |
| **Tor Exit Integrity**| `TEST-NET-04` | Query `check.torproject.org/api/ip` | `IsTor == True`. Real WAN IP hidden. | `IsTor == False` (Real IP leaked). |
| **Fail-Closed Stop** | `TEST-NET-05` | HTTP request while Tor daemon halted | Immediate socket failure / timeout. **Zero cleartext fallback.** | Traffic silently forwards to host WAN. |

---

## 5. Host-Level Orchestration (Windows Host)

To run the local orchestrator directly on your development machine:

```powershell
# Using Python:
python host/run_simulation.py

# Or natively with PowerShell:
.\host\run_simulation.ps1
```
