#!/usr/bin/env python3
"""
tinygpu_asm - assembler and disassembler for the tiny-gpu ISA
(https://github.com/adam-maj/tiny-gpu, the GPU in CoreCascade SoC v1 and v2).

    tinygpu_asm.py a.s b.s -o kernels.h        C header: one array per kernel
    tinygpu_asm.py a.s -f hex -o a.hex         one 4-digit word per line ($readmemh)
    tinygpu_asm.py a.s -f bin -o a.bin         raw 16-bit little-endian words
    tinygpu_asm.py a.s -l a.lst                listing (address, word, source)
    tinygpu_asm.py -d 0x50DE 0x300F ...        disassemble words
    tinygpu_asm.py -d a.hex                    disassemble a hex file

Source syntax (one instruction per line; the syntax of tiny-gpu's README):

    .kernel matadd              ; names the kernel: C array k_matadd
    .equ    baseB, 8            ; named constant
            MUL   R0, %blockIdx, %blockDim
            ADD   R0, R0, %threadIdx
            CONST R2, #baseB    ; #imm: 0..255 or -128..-1, decimal/0x/0b or a .equ name
    LOOP:   LDR   R4, R4        ; R4 = mem[R4]
            STR   R7, R6        ; mem[R7] = R6
            CMP   R9, R2
            BRn   LOOP          ; BR + any of n z p, target = label or number
            RET
    Comments start with ';' or '//'. Mnemonics and registers are case-insensitive.

Encoding (16 bits, [15:12] opcode):
    NOP   0000 0000 0000 0000        ADD/SUB/MUL/DIV  0011/0100/0101/0110 dddd ssss tttt
    BRnzp 0001 nzp0 iiii iiii        LDR   0111 dddd ssss 0000
    CMP   0010 0000 ssss tttt        STR   1000 0000 ssss tttt
    CONST 1001 dddd iiii iiii        RET   1111 0000 0000 0000
    R13 = %blockIdx, R14 = %blockDim, R15 = %threadIdx (read-only).

What the upstream RTL actually does with CMP / BRnzp (checked in simulation):
the comparison is unsigned and the flag that instruction bit 11 ('n') tests is
set whenever rs != rt, so
    BRn   branches if rs != rt        BRz  branches if rs == rt
    BRp   never branches              BRnz always branches (after a CMP)
and before the first CMP of a thread no branch is taken. The assembler encodes
the documented mnemonics bit-exactly and warns about 'p'.
"""

import argparse
import os
import re
import sys

OPCODES = {"NOP": 0x0, "BR": 0x1, "CMP": 0x2, "ADD": 0x3, "SUB": 0x4, "MUL": 0x5,
           "DIV": 0x6, "LDR": 0x7, "STR": 0x8, "CONST": 0x9, "RET": 0xF}
ALU_OPS = ("ADD", "SUB", "MUL", "DIV")
SPECIAL_REGS = {"%blockidx": 13, "%blockdim": 14, "%threadidx": 15}
REG_NAMES = {13: "%blockIdx", 14: "%blockDim", 15: "%threadIdx"}
MAX_WORDS = 256                     # 8-bit PC; also the command processor's limit
FIRST_READONLY = 13


class AsmError(Exception):
    pass


class Program:
    """An assembled kernel."""

    def __init__(self, name, words, lines, source):
        self.name = name
        self.words = words            # list of 16-bit ints
        self.lines = lines            # source text per word (for listings/comments)
        self.source = source


# ---------------------------------------------------------------------------
# assembler
# ---------------------------------------------------------------------------
def _strip_comment(line):
    for mark in (";", "//"):
        i = line.find(mark)
        if i >= 0:
            line = line[:i]
    return line.strip()


def _number(text, symbols, what):
    t = text.strip()
    if t.startswith("#"):
        t = t[1:].strip()
    if not t:
        raise AsmError(f"missing {what}")
    if re.fullmatch(r"[A-Za-z_]\w*", t):
        if t not in symbols:
            raise AsmError(f"unknown symbol '{t}'")
        return symbols[t]
    try:
        return int(t, 0)
    except ValueError:
        raise AsmError(f"bad {what} '{text.strip()}'") from None


