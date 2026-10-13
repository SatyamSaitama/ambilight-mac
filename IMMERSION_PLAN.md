# Xergy 270° movie immersion plan

Researched 13 October 2026. The proposal below records the original investigation; implementation status is recorded next.

## Implementation status — v1.1

Implemented the software phase for the confirmed shared-controller setup: native saved settings, source/window/crop selection, whole/perimeter sampling before colour correction, restrained Movie defaults, subtitle mask, dark-scene preservation, time-based response, live colour/status diagnostics, saved BLE IDs, reconnection/pacing, RGB calibration, and asynchronous shutdown. Two distinct BLE controllers can use left/right routing; compatible WLED hardware can use four regions with swapping and bar direction controls.

No arbitrary segment command was verified for the stock shared controller. Separate colours on its two bars or halves remain an investigation, not an enabled stock feature. The app explicitly limits shared BLE to one live colour. No controller was cut, rewired, or purchased. Placement remains a physical adjustment for the user.

Build and synthetic test results, interface verification, and output checks are documented in README.md and VALIDATION.md. Tests on real movie playback, physical lamp delay, HDR fidelity, and full-length sleep/wake endurance remain manual acceptance checks. The original findings and proposed phases follow.

## Recommendation

The user confirmed that both bars share one controller/cable and movies play on this Mac or its connected monitor. First improve placement and cinematic colour processing. Run a bounded investigation of whether that shared controller exposes independent outputs/sections. The current global-colour command cannot give the two bars different colours. Aim for four mapped regions (upper/lower left and upper/lower right) only after proving section control, or through a compatible ESP32/WLED retrofit if stock control cannot deliver it.

Playback on the Mac/external monitor matches the existing capture architecture. Test the actual player/service before buying hardware; a successfully captured desktop is not proof that every movie source supplies usable frames.

## What is established

