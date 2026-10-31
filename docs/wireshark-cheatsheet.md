# Wireshark Cheat Sheet

Written against Wireshark 4.7.4. On Arch, `wireshark-cli` provides `tshark`, `dumpcap`, `capinfos`, `editcap` and `mergecap`, and `wireshark-qt` adds the `wireshark` GUI. Both were removed from the CachyOS laptop on 2026-10-31, so reinstall them with `sudo pacman -S wireshark-qt` before using anything below.

## Capture without root

```bash
sudo usermod -aG wireshark $USER       # then log out and back in
groups | grep wireshark                # check it took effect
```

## GUI

```bash
wireshark                              # open the GUI
wireshark -i wlan0 -k                  # start capturing on wlan0 right away
wireshark -r capture.pcapng            # open a saved capture
wireshark -r cap.pcapng -Y "http"      # open a file with a display filter applied
```

## tshark: interfaces and live capture

```bash
tshark -D                              # list interfaces
tshark -i eth0                         # capture on eth0 (Ctrl+C to stop)
tshark -i any                          # capture on all interfaces
tshark -i eth0 -c 100                  # stop after 100 packets
tshark -i eth0 -a duration:60          # stop after 60 seconds
tshark -i eth0 -w out.pcapng           # save to a file
tshark -i eth0 -w out.pcapng -b filesize:10000 -b files:5   # ring buffer: 5 files of about 10 MB
```

## Capture filters

BPF syntax, set with `-f`, applied while capturing.

```bash
tshark -i eth0 -f "host 192.168.1.10"
tshark -i eth0 -f "port 53"
tshark -i eth0 -f "tcp port 443 and not host 10.0.0.1"
tshark -i eth0 -f "net 192.168.1.0/24"
```

## Reading files and display filters

Wireshark syntax, set with `-Y`.

```bash
tshark -r out.pcapng                                    # read a file
tshark -r out.pcapng -Y "ip.addr == 1.2.3.4"
tshark -r out.pcapng -Y "tcp.port == 80"
tshark -r out.pcapng -Y "dns"
tshark -r out.pcapng -Y "http.request"
tshark -r out.pcapng -Y "tcp.flags.syn == 1 && tcp.flags.ack == 0"   # SYNs only
tshark -r out.pcapng -Y "tcp.analysis.retransmission"
tshark -r in.pcapng -Y "dns" -w dns-only.pcapng         # save filtered packets
```

## Output formats

```bash
tshark -r f.pcapng -V                  # full packet detail
tshark -r f.pcapng -x                  # hex and ASCII dump
tshark -r f.pcapng -T fields -e ip.src -e ip.dst -e tcp.dstport              # chosen fields only
tshark -r f.pcapng -T fields -E separator=, -E header=y -e frame.time -e ip.src   # CSV
tshark -r f.pcapng -T json             # JSON
tshark -r f.pcapng -n                  # turn off name resolution (faster)
```

## Statistics

`-q` hides the per-packet lines.

```bash
tshark -r f.pcapng -q -z io,phs              # protocol hierarchy
tshark -r f.pcapng -q -z conv,tcp            # TCP conversations
tshark -r f.pcapng -q -z endpoints,ip        # IP endpoints
tshark -r f.pcapng -q -z http,tree           # HTTP request stats
tshark -r f.pcapng -q -z dns,tree            # DNS stats
tshark -r f.pcapng -q -z follow,tcp,ascii,0  # follow TCP stream 0
```

## Helper tools

```bash
dumpcap -i eth0 -w out.pcapng                # lightweight capture, best for long runs
capinfos out.pcapng                          # file summary (duration, packet count, size)
editcap -c 1000 big.pcapng part.pcapng       # split into files of 1000 packets each
editcap -A "2026-10-28 10:00:00" -B "2026-10-28 11:00:00" in.pcapng slice.pcapng   # keep a time range
mergecap -w merged.pcapng a.pcapng b.pcapng  # merge captures
```

## GUI shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl+E` | Start or stop capture |
| `Ctrl+K` | Capture options |
| `Ctrl+/` | Jump to the display filter bar |
| `Ctrl+Alt+Shift+T` | Follow TCP stream |
| `Ctrl+G` | Go to a packet number |
| `Ctrl+F` | Find a packet |
| `Ctrl+M` | Mark a packet |

## Display filter basics

`==`, `!=`, `>`, `<`, `&&`, `||` and `!` all work. Common fields are `ip.addr`, `ip.src`, `ip.dst`, `tcp.port`, `udp.port`, `eth.addr`, `http.host`, `dns.qry.name` and `frame.len`. To match text inside packets, use `contains "text"` or `matches "regex"`.

Capture filters (`-f`) and display filters (`-Y`) use different syntax: a capture filter is written `port 80`, while the display filter for the same thing is `tcp.port == 80`.
