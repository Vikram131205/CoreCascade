"""
obi_xbar unit tests: OBI protocol checker + reference model.

tb_xbar.v is the crossbar exactly as soc_top builds it. Python drives all 8
master ports and models all 11 slaves, one clock cycle at a time:

  phase A (just after the clock edge)  drive this cycle's inputs
  phase B (ReadOnly, before next edge) sample outputs, check, decide next cycle

Every cycle, a reference model of docs/spec/bus_obi.md predicts which slaves
see a request, which master each slave arbitration picks and which masters
are granted, and the checker compares that with the RTL. Independently of
the arbitration details it also follows every transaction end to end:

  - a request reaches the slave it addresses, with exactly the master's fields
  - a slave is never given a second request while its response is pending
    (except in the cycle that response returns)
  - every response reaches the master that issued the request, in the cycle
    the slave answers, with the slave's rdata / err; nobody else gets it
  - an address that hits no slave is answered by the crossbar with err, rdata 0,
    one cycle after the grant
  - master 7 (display) wins every slave it requests; otherwise round robin
  - nothing is lost or duplicated: after the drain every request completed
"""

import os
import random
from collections import Counter

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from memmap import MASK32, MASTERS, NM, NS, PRIO_M, S_BANK0, SHARED_BASE, SLAVES, random_addr, slave_of

SEED = int(os.environ.get("SEED", "1"))


def field(v, i, w):
    return (v >> (i * w)) & ((1 << w) - 1)


def pack(vals, w):
    out = 0
    for i, x in enumerate(vals):
        out |= (x & ((1 << w) - 1)) << (i * w)
    return out


class Txn:
    __slots__ = ("m", "we", "be", "addr", "wdata", "slave", "t_req", "t_gnt", "due", "rdata", "err")

    def __init__(self, m, we, be, addr, wdata, t):
        self.m, self.we, self.be, self.addr, self.wdata = m, we, be, addr, wdata
        self.slave = slave_of(addr)
        self.t_req, self.t_gnt, self.due = t, None, None
        self.rdata, self.err = None, None

    def fields(self):
        return (self.we, self.be, self.addr, self.wdata)

    def __repr__(self):
        return f"{MASTERS[self.m]} {'W' if self.we else 'R'} 0x{self.addr:08X} be={self.be:X}"


class Cfg:
    """Traffic and slave behaviour for one run."""

    def __init__(self, **kw):
        self.p_issue = {}        # per master: chance an idle master issues (default 0.5)
        self.p_unmapped = 0.05   # chance a random request hits no slave
        self.addr_fn = None      # optional fn(rng, master, cycle) -> address
        self.p_write = 0.5
        self.back_to_back = 0.5  # chance to issue again in the cycle the response returns
        self.p_gnt = 1.0         # per-cycle chance a slave asserts gnt
        self.lat = (1,)          # slave response latency choices, in cycles
        self.p_err = 0.0         # chance a slave answers with err
        self.__dict__.update(kw)

    @staticmethod
    def _per_master(value, m, default):
        if isinstance(value, dict):
            return value.get(m, value.get("*", default))
        return value

    def issue_prob(self, m):
        return self._per_master(self.p_issue, m, 0.5)

    def b2b_prob(self, m):
        return self._per_master(self.back_to_back, m, 0.5)


class SlaveModel:
    """Memory-backed slave: one transaction at a time, programmable gnt/latency/err."""

    def __init__(self, s, rng, cfg):
        self.s, self.rng, self.cfg = s, rng, cfg
        self.mem = {}
        self.pending = None
        self.accepted = 0

    def word(self, addr):
        a = addr & ~3
        return self.mem.get(a, (a * 2654435761 + self.s) & MASK32)

    def accept(self, txn, t, errors):
        if self.pending is not None:
            errors.append(f"cycle {t}: {SLAVES[self.s]} got {txn} while {self.pending} is still outstanding")
        old = self.word(txn.addr)
        if txn.we:
            new = old
            for b in range(4):
                if txn.be >> b & 1:
                    new = (new & ~(0xFF << 8 * b)) | (txn.wdata & (0xFF << 8 * b))
            self.mem[txn.addr & ~3] = new
            txn.rdata = self.rng.getrandbits(32)        # meaningless for writes, but must be routed
        else:
            txn.rdata = old
        txn.err = self.rng.random() < self.cfg.p_err
        txn.due = t + self.rng.choice(self.cfg.lat)
        self.pending = txn
        self.accepted += 1


