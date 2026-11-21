"""
SoC-level test: the testbench plays a host PC wired to the chip's UART pins.

  1. Reset with the `boot` strap high: the hardware boot loader owns the bus.
  2. Send the firmware ELF over UART ('W' commands), read part back ('R'),
     then 'G' to release the CPU.
  3. The CPU (C firmware) loads GPU kernels/data, launches 4 kernels and
     sleeps until the GPU-done interrupt; results are printed on the UART.
  4. Firmware asks for a key; we send one; the UART-RX interrupt echoes it.
  5. Check: exit code, console text, GPU memory vs an independent model,
     interrupts taken, and that CPU/GPU really contended for memory.
"""

import os
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, with_timeout

try:
    from cocotb.triggers import SimTimeoutError
except ImportError:                               # cocotb 1.x
    from cocotb.result import SimTimeoutError

FIRMWARE = os.environ.get("FIRMWARE", "../build/firmware.elf")
UART_DIV = int(os.environ.get("UART_DIV", "8"))


# ════════════════════════════════════════════════════════════════
#  ELF
# ════════════════════════════════════════════════════════════════

def elf_segments(path):
    """Yield (address, bytes) for each PT_LOAD segment of a 32-bit LE ELF."""
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"\x7fELF" and data[4] == 1, "not an ELF32 file"
    phoff, = struct.unpack_from("<I", data, 0x1C)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x2A)
    for i in range(phnum):
        p_type, p_offset, _vaddr, p_paddr, p_filesz, _memsz, _flags, _align = \
            struct.unpack_from("<8I", data, phoff + i * phentsize)
        if p_type == 1 and p_filesz:
            yield p_paddr, data[p_offset:p_offset + p_filesz]


# ════════════════════════════════════════════════════════════════
#  Host side of the UART
# ════════════════════════════════════════════════════════════════

