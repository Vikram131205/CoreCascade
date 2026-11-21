"""
CocoTB verification for the RV32I 5-stage pipeline (rv32i_core)
================================================================
Each test builds a small program ending in HALT (jal x0, 0), runs it on the
Python golden model (rv32.RV32ISS) and on the RTL, then compares all 32
registers and the whole data memory.

The DUT is tb_cpu.v: core + synchronous SRAMs. Its `gnt_block` input lets a
test refuse data-bus requests at random to exercise the pipeline freeze that
happens when another bus master (the GPU) owns the memory.

Run:  cd verification && make
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

from rv32 import *  # noqa: F401,F403  (instruction encoders + golden model)

IMEM_WORDS = 1024
DMEM_WORDS = 1024


# ════════════════════════════════════════════════════════════════
#  DUT helpers
# ════════════════════════════════════════════════════════════════

async def stall_injector(dut, rng, prob):
    """Randomly withhold the data-bus grant and delay responses (0-3 extra cycles)."""
    while True:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        dut.gnt_block.value = int(rng.random() < prob)
        dut.resp_delay.value = rng.randint(0, 3)


async def run_program(dut, program, stall_prob=0.0, seed=0, init_dmem=None, irq_driver=None,
                      extra_cycles=0):
    """Load program, reset, run to completion, return the golden model.

    irq_driver: optional coroutine function(dut) started after reset; the run
    also waits for it to finish.
    """
    model = RV32ISS(program, dmem_bytes=4 * DMEM_WORDS)
    if init_dmem:
        for addr, value in init_dmem.items():
            model.store(addr, 4, value)
    model.run()

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.gnt_block.value = 0
    dut.resp_delay.value = 0
    dut.irq.value = 0
    dut.mtip.value = 0
    dut.reset.value = 1

    for i in range(IMEM_WORDS):
        dut.u_imem.mem[i].value = program[i] if i < len(program) else NOP
    for i in range(DMEM_WORDS):
        dut.u_dmem.mem[i].value = 0
    for addr, value in (init_dmem or {}).items():
        dut.u_dmem.mem[addr // 4].value = value
    for i in range(32):
        dut.u_core.rf.mem[i].value = 0

    await ClockCycles(dut.clk, 2)
    dut.reset.value = 0
    if stall_prob:
        cocotb.start_soon(stall_injector(dut, random.Random(seed), stall_prob))
    irq_task = cocotb.start_soon(irq_driver(dut)) if irq_driver else None

    # generous budget: worst case every instruction stalls/flushes a few cycles
    m_ops = sum(1 for i in program if (i & 0x7F) == 0x33 and (i >> 25) == 1)
    assert len(program) <= IMEM_WORDS, "program does not fit in the testbench IMEM"
    await ClockCycles(dut.clk, 8 * model.retired + 40 * m_ops + extra_cycles + 100)  # divides ~35 cycles
    if irq_task:
        await irq_task
        await ClockCycles(dut.clk, 50)
    return model


def check(dut, model, tag, skip_words=()):
    errors = 0
    for i in range(32):
        actual = int(dut.u_core.rf.mem[i].value)
        if actual != model.regs[i]:
            dut._log.error(f"{tag} x{i}: DUT=0x{actual:08X} expected=0x{model.regs[i]:08X}")
            errors += 1
    for i in range(DMEM_WORDS):
        if i in skip_words:
            continue
        actual = int(dut.u_dmem.mem[i].value)
        if actual != model.word(i):
            dut._log.error(f"{tag} dmem[0x{4*i:03X}]: DUT=0x{actual:08X} expected=0x{model.word(i):08X}")
            errors += 1
    dut._log.info(f"{tag} {model.retired} instructions retired, {errors} mismatches")
    assert errors == 0, f"{tag} {errors} mismatches"


# ════════════════════════════════════════════════════════════════
#  Directed tests
# ════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_r_type(dut):
    """ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU."""
    program = [
        addi(1, 0, 42), addi(2, 0, 15), addi(3, 0, -5), addi(4, 0, 3),
        add(10, 1, 2), sub(11, 1, 2), and_(12, 1, 2), or_(13, 1, 2), xor(14, 1, 2),
        sll(15, 1, 4), srl(16, 1, 4), sra(17, 3, 4), slt(18, 3, 1), sltu(19, 1, 3),
        srl(20, 3, 4), slt(21, 1, 3), sltu(22, 3, 1),
        HALT,
    ]
    check(dut, await run_program(dut, program), "[R-TYPE]")


@cocotb.test()
async def test_i_type(dut):
    """ADDI, ANDI, ORI, XORI, SLLI, SRLI, SRAI, SLTI, SLTIU."""
    program = [
        addi(1, 0, 100), addi(2, 0, -20),
        addi(10, 1, 50), andi(11, 1, 0x0F), ori(12, 1, 0x0F), xori(13, 1, 0xFF),
        slli(14, 1, 2), srli(15, 1, 3), srai(16, 2, 2), slti(17, 1, 50), sltiu(18, 1, 200),
        xori(19, 2, -1), sltiu(20, 1, -1), slti(21, 2, -19), srli(22, 2, 28),
        HALT,
    ]
    check(dut, await run_program(dut, program), "[I-TYPE]")


@cocotb.test()
async def test_load_store(dut):
    """SW then LW back."""
    program = [
        addi(1, 0, 0xAB), addi(2, 0, 0x42),
        sw(1, 0, 0), sw(2, 4, 0),
        lw(10, 0, 0), lw(11, 4, 0),
        HALT,
    ]
    check(dut, await run_program(dut, program), "[LOAD/STORE]")


@cocotb.test()
async def test_data_hazard(dut):
    """EX->EX and MEM->EX forwarding chains."""
    program = [
        addi(1, 0, 10), addi(2, 0, 20),
        add(3, 1, 2), add(4, 3, 1), add(5, 3, 2),
        addi(6, 0, 5), add(7, 5, 6), sub(8, 7, 6),
        sw(8, 0, 0), lw(9, 0, 0), sw(9, 4, 0),   # store of freshly loaded value
        HALT,
    ]
    check(dut, await run_program(dut, program), "[HAZARD]")


@cocotb.test()
async def test_load_use_hazard(dut):
    """Load followed immediately by a consumer (ALU, store data, branch, JALR)."""
    program = [
        addi(1, 0, 99), addi(2, 0, 7), sw(1, 0, 0),
        lw(3, 0, 0), add(4, 3, 2),                     # ALU use
        lw(5, 0, 0), sw(5, 8, 0),                      # store-data use
        lw(6, 0, 0), beq(6, 1, 8), addi(7, 0, 1),      # branch use (taken, skips addi)
        addi(10, 0, 72), sw(10, 12, 0),                # dmem[12] = address of the target below
        lw(11, 12, 0), jalr(12, 11, 0),                # jalr use -> jumps to byte 72
        addi(13, 0, 1), addi(14, 0, 1),                # skipped
        addi(15, 0, 1), addi(16, 0, 1),                # skipped
        HALT,                                          # index 18 = byte 72
    ]
    check(dut, await run_program(dut, program), "[LOAD-USE]")


@cocotb.test()
async def test_branches(dut):
    """All six branch types, taken and not taken, signed/unsigned corner cases."""
    program = [addi(1, 0, -1), addi(2, 0, 1), addi(3, 0, 1), addi(20, 0, 0)]
    cases = [
        (beq, 2, 3), (beq, 1, 2), (bne, 1, 2), (bne, 2, 3),
        (blt, 1, 2), (blt, 2, 1), (bge, 2, 1), (bge, 1, 2), (bge, 2, 3),
        (bltu, 2, 1), (bltu, 1, 2), (bgeu, 1, 2), (bgeu, 2, 1), (bgeu, 2, 3),
    ]
    for n, (br, rs1, rs2) in enumerate(cases):
        # taken => skips the marker; x20 bit n set => branch n NOT taken
        program += [br(rs1, rs2, 8), ori(20, 20, 1 << n) if n < 11 else addi(21 + n - 11, 0, 1)]
    program += [HALT]
    check(dut, await run_program(dut, program), "[BRANCH]")


@cocotb.test()
async def test_jal_jalr(dut):
    """Function call/return, link-register forwarding, JALR clears bit 0."""
    program = [
        addi(10, 0, 5),          # 0x00  arg
        jal(1, 0x20),            # 0x04  call f (0x24)
        add(11, 10, 0),          # 0x08  after return
        auipc(5, 0),             # 0x0C  x5 = 0x0C
        jalr(6, 5, 0x15),        # 0x10  -> (0x0C + 0x15) & ~1 = 0x20
        addi(12, 0, 1),          # 0x14  skipped
        addi(13, 0, 1),          # 0x18  skipped
        addi(14, 0, 1),          # 0x1C  skipped
        HALT,                    # 0x20
        # f: x10 = x10 * 2 + 1 ; uses link register immediately
        add(7, 1, 0),            # 0x24  link forwarded from MEM stage
        add(10, 10, 10),         # 0x28
        addi(10, 10, 1),         # 0x2C
        jalr(0, 1, 0),           # 0x30  return
    ]
    check(dut, await run_program(dut, program), "[JAL/JALR]")


@cocotb.test()
async def test_lui_auipc(dut):
    """LUI, AUIPC and full 32-bit constants."""
    program = []
    for rd, value in [(1, 0x12345678), (2, 0xDEADBEEF), (3, 0x80000000), (4, 0x00000FFF),
                      (5, 0xFFFFF800), (6, 0x7FFFFFFF), (7, 0x00001000)]:
        program += li(rd, value)
    program += [auipc(8, 1), auipc(9, 0xFFFFF), lui(10, 0xABCDE), add(11, 10, 1), HALT]
    check(dut, await run_program(dut, program), "[LUI/AUIPC]")


@cocotb.test()
async def test_byte_half(dut):
    """SB/SH/SW on every lane, LB/LH sign extension, LBU/LHU zero extension."""
    program = li(1, 0x8081F2F3) + [
        addi(2, 0, 0x100),
        sw(1, 0, 2),
        lb(3, 0, 2), lb(4, 1, 2), lb(5, 2, 2), lb(6, 3, 2),
        lbu(7, 0, 2), lbu(8, 3, 2),
        lh(9, 0, 2), lh(10, 2, 2), lhu(11, 0, 2), lhu(12, 2, 2),
        addi(13, 0, 0x5A),
        sb(13, 4, 2), sb(13, 5, 2), sb(13, 7, 2),     # partial word 0x100+4
        sh(1, 8, 2), sh(1, 14, 2),                   # halves of two words
        lw(14, 4, 2), lw(15, 8, 2), lw(16, 12, 2),
        HALT,
    ]
    check(dut, await run_program(dut, program), "[BYTE/HALF]")


@cocotb.test()
async def test_loops(dut):
    """Backward branches: sum 1..20, then copy an array with a loop."""
    init = {0x200 + 4 * i: (i * 0x01010101 + 7) & MASK for i in range(16)}
    program = [
        addi(1, 0, 0), addi(2, 0, 20),
        add(1, 1, 2), addi(2, 2, -1), bne(2, 0, -8),       # sum loop
        addi(3, 0, 0x200), addi(4, 0, 0x300), addi(5, 0, 16),
        lw(6, 0, 3), sw(6, 0, 4), addi(3, 3, 4), addi(4, 4, 4),
        addi(5, 5, -1), bne(5, 0, -20),                    # memcpy loop
        HALT,
    ]
    check(dut, await run_program(dut, program, init_dmem=init), "[LOOPS]")


# ════════════════════════════════════════════════════════════════
#  Random tests
# ════════════════════════════════════════════════════════════════

def random_program(rng, length=150, m_ops=False):
    R_OPS = [add, sub, sll, slt, sltu, xor, srl, sra, or_, and_]
    I_OPS = [addi, slti, sltiu, xori, ori, andi]
    SH_OPS = [slli, srli, srai]
    BR_OPS = [beq, bne, blt, bge, bltu, bgeu]
    LOADS = [(lb, 1), (lh, 2), (lw, 4), (lbu, 1), (lhu, 2)]
    STORES = [(sb, 1), (sh, 2), (sw, 4)]
    regs = list(range(1, 16))
    base = 31

    prog = li(base, 0x100)
    for r in regs:
        prog += li(r, rng.getrandbits(32))

    M_OPS = [mul, mulh, mulhsu, mulhu, div, divu, rem, remu]
    for _ in range(length):
        if m_ops and rng.random() < 0.15:
            prog.append(rng.choice(M_OPS)(rng.choice(regs), rng.choice(regs), rng.choice(regs)))
            continue
        rd, rs1, rs2 = rng.choice(regs), rng.choice(regs), rng.choice(regs)
        kind = rng.random()
        if kind < 0.35:
            prog.append(rng.choice(R_OPS)(rd, rs1, rs2))
        elif kind < 0.50:
            prog.append(rng.choice(I_OPS)(rd, rs1, rng.randint(-2048, 2047)))
        elif kind < 0.55:
            prog.append(rng.choice(SH_OPS)(rd, rs1, rng.randint(0, 31)))
        elif kind < 0.68:
            op, size = rng.choice(LOADS)
            prog.append(op(rd, size * rng.randint(0, 255 // size), base))
        elif kind < 0.80:
            op, size = rng.choice(STORES)
            prog.append(op(rs2, size * rng.randint(0, 255 // size), base))
        elif kind < 0.92:
            prog.append(rng.choice(BR_OPS)(rs1, rs2, 4 * rng.randint(2, 4)))
        elif kind < 0.95:
            prog.append(jal(rd, 4 * rng.randint(2, 4)))
        elif kind < 0.98:
            prog.append(lui(rd, rng.getrandbits(20)))
        else:
            prog.append(auipc(rd, rng.getrandbits(20)))
    return prog + [NOP] * 4 + [HALT]


@cocotb.test()
async def test_random(dut):
    """Constrained-random programs (ALU, loads/stores, forward branches/jumps)."""
    for seed in (1, 2, 3):
        prog = random_program(random.Random(seed))
        check(dut, await run_program(dut, prog), f"[RANDOM seed={seed}]")


@cocotb.test()
async def test_random_bus_stalls(dut):
    """Same random programs, but the data bus refuses ~40% of requests."""
    for seed in (4, 5, 6):
        prog = random_program(random.Random(seed))
        check(dut, await run_program(dut, prog, stall_prob=0.4, seed=seed),
              f"[STALL seed={seed}]")


@cocotb.test()
async def test_loops_bus_stalls(dut):
    """Loop test under heavy bus contention."""
    init = {0x200 + 4 * i: (i * 0x01010101 + 7) & MASK for i in range(16)}
    program = [
        addi(3, 0, 0x200), addi(4, 0, 0x300), addi(5, 0, 16),
        lw(6, 0, 3), add(7, 7, 6), sw(6, 0, 4), addi(3, 3, 4), addi(4, 4, 4),
        addi(5, 5, -1), bne(5, 0, -24),
        sw(7, 0x40, 4),
        HALT,
    ]
    check(dut, await run_program(dut, program, stall_prob=0.6, seed=9, init_dmem=init),
          "[LOOP STALL]")


# ════════════════════════════════════════════════════════════════
#  CSRs and interrupts
# ════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_csr(dut):
    """CSRRW/S/C and immediate forms, masks, read-only CSRs, forwarding."""
    program = li(1, 0xA5A5A5A7) + [
        csrrw(2, MSCRATCH, 1),        # x2 = 0 (old), mscratch = x1
        csrrs(3, MSCRATCH, 0),        # read
        addi(4, 3, 1),                # use CSR result immediately (forwarding)
        csrrci(5, MSCRATCH, 0x7),     # clear low bits, x5 = old
        csrrsi(6, MSCRATCH, 0x10),
        csrrs(7, MSCRATCH, 0),
        csrrw(8, MTVEC, 1),           # mtvec ignores [1:0]
        csrrs(9, MTVEC, 0),
        csrrwi(10, MSTATUS, 0x1F),    # only MIE (bit 3) sticks
        csrrs(11, MSTATUS, 0),        # MPP reads as 11
        csrrc(12, MSTATUS, 1),
        csrrs(13, MISA, 0),
        csrrw(14, MISA, 1),           # read-only
        csrrs(15, MISA, 0),
        li(16, 0xFFFFFFFF)[0],
        csrrw(17, MIE, 16),           # only MEIE (bit 11) sticks
        csrrs(18, MIE, 0),
        csrrwi(19, MIE, 0),
        csrrw(20, MEPC, 1),
        csrrs(21, MEPC, 0),
        lw(22, 0, 0), csrrw(0, MSCRATCH, 22), csrrs(23, MSCRATCH, 0),   # load-use into CSR
        HALT,
    ]
    check(dut, await run_program(dut, program), "[CSR]")


IRQ_COUNT_ADDR = 0x3F0
HANDLER_ADDR = 0x800


def with_irq_handler(body, mie_bits=0x800):
    """Enable interrupts, run `body`, HALT. Handler counts interrupts in memory
    and saves/restores its only scratch register through mscratch."""
    prog = li(29, HANDLER_ADDR) + [csrrw(0, MTVEC, 29)]
    prog += li(29, mie_bits) + [csrrw(0, MIE, 29), csrrsi(0, MSTATUS, 8)]
    prog += body + [NOP] * 4 + [HALT]
    assert len(prog) < HANDLER_ADDR // 4
    prog += [NOP] * (HANDLER_ADDR // 4 - len(prog))
    prog += [
        csrrw(0, MSCRATCH, 30),
        lw(30, IRQ_COUNT_ADDR, 0),
        addi(30, 30, 1),
        sw(30, IRQ_COUNT_ADDR, 0),
        csrrs(30, MSCRATCH, 0),
        MRET,
    ]
    return prog


def irq_pulser(rng, pulses, stats, line="irq"):
    """Raise irq at random times; drop it once the handler has counted it."""
    async def drive(dut):
        for _ in range(pulses):
            await ClockCycles(dut.clk, rng.randint(3, 60))
            before = int(dut.u_dmem.mem[IRQ_COUNT_ADDR // 4].value)
            await FallingEdge(dut.clk)
            getattr(dut, line).value = 1
            for _ in range(2000):
                await RisingEdge(dut.clk)
                if int(dut.u_dmem.mem[IRQ_COUNT_ADDR // 4].value) != before:
                    break
            else:
                raise AssertionError("interrupt was never taken")
            await FallingEdge(dut.clk)
            getattr(dut, line).value = 0
            stats["sent"] += 1
            stats["mepc"].append(int(dut.u_core.csrs.mepc_q.value))
    return drive


async def run_irq_test(dut, seed, stall_prob, tag, line="irq", cause=0x8000000B, m_ops=False):
    rng = random.Random(seed)
    body = random_program(rng, m_ops=m_ops)[:-5]   # strip NOPs + HALT
    body += [addi(1, 0, 0), addi(2, 0, 30),        # plus a loop, to be interrupted mid-branch
             add(1, 1, 2), addi(2, 2, -1), bne(2, 0, -8)]
    prog = with_irq_handler(body, mie_bits=0x800 if line == "irq" else 0x080)
    stats = {"sent": 0, "mepc": []}
    model = await run_program(dut, prog, stall_prob=stall_prob, seed=seed,
                              irq_driver=irq_pulser(rng, 12, stats, line))
    check(dut, model, tag, skip_words={IRQ_COUNT_ADDR // 4})
    taken = int(dut.u_dmem.mem[IRQ_COUNT_ADDR // 4].value)
    mcause = int(dut.u_core.csrs.mcause.value)
    dut._log.info(f"{tag} interrupts sent={stats['sent']} handled={taken} mcause=0x{mcause:08X}")
    assert taken == stats["sent"], "every interrupt must be handled exactly once"
    assert mcause == cause
    halt_pc = 4 * prog.index(HALT)
    mid = sum(1 for pc in stats["mepc"] if pc != halt_pc)
    dut._log.info(f"{tag} interrupted PCs: {[hex(pc) for pc in stats['mepc']]}")
    assert mid >= 4, f"only {mid} interrupts landed inside the program body"


@cocotb.test()
async def test_interrupts(dut):
    """Random programs interrupted at random points must give identical results."""
    for seed in (11, 12):
        await run_irq_test(dut, seed, 0.0, f"[IRQ seed={seed}]")


@cocotb.test()
async def test_interrupts_bus_stalls(dut):
    """Interrupts combined with random data-bus stalls and response delays."""
    for seed in (13, 14):
        await run_irq_test(dut, seed, 0.4, f"[IRQ+STALL seed={seed}]")


@cocotb.test()
async def test_timer_interrupts(dut):
    """Machine timer interrupt (mtip) at random points, with M ops and bus stalls."""
    await run_irq_test(dut, 21, 0.0, "[TIMER]", line="mtip", cause=0x80000007)
    await run_irq_test(dut, 22, 0.4, "[TIMER+STALL]", line="mtip", cause=0x80000007, m_ops=True)


# ════════════════════════════════════════════════════════════════
#  M extension
# ════════════════════════════════════════════════════════════════

M_CORNERS_A = [0, 1, 0xFFFFFFFF, 7, 0xFFFFFFF9, 0x80000000, 0x7FFFFFFF, 12345678, 0xFFFE7E33]
M_CORNERS_B = [0, 1, 0xFFFFFFFF, 3, 0xFFFFFFFD, 0x80000000, 0x7FFFFFFF]


@cocotb.test()
async def test_mul_div(dut):
    """All 8 RV32M ops on signed/unsigned corner cases (incl. /0 and overflow).

    Operand pairs come from a table in data memory, so loads feed the MDU
    directly (load-use stall + forwarding into multi-cycle ops)."""
    pairs = [(x, y) for x in M_CORNERS_A for y in M_CORNERS_B]
    table = 0x800
    init = {}
    for n, (x, y) in enumerate(pairs):
        init[table + 8 * n] = x
        init[table + 8 * n + 4] = y
    prog = [addi(31, 0, 0)] + li(20, table) + [addi(21, 0, len(pairs))]
    loop = len(prog)
    prog += [lw(1, 0, 20), lw(2, 4, 20),
             mul(10, 1, 2), mulh(11, 1, 2), mulhsu(12, 1, 2), mulhu(13, 1, 2),
             div(14, 1, 2), divu(15, 1, 2), rem(16, 1, 2), remu(17, 1, 2)]
    prog += [sw(10 + k, 4 * k, 31) for k in range(8)]
    prog += [addi(31, 31, 32), addi(20, 20, 8), addi(21, 21, -1)]
    prog += [bne(21, 0, 4 * (loop - len(prog))), HALT]
    model = RV32ISS(prog)          # loops: give the run budget for every executed M op
    for addr, value in init.items():
        model.store(addr, 4, value)
    model.run()
    check(dut, await run_program(dut, prog, init_dmem=init, extra_cycles=40 * 8 * len(pairs)),
          "[MUL/DIV]")


@cocotb.test()
async def test_random_m_ext(dut):
    """Random programs with M ops, forwarding into/out of the MDU, bus stalls + latency."""
    for seed in (31, 32):
        prog = random_program(random.Random(seed), m_ops=True)
        check(dut, await run_program(dut, prog), f"[RANDOM-M seed={seed}]")
    for seed in (33, 34):
        prog = random_program(random.Random(seed), m_ops=True)
        check(dut, await run_program(dut, prog, stall_prob=0.4, seed=seed), f"[RANDOM-M+STALL seed={seed}]")


# ════════════════════════════════════════════════════════════════
#  Synchronous exceptions
# ════════════════════════════════════════════════════════════════

TRAP_LOG, TRAP_PTR, TRAP_SAVE = 0x300, 0x3E4, 0x3E0


def trap_program():
    """Every exception type once; the handler logs (mcause, mepc, mtval) and skips."""
    main = li(29, HANDLER_ADDR) + [csrrw(0, MTVEC, 29)]
    main += li(1, TRAP_LOG) + [sw(1, TRAP_PTR, 0)]
    main += [ECALL, EBREAK, 0x00000000, 0xFFFFFFFF]            # ecall, ebreak, 2x illegal
    main += li(2, 0x101) + [lw(3, 0, 2), sh(1, 2, 2), lh(4, 0, 2), sw(1, 1, 2)]   # misaligned
    main += li(5, 0x80000000)
    main += [sw(1, 0x200, 0), lw(6, 0, 5), sw(2, 0x204, 0)]     # load fault between two stores
    main += [sw(1, 4, 5)]                                       # store access fault
    main += [lw(7, 8, 5), add(8, 7, 7)]                         # faulting load + load-use
    main += [beq(0, 0, 6), jal(9, 10)]                          # misaligned branch / jump target
    main += [mul(10, 2, 2), lw(11, 0x200, 0), add(12, 11, 10)]  # normal execution resumes
    main += [NOP] * 4 + [HALT]
    assert len(main) < HANDLER_ADDR // 4
    prog = main + [NOP] * (HANDLER_ADDR // 4 - len(main))
    prog += [
        csrrw(0, MSCRATCH, 30), sw(29, TRAP_SAVE, 0), lw(30, TRAP_PTR, 0),
        csrrs(29, MCAUSE, 0), sw(29, 0, 30),
        csrrs(29, MEPC, 0), sw(29, 4, 30),
        csrrs(29, MTVAL, 0), sw(29, 8, 30),
        addi(30, 30, 12), sw(30, TRAP_PTR, 0),
        csrrs(29, MEPC, 0), addi(29, 29, 4), csrrw(0, MEPC, 29),
        lw(29, TRAP_SAVE, 0), csrrs(30, MSCRATCH, 0), MRET,
    ]
    return prog


@cocotb.test()
async def test_traps(dut):
    """ecall, ebreak, illegal, misaligned load/store/target, load/store access faults."""
    for stall, tag in ((0.0, "[TRAPS]"), (0.4, "[TRAPS+STALL]")):
        model = await run_program(dut, trap_program(), stall_prob=stall, seed=41)
        check(dut, model, tag)
        causes = [c for c, _, _ in model.traps]
        dut._log.info(f"{tag} trap causes in order: {causes}")
        assert causes == [11, 3, 2, 2, 4, 6, 4, 6, 5, 7, 5, 0, 0], causes


@cocotb.test()
async def test_irq_priority(dut):
    """External and timer interrupt pending together: external is taken first."""
    log, ack = 0x380, 0x3F0
    main = li(29, HANDLER_ADDR) + [csrrw(0, MTVEC, 29)]
    main += li(29, 0x880) + [csrrw(0, MIE, 29)]
    main += [addi(28, 0, log), csrrsi(0, MSTATUS, 8)] + [NOP] * 30 + [HALT]
    prog = main + [NOP] * (HANDLER_ADDR // 4 - len(main))
    prog += [csrrs(27, MCAUSE, 0), sw(27, 0, 28), addi(28, 28, 4),
             lw(26, ack, 0), addi(26, 26, 1), sw(26, ack, 0), MRET]

    async def both(dut):
        await ClockCycles(dut.clk, 2)
        dut.irq.value = 1
        dut.mtip.value = 1
        for _ in range(400):
            await RisingEdge(dut.clk)
            n = int(dut.u_dmem.mem[ack // 4].value)
            if n >= 1:
                dut.irq.value = 0
            if n >= 2:
                dut.mtip.value = 0
                return
        raise AssertionError("interrupts were not handled")

    await run_program(dut, prog, irq_driver=both)
    first, second = int(dut.u_dmem.mem[log // 4].value), int(dut.u_dmem.mem[log // 4 + 1].value)
    dut._log.info(f"[IRQ PRIO] first mcause=0x{first:08X}, second=0x{second:08X}")
    assert (first, second) == (0x8000000B, 0x80000007)
