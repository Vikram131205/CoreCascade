#!/usr/bin/env python3
"""
Load firmware into the SoC over its UART boot loader, then show the console.

    python uart_load.py /dev/ttyUSB1 ../build/firmware.elf [--baud 115200]

The chip must have been reset with the `boot` strap pin high.
Protocol (see rtl/uart_boot.v): 'W' addr[4] count[2] data..., 'R' addr[4]
count[2], 'G'. Little-endian. Needs pyserial.
"""
import argparse
import struct
import sys

import serial


def elf_segments(path):
    with open(path, "rb") as f:
        data = f.read()
    phoff, = struct.unpack_from("<I", data, 0x1C)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x2A)
    for i in range(phnum):
        p_type, p_offset, _v, p_paddr, p_filesz, *_ = struct.unpack_from("<8I", data, phoff + i * phentsize)
        if p_type == 1 and p_filesz:
            blob = data[p_offset:p_offset + p_filesz]
            yield p_paddr, blob + b"\0" * (-len(blob) % 4)


def expect_ack(port, what):
    ack = port.read(1)
    if ack != b"K":
        sys.exit(f"no ACK after {what} (got {ack!r}) - is the boot strap high?")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port")
    ap.add_argument("elf")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args()

    with serial.Serial(args.port, args.baud, timeout=2) as port:
        for base, blob in elf_segments(args.elf):
            for off in range(0, len(blob), 1024):
                chunk = blob[off:off + 1024]
                port.write(b"W" + struct.pack("<IH", base + off, len(chunk) // 4) + chunk)
                expect_ack(port, f"write @ 0x{base + off:08X}")
            port.write(b"R" + struct.pack("<IH", base, 1))
            if port.read(4) != blob[:4]:
                sys.exit(f"readback mismatch @ 0x{base:08X}")
            print(f"loaded {len(blob):6d} bytes @ 0x{base:08X}")

        port.write(b"G")
        expect_ack(port, "go")
        print("CPU released - console follows (Ctrl+C to quit)\n")
        port.timeout = None
        try:
            while True:
                sys.stdout.write(port.read(1).decode(errors="replace"))
                sys.stdout.flush()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
