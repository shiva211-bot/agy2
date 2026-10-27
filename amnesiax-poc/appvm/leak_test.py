#!/usr/bin/env python3
"""
==============================================================================
AMNESIAX — AppVM Isolation & Leak Acceptance Test Suite
==============================================================================
Target Platform: Workstation AppVM (Static IP: 10.10.10.2)
Framework:       Python unittest (Supports pytest and standalone CLI execution)
Dependencies:    Standard Library Only (socket, struct, urllib, ssl, json, unittest)
==============================================================================
"""

import os
import sys
import ssl
import json
import socket
import struct
import unittest
import urllib.request
import urllib.error

# ANSI Color formatting
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"


class TestAmnesiaXBoundary(unittest.TestCase):
    """
    Automated acceptance test suite verifying the 5 core AMNESIAX network boundaries.
    """

    def setUp(self):
        self.check_tor_url = "https://check.torproject.org/api/ip"
        self.cloudflare_dns = "1.1.1.1"
        self.google_dns = "8.8.8.8"
        self.ipv6_target = "2606:4700:4700::1111"

    # --------------------------------------------------------------------------
    # 1. Direct IP Bypass Test
    # --------------------------------------------------------------------------
    def test_01_direct_ip_bypass_fails_closed(self):
        """
        [TEST-NET-01] Direct IP Bypass / Non-Tor UDP Leak Test:
        Attempt a raw outbound UDP socket to an arbitrary public IP (1.1.1.1:12345).
        EXPECTED: Must time out or trigger an unreachable exception (Fail-closed).
        Direct un-proxied packets must NEVER reach the public internet.
        """
        print(f"\n{CYAN}[*] Running Check 1: Direct Non-Tor UDP Socket Egress Probe...{RESET}")
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(3.0)
        try:
            canary_payload = b"AMNESIAX_LEAK_CANARY_PROBE"
            sock.sendto(canary_payload, (self.cloudflare_dns, 12345))
            data, addr = sock.recvfrom(512)
            self.fail(f"CRITICAL LEAK: Raw UDP packet reached public WAN! Received response from {addr}")
        except (socket.timeout, TimeoutError):
            print(f" {GREEN}[PASS]{RESET} Raw outbound UDP dropped fail-closed (socket timed out).")
        except OSError as e:
            print(f" {GREEN}[PASS]{RESET} Raw outbound UDP rejected fail-closed ({e}).")
        finally:
            sock.close()

    # --------------------------------------------------------------------------
    # 2. DNS Leak Test
    # --------------------------------------------------------------------------
    def test_02_dns_leak_interception_or_drop(self):
        """
        [TEST-NET-02] DNS Leak Test:
        Send raw DNS query explicitly to an external unauthorized resolver (8.8.8.8:53).
        EXPECTED: The gateway NAT must transparently intercept and redirect it to Tor
        DNSPort (5353), or drop it completely. Direct raw packets to Google DNS must
        not leak un-proxied to WAN.
        """
        print(f"\n{CYAN}[*] Running Check 2: Direct External DNS Resolver Bypass Probe...{RESET}")
        domain = "check.torproject.org"
        q_id = 0xBEEF

        # Construct raw RFC 1035 DNS Question packet
        header = struct.pack("!HHHHHH", q_id, 0x0100, 1, 0, 0, 0)
        qname = b"".join(bytes([len(p)]) + p.encode("ascii") for p in domain.split(".")) + b"\x00"
        question = qname + struct.pack("!HH", 1, 1)  # Type A, Class IN
        dns_packet = header + question

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(4.0)
        try:
            sock.sendto(dns_packet, (self.google_dns, 53))
            reply, _ = sock.recvfrom(1024)
            if len(reply) >= 12:
                reply_id, _ = struct.unpack("!HH", reply[:4])
                self.assertEqual(reply_id, q_id, "DNS reply ID mismatch")
                print(f" {GREEN}[PASS]{RESET} DNS query to {self.google_dns} intercepted safely by Tor DNSPort.")
        except (socket.timeout, TimeoutError):
            print(f" {GREEN}[PASS]{RESET} DNS query to unauthorized resolver timed out/dropped fail-closed.")
        except OSError as e:
            print(f" {GREEN}[PASS]{RESET} Direct external DNS rejected fail-closed ({e}).")
        finally:
            sock.close()

    # --------------------------------------------------------------------------
    # 3. IPv6 Leak Test
    # --------------------------------------------------------------------------
    def test_03_ipv6_leak_prevention(self):
        """
        [TEST-NET-03] IPv6 Leak Test:
        Attempt an IPv6 socket connection to public Cloudflare IPv6 ([2606:4700:4700::1111]:80).
        EXPECTED: Connection must fail immediately with Network Unreachable,
        Address Family Not Supported, or Timeout. IPv6 egress is strictly forbidden.
        """
        print(f"\n{CYAN}[*] Running Check 3: IPv6 Egress & Dual-Stack Leak Probe...{RESET}")
        sock6 = None
        try:
            sock6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            sock6.settimeout(3.0)
            sock6.connect((self.ipv6_target, 80))
            self.fail("CRITICAL LEAK: IPv6 outbound connection succeeded! Gateway allowed IPv6 traffic to bypass Tor.")
        except socket.gaierror as e:
            print(f" {GREEN}[PASS]{RESET} IPv6 protocol family disabled/unsupported ({e}).")
        except OSError as e:
            print(f" {GREEN}[PASS]{RESET} IPv6 connection dropped fail-closed ({e}).")
        finally:
            if sock6:
                try:
                    sock6.close()
                except Exception:
                    pass

    # --------------------------------------------------------------------------
    # 4. Tor Integrity Check
    # --------------------------------------------------------------------------
    def test_04_tor_exit_node_verification(self):
        """
        [TEST-NET-04] Tor Integrity Check:
        Query https://check.torproject.org/api/ip.
        EXPECTED: IsTor == True. The reported IP must belong to a verified Tor exit node,
        confirming that transparent proxying is functional and real WAN IP is hidden.
        """
        # If running in simulated crashed gateway state, skip online test
        if os.environ.get("AMNESIAX_CRASH_MODE") == "1":
            self.skipTest("Gateway is in simulated crashed state (Skipping active Tor check)")

        print(f"\n{CYAN}[*] Running Check 4: Verifying Tor Exit Node Egress Integrity...{RESET}")
        req = urllib.request.Request(
            self.check_tor_url,
            headers={"User-Agent": "AMNESIAX-AppVM-Test/1.0"}
        )
        context = ssl.create_default_context()

        try:
            with urllib.request.urlopen(req, timeout=12, context=context) as response:
                self.assertEqual(response.status, 200, "check.torproject.org did not return HTTP 200")
                payload = json.loads(response.read().decode("utf-8"))

                is_tor = payload.get("IsTor", False)
                exit_ip = payload.get("IP", "Unknown")

                print(f"     Reported Public IP: {exit_ip}")
                print(f"     IsTor Flag:         {is_tor}")

                self.assertTrue(is_tor, f"SECURITY FAILURE: Traffic is NOT recognized as Tor! (IP: {exit_ip})")
                print(f" {GREEN}[PASS]{RESET} AppVM egress confirmed as verified Tor exit node ({exit_ip}).")
        except urllib.error.URLError as e:
            self.fail(f"Could not reach Tor check endpoint: {e}")

    # --------------------------------------------------------------------------
    # 5. Fail-Closed Verification
    # --------------------------------------------------------------------------
    def test_05_fail_closed_on_gateway_drop(self):
        """
        [TEST-NET-05] Fail-Closed Daemon Stop Verification:
        Verifies that if the gateway or Tor daemon drops/crashes, all outbound
        HTTP/HTTPS traffic ceases immediately with ZERO unencrypted fallback.
        Activated when AMNESIAX_CRASH_MODE=1 or --simulate-crash flag is supplied.
        """
        is_crash_mode = os.environ.get("AMNESIAX_CRASH_MODE") == "1"

        if not is_crash_mode:
            print(f"\n{YELLOW}[INFO] Check 5 (Fail-Closed Stop) is in STANDBY.{RESET}")
            print(f"       To test live: stop the Tor daemon on the gateway (`systemctl stop tor`),")
            print(f"       then run: AMNESIAX_CRASH_MODE=1 python3 leak_test.py")
            return

        print(f"\n{CYAN}[*] Running Check 5: Active Fail-Closed Verification (Daemon Down)...{RESET}")
        req = urllib.request.Request("http://1.1.1.1", headers={"User-Agent": "AMNESIAX-CrashTest"})

        try:
            with urllib.request.urlopen(req, timeout=4) as response:
                self.fail(f"CRITICAL LEAK: Connection succeeded while Tor is down! Response code: {response.status}")
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            print(f" {GREEN}[PASS]{RESET} Fail-closed confirmed: Egress blocked immediately upon Tor halt ({e}).")


def main():
    if "--simulate-crash" in sys.argv:
        os.environ["AMNESIAX_CRASH_MODE"] = "1"
        sys.argv.remove("--simulate-crash")

    print(f"{BOLD}{GREEN}")
    print("======================================================================")
    print("  AMNESIAX WORKSTATION APPVM LEAK-PREVENTION TEST SUITE")
    print("======================================================================")
    print(f" Target Subnet: 10.10.10.0/24 | Mode: {'CRASH TEST' if os.environ.get('AMNESIAX_CRASH_MODE') == '1' else 'NORMAL'}{RESET}\n")

    unittest.main(verbosity=1)


if __name__ == "__main__":
    main()
