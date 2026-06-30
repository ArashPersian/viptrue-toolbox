# Tunnel Scanner Architecture

The Auto Tunnel Expert scanner is a registry-driven framework for choosing a
tunnel, not a single hardcoded WireGuard or Xray setup path.

## Goals

- Probe between two servers without collecting SSH credentials.
- Rank engine families by local buildability, suitability, and risk labels.
- Keep WireGuard and Xray as destination examples, not scanner requirements.
- Let the user choose a buildable engine after scan output.
- Build only proven Hysteria2 OBFS UDP generic forward in this PR.
- Test forwarding with generic TCP/UDP probes, not application-specific auth.

## Pairing Mode

Pairing Mode is implemented first.

1. Run the scanner on the Foreign / Exit server.
2. The Foreign side prints and saves a `VIPTRUE_SCAN_BUNDLE`.
3. Run the scanner on the Iran / Entry server.
4. Paste the scan bundle, or enter the same values manually.
5. Review the scan summary card, compact grouped ranking, and exact next
   action.
6. Build only the selected implemented engine.

SSH Auto Mode is intentionally a placeholder. This PR does not ask for SSH
hosts, users, keys, passwords, or credentials.

## Scanner Inputs

The scanner asks for:

- Server role: Iran / Entry or Foreign / Exit
- Traffic type: UDP, TCP, or both
- Iran public IP/domain
- Iran listen/input port
- Foreign public IP/domain
- Destination IP from the foreign server point of view, default `127.0.0.1`
- Destination port on the foreign server
- Optional profile name

The destination service may be configured later. If the destination port is not
listening, the scanner shows that once in the summary card and does not fail
unless a future explicit live test requires a listener.

## Scan Output UX

After prompts, the scanner prints a summary card before any table:

- route scanned,
- UDP/TCP destination listener status,
- recommended engine,
- buildability,
- Iran fit,
- speed,
- detection-risk label,
- score,
- why that engine was selected,
- next exact action.

The default view does not print the full 49-engine registry. It shows compact
groups:

- `BUILDABLE NOW`
- `MANUAL / IMPLEMENTED PRESETS`
- `PRIORITY NEXT`
- `EMERGENCY / HARD MODE` as a short summary
- `PLANNED / EXTERNAL REQUIRED` as a short summary
- `APPLICATION-SPECIFIC PRESETS` as a short summary

Use the scan options menu to print compact ranking, full 49-engine ranking,
buildable-only engines, priority-next engines, emergency/hard-mode engines, or
forwarding proof commands.

Readiness labels:

- `YES`: buildable now
- `MAN`: manual preset
- `NEXT`: priority-next
- `PLAN`: planned/scaffolded
- `EXT`: external required
- `EMRG`: emergency-only

Emergency engines are never the default recommendation while normal engines are
available. WireGuard and Xray presets are treated as application-specific and
are hidden from the generic default ranking.

## Scoring Model

The scanner uses a standardized score model and prints compact grouped tables:

- Dependency available: `+10`
- Local port available: `+10`
- Service can start: `+20` after a build/test path can verify it
- Local listener active: `+15` after a build/test path can verify it
- Iran-to-Foreign control connection succeeds: `+25` after live test
- UDP/TCP probe reaches destination: `+30` after live test
- Low latency: `+10` after live test
- Stable logs/no fatal timeout: `+10` after live test
- Proven field profile: `+10`

Emergency-only methods are capped below normal methods unless normal methods
fail. A fatal timeout should fail that candidate. UDP port `443` is forbidden
for Hysteria2 UDP candidates.

Current scanner output is a pre-build ranking using local dependencies, local
port availability, destination-listener hints, and registry metadata. Build and
test steps add stronger evidence.

## Generic Proof Commands

Proof commands are not printed by default. Select scan option `7` to print
them.

UDP forwarding proof:

```sh
On Foreign:
  timeout 40 tcpdump -ni any udp port <dest_port>

On Iran:
  echo viptrue-test >/dev/udp/127.0.0.1/<iran_listen_port>
```

TCP forwarding proof when a destination listener exists:

```sh
On Iran:
  nc -vz 127.0.0.1 <iran_listen_port>
  printf 'viptrue-test\n' | nc -w2 127.0.0.1 <iran_listen_port>
```

If no TCP destination listener exists, start a temporary listener on Foreign:

```sh
nc -lk -p <dest_port>
```

These commands prove forwarding only. They do not prove WireGuard, Xray, or
application-level authentication.

## Generic Hysteria2 Build

`hysteria2_obfs_udp` builds use a v2 runtime bundle:

```text
VIPTRUE_TUNNEL_BUNDLE=v2;engine=hysteria2_obfs_udp;type=generic-udp-forward;...
```

The bundle contains operational secrets and must not be committed or shared
publicly. The builder writes managed configs under
`/etc/viptrue-hy2-wg-forward/auto/`, backs up files before replacement, and does
not stop unrelated tunnels. Same-profile or same-port conflicts require explicit
confirmation.

Scan bundles do not contain auth/OBFS secrets. Tunnel bundles do contain
operational secrets. Both are printed as one copy-friendly line and saved to a
local bundle file with a `cat <path>` copy command.
