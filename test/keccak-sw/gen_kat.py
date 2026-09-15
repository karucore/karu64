"""Emit the pinned independent SHAKE known answers (stdout only)."""
import hashlib

for rate, shake in ((168, hashlib.shake_128), (136, hashlib.shake_256)):
    message = bytes((17 * i + 3) & 255 for i in range(3 * rate))
    expected = shake(message).digest(3 * rate)
    print(f"static const uint8_t expected{rate}[{len(expected)}] = {{")
    for start in range(0, len(expected), 16):
        print("    " + "".join(f"0x{x:02x}," for x in expected[start:start + 16]))
    print("};")