| Evidence | Finding | Limit |
|---|---|---|
| User's IMG_7563.HEIC | Both bars show multiple vertical colour regions at the same time. | Does not establish arbitrary colour assignment, separate controller outputs, or pixel-streaming support. |
| User's IMG_7561.HEIC | Two upright bars are behind the external monitor; illuminated sections are visible below it. | Photos do not reveal the full cable/controller topology. |
| User clarification | Both bars share one controller/cable. Movies play on this Mac or its attached monitor. | A shared controller may have mirrored or independently driven data outputs; the internal wiring remains unverified. |
| [Exact Xergy listing](https://xergy.in/products/270-rgbic-ambient-table-lamp-pack-of-2) | Markets 15 RGBIC LEDs, 270° diffusion, 5V USB/5W, two lamps, app/IR/buttons and microphone effects. | Does not document independent bar or segment addressing. Confirm LED count and power rating for the actual unit before modification. |
| [Official LotusLamp X listing](https://play.google.com/store/apps/details?id=com.szelk.ledlamppro) | Supports RGB/RGBIC devices, colour, brightness, effects and audio rhythm inputs. | Music sync does not establish image sync or an arbitrary pixel API. |
| Project README | Records MELK-OA10/FFF0/FFF3 identification and successful global-colour tests on this setup. | These are previous project observations, not hardware tests rerun during this research. |
| Current source | One BLE peripheral; all calculated zones reduced to one RGB value. | No left/right controller routing or segment command implemented. |

The distinction is LED capability versus controller access. RGBIC explains the multicolour pattern in the photo; the application still needs a command that specifies *where* each colour goes.

## Can each bar or half-bar show a different colour?

- **Current shared controller:** separate bar colours are possible only with a verified command for selecting independently addressable outputs/sections. The current global-colour frame contains no implemented destination selector. Adding a second software connection to the same controller would not create an independent output.
- **Two separate BLE controllers, as a future alternative:** independently setting one bar red and the other blue is feasible with the known global-colour command, subject to matching controller compatibility. The desktop app would need two connections and saved peripheral IDs. This is not the user's current wiring.
- **One controller feeding both bars through the same parallel data signal:** corresponding pixels will mirror. Independent bars would require separate data outputs/wiring or controllers. The photos do not prove this wiring arrangement.
- **Two colours within one bar:** physically demonstrated by the preset, but custom static halves and screen-driven halves remain unverified on the stock controller.

The known colour frame is `7E 07 05 03 RR GG BB 10 EF` to BLE characteristic FFF3. Both [l0lsec's implementation](https://github.com/l0lsec/LotusLampX/blob/main/cli/protocol.py) and [wporter82's tested protocol notes](https://github.com/wporter82/lotus-lamp-python/blob/main/docs/PROTOCOL.md) expose global colour; neither provides a verified arbitrary segment API for this Xergy pair. The latter was tested on another branded MELK-OA10 lamp, so timings and ancillary commands must not be assumed identical.

The existing README's claim that a nine-byte packet makes pixel control structurally impossible is too strong. A short packet could theoretically carry an index and RGB or select a region across multiple commands. The supported conclusion is: **no verified arbitrary segment command was found, and the current implementation only sends whole-controller colour.**

## Phase 1 — establish the control boundary

1. Temporarily stop desktop colour streaming and disconnect the phone app when another BLE client needs the connection.
2. Record the shared controller's peripheral ID and inspect its cable branches without modifying them. Determine whether available documentation or a non-destructive inspection identifies a mirrored data split, serial chain, or independent outputs. One shared cable alone does not answer this.
3. Establish a modest-brightness global-colour baseline: both bars should follow the known command. Treat separate left/right control as unproven until a static red/blue split can be demonstrated and reversed.
4. Inspect LotusLamp X while connected to this exact device for per-output, DIY, paint or segment controls. A pixel-count setting is not proof of segment painting.
5. If a native control can hold half-red/half-blue, record the app's corresponding local BLE writes and reproduce that observed command. Verify spatial order, persistence and update rate. Do not derive support from a rainbow animation or guess unknown configuration commands.
6. If no useful native control or documented command is found, time-box further protocol investigation. Proceed with proven global/dual-bar support rather than making the movie experience depend on an open-ended reverse-engineering effort.

Deliverable: a capability record containing endpoint IDs, bar assignments, verified global/segment commands, observed colour order and measured practical update rate.

## Phase 2 — improve the existing setup without purchasing anything

- Position one bar behind each side of the monitor, with their lit lengths centred vertically on the visible picture as closely as practical. Keep direct emitters hidden from the seated position, including the sections currently visible below the monitor. Use secure placement.
- Aim the emitting surfaces toward the wall. Start with roughly 10–20 cm of wall spacing if the desk allows, then adjust by eye until the two washes have comparable size and intensity. This is a tuning starting point, not an Xergy requirement.
- Clear objects from the light paths. Reduce the laptop screen's competing glow during movies. Prefer the plain wall around the monitor as the reflection surface; unequal wall colour or obstructions can be compensated only partly in software.
- Start around 25–40% application master brightness in a dark room and adjust downward if the wall attracts attention away from the picture. These are subjective starting values, not measured luminance targets.
- Use Movie mode for ordinary films. Leave audio modulation off initially; add a small amount only for concerts or action content if preferred. The controller's microphone patterns choose their own colours and do not reproduce the movie image.

Success: soft, balanced light around the picture, no exposed bright bar in the viewer's line of sight, and darkness still feels dark.

## Phase 3 — improve the application

The actual build is `Engine.swift + main.swift` for CLI and `Engine.swift + app/MenuBarApp.swift` for the menu app. The README's direct compile of `ambilight.swift` targets an older duplicate implementation.

### A. Spatial colour routing

Introduce explicit output capabilities: global colour, multiple global devices, or addressable pixels. Store a layout independently of transport.

- One available output: compute a stable representative colour from the selected picture perimeter, with a configurable whole-picture option.
- Two outputs: left bar follows the left picture edge; right follows the right edge. Start with the outer 15–25% of picture width and tune inward depth.
- Four outputs: split each side vertically into upper and lower regions. Map those to each bar's upper/lower LEDs; allow direction reversal.
- More outputs: consider three regions per bar only after evaluating four. Diffusion on a wall may blur extra regions, so more regions do not automatically improve immersion.

Keep capture resolution independent of output count. Currently `captureWidth = min(960, ledCount * 4)`; simply setting two LEDs would shrink analysis to eight pixels across. A starting analysis width of about 160–240 pixels with aspect-preserving height is more useful for a small number of zones; profile actual CPU use.

Reduce each region to its representative colour before output-specific correction. The current BLE path averages already-corrected stripe colours, which discards spatial identity and can muddy mixed-colour shots.

### B. Cinematic brightness and colour

Keep the existing letterbox/pillarbox detection, scene-cut handling, colour weighting and smoothing. Improve them rather than recreating them.

- Add GUI brightness, saturation, dark-scene lift and response controls with live zone previews.
- Reduce the current Movie defaults' aggressive saturation (1.90) and normalization (0.50) when tuning for films. Suggested A/B starting range: saturation 1.2–1.4, normalization 0.1–0.25, brightness 0.25–0.40. Calibrate gamma separately; these are proposed values, not validated settings.
- Use separate colour and luminance decisions so a small bright coloured object cannot make a mostly dark scene flood the room.
- Preserve black frames with hysteresis and controlled fade; avoid persistent near-black glow or threshold flicker.
- Make smoothing depend on elapsed time so the feel stays consistent if capture/output rates change. Preserve prompt scene-cut response without uncontrolled brightness jumps.
- Add per-bar RGB gain calibration and verify neutral grey/white against the wall. Explicitly validate the capture colour space and HDR-to-SDR behaviour before claiming accurate HDR matching.

### C. Capture source and reliability

- Provide monitor/player-window/region selection; the current app captures the entire selected display. Retain reliable picture-area detection and test subtitles and player controls.
- Persist peripheral IDs, not only the `MELK` substring. Keep one latest-colour buffer and connection state per device; do not reconnect for each frame.
- Expose actual lamp connection state, effective writes/second and reconnect failures. The present GUI's Running status only establishes that a capture stream exists.
- Benchmark 5, 10 and 15 colour writes per second per bar, then test 20 only if useful and stable. A configured ceiling is not a measured hardware capability.
- Repair asynchronous start/stop cancellation and the quit path: the menu app currently waits on the main thread while BLE callbacks also require that thread.
- Consolidate the legacy CLI source and update build guidance during implementation.

## Phase 4 — hardware path only if necessary

If arbitrary sections are unavailable over stock BLE and four regions remain the objective, investigate a WLED controller retrofit. WLED supports [multiple physical LED outputs](https://kno.wled.ge/features/multi-strip/) and [realtime RGB pixel data](https://kno.wled.ge/interfaces/udp-realtime/); the existing app already has a DRGB sender.

Before choosing components, identify the actual LED chipset/protocol, voltage, accessible data input, pixel count, colour order and bar wiring. Compare with [WLED's compatibility list](https://kno.wled.ge/basics/compatible-led-strips/). RGBIC branding alone does not prove WS2812 compatibility.

For a compatible retrofit, prefer an enclosed controller with appropriate level shifting and separate data outputs for the two bars. A parallel split from one data pin would retain mirrored pixels. Supply and protection must match the verified load; software current limiting is not a substitute for proper electrical design. Do not cut the original controller before establishing compatibility and a complete wiring plan.

Target 30–60 updates/second for a short compatible pixel installation, then measure. Existing horizontal-column sampling must still be replaced by the vertical-bar layout above. If the bars use an unsupported/proprietary interface, preserve them for ambience and use a known compatible light assembly for screen zones.

## Acceptance checks

| Check | Expected result |
|---|---|
| Left red/right blue, then swapped | Correct bar changes; other bar retains its own colour. |
| Four different corner/side-region colours | Four physical sections match, with no reversed bar order. Required only for a claimed four-zone mode. |
| Slow colour pan | Colour moves smoothly with the picture; no stale queued colours. |
| Hard cut | Prompt update without an extended unrelated intermediate hue. |
| Dark shot and complete black frame | No bright room wash, near-black pumping or stuck output. |
| White subtitles on dark footage | Text does not repeatedly whiten the wall. |
| Letterbox, pillarbox and aspect changes | Active-picture mapping remains stable. |
| Actual movie service/player | Usable picture frames are available for that source. |
| Screen and lights filmed together | Measure visible delay and left/right skew; use results to select rate/smoothing. Aim for under roughly 100–150 ms if the stock hardware allows; this is a design target, not a promise. |
| Full-length playback, sleep/wake and app restart | No unintended device swaps, persistent disconnects or duplicate capture sessions. |

Implementation order for this shared-controller pair: placement and cinematic tuning → bounded shared-controller section check → source/connection reliability → verified section routing if available; otherwise compatible hardware investigation → four-region mapping and calibration.
