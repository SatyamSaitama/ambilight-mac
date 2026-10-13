# v1.1 validation — 13 October 2026

Built on macOS 26.6.2 with Swift 6.3.3. Both optimized targets compile successfully; the menu app's property list and local code signature validate.

## Automated checks passed

- **40 synthetic/regression checks** in `./build.sh`: picture borders, whole/perimeter/left-right/four-region sampling, subtitle masking, crop, calibration after swapping, odd pixel lengths and direction reversal, chroma/luminance separation, consistent response at 30/60 fps, zero-response updates, dark-scene hysteresis, stable picture bounds, sparse horizontal-strip interpolation, and configuration validation.
- The actual asynchronous output clock was tested without capture or lamps: one static sample settles, a single black sample completes its fade, and stopping a handler cancels later writes.
- **Three localhost UDP integration cases** in `python3 tools/check-output.py`: four regions with odd bar lengths, swapped/reversed sections, and independent left/right. Each checks the exact DRGB bytes, static heartbeat, final held-black packet, and successful SIGTERM exit.
- CLI checks reject shared BLE four-section mode, zero capture rate, invalid source IDs, and non-finite brightness. Dry-run SPEED uses its corrected `7E 04 02` header. Non-finite command delay is covered by the regression suite.
- `git diff --check` passes.

## Native interface checked

Inspected all four settings tabs using the hardware-inactive UI preview. Controls fit the window. Shared BLE offers only Whole picture and Picture edges; right-controller/gain and bar-direction controls are disabled. Two-controller mode selects left/right and rejects missing/distinct-ID errors. WLED enables its host/pixel fields and offers four bar segments. The BLE rate ceiling is disabled for WLED. Brightness/response values and calibration fields display correctly.

Normal startup opens Settings. Standard Command-Q was tested and exits successfully. Settings are versioned and validated before starting capture or connecting outputs. The previous app binary is retained at `backups/Ambilight-v0.app`, and the v0 source remains at commit `b6f6005`.

## Current machine limitation

The rebuilt app reports that macOS is denying Screen Recording access. No usable live movie capture or physical BLE output was therefore validated during this implementation. Enable/renew Ambilight in **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and reopen the app. Allow Bluetooth if requested and select the intended source/controller. Settings is left open for this step.

Stock-controller segment commands remain unverified. No custom half-bar or independent-bar support is claimed for the shared Xergy cable/controller. The implemented two-controller and WLED mappings were checked in software; physical colour order, BLE delay/rate, HDR appearance, actual protected-player capture, long playback, and sleep/wake endurance remain hands-on checks. Use `tools/immersion-test.html` and the acceptance checks in `IMMERSION_PLAN.md`.