class MasterModel:
    """OBI master: holds its request until gnt, one transaction outstanding."""

    def __init__(self, m, rng, cfg):
        self.m, self.rng, self.cfg = m, rng, cfg
        self.req = None          # request driven this cycle
        self.out = None          # granted, waiting for rvalid
        self.issued = self.completed = 0
        self.waits = []
        self.stop = False

    def new_txn(self, t):
        cfg, rng = self.cfg, self.rng
        if cfg.addr_fn is not None:
            addr = cfg.addr_fn(rng, self.m, t)
        else:
            target = None if rng.random() < cfg.p_unmapped else rng.randrange(NS)
            addr = random_addr(rng, target)
        we = int(rng.random() < cfg.p_write)
        be = rng.choice([0xF, 0xF, 0x1, 0x2, 0x4, 0x8, 0x3, 0xC]) if we else 0xF
        self.issued += 1
        return Txn(self.m, we, be, addr, rng.getrandbits(32), t)

    def plan(self, t_next):
        """Decide whether to request in cycle t_next."""
        if self.req is not None or self.stop:
            return                                          # keep the request stable
        if self.out is not None:
            # only allowed to overlap with the cycle the response comes back
            if self.out.due == t_next and self.rng.random() < self.cfg.b2b_prob(self.m):
                self.req = self.new_txn(t_next)
            return
        if self.rng.random() < self.cfg.issue_prob(self.m):
            self.req = self.new_txn(t_next)


