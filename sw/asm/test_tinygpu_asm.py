#!/usr/bin/env python3
"""
Tests for tinygpu_asm (stdlib unittest; run: python3 sw/asm/test_tinygpu_asm.py).

  - every instruction encodes to the bit fields tiny-gpu's decoder.sv reads
  - SoC v1's hand-encoded kernels (binary literals with the assembly in the
    comment next to each word, soc/fw/main.c) assemble to the same words
  - SoC v2's kernels (soc_v2/fw/kernels/*.s) assemble to the words the
    firmware used to hard-code
  - disassemble -> assemble reproduces all 65,536 possible words
  - errors carry file:line; warnings for BRp and a missing RET
  - the command line writes C, hex, binary and listings
"""

import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import tinygpu_asm as tg  # noqa: E402


def words(src, **kw):
    return tg.assemble(src, **kw).words


class Encoding(unittest.TestCase):
    """Field positions from tiny-gpu decoder.sv: [15:12] op, [11:8] rd,
    [7:4] rs, [3:0] rt, [7:0] imm, [11:9] nzp."""

    def test_each_instruction(self):
        cases = {
            "NOP": 0x0000,
            "RET": 0xF000,
            "ADD R1, R2, R3": 0x3123,
            "SUB R12, R0, R15": 0x4C0F,
            "MUL R0, %blockIdx, %blockDim": 0x50DE,
            "DIV R6, R0, R2": 0x6602,
            "CMP R9, R2": 0x2092,
            "LDR R4, R4": 0x7440,
            "STR R7, R6": 0x8076,
            "CONST R1, #255": 0x91FF,
            "CONST R1, #-1": 0x91FF,
            "CONST R2, #0x10": 0x9210,
            "CONST R2, #0b101": 0x9205,
            "ADD R0, R0, %threadIdx": 0x300F,
        }
        for text, expect in cases.items():
            with self.subTest(text=text):
                self.assertEqual(words(text), [expect])

    def test_branches(self):
        prog = "L0: NOP\n" + "".join(f"BR{c} L0\n" for c in ("n", "z", "p", "nz", "np", "zp", "nzp")) + "RET\n"
        got = words(prog, warn=lambda m: None)
        self.assertEqual(got[1:8], [0x1000 | (m << 9) for m in (4, 2, 1, 6, 5, 3, 7)])
        self.assertEqual(words("NOP\nNOP\nBRz 1\nRET"), [0, 0, 0x1401, 0xF000])
        self.assertEqual(words("NOP\nNOP\nbrNZ #0\nret"), [0, 0, 0x1C00, 0xF000])

    def test_labels_equ_case(self):
        src = """
        .kernel demo
        .equ base, 16
        start: CONST r1, #base   ; comment
               add R2, r1, R1    // other comment
        loop:  CMP R2, R1
               BRn loop
               RET
        """
        p = tg.assemble(src)
        self.assertEqual(p.name, "demo")
        self.assertEqual(p.words, [0x9110, 0x3211, 0x2021, 0x1802, 0xF000])

    def test_word_directive(self):
        self.assertEqual(words(".word 0xABCD\nRET"), [0xABCD, 0xF000])


class KnownKernels(unittest.TestCase):

    def test_soc_v1_hand_encoded_kernels(self):
        """soc/fw/main.c: '0b...,  // <assembly>' lines, from tiny-gpu's own tests."""
        with open(os.path.join(ROOT, "soc", "fw", "main.c")) as f:
            text = f.read()
        kernels = re.findall(r"static const uint16_t (\w+)\[\] = \{(.*?)\};", text, re.S)
        self.assertEqual([k for k, _ in kernels], ["matadd_kernel", "matmul_kernel"])
        for name, body in kernels:
            pairs = re.findall(r"0b([01]{16}),\s*//\s*(.*)", body)
            expect = [int(b, 2) for b, _ in pairs]
            src = "\n".join(line for _, line in pairs)
            with self.subTest(kernel=name):
                self.assertEqual(words(src), expect)

    def test_soc_v2_kernels(self):
        expect = {
            "matadd": [0x50DE, 0x300F, 0x9100, 0x9208, 0x9310, 0x3410, 0x7440,
                       0x3520, 0x7550, 0x3645, 0x3730, 0x8076, 0xF000],
            "matmul": [0x50DE, 0x300F, 0x9101, 0x9202, 0x9300, 0x9404, 0x9508, 0x6602, 0x5762, 0x4707,
                       0x9800, 0x9900, 0x5A62, 0x3AA9, 0x3AA3, 0x7AA0, 0x5B92, 0x3BB7, 0x3BB4, 0x7BB0,
                       0x5CAB, 0x388C, 0x3991, 0x2092, 0x180C, 0x3950, 0x8098, 0xF000],
            "pattern": [0x50DE, 0x300F, 0x9103, 0x5201, 0x8002, 0xF000],
        }
        for name, ref in expect.items():
            with self.subTest(kernel=name):
                p = tg.assemble_file(os.path.join(ROOT, "soc_v2", "fw", "kernels", f"{name}.s"))
                self.assertEqual(p.name, name)
                self.assertEqual(p.words, ref)


