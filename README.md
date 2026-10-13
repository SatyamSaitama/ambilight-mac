# Ambilight for Mac

Screen-reactive bias lighting for macOS. A menu bar app follows the film on your screen and drives a LotusLamp X / MELK Bluetooth LED controller (such as the Xergy 270° bars) or a WLED installation. Requires macOS 13 or newer and Apple's Swift compiler to build.

Earlier versions are tagged: `v0` is the first working build, `v1.1` the cinematic rewrite.

## Start

```sh
./build.sh
open Ambilight.app --args --settings
```

The build compiles both targets, runs the regression suite, signs the local app, and preserves the previous app in `backups/Ambilight-v0.app` on the first build. The v0 source snapshot is commit `b6f6005`.

Choose **Movie** and **Shared BLE controller** for a two-bar, one-controller setup. **Whole picture** is the default layout, so a flash mid-frame registers. In **Picture source**, refresh and select the external monitor or movie-player window. Close LotusLamp X if it is holding the Bluetooth connection. The first matching controller is saved by UUID; **Find lights** lets you select a specific controller before applying settings.

Allow Ambilight in macOS **Privacy & Security → Screen & System Audio Recording** (the top list, not *System Audio Recording Only*) and **Bluetooth** if macOS asks.

The app is ad-hoc signed, so **every rebuild invalidates the Screen Recording grant**, and toggling the existing entry off and on does not fix it: that flips a switch on a record still tied to the old build. What works is to quit the app, run `tccutil reset ScreenCapture local.ambilight.menubar`, add `Ambilight.app` again with **+**, and relaunch. Batch changes into one build to do this once. Protected streaming video can be black in screen capture even when the desktop works; test the actual player. Capture frames and audio are processed locally; the app sends only RGB lighting data.

## Movie improvements

- Whole-picture or picture-edge sampling, computed before gamma and brightness correction.
- Display, player-window, and normalized manual crop selection; stable letterbox/pillarbox bounds through dark shots.
- A lower central mask reduces subtitle influence. It is a geometric mask, not text recognition.
- Time-based smoothing, prompt scene-cut updates, black hysteresis, and bounded brightness lift preserve dark scenes.
- Saved brightness, saturation, response, gamma, edge depth, audio depth, and RGB channel gains.
- Live output-colour swatches, capture/processing metrics, connection state, and measured BLE colour writes per second. UDP delivery is explicitly unconfirmed.
- Persistent controller IDs, automatic reconnect, a latest-colour buffer, paced BLE writes, and asynchronous shutdown.
- Reading is steady warm white; Off turns the selected output off. Sound + Movie adds subtle intensity response to captured system audio.
- **Brightness envelope:** colour follows the response time, but brightness rises in about 50 ms and falls over the **Afterglow** time. A flash on screen lights the room at once and then fades out, instead of blinking off. Scene cuts snap the colour but ease brightness down. Fades below one 8-bit step finish, so the lamp really goes dark.
- **Lamp-side dimming:** the controller's own brightness command sets the master level and colour is sent at full range, leaving more steps for dark scenes. Full brightness is restored when the app shuts down.
- **Dominant colour:** each pixel is weighted by how common its hue is in the frame, so a sunset stays warm instead of averaging orange sky and purple cloud into mauve. It changes colour only, never brightness.
- **Scene-aware response:** a coarse motion grid makes quiet scenes drift slowly with a longer afterglow, and busy ones track quickly. Flashes always land at once, and cuts are not counted as motion.

Default recipe: **Whole picture**, brightness **100%**, saturation **1.50**, dark-scene lift **20%**, response **250 ms**, afterglow **800 ms**, gamma **1.60**, subtitles and border detection enabled, dominant colour and scene-aware response on. **Reset** returns here. Audio is off in Movie. The BLE rate ceiling starts at **15/s**; compare **10/s** or **5/s** if motion stutters. Measured writes can be lower because unchanged colours are suppressed. These are tuning starting points, not a hardware latency guarantee.

Hide both light bars behind the monitor from your seated position, including the exposed sections below it. Aim their light at the wall and adjust spacing until both reflected washes are balanced. Reduce brightness if the wall distracts from the picture.

## When does it capture?

Capture is gated by a check of the window list once a second. That check reads window names and positions only and never captures anything itself.

- **Movie modes follow only while a video player is the top window on the movie display:** Stremio, QuickTime, TV, IINA, VLC, Infuse, Plex, or a browser tab on YouTube, Twitch, Vimeo or Stremio. It goes by the top window on that display, not the frontmost app, so a film on the monitor keeps being followed while you type on the laptop. A specific player window chosen as the source is followed wherever it is. The rest of the time the screen-recording indicator is off and the lamp shows a resting colour: **dim warm glow**, **off**, or **the last colour**.
- **Remote desktops pause capture in every mode.** Citrix and similar clients blank their own session while any app is capturing the screen. They react to an *active* capture, not to the permission. Their windows are also excluded from every captured frame.
- **DRM video is never captured.** Netflix, Prime Video, Disney+, Hotstar, JioCinema, SonyLIV, ZEE5, Crunchyroll, Apple TV+ and the TV app protect their video from capture. Safari shows it to you but black to capture: Crunchyroll read 0–3 out of 255 throughout playback. Chrome goes further and blacks it out for the viewer while any capture runs. So while one is visible, the app stays out of the way and says so in the menu.

The lists can be extended without rebuilding:

