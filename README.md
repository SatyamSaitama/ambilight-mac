# Ambilight v1.1

Native macOS movie lighting for the Xergy / LotusLamp X bars, with a menu app and a shared CLI engine. Requires macOS 13 or newer and Apple's Swift compiler to build.

## Start

```sh
./build.sh
open Ambilight.app --args --settings
```

The build compiles both targets, runs the regression suite, signs the local app, and preserves the previous app in `backups/Ambilight-v0.app` on the first build. The v0 source snapshot is commit `b6f6005`.

Choose **Movie**, **Shared BLE controller**, and **Picture edges** for this two-bar, one-controller setup. In **Picture source**, refresh and select the external monitor or movie-player window. Close LotusLamp X if it is holding the Bluetooth connection. The first matching controller is saved by UUID; **Find lights** lets you select a specific controller before applying settings.

Allow the existing Ambilight app in macOS **Privacy & Security → Screen & System Audio Recording** and **Bluetooth** if macOS asks. A locally rebuilt app may need its existing permission renewed and a relaunch. Protected streaming video can be black in screen capture even when the desktop works; test the actual player. Capture frames and audio are processed locally; the app sends only RGB lighting data.

## Movie improvements

- Whole-picture or picture-edge sampling, computed before gamma and brightness correction.
- Display, player-window, and normalized manual crop selection; stable letterbox/pillarbox bounds through dark shots.
- A lower central mask reduces subtitle influence. It is a geometric mask, not text recognition.
- Time-based smoothing, prompt scene-cut updates, black hysteresis, and bounded brightness lift preserve dark scenes.
- Saved brightness, saturation, response, gamma, edge depth, audio depth, and RGB channel gains.
- Live output-colour swatches, capture/processing metrics, connection state, and measured BLE colour writes per second. UDP delivery is explicitly unconfirmed.
- Persistent controller IDs, automatic reconnect, a latest-colour buffer, paced BLE writes, and asynchronous shutdown.
- Reading is steady warm white; Off turns the selected output off. Sound + Movie adds subtle intensity response to captured system audio.

Recommended starting recipe: brightness **35%**, saturation **1.30**, dark-scene lift **18%**, response **120 ms**, gamma **1.60**, edge depth **20%**, subtitles and border detection enabled. Audio is off in Movie. The BLE rate ceiling starts at **15/s**; compare **10/s** or **5/s** if motion stutters. Measured writes can be lower because unchanged colours are suppressed. These are tuning starting points, not a hardware latency guarantee.

Hide both light bars behind the monitor from your seated position, including the exposed sections below it. Aim their light at the wall and adjust spacing until both reflected washes are balanced. Reduce brightness if the wall distracts from the picture.

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

Source is shared by both targets: `Engine.swift`, `Configuration.swift`, `Cinema.swift`, and `Output.swift`. `main.swift` supplies the CLI and `app/MenuBarApp.swift` the native settings/menu. The old duplicate `ambilight.swift` was removed so fixes cannot diverge. Logs are at `~/Library/Logs/Ambilight.log`.

Software validation does not replace visual calibration on your wall. Stock BLE latency, real four-section hardware behaviour, HDR colour fidelity, and full-length movie/sleep-wake endurance require hands-on testing.