def _reg(text):
    t = text.strip()
    low = t.lower()
    if low in SPECIAL_REGS:
        return SPECIAL_REGS[low]
    m = re.fullmatch(r"[rR](\d+)", t)
    if not m or int(m.group(1)) > 15:
        raise AsmError(f"bad register '{t}' (R0-R15, %blockIdx, %blockDim, %threadIdx)")
    return int(m.group(1))


def _dest(text):
    r = _reg(text)
    if r >= FIRST_READONLY:
        raise AsmError(f"{REG_NAMES[r]} (R{r}) is read-only; write R0-R12")
    return r


def _operands(text, n, mnemonic):
    ops = [o.strip() for o in text.split(",")] if text.strip() else []
    if len(ops) != n:
        raise AsmError(f"{mnemonic} takes {n} operand{'s' if n != 1 else ''}, got {len(ops)}")
    return ops


def _branch_cond(mnemonic):
    """'BRnzp' style -> 3-bit nzp mask, or None if not a branch."""
    m = re.fullmatch(r"[Bb][Rr]([NZPnzp]+)", mnemonic)
    if not m:
        return None
    cond = m.group(1).lower()
    if cond not in ("n", "z", "p", "nz", "np", "zp", "nzp"):
        raise AsmError(f"bad branch condition '{m.group(1)}' (letters n, z, p in that order)")
    return (4 if "n" in cond else 0) | (2 if "z" in cond else 0) | (1 if "p" in cond else 0)


def assemble(source, name="kernel", filename="<source>", warn=None):
    """Assemble tiny-gpu source text. Returns a Program; raises AsmError listing all errors."""
    errors, symbols, labels = [], {}, {}
    items = []                       # (lineno, text, mnemonic, operands)
    kernel_name = name

    # pass 1: labels, directives, instruction addresses
    for lineno, raw in enumerate(source.splitlines(), 1):
        line = _strip_comment(raw)
        try:
            while True:
                m = re.match(r"([A-Za-z_]\w*)\s*:\s*(.*)$", line)
                if not m:
                    break
                label, line = m.group(1), m.group(2)
                if label in labels or label in symbols:
                    raise AsmError(f"'{label}' defined twice")
                labels[label] = len(items)
            if not line:
                continue
            parts = line.split(None, 1)
            mnemonic, rest = parts[0], (parts[1] if len(parts) > 1 else "")
            if mnemonic.startswith("."):
                d = mnemonic.lower()
                if d == ".kernel":
                    if not re.fullmatch(r"[A-Za-z_]\w*", rest.strip()):
                        raise AsmError(".kernel needs a C identifier")
                    kernel_name = rest.strip()
                elif d == ".equ":
                    sym, value = _operands(rest, 2, ".equ")
                    if not re.fullmatch(r"[A-Za-z_]\w*", sym):
                        raise AsmError(f"bad symbol name '{sym}'")
                    if sym in symbols or sym in labels:
                        raise AsmError(f"'{sym}' defined twice")
                    symbols[sym] = _number(value, symbols, "value")
                elif d == ".word":
                    items.append((lineno, raw.strip(), ".word", rest))
                else:
                    raise AsmError(f"unknown directive '{mnemonic}'")
                continue
            items.append((lineno, raw.strip(), mnemonic, rest))
        except AsmError as e:
            errors.append(f"{filename}:{lineno}: {e}")

    if len(items) > MAX_WORDS:
        errors.append(f"{filename}: {len(items)} instructions; tiny-gpu programs hold at most {MAX_WORDS}")

    # pass 2: encode
    words, texts = [], []
    has_ret = False
    for lineno, text, mnemonic, rest in items:
        try:
            up = mnemonic.upper()
            cond = _branch_cond(mnemonic)
            if mnemonic == ".word":
                w = _number(rest, symbols, "word")
                if not 0 <= w <= 0xFFFF:
                    raise AsmError(f".word value {w} does not fit in 16 bits")
            elif cond is not None:
                (target,) = _operands(rest, 1, mnemonic)
                t = target.strip().lstrip("#").strip()
                if t in labels:
                    addr = labels[t]
                else:
                    addr = _number(target, symbols, "branch target")
                if not 0 <= addr < max(len(items), 1):
                    raise AsmError(f"branch target {addr} is outside the program (0..{len(items) - 1})")
                if cond & 1 and warn is not None:
                    msg = ("'p' is never true on the tiny-gpu RTL; this branch is never taken" if cond == 1
                           else "'p' has no effect on the tiny-gpu RTL")
                    warn(f"{filename}:{lineno}: warning: {msg}")
                w = (OPCODES["BR"] << 12) | (cond << 9) | addr
            elif up in ("NOP", "RET"):
                _operands(rest, 0, up)
                w = OPCODES[up] << 12
                has_ret |= up == "RET"
            elif up in ALU_OPS:
                rd, rs, rt = _operands(rest, 3, up)
                w = (OPCODES[up] << 12) | (_dest(rd) << 8) | (_reg(rs) << 4) | _reg(rt)
            elif up == "CMP":
                rs, rt = _operands(rest, 2, up)
                w = (OPCODES[up] << 12) | (_reg(rs) << 4) | _reg(rt)
            elif up == "LDR":
                rd, rs = _operands(rest, 2, up)
                w = (OPCODES[up] << 12) | (_dest(rd) << 8) | (_reg(rs) << 4)
            elif up == "STR":
                rs, rt = _operands(rest, 2, up)
                w = (OPCODES[up] << 12) | (_reg(rs) << 4) | _reg(rt)
            elif up == "CONST":
                rd, imm = _operands(rest, 2, up)
                v = _number(imm, symbols, "immediate")
                if not -128 <= v <= 255:
                    raise AsmError(f"immediate {v} does not fit in 8 bits (-128..255)")
                w = (OPCODES[up] << 12) | (_dest(rd) << 8) | (v & 0xFF)
            else:
                raise AsmError(f"unknown instruction '{mnemonic}'")
            words.append(w)
            texts.append(text)
        except AsmError as e:
            errors.append(f"{filename}:{lineno}: {e}")

    if errors:
        raise AsmError("\n".join(errors))
    if words and not has_ret and warn is not None:
        warn(f"{filename}: warning: no RET; threads never finish")
    return Program(kernel_name, words, texts, filename)


