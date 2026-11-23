"""
CoreCascade SoC v2 address map and bus constants, as frozen in
docs/spec/memory_map.md (v1.0) and docs/spec/bus_obi.md (v1.0).

The unit tests check the RTL against these numbers, so they are written out
by hand from the spec rather than parsed from the RTL.
"""

MASK32 = 0xFFFF_FFFF

# ---- crossbar ports ---------------------------------------------------------
NM = 8                       # masters
NS = 11                      # slaves
PRIO_M = 7                   # display: wins every slave it requests

MASTERS = ["cpu", "boot", "gpu0", "gpu1", "gpu2", "gpu3", "cp", "display"]
SLAVES = ["itcm", "dtcm"] + [f"bank{b}" for b in range(8)] + ["periph"]

# slave s is hit when (addr & SLV_MASK[s]) == SLV_BASE[s]
SLV_BASE = [0x0000_0000, 0x1000_0000] + [0x2000_0000 | (b << 2) for b in range(8)] + [0x4000_0000]
SLV_MASK = [0xF000_0000, 0xF000_0000] + [0xF000_001C] * 8 + [0xF000_0000]

S_ITCM, S_DTCM, S_BANK0, S_PERIPH = 0, 1, 2, 10


def slave_of(addr):
    """Index of the slave an address hits, or None (the crossbar answers err)."""
    for s in range(NS):
        if addr & SLV_MASK[s] == SLV_BASE[s]:
            return s
    return None


# ---- regions (FPGA_FULL sizes) ----------------------------------------------
ITCM_BASE, ITCM_SIZE = 0x0000_0000, 32 * 1024
DTCM_BASE, DTCM_SIZE = 0x1000_0000, 16 * 1024
SHARED_BASE, SHARED_SIZE = 0x2000_0000, 256 * 1024
PERIPH_BASE = 0x4000_0000
NUM_BANKS = 8


def bank_of(addr):
    """Shared SRAM is word-interleaved: bank = addr[4:2]."""
    return (addr >> 2) & (NUM_BANKS - 1)


def bank_row(addr, row_bits):
    """Row inside a bank: addr[5 +: row_bits]."""
    return (addr >> 5) & ((1 << row_bits) - 1)


# ---- peripherals (behind the bridge, 4 KB apart) ----------------------------
NP = 6
PERIPHS = ["sysctl", "uart", "timer", "irq_ctrl", "gpu_cp", "display"]


def periph_addr(idx, offset):
    return PERIPH_BASE | (idx << 12) | (offset & 0xFFF)


def random_addr(rng, target):
    """A random word-aligned address that hits `target`
    (a slave index, or None for an unmapped address)."""
    if target is None:
        top = rng.choice([0x3, 0x5, 0x6, 0x7, 0x8, 0x9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF])
        return (top << 28) | (rng.getrandbits(28) & ~3)
    if target == S_ITCM:
        return ITCM_BASE + rng.randrange(0, ITCM_SIZE, 4)
    if target == S_DTCM:
        return DTCM_BASE + rng.randrange(0, DTCM_SIZE, 4)
    if target == S_PERIPH:
        return periph_addr(rng.randrange(NP), rng.randrange(0, 0x40, 4))
    bank = target - S_BANK0
    row = rng.randrange(SHARED_SIZE // (4 * NUM_BANKS))
    return SHARED_BASE | (row << 5) | (bank << 2)
