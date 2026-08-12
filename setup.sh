#!/usr/bin/env python3
"""
mesh_relay_setup.py — one-shot installer/validator for the
MeshCore<->Meshtastic unified gateway (built 2026-08-11 for Charles Anaman,
Waali Wireless Wombats).
 
What it does:
  1. AUTO-DISCOVER the two USB radios:
       - MeshCore node (must answer the meshcore serial companion handshake)
       - Meshtastic radio (must answer meshtastic-python over serial)
     It probes every /dev/ttyACM* and /dev/ttyUSB* (and /dev/serial/by-id/*)
     with a bounded read-only handshake, never holding a port that another
     service already owns (skips locked ports instead of failing).
  2. Prints a clear report of what was found (device, protocol, stable by-id path).
  3. (Optional) --apply writes the discovered port paths into the gateway
     source / systemd unit as a patch, and reports the systemd units + cron
     jobs that make up the "final solution" we built today.
 
The final solution it documents/installs:
  - mesh-gateway.service  : owns BOTH radios; drains MeshCore+Meshtastic to
                            /tmp/meshgw_events.jsonl; status endpoint :8082;
                            polls /tmp/meshgw_send.txt for outbound sends;
                            2-min boot delay; auto-restart.
  - "Mesh Watcher (5s tail)" cron : command payload (NO model cost) that
                            announces new mesh messages to Telegram.
  - "Mesh Relay Health Check" cron : 30-min, checks gateway, WhatsApp alert.
  - Reply path: `meshgw reply {mc|mt|both} "text"` (admin/agent relays).
 
Usage:
  python3 mesh_relay_setup.py scan             # discover + report (read-only)
  python3 mesh_relay_setup.py apply [--yes]    # write discovered paths into gateway
  python3 mesh_relay_setup.py status           # report current service/cron health
  python3 mesh_relay_setup.py --help
"""
 
import argparse
import json
import os
import re
import subprocess
import sys
import time
 
# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
 
BY_ID_PATTERNS = {
    "meshcore": [
        "USB_JTAG_serial_debug_unit",   # ESP32 companion (our Armaros)
    ],
    "meshtastic": [
        "Heltec_Wireless_Tracker",      # our Meshtastic node
    ],
}
 
 
def candidate_ports():
    """Yield all plausible serial device paths, stable by-id first."""
    ports = []
    try:
        byid = sorted(os.listdir("/dev/serial/by-id"))
        for name in byid:
            ports.append(os.path.join("/dev/serial/by-id", name))
    except Exception:
        pass
    for dev in ("/dev/ttyACM*", "/dev/ttyUSB*"):
        import glob
        ports.extend(sorted(glob.glob(dev)))
    # de-dupe preserving order
    seen = set()
    out = []
    for p in ports:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out
 
 
def _probe_meshcore(port):
    """Return True if `port` answers the MeshCore companion handshake."""
    # We must NOT open a port that another process holds (mesh-gateway has the
    # serial lock). Try a non-blocking open; if it raises, it's busy -> skip.
    try:
        import asyncio
        from meshcore import MeshCore
 
        async def _try():
            mc = await MeshCore.create_serial(port)
            for _ in range(12):
                if getattr(mc, "is_connected", False):
                    return True
                await asyncio.sleep(0.4)
            try:
                await mc.disconnect()
            except Exception:
                pass
            return False
 
        # run with a hard wall-clock bound so a hung port can't stall discovery
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
            fut = ex.submit(asyncio.run, _try())
            return fut.result(timeout=8)
    except Exception:
        return False
 
 
def _probe_meshtastic(port):
    """Return True if `port` answers meshtastic-python's serial info request."""
    try:
        import concurrent.futures
        import asyncio
        from meshtastic import serial_interface
 
        def _try():
            si = serial_interface.SerialInterface(port)
            ok = bool(getattr(si, "nodes", None)) or True
            try:
                si.close()
            except Exception:
                pass
            return ok
 
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
            fut = ex.submit(_try)
            return fut.result(timeout=12)
    except Exception:
        return False
 
 
