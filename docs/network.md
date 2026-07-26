# Network plan

OPNsense runs bare metal on a mini PC with 4 physical NICs (Intel I226-V, 2.5GbE each). Unlike the VLAN-trunk approach mentioned in `roadmap.md`, this plan dedicates one physical port per network — no VLAN tagging required on OPNsense's side, since there are enough NICs to go around. `roadmap.md` should be updated to match once this is confirmed working.

Diagram: https://claude.ai/code/artifact/6f8b720a-5a27-47ff-9f45-eda38910f8c3

## Topology

```
NSD-G1000TS (ISP router)   10.10.0.1/24, DHCP on (unused — WAN is static)
        |
   WAN -+ OPNsense igc0 — static 10.10.0.10/24, gw 10.10.0.1, DNS 1.1.1.1/8.8.8.8
        |
   LAN -+ OPNsense igc1 — 10.10.10.1/24 (main internal network)
        |     |
        |     +-- 2.5G/10G switch (managed, LACP, fanless)
        |           +-- Proxmox VE — 2× 10GbE (X540-AT2), LACP bonded
        |           +-- Asustor NAS — 2× 2.5GbE, LACP bonded
        |           +-- LAN WiFi AP (UniFi U7 Lite) — main SSID, 2.5GbE uplink
        |           +-- 4× spare 2.5GbE ports
        |
CAMERAS -+ OPNsense igc2 — 10.10.20.1/24
        |     |
        |     +-- NVR uplink port only (static 10.10.20.10). Cameras themselves are
        |         PoE, wired directly into the NVR's own built-in PoE ports — they sit
        |         behind the NVR's internal switch and never touch this network directly.
        |         No switch needed — single device, direct cable.
        |
   IOT -+ OPNsense igc3 — 10.10.30.1/24
              |
              +-- second WiFi router in AP mode, dedicated IoT SSID. No switch needed —
                  single device, direct cable.
```

CAMERAS and IOT deliberately bypass the switch — each has exactly one downstream device, so a direct cable keeps that traffic physically isolated, not just firewalled off. Only LAN (which has multiple devices) needs the switch.

## Interface assignment

| Port | Role    | Address       | Notes |
|------|---------|---------------|-------|
| igc0 | WAN     | 10.10.0.10/24 | static, gateway 10.10.0.1 (NSD-G1000TS). Not using NSD's DHCP. |
| igc1 | LAN     | 10.10.10.1/24 | main internal network, own DHCP scope, uplinks to the switch |
| igc2 | CAMERAS | 10.10.20.1/24 | single device only — NVR uplink, static IP recommended |
| igc3 | IOT     | 10.10.30.1/24 | own DHCP scope, WiFi AP uplink |

