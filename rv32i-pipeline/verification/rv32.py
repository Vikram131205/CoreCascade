"""
RV32I helpers shared by the CPU and SoC testbenches.

  * Encoders  : tiny assembler, one function per instruction (addi(rd, rs1, imm), ...)
  * RV32ISS   : golden instruction-set simulator (architectural state only, no pipeline)

Branch / jump offsets are in bytes, relative to the branch instruction.
"""

MASK = 0xFFFFFFFF


def u32(v):
    return v & MASK


def s32(v):
    v &= MASK
    return v - (1 << 32) if v & 0x80000000 else v


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


# ════════════════════════════════════════════════════════════════
#  Encoders
# ════════════════════════════════════════════════════════════════

def _r(f7, rs2, rs1, f3, rd, op=0x33):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def _i(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def _s(imm, rs2, rs1, f3):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23

def _b(off, rs2, rs1, f3):
    off &= 0x1FFF
    return (((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) \
        | (f3 << 12) | (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | 0x63

def _u(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

# R-type
def add(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 0, rd)
def sub(rd, rs1, rs2):  return _r(0x20, rs2, rs1, 0, rd)
def sll(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 1, rd)
def slt(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 2, rd)
def sltu(rd, rs1, rs2): return _r(0x00, rs2, rs1, 3, rd)
def xor(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 4, rd)
def srl(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 5, rd)
def sra(rd, rs1, rs2):  return _r(0x20, rs2, rs1, 5, rd)
def or_(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 6, rd)
def and_(rd, rs1, rs2): return _r(0x00, rs2, rs1, 7, rd)
# I-type ALU
def addi(rd, rs1, imm):  return _i(imm, rs1, 0, rd, 0x13)
def slti(rd, rs1, imm):  return _i(imm, rs1, 2, rd, 0x13)
def sltiu(rd, rs1, imm): return _i(imm, rs1, 3, rd, 0x13)
def xori(rd, rs1, imm):  return _i(imm, rs1, 4, rd, 0x13)
def ori(rd, rs1, imm):   return _i(imm, rs1, 6, rd, 0x13)
def andi(rd, rs1, imm):  return _i(imm, rs1, 7, rd, 0x13)
def slli(rd, rs1, sh):   return _i(sh & 0x1F, rs1, 1, rd, 0x13)
def srli(rd, rs1, sh):   return _i(sh & 0x1F, rs1, 5, rd, 0x13)
def srai(rd, rs1, sh):   return _i(0x400 | (sh & 0x1F), rs1, 5, rd, 0x13)
# loads / stores
def lb(rd, imm, rs1):  return _i(imm, rs1, 0, rd, 0x03)
def lh(rd, imm, rs1):  return _i(imm, rs1, 1, rd, 0x03)
def lw(rd, imm, rs1):  return _i(imm, rs1, 2, rd, 0x03)
def lbu(rd, imm, rs1): return _i(imm, rs1, 4, rd, 0x03)
def lhu(rd, imm, rs1): return _i(imm, rs1, 5, rd, 0x03)
def sb(rs2, imm, rs1): return _s(imm, rs2, rs1, 0)
def sh(rs2, imm, rs1): return _s(imm, rs2, rs1, 1)
def sw(rs2, imm, rs1): return _s(imm, rs2, rs1, 2)
# branches
def beq(rs1, rs2, off):  return _b(off, rs2, rs1, 0)
def bne(rs1, rs2, off):  return _b(off, rs2, rs1, 1)
def blt(rs1, rs2, off):  return _b(off, rs2, rs1, 4)
def bge(rs1, rs2, off):  return _b(off, rs2, rs1, 5)
def bltu(rs1, rs2, off): return _b(off, rs2, rs1, 6)
def bgeu(rs1, rs2, off): return _b(off, rs2, rs1, 7)
# jumps / upper immediates
def jal(rd, off):
    off &= 0x1FFFFF
    return (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21) | (((off >> 11) & 1) << 20) \
        | (((off >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F
def jalr(rd, rs1, imm): return _i(imm, rs1, 0, rd, 0x67)
# CSRs (csr = 12-bit address)
def csrrw(rd, csr, rs1):   return _i(csr, rs1, 1, rd, 0x73)
def csrrs(rd, csr, rs1):   return _i(csr, rs1, 2, rd, 0x73)
def csrrc(rd, csr, rs1):   return _i(csr, rs1, 3, rd, 0x73)
def csrrwi(rd, csr, zimm): return _i(csr, zimm, 5, rd, 0x73)
def csrrsi(rd, csr, zimm): return _i(csr, zimm, 6, rd, 0x73)
def csrrci(rd, csr, zimm): return _i(csr, zimm, 7, rd, 0x73)
MRET = 0x30200073
ECALL  = 0x00000073
EBREAK = 0x00100073
def mul(rd, rs1, rs2):    return _r(0x01, rs2, rs1, 0, rd)
def mulh(rd, rs1, rs2):   return _r(0x01, rs2, rs1, 1, rd)
def mulhsu(rd, rs1, rs2): return _r(0x01, rs2, rs1, 2, rd)
def mulhu(rd, rs1, rs2):  return _r(0x01, rs2, rs1, 3, rd)
def div(rd, rs1, rs2):    return _r(0x01, rs2, rs1, 4, rd)
def divu(rd, rs1, rs2):   return _r(0x01, rs2, rs1, 5, rd)
def rem(rd, rs1, rs2):    return _r(0x01, rs2, rs1, 6, rd)
def remu(rd, rs1, rs2):   return _r(0x01, rs2, rs1, 7, rd)
MTVAL = 0x343
MSTATUS, MISA, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE, MIP =     0x300, 0x301, 0x304, 0x305, 0x340, 0x341, 0x342, 0x344
def lui(rd, imm20):     return _u(imm20, rd, 0x37)
def auipc(rd, imm20):   return _u(imm20, rd, 0x17)

NOP  = addi(0, 0, 0)
HALT = jal(0, 0)          # jump-to-self: marks the end of a test program


def li(rd, value):
    """Load a full 32-bit constant (LUI + ADDI, like the assembler pseudo-op)."""
    value = u32(value)
    lo = sext(value, 12)
    hi = u32(value - lo) >> 12
    out = []
    if hi:
        out.append(lui(rd, hi))
        if lo:
            out.append(addi(rd, rd, lo))
    else:
        out.append(addi(rd, 0, lo))
    return out


# ════════════════════════════════════════════════════════════════
#  Golden model
# ════════════════════════════════════════════════════════════════

class RV32ISS:
    """Architectural RV32IM + machine-mode trap simulator.

    Instruction and data memory are separate. Data addresses with bit 31 set
    raise access faults (matching the testbench's OBI slave model).
    Interrupts are not modelled (tests compare against an uninterrupted run).
    """

    def __init__(self, program, dmem_bytes=4096):
        self.imem = list(program)
        self.dmem = bytearray(dmem_bytes)
        self.regs = [0] * 32
        self.pc = 0
        self.retired = 0
        self.traps = []          # (mcause, mepc, mtval) of every trap taken
        self.csr = {MSTATUS: 0, MIE: 0, MTVEC: 0, MSCRATCH: 0, MEPC: 0, MCAUSE: 0, MTVAL: 0}

    # ---- data memory (little endian) ----
    def load(self, addr, size, signed):
        v = int.from_bytes(self.dmem[addr:addr + size], "little")
        return u32(sext(v, 8 * size)) if signed else v

    def store(self, addr, size, value):
        self.dmem[addr:addr + size] = (value & ((1 << (8 * size)) - 1)).to_bytes(size, "little")

    def csr_read(self, addr):
        if addr == MSTATUS:
            return self.csr[MSTATUS] | 0x1800        # MPP = M
        if addr == MISA:
            return 0x40001100                        # RV32IM
        if addr == MIP:
            return 0
        return self.csr.get(addr, 0)

    def csr_write(self, addr, value):
        masks = {MSTATUS: 0x88, MIE: 0x880, MTVEC: ~3 & MASK, MSCRATCH: MASK,
                 MEPC: ~3 & MASK, MCAUSE: MASK, MTVAL: MASK}
        if addr in masks:
            self.csr[addr] = value & masks[addr]

    def word(self, index):
        return int.from_bytes(self.dmem[4 * index:4 * index + 4], "little")

    def trap(self, cause, tval):
        self.traps.append((cause, self.pc, tval))
        self.csr[MEPC] = self.pc & ~3 & MASK
        self.csr[MCAUSE] = cause
        self.csr[MTVAL] = u32(tval)
        mie = (self.csr[MSTATUS] >> 3) & 1
        self.csr[MSTATUS] = (mie << 7)                # MPIE = MIE, MIE = 0
        self.pc = self.csr[MTVEC]
        self.retired += 1

    # ---- execution ----
    def run(self, max_steps=100000):
        for _ in range(max_steps):
            inst = self.imem[self.pc // 4] if self.pc // 4 < len(self.imem) else NOP
            if inst == HALT:
                return
            self.step(inst)
        raise RuntimeError("golden model did not reach HALT")

    @staticmethod
    def illegal(inst):
        op, f3, f7, imm = inst & 0x7F, (inst >> 12) & 7, inst >> 25, inst >> 20
        if op == 0x33:
            return not (f7 in (0x00, 0x01) or (f7 == 0x20 and f3 in (0, 5)))
        if op == 0x13:
            return (f3 == 1 and f7 != 0) or (f3 == 5 and f7 not in (0x00, 0x20))
        if op == 0x03:
            return f3 in (3, 6, 7)
        if op == 0x23:
            return f3 > 2
        if op == 0x63:
            return f3 in (2, 3)
        if op == 0x67:
            return f3 != 0
        if op in (0x6F, 0x37, 0x17, 0x0F):
            return False
        if op == 0x73:
            if f3 == 0:
                return imm not in (0x000, 0x001, 0x302, 0x105)
            return f3 == 4
        return True

    def step(self, inst):
        op = inst & 0x7F
        rd = (inst >> 7) & 0x1F
        f3 = (inst >> 12) & 0x7
        rs1 = (inst >> 15) & 0x1F
        rs2 = (inst >> 20) & 0x1F
        f7 = inst >> 25
        a, b = self.regs[rs1], self.regs[rs2]
        imm_i = sext(inst >> 20, 12)
        imm_s = sext(((inst >> 25) << 5) | ((inst >> 7) & 0x1F), 12)
        imm_b = sext((((inst >> 31) & 1) << 12) | (((inst >> 7) & 1) << 11)
                     | (((inst >> 25) & 0x3F) << 5) | (((inst >> 8) & 0xF) << 1), 13)
        imm_j = sext((((inst >> 31) & 1) << 20) | (((inst >> 12) & 0xFF) << 12)
                     | (((inst >> 20) & 1) << 11) | (((inst >> 21) & 0x3FF) << 1), 21)
        imm_u = inst & 0xFFFFF000

        if self.illegal(inst):
            return self.trap(2, 0)

        next_pc = self.pc + 4
        result = None

        if op == 0x33 and f7 == 0x01:  # M extension
            sa, sb = s32(a), s32(b)
            if f3 == 0:
                result = a * b
            elif f3 == 1:
                result = (sa * sb) >> 32
            elif f3 == 2:
                result = (sa * b) >> 32
            elif f3 == 3:
                result = (a * b) >> 32
            elif f3 == 4:   # DIV
                if b == 0:
                    result = MASK
                elif a == 0x80000000 and b == MASK:
                    result = 0x80000000
                else:
                    q = abs(sa) // abs(sb)
                    result = -q if (sa < 0) != (sb < 0) else q
            elif f3 == 5:   # DIVU
                result = MASK if b == 0 else a // b
            elif f3 == 6:   # REM
                if b == 0:
                    result = a
                elif a == 0x80000000 and b == MASK:
                    result = 0
                else:
                    r = abs(sa) % abs(sb)
                    result = -r if sa < 0 else r
            else:           # REMU
                result = a if b == 0 else a % b
        elif op == 0x33:  # R-type
            sh = b & 0x1F
            result = {
                (0, 0x00): a + b, (0, 0x20): a - b,
                (1, 0x00): a << sh,
                (2, 0x00): int(s32(a) < s32(b)), (3, 0x00): int(a < b),
                (4, 0x00): a ^ b,
                (5, 0x00): a >> sh, (5, 0x20): s32(a) >> sh,
                (6, 0x00): a | b, (7, 0x00): a & b,
            }[(f3, f7)]
        elif op == 0x13:  # I-type ALU
            sh = imm_i & 0x1F
            if f3 == 5:
                result = (s32(a) >> sh) if (f7 & 0x20) else (a >> sh)
            else:
                result = {
                    0: a + imm_i, 1: a << sh,
                    2: int(s32(a) < imm_i), 3: int(a < u32(imm_i)),
                    4: a ^ u32(imm_i), 6: a | u32(imm_i), 7: a & u32(imm_i),
                }[f3]
        elif op == 0x03:  # loads
            addr = u32(a + imm_i)
            size, signed = {0: (1, True), 1: (2, True), 2: (4, False),
                            4: (1, False), 5: (2, False)}[f3]
            if addr % size:
                return self.trap(4, addr)
            if addr & 0x80000000:
                return self.trap(5, addr)
            result = self.load(addr, size, signed)
        elif op == 0x23:  # stores
            addr = u32(a + imm_s)
            size = {0: 1, 1: 2, 2: 4}[f3]
            if addr % size:
                return self.trap(6, addr)
            if addr & 0x80000000:
                return self.trap(7, addr)
            self.store(addr, size, b)
        elif op == 0x63:  # branches
            taken = {
                0: a == b, 1: a != b,
                4: s32(a) < s32(b), 5: s32(a) >= s32(b),
                6: a < b, 7: a >= b,
            }[f3]
            if taken:
                next_pc = u32(self.pc + imm_b)
                if next_pc & 2:
                    return self.trap(0, next_pc)
        elif op == 0x6F:  # JAL
            next_pc = u32(self.pc + imm_j)
            if next_pc & 2:
                return self.trap(0, next_pc)
            result = self.pc + 4
        elif op == 0x67:  # JALR
            next_pc = u32(a + imm_i) & ~1
            if next_pc & 2:
                return self.trap(0, next_pc)
            result = self.pc + 4
        elif op == 0x37:  # LUI
            result = imm_u
        elif op == 0x17:  # AUIPC
            result = self.pc + imm_u
        elif op == 0x73 and f3 == 0:
            imm = inst >> 20
            if imm == 0x000:
                return self.trap(11, 0)
            if imm == 0x001:
                return self.trap(3, 0)
            if imm == 0x302:  # MRET
                mpie = (self.csr[MSTATUS] >> 7) & 1
                self.csr[MSTATUS] = (mpie << 3) | 0x80
                next_pc = self.csr[MEPC]
            # WFI = NOP
        elif op == 0x73:  # CSR instructions
            addr = inst >> 20
            old = self.csr_read(addr)
            src = rs1 if f3 & 4 else a
            new = {1: src, 2: old | src, 3: old & ~src}[f3 & 3]
            self.csr_write(addr, u32(new))
            result = old
        # FENCE = NOP

        if result is not None and rd != 0:
            self.regs[rd] = u32(result)
        self.pc = u32(next_pc)
        self.retired += 1
