# ambilight

Screen-reactive bias lighting for a monitor light bar, driven from macOS.

Captures the screen with ScreenCaptureKit at a deliberately tiny resolution (so
the compositor does the downscaling on GPU), splits it into zones, and drives
your LED controller.

Two backends:

| Backend | Hardware | Result |
|---|---|---|
| **BLE** (`--ble`) | none — your existing MELK/LotusLampX dongle | one color for the whole bar, ~15 Hz |
| **WLED** (default) | ESP32, ~₹400 | per-zone Ambilight, 60 fps |

---

## What the stock hardware actually is

Findings from this machine, all verified rather than assumed:

**The USB connector is 5V power only.** With the bar lit and running:

```
ioreg -rc IOUSBHostDevice      → 0 devices
system_profiler SPUSBDataType  → empty
```

A device with a real data connection enumerates the instant it's plugged in.
This one never appears, so **nothing can be sent down the USB cable.** Control
is over Bluetooth LE — the meander antenna in the corner of the PCB.

**The controller is a `MELK-OA10`.** Confirmed by BLE scan, and its GATT table
matches the LotusLampX reverse-engineering exactly:

```
SERVICE FFF0
  CHAR FFF3  [read,write,writeNoResp]   ← command channel
  CHAR FFF4  [read,notify]
```

`MELK-*` names are SYMPHONY type 30 and use **plain, unencrypted** frames. Only
`ELK-*` devices use the encrypted 21-byte variant, so none of that applies here.

**The strip is addressable, but no command was found that addresses it.** The
E1 frame is a fixed 9 bytes with five payload slots. That is too small for a
framebuffer, though not in principle too small for an index-plus-RGB write
across several commands — so "impossible" would be too strong. What is
established is weaker and empirical: *no verified segment command exists.* Six
payload shapes for `CUSTOM` and `PHONE_MAI_RHYTHM` were probed on this unit and
all were inert, and two independent reverse-engineering projects both describe
the control granularity as single-zone. The per-pixel capability lives
in the controller's firmware and is only reachable through its own canned
effects. One solid color per write is the ceiling. Per-zone requires replacing
the controller (see below).

---

## Quick start (BLE — no purchase)

```bash
swiftc -O ambilight.swift -o ambilight
./ambilight --ble MELK
```

That's it. It scans, connects, sends a power-on frame, and starts streaming your
screen's average color.

Verify the link first if you like — this cycles hues with no screen capture:

```bash
./ambilight --test --ble MELK
```

### Bluetooth permission

CoreBluetooth **aborts the process** (SIGABRT, exit 134) rather than returning an
error when permission is missing. If it dies instantly with no output, grant it:

**System Settings → Privacy & Security → Bluetooth** → enable for your terminal.

Note the controller accepts one connection at a time — force-close the
LotusLampX phone app first, or it will hold the link.

---

## Protocol reference

Fixed 9-byte frames to characteristic `FFF3`, write-without-response, **no
checksum**:

```
offset   0     1     2     3    4    5    6    7     8
       0x7E  len   cmd   p0   p1   p2   p3   p4   0xEF
```

`len` is a hardcoded per-command constant (`0x04` for brightness, `0x07`
otherwise), not a computed length. Byte 7 is a payload slot, not a checksum.

| Action | Bytes |
|---|---|
| set color | `7E 07 05 03 RR GG BB 10 EF` |
| power on | `7E 07 04 FF 01 01 02 01 EF` |
| power off | `7E 07 04 00 01 00 02 01 EF` |
| brightness | `7E 04 01 LL FF FF FF 00 EF` |
| preset mode | `7E 07 03 ID 03 FF FF 00 EF` |
| scene | `7E 07 31 ID FF FF FF 00 EF` |

