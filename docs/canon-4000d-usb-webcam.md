# Canon EOS 4000D as a USB Webcam on Linux

Status: **Working and verified on `asus-vivobook` 2026-08-28.** `gphoto2 → ffmpeg → /dev/video9` bridge streaming 1056×704 @ 25 fps. Wrapper script `scripts/start-canon-webcam.sh` (installed to `~/.local/bin/`) with `-q` quality-settings and `-r` lossless-record modes. Boot-time loopback persistence not yet enabled (optional, see end).

Kartik wanted the easiest way to get video off a **Canon EOS 4000D** (EF-S 18‑55 mm III kit lens) over **USB** on his Debian laptop, for **video calls** and occasionally **archiving clips**. Three options were weighed (see *Options considered*); the zero‑cost, zero‑hardware one — the standard `gphoto2` + `v4l2loopback` recipe — was chosen and set up.

## Machine facts

| Fact | Value |
|---|---|
| Host | `asus-vivobook`, Debian forky/sid, kernel `7.1.8+deb14.1-amd64` |
| Camera | Canon EOS 4000D (Rebel T100), mini‑HDMI + USB 2.0 Mini‑B, LP‑E10 battery |
| gphoto2 support | 4000D in libgphoto2 since **2.5.20**; EOS live‑view fixes through 2.5.25+. Debian forky is far newer — support solid |
| USB live‑view stream | MJPEG, **1056×704, 25 fps**, ~0.2–0.5 s latency (this is *not* the 1080p movie signal — USB 2.0 live view is always lower res) |
| Loopback module | `v4l2loopback` 0.15.4 via `v4l2loopback-dkms`, built & signed for the running kernel |
| Loopback device | `/dev/video9`, `card_label="Canon 4000D"` (laptop's own webcam holds video0/1) |
| Canon EOS Webcam Utility | Windows/macOS only — **no Linux build**, not an option |
| No passwordless sudo on this box | the one `sudo modprobe` step prompts for a password |

## One‑time setup (DONE 2026-08-28)

```bash
sudo apt update
sudo apt install linux-headers-amd64 gphoto2 ffmpeg v4l2loopback-dkms v4l2loopback-utils
```

| Package | Role |
|---|---|
| `linux-headers-amd64` | metapackage tracking headers for current + future kernels; DKMS builds against it |
| `gphoto2` | pulls the live‑view MJPEG off the camera over USB (drags in `libgphoto2-6`) |
| `ffmpeg` | converts the MJPEG and writes it into the loopback device |
| `v4l2loopback-dkms` | kernel module providing the virtual `/dev/videoN`; compiled at install time |
| `v4l2loopback-utils` | `v4l2loopback-ctl` for inspecting/managing the device |

### Verification (all passed 2026-08-28)

```bash
sudo dkms status v4l2loopback
# → v4l2loopback/0.15.4, 7.1.8+deb14.1-amd64, x86_64: installed

sudo modinfo v4l2loopback | head
# → filename .../updates/dkms/v4l2loopback.ko.xz, version 0.15.4, depends: videodev
```

> `dkms` and `modinfo` live in `/usr/sbin`, which is not on the normal user's `PATH` here.
> Use `sudo dkms …` / `sudo modinfo …` or the full `/usr/sbin/…` path.

## Everyday use — the wrapper script

`scripts/start-canon-webcam.sh` does the whole dance: checks the camera is seen, releases it from the GNOME/GVFS auto‑mount, loads `v4l2loopback` if needed, then runs the `gphoto2 | ffmpeg` bridge with a clean Ctrl‑C teardown.

Install it on the laptop once:

```bash
mkdir -p ~/.local/bin
cp /path/to/claude-agent-workspace/scripts/start-canon-webcam.sh ~/.local/bin/
chmod +x ~/.local/bin/start-canon-webcam.sh
# ~/.local/bin is on PATH by default on Debian if it exists at login;
# otherwise: echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

Then, every time:

1. Connect the 4000D by USB. Set the **mode dial to a stills position** (P/Av/Tv/M/Auto) — *not* the movie icon. For `-q` to have full effect use **M**.
2. Run:

   ```bash
   start-canon-webcam.sh          # plain webcam
   start-canon-webcam.sh -q       # + apply quality settings first
   ```

   Enter the sudo password if it asks (first run after boot, to load the module).
   The mirror flips up, live view starts, and `ffmpeg` prints a running
   `frame= … fps= …` line.
3. In any app (browser, Zoom, Discord…) pick the camera **Canon 4000D**.
4. Stop with **Ctrl‑C**. The mirror drops; `/dev/video9` stays for the next run.

To also save a lossless copy while you're on the call:

```bash
start-canon-webcam.sh -q -r ~/Videos/canon-$(date +%F-%H%M).mkv
```

Local preview without an app:

```bash
ffplay /dev/video9            # or: mpv av://v4l2:/dev/video9
```

### Script options

```text
start-canon-webcam.sh [-n VIDEO_NR] [-d /dev/videoN] [-l "Card Label"] [-q] [-r FILE]
  -n   loopback device number (default 9)
  -d   explicit device path, overrides -n
  -l   card_label apps see    (default "Canon 4000D")
  -q   apply quality settings to the camera first (WB, ISO 100, sRGB, Standard style)
  -r   also record the untouched stream losslessly to FILE (.mkv/.mov/.avi)
```

Env overrides: `CANON_VIDEO_NR`, `CANON_DEVICE`, `CANON_LABEL`,
`CANON_WB` (white balance for `-q`, default `Daylight`),
`CANON_ISO` (ISO for `-q`, default `100`).

### The raw pipeline (what the script runs)

```bash
gio mount -s gphoto2 2>/dev/null; pkill -x gvfsd-gphoto2
sudo modprobe v4l2loopback exclusive_caps=1 card_label="Canon 4000D" video_nr=9

# -q only: best-effort, each skipped if the body/mode rejects it
gphoto2 --set-config whitebalance=Daylight --set-config iso=100 \
        --set-config colorspace=sRGB --set-config picturestyle=Standard

gphoto2 --set-config output=PC --stdout --capture-movie \
  | ffmpeg -f mjpeg -i - \
      -map 0:v -vf format=yuv420p -f v4l2 /dev/video9 \
      -map 0:v -c:v copy /path/to/clip.mkv        # second output only with -r
```

- `exclusive_caps=1` — makes Chrome/Firefox/Zoom/Electron apps accept the node as a real capture device.
- `output=PC` — largest live‑view preview size the 4000D offers (`MOBILE`/`MOBILE2` are smaller).
- `-vf format=yuv420p` — v4l2 consumers want planar YUV; the camera sends `yuvj422p` MJPEG.
- `-c:v copy` — the recording branch stores the camera's exact JPEG frames, no re‑encode.

## Getting the best quality

**The ceiling: 1056×704 @ ~25 fps.** That's what Canon's USB live-view stream gives on a Rebel-class body — no setting changes it. Higher resolution needs the mini-HDMI → capture-card route (*Options considered*, row C). Within that frame:

### What actually helps (and what `-q` does)

`-q` applies these before live view starts — each is best-effort and skipped if the body or the mode dial position rejects it:

| Setting | Effect on the feed | Notes |
|---|---|---|
| `whitebalance=Daylight` (`CANON_WB` to change) | stops colour drifting mid-call | pick one that matches your room light: `Tungsten`, `Fluorescent`, `Cloudy`, `Shade`, `Flash` |
| `iso=100` (`CANON_ISO`) | least sensor noise | in **M** it sticks; in P/Av/Tv the camera may keep ISO on Auto and skip it |
| `colorspace=sRGB` | correct colours for screen use | marginal — the preview is ~sRGB anyway |
| `picturestyle=Standard` | contrast/saturation/sharpening of the preview JPEG | `Neutral` if you'd rather grade a recording later |

### Manual extras (mode dial on **M**, run before starting the script)

```bash
gphoto2 --set-config aperture=5.6       # kit lens sharpest ~f/5.6–8
gphoto2 --set-config shutterspeed=1/50  # >= 1/50 to avoid mains flicker
```

Then: **light the scene** so the camera isn't gaining up, **focus manually** (lens switch → MF, magnify once and nail it), keep the lens at f/5.6–f/8.

Run `gphoto2 --list-config` to see the exact option names/values your body exposes — the aliases above are the common Canon EOS ones but aren't guaranteed per model.

### What does *not* help for calls

Feeding 4:2:2 (`-pix_fmt yuyv422`) instead of `yuv420p` preserves chroma into the loopback, but every call app re-encodes to 4:2:0 VP8/VP9/H.264 anyway, so it's wasted. Browsers also usually cap the negotiated resolution at 720p regardless. The wins that survive a call are the in-camera ones above plus lighting and focus.

### Archiving clips

Use `-r FILE`. It adds a second ffmpeg output that copies the camera's original MJPEG frames verbatim (`-c:v copy`) — the highest-fidelity capture possible from this stream, higher than OBS (which always re-encodes). `.mkv` is the safest container. Transcode later if you need something smaller:

```bash
ffmpeg -i clip.mkv -c:v libx264 -crf 12 -preset slow -pix_fmt yuv422p clip-h264.mkv
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Could not claim the USB device` / `device busy` | GVFS re‑grabbed the camera. Re‑run `gio mount -s gphoto2; pkill -x gvfsd-gphoto2` (the script does this each start). |
| `*** Error: Could not capture image ***` / `Out of Focus` | Half‑press the shutter once to focus, or set the lens switch to **MF**. |
| App doesn't list the camera | Confirm `exclusive_caps=1` was set: `cat /sys/module/v4l2loopback/parameters/exclusive_caps` → `Y`. Reload the module if not. |
| `modprobe: ... cannot be found` after a kernel update | DKMS didn't rebuild. `sudo apt install --reinstall v4l2loopback-dkms`, or `sudo dkms autoinstall`. Make sure `linux-headers-amd64` is installed so future kernels rebuild automatically. |
| Feed freezes after ~1 min, camera warm | LP‑E10 running low / sensor heat. Use the **ACK‑E10** dummy‑battery AC kit for long sessions. |
| Autofocus hunts constantly | Live‑view contrast AF is slow. Set lens to **MF**, focus once. |

## Persist the loopback across reboots (optional — NOT done yet)

So `/dev/video9` always exists and `start-canon-webcam.sh` never needs sudo:

```bash
echo 'v4l2loopback' | sudo tee /etc/modules-load.d/v4l2loopback.conf
printf 'options v4l2loopback exclusive_caps=1 card_label="Canon 4000D" video_nr=9\n' \
  | sudo tee /etc/modprobe.d/v4l2loopback.conf
```

Trade‑off: a dummy "Canon 4000D" camera then shows up in every app's device list even when the DSLR is unplugged. Leave it on‑demand if that's annoying.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **A. `gphoto2` → `v4l2loopback` (chosen)** | free, no hardware, works today, system‑wide `/dev/videoN`, scriptable | USB 2.0 caps at ~1056×704 / sub‑second latency; DKMS rebuild on every kernel bump; GVFS auto‑mount needs clearing; no usable continuous AF; battery drain | **Chosen** — the "easiest via USB with what's on hand" answer |
| **B. OBS Studio as capture host** | recording, scenes, overlays, in‑app exposure control | native `obs-gphoto` source isn't packaged for Debian (build from source); still sits on the Option A stack; same resolution ceiling | only if the goal is streaming/recording, not "be a webcam" |
| **C. mini‑HDMI → USB capture dongle (UVC)** | true plug‑and‑play, survives kernel updates, higher res + lower latency, camera USB port stays free | costs ~$15–25 (MS2130); 4000D HDMI is **not clean** — info overlay, feed drops/resizes on half‑press / movie mode; may output 1080i; still want ACK‑E10 | best *experience* long‑term if a small purchase is acceptable |

## References

- [Setting up a DSLR webcam on Linux — Austin Gil](https://austingil.com/dslr-webcam-linux/)
- [gPhoto remote control docs (live view / `output` sizes)](http://www.gphoto.org/doc/remote/)
- [libgphoto2 NEWS (4000D support, EOS live‑view fixes)](https://github.com/gphoto/libgphoto2/blob/master/NEWS)
- [EOS cameras with clean HDMI output — p4pictures](https://www.p4pictures.com/2021/03/eos-cameras-clean-hdmi-live-streaming/)
- [Canon KB: cameras with "Clean HDMI output"](https://support.usa.canon.com/kb/index?page=content&id=ART170224)
