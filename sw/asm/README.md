# tiny-gpu assembler

`tinygpu_asm.py` assembles and disassembles the 16-bit ISA of
[tiny-gpu](https://github.com/adam-maj/tiny-gpu), the GPU in SoC v1 and v2. It replaces the
hand-typed hex the firmware used to carry. It needs only Python 3, no packages.

```bash
python3 sw/asm/tinygpu_asm.py k.s -o kernels.h      # C header (one array per kernel)
python3 sw/asm/tinygpu_asm.py k.s -f hex -o k.hex   # $readmemh file
python3 sw/asm/tinygpu_asm.py k.s -l k.lst          # listing
python3 sw/asm/tinygpu_asm.py -d 0x50DE 0x300F      # disassemble
python3 sw/asm/test_tinygpu_asm.py                  # tests
```

`soc_v2/Makefile` runs it on `soc_v2/fw/kernels/*.s` and writes `build/kernels.h`. The firmware
it produces is byte-identical to the one built from the old hex arrays.

## Syntax

```asm
.kernel matadd                 ; C array k_matadd
.equ    baseB, 8               ; named constant
        MUL   R0, %blockIdx, %blockDim
        ADD   R0, R0, %threadIdx
        CONST R2, #baseB       ; 8-bit immediate: 0..255 or -128..-1
LOOP:   LDR   R4, R2           ; R4 = mem[R2]
        STR   R2, R4           ; mem[R2] = R4
        CMP   R4, R2
        BRn   LOOP             ; BR + n/z/p, target = label or number
        RET
```

| Instruction | Encoding | |
|---|---|---|
| `NOP` | `0000 0000 0000 0000` | |
| `BRnzp target` | `0001 nzp0 tttt tttt` | branch if the NZP flags match |
| `CMP rs, rt` | `0010 0000 ssss tttt` | set NZP |
| `ADD/SUB/MUL/DIV rd, rs, rt` | `0011/0100/0101/0110 dddd ssss tttt` | |
| `LDR rd, rs` | `0111 dddd ssss 0000` | load |
| `STR rs, rt` | `1000 0000 ssss tttt` | store `rt` at `[rs]` |
| `CONST rd, #imm` | `1001 dddd iiii iiii` | |
| `RET` | `1111 0000 0000 0000` | thread done |

Registers R0–R12 are general. R13 = `%blockIdx`, R14 = `%blockDim` and R15 = `%threadIdx` are
read-only, and the assembler rejects writes to them. A program holds at most 256 instructions.

## How CMP and BR really behave on tiny-gpu

Checked by simulating tiny-gpu's `alu.sv`: the comparison is unsigned, and the flag that
instruction bit 11 (`n`) tests is set whenever `rs != rt`.

| Mnemonic | Branches when |
|---|---|
| `BRn` | `rs != rt` |
| `BRz` | `rs == rt` |
| `BRp` | never |
| `BRnz` | always (after a `CMP`) |

Before a thread's first `CMP`, no branch is taken. tiny-gpu's own matmul loop (`CMP R9, R2 ; BRn
LOOP`) works because it loops while `k != N`. The assembler encodes the mnemonics exactly as
documented and warns about `p` (`-W` turns warnings into errors).
