# NetworkManager Setup Plan (Homelab Host, Not Yet Executed)

Kartik asked to get NetworkManager actually managing the network on his Debian homelab box (`dell-optiplex`, 192.168.0.222), disable IPv6 and everything related to it, and disable anything that could put the box to sleep and drop networking. Investigated and planned on 2026-08-24; execution deferred to a future session — **nothing in this document has been applied to the host yet.**

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

## Why this was deferred instead of executed

Step 1 briefly brings `enp3s0` down and back up under NM's control. It should reacquire the same DHCP lease within a couple of seconds, but this SSH session (via `plink` from the Windows machine) is the only access path to the host — if the handover doesn't come back cleanly, there's no rollback without physical/console access to the OptiPlex. Per the `homelab-admin` skill's own safety rule ("never change networking without rollback out-of-band access"), execution was paused pending confirmation that Kartik has local/console access as a fallback before step 1 runs. Steps 2 and 3 carry much lower risk (per-connection IPv6 change and a reversible systemd mask) and could reasonably run right after step 1 succeeds, in the same session.

## To resume this later

Confirm local/console access to `dell-optiplex` is available, then run steps 1–3 above in order, verifying after each step (per `homelab-admin`'s validation checklist: service still running, `ip addr`/`nmcli device status` shows `enp3s0` as managed with the expected IP, `ip -6 addr` shows nothing on `enp3s0`, `systemctl status sleep.target` reports masked) before moving to the next.

## Sources

- [Debian wiki — NetworkManager](https://wiki.debian.org/NetworkManager) (ifupdown/NetworkManager interaction, `managed=` handover procedure)
- [NetworkManager.conf(5) — networkmanager.dev](https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html) (`[ifupdown] managed`, `wifi.powersave`, `carrier-wait-timeout`)
- [Red Hat Customer Portal — IPv6 warnings when IPv6 is disabled in the kernel](https://access.redhat.com/solutions/6967304) (per-connection `ipv6.method` vs. kernel-level `ipv6.disable=1` tradeoffs)
- [Debian wiki — Suspend](https://wiki.debian.org/Suspend) (`systemctl mask` as the documented way to prevent all sleep/suspend/hibernate)
