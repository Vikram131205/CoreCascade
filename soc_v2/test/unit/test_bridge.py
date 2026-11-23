"""
periph_bridge: one OBI slave in front of NP = 6 register blocks
(block i at 0x4000_0000 + i * 0x1000, selected by addr[15:12]).

Python is an OBI master on one side and models the six register blocks on the
other (random p_ready = back-pressure, read data registered on the handshake).

  - p_req is one-hot on the addressed block, only while req is high, and
    only for valid blocks; p_we / p_be / p_addr[11:0] / p_wdata pass through
  - gnt = p_ready of the addressed block (unknown blocks are granted at once)
  - rvalid exactly one cycle after each handshake, for reads and writes
  - read data is the block's registered value; unknown blocks answer err with
    rdata 0; known blocks never answer err
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from memmap import NP, PERIPH_BASE

SEED = int(os.environ.get("SEED", "1"))


def pack(vals, w):
    out = 0
    for i, x in enumerate(vals):
        out |= (x & ((1 << w) - 1)) << (i * w)
    return out


@cocotb.test()
async def test_bridge(dut):
    rng = random.Random(SEED)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for sig in (dut.req, dut.we, dut.be, dut.addr, dut.wdata, dut.p_ready, dut.p_rdata):
        sig.value = 0
    dut.reset.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.reset.value = 0

    blk_rdata = [rng.getrandbits(32) for _ in range(NP)]   # each block's registered read data
    req = None                                             # (we, be, addr, wdata)
    pending = None                                         # (idx, we, expected rdata)
    ready = [1] * NP
    seen = {"err": 0, "wait": 0, "read": 0, "write": 0}
    for t in range(4000):
        dut.p_ready.value = pack(ready, 1)
        dut.p_rdata.value = pack(blk_rdata, 32)
        if req is None:
            dut.req.value = 0
        else:
            dut.req.value, dut.we.value, dut.be.value, dut.addr.value, dut.wdata.value = 1, *req
        await ReadOnly()
        gnt, rvalid = int(dut.gnt.value), int(dut.rvalid.value)
        p_req = int(dut.p_req.value)

        # request side
        if req is None:
            assert p_req == 0, f"cycle {t}: p_req {p_req:06b} without req"
        else:
            we, be, addr, wdata = req
            idx = (addr >> 12) & 0xF
            exp_p_req = (1 << idx) if idx < NP else 0
            assert p_req == exp_p_req, f"cycle {t}: p_req {p_req:06b}, expected {exp_p_req:06b}"
            assert (int(dut.p_we.value), int(dut.p_be.value), int(dut.p_addr.value), int(dut.p_wdata.value)) \
                == (we, be, addr & 0xFFF, wdata), f"cycle {t}: request fields not passed through"
            exp_gnt = ready[idx] if idx < NP else 1
            assert gnt == exp_gnt, f"cycle {t}: gnt {gnt}, expected {exp_gnt} (block {idx})"

        # response side
        if pending is None:
            assert rvalid == 0, f"cycle {t}: rvalid without a request"
        else:
            idx, pwe, expect = pending
            assert rvalid == 1, f"cycle {t}: no rvalid the cycle after the handshake"
            err = int(dut.err.value)
            if idx >= NP:
                assert err == 1 and int(dut.rdata.value) == 0, f"cycle {t}: unknown block {idx} must answer err"
                seen["err"] += 1
            else:
                assert err == 0, f"cycle {t}: err from block {idx}"
                if not pwe:
                    got = int(dut.rdata.value)
                    assert got == expect, f"cycle {t}: block {idx} read {got:08X}, expected {expect:08X}"
        pending = None

        # advance: handshake -> response next cycle; blocks register read data
        if req is not None and gnt:
            we, be, addr, wdata = req
            idx = (addr >> 12) & 0xF
            if idx < NP and not we:
                blk_rdata[idx] = rng.getrandbits(32)            # visible from the next cycle
                pending = (idx, we, blk_rdata[idx])
                seen["read"] += 1
            else:
                pending = (idx, we, None)
                seen["write"] += int(idx < NP)
            req = None
        elif req is not None:
            seen["wait"] += 1
        ready = [int(rng.random() < 0.6) for _ in range(NP)]
        if req is None and rng.random() < 0.8:
            idx = rng.randrange(NP) if rng.random() < 0.85 else rng.randrange(NP, 16)
            addr = PERIPH_BASE | (rng.getrandbits(12) << 16) | (idx << 12) | (rng.getrandbits(10) << 2)
            req = (rng.getrandbits(1), rng.getrandbits(4), addr, rng.getrandbits(32))
        await RisingEdge(dut.clk)
    dut._log.info(f"coverage {seen}")
    assert all(v > 50 for v in seen.values()), seen
