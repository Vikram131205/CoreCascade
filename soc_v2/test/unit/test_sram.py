"""
obi_sram (one shared-SRAM bank) as an OBI slave: WORDS = 64, ROW_LSB = 5.

  - gnt is always 1 and err always 0
  - rvalid comes exactly one cycle after each request (reads and writes),
    never otherwise, and never out of reset
  - reads return the row's contents; writes honour the byte enables
  - the row is addr[ROW_LSB +: 6]: the bank-select bits addr[4:2] and the
    byte offset addr[1:0] are ignored inside a bank (that is what lets the
    crossbar interleave words across banks)
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

SEED = int(os.environ.get("SEED", "1"))
WORDS, ROW_LSB = 64, 5


def row_of(addr):
    return (addr >> ROW_LSB) & (WORDS - 1)


def rand_addr(rng, row):
    """Any address in that row: random bank bits [4:2], byte offset and upper bits."""
    return (rng.getrandbits(21) << (ROW_LSB + 6)) | (row << ROW_LSB) | rng.getrandbits(ROW_LSB)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.req.value = 0
    dut.we.value = 0
    dut.be.value = 0
    dut.addr.value = 0
    dut.wdata.value = 0
    dut.reset.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)


@cocotb.test()
async def test_reset_no_response(dut):
    """Requests during reset get no rvalid."""
    await setup(dut)
    for _ in range(5):
        dut.req.value = 1
        await ReadOnly()
        assert int(dut.gnt.value) == 1
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.rvalid.value) == 0, "rvalid during reset"
        await RisingEdge(dut.clk)
    dut.req.value = 0


@cocotb.test()
async def test_random_access(dut):
    """Fill every row, then 3000 cycles of random back-to-back reads/writes."""
    rng = random.Random(SEED)
    await setup(dut)
    dut.reset.value = 0
    model = [None] * WORDS
    pending = None                     # (we, row) issued last cycle
    plan = [(1, 0xF, r, rng.getrandbits(32)) for r in range(WORDS)]
    for _ in range(3000):
        r = rng.randrange(WORDS)
        if rng.random() < 0.2:
            plan.append(None)
        elif rng.random() < 0.5:
            plan.append((1, rng.choice([0xF, 0x1, 0x2, 0x4, 0x8, 0x5, 0xA]), r, rng.getrandbits(32)))
        else:
            plan.append((0, 0xF, r, 0))
    plan.append(None)

    aliased = 0
    for step in plan:
        if step is None:
            dut.req.value = 0
        else:
            we, be, row, wdata = step
            addr = rand_addr(rng, row)
            aliased += int(addr & 0x1C != 0)
            dut.req.value, dut.we.value, dut.be.value = 1, we, be
            dut.addr.value, dut.wdata.value = addr, wdata
        await ReadOnly()
        assert int(dut.gnt.value) == 1 and int(dut.err.value) == 0
        if pending is None:
            assert int(dut.rvalid.value) == 0, "rvalid without a request"
        else:
            assert int(dut.rvalid.value) == 1, "no rvalid one cycle after the request"
            pwe, prow, expect = pending
            if not pwe:
                got = int(dut.rdata.value)
                assert got == expect, f"row {prow}: read {got:08X}, expected {expect:08X}"
        pending = None
        if step is not None:
            we, be, row, wdata = step
            if we:
                old = model[row] if model[row] is not None else 0
                for b in range(4):
                    if be >> b & 1:
                        old = (old & ~(0xFF << 8 * b)) | (wdata & (0xFF << 8 * b))
                model[row] = old
                pending = (1, row, None)
            else:
                pending = (0, row, model[row])
        await RisingEdge(dut.clk)
    dut._log.info(f"{len(plan)} cycles; {aliased} accesses used nonzero bank-select/byte bits")