def assemble_file(path, warn=None):
    stem = os.path.splitext(os.path.basename(path))[0]
    with open(path) as f:
        return assemble(f.read(), name=re.sub(r"\W", "_", stem), filename=path, warn=warn)


# ---------------------------------------------------------------------------
# disassembler
# ---------------------------------------------------------------------------
def _rname(r):
    return REG_NAMES.get(r, f"R{r}")


def decode(w):
    """One word -> canonical assembly text (without label resolution), or None
    if the word is not something the assembler would produce."""
    op, d, s, t, imm = w >> 12, (w >> 8) & 0xF, (w >> 4) & 0xF, w & 0xF, w & 0xFF
    if op == 0x0 and w == 0:
        return "NOP"
    if op == 0xF and w == 0xF000:
        return "RET"
    if op == 0x1 and (w >> 8) & 1 == 0 and (w >> 9) & 7:
        cond = (w >> 9) & 7
        letters = ("n" if cond & 4 else "") + ("z" if cond & 2 else "") + ("p" if cond & 1 else "")
        return f"BR{letters} {imm}"
    if op == 0x2 and d == 0:
        return f"CMP {_rname(s)}, {_rname(t)}"
    if 0x3 <= op <= 0x6 and d < FIRST_READONLY:
        return f"{ALU_OPS[op - 3]} {_rname(d)}, {_rname(s)}, {_rname(t)}"
    if op == 0x7 and t == 0 and d < FIRST_READONLY:
        return f"LDR {_rname(d)}, {_rname(s)}"
    if op == 0x8 and d == 0:
        return f"STR {_rname(s)}, {_rname(t)}"
    if op == 0x9 and d < FIRST_READONLY:
        return f"CONST {_rname(d)}, #{imm}"
    return None


