# Tunnel Engine Registry

The Tunnel Manager now uses an engine registry as the product map for tunnel
selection. The registry is implemented in `modules/utility/04-tunnel-manager.sh`
so shell menus can scan, rank, and explain engines without requiring external
data files on the server.

## Engine Families

- UDP / QUIC: Hysteria2 OBFS UDP is the implemented and field-proven baseline.
  TUIC, MASQUE, AmneziaWG, and UDP wrappers are registered for later work.
- TCP / web-like: REALITY, XHTTP, gRPC, WebTunnel, NaiveProxy, OBFS4,
  ShadowTLS, and generic TCP forward are scaffolded or planned.
- Reverse / Iran-specific: WaterWall Reverse TLS, reverse WS/gRPC, Xray reverse,
  reverse SSH, Chisel, GOST, and FRP/Rathole are registered as next-stage
  reverse candidates.
- CDN / clean-IP / operator-specific: Cloudflare, ArvanCloud, and IPv6 bypass
  entries are marked ISP-specific where appropriate.
- DNS / emergency hard-mode: DNSTT, Slipstream DNS, Iodine, dns2tcp, DoH, DoT,
  DoQ, DNS scanner, and segmentation probes are emergency or research paths.
- Raw IP / kernel tunnel: GRE is available through the manual lab; GRETAP, IPIP,
  SIT, VXLAN, and WireGuard site-to-site are tracked as raw/kernel candidates.
- Spoof / desync / anti-DPI helpers: zapret-style desync, udp2raw-style wrapper,
  fake packet TTL/split/fragment, and Xray fragment/noise are scaffolded or
  research-only helpers.

## Registry Fields

Each row carries:

- `engine_id`
- `display_name`
- `family`
- `traffic`
- `direction`
- `use_case`
- `implementation_status`
- `iran_suitability`
- `speed_profile`
- `detection_risk_profile`
- `dependencies`
- `requires_domain`
- `requires_dns_zone`
- `requires_cloudflare`
- `requires_root`
- `supports_multi_foreign`
- `supports_generic_tcp`
- `supports_generic_udp`
- `probe_method`
- `build_method`
- `test_method`
- `notes`

## Detection-Risk Labels

Detection-risk labels are metadata heuristics, not guarantees.

- NaiveProxy, WebTunnel, REALITY, and ReverseTLS are labeled lower.
- Hysteria2 OBFS is labeled medium/lower when UDP works.
- GRE and other raw IP options are labeled higher.
- DNS tunnels are emergency-only, noisy, and low-speed.
- Cloudflare clean-IP style paths are ISP-specific and brittle.
- UDP/QUIC methods must be probed because UDP or QUIC may be filtered.

## Buildability Status

`hysteria2_obfs_udp` is the only generic Auto Tunnel Expert builder implemented
in this PR. It creates Hysteria2 OBFS UDP generic forwards with self-signed TLS,
`sniGuard: disable`, salamander OBFS, Bing masquerade, and non-443 UDP.

Other engines are intentionally registry/scanner entries for this PR. Their menu
response is explicit: registered but not implemented yet; use Manual Tunnel Lab
or wait for the next engine PR.

## Scan Groups

The scan UX groups registry rows instead of printing one long default table:

- `BUILDABLE NOW`: Auto Tunnel Expert can build this engine now.
- `MANUAL / IMPLEMENTED PRESETS`: implemented elsewhere in the toolbox or
  available through Manual Tunnel Lab.
- `PRIORITY NEXT`: next implementation candidates, currently scaffolded.
- `PLANNED / EXTERNAL REQUIRED`: planned, research, or dependency-heavy engines.
- `EMERGENCY / HARD MODE`: DNS and other hard-mode paths, not daily defaults.
- `APPLICATION-SPECIFIC PRESETS`: WireGuard/Xray/application-shaped entries.

Compact readiness labels are:

- `YES`: buildable now
- `MAN`: manual preset
- `NEXT`: priority-next
- `PLAN`: planned/scaffolded
- `EXT`: external required
- `EMRG`: emergency-only

WireGuard and Xray entries remain visible in the full ranking, but generic scans
do not rank them above generic forwarding engines. Emergency engines are grouped
separately and are not default recommendations while normal methods are
available.

## Next Implementation Order

1. Hysteria2 generic UDP forward polish
2. WaterWall Reverse TLS
3. Reverse WS/gRPC
4. Generic TCP forward via tested engine
5. Cloudflare/CDN scan helpers
6. DNS hard-mode research/scaffold
7. spoof/desync helper research
