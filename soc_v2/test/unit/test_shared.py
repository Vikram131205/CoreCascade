"""
Crossbar + real shared-SRAM banks (tb_shared.v, wired like soc_top).

  - data integrity: 8 masters read and write the shared window concurrently
    with random byte enables; every read must return what the last granted
    write left there, and every response arrives the cycle after the grant
  - interleaving: after the run, the contents of each physical bank are
    compared word by word with the model: word w lives in bank w % 8, row w / 8
  - bandwidth: 8 masters streaming one array (staggered by a word) move
    8 words per cycle; 8 masters on the same bank move 1
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from memmap import MASTERS, NM, NUM_BANKS, S_BANK0, SHARED_BASE

SEED = int(os.environ.get("SEED", "1"))
BANK_WORDS = 64                                   # tb_shared default
WINDOW_WORDS = BANK_WORDS * NUM_BANKS             # 512 words = 2 KB


def field(v, i, w):
    return (v >> (i * w)) & ((1 << w) - 1)


def pack(vals, w):
    out = 0
    for i, x in enumerate(vals):
        out |= (x & ((1 << w) - 1)) << (i * w)
    return out


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for sig in (dut.m_req, dut.m_we, dut.m_be, dut.m_addr, dut.m_wdata):
        sig.value = 0
    dut.reset.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.reset.value = 0


async def run(dut, next_txn, mem, cycles, b2b=True):
    """Each master asks next_txn(m, k) for its k-th transaction (we, be, word, wdata)
    or None. Returns (transfers, cycles). Checks every read against `mem`."""
    req = [None] * NM            # (we, be, word, wdata) being requested
    out = [None] * NM            # (txn, expected rdata or None, due cycle)
    count = [0] * NM
    transfers = 0
    for m in range(NM):
        req[m] = next_txn(m, 0)
    t = 0
    while t < cycles or any(out) or any(req):
        if t > cycles + 100:
            raise AssertionError("did not drain")
        dut.m_req.value = pack([r is not None for r in req], 1)
        dut.m_we.value = pack([r[0] if r else 0 for r in req], 1)
        dut.m_be.value = pack([r[1] if r else 0 for r in req], 4)
        dut.m_addr.value = pack([SHARED_BASE + 4 * r[2] if r else 0 for r in req], 32)
        dut.m_wdata.value = pack([r[3] if r else 0 for r in req], 32)
        await ReadOnly()
        gnt, rvalid, err = int(dut.m_gnt.value), int(dut.m_rvalid.value), int(dut.m_err.value)
        rdata_bits = str(dut.m_rdata.value)     # MSB first; write lanes may be X (don't care)

        for m in range(NM):
            if rvalid >> m & 1:
                assert out[m] is not None and out[m][2] == t, f"cycle {t}: unexpected rvalid for {MASTERS[m]}"
                assert not err >> m & 1, f"cycle {t}: err for {MASTERS[m]}"
                exp = out[m][1]
                if exp is not None:
                    lane = rdata_bits[len(rdata_bits) - 32 * (m + 1):len(rdata_bits) - 32 * m]
                    assert set(lane) <= {"0", "1"}, f"cycle {t}: {MASTERS[m]} read X/Z: {lane}"
                    got = int(lane, 2)
                    assert got == exp, (f"cycle {t}: {MASTERS[m]} read word {out[m][0][2]}: "
                                        f"got {got:08X}, expected {exp:08X}")
                out[m] = None
            elif out[m] is not None and out[m][2] == t:
                raise AssertionError(f"cycle {t}: {MASTERS[m]} expected its response (banks answer in 1 cycle)")

        banks = set()
        for m in range(NM):
            if gnt >> m & 1:
                assert req[m] is not None, f"cycle {t}: gnt without req"
                we, be, word, wdata = req[m]
                bank = word % NUM_BANKS
                assert bank not in banks, f"cycle {t}: two grants on bank {bank}"
                banks.add(bank)
                if we:
                    old = mem[word]
                    for b in range(4):
                        if be >> b & 1:
                            old = (old & ~(0xFF << 8 * b)) | (wdata & (0xFF << 8 * b))
                    mem[word] = old
                    out[m] = (req[m], None, t + 1)
                else:
                    out[m] = (req[m], mem[word], t + 1)
                count[m] += 1
                transfers += 1
                req[m] = None
        for m in range(NM):
            if req[m] is None and t + 1 < cycles and (out[m] is None or (b2b and out[m][2] == t + 1)):
                req[m] = next_txn(m, count[m])
        await RisingEdge(dut.clk)
        t += 1
    return transfers, t


async def check_banks(dut, mem):
    """Physical layout: word w of the window is row w // 8 of bank w % 8."""
    for w in range(WINDOW_WORDS):
        bank, row = w % NUM_BANKS, w // NUM_BANKS
        got = int(dut.slv[S_BANK0 + bank].u_mem.u_mem.mem[row].value)
        assert got == mem[w], f"word {w}: bank {bank} row {row} holds {got:08X}, expected {mem[w]:08X}"


@cocotb.test()
async def test_concurrent_integrity(dut):
    """Fill the window, then 3000 cycles of random concurrent reads/writes with byte enables."""
    rng = random.Random(SEED)
    await reset(dut)
    mem = [0] * WINDOW_WORDS
    fill = {m: list(range(m, WINDOW_WORDS, NM)) for m in range(NM)}
    values = {w: rng.getrandbits(32) for w in range(WINDOW_WORDS)}

    def filler(m, k):
        return (1, 0xF, fill[m][k], values[fill[m][k]]) if k < len(fill[m]) else None

    await run(dut, filler, mem, WINDOW_WORDS // NM + 2)
    await check_banks(dut, mem)

    hot = [rng.randrange(WINDOW_WORDS) for _ in range(12)]     # a few contended words

    def random_txn(m, k):
        if rng.random() < 0.2:
            return None
        word = rng.choice(hot) if rng.random() < 0.3 else rng.randrange(WINDOW_WORDS)
        if rng.random() < 0.5:
            return (1, rng.choice([0xF, 0x1, 0x2, 0x4, 0x8, 0x3, 0xC]), word, rng.getrandbits(32))
        return (0, 0xF, word, 0)

    n, cycles = await run(dut, random_txn, mem, 3000)
    dut._log.info(f"{n} concurrent transfers in {cycles} cycles, all reads matched")
    await check_banks(dut, mem)


@cocotb.test()
async def test_bandwidth(dut):
    """Streaming the same array, staggered by one word: 8 words/cycle.
    All masters on one bank: 1 word/cycle."""
    await reset(dut)
    mem = [0] * WINDOW_WORDS
    per = WINDOW_WORDS // NM                      # master m fills bank m: words m, m+8, ...
    await run(dut, lambda m, k: (1, 0xF, m + NM * k, 0x1000 + m + NM * k) if k < per else None, mem, per + 4)
    await check_banks(dut, mem)

    steps = 400
    n, cycles = await run(dut, lambda m, k: (0, 0xF, (m + k) % WINDOW_WORDS, 0) if k < steps else None,
                          mem, steps + 10)
    spread = n / cycles
    n2, cycles2 = await run(dut, lambda m, k: (0, 0xF, (8 * (m + 8 * k)) % WINDOW_WORDS, 0) if k < 50 else None,
                            mem, 50 * NM + 10)
    same = n2 / cycles2
    dut._log.info(f"bandwidth: staggered stream {spread:.2f} words/cycle, same bank {same:.2f} words/cycle")
    assert spread > 7.5, spread
    assert same <= 1.0, same