def disassemble(words, name=None):
    """Words -> source text that assembles back to exactly the same words."""
    targets = sorted({w & 0xFF for w in words if decode(w) and decode(w).startswith("BR")
                      and (w & 0xFF) < len(words)})
    label = {a: f"L{a:02X}" for a in targets}
    out = [f".kernel {name}"] if name else []
    for addr, w in enumerate(words):
        text = decode(w)
        if text is not None and text.startswith("BR") and (w & 0xFF) >= len(words):
            text = None                                   # target outside this program
        if text is None:
            text = f".word 0x{w:04X}"
        elif text.startswith("BR"):
            mnem, tgt = text.split()
            text = f"{mnem} {label.get(int(tgt), tgt)}"
        prefix = f"{label[addr]}:" if addr in label else ""
        out.append(f"{prefix:<8}{text:<32}; {addr:02X}: {w:04X}")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# output formats
# ---------------------------------------------------------------------------
def c_header(programs, guard, ctype="uint32_t", section=".gpu", prefix="k_", tool="sw/asm/tinygpu_asm.py"):
    srcs = ", ".join(p.source for p in programs)
    attr = f' __attribute__((section("{section}")))' if section else ""
    out = [f"/* Generated by {tool} from {srcs}. Do not edit. */",
           f"#ifndef {guard}", f"#define {guard}", "", "#include <stdint.h>", ""]
    for p in programs:
        out.append(f"/* {p.name}: {len(p.words)} instructions */")
        out.append(f"static const {ctype} {prefix}{p.name}[]{attr} = {{")
        for addr, (w, text) in enumerate(zip(p.words, p.lines)):
            out.append(f"    0x{w:04X}, /* {addr:02X}: {text.replace('*/', '* /')} */")
        out.append("};")
        out.append("")
    out.append(f"#endif /* {guard} */")
    return "\n".join(out) + "\n"


def listing(p):
    out = [f"; {p.name} ({p.source}): {len(p.words)} instructions", "; addr word  source"]
    for addr, (w, text) in enumerate(zip(p.words, p.lines)):
        out.append(f"  {addr:02X}   {w:04X}  {text}")
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="tiny-gpu assembler / disassembler")
    ap.add_argument("inputs", nargs="+", help="source files, or words / a hex file with -d")
    ap.add_argument("-o", "--output", help="output file (default: stdout)")
    ap.add_argument("-f", "--format", choices=("c", "hex", "bin"), default="c")
    ap.add_argument("-l", "--listing", help="also write a listing (single input)")
    ap.add_argument("-d", "--disassemble", action="store_true")
    ap.add_argument("--ctype", default="uint32_t", help="C element type (uint32_t: one instruction per word)")
    ap.add_argument("--section", default=".gpu", help="linker section for C arrays ('' for none)")
    ap.add_argument("--prefix", default="k_", help="C array name prefix")
    ap.add_argument("-W", "--werror", action="store_true", help="treat warnings as errors")
    args = ap.parse_args(argv)

    warnings = []

    def warn(msg):
        warnings.append(msg)
        print(msg, file=sys.stderr)

    try:
        if args.disassemble:
            if len(args.inputs) == 1 and os.path.isfile(args.inputs[0]):
                with open(args.inputs[0]) as f:
                    tokens = f.read().split()
            else:
                tokens = args.inputs
            words = [int(tok, 16) & 0xFFFF for tok in tokens if not tok.startswith("//")]
            text, mode = disassemble(words), "w"
        else:
            programs = [assemble_file(p, warn) for p in args.inputs]
            if args.werror and warnings:
                raise AsmError("warnings treated as errors")
            if args.listing:
                with open(args.listing, "w") as f:
                    f.write("".join(listing(p) for p in programs))
            if args.format == "c":
                guard = re.sub(r"\W", "_", os.path.basename(args.output or "kernels.h")).upper()
                text = c_header(programs, guard, args.ctype, args.section, args.prefix)
                mode = "w"
            elif args.format == "hex":
                text = "".join(f"{w:04X}\n" for p in programs for w in p.words)
                mode = "w"
            else:
                text = b"".join(w.to_bytes(2, "little") for p in programs for w in p.words)
                mode = "wb"
    except AsmError as e:
        print(e, file=sys.stderr)
        return 1

    if args.output:
        with open(args.output, mode) as f:
            f.write(text)
    elif mode == "wb":
        sys.stdout.buffer.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
