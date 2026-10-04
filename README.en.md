# Live MiniDV capture on macOS 26 Tahoe (Apple Silicon): Sony DCR-PC115E over FireWire / i.LINK, video **and** audio in real time

Apple removed the FireWire stack in macOS 26. This is a working setup that (a) archives MiniDV tapes
bit-exactly and (b) turns the camcorder into a live camera with sound in OBS, Chrome and Zoom.

[Русская версия →](README.md) · [Full guide (HTML)](https://paperpit.github.io/minidv-apple-silicon/guide.ru.html) · [Live mode setup](docs/live-setup.md)

---

## Why this exists

macOS 26 (Tahoe) ships no FireWire support at all. Old MiniDV camcorders are left without a driver:
you cannot capture a tape, and you cannot use the camera as a webcam. This repository is what we managed
to rebuild on a MacBook Air M1 — and everything below was checked with numbers, not with "seems to work":

- **Tape capture** — a bit-exact copy of the DV stream; the resulting file divides by 144,000 bytes with no remainder.
- **Live video** — the camcorder, in CAMERA mode or playing back a tape, goes to OBS through Syphon.
- **Live audio** — taken straight out of the DV stream, with no separate audio cable, into BlackHole
  (applications see it as a microphone) and from there into OBS, Chrome and Zoom.
- **One double-click** — a launcher brings up the camera, the audio, the OBS sources and the browser-facing virtual camera.

Verified by bit-for-bit comparison against FFmpeg: 16-bit/48 kHz and 12-bit/32 kHz audio, plus an offline
render of the output graph. Frame geometry is a separate story: Sony's `16:9WIDE` is recorded anamorphically,
and without stretching the picture comes out roughly 42% too narrow — measured on an OBS recording, where
the content filled 1344×1075 (5:4) instead of 16:9 (details in the guide).

## What works

| Capability | Status |
|---|---|
| FireWire driver (DriverKit, user-space OHCI) | works: `net.mrmidi.ASFW.ASFWDriver [activated enabled]` |
| DV capture from the bus | works: ring of 480-byte DIF chunks in shared memory, channel 63 |
| Tape capture to `.dv` | works: 1895 frames, 1 dropped, 0 ring overruns, remainder mod 144,000 = 0 |
| Live video into OBS | works over Syphon, 50p after deinterlace, square pixels |
| Live audio from DV | works: 16-bit/48 kHz and 12-bit/32 kHz, bit-exact against FFmpeg |
| Virtual camera for the browser | works: OBS Virtual Camera (the launcher starts it automatically) |
| Camera as a system device (CMIO) | **no**: the extension is written, but it will not activate with an ad-hoc signature |
| Second audio pair (ST2), shared timeline, bus reset | **no**, see "What is still missing" |

## Requirements

**Hardware**

- An Apple Silicon Mac (tested on a MacBook Air M1, `MacBookAir10,1`). Other Apple Silicon Macs with a
  Thunderbolt 3 port should behave the same way; that is unverified.
- A Sony DCR-PC115E (or another MiniDV camcorder with 4-pin i.LINK, S100).
- A FireWire 4-pin ↔ 9-pin cable.
- **Apple Thunderbolt to FireWire** (A1463) and **Apple Thunderbolt 3 to Thunderbolt 2** (A1790).
  The order is not optional: `A1790 into the Mac → A1463 into it → cable into the camcorder`. A1790 is one-way.
- Mains power for the camcorder: a battery sag in the middle of a cassette ends the capture.

**Software**

```bash
xcode-select --install                        # Xcode and xcodegen
brew install xcodegen
brew install --cask blackhole-2ch             # virtual microphone for the camera audio
brew install --cask obs                       # OBS Studio 30+ (virtual camera is a system extension)
brew install node                             # for the launcher helper (obs-websocket); skip if already installed
```

`node` is only needed by the launcher helper. Without it the launcher still brings up the camera and the
audio, but you have to add the OBS sources by hand once — OBS remembers them.

## Quick start

### 1. Driver

```bash
git clone https://github.com/PaperPit/minidv-apple-silicon.git      # this repository
git clone https://github.com/mrmidi/ASFireWire.git ~/Developer/ASFireWire
cd ~/Developer/ASFireWire
git checkout 9055449                          # the commit our patch was taken against
git apply ../minidv-apple-silicon/patches/asfw-minidv-live.patch
./build.sh --config Release && ./sign.sh
```

Then follow the guide: disable SIP, turn on developer mode, install `ASFW.app`, approve the extension in
System Settings and reboot. Step by step: [docs/guide.ru.html](https://paperpit.github.io/minidv-apple-silicon/guide.ru.html), sections 2 and 6.

### 2. Live mode

```bash
git clone https://github.com/PaperPit/minidv-apple-silicon.git && cd minidv-apple-silicon
./tools/minidv-live/install.sh                # builds and installs "MiniDV Live.app"
```

Double-click **MiniDV Live** (or ⌘Space → "MiniDV Live") and everything is up: camera, audio, OBS sources,
virtual camera. Log: `~/Library/Logs/MiniDVLive.log`.

OBS will now show:

- `Sony DCR-PC115E` (Syphon Client) — video;
- `BlackHole 2ch` (Audio Input Capture) — audio.

In Chrome or Zoom, pick the camera `OBS Virtual Camera` and the microphone `BlackHole 2ch`.

> **The catch.** `OBS Virtual Camera` is a system extension, so it is **always** listed among the cameras,
> even when OBS is closed. Frames only flow while the virtual camera output is active: hit
> **Start Virtual Camera** in OBS first, then select it in the browser. The launcher does this for you.
> The extension advertises a single 1920×1080@60 format — an application that insists on exactly 30 fps
> will be refused (`tools/camera-test` will show this precisely).
> For windowless debugging: `MINIDV_NO_DIALOG=1 "/Applications/MiniDV Live.app/Contents/MacOS/MiniDVLive"`.

## How it works

**Audio is already inside the DV stream.** No separate audio path is needed: every DV frame carries
12 DIF sequences of 9 audio blocks each, so sound is tied to the frame by construction and there is no
sync to restore afterwards. One frame holds 1920 samples per channel at 48 kHz, 1280 at 32 kHz and
1764 at 44.1 kHz. Both branches are bit-exact against FFmpeg: 16-bit/48 kHz over 250 frames (480,000 samples,
max|d| = 0) and 12-bit/32 kHz (1280 samples per channel, compared against FFmpeg's first audio stream).
An offline render of the AVAudioEngine graph matches bit-for-bit too, and a live run into the device
delivered 50 buffers out of 50 with no losses. Extracting the audio costs 3.5 µs per frame at `-O`,
about 0.009% of the 40 ms budget.

**Frame geometry.** DV pixels are not square, and Sony's 16:9WIDE is an anamorphic recording — the picture
is physically squeezed horizontally inside the 720×576 frame (DCR-PC115E manual, page 59: "the picture … is
compressed in the widthwise direction"). To display it correctly:

| Camera mode | PAR | Size in square pixels |
|---|---|---|
| 4:3 | 16:15 | 768×576 |
| 16:9WIDE | 64:45 | 1024×576 |

The wide-screen flag is read from the VAUX Video Control packet (tag `0x61`) by the same rule FFmpeg uses.
Syphon carries no pixel aspect ratio at all, so the frame leaves for Syphon already stretched to square
pixels. Nothing has to be configured in OBS: 1024×576 is exactly 16:9 and lands in a 1920×1080 canvas with
no letterboxing and no distortion.

## Verifications without the camera

```bash
ASFW=/Applications/ASFW.app/Contents/MacOS/ASFW

$ASFW --list-audio-devices                     # where audio can be played
$ASFW --audio-selftest 3                       # 1 kHz on the left / 3 kHz on the right, into the real sink
$ASFW --dv-audio-selftest test48.dv --pcm-out out.pcm        # .dv → audio through the real path
$ASFW --audio-render-selftest test48.dv --pcm-out render.pcm # the same graph, rendered offline
$ASFW --dv-frame-selftest wide.dv --png wide.png             # frame geometry: 1024×576 for 16:9
```

Test streams are generated with FFmpeg:

```bash
# 16-bit/48 kHz, 4:3
ffmpeg -y -f lavfi -i "testsrc2=size=720x576:rate=25" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=10.5" \
  -f lavfi -i "sine=frequency=3000:sample_rate=48000:duration=10.5" \
  -filter_complex "[1:a][2:a]join=inputs=2:channel_layout=stereo[a]" \
  -map 0:v -map "[a]" -c:v dvvideo -pix_fmt yuv420p -r 25 \
  -c:a pcm_s16le -ar 48000 -ac 2 -t 10 -f dv test48.dv

# same, but anamorphic 16:9
ffmpeg -y -f lavfi -i "testsrc2=size=720x576:rate=25" -c:v dvvideo -pix_fmt yuv420p -r 25 -aspect 16:9 -t 2 -f dv wide.dv
```

## What's inside

```
README.md / README.en.md   this instruction (RU) and its English version
docs/guide.ru.html         full guide: the stack, the driver, the bugs, the capture method, live mode
docs/live-setup.md         live mode setup, flags, diagnostics
docs/troubleshooting.md    common problems and where to look
tools/minidv-live/         the "MiniDV Live" launcher: camera, audio, OBS and virtual camera
tools/camera-test/         browser page for testing the camera and microphone
patches/                   patch against ASFireWire: live DV, audio, geometry, camera extension
images/                    documentation images
```

## What is still missing

- **Camera as a system device (CMIO).** The `ASFWCamera` extension publishes "Sony DCR-PC115E" but does not
  activate: `OSSystemExtensionError.validationFailed (9)` — it needs a proper signature (Developer ID/Development
  with a matching Mach service), not ad-hoc. Live mode therefore runs Syphon → OBS → OBS Virtual Camera, which
  works everywhere, browsers included.
- **ST2** (the second audio pair of the 12-bit mode) is not published; only the first one is decoded.
- **No shared timeline** for audio and video: sync rests on frames arriving one by one, and there is no drift metric.
- **Bus reset**: the Syphon runner has a watchdog, but unplugging the cable and switching CAMERA ↔ VCR are not handled.
- **gap count 44** against an optimal 5 — the driver does not claim the Bus Manager role.
- **NTSC and DVCPRO50** are not supported by the audio extractor (PAL 625/50 only).

## Safety and rollback

Live mode needs a dext signed ad-hoc, which means **SIP disabled** and developer mode enabled. That is a fine
state for this job and a poor one for a daily driver: do not run banking apps on a machine configured this way.
The full rollback order is in the guide, section 6; in short: remove the extension first, then `csrutil enable`,
otherwise you can end up with an orphaned kernel stub.

## License and credits

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

This project stands on [ASFireWire](https://github.com/mrmidi/ASFireWire) (a DriverKit FireWire driver for
macOS 26) — without it none of this would exist. It also uses
[Syphon](https://syphon.github.io/) (frame sharing into OBS),
[BlackHole](https://existential.audio/blackhole/) (virtual microphone),
[obs-websocket](https://github.com/obsproject/obs-websocket) (scene setup),
[FFmpeg](https://ffmpeg.org/) (reference for audio and geometry, and generator of the test streams).

## Search terms

Terms this project should be found by:

- MiniDV, DV, DV25, dvvideo, PAL 625/50, tape capture, DV capture, bit-exact capture, `.dv`
- FireWire, i.LINK, IEEE 1394, OHCI, FW643, Apple Thunderbolt to FireWire A1463, Thunderbolt 3 to Thunderbolt 2 A1790
- DriverKit, dext, system extension, SIP disabled, macOS 26, macOS Tahoe, Apple Silicon, M1, M2, M3, M4
  (M2/M3/M4 untested)
- Sony DCR-PC115E, Sony Handycam, MiniDV camcorder as webcam, other i.LINK DV camcorders
- live camera, live video, live audio, CoreAudio, audio from the DV stream, 16-bit 48 kHz, 12-bit 32 kHz
- BlackHole 2ch, Syphon, OBS Studio, Syphon Client, OBS Virtual Camera, virtual camera, browser camera, Chrome, Zoom
- anamorphic 16:9, 16:9WIDE, PAR, 4:3, 768×576, 1024×576
