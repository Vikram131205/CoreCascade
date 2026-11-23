# RV32IM 5-Stage Pipelined Processor

A fully functional **RISC-V RV32IM + Zicsr** (machine mode) 5-stage pipelined processor implemented in Verilog, with complete hazard handling, precise traps, timer and external interrupts, an OBI data port, and a Python golden-model verification framework.

## Architecture

```
┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐
│  IF  │──▶│  ID  │──▶│  EX  │──▶│ MEM  │──▶│  WB  │
│Fetch │   │Decode│   │Execute│  │Memory│   │Write │
└──────┘   └──────┘   └──────┘   └──────┘   └──────┘
     ◀──── Forwarding Unit (EX-EX, MEM-EX) ────▶
     ◀──── Hazard Unit (Load-Use Stall) ────────▶
     ◀──── Branch Flush (IF/ID + ID/EX) ────────▶
```

### Supported Instructions

| Type | Instructions |
|------|-------------|
| **R-type** | ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND |
| **I-type** | ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI |
| **Load**   | LB, LH, LW, LBU, LHU |
| **Store**  | SB, SH, SW |
| **Branch** | BEQ, BNE, BLT, BGE, BLTU, BGEU |
| **Jump**   | JAL, JALR |
| **Upper**  | LUI, AUIPC |
| **Zicsr**  | CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI |
| **M extension** | MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU (`mdu.v`: multiply holds EX 3 cycles, divide about 35) |
| **Privileged** | MRET, ECALL, EBREAK; machine external (`irq`) and timer (`irq_timer`) interrupts |

CSRs: `mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mtval, mip, mcycle(h)/cycle(h), minstret(h)/instret(h), mhartid` (`csr_unit.v`).
Traps are precise. Illegal instructions, ECALL, EBREAK, misaligned loads/stores and misaligned branch/jump targets trap in EX; a load/store bus error (`err`) traps in MEM. The oldest wins; `mepc` is the faulting instruction and `mtval` the bad address or instruction. Interrupts are taken on the instruction in ID (external before timer): older instructions complete and `mepc` points at the interrupted one. FENCE and WFI execute as NOPs.
The core runs C compiled by `clang --target=riscv32 -march=rv32im_zicsr` (see `../soc_v2/fw`).

### Memory Interface

`rv32i_core` has external bus ports, so the same core drops into an SoC:

- **Instruction port:** synchronous-read memory, 1-cycle latency. The core presents the *next* PC so the data lines up with IF.
- **Data port (OBI, see `../docs/spec/bus_obi.md`):** `req/we/be/addr/wdata`, issued from EX and held until `gnt`. The response (`rvalid`, `rdata`, `err`) can come any number of cycles later, for reads and writes; one transaction is outstanding at a time. The whole pipeline freezes while a request waits for `gnt` or the instruction in MEM waits for `rvalid`, so other bus masters (e.g. a GPU) can hold the memory.

Both ports match single-port synchronous SRAM macros, so the core fits FPGA BRAM and ASIC SRAM.

### Hazard Handling

- **Data Hazards (RAW):** Resolved via EX-EX and MEM-EX forwarding
- **Load-Use Hazards:** 1-cycle pipeline stall (PC hold + IF/ID hold + ID/EX bubble)
- **Control Hazards:** Pipeline flush of IF/ID and ID/EX registers on taken branches/jumps
- **Bus Stalls:** Global freeze while the data bus withholds its grant

## Project Structure

```
pp/
├── pp.srcs/sources_1/new/       # RTL source files
│   ├── rv32i_core.v             # Pipeline with external memory ports
│   ├── top_module.v             # Standalone system: core + instruction/data SRAM
│   ├── sram_sp.v                # Synchronous single-port SRAM (byte enables)
│   ├── pc_.v                    # Program counter (with stall)
│   ├── controlpath.v            # Control signal decoder
│   ├── reg_file_.v              # Register file (32x32, write-through bypass)
│   ├── ALU.v                    # Arithmetic Logic Unit
│   ├── alu_pc.v                 # Branch target adder
│   ├── alu_four.v               # PC+4 adder
│   ├── hazard_unit.v            # Forwarding + stall logic
│   ├── bj_det.v                 # Branch/jump detector
│   ├── extender_offsethandler.v # Immediate sign extension
│   ├── mux_32.v                 # 2:1 mux
│   ├── mux_32_3in.v             # 3:1 mux (forwarding)
│   ├── pp_stage_2.v             # IF/ID pipeline register
│   ├── pp_stage_3.v             # ID/EX pipeline register
│   ├── pp_stage_4.v             # EX/MEM pipeline register
│   └── pp_stage_5.v             # MEM/WB pipeline register
│
├── pp.srcs/sim_1/new/
│   └── testbench.v              # Self-checking Vivado testbench
│
└── verification/                # cocotb verification
    ├── Makefile                 # Just type 'make'
    ├── tb_cpu.v                 # Core + SRAMs, with random bus-grant stalls
    ├── rv32.py                  # RV32I assembler helpers + golden ISS
    └── test_pipeline.py         # Directed + constrained-random tests
```

> `pp.srcs/sim_1/new/testbench.v` targets the old `top_module` debug ports and
> is no longer compatible. Use the cocotb suite.

## Verification

### Initial Verification Using Waveforms

<img width="1909" height="1130" alt="image" src="https://github.com/user-attachments/assets/b1077ebb-086d-49c9-aa15-f57560d4a995" />

Credits - Xilinx Vivado 

### Quick Start (WSL + Icarus Verilog) (Advanced Python based Verification)

```bash
cd verification
make                  # run all tests
make clean            # remove build artifacts
```

### How It Works

Each test builds a program ending in `jal x0, 0` and runs it on the Python
golden model (`rv32.RV32ISS`) and on the RTL. It then compares all 32 registers
and the whole data memory. Coverage:

- all R/I-type ALU ops
- branches: taken and not taken, signed and unsigned corners
- JAL/JALR calls and returns, LUI/AUIPC
- byte/half loads and stores on every lane, with sign extension
- loops, and constrained-random programs
- the same programs while the data bus randomly refuses 40–60% of requests

The testbench drives garbage on `rdata` outside the response cycle, so the
core cannot rely on stale memory output.

- CSR instructions
- random interrupts in the middle of random programs, with and without bus stalls: results must match an uninterrupted run, and every interrupt must be handled exactly once
- timer interrupts, and external-over-timer priority
- MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU: directed corner cases (divide by zero, overflow) and random programs mixing M instructions
- every exception type once (ecall, ebreak, illegal, misaligned load/store/target, load and store access faults), with and without bus stalls: causes, `mepc` and `mtval` checked

```
TESTS=21 PASS=21 FAIL=0
```

## Tools Used

- **Vivado 2024.2** — Synthesis and xsim simulation
- **Icarus Verilog 13.0** — Open-source simulation (via WSL)
- **Python 3** — Golden model and verification scripts