async def run(dut, cfg, cycles, seed, drain=200):
    """Drive `cycles` cycles of traffic, then drain; return statistics."""
    rng = random.Random(seed)
    masters = [MasterModel(m, rng, cfg) for m in range(NM)]
    slaves = [SlaveModel(s, rng, cfg) for s in range(NS)]
    last = [0] * NS                      # round-robin pointer per slave (reset value 0)
    err_rsp = [None] * NM                # unmapped request answered next cycle
    gnt_now = [1] * NS
    stats = Counter()
    handshakes = Counter()
    errors = []

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for sig in (dut.m_req, dut.m_we, dut.m_be, dut.m_addr, dut.m_wdata,
                dut.s_gnt, dut.s_rvalid, dut.s_rdata, dut.s_err):
        sig.value = 0
    dut.reset.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.reset.value = 0

    for m in masters:
        m.plan(0)

    t = 0
    while True:
        if t == cycles:
            for m in masters:
                m.stop = True
        if t >= cycles and all(m.req is None and m.out is None for m in masters):
            break
        if t > cycles + drain:
            raise AssertionError(f"traffic did not drain: {[(m.req, m.out) for m in masters]}")

        # ---------------- phase A: drive cycle t ----------------
        reqs = [m.req for m in masters]
        dut.m_req.value = pack([r is not None for r in reqs], 1)
        dut.m_we.value = pack([r.we if r else 0 for r in reqs], 1)
        dut.m_be.value = pack([r.be if r else 0 for r in reqs], 4)
        dut.m_addr.value = pack([r.addr if r else 0 for r in reqs], 32)
        dut.m_wdata.value = pack([r.wdata if r else 0 for r in reqs], 32)
        resp_now = [sl.pending if sl.pending is not None and sl.pending.due == t else None for sl in slaves]
        dut.s_gnt.value = pack(gnt_now, 1)
        dut.s_rvalid.value = pack([r is not None for r in resp_now], 1)
        dut.s_rdata.value = pack([r.rdata if r else rng.getrandbits(32) for r in resp_now], 32)
        dut.s_err.value = pack([int(r.err) if r else rng.getrandbits(1) for r in resp_now], 1)

        # ---------------- phase B: sample and check ----------------
        await ReadOnly()
        m_gnt, m_rvalid, m_err = int(dut.m_gnt.value), int(dut.m_rvalid.value), int(dut.m_err.value)
        m_rdata = int(dut.m_rdata.value)
        s_req, s_we, s_be = int(dut.s_req.value), int(dut.s_we.value), int(dut.s_be.value)
        s_addr, s_wdata = int(dut.s_addr.value), int(dut.s_wdata.value)

        # reference arbitration
        exp_s_req, win, ncand = 0, [None] * NS, [0] * NS
        for s in range(NS):
            cands = [m for m in range(NM) if reqs[m] is not None and reqs[m].slave == s]
            ncand[s] = len(cands)
            if not cands:
                continue
            if PRIO_M in cands:
                win[s] = PRIO_M
            else:
                win[s] = next((last[s] + k) % NM for k in range(1, NM + 1) if (last[s] + k) % NM in cands)
            if slaves[s].pending is None or resp_now[s] is not None:
                exp_s_req |= 1 << s
        if s_req != exp_s_req:
            errors.append(f"cycle {t}: s_req {s_req:011b}, expected {exp_s_req:011b}")
        for s in range(NS):
            if exp_s_req >> s & 1:
                got = (field(s_we, s, 1), field(s_be, s, 4), field(s_addr, s, 32), field(s_wdata, s, 32))
                if got != reqs[win[s]].fields():
                    errors.append(f"cycle {t}: {SLAVES[s]} sees {got}, expected the request of {reqs[win[s]]}")

        exp_gnt, hs = 0, []
        for m, r in enumerate(reqs):
            if r is not None and r.slave is None and err_rsp[m] is None:
                exp_gnt |= 1 << m                        # crossbar's own error responder
        for s in range(NS):
            if exp_s_req >> s & 1 and gnt_now[s]:
                exp_gnt |= 1 << win[s]
                hs.append(s)
        if m_gnt & ~pack([r is not None for r in reqs], 1):
            errors.append(f"cycle {t}: gnt {m_gnt:08b} to a master that is not requesting")
        if m_gnt != exp_gnt:
            errors.append(f"cycle {t}: m_gnt {m_gnt:08b}, expected {exp_gnt:08b}")

        # responses
        exp_rv, exp_resp = 0, {}
        for m in range(NM):
            if err_rsp[m] is not None:
                exp_rv |= 1 << m
                exp_resp[m] = (0, 1)
        for s in range(NS):
            txn = resp_now[s]
            if txn is not None:
                if exp_rv >> txn.m & 1:
                    errors.append(f"cycle {t}: two responses for {MASTERS[txn.m]}")
                exp_rv |= 1 << txn.m
                exp_resp[txn.m] = (txn.rdata, int(txn.err))
        for m in range(NM):                               # end-to-end view of each master
            if m_rvalid >> m & 1 and (masters[m].out is None or masters[m].out.due != t):
                errors.append(f"cycle {t}: rvalid to {MASTERS[m]}, which has no response due")
        if m_rvalid != exp_rv:
            errors.append(f"cycle {t}: m_rvalid {m_rvalid:08b}, expected {exp_rv:08b}")
        if m_err & ~m_rvalid:
            errors.append(f"cycle {t}: m_err {m_err:08b} without rvalid")
        for m, (rd, er) in exp_resp.items():
            got = (field(m_rdata, m, 32), field(m_err, m, 1))
            if got != (rd, er):
                errors.append(f"cycle {t}: {MASTERS[m]} got rdata/err {got[0]:08X}/{got[1]}, "
                              f"expected {rd:08X}/{er} for {masters[m].out}")

        if errors:
            raise AssertionError("\n".join(errors[:10]))

        # ---------------- advance the models ----------------
        for s in range(NS):
            if resp_now[s] is not None:
                slaves[s].pending = None
        for m in range(NM):
            if exp_rv >> m & 1:
                masters[m].out = None
                masters[m].completed += 1
        err_next = [None] * NM
        for m in range(NM):
            if exp_gnt >> m & 1:
                txn = reqs[m]
                txn.t_gnt = t
                masters[m].waits.append(t - txn.t_req)
                if exp_rv >> m & 1:
                    stats["back_to_back"] += 1
                masters[m].req, masters[m].out = None, txn
                if txn.slave is None:
                    txn.due, txn.rdata, txn.err = t + 1, 0, True
                    err_next[m] = txn
                    stats["unmapped"] += 1
        for s in hs:
            txn = reqs[win[s]]
            slaves[s].accept(txn, t, errors)
            last[s] = win[s]
            handshakes[s] += 1
            stats["slave_err"] += int(txn.err)
            if ncand[s] > 1:
                stats["contended"] += 1
                stats["prio_win"] += int(win[s] == PRIO_M)
        stats["max_parallel"] = max(stats["max_parallel"], len(hs))
        stats["parallel_cycles"] += int(len(hs) >= 2)
        stats["handshakes"] += len(hs)
        err_rsp = err_next
        if errors:
            raise AssertionError("\n".join(errors[:10]))

        gnt_now = [int(rng.random() < cfg.p_gnt) for _ in range(NS)]
        for m in masters:
            m.plan(t + 1)

        await RisingEdge(dut.clk)
        t += 1

    # ---------------- end of run: nothing lost or duplicated ----------------
    for m in masters:
        assert m.issued == m.completed, f"{MASTERS[m.m]}: issued {m.issued}, completed {m.completed}"
    assert all(sl.pending is None for sl in slaves)
    assert sum(sl.accepted for sl in slaves) + stats["unmapped"] == sum(m.completed for m in masters)

    stats["cycles"] = t
    stats["completed"] = sum(m.completed for m in masters)
    per_master = {MASTERS[m.m]: m.completed for m in masters}
    max_wait = {MASTERS[m.m]: max(m.waits, default=0) for m in masters}
    dut._log.info(f"completed {stats['completed']} transactions in {t} cycles; per master {per_master}")
    dut._log.info(f"handshakes per slave {dict((SLAVES[s], n) for s, n in sorted(handshakes.items()))}")
    dut._log.info(f"max wait (cycles) {max_wait}")
    dut._log.info("coverage " + ", ".join(f"{k}={v}" for k, v in sorted(stats.items())))
    return stats, masters, handshakes