```sh
defaults write local.ambilight.menubar extraPlayers -array com.example.player
defaults write local.ambilight.menubar extraTitleKeywords -array "MySite"
defaults write local.ambilight.menubar extraProtectedKeywords -array "SomeDRMSite"
defaults write local.ambilight.menubar extraRemotePrefixes -array com.example.vdi
```

## Which colours can the bars show?

| Output | Live picture mapping | Requirement |
|---|---|---|
| Shared Xergy / MELK BLE controller | One representative colour on both bars | Current confirmed wiring |
| Two independent BLE controllers | Left edge on one bar, right edge on the other | Two distinct compatible controller UUIDs |
| WLED | Shared colour, left/right, or four upper/lower sections | An already-compatible addressable LED installation |

The physical bars can show multicolour RGBIC presets. That does **not** establish arbitrary live section control. No verified per-bar or per-section command was found for this shared Xergy controller. The app therefore rejects unsupported BLE layouts instead of simulating two independent outputs. A second connection to the same UUID does not create another bar output.

The current BLE transport uses service **FFF0**, writable characteristic **FFF3**, and the known whole-controller colour frame:

```text
7E 07 05 03 RR GG BB 10 EF
```

The nine-byte format alone does not prove that segment control is impossible. Observing a real LotusLamp X segment command on this exact hardware would be needed to add it. See the [research and immersion plan](IMMERSION_PLAN.md), [Xergy product listing](https://xergy.in/products/270-rgbic-ambient-table-lamp-pack-of-2), [LotusLamp X listing](https://play.google.com/store/apps/details?id=com.szelk.ledlamppro), and [tested protocol notes for another MELK-OA10 lamp](https://github.com/wporter82/lotus-lamp-python/blob/main/docs/PROTOCOL.md).

Do not cut or replace the stock controller based on RGBIC branding. The actual chipset, voltage, pixel order, accessible data inputs, and bar wiring remain unverified. WLED support here is a software backend for compatible hardware, not proof these bars can be retrofitted. Consult [WLED compatibility](https://kno.wled.ge/basics/compatible-led-strips/) and [multiple-output documentation](https://kno.wled.ge/features/multi-strip/) before planning a hardware change.

## CLI examples

```sh
# Existing shared controller, cinematic defaults
./ambilight --ble MELK --profile movie --layout perimeter

# List capture sources or passively discover lights
./ambilight --list-sources
./ambilight --list-devices

# Capture a player window; use the ID printed by --list-sources
./ambilight --ble MELK --profile movie --window 12345

# Crop to the central 80% of a source
./ambilight --ble MELK --profile movie --crop 0.1,0.1,0.8,0.8

# Compatible WLED: 30 total pixels, left bar followed by right bar
./ambilight --host wled.local --leds 30 --profile movie --layout four

# Modest-brightness static mapping check, no capture; Ctrl-C turns it off
./ambilight --host wled.local --leds 30 --layout four --test

# Hardware-free regression suite
./ambilight --selftest
```

For two independent BLE controllers, specify `--ble MELK --device-id <left-uuid> --right-device-id <right-uuid> --layout sides`. UUID placeholders must be replaced by two different real controller IDs. `--swap-sides` routes picture sides to the opposite outputs. With WLED, `--reverse-left` and `--reverse-right` change pixel direction, and `--left-gain r,g,b` / `--right-gain r,g,b` calibrate each physical bar. Shared BLE uses the left gain for both bars.

WLED pixel order is left bar first, then right, each top to bottom. Odd total counts give the left bar the extra pixel; odd bar lengths give the upper section the extra pixel. Configure WLED outputs to match that virtual pixel order. The CLI also retains `--layout columns` for horizontal strips. Use `--help` for the complete option list and advanced one-shot controller commands. Raw/scene commands are not proof of new hardware capabilities.

## Validation and tools

`tools/immersion-test.html` is a local manual test page: left/right colours, four corners, dark scenes, subtitles, a bright centre, black, and neutral grey. Keys **1–7** select scenes; **S** swaps sides; **F** enters fullscreen. It contains no automatic flashing. Test aspect changes and your actual movie source separately.

`./build.sh` runs synthetic checks for region sampling, crop, calibration, odd pixel counts, reversal/swapping, dark-scene preservation, subtitle suppression, time-based response, picture bounds, and invalid configurations. `open -n Ambilight.app --args --ui-preview` shows settings with illustrative swatches and disables capture, Bluetooth connections, and UDP output. It is for interface verification; saving still changes preferences.

`tools/check-output.py` checks the actual CLI's WLED packets on localhost and graceful shutdown without external hardware. It is a developer check, not an LED or Bluetooth latency measurement.

The WLED backend sends [DRGB realtime packets](https://kno.wled.ge/interfaces/udp-realtime/) on UDP port 21324 by default, up to 490 pixels. A heartbeat holds static output between frames. Off, sleep, and graceful quit send black with timeout 255 so WLED stays dark until a new request. UDP has no acknowledgement; a ready sender does not prove physical delivery. WLED's own brightness and gamma settings also affect the final colour.

Source is shared by both targets: `Engine.swift`, `Configuration.swift`, `Cinema.swift`, `Output.swift`, and `Gate.swift`. `main.swift` supplies the CLI and `app/MenuBarApp.swift` the native settings/menu. The old duplicate `ambilight.swift` was removed so fixes cannot diverge. Logs are at `~/Library/Logs/Ambilight.log`.

Software validation does not replace visual calibration on your wall. Stock BLE latency, real four-section hardware behaviour, HDR colour fidelity, and full-length movie/sleep-wake endurance require hands-on testing.

## Licence

MIT. See [LICENSE](LICENSE).
