# Project State

Version: 0.4.1
Branch: fasttrack/tunnel-engine-registry-scanner
Base commit: 853921a Merge pull request #10 from ArashPersian/fasttrack/auto-tunnel-wizard
Commit: 77120c9 Add tunnel engine registry scanner
PR status: not opened yet
Release status: no release or tag planned for this batch

## Scope

- Add Auto Tunnel Expert as the strategic Tunnel Manager product path.
- Add a shell-native engine registry with scanner-oriented metadata.
- Add adaptive Pairing Mode scanner prompts and ranked engine output.
- Build only the proven Hysteria2 OBFS UDP generic forward in this PR.
- Keep WireGuard and Xray as destination examples, not generic scanner
  requirements.
- Preserve existing manual Hysteria2, WireGuard, GRE, legacy, and synthetic
  tooling under Manual Tunnel Lab and the existing management menus.

## Checks

Local checks:

- Passed: `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/04-tunnel-manager.sh`
- Passed: menu smoke to `Tunnel Manager -> Auto Tunnel Expert`
- Passed: menu smoke to `Auto Tunnel Expert -> Show Engine Registry`
- Passed: menu smoke to `Auto Tunnel Expert -> Scan Best Tunnel Between Two Servers`
- Passed: menu smoke to `Auto Tunnel Expert -> Build Selected Tunnel From Scan Result`
- Passed: menu smoke that Manual Tunnel Lab is still reachable
- Passed: registry smoke with 49 engines and required families/statuses
- Passed: no-WireGuard/no-Xray generic build-output check
- Passed: multi-foreign preservation static check
- Passed: v2 bundle parser tests for valid bundle, missing auth, missing obfs,
  invalid port, and forbidden Hysteria UDP `443`
- Passed: secret handling/static check for runtime bundle warnings and no
  private-key printing in the generic flow
- Passed: no `undetectable` wording check
- Passed: `git diff --check`
- Not run locally: ShellCheck is unavailable in PowerShell and Git Bash PATH

## Remaining Issues

- SSH Auto Mode is intentionally a placeholder; this PR does not collect SSH
  credentials.
- Only `hysteria2_obfs_udp` generic UDP forward is buildable from Auto Tunnel
  Expert in this PR.
- Live latency, packet loss, and payload-delivery scoring require real
  Iran/Foreign server validation after merge.

## Next Exact Step

Run the local validation matrix, open the Tunnel Engine Registry and Adaptive
Scanner PR, review GitHub ShellCheck, and merge only if checks pass.