def bank_addr(rng, bank):
    return SHARED_BASE | (rng.randrange(8192) << 5) | (bank << 2)


@cocotb.test()
async def test_random_traffic(dut):
    """All masters, all slaves, unmapped addresses, slave stalls, latencies 1-3, slave errors."""
    cfg = Cfg(p_issue={"*": 0.6}, p_unmapped=0.05, p_gnt=0.7, lat=(1, 1, 2, 3), p_err=0.05)
    stats, _, hs = await run(dut, cfg, 4000, SEED)
    assert all(hs[s] > 0 for s in range(NS)), "every slave must be exercised"
    for key in ("contended", "prio_win", "back_to_back", "unmapped", "slave_err", "parallel_cycles"):
        assert stats[key] > 0, f"coverage hole: {key}"


@cocotb.test()
async def test_slow_slaves(dut):
    """Slaves that rarely grant and answer late: requests wait, and the presented
    request may change while gnt is low (a higher-priority master arrives)."""
    cfg = Cfg(p_issue={"*": 0.5}, p_unmapped=0.02, p_gnt=0.25, lat=(1, 2, 3, 4, 5), p_err=0.02)
    stats, _, _ = await run(dut, cfg, 3000, SEED + 1)
    assert stats["contended"] > 0 and stats["prio_win"] > 0


@cocotb.test()
async def test_parallel_banks(dut):
    """Master m streams to bank m: eight transfers in the same cycle, every cycle."""
    cfg = Cfg(p_issue={"*": 1.0}, back_to_back=1.0, p_write=0.5,
              addr_fn=lambda rng, m, t: bank_addr(rng, m))
    cycles = 1000
    stats, masters, _ = await run(dut, cfg, cycles, SEED + 2)
    per_cycle = stats["handshakes"] / stats["cycles"]
    dut._log.info(f"shared-SRAM transfers per cycle: {per_cycle:.2f} (8 banks, 8 masters)")
    assert stats["max_parallel"] == 8
    assert per_cycle > 7.9, per_cycle


@cocotb.test()
async def test_round_robin_fairness(dut):
    """Masters 0-6 hammer one bank (display idle): equal shares, nobody waits
    for more than the other six."""
    cfg = Cfg(p_issue={"*": 1.0, PRIO_M: 0.0}, back_to_back=1.0,
              addr_fn=lambda rng, m, t: bank_addr(rng, 3))
    _, masters, _ = await run(dut, cfg, 1400, SEED + 3)
    shares = [m.completed for m in masters[:PRIO_M]]
    worst = max(max(m.waits) for m in masters[:PRIO_M])
    dut._log.info(f"grants per master {shares}, worst wait {worst} cycles")
    assert max(shares) - min(shares) <= 1, shares
    assert worst <= PRIO_M - 1, worst


@cocotb.test()
async def test_display_priority(dut):
    """Everybody hammers one bank and the display requests now and then:
    the display is granted in the cycle it asks, every time."""
    cfg = Cfg(p_issue={"*": 1.0, PRIO_M: 0.3}, back_to_back={"*": 1.0, PRIO_M: 0.0},
              addr_fn=lambda rng, m, t: bank_addr(rng, 5))
    stats, masters, _ = await run(dut, cfg, 1500, SEED + 4)
    disp = masters[PRIO_M]
    dut._log.info(f"display requests {disp.completed}, worst wait {max(disp.waits)} cycles")
    assert disp.completed > 100 and max(disp.waits) == 0
    assert stats["prio_win"] > 100


@cocotb.test()
async def test_unmapped(dut):
    """Every master sends unmapped addresses back to back, mixed with good ones:
    each gets err + rdata 0 one cycle after its grant."""
    cfg = Cfg(p_issue={"*": 1.0}, back_to_back=1.0, p_unmapped=0.6, p_gnt=1.0)
    stats, _, _ = await run(dut, cfg, 1500, SEED + 5)
    assert stats["unmapped"] > 1000
