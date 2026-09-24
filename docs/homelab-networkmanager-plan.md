# NetworkManager Setup Plan (Homelab Host) — Executed 2026-08-24

Kartik asked to get NetworkManager actually managing the network on his Debian homelab box (`dell-optiplex`, 192.168.0.222), disable IPv6 and everything related to it, and disable anything that could put the box to sleep and drop networking. Planned on 2026-08-24; **executed the same day** once Kartik confirmed local/console access to the box as a fallback. All three steps succeeded, validated after each one, SSH session never dropped. See "What actually happened" below for one deviation from the original plan (step 2 needed a follow-up fix).

## Current state (as of 2026-08-24)

- Single NIC: `enp3s0`, DHCP-assigned `192.168.0.222/24`, default route via `192.168.0.1`.
- `NetworkManager.service` is installed and running (pulled in earlier as part of the dwm-titus `desktop-optional` package profile), but `nmcli device status` shows `enp3s0` as **unmanaged**. Root cause, confirmed against the [Debian wiki's NetworkManager page](https://wiki.debian.org/NetworkManager): `enp3s0` has a stanza in `/etc/network/interfaces` (`allow-hotplug enp3s0` / `iface enp3s0 inet dhcp`), and `/etc/NetworkManager/NetworkManager.conf` has `[main] plugins=ifupdown,keyfile` / `[ifupdown] managed=false` — Debian's default since Squeeze, which hands any interface listed in `interfaces(5)` off to `ifupdown`/`networking.service` instead of NetworkManager. NM is running but doing nothing.
- IPv6: enabled, link-local only (`fe80::e324:8592:6353:ace/64` on `enp3s0`) — no global IPv6 address or route assigned by the LAN. `sysctl net.ipv6.conf.all.disable_ipv6 = 0` (and `default`/`enp3s0` = 0). The IPv6 kernel module isn't a loadable module on this kernel (`7.1.8+deb14.1-amd64`) — it's compiled in, so `rmmod`/blacklist approaches don't apply here.
- Sleep: `sleep.target`, `suspend.target`, `hibernate.target`, `hybrid-sleep.target`, `suspend-then-hibernate.target` are all present and unmasked (systemd defaults). `/etc/systemd/logind.conf` has no active overrides (empty `[Login]` section, all defaults). No `tlp`/`power-profiles-daemon`/`powertop` installed. `nvidia-suspend.service`/`nvidia-hibernate.service` are enabled (from the NVIDIA driver package) but only trigger as hooks *if* the higher-level sleep targets are actually entered — masking those targets makes the nvidia hooks moot without touching them directly.

## Planned changes

1. **Hand `enp3s0` over to NetworkManager.**
   - Comment out (or remove) the `enp3s0` stanza in `/etc/network/interfaces`, leaving the `lo` stanza untouched.
   - Set `managed=true` under `[ifupdown]` in `/etc/NetworkManager/NetworkManager.conf` (or a drop-in under `/etc/NetworkManager/conf.d/`).
   - Restart `NetworkManager.service` (`sudo systemctl restart NetworkManager`) for the change to take effect — confirmed via the Debian wiki this is the standard, documented handover procedure.

2. **Disable IPv6 on the `enp3s0` connection specifically, not at the kernel/GRUB level.**
   - Once NM manages the interface: `nmcli connection modify enp3s0 ipv6.method disabled`, then `nmcli connection up enp3s0` (or reboot) to apply.
   - `ipv6.method disabled` strips all IPv6 configuration on that connection — link-local, SLAAC/RA, and DHCPv6 alike — which covers "IPv6 and all related functions" for this interface.
   - Deliberately **not** using the global `ipv6.disable=1` GRUB kernel parameter: Red Hat's own documentation warns this breaks anything binding to `::1` (including sshd) and can trigger unrelated SELinux/service issues. Per-connection `disabled` avoids that entirely while achieving the same practical result on this box (single NIC, no other IPv6-dependent services identified).

3. **Mask the sleep-related systemd targets so the box can never suspend/hibernate from any trigger.**
   - `sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target`
   - This is the Debian wiki's own documented method ([wiki.debian.org/Suspend](https://wiki.debian.org/Suspend)) for guaranteeing a system never sleeps, regardless of whether the trigger is a power/suspend key, a D-Bus call, or a script — and it's fully reversible with `systemctl unmask` on the same unit list.
   - No `logind.conf` edits needed: masking the targets blocks any attempt to enter them, so `HandleSuspendKey`/idle-action defaults become moot.

## Why this was deferred, then executed

Step 1 briefly brings `enp3s0` down and back up under NM's control. Per the `homelab-admin` skill's own safety rule ("never change networking without rollback out-of-band access"), execution was paused in the earlier session pending confirmation that Kartik has local/console access as a fallback before step 1 runs. On 2026-08-24 Kartik confirmed console access was available, so all three steps were run in order in the same session.

## What actually happened (2026-08-24)

- **Step 1** ran exactly as planned. NetworkManager's log showed it "assumed" the already-DHCP-configured interface (`reason 'connection-assumed', managed-type: 'external'`) rather than tearing it down first — no interface flap, SSH session never dropped, `enp3s0` came back `nmcli device status: connected (externally)` holding the same `192.168.0.222` address.
- **Step 2 needed a follow-up fix.** Running `nmcli connection modify enp3s0 ipv6.method disabled` + `nmcli connection up enp3s0` did strip IPv6 correctly (`ip -6 addr show enp3s0` empty), but this was a *full* reconnect (not an "assumed" one), so NM's internal DHCP client made a fresh DORA request. The router (`192.168.0.1`) handed back a **different address, `192.168.0.223`**, instead of `.222` (the old `.222` lingered only as a secondary address with a draining lease). Root cause: NM's internal DHCP client sends a different `dhcp_client_identifier` than the old `ifupdown`/`dhclient` setup did, so the router's lease table treated it as a new client.
   - First fix attempt: `nmcli connection modify enp3s0 ipv4.dhcp-client-id mac` (matches the classic type-01-hardware-address client-id) + a full `connection down`/`up` to force a fresh DORA. Confirmed the client-id changed (`dhcp_client_identifier = 01:a4:1f:72:4d:d9:4e`) but the router *still* handed back `.223`, not `.222` — its lease table apparently keys on something else, or the old `.222` lease entry hadn't aged out.
   - Kartik's decision: stop chasing the router's DHCP behavior and switch `enp3s0` to a **static IP** instead — `ipv4.method manual`, `ipv4.addresses 192.168.0.222/24`, `ipv4.gateway 192.168.0.1`, `ipv4.dns 194.168.4.100,194.168.8.100` (the same DNS servers DHCP had been handing out). This is more robust for a homelab server that other things reach by fixed IP, independent of router lease-table quirks going forward.
   - After the static config, a stray leftover: the address briefly still showed the `dynamic` kernel flag and there was a duplicate stale `proto dhcp` default route at metric 1002 (traced to `networking.service`/ifupdown, which ran once at boot before this session's edits and was never torn down — no live `dhclient` process, just orphaned kernel routes). Fixed with a second full `systemctl restart NetworkManager` (address flag corrected to `valid_lft forever`) plus manually deleting the two leftover metric-1002 routes (`ip route del default ... metric 1002`, `ip route del 192.168.0.0/24 ... metric 1002`). Final state: single static default route at metric 100, `192.168.0.222/24` with `valid_lft forever`, confirmed with a live ping to `8.8.8.8`.
- **Step 3** ran exactly as planned — `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target`, confirmed all five report `Loaded: masked`.

**`.222` is now a static assignment, not a DHCP lease** — this repo's docs/memory referring to `.222` as the host's DHCP address should be read as "its address, now fixed" rather than implying a lease that could still drift.

## If revisiting this host's networking again

Current state: `enp3s0` static at `192.168.0.222/24` via NetworkManager, IPv6 disabled on the connection (not kernel-wide), sleep targets masked. `networking.service` (ifupdown) is still enabled but only manages `lo` now — it's not actively conflicting, but wasn't explicitly disabled either since it's harmless as-is.

## Redone after reinstall (2026-09-24)

`dell-optiplex` was reinstalled (Debian 13, kernel `6.12.107+deb13-amd64`, Cinnamon), so the state above is history. On the fresh install, NetworkManager already managed `enp3s0` through its default `Wired connection 1` profile (DHCP; the router still hands out `192.168.0.222`). `networking.service` only brought up `lo`, and `systemd-networkd` was already disabled. `wpa_supplicant` was left enabled, since it's NetworkManager's own Wi-Fi backend rather than a competing daemon.

Changes, run as one root script (log: `/var/tmp/nm-ipv4-20260924.log`; backups with a `.bak-20260924` suffix next to `NetworkManager.conf` and `gai.conf`, plus `/var/tmp/Wired connection 1.nmconnection.bak-20260924`):

- `/etc/NetworkManager/NetworkManager.conf` reduced to `[main] plugins=keyfile`, dropping the `ifupdown` plugin and its `managed=false` section.
- `systemctl disable --now networking.service`. `lo` stays up without it (systemd configures loopback itself, and NM shows it as externally connected).
- `nmcli connection modify "Wired connection 1" ipv6.method disabled`, applied with `nmcli device reapply enp3s0` instead of a full reconnect, so there was no new DHCP request and no repeat of the address change described above.
- `/etc/sysctl.d/90-disable-ipv6.conf` sets `disable_ipv6 = 1` for `all` and `default` and `0` for `lo`, so interfaces NM doesn't manage (bridges, containers) come up without IPv6, while `::1` stays available for local services (CUPS on `[::1]:631`, sshd on `[::]:22`). NM's `ipv6.method` can't be set as a global connection default in `NetworkManager.conf`, so a new NM profile with `ipv6.method=auto` would turn IPv6 back on for its interface. Set `ipv6.method disabled` on any new profile.
- `/etc/gai.conf` gained the full RFC 6724 precedence table with `::ffff:0:0/96` raised to `100`, so `getaddrinfo` returns IPv4 first. The whole table is restated because any `precedence` line replaces glibc's default table.

Verified: NM `active`/`enabled`; `networking`, `systemd-networkd` `inactive`/`disabled`; `enp3s0` has only `192.168.0.222/24` and no IPv6 address or route; `disable_ipv6` reads `1` for `all`/`default`/`enp3s0` and `0` for `lo`; `getent ahosts google.com` returns only IPv4; ping and HTTPS both work.

DNS (same day): `Wired connection 1` now uses Cloudflare (`ipv4.dns "1.1.1.1 1.0.0.1"`, `ipv4.ignore-auto-dns yes`), applied with `nmcli device reapply`; `/etc/resolv.conf` lists only those two servers. There's no system DNS cache to flush: `systemd-resolved`, `nscd`, `dnsmasq`, and `unbound` aren't running, and NM writes `resolv.conf` directly, so glibc queries the upstream servers on every lookup. Browsers keep their own caches (Brave: `brave://net-internals/#dns` → Clear host cache).

To keep the ISP's DNS from returning through any other connection (a new NIC, a VPN, or a regenerated "Wired connection"), `/etc/NetworkManager/conf.d/90-global-dns.conf` sets `[global-dns-domain-*] servers=1.1.1.1,1.0.0.1`. NM's global DNS overrides the DNS from every connection profile and DHCP lease. Verified after a `systemctl restart NetworkManager` as a stand-in for a reboot: `resolv.conf` still lists only Cloudflare, NM's `GlobalDnsConfiguration` D-Bus property shows both servers, `enp3s0` kept `.222`, and lookups resolve. No `resolvconf`, `openresolv`, or `isc-dhcp-client` is installed to overwrite `resolv.conf` behind NM's back. To revert, delete that file and run `systemctl reload NetworkManager`.

Bridge (same day): the host's IP now lives on a `br0` bridge rather than directly on `enp3s0`, for bridged KVM guests. `br0` uses DHCP with `enp3s0`'s MAC cloned, so it still gets `.222`. `enp3s0` is a bridge port (`br0-port1`), and `Wired connection 1` is kept as the rollback profile with `autoconnect no`. Details and the rollback command are in `docs/kvm-virtualization-setup.md`'s "Redo after reinstall" section.

## Sources

- [Debian wiki — NetworkManager](https://wiki.debian.org/NetworkManager) (ifupdown/NetworkManager interaction, `managed=` handover procedure)
- [NetworkManager.conf(5) — networkmanager.dev](https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html) (`[ifupdown] managed`, `wifi.powersave`, `carrier-wait-timeout`)
- [Red Hat Customer Portal — IPv6 warnings when IPv6 is disabled in the kernel](https://access.redhat.com/solutions/6967304) (per-connection `ipv6.method` vs. kernel-level `ipv6.disable=1` tradeoffs)
- [Debian wiki — Suspend](https://wiki.debian.org/Suspend) (`systemctl mask` as the documented way to prevent all sleep/suspend/hibernate)
