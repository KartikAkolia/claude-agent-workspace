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

## Sources

- [Debian wiki — NetworkManager](https://wiki.debian.org/NetworkManager) (ifupdown/NetworkManager interaction, `managed=` handover procedure)
- [NetworkManager.conf(5) — networkmanager.dev](https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html) (`[ifupdown] managed`, `wifi.powersave`, `carrier-wait-timeout`)
- [Red Hat Customer Portal — IPv6 warnings when IPv6 is disabled in the kernel](https://access.redhat.com/solutions/6967304) (per-connection `ipv6.method` vs. kernel-level `ipv6.disable=1` tradeoffs)
- [Debian wiki — Suspend](https://wiki.debian.org/Suspend) (`systemctl mask` as the documented way to prevent all sleep/suspend/hibernate)