class RoundTrip(unittest.TestCase):

    def test_every_16_bit_word(self):
        """Disassemble all 65,536 words (as 256-word programs) and reassemble."""
        for base in range(0, 0x10000, 256):
            ws = list(range(base, base + 256))
            src = tg.disassemble(ws)
            self.assertEqual(words(src, warn=lambda m: None), ws, f"block 0x{base:04X}")

    def test_canonical_text(self):
        self.assertEqual(tg.decode(0x50DE), "MUL R0, %blockIdx, %blockDim")
        self.assertIsNone(tg.decode(0x2192))         # CMP with rd bits set: not canonical
        self.assertIsNone(tg.decode(0x3D00))         # write to %blockIdx
        self.assertIsNone(tg.decode(0x1000))         # branch with no condition


class Errors(unittest.TestCase):

    def assertAsmError(self, src, *fragments):
        with self.assertRaises(tg.AsmError) as cm:
            tg.assemble(src, filename="k.s")
        for frag in fragments:
            self.assertIn(frag, str(cm.exception))

    def test_messages(self):
        self.assertAsmError("NOP\nFOO R1", "k.s:2:", "unknown instruction 'FOO'")
        self.assertAsmError("ADD R1, R2", "k.s:1:", "takes 3 operands")
        self.assertAsmError("ADD R16, R1, R2", "bad register 'R16'")
        self.assertAsmError("CONST %blockIdx, #1", "read-only")
        self.assertAsmError("LDR R15, R1", "read-only")
        self.assertAsmError("CONST R1, #256", "does not fit in 8 bits")
        self.assertAsmError("CONST R1, #-129", "does not fit in 8 bits")
        self.assertAsmError("CONST R1, #nope", "unknown symbol 'nope'")
        self.assertAsmError("BRn nowhere\nRET", "unknown symbol 'nowhere'")
        self.assertAsmError("BRn 5\nRET", "outside the program")
        self.assertAsmError("BRx 0", "unknown instruction")
        self.assertAsmError("BRpn 0", "bad branch condition")
        self.assertAsmError("a: NOP\na: RET", "k.s:2:", "defined twice")
        self.assertAsmError(".bogus 1", "unknown directive")
        self.assertAsmError("NOP\n" * 257, "at most 256")

    def test_all_errors_reported(self):
        with self.assertRaises(tg.AsmError) as cm:
            tg.assemble("FOO\nADD R1\nCONST R1, #999", filename="k.s")
        self.assertEqual(str(cm.exception).count("k.s:"), 3)

    def test_warnings(self):
        seen = []
        tg.assemble("NOP\nBRp 0\nBRnzp 0\nRET", warn=seen.append)
        self.assertTrue(any("never taken" in m for m in seen))
        self.assertTrue(any("no effect" in m for m in seen))
        seen.clear()
        tg.assemble("NOP", warn=seen.append)
        self.assertTrue(any("no RET" in m for m in seen))


class CommandLine(unittest.TestCase):

    def run_tool(self, *args):
        return subprocess.run([sys.executable, os.path.join(HERE, "tinygpu_asm.py"), *args],
                              capture_output=True, text=True)

    def test_outputs(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "demo.s")
            with open(src, "w") as f:
                f.write("CONST R1, #7\nSTR R1, R1\nRET\n")
            r = self.run_tool(src, "-o", os.path.join(d, "k.h"), "-l", os.path.join(d, "k.lst"))
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(os.path.join(d, "k.h")) as f:
                header = f.read()
            self.assertIn('static const uint32_t k_demo[] __attribute__((section(".gpu"))) = {', header)
            self.assertIn("0x9107, /* 00: CONST R1, #7 */", header)
            self.assertIn("#ifndef K_H", header)
            with open(os.path.join(d, "k.lst")) as f:
                self.assertIn("  00   9107  CONST R1, #7", f.read())
            r = self.run_tool(src, "-f", "hex", "-o", os.path.join(d, "k.hex"))
            with open(os.path.join(d, "k.hex")) as f:
                self.assertEqual(f.read(), "9107\n8011\nF000\n")
            r = self.run_tool(src, "-f", "bin", "-o", os.path.join(d, "k.bin"))
            with open(os.path.join(d, "k.bin"), "rb") as f:
                self.assertEqual(f.read(), bytes([0x07, 0x91, 0x11, 0x80, 0x00, 0xF0]))
            r = self.run_tool(src, "--ctype", "uint16_t", "--section", "")
            self.assertIn("static const uint16_t k_demo[] = {", r.stdout)
            r = self.run_tool("-d", os.path.join(d, "k.hex"))
            self.assertIn("CONST R1, #7", r.stdout)

    def test_error_exit_code(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "bad.s")
            with open(src, "w") as f:
                f.write("RET\nADD R1, R2\n")
            r = self.run_tool(src)
            self.assertEqual(r.returncode, 1)
            self.assertIn("bad.s:2:", r.stderr)
            with open(src, "w") as f:
                f.write("NOP\nBRp 0\nRET\n")
            self.assertEqual(self.run_tool(src, "-W").returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
