"""
CoreCascade SoC v2 system test. The testbench is the host PC on the UART pins
and a monitor on the VGA pins.

  1. Reset with boot strap high; download the firmware ELF over UART into
     ITCM, DTCM and shared SRAM (through the crossbar), read back, 'G'.
  2. The firmware runs its tests (concurrency, matmul, queued launches,
     GPU -> framebuffer -> display, command-processor error, exceptions,
     timer interrupt) and prints PASS/FAIL lines.
  3. During the display test the testbench captures whole frames from the
     VGA pins and checks every pixel against the pattern the GPU drew.
  4. It answers the key prompt (UART RX interrupt) and checks the exit code.
"""

import os
import re
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, with_timeout

try:
    from cocotb.triggers import SimTimeoutError
except ImportError:                          # cocotb 1.x
    from cocotb.result import SimTimeoutError

FIRMWARE = os.environ.get("FIRMWARE", "../build/firmware.elf")
UART_DIV = int(os.environ.get("UART_DIV", "8"))
FB_W, FB_H = 16, 16                          # must match test/Makefile and the firmware build


def elf_segments(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"\x7fELF" and data[4] == 1, "not an ELF32 file"
    phoff, = struct.unpack_from("<I", data, 0x1C)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x2A)
    for i in range(phnum):
        p_type, p_offset, _v, p_paddr, p_filesz, *_ = struct.unpack_from("<8I", data, phoff + i * phentsize)
        if p_type == 1 and p_filesz:
            yield p_paddr, data[p_offset:p_offset + p_filesz]


class UartHost:
    def __init__(self, dut):
        self.dut = dut
        self.rxq = Queue()
        dut.uart_rx_i.value = 1
        cocotb.start_soon(self._monitor())

    async def _monitor(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.uart_tx_o)
            await ClockCycles(dut.clk_i, UART_DIV + UART_DIV // 2)
            byte = 0
            for i in range(8):
                byte |= int(dut.uart_tx_o.value) << i
                await ClockCycles(dut.clk_i, UART_DIV)
            self.rxq.put_nowait(byte)

    async def send(self, data):
        for byte in data:
            self.dut.uart_rx_i.value = 0
            await ClockCycles(self.dut.clk_i, UART_DIV)
            for i in range(8):
                self.dut.uart_rx_i.value = (byte >> i) & 1
                await ClockCycles(self.dut.clk_i, UART_DIV)
            self.dut.uart_rx_i.value = 1
            await ClockCycles(self.dut.clk_i, UART_DIV)

    async def recv(self, n, timeout_us=3000):
        out = bytearray()
        for _ in range(n):
            out.append(await with_timeout(self.rxq.get(), timeout_us, "us"))
        return bytes(out)

    async def write_words(self, addr, words):
        for off in range(0, len(words), 256):
            chunk = words[off:off + 256]
            await self.send(b"W" + struct.pack("<IH", addr + 4 * off, len(chunk))
                            + b"".join(struct.pack("<I", w) for w in chunk))
            assert await self.recv(1) == b"K", "no ACK for W"

    async def read_words(self, addr, count):
        await self.send(b"R" + struct.pack("<IH", addr, count))
        return list(struct.unpack(f"<{count}I", await self.recv(4 * count)))

    async def go(self):
        await self.send(b"G")
        assert await self.recv(1) == b"K", "no ACK for G"


def expected_rgb(x, y):
    p = y * FB_W + x
    v = ((p & 127) * 3) & 0xFF
    return ((v >> 5) << 9) | ((v >> 7) << 8) | (((v >> 2) & 7) << 5) | (((v >> 4) & 1) << 4) \
        | ((v & 3) << 2) | (v & 3)


async def capture_frames(dut, nframes, frames):
    """Record whole frames from the VGA pins (pixel probe gives x/y)."""
    disp = dut.u_disp
    frame, seen = {}, 0
    while seen < nframes:
        await RisingEdge(dut.clk_i)
        if int(disp.out_active.value):
            frame[(int(disp.out_y.value), int(disp.out_x.value))] = int(dut.vga_rgb_o.value)
        if int(disp.vsync_irq.value):
            if len(frame) == FB_W * FB_H:
                frames.append(frame)
            frame, seen = {}, seen + 1


@cocotb.test()
async def test_soc_v2(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    host = UartHost(dut)
    dut.gpio_i.value = 0
    dut.boot_i.value = 1
    dut.rst_ni.value = 0
    await ClockCycles(dut.clk_i, 5)
    dut.rst_ni.value = 1
    await ClockCycles(dut.clk_i, 5)
    assert int(dut.u_boot.active.value) == 1, "boot loader should be active"

    # ---- 1. download over UART ----
    image = []
    for base, blob in elf_segments(FIRMWARE):
        blob += b"\0" * (-len(blob) % 4)
        words = list(struct.unpack(f"<{len(blob) // 4}I", blob))
        await host.write_words(base, words)
        image.append((base, words))
        dut._log.info(f"UART boot: wrote {len(blob):5d} bytes @ 0x{base:08X}")
    for base, words in image:
        n = min(8, len(words))
        assert await host.read_words(base, n) == words[:n], f"readback mismatch @ 0x{base:08X}"
    dut._log.info("UART boot: readback OK, releasing CPU")
    await host.go()

    # ---- 2. run, follow the console ----
    console, key_sent, frames = "", False, []
    capture = None
    for _ in range(20000):
        try:
            ch = chr((await host.recv(1, timeout_us=100))[0])
        except SimTimeoutError:
            ch = ""
        console += ch
        if ch == "\n" and console.strip():
            line = console.rstrip("\n").splitlines()[-1]
            dut._log.info("console| " + line)
            if line.startswith("display: scanning out") and capture is None:
                capture = cocotb.start_soon(capture_frames(dut, 4, frames))
        if console.endswith("send a key> ") and not key_sent:
            dut._log.info("console| send a key>   (sending 'Z')")
            await host.send(b"Z")
            key_sent = True
        if "RESULT:" in console and console.endswith("\n"):
            break
    else:
        raise AssertionError(f"firmware did not finish. Console so far:\n{console}")

    for _ in range(2000):
        if int(dut.halted_o.value):
            break
        await RisingEdge(dut.clk_i)
    assert int(dut.halted_o.value), "EXIT register never written"

    # ---- 3. checks ----
    exit_code = int(dut.u_sys.exit_code.value)
    good = sum(1 for f in frames
               if all(f[(y, x)] == expected_rgb(x, y) for y in range(FB_H) for x in range(FB_W)))
    dut._log.info(f"exit code {exit_code}; VGA frames captured {len(frames)}, pixel-exact {good}")
    assert exit_code == 0, f"firmware reported {exit_code} failed tests"
    assert "RESULT: PASS" in console
    assert len(re.findall(r": PASS \(", console)) == 7, "expected 7 passing tests"
    assert "got 'Z'" in console
    loops = int(re.search(r"CPU looped (\d+) times", console).group(1))
    assert loops > 0, "CPU did no work while the GPU ran"
    assert good >= 1, "no VGA frame matched the GPU-rendered framebuffer"
