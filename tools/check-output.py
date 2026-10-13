#!/usr/bin/env python3
"""Exercise actual CLI UDP output on localhost, without capture or physical LEDs."""
import signal
import socket
import subprocess
import time
from pathlib import Path


def check(name, layout, pixels, extra=()):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
        receiver.bind(("127.0.0.1", 0))
        receiver.settimeout(4)
        executable = Path(__file__).resolve().parents[1] / "ambilight"
        command = [str(executable), "--host", "127.0.0.1", "--port",
                   str(receiver.getsockname()[1]), "--leds", str(len(pixels)),
                   "--layout", layout, "--test", *extra]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            expected = bytes([2, 2] + [channel for pixel in pixels for channel in pixel])
            first, _ = receiver.recvfrom(2048)
            assert first == expected, f"{name}: wrong initial packet {first.hex()}"
            started = time.monotonic()
            for _ in range(2):
                packet, _ = receiver.recvfrom(2048)
                assert packet == expected, f"{name}: heartbeat changed pixels"
            elapsed = time.monotonic() - started
            assert 0.6 < elapsed < 3, f"{name}: unexpected static heartbeat interval {elapsed:.2f}s"
            process.send_signal(signal.SIGTERM)
            black = bytes([2, 255] + [0] * (len(pixels) * 3))
            deadline = time.monotonic() + 3
            received_black = False
            while time.monotonic() < deadline:
                packet, _ = receiver.recvfrom(2048)
                if packet == black:
                    received_black = True
                    break
                assert packet == expected, f"{name}: unexpected shutdown packet"
            stdout, stderr = process.communicate(timeout=4)
            assert received_black, f"{name}: no final held-black packet"
            assert process.returncode == 0, f"{name}: {stderr or stdout}"
            print(f"PASS {name}: pixel order, static heartbeat, SIGTERM blackout and exit")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    red, green, blue, yellow = (64, 0, 0), (0, 64, 0), (0, 0, 64), (64, 64, 0)
    check("four regions with odd bar lengths", "four", [red, red, green, green, blue, blue, yellow])
    check("swapped and reversed bar sections", "four", [yellow, yellow, blue, blue, green, red, red],
          ("--swap-sides", "--reverse-left", "--reverse-right"))
    check("independent left/right", "sides", [red] * 3 + [blue] * 3)