class UartHost:
    def __init__(self, dut):
        self.dut = dut
        self.rxq = Queue()
        dut.uart_rx.value = 1
        cocotb.start_soon(self._monitor())

    async def _monitor(self):
        """Decode bytes the chip sends on uart_tx."""
        dut = self.dut
        while True:
            await FallingEdge(dut.uart_tx)                       # start bit
            await ClockCycles(dut.clk, UART_DIV + UART_DIV // 2)  # middle of bit 0
            byte = 0
            for i in range(8):
                byte |= int(dut.uart_tx.value) << i
                await ClockCycles(dut.clk, UART_DIV)
            self.rxq.put_nowait(byte)

    async def send(self, data):
        for byte in data:
            self.dut.uart_rx.value = 0
            await ClockCycles(self.dut.clk, UART_DIV)
            for i in range(8):
                self.dut.uart_rx.value = (byte >> i) & 1
                await ClockCycles(self.dut.clk, UART_DIV)
            self.dut.uart_rx.value = 1
            await ClockCycles(self.dut.clk, UART_DIV)

    async def recv(self, n, timeout_us=2000):
        out = bytearray()
        for _ in range(n):
            out.append(await with_timeout(self.rxq.get(), timeout_us, "us"))
        return bytes(out)

    # ---- boot loader protocol ----
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


# ════════════════════════════════════════════════════════════════
#  Reference model of the firmware's GPU data (same LFSR as main.c)
# ════════════════════════════════════════════════════════════════

class Lfsr:
    def __init__(self):
        self.state = 0xACE1

    def rand8(self):
        s = self.state
        self.state = ((s >> 1) ^ ((-(s & 1)) & 0xB400)) & 0xFFFFFFFF
        return self.state & 0xFF


def expected_gpu_dmem():
    rng = Lfsr()
    mem = [0] * 256

    def matadd():
        for i in range(8):
            a, b = rng.rand8(), rng.rand8()
            mem[i], mem[8 + i], mem[16 + i] = a, b, (a + b) & 0xFF

    def matmul():
        a, b = [0] * 4, [0] * 4
        for i in range(4):
            a[i], b[i] = rng.rand8() & 0x0F, rng.rand8() & 0x07
            mem[i], mem[4 + i] = a[i], b[i]
        for r in range(2):
            for c in range(2):
                mem[8 + 2 * r + c] = (a[2 * r] * b[c] + a[2 * r + 1] * b[2 + c]) & 0xFF

    matadd(); matmul(); matadd(); matadd()
    return mem


async def count_events(dut, stats):
    """Count GPU-memory contention cycles and interrupts taken by the CPU."""
    while True:
        await RisingEdge(dut.clk)
        if int(dut.u_gpu.m_req.value) and not int(dut.u_gpu.m_gnt.value):
            stats["refused"] += 1
        if int(dut.u_cpu.irq_take.value):
            stats["irqs"] += 1


# ════════════════════════════════════════════════════════════════
#  Test
# ════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_soc_boot_and_gpu(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    host = UartHost(dut)
    dut.gpio_in.value = 0
    dut.boot.value = 1
    dut.reset.value = 1
    await ClockCycles(dut.clk, 5)
    dut.reset.value = 0
    await ClockCycles(dut.clk, 5)
    assert int(dut.u_boot.active.value) == 1, "boot loader should own the bus"

    # ---- 1. download firmware over the UART ----
    image = []
    for base, blob in elf_segments(FIRMWARE):
        blob += b"\0" * (-len(blob) % 4)
        words = list(struct.unpack(f"<{len(blob) // 4}I", blob))
        await host.write_words(base, words)
        image.append((base, words))
        dut._log.info(f"UART boot: wrote {len(blob):5d} bytes @ 0x{base:08X}")

    for base, words in image:                # read back the start of each segment
        n = min(8, len(words))
        assert await host.read_words(base, n) == words[:n], f"readback mismatch @ 0x{base:08X}"
    dut._log.info("UART boot: readback OK, releasing CPU")
    await host.go()

    # ---- 2. run: collect console output, answer the prompt ----
    stats = {"refused": 0, "irqs": 0}
    cocotb.start_soon(count_events(dut, stats))
    console = ""
    key_sent = False
    for _ in range(4000):
        try:
            ch = chr((await host.recv(1, timeout_us=100))[0])
        except SimTimeoutError:              # quiet line, keep waiting
            ch = ""
        console += ch
        if ch == "\n" and console.strip():
            dut._log.info("console| " + console.rstrip("\n").splitlines()[-1])
        if console.endswith("send a key> ") and not key_sent:
            dut._log.info("console| send a key>   (sending 'Z')")
            await host.send(b"Z")
            key_sent = True
        if "RESULT:" in console and console.endswith("\n"):
            break
    else:
        raise AssertionError(f"firmware did not finish. Console so far:\n{console}")

    for _ in range(1000):
        if int(dut.halted.value):
            break
        await RisingEdge(dut.clk)
    assert int(dut.halted.value), "EXIT register never written"

    # ---- 3. checks ----
    exit_code = int(dut.u_sys.exit_code.value)
    dut._log.info(f"exit code {exit_code}, interrupts taken {stats['irqs']}, "
                  f"CPU refused on GPU memory {stats['refused']} cycles")
    assert exit_code == 0, f"firmware reported {exit_code} failures"
    assert "RESULT: PASS" in console
    assert console.count("PASS (") == 4, "expected 4 kernel reports"
    assert "got 'Z'" in console, "UART RX interrupt / echo failed"
    assert stats["irqs"] >= 5, "expected 4 GPU-done + 1 UART-RX interrupts"
    assert stats["refused"] > 0, "contention pass never collided with the GPU"

    expected = expected_gpu_dmem()
    got = [int(dut.u_gpu.dmem[i].value) for i in range(24)]
    assert got == expected[:24], f"GPU memory {got} != expected {expected[:24]}"
    dut._log.info(f"GPU memory A/B/C matches model: {got}")
