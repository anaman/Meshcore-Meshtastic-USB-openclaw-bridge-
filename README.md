# MeshCore ↔ Meshtastic USB Bridge — Radio Setup Tool

A small, self-contained setup tool from the first phase of my LoRa mesh
bridge project. It **auto-discovers two USB-connected LoRa radios** — a
MeshCore companion node and a Meshtastic radio — verifies each one with a
real protocol handshake, and wires the discovered ports into a unified
gateway.

The gateway (`mesh_gateway.py`, part of the full project) owns both radios,
relays messages between the MeshCore and Meshtastic networks, and hands
traffic to an AI agent (**OpenClaw**) that delivers it to Telegram or
WhatsApp when you're away from your desk — and routes your replies back
over the radios.

> **This is the original, standalone phase of the project.**
> It has since grown into a full three-network bridge — MeshCore +
> Meshtastic + Reticulum — with a web dashboard, MQTT, peer tracking and
> complete setup docs:
>
> **➡️ Full project: https://github.com/anaman/trimeshtapp**
> (start with `docs/SETUP.md`; the updated version of this tool ships in
> `mesh-relay/` and `skills/mesh-relay-setup`)

## What's inside

| File | Purpose |
|---|---|
| `mesh_relay_setup.py` | Discovery + validation CLI for the two USB radios |
| `README.md` | This file |
| `LICENSE` | CC0-1.0 (public domain dedication) |

## How discovery works

- Candidates: `/dev/serial/by-id/*` first (stable across reboots), then
  `/dev/ttyACM*` and `/dev/ttyUSB*`.
- The MeshCore node is recognized by its USB descriptor ("USB_JTAG…" on the
  reference hardware) and confirmed with the MeshCore companion handshake.
- The Meshtastic radio is recognized by its descriptor
  ("Heltec_Wireless_Tracker" on the reference hardware) and confirmed via
  the `meshtastic` serial interface.
- Probes are read-only and time-bounded; a port that is busy (held by a
  running service) is skipped, never force-opened.

## Usage

Requirements: Linux with systemd, Python 3, and:

```bash
pip install meshcore meshtastic
```

```bash
python3 mesh_relay_setup.py scan      # discover the radios + report (read-only)
python3 mesh_relay_setup.py status    # gateway service + status endpoint health
python3 mesh_relay_setup.py apply     # write the discovered ports into the gateway
```

Notes:

- Stop `mesh-gateway.service` first if you want a clean scan — it holds an
  exclusive lock on both radios; serial ports allow only one owner.
- `apply` patches `MESHCORE_PORT` / `MESHTASTIC_PORT` in the gateway source.
  Set the `MESH_GATEWAY_SRC` environment variable to point at your copy of
  `mesh_gateway.py` (default: `/opt/mesh-bridge/mesh-relay/mesh_gateway.py`).

## The full project

Everything this tool feeds into — the mesh gateway, the Reticulum/RNS leg,
the web dashboard, systemd units and step-by-step docs — is open source:

- **https://github.com/anaman/trimeshtapp** — full stack (GPL-3.0)
- Agent-friendly playbooks in `skills/` (setup, flush/restart safety,
  radio debugging, RNS/LXMF)

## License

This repository is released under **CC0-1.0** (see `LICENSE`) — copy,
modify, and use it freely.