Red is `7E 07 05 03 FF 00 00 10 EF`. Protocol credit:
[l0lsec/LotusLampX](https://github.com/l0lsec/LotusLampX).

### Rate limiting

Write-without-response has no flow control — overrun just silently drops frames.
`--ble-rate` caps writes (default 15/sec) and `--ble-deadband` suppresses
changes smaller than N per channel, bounded by a 1-second max-hold so a slowly
drifting color still reaches the lamp.

Do **not** reconnect per command the way the reference implementations do; that
costs about a second each. This holds one persistent connection and reconnects
automatically if it drops.

---

## The app

`Ambilight.app` is a menu bar item (no Dock icon) with five modes:

| Mode | Shortcut | |
|---|---|---|
| Movie | ⌘⇧1 | Follows the picture, ignores black bars |
| Ambient | ⌘⇧2 | Slow and muted, for working |
| Reading | ⌘⇧3 | Steady warm white ~2700K, no screen tracking |
| Sound + Movie | ⌘⇧4 | Picture colour, pulsed by system audio |
| Off | ⌘⇧0 | Lamp off |

The last mode is remembered across restarts, and quitting turns the lamp off
rather than leaving it frozen on the last frame. Engine output goes to
`~/Library/Logs/Ambilight.log` (menu: **Open Log**).

Build it with `./build.sh`, which also runs the self-test and verifies the
bundle. But read the next section first.

### Screen Recording permission — two traps

**The app must ask explicitly.** ScreenCaptureKit does *not* raise the
permission prompt by itself; `Runner.start` calls
`CGRequestScreenCaptureAccess()` first. Without that call the stream just fails
with `declined` and no amount of toggling Settings helps, because the user was
never asked. If you ever see "The user declined TCCs" with the toggle visibly
on, check that call still exists.

**Never run the engine as a child process of the app.** macOS attributes a
capture request to the binary that makes it. An earlier version spawned the CLI
from the app; a bare executable inside a bundle has no grantable TCC identity,
so it was refused no matter what was toggled for the app. That is why the app
links `Engine.swift` directly instead of shelling out, and why the bundle
contains no helper binary.

**Rebuilding invalidates the grant.** The app is ad-hoc signed, so every build
changes its code hash and macOS stops matching the Screen Recording entry.
Toggling the existing row off and on does **not** fix it — that flips a boolean
on a record still keyed to the old hash. What works:

```bash
pkill -f Ambilight.app/Contents/MacOS/Ambilight
tccutil reset ScreenCapture local.ambilight.menubar
```

Then in System Settings → Privacy & Security → **Screen & System Audio
Recording**, click `+`, add `Ambilight.app`, and relaunch. Batch your code
changes into one build to go through this once, or sign with a real developer
certificate to make the identity stable and avoid it entirely.

**The Settings dialog lags.** When you flip that toggle, the confirmation sheet
describes the *previous* state, not the new one. Trust the toggle colour, not
the sentence.

Grant it in the **"Screen & System Audio Recording"** section — the
**"System Audio Recording Only"** list below it is a different permission and
does not allow screen capture.

### Known gap

The engine writes BLE status (`ble: connected`, write rates) to stderr, which
the app does not capture into its log. The log therefore shows that capture
started but not whether the lamp is being driven. The CLI shows both.

---

## Tuning

### Presets

```bash
./ambilight --ble MELK --profile calm       # slow, muted, dimmer
./ambilight --ble MELK --profile balanced   # default
./ambilight --ble MELK --profile punchy     # fast, vivid, reactive
./ambilight --ble MELK --profile movie      # for watching things
```

| | smoothing | saturation | normalize | brightness | rate | deadband |
|---|---|---|---|---|---|---|
| calm | 0.08 | 1.40 | 0.55 | 0.75 | 10/s | 6 |
| balanced | 0.18 | 1.70 | 0.70 | 1.00 | 15/s | 4 |
| punchy | 0.45 | 2.20 | 0.85 | 1.00 | 20/s | 2 |
| movie | 0.30 | 1.90 | 0.50 | 0.90 | 20/s | 3 |

`movie` also enables letterbox detection, and deliberately uses a *lower*
normalize than `punchy`: films use darkness on purpose, and lifting every night
scene to full brightness fights the thing you are watching.

### Sound-reactive mode

The controller has an onboard mic and animates itself per-pixel at full speed
when enabled — no BLE traffic at all. Toggle it from the Mac instead of the
phone app:

```bash
./ambilight --ble MELK --mic 128    # on, sensitivity 0-255
./ambilight --ble MELK --mic-off
```

It does not follow screen color — it is a different effect, not a better version
of this one. Running the normal color stream afterwards takes the lamp back.

That it works per-pixel at full frame rate is worth noting: the strip and the
controller are both capable of real animation. The 9-byte command channel is the
only thing limiting this project to a single color.

### Controller commands

Eleven commands exist in the protocol; the colour stream uses four. The rest are
one-shot and compose freely:

```bash
./ambilight --ble MELK --scene 24               # on-device scene (Fire)
./ambilight --ble MELK --mode 3 --speed 200     # Breathe, fast
./ambilight --ble MELK --warm 200,60            # warm/cold white mix
./ambilight --ble MELK --set-brightness 180
./ambilight --ble MELK --timer 1800             # auto-off in 30 min (0 cancels)
./ambilight --ble MELK --sensor on --sensor-delay 60
```

`--dry-run` prints the frames instead of sending them, which is how the byte
layouts above were checked against the spec.

### What actually works on a MELK-OA10 — tested, not assumed

The reverse-engineering sources list commands but were never verified against
hardware. These results come from driving a real MELK-OA10:

| Command | Result |
|---|---|
| `COLOR` (5) | **Works.** Solid colour, whole strip. |
| `BRIGHTNESS` (1) | **Works.** Independent of colour. |
| `MODE` (3) | **Works** — Strobe and Breathe both animate on-device. |
| `MIC_ON_OFF` (7) | **Works** (on-board mic). |
| `SET_SCENE` (0x31) | **No effect.** All 28 documented scene IDs accepted silently, nothing renders. |

**The finding that matters: `MODE` ignores the colour you set.** Tested by
setting the strip solid green, then starting Breathe: it pulsed red, then
purple. It runs its own hue cycle regardless of `COLOR`. (An earlier reading
suggested otherwise — that was the *next* `COLOR` command in the test sequence
overriding the mode back to solid, which made the two look connected. Hold each
stage long enough that nothing else lands during it.)

So on-device motion and screen-matched colour are mutually exclusive: you get
one or the other, never both. `MODE` is a standalone effect like mic mode —
useful as a manual preset, useless for following a picture.

**Conclusion: the colour stream is the ceiling on this hardware.** One flat,
accurate colour at ~15 Hz is the best a MELK-OA10 can do for bias lighting.
Colour *with* motion, or per-zone colour, requires replacing the controller —
see the ESP32 section.

Scene IDs are left in the CLI (`--scene`, `--catalogue`) in case another unit in
this family implements them. The IDs come from the app's `ELKSymphonyScene` enum
and are probably for a different device class in the vendor's range.

### Sound + Movie

Screen colour with intensity driven by **system audio**, captured from the same
ScreenCaptureKit stream as the pixels. No microphone is involved, so fans,
keyboard and room noise cannot reach it — unlike the controller's own mic mode.

Intensity is baked into the RGB values rather than sent as a separate
`BRIGHTNESS` frame: one write per update instead of two, which matters against
a ~20 writes/sec ceiling.

```bash
./ambilight --ble MELK --profile movie --audio --audio-depth 0.45
```

**Two bugs worth remembering if this is ever touched again:**

*Extraction silently failed.* `CMSampleBufferGetAudioBufferListWithRetained
BlockBuffer` returned `-12737` (ArrayTooSmall) on every buffer, so the level sat
at 0.00 forever and the lamp just went dim. The fix is the two-call pattern —
ask for `bufferListSizeNeededOut` first, allocate exactly that, and **zero the
memory**, since garbage in `mNumberBuffers` causes the same error even when the
allocation is generously large. The list only needs 40 bytes.

*A linear map sat dim.* With `k = (1 - depth) + depth * level`, a film spends
most of its time in the bottom half of the range. A square-root curve on the
level, with depth 0.45, keeps typical content at 78-90% brightness and floors
silence at 55% instead of 40%.

The `audio` figure in the status line prints `EXTRACT-FAIL=n` if buffers ever
stop yielding samples again.

### Corrections from a second protocol source

[wporter82/lotus-lamp-python](https://github.com/wporter82/lotus-lamp-python),
tested against a MELK-OA10 5F, contradicts or extends the first source:

- **The `len` byte is not constant.** `SPEED` uses `04`, not `07`, and the clock
  command uses `06`. Our `--speed` was sending the wrong frame, which is the
  likely reason it never visibly did anything.
- **`MODE` has ~213 animations, not 4**, grouped into categories (trans, tail,
  water, curtain, run, flow). Only 1-4 were previously documented. They still
  ignore `COLOR`, so they cannot follow the screen — but there is far more there
  than Jump/Strobe/Breathe/Warning.
- **Measured safe write rate is ~10/sec**, below our 15-20 ceiling. The deadband
  means we rarely sustain that, but it is worth knowing.
- **Do not send a zero `len` byte.** `7E 00 05 ...` and `7E 00 06 ...` are
  reported to freeze the lamp until it is power-cycled.
- Two new opcodes: `0x82` timer schedule, `0x83` clock sync.
- That source has no `MIC`, `SET_SCENE`, `0x40`, `0x76` or `0x87`, so our notes
  remain broader on effects.

### Letterbox detection

A 2.35:1 film on a 16:9 monitor is about 20% black bars. Sampling those drags
the average toward black, and `--normalize` then amplifies whatever noise is
left. With `--letterbox` (on by default in the `movie` profile) the picture area
is found per frame and only that is sampled. It handles horizontal bars, 4:3
pillarboxing, and a windowed player with bars on all four sides.

Bounds expand instantly but contract over ~3 seconds, so a dark scene is never
mistaken for a wider bar — bars are permanent, dark scenes are not. A frame that
is almost entirely black is rejected outright and the previous bounds are kept.

Check the logic any time with:

```bash
./ambilight --selftest
```

Any flag you pass by hand overrides the preset, so you can start from one and
adjust a single knob:

```bash
./ambilight --ble MELK --profile punchy --brightness 0.6
```

### Individual knobs

| Flag | Default | |
|---|---|---|
| `--normalize` | 0 (BLE: 0.7) | Lifts dim screens to usable brightness while preserving hue. Without it, gamma crushes an ordinary desktop to near-black and the lamp looks dead. |
| `--region` | 0.4 (BLE: 1.0) | Top fraction of screen sampled. |
| `--smoothing` | 0.35 (BLE: 0.18) | Higher is snappier. |
| `--saturation` | 1.35 (BLE: 1.7) | Averaging pulls toward grey; this pushes back. |
| `--brightness` | 1.0 | Master scale. |
| `--gamma` | 2.2 | Lower if dark scenes vanish. |
| `--vividness` | 0.6 (movie 0.75) | Weights saturated pixels over grey ones. A flat mean is dominated by grey UI and dark background, which is what makes averaged screen colour look muddy. 0 = plain mean. |
| `--cut` | 0.22 (movie 0.18) | Scene-cut sensitivity. On a cut the smoothing is bypassed for one frame so the lamp snaps rather than sliding through a colour that appears in neither shot. Lower = snappier. |
| `--display` | 0 | Which monitor to follow. |
| `--preview` | off | Draw the computed colors in the terminal. |

BLE mode auto-adjusts region/saturation/smoothing/normalize as shown; anything
you pass explicitly wins.

### Picking the display

`--display 0` is whichever macOS calls the main display. Check with:

```bash
system_profiler SPDisplaysDataType | grep -A3 Resolution
```

### Run it on login

```bash
cat > ~/Library/LaunchAgents/local.ambilight.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.ambilight</string>
  <key>ProgramArguments</key>
  <array>
    <string>REPLACE_WITH_ABSOLUTE_PATH/ambilight</string>
    <string>--ble</string><string>MELK</string>
    <string>--profile</string><string>balanced</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
EOF
launchctl load ~/Library/LaunchAgents/local.ambilight.plist
```

---

## Upgrading to per-zone (ESP32 + WLED)

Only worth it if one color stops being enough. Cut the dongle off, keep its USB
cable for 5V, and solder on an ESP32 running [WLED](https://kno.wled.ge):

```
  ESP32 GPIO2  ──[330Ω]──────────────►  strip DIN
  ESP32 GND    ─────────────┬────────►  strip GND
  USB 5V  ──────────────────┼────────►  strip 5V
                       [1000µF]
```

Three rules that cause most failures:

1. **GND must be common** between ESP32 and strip.
2. **Inject 5V straight from the USB cable**, not through the ESP32's 5V pin.
3. **Observe the arrow** on the strip — DIN is the upstream end.

WS2812B pulls up to 60mA/LED at white, so 30 LEDs = 1.8A, already over a USB
port. Don't guess: enable WLED's **Automatic Brightness Limiter** and set max
current to your supply's real limit. It scales brightness itself and can't
overdraw.

The ESP32's 3.3V data line is marginal against the WS2812B's ~3.5V threshold. If
you see flicker, put a 1N4001 in series with the strip's 5V (dropping it to
~4.3V lowers the threshold to ~3.0V), or add a 74AHCT125 level shifter.

Flash at <https://install.wled.me> in **Chrome or Edge** (needs WebSerial; Safari
won't work), set LED count and type, enable the current limiter, then:

```bash
./ambilight --host wled.local --leds 30
```

---

## Tools

`tools/blescan.swift` — lists nearby BLE devices; `--connect <substring>` dumps a
device's full GATT table. Useful if the controller is ever replaced.

`tools/colortest.html` — cycles red/green/blue/white fullscreen, for confirming
the lamp tracks screen color.

## Notes

The WLED backend uses the DRGB realtime protocol: byte 0 = `2`, byte 1 = timeout
seconds, then RGB triplets. The 2-second timeout means WLED reverts to its own
effects shortly after this stops, so quitting restores your normal lighting
instead of freezing the last frame. DRGB caps at 490 LEDs per packet.

Capture resolution is derived from the display's aspect ratio. This matters:
ScreenCaptureKit letterboxes a mismatched frame, and those black bars land on
the first and last zones, leaving both ends of the strip permanently dark.