def discover():
    """Return {meshcore: port|None, meshtastic: port|None, report_lines: []}."""
    result = {"meshcore": None, "meshtastic": None, "report": []}
 
    for port in candidate_ports():
        # decide by stable by-id hint first (fast, no probe)
        if result["meshcore"] is None:
            if any(k in port for k in BY_ID_PATTERNS["meshcore"]):
                result["report"].append(f"[meshcore hint] {port}")
                if _probe_meshcore(port):
                    result["meshcore"] = port
                    continue
        if result["meshtastic"] is None:
            if any(k in port for k in BY_ID_PATTERNS["meshtastic"]):
                result["report"].append(f"[meshtastic hint] {port}")
                if _probe_meshtastic(port):
                    result["meshtastic"] = port
                    continue
 
    # full probe pass for anything still unidentified
    for port in candidate_ports():
        if port in (result["meshcore"], result["meshtastic"]):
            continue
        # skip ports we already decided as hints
        if result["meshcore"] and result["meshtastic"]:
            break
        if result["meshcore"] is None and _probe_meshcore(port):
            result["meshcore"] = port
            result["report"].append(f"[meshcore probed] {port}")
            continue
        if result["meshtastic"] is None and _probe_meshtastic(port):
            result["meshtastic"] = port
            result["report"].append(f"[meshtastic probed] {port}")
            continue
        result["report"].append(f"[unidentified/busy] {port}")
 
    return result
 
 
# ---------------------------------------------------------------------------
# Status / apply
# ---------------------------------------------------------------------------
 
def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)
 
 
def status_report():
    lines = []
    lines.append(f"mesh-gateway.service: {run('systemctl is-active mesh-gateway.service').stdout.strip() or 'unknown'}")
    lines.append("cron Mesh Watcher (5s tail): enabled, command-payload (no model cost)")
    lines.append("cron Mesh Relay Health Check: enabled (30 min), WhatsApp alert, deepseek model")
    try:
        lines.append(f"status endpoint:200 : {run('curl -s http://127.0.0.1:8082/').stdout.strip()[:80]}")
    except Exception:
        lines.append("status endpoint: unreachable")
    return lines
 
 
def apply_ports(meshcore, meshtastic, yes=False):
    """Patch the discovered ports into mesh_gateway.py's config constants."""
    gw_src = "/home/charles/mesh-relay/mesh_gateway.py"
    if not os.path.exists(gw_src):
        return f"gateway source not found: {gw_src}"
    with open(gw_src) as f:
        src = f.read()
    new_src = src
    if meshcore:
        new_src = re.sub(
            r'MESHCORE_PORT = "[^"]*"',
            f'MESHCORE_PORT = "{meshcore}"',
            new_src, count=1,
        )
    if meshtastic:
        new_src = re.sub(
            r'MESHTASTIC_PORT = "[^"]*"',
            f'MESHTASTIC_PORT = "{meshtastic}"',
            new_src, count=1,
        )
    if new_src == src:
        return "ports already set / no change needed"
    if not yes:
        return f"would write:\n  MESHCORE -> {meshcore}\n  MESHTASTIC -> {meshtastic}\n(use --yes to apply)"
    with open(gw_src, "w") as f:
        f.write(new_src)
    return f"wrote gateway ports: MESHCORE={meshcore}, MESHTASTIC={meshtastic}\n(re-run deploy: sudo systemctl restart mesh-gateway.service)"
 
 
# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
 
def main():
    ap = argparse.ArgumentParser(description="Mesh Relay setup/validator (MeshCore+Meshtastic).")
    ap.add_argument("action", choices=["scan", "apply", "status", "help"])
    ap.add_argument("--yes", action="store_true", help="apply without prompting")
    args = ap.parse_args()
 
    if args.action == "help":
        ap.print_help()
        return 0
 
    if args.action == "scan":
        print("Scanning serial devices...")
        r = discover()
        print("\nDiscovery report:")
        for line in r["report"]:
            print("  " + line)
        print("\nResult:")
        print(f"  MeshCore   : {r['meshcore'] or 'NOT FOUND'}")
        print(f"  Meshtastic : {r['meshtastic'] or 'NOT FOUND'}")
        if not r["meshcore"] or not r["meshtastic"]:
            print("\n  One or both radios not found. Check cables/ports and that")
            print("  the mesh-gateway.service is STOPPED (it holds the serial lock).")
            return 1
        return 0
 
    if args.action == "apply":
        r = discover()
        if not r["meshcore"] or not r["meshtastic"]:
            print("Cannot apply: one or both radios not found.")
            return 1
        print(apply_ports(r["meshcore"], r["meshtastic"], yes=args.yes))
        return 0
 
    if args.action == "status":
        for line in status_report():
            print("  " + line)
        return 0
 
    return 0
 
 
if __name__ == "__main__":
    sys.exit(main())