Decided: WAN=igc0, LAN=igc1 (swapped from the console's initial default assignment). Not yet applied on the actual hardware — needs console option **1) Assign interfaces** re-run (~30s, no reinstall needed).

## Switch

One switch handles all LAN-side (switched) traffic — not "an additional" switch on top of anything, this is what lets Proxmox, the NAS, and the WiFi AP all actually use their existing multi-port hardware.

**Decided: XikeStor SKS3200-8E2X** — 8× 2.5GbE RJ45 + 2× 10G SFP+, simple L2 managed (LACP/VLAN/QoS), fanless.

The 10G ports are SFP+-only (not RJ45/combo), so connecting Proxmox's copper X540-AT2 ports requires a **10GBASE-T SFP+ transceiver module** per port used:
- Confirmed compatible via user reports testing 10GBase-T SFP+ modules (e.g. THGtek) on this exact switch.
- Pick a **low-power (~1.8W-class) module** specifically — generic ones run 4-5W and get hot with no fan to dissipate it, risking throttling/reliability issues on a passively-cooled switch.
- One transceiver needed for a single 10G link to PVE; two if bonding both of PVE's 10G ports via LACP (~$60-100 total on top of the switch).

Other spec points satisfied: LACP (802.3ad) for the NAS's 2×2.5G bond and PVE's 2×10G bond; jumbo frame support worth confirming in firmware; PoE not needed (NVR/WiFi routers have their own power).

**Runner-up considered**: QNAP QSW-M2108-2C — 2× 10GbE *combo* ports (RJ45 or SFP+ per port) would've avoided the transceiver purchase entirely, but at a higher price point than the XikeStor + transceivers. ([servethehome.com buyer's guide](https://www.servethehome.com/the-ultimate-cheap-2-5gbe-switch-mega-round-up-buyers-guide-qnap-netgear-hasivo-mokerlink-trendnet-zyxel-tp-link/))

## Proxmox VE host NICs

- `02:00.0` / `02:00.1` — Intel X540-AT2, dual 10GbE (driver `ixgbe`). Currently only one port active (bridged as `vmbr0`, carrying management + VM traffic); plan is to bond both into the switch via LACP for throughput/redundancy.
- `05:00.0` / `06:00.0` — Intel I210, dual 1GbE (driver `igb`). Currently unused; spare for future cluster/corosync or dedicated management link if needed.

## Firewall isolation rules

- **CAMERAS**: no pass rules — default-blocks CAMERAS → WAN and CAMERAS → LAN/IOT. NVR/cameras can't reach the internet or other internal networks on their own initiative.
- **LAN → CAMERAS**: explicit allow rule so LAN devices can view the NVR. Return traffic auto-permitted by the stateful firewall.
- **IOT**: isolate from LAN by default; WAN access TBD per device (some IoT devices need internet, some don't — decide case by case once devices are known).

## WiFi

No VLAN-capable AP needed — since each network already has its own dedicated physical port, WiFi segmentation is done with **two separate routers/APs**, one per network, rather than one AP with multiple VLAN-tagged SSIDs:

- **LAN**: **Ubiquiti UniFi U7 Lite**, 2.5GbE uplink, PoE-powered (injector included) — uplinked through the switch. House is small (<1500 sqft), 2 floors, no inter-floor Ethernet wiring; a single centrally-mounted AP (e.g. ceiling near a stairwell) is sufficient, no mesh needed.
- **IOT**: a second WiFi router in Access Point mode, uplinked directly to `igc3` (no switch). SSID dedicated to IoT devices.
- Cameras don't need WiFi (PoE/wired to the NVR).

## DNS naming

Local DNS is handled by Technitium (`roadmap.md` step 4, a dedicated VM — not run in k3s, since DNS is foundational infrastructure that shouldn't depend on the cluster that will eventually depend on it). Using the owned domain `ikeda.codes`, split into one subdomain per exposure category so nothing needs to stay in sync across two DNS systems (no split-horizon):

| Category | Suffix | Served by | Example |
|---|---|---|---|
| Internal-only (never leaves the LAN) | `*.local.ikeda.codes` | Technitium only — private zone, never published to Cloudflare/public DNS | `pve.local.ikeda.codes` |
| Self-hosted, tunneled out (runs at home, reachable from the internet via a future Cloudflare Tunnel) | `*.ikeda.codes` (bare) or `*.home.ikeda.codes` | Real public DNS at Cloudflare | `jellyfin.ikeda.codes` |
| Actually cloud-hosted (rented infra elsewhere, unrelated to the homelab) | `*.cloud.ikeda.codes` | Real public DNS, wherever that's hosted | `api.cloud.ikeda.codes` |

Since `local.ikeda.codes` is a subdomain of a domain actually owned, internal-only services can still get valid publicly-trusted TLS certs via ACME DNS-01 challenge against Cloudflare's API (DNS-01 doesn't require the name to resolve publicly) — real HTTPS without browser warnings, unlike the classic `.lan`/`.home` fake-TLD approach.

Technitium gets a static IP (`10.10.10.53/24`, not DHCP or a reservation) — foundational infrastructure everything else depends on shouldn't itself depend on DHCP working at boot, same reasoning as OPNsense's own interfaces all being static. `.53` is just a mnemonic (the DNS port), not a technical requirement.

Technitium only needs to be reachable from LAN — CAMERAS has no pass rules at all (doesn't need DNS) and IOT is isolated from LAN by default, so neither can reach `10.10.10.53` directly, nor should they need to. Each interface's DHCP-provided DNS server stays OPNsense's own IP on that interface (`10.10.20.1`, `10.10.30.1`); OPNsense's Unbound resolver forwards queries for the `local.ikeda.codes` zone specifically to Technitium, while resolving everything else itself. Clients on every network only ever need to reach their own gateway for DNS — no new cross-VLAN firewall rule required.

## WireGuard remote access

**Blocked: no inbound path to OPNsense's WAN.** The ISP router (`NSD-G1000TS`) runs in **MAP-E mode** (IPv4-over-IPv6 with carrier-grade NAT) — its own port-mapping feature refuses to run at all in this mode ("This function cannot be used while operating in MAP-E mode"), so there's no way to forward an inbound port to OPNsense's WAN, and OPNsense's WAN interface has no IPv6 configured either (checked: `IPv6 Configuration Type: None`, and the interfaces overview shows no IPv6 address). A WireGuard server listening directly on OPNsense's WAN, or on a LAN VM behind a port forward, simply isn't reachable from outside.

**Revised design: relay through a small external VPS** with a real public IP, in a Tokyo/Osaka region for latency (candidates: Vultr, Linode/Akamai, Oracle Cloud's free tier, or a Japan-domestic provider like Sakura/ConoHa) — not yet chosen/provisioned:

- The VPS becomes the WireGuard hub: it has a real public IP, so it can accept inbound UDP `51820` directly (open that port in the provider's firewall/security group — the one inbound-port step that actually works here).
- Phone/laptop clients connect to the VPS as normal WireGuard peers.
- A VM on LAN (static IP, same role this design always planned to have) becomes a WireGuard **client** of the VPS instead of a server — it dials *out* (which works fine even behind MAP-E's CGNAT) and keeps the connection alive with a persistent keepalive so the NAT mapping doesn't expire. It still masquerades tunnel traffic behind its own LAN address to reach the rest of the LAN, same trick as originally planned.
- Traffic path becomes phone/laptop → VPS → home LAN VM → LAN, instead of phone/laptop → home LAN VM → LAN directly.
- This removes the OPNsense NAT port forward and the ISP router bridge/port-forward steps entirely — the VPS's public IP replaces both.

Tradeoff accepted knowingly: this reintroduces a piece of infrastructure outside the home network (the VPS), which the original "self-hosted, no third-party coordination service" reasoning in `roadmap.md` was written to avoid — weighed against Cloudflare Tunnel (simpler, but relays *all* traffic through Cloudflare permanently and reverses that reasoning further) and NetBird (similar hosted-relay tradeoffs). A self-hosted relay VPS keeps the trust model closest to the original plan: only you hold the WireGuard keys, the VPS just forwards encrypted packets.

Not yet built - see `roadmap.md` step 4.

## Open items

- [x] Apply WAN/LAN swap on console (option 1: Assign interfaces) — igc0=WAN, igc1=LAN
- [x] Configure WAN static IP (10.10.0.10/24, gw 10.10.0.1, DNS 1.1.1.1)
- [x] Set LAN to 10.10.10.1/24, DHCP scope 10.10.10.100-10.10.10.200
- [x] Assign igc2 (CAMERAS), set addressing (10.10.20.1/24)
- [x] Assign igc3 (IOT), set addressing (10.10.30.1/24), DHCP scope (10.10.30.100-10.10.30.200)
- [x] Configure firewall isolation rules (see above) — LAN→CAMERAS allow rule live, managed via `iac/ansible/roles/opnsense_firewall`; CAMERAS/IOT isolation needs no explicit rules (default deny)
- [ ] Buy XikeStor SKS3200-8E2X switch
- [ ] Buy 10GBASE-T SFP+ transceiver(s), low-power (~1.8W) class — 1 for a single PVE link, 2 for the full LACP bond
- [ ] Set up LACP bonds: PVE (2×10G) and NAS (2×2.5G) into the switch
- [ ] Buy/set up UniFi U7 Lite for LAN WiFi, mount centrally
- [ ] Get/configure second WiFi router in AP mode for IoT SSID
- [x] Give the NVR a static IP (10.10.20.10) and gateway (10.10.20.1) on the CAMERAS network
- [x] Confirmed OPNsense's WAN has no inbound path: ISP router is in MAP-E mode (port mapping disabled), WAN has no IPv6 configured
- [ ] Choose and provision the relay VPS (Tokyo/Osaka region for latency)
- [ ] Open inbound UDP/51820 in the VPS provider's firewall/security group
