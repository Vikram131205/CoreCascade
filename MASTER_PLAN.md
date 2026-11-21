# CoreCascade: Master Plan and Design Decisions

| | |
|---|---|
| **Project** | CoreCascade: a heterogeneous RISC-V CPU + SIMT GPU SoC with its own GPU toolchain |
| **Team** | Vikram Singh, Rushil Jain, Jainam Sonigara |
| **Guide** | Dr. Sumam David |
| **Duration** | 5 semesters. Semesters 1–2 are done; this document plans Semesters 3–5 |
| **Document status** | v1.0, 2026-11-01. Living document: the single source of truth for scope, architecture and decisions |
| **Final deliverables** | (1) Working SoC on FPGA (Nexys 4 DDR) and on a laptop "virtual board"; (2) a timing-clean, DRC/LVS-clean **GDS** of a reduced configuration (**no tapeout**); (3) a measured evaluation in a final report / paper |

---

## Contents
- [0. How to use this document](#0-how-to-use-this-document)
- [1. Executive summary](#1-executive-summary)
- [2. Goals, non-goals, success criteria](#2-goals-non-goals-success-criteria)
- [3. Baseline: where we are (end of Semester 2)](#3-baseline-where-we-are-end-of-semester-2)
- [4. Target hardware architecture (v2)](#4-target-hardware-architecture-v2)
- [5. GPU v2 in detail](#5-gpu-v2-in-detail)
- [6. Software architecture](#6-software-architecture)
- [7. Build targets: FPGA, laptop, GDS](#7-build-targets-fpga-laptop-gds)
- [8. Decision log (with rejected alternatives)](#8-decision-log-with-rejected-alternatives)
- [9. Roadmap](#9-roadmap)
- [10. Priorities and cut list](#10-priorities-and-cut-list)
- [11. Verification plan](#11-verification-plan)
- [12. Evaluation plan](#12-evaluation-plan)
- [13. Risk register](#13-risk-register)
- [14. Team, roles, process](#14-team-roles-process)
- [15. Repository, tools, environment](#15-repository-tools-environment)
- [16. Open questions](#16-open-questions)
- [17. Glossary](#17-glossary)
- [Appendix A: Baseline measurements](#appendix-a-baseline-measurements)
- [Appendix B: Current file inventory](#appendix-b-current-file-inventory)
- [Appendix C: References](#appendix-c-references)

---

## 0. How to use this document

- **Decisions have IDs** (`B-xx` = already implemented baseline decisions, `D-xx` = v2 decisions). Every decision records *what*, *why*, *alternatives rejected and why*, and *when to revisit*. When someone asks "why didn't you use AXI?", the answer is a decision ID.
- **Changing a decision:** open a short proposal (issue or PR) that edits the decision entry, states the new evidence, and gets agreement from all three members. Never silently diverge from this document. Update it in the same PR as the code.
- **Roadmap tasks have IDs** (`S3-xx`, `S4-xx`, `S5-xx`) that map 1:1 to issues in the tracker.
- **Numbers marked "target"** are goals to measure against, not promises. Numbers marked "measured" come from actual simulation runs (Appendix A).
- **Three interface specs** (ISA v2, bus + memory map, driver ABI) live in `docs/spec/` and are versioned. This master plan summarises them; the specs are authoritative for bit-level detail.

---

## 1. Executive summary

We have a working, verified **v1 SoC**: an RV32I 5-stage pipelined CPU (with CSRs and interrupts) hosting the open-source **tiny-gpu** on a single shared bus, booting over UART, running C firmware that launches GPU kernels and handles a GPU-done interrupt. It passes 16/16 CPU tests and a full-chip boot-to-result test.

Measurement exposed the core problem: **as integrated, the GPU is about 2.8× slower than our own CPU** (265 vs 96 cycles on an 8-element add). The GPU loses most of its time to single-channel memory handshakes and a multi-step, non-pipelined core. The system is also not concurrent: one bus means one user at a time, the GPU has a private 256-byte memory that the CPU fills byte by byte, and the CPU babysits every launch.

**v2 turns this into a real heterogeneous SoC:**
- **Hardware:**
  - CPU with private memories (ITCM/DTCM), so it never waits on the GPU;
  - an OBI crossbar with 8-bank shared SRAM, so several masters move data in parallel;
  - **our own GPU v2** (a redesigned fork of tiny-gpu): 32-bit, new ISA, per-thread divergence, a barrel multi-warp pipeline, a bus master on shared memory, parameterised core count;
  - a **command processor** with a ring buffer and fences, so launches are asynchronous;
  - a VGA display controller, timer, traps, multiply/divide and better peripherals.
- **Software:**
  - assembler, functional simulator (golden model) and **a compiler for a small C-like kernel language**;
  - an asynchronous GPU runtime, HAL, a cooperative scheduler, then FreeRTOS;
  - profiling tools and a Verilator "virtual board".
- **Targets:** FPGA (main), laptop virtual board (always available), and a GDS of a reduced ASIC_LITE configuration.

**The final report must prove three claims with measurements:**
1. **The GPU accelerates:** a clear speedup over our CPU (with the M extension) on real workloads.
2. **The system is concurrent:** the CPU does useful work while the GPU renders, with small measured slowdown.
3. **It was designed, not assembled:** scaling studies (cores, banks, warps) and compiler ablations justify the choices.

---

## 2. Goals, non-goals, success criteria

### 2.1 Goals
| ID | Goal |
|---|---|
| G1 | CPU and GPU execute **concurrently** on **shared memory** with **asynchronous** work submission |
| G2 | A GPU we designed (v2) that **outperforms our CPU** on parallel workloads, and **scales** with cores |
| G3 | A complete **software stack** so the GPU is programmable without writing binary: assembler → compiler → runtime |
| G4 | Runs **live on FPGA** with a visual demo (VGA), and **identically in simulation** on a laptop |
| G5 | A **GDS** of a reduced configuration that is timing-clean and DRC/LVS-clean |
| G6 | **Verification at every level**, with measured results that are reproducible from the repo |

### 2.2 Non-goals (explicitly out of scope)
| Non-goal | Why |
|---|---|
| Actual tapeout / fabrication | Depends on external shuttles and timelines; decided out of scope (D-36) |
| Linux / MMU / virtual memory | Huge effort, no contribution to the three claims |
| CPU data caches, cache coherence | Avoided by design (D-05). Coherence is the classic project killer |
| DDR memory, AXI, general DMA | Not needed by our design (D-06, D-09); bridges only if ever needed |
| Floating point (CPU or GPU) | Fixed-point covers our workloads; FP is large in area and verification (D-14) |
| A full C/C++ compiler or LLVM backend | Our kernel language is deliberately small (D-30) |
| GPU atomics, multiple resident blocks per core | Complexity without benefit for our benchmarks (D-17, D-19) |
| Graphics pipeline (rasteriser, textures) | This is a compute GPU (GPGPU); the display only shows compute results |

### 2.3 Success criteria (targets)
| Claim | Metric | Target |
|---|---|---|
| GPU accelerates | Mandelbrot frame time, GPU vs CPU (RV32IM, same clock) | **≥ 5×** |
| GPU accelerates | matmul, GPU vs CPU | **≥ 2×** |
| Concurrent | CPU benchmark score drop while GPU renders continuously | **< 10 %** |
| Scales | Mandelbrot speedup going 1 → 4 cores | **≥ 3×** |
| Programmable | Compiled kernels vs hand-written assembly | **within 1.5×** cycles |
| FPGA | System clock on Artix-7 | **≥ 50 MHz** |
| GDS | ASIC_LITE on sky130 | DRC/LVS clean, timing met at chosen clock (target 40–50 MHz) |
| Quality | All tests in CI green at every milestone | 100 % |

---

## 3. Baseline: where we are (end of Semester 2)

### 3.1 What exists and works
| Area | State |
|---|---|
| **CPU** (`rv32i-pipeline/`) | RV32I 5-stage in-order pipeline. Forwarding (EX→EX, MEM→EX), load-use stall, branch flush in EX. Added this year: LUI/AUIPC/JALR; CSR instructions + MRET; machine external interrupt; synchronous-SRAM instruction and data ports; data request issued from EX with whole-pipeline **freeze** when the bus withholds its grant; register file written on posedge with bypass; x0 hardwired. Fixed bugs: LB/LH sign extension, JAL link value under forwarding, invalid-branch-taken, latch in branch unit |
| **SoC** (`soc/`) | Single shared bus (req/gnt, 1-cycle read). Masters: CPU, hardware UART boot loader. Slaves: 4 KB IMEM, 4 KB DMEM, GPU subsystem (tiny-gpu + 256×16 program SRAM + 256×8 data SRAM + control registers), sysctl (GPIO, EXIT, interrupt controller), UART console |
| **GPU** | tiny-gpu, **unmodified**, converted with sv2v. 2 cores × 4 threads, 8-bit data, 16-bit ISA, no divergence, multi-step core FSM |
| **Firmware** (`soc/fw/`) | C (clang, `rv32i_zicsr`, `-Os`): interrupt-driven GPU launches, UART console, self-checking matadd/matmul. 2,292 B code |
| **Verification** | CPU: 16 cocotb tests against a Python golden ISS, including random programs, random bus stalls and random interrupts, plus mutation checks. SoC: boot over UART pins → 4 GPU kernels → UART-RX interrupt → independent check of GPU memory. Yosys structural check: no latches, multiple drivers or loops. VCD waveforms with a GTKWave layout |
| **Docs** | `soc/README.md`, `rv32i-pipeline/README.md`, midsem deck |

### 3.2 Measured weaknesses (see Appendix A)
1. **The GPU doesn't accelerate:** 265 GPU cycles vs 96 CPU cycles for an 8-element byte add (0.36×), *before* counting the CPU's launch overhead.
2. **Why:** 63 % of kernel time is threads queuing for **one** memory channel, each access holding it for about 7 handshake cycles while the SRAM answers in 1. The remaining instructions cost about 10 cycles each in the core FSM.
3. **No concurrency:** one bus, one master at a time. The GPU's private memory forces byte-by-byte copies (8-bit memory on a 32-bit bus).
4. **Tiny memories:** 256 B GPU data; firmware already uses 2.3 KB of the 4 KB IMEM.
5. **Unknown timing:** no timing analysis yet. Suspected critical path: CPU ALU → address decode → arbitration/grant → freeze → next-PC mux → IMEM address.
6. **Inherited code quality:** tiny-gpu mixes blocking and non-blocking assignments in clocked logic (controller, dispatcher), which risks simulation/synthesis mismatch.
7. **Process risk:** `soc/` is **not under version control**, and the CPU changes are **uncommitted**.

### 3.3 Baseline decisions already implemented (carried into v2)
These are recorded in §8.1 (B-01 … B-13).

---

## 4. Target hardware architecture (v2)

### 4.1 System block diagram
```
 ┌──────────────── RV32IM CPU ───────────────┐   ┌──────────────── GPU cluster ────────────────┐
 │ 5-stage pipeline · traps · timer · IRQ    │   │ Command processor (ring buffer, fences)     │
 │ ITCM (code, dual-port) · DTCM (data)      │   │ Dispatcher → N cores × W warps × L lanes    │
 └───────┬────────────────────────┬──────────┘   │ per-core: program RAM, scratchpad, barrier  │
         │ ITCM 2nd port          │ shared/periph │ cluster arbiter → P OBI master ports        │
         │ (loader / debug)       │               └───────┬────────────────────┬───────────────┘
         │                        │                       │ (P ports)          │ CP port
 ┌───────┴───┐                    │                       │                    │       ┌────────────┐ ┌────────────┐
 │ boot/debug│                    │                       │                    │       │ display    │ │ (spare     │
 │ bridge    │                    │                       │                    │       │ controller │ │  master)   │
 │ (UART)    │                    │                       │                    │       │ (VGA)      │ │            │
 └─────┬─────┘                    │                       │                    │       └─────┬──────┘ └────────────┘
       │                          │                       │                    │             │
 ══════╧══════════════════════════╧═══════ OBI CROSSBAR (per-slave round-robin) ════════════╧═══════════════════
        │         │         │         │         │         │         │         │                    │
     bank 0    bank 1    bank 2    bank 3    bank 4    bank 5    bank 6    bank 7         peripheral bridge
     └──────────────── shared SRAM, word-interleaved: data, kernels, framebuffers, ring ──┘   (UART, timer, GPIO,
                                                                                          IRQ ctrl, CP regs,
                                                                                          display regs, perf ctrs)
```

**How concurrency arises:**
- The CPU runs from ITCM/DTCM, which never touch the crossbar.
- GPU ports, the command processor and the display reach different banks in the same cycle.
- Two masters wait only when they hit the **same bank in the same cycle**, and then round-robin alternates.

### 4.2 Memory map v2 (proposal; frozen in `docs/spec/memory_map.md` by S3 week 5)
| Base | Region | FPGA_FULL size | ASIC_LITE size | Notes |
|---|---|---|---|---|
| `0x0000_0000` | ITCM | 32 KB | 16 KB | CPU fetch port + second port on crossbar (loader, debug, CPU constant reads) |
| `0x1000_0000` | DTCM | 16 KB | 8 KB | CPU private data/stack; also reachable by the loader/debug bridge |
| `0x2000_0000` | Shared SRAM | 256 KB (8 × 32 KB) | 16 KB (8 × 2 KB) | Word-interleaved: bank = `addr[4:2]` |
| `0x4000_0000` | SYSCTL | 4 KB | 4 KB | GPIO in/out, EXIT, scratch, chip ID |
| `0x4000_1000` | UART | 4 KB | 4 KB | DATA, STATUS, CTRL (FIFO levels, IRQ enables) |
| `0x4000_2000` | Timer (CLINT-style) | 4 KB | 4 KB | `mtime` (64-bit), `mtimecmp` (64-bit) |
| `0x4000_3000` | Interrupt controller | 4 KB | 4 KB | PENDING, ENABLE, PRIORITY, CLAIM/COMPLETE |
| `0x4000_4000` | GPU command processor | 4 KB | 4 KB | Queue registers, status, errors |
| `0x4000_5000` | Display controller | 4 KB | 4 KB | FB_BASE, CTRL, STATUS |
| `0x4000_6000` | Performance counters | 4 KB | 4 KB | CPU, GPU, crossbar counters |
| other | — | — | — | Bus error (OBI `err`) |

GPU scratchpads and program RAMs are **core-local** and not mapped on the crossbar (D-18, D-20).

### 4.3 CPU subsystem
| Feature | Specification |
|---|---|
| ISA | RV32IM + Zicsr, machine mode only |
| Pipeline | Existing 5-stage (IF, ID, EX, MEM, WB); data request from EX, response in MEM, freeze on `!gnt` |
| Multiply/divide | MUL/MULH/MULHSU/MULHU: 2-cycle pipelined (DSP on FPGA). DIV/DIVU/REM/REMU: iterative, ~33 cycles, stalls the pipeline |
| Traps | Synchronous exceptions: illegal instruction (2), breakpoint (3), load misaligned (4), load access fault (5), store misaligned (6), store access fault (7), ecall (11). `mtval` holds the bad address/instruction. Interrupts: machine timer (7), machine external (11) |
| Trap timing | Illegal/ecall/ebreak detected in ID and taken when the instruction reaches EX; misaligned detected in EX; bus `err` on loads arrives in MEM and is taken there (flush EX and younger). Interrupts keep the existing scheme (taken on the valid ID instruction) |
| CSRs | `mstatus, misa, mie, mip, mtvec, mscratch, mepc, mcause, mtval, mcycle(h), minstret(h), mhartid` |
| Memories | ITCM: fetch port (read) + crossbar port (read/write). DTCM: CPU data port. Accesses outside ITCM/DTCM go to the crossbar |
| Bus master | One OBI master port for shared memory and peripherals; one outstanding transaction |

### 4.4 Interconnect (OBI crossbar)
**Signals per port** (OBI subset): `req, gnt, addr[31:0], we, be[3:0], wdata[31:0]` → `rvalid, rdata[31:0], err`. No `rready`: masters must always accept a response.

**Rules:**
1. A master holds its request fields stable until `gnt`.
2. **Every master has at most one outstanding transaction**; it issues the next request only after `rvalid` (relaxed later only if measured necessary). This guarantees in-order responses without transaction IDs.
3. Each slave has a **round-robin arbiter** across masters. The display controller gets **highest priority** to avoid scan-out underflow; its line buffer gives it slack, so this costs others very little.
4. The crossbar keeps, per slave, which master owns the response in flight, and routes `rvalid/rdata/err` back.
5. Unmapped addresses return `err` (the CPU takes an access-fault trap; the GPU reports an error to the command processor).

**Masters (FPGA_FULL):** CPU, boot/debug bridge, GPU ports (P, default = number of cores), command processor, display → **4 + P**.

**Slaves:** 8 shared banks + ITCM second port + DTCM bridge port + peripheral bridge → **11**.

**Timing note:** arbitration is combinational in the request cycle. If the CPU path (ALU → decode → grant → freeze) fails 50 MHz, register the CPU's request (one extra cycle of load latency to shared memory only; ITCM/DTCM stay single-cycle).

### 4.5 Shared SRAM
- **8 banks, word-interleaved** (`bank = addr[4:2]`): consecutive words land in different banks, so GPU lanes reading `a[i], a[i+1], …` and the display reading a line spread across banks.
- Each bank is single-port, synchronous, 32-bit with byte enables. FPGA: block RAM. ASIC: sky130 SRAM macros (1rw1r variants; one port used) or DFFRAM.
- Layout (FPGA_FULL, by software convention): two 75 KB framebuffers (320×240×8 bpp), a command ring (4 KB), GPU kernel binaries, and buffers for kernel data.

### 4.6 Command processor (summary; details in §5.7)
- The CPU writes 32-byte **launch descriptors** into a ring buffer in shared memory and advances `Q_TAIL`.
- The command processor fetches descriptors, loads the kernel into the cores' program RAMs (skipped if it's already loaded), dispatches the grid, waits for completion **and for all GPU stores to be acknowledged**, writes the descriptor's **fence value** to its fence address, raises an interrupt if requested, and advances `Q_HEAD`.
- Errors (illegal GPU instruction, misaligned or unmapped address, unstructured divergence, timeout) stop the queue, set `STATUS.ERR` plus a code, and raise an interrupt.

### 4.7 Display controller
- 640×480 at 60 Hz timing using a **25 MHz pixel enable** derived from the 50 MHz system clock. There's no separate clock domain; 25.0 MHz is accepted by typical monitors.
- 320×240 framebuffer, 8 bpp (RGB332), each pixel shown 2×2. Output: Nexys VGA is 4-4-4, so RGB332 is expanded.
- **Line buffer:** fetches 80 words (one source line) during the previous line pair. Bandwidth ≈ 4.6 MB/s, negligible.
- `FB_BASE` is double-buffered: software writes a new base, and it takes effect at the next vsync (tear-free page flip). There's a vsync interrupt.
- In ASIC_LITE the display is disabled by parameter (or a tiny 80×60 mode, if area allows).

### 4.8 Peripherals
| Block | Spec |
|---|---|
| UART | 8N1, 16-byte TX and RX FIFOs, IRQ on RX-not-empty and TX-below-threshold, baud divisor parameter + register |
| Timer | CLINT-style `mtime`/`mtimecmp`, drives the machine timer interrupt (`MTIP`) |
| Interrupt controller | Sources: UART, GPU command processor (done/error), display vsync, GPIO, perf-counter overflow, (spare). Per-source enable + priority, CLAIM/COMPLETE registers, drives the machine external interrupt (`MEIP`) |
| SYSCTL | GPIO in (synchronised) and out, EXIT (sets `halted`), scratch, chip ID/version |
| Boot/debug bridge | Existing UART boot FSM extended: usable **at runtime** (escape sequence or a dedicated pin) to read/write any address while the CPU runs. Used for loading, memory dumps (e.g. framebuffer screenshots from the FPGA), and live debugging |
| Performance counters | CPU: cycles, instructions retired, freeze cycles, stall cycles. GPU: per-core active cycles, instructions issued, no-ready-warp cycles, memory-wait cycles, barrier-wait cycles, divergent branches, memory requests. Crossbar: per-slave conflict cycles |

### 4.9 Clocking and reset
- **One clock domain, 50 MHz** (FPGA: the board's 100 MHz → PLL in the FPGA wrapper. ASIC: clock input pin).
- **Reset:** asynchronous assert, synchronous de-assert, using a reset synchroniser in the top wrapper. Internally, synchronous resets (the current style).
- **Every register whose initial value matters is reset** (ASIC registers start unknown; FPGA registers don't). Gate-level simulation enforces this.

### 4.10 System-level correctness rules (MUST)
1. **Fence after drain:** the command processor writes a fence only after every store of that kernel has received `rvalid`.
2. **Descriptor before tail:** the CPU writes the descriptor fully before writing `Q_TAIL`. This is safe because CPU stores are blocking and in order (one outstanding). If a store buffer is ever added, implement `FENCE` and use it here.
3. **No CPU data cache on shared memory.** If a GPU instruction cache is ever added, invalidate it at every launch.
4. **Single writer per memory region per phase:** while a kernel runs, the CPU doesn't write that kernel's buffers. That's a software contract the runtime documents, not hardware-enforced.
5. **No target-specific logic in core RTL.** Only the memory wrappers, the top-level wrapper and the parameter files differ per target.

---

## 5. GPU v2 in detail

### 5.1 Organisation and terminology
| Term | Meaning in CoreCascade |
|---|---|
| **Lane** | One hardware thread slot: an ALU, a register file slice and an LSU address unit |
| **Warp** | A group of L threads executing the same instruction (SIMT), with an active mask |
| **Core** | Fetch/decode/warp scheduler + L lanes + W warp contexts + program RAM + scratchpad |
| **Block** | Up to W×L threads of a kernel resident on one core; they share the scratchpad and barrier |
| **Grid** | All blocks of a launch (2-D: `grid_x × grid_y` blocks) |

**Parameters** (defaults FPGA / ASIC_LITE): cores `N` = 4 / 2, lanes `L` = 4 / 4, warps `W` = 4 / 2, scratchpad 4 KB / 1 KB, program RAM 2 KB / 1 KB, divergence stack depth 8 / 4, cluster ports `P` = N.

### 5.2 Staged delivery (each stage is usable for demos)
| Stage | Semester | Content |
|---|---|---|
| **v2.0** | S3 | 32-bit datapath, ISA v2 decoder, lanes as OBI bus masters through the cluster arbiter, 1-cycle memory handshake, parameterised cores. **Execution still multi-step (FSM).** Program RAM loaded by the CPU via MMIO (command processor arrives in v2.1/S4) |
| **v2.1** | S4 | Per-thread divergence (active mask + reconvergence stack). Command processor |
| **v2.2** | S4 | **Barrel multi-warp pipeline** (one instruction per cycle from a ready warp), performance counters |
| **v2.3** | S5 | Per-core scratchpad + barrier |
| **v2.4** | S5 stretch | Coalescing / multiple ports per core; instruction cache |

### 5.3 ISA v2 (draft; frozen in `docs/spec/isa_v2.md` by S3 week 5)
**Per-thread state:**
- `r0` (always 0) and `r1–r15`, 32-bit.
- Predicates `p0` (always true) and `p1–p3`.
- Special registers, read with `S2R`: `%tid` (thread index in block), `%bid_x`, `%bid_y`, `%bdim` (threads per block), `%gdim_x`, `%gdim_y`, `%lane`, `%warp`, `%core`, `%argp` (pointer to the kernel argument struct), `%clock`.

**Encoding:** fixed 32-bit; every instruction has a 3-bit **guard** `[neg, p1:p0]`. A lane executes only if `pred[p] XOR neg`, and `000` = always.
```
 31      26 25  23 22   19 18   15 14   11 10            0
[ opcode  ][guard ][  rd  ][ rs1  ][ rs2  ][  funct11     ]  R  : register ALU
[ opcode  ][guard ][  rd  ][ rs1  ][       imm15         ]  I  : ALU-immediate, loads
[ opcode  ][guard ][ rs2  ][ rs1  ][       imm15         ]  S  : stores
[ opcode  ][guard ][  rd  ][          imm19              ]  U  : LUI (rd = imm19 << 13)
[ opcode  ][guard ][ pd   ][ rs1  ][ rs2  ][ cond | funct]  P  : SETP (compare → predicate)
[ opcode  ][guard ][            offset23 (words)         ]  J  : BRA, SPLIT
```

**Instruction classes (about 40 instructions):**
| Class | Instructions |
|---|---|
| Integer ALU | ADD SUB AND OR XOR SLL SRL SRA SLT SLTU MIN MAX (+ immediate forms ADDI ANDI ORI XORI SLLI SRLI SRAI SLTI) |
| Multiply | MUL (low 32), MULH (high 32, signed), **MULQ rd, rs1, rs2, sh** = `(rs1 × rs2) >> sh` (signed 64-bit product; `sh` in funct): fixed-point in any Q format (Q16.16, Q8.24 …) |
| Constants / moves | LUI, S2R (special → GPR), SELP (`rd = ps ? rs1 : rs2`) |
| Compare | SETP.{EQ,NE,LT,LE,GT,GE}[.U] pd, rs1, rs2 (and an immediate form) |
| Global memory | LDW, LDB, LDBU, STW, STB (address = rs1 + imm15; word accesses must be aligned) |
| Scratchpad | LDS, STS (word, core-local) |
| Control | BRA offset (guarded; uniform or divergent), SPLIT offset (push reconvergence point), JOIN, BAR (block barrier), EXIT, NOP |
| **Not included** | Divide (use reciprocal multiply / software), atomics, floating point, indirect jumps, calls (the compiler inlines) |

**Divergence semantics (structured, compiler-assisted):**
1. Before a potentially divergent branch, the compiler emits `SPLIT join_label`. This pushes `{reconvergence PC = join_label, current mask}` onto the warp's stack.
2. `BRA` with a guard: if all active lanes agree, it's an ordinary branch (no stack use). If they disagree, the taken lanes continue at the target with mask T, and `{fall-through PC, mask N}` is pushed.
3. At `join_label` the compiler places `JOIN`. It pops: if the popped entry is a pending "other path", jump there with its mask; otherwise restore the saved mask and continue.
4. A divergent `BRA` without a preceding `SPLIT` is an **"unstructured divergence"** error, reported to the command processor. Stack overflow is also an error; the compiler checks nesting depth statically.

**Kernel ABI:**
- At launch each thread can read `%argp`, which points to the descriptor's argument struct in shared memory; arguments are loaded with `LDW [%argp + off]`.
- Blocks are 1-D (`%tid` in `0 … bdim-1`); grids are 2-D.
- Threads beyond `bdim` in the last warp are masked off at dispatch.
- `EXIT` ends a thread; when all threads of a block exit, the core reports block done.

**Single source of truth:** the encoding lives in one machine-readable table (`sw/isa/isa_v2.yaml`), from which scripts generate the RTL decoder constants, the assembler/disassembler tables, the simulator decoder and the spec's encoding tables. That's how the four can't drift apart.

### 5.4 Core microarchitecture (v2.2 barrel pipeline)
```
 warp scheduler ─► IF ─► ID/RF ─► EX ─► WB ──► register file
   (round-robin     │      │        │      │
    over ready      │      │        │      └─► memory ops → LSU → cluster port → crossbar
    warps)        program  guard   ALU/MUL/            (warp parks until all lanes' responses return,
                   RAM     eval    AGEN/SETP/           then writes back through the LSU return port)
                                   branch+stack
```
- **Each warp has at most one instruction in the pipeline.** With `W ≥ 4` and 4 stages, consecutive instructions of a warp never overlap, so there's **no forwarding and no hazard logic**, and the scheduler issues one instruction per cycle whenever enough warps are ready.
- **Long-latency operations** (loads/stores, MUL taking 2 cycles, BAR) simply mark the warp *not ready* until they complete. That's the classic latency-hiding effect: other warps fill the pipeline meanwhile.
- **Register file per lane:** W × 16 × 32 bits, 2 reads + 1 write per cycle. The write port is shared between the ALU writeback and the LSU return (the LSU has priority; the ALU writeback of the colliding warp is retried next cycle). FPGA: LUTRAM. ASIC: flops (the area is reported in the scaling study).
- **Throughput target:** about 1 warp-instruction per cycle = L thread-instructions per cycle per core, vs tiny-gpu's about 1 per 10+ cycles per block.

### 5.5 LSU and cluster
- Each core's LSU serialises the active lanes' requests (one lane per cycle) onto **its cluster port** (P = N by default). A lane's response is written back when it arrives; the warp becomes ready when all lanes are done.
- Banked shared memory lets different cores' ports proceed in parallel. Two cores collide only on the same bank.
- **v2.4 stretch:** 2 ports per core and/or coalescing (merge lanes hitting the same word; issue lanes targeting different banks in the same cycle). The scaling study decides whether it's worth it.

### 5.6 Scratchpad and barrier (v2.3)
- Per-core scratchpad: L banks, word-interleaved, single-port; same-bank collisions serialise. Accessed only via LDS/STS, so it never touches the crossbar.
- `BAR`: a warp waits until all live warps of the block reach the barrier. It's implemented with an arrival counter and a per-warp waiting bit. A divergent `BAR` is an error.

### 5.7 Command processor
**Registers** (`0x4000_4000`): `CTRL` (enable, reset, irq_en), `Q_BASE`, `Q_SIZE` (entries, power of two), `Q_HEAD` (read-only), `Q_TAIL`, `STATUS` (busy, err, err_code, err_desc_index), `TIMEOUT` (cycles, 0 = off), `LAST_FENCE`.

**Descriptor** (8 words, 32 B):
| Word | Field |
|---|---|
| 0 | `kernel_addr`: kernel binary in shared memory |
| 1 | `kernel_words`: length (≤ program RAM size) |
| 2 | `grid_x[15:0] \| grid_y[31:16]` |
| 3 | `block_threads`: ≤ W × L |
| 4 | `arg_ptr` |
| 5 | `fence_addr` |
| 6 | `fence_value` |
| 7 | `flags`: bit0 irq_on_complete, bit1 force_reload |

**Flow:**
1. Fetch the descriptor.
2. If `kernel_addr` differs from the last one loaded (or `force_reload`), stream the kernel into **all** cores' program RAMs (broadcast write).
3. Dispatch blocks to cores as they free up.
4. Wait for the last block **and** for zero outstanding GPU stores.
5. Write `fence_value` to `fence_addr`.
6. Interrupt (if flagged).
7. `Q_HEAD++`.

### 5.8 GPU error model
| Error | Detected by | Effect |
|---|---|---|
| Illegal instruction | Decoder | Block aborted, CP stops queue, IRQ |
| Misaligned / unmapped address | LSU / crossbar `err` | Same |
| Unstructured divergence / stack overflow | Branch unit | Same |
| Divergent barrier | Barrier unit | Same |
| Timeout | CP watchdog | Same; GPU soft-reset |

---

## 6. Software architecture

### 6.1 Layers
```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ Applications & demos: Mandelbrot explorer, image filters, tiled matmul,  │
 │ CoreMark, benchmark suite                                                │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ GPU runtime (cc_*): buffers, async launch, fences, callbacks, errors     │
 ├───────────────────────────────┬──────────────────────────────────────────┤
 │ Scheduler: cooperative (S4) → │ HAL: uart, timer, irq, display, gpio,    │
 │ FreeRTOS (S5)                 │ perf, sysctl                             │
 ├───────────────────────────────┴──────────────────────────────────────────┤
 │ Startup (crt0), linker script, libc subset (printf-lite, memcpy…)        │
 └──────────────────────────────────────────────────────────────────────────┘
 Kernel toolchain (host PC):  .cck source → compiler → .s → assembler → .bin + C header
 Host tools: functional simulator · profiler · loader/debugger (UART bridge) · virtual board
```

### 6.2 ISA definition and generators (`sw/isa/`)
`isa_v2.yaml` holds each instruction's mnemonic, format, opcode/funct, operands and semantics notes. Generators emit:
- `hw/gpu/isa_v2_defs.vh` (RTL constants);
- `sw/asm/tables.py`;
- `sw/sim/decode.py`;
- the encoding tables in `docs/spec/isa_v2.md`.

### 6.3 Assembler and disassembler (`sw/asm/`)
- Two-pass, with labels, `.kernel name`, `.word`, `.align`, guard syntax (`@p1`, `@!p2`), special registers (`%tid`) and pseudo-ops (`LI` → LUI+ORI, `MOV`).
- Output: raw `.bin`, a C header (`kernel_<name>[]` + length), and a listing.
- Also an assembler for **today's tiny-gpu ISA** (S3 weeks 1–2), to retire the hand-typed binary immediately.

### 6.4 Functional simulator (`sw/sim/`)
- Python model of ISA v2 at warp granularity: active masks, divergence stack, scratchpad, barrier, shared memory, error model.
- **Not cycle-accurate** (D-31). Performance comes from RTL.
- Uses:
  - golden model for RTL, via an **instruction-by-instruction trace comparison** (RTL emits `{core, warp, pc, mask, rd, value}` at writeback);
  - test target for the compiler;
  - debugging kernels without RTL.

### 6.5 Kernel language "CCK" and compiler (`sw/compiler/`)
**Language (v1):**
- Types: `int` (32-bit), `fix` (Q16.16, operators mapped to MULQ), `bool`. Pointers to global `int`/`fix` arrays (`global int* a`), and scratchpad arrays (`shared int tile[256]`).
- Builtins: `tid()`, `bid_x()`, `bid_y()`, `bdim()`, `gdim_x()`, `gdim_y()`, `barrier()`.
- Control: `if/else`, `for`, `while`, `break`, `continue`. All may be divergent.
- Functions: `kernel void name(params)`, plus `inline` helper functions (always inlined).
- **Not supported:** recursion, function pointers, dynamic allocation, structs (v1), floating point.

**Pipeline:**
1. Lexer → recursive-descent parser → AST.
2. Semantic analysis: types, scopes, address spaces.
3. Lowering to a three-address IR with basic blocks and a control-flow graph.
4. **Uniformity (divergence) analysis:** marks values and branches as *uniform* (the same in all threads, e.g. derived from `bid_x()` or kernel arguments) or *varying* (derived from `tid()` or loads of varying addresses).
5. Branch lowering:
   - uniform → plain `BRA`;
   - varying and short → **if-conversion** with guards;
   - varying and long → `SPLIT/BRA/JOIN`, with a static nesting-depth check.
6. Optimisations (S5, each switchable for the ablation): constant folding/propagation, dead-code elimination, common-subexpression elimination, strength reduction (multiply by a power of two → shift), loop-invariant code motion.
7. Instruction selection.
8. **Register allocation:** linear scan over 15 registers; spilling to the scratchpad (S5; v1 reports an error when registers run out).
9. Optional list scheduling (separate loads from their uses; less critical thanks to the barrel pipeline).
10. Emit assembly → assembler. Also emit a C header with the argument-struct layout and a `CC_KERNEL(name)` descriptor.

**Testing:**
- Golden outputs per test kernel.
- **Differential testing:** the same CCK program is compiled and run on the simulator, compared against a C reference implementation on the host, and later against RTL.
- A random kernel generator (Csmith-style, small) for fuzzing.

### 6.6 GPU runtime API (`sw/runtime/`)
```c
int        cc_init(void);                                  // set up ring buffer, IRQ handler
void*      cc_alloc(size_t bytes);  void cc_free(void*);   // shared-SRAM allocator (bump + free list)
cc_fence_t cc_launch(const cc_kernel_t* k, uint16_t grid_x, uint16_t grid_y,
                     uint16_t block_threads, const void* args, size_t args_size);  // returns at once
bool       cc_done(cc_fence_t f);
void       cc_wait(cc_fence_t f);                          // sleeps (scheduler) until fence reached
void       cc_on_complete(cc_fence_t f, void (*cb)(void*), void* ctx);
int        cc_status(cc_error_t* err);                     // error code + failing descriptor
```
- Implementation: monotonically increasing 32-bit fence counter; descriptors and argument copies live in shared memory; the command-processor interrupt handler reads `LAST_FENCE` and wakes waiters/callbacks.
- **Contract:** buffers passed to a kernel must not be written by the CPU until its fence completes (§4.10 rule 4).

### 6.7 Scheduler and FreeRTOS
- **S4: cooperative scheduler.** Tasks are functions that yield. Event flags are set from interrupt handlers (GPU done, vsync, UART RX). It's small, deterministic and needs no traps, and it's enough to show concurrency.
- **S5: FreeRTOS** (RISC-V port, RV32I). Needs `mtime`/`mtimecmp`, the machine timer interrupt, `ecall` (yield) and trap entry/exit. The runtime's `cc_wait` maps to a semaphore.

### 6.8 HAL and libc subset
- `uart` (interrupt-driven ring buffers), `timer` (`delay_us`, timestamps), `irq` (register/enable handlers, claim/complete), `display` (set back buffer, flip at vsync, wait vsync), `gpio`, `perf` (snapshot/diff counters), `sysctl`.
- libc subset: `memcpy`, `memset`, `strlen`, `printf-lite` (integers, hex, fixed-point), plus the runtime division helpers until the M extension lands.

### 6.9 Host tools (`sw/tools/`)
| Tool | Function |
|---|---|
| `cc-load` (extends `uart_load.py`) | Load an ELF over the boot bridge; `peek`/`poke`; `dump addr len file`; `screenshot` (dump the framebuffer → PNG); console |
| `cc-prof` | Reads performance counters (via firmware print or bridge) → per-kernel report + CPU/GPU activity timeline plot |
| `cc-bench` | Runs the benchmark suite on the virtual board or FPGA, appends results to `bench/results.csv`, regenerates plots |

### 6.10 Firmware build and memory layout
- Toolchain: clang/LLVM, `--target=riscv32 -march=rv32im_zicsr -mabi=ilp32`, ld.lld.
- Linker script sections:
  - `.text`, `.rodata` → ITCM (the ITCM's second port lets the CPU read constants there);
  - `.data`, `.bss`, stack → DTCM;
  - `.shared` (buffers, ring) and `.gpu_kernels` (kernel binaries, which must be in shared memory for the command processor) → shared SRAM.
- Boot:
  - FPGA: ITCM/DTCM/shared contents pre-loaded via the bitstream, or loaded over the UART bridge.
  - ASIC: UART bridge only.
  - Virtual board: memories loaded directly from the ELF.

---

## 7. Build targets: FPGA, laptop, GDS

### 7.1 Configuration table
| Parameter | **FPGA_FULL** | **VIRTUAL** (Verilator) | **ASIC_LITE** (GDS) | ASIC_MID (stretch) |
|---|---|---|---|---|
| ITCM / DTCM | 32 / 16 KB | = FPGA_FULL | 16 / 8 KB | 32 / 16 KB |
| Shared SRAM | 256 KB (8 × 32) | = FPGA_FULL | 16 KB (8 × 2) | 64–128 KB |
| GPU N × W × L | 4 × 4 × 4 | = FPGA_FULL | 2 × 2 × 4 (4 cores if it fits) | 4 × 4 × 4 |
| Scratchpad / program RAM per core | 4 / 2 KB | = | 1 / 1 KB | 2 / 2 KB |
| Display | 320×240 VGA | Frames → PNG / SDL window | Off (or 80×60) | Off |
| Clock | 50 MHz (PLL) | n/a | Target 40–50 MHz (pin) | Same |
| Boot | Bitstream preload or UART | Direct ELF load | UART bridge | UART bridge |
| Proves | Live demos, FPGA resources, fmax | Function, any time, on any laptop | Area, timing, power, clean layout | Silicon scaling |

### 7.2 Target-specific layer (the only code that differs)
- `hw/common/mem/`: `sram_sp` → FPGA block RAM inference / sky130 macro wrapper / DFFRAM wrapper / behavioural model.
- `hw/fpga/nexys4ddr_top.v` + `.xdc` + Vivado TCL. `hw/asic/asic_top.v` + LibreLane config.
- `hw/cfg/{fpga_full,asic_lite,asic_mid}.vh` hold the parameters.

### 7.3 FPGA (Nexys 4 DDR, Artix-7 XC7A100T)
- Resources: about 63k LUTs, 135 × 36 Kb block RAM (≈ 600 KB), 240 DSPs. Estimated BRAM use for FPGA_FULL ≈ 330 KB (55 %). LUTs: unknown until synthesis. For reference, IEEE-Core-Cascade's 8-core 32-bit tiny-gpu variant used about 45 % of the LUTs.
- I/O used: USB-UART, VGA (4-4-4), 16 switches (one = boot strap), 5 buttons (Mandelbrot pan/zoom), 16 LEDs (status), 7-segment display (fps / fence count).
- Vivado (free edition supports the 100T). Build time about 10–30 min on a laptop.

### 7.4 Laptop-only path (virtual board)
- **Verilator** C++ harness for `soc_top` in the FPGA_FULL configuration:
  - loads the ELF directly into memories (fast) or via the UART model;
  - UART ↔ terminal;
  - VGA → PNG per frame, optionally a live SDL window;
  - keyboard → buttons/switches.
- Speed: expect roughly 10⁵–10⁶ cycles/s on a laptop (to be measured), so a Mandelbrot frame takes seconds to minutes. Fine for functional demos and recordings; not real-time.
- Verilator models no unknown (X) values, so it can hide reset bugs. Icarus/cocotb unit tests and gate-level simulation stay in the flow.
- **Everything except a live hardware demo is laptop-doable:** RTL simulation, the compiler, the simulator, Vivado synthesis for resource/timing numbers, and LibreLane for GDS.
- **Laptop requirements:** Windows + WSL2 Ubuntu; **16 GB RAM minimum** (32 GB strongly preferred for top-level LibreLane runs); **≈ 100 GB free disk** (Vivado, Docker images, sky130 PDK).

### 7.5 GDS (ASIC_LITE)
**Definition of done:**
1. Synthesised, placed and routed with LibreLane (OpenLane 2) on sky130, with real SRAM macros (or DFFRAM).
2. **DRC clean** (Magic/KLayout) and **LVS clean** (Netgen); antenna violations fixed.
3. **Timing met** (setup and hold) across the standard corners at the chosen clock.
4. **Gate-level simulation** passes the SoC smoke test on the synthesised netlist, and on the post-layout netlist with SDF if run time allows (memories back-door loaded, short programs).
5. Reported: area, utilisation, fmax, power estimate (with activity from simulation).

**Strategy:**
- **Hierarchical:** harden the GPU core and the CPU as macros, then the top level. This shortens runs and isolates timing problems.
- A core block with pins at its boundary; **no pad ring** (not fabricating).
- Trial run on the v1 SoC in S3; ASIC_LITE sub-block runs in S4; closure in S5.

---

## 8. Decision log (with rejected alternatives)

Format: **Decision** · **Why** · **Rejected alternatives** · **Revisit if**.

### 8.1 Baseline decisions (implemented in Semesters 1–2)

**B-01 Synchronous-SRAM memory interfaces for the CPU**
- **Decision:** both CPU ports assume memories that return data one cycle after the address. The fetch port presents the *next* PC.
- **Why:** matches FPGA block RAM and every ASIC SRAM macro; combinational memories exist in neither.
- **Rejected:** combinational (asynchronous-read) memories, the original design: not implementable as SRAM.
- **Revisit if:** never.

**B-02 Data request from EX, response in MEM, whole-pipeline freeze on `!gnt`**
- **Why:** keeps the 5-stage structure and single-cycle loads with synchronous SRAM. Freezing everything is simple and provably safe.
- **Rejected:**
  - issuing from MEM: adds a stage of load latency;
  - stalling only the later stages: needs bubble insertion and more hazard cases.
- **Revisit if:** the freeze path limits fmax (then register the request, §4.4).

**B-03 Register file: posedge write + write-through bypass**
- **Rejected:** negedge write (the original): two clock edges complicate ASIC timing and clock-tree design.

**B-04 Interrupts taken on the valid instruction in ID**
- **Why:** older instructions (EX/MEM/WB) complete, younger ones are flushed, and `mepc` = the ID instruction's PC. That's a precise interrupt with minimal logic. It's blocked during freeze, load-use stall, redirects and CSR instructions in EX.
- **Rejected:** taking it at WB/commit: needs flushing completed state or a commit stage.

**B-05 Harvard CPU (separate fetch port)**
- **Why:** fetches never contend with data accesses. This evolves into ITCM in v2.

**B-06 tiny-gpu ready-pulse adapter + GPU priority on GPU memories (v1)**
- **Why:** tiny-gpu holds valid until ready, while synchronous SRAM answers next cycle; a one-shot fire plus a 1-cycle ready pulse adapts them. Priority keeps kernel timing independent of the CPU.
- **Superseded by:** GPU v2 on the crossbar.

**B-07 UART TX back-pressure via bus grant**
- **Why:** a store to `UART_DATA` simply waits while the transmitter is busy, so firmware needs no polling.
- **Rejected:** polling `STATUS` in software (more code, same speed).
- **Revisit if:** FIFOs land (S4); back-pressure then applies only when the FIFO is full.

**B-08 Hardware UART boot loader (FSM, no ROM)**
- **Why:** a chip must be programmable without a testbench; an FSM is about 1k cells and needs no firmware.
- **Rejected:**
  - boot ROM + software loader: needs ROM generation and a bootstrapping problem;
  - JTAG debug module: large and complex (D-27).

**B-09 Interrupt sources: GPU done as edge-latched W1C; UART RX as level**
- **Why:** `gpu_done` stays high until reset, so it must be edge-latched; RX is naturally cleared by reading data.

**B-10 Extra CPU reset cycle after boot release**
- **Why:** lets IMEM already be fetching address 0 when the CPU leaves reset (synchronous-SRAM latency).

**B-11 clang/LLVM for firmware**
- **Rejected:** GNU riscv toolchain: not installed and heavier to set up on the team's machines; clang's riscv32 target plus ld.lld were available and work.
- **Revisit if:** a library needs GCC.

**B-12 cocotb + Python golden models + mutation checks**
- **Why:** fast to write; Python models double as tooling; mutation checks prove the tests can fail.
- **Rejected:** SystemVerilog/UVM: no licensed simulator, heavy methodology.

**B-13 sv2v for tiny-gpu**
- **Why:** tiny-gpu uses SystemVerilog that Icarus/Yosys/OpenLane handle poorly; sv2v gives Verilog-2005.
- **Revisit:** at the GPU v2 rewrite (D-38).

### 8.2 System architecture

**D-01 Topology: CPU host + GPU accelerator on shared memory**
- **Why:** the standard heterogeneous-SoC pattern (phone SoCs, Jetson-class): the CPU runs control and OS, the GPU runs data-parallel kernels.
- **Rejected:**
  - *GPU-only* (GPU runs everything): GPUs are poor at control-heavy code, and there's nobody to manage launches.
  - *Multicore CPU instead of a GPU*: loses the SIMT/GPU contribution.
  - *GPU as a CPU coprocessor via custom RISC-V instructions*: ties the GPU to the CPU pipeline, removes concurrency, and makes both harder to verify.
- **Revisit if:** never.

**D-02 Keep our own RV32 CPU core**
- **Why:** it's the team's own verified design (16 tests, interrupts, bus freeze); examiners value own work; it's good enough for a host.
- **Rejected:** *Ibex, CV32E40P, VexRiscv, PicoRV32*: more mature, but replacing our core adds nothing to the thesis.
- **Fallback (deliberately cheap):** CV32E40P and Ibex use OBI-style memory interfaces, so choosing OBI (D-06) makes a swap possible.
- **Revisit if:** CPU work (traps/timer/FreeRTOS) blocks progress for more than 3 weeks.

**D-03 CPU ISA: RV32IM + Zicsr, machine mode only**
- **Why:**
  - M is needed for **fair GPU-vs-CPU comparison** (without it the CPU does multiplies in software and the GPU looks better than it is) and for firmware speed;
  - traps and a timer are needed for FreeRTOS and robustness.
- **Rejected:**
  - *C (compressed)*: code-size win but a decoder rewrite plus misaligned fetch;
  - *A (atomics)*: no multi-core CPU; single-producer/single-consumer rings need none;
  - *U/S modes, PMP*: no isolation requirement;
  - *F (floating point)*: area/verification cost, not needed.
- **Revisit if:** code size exceeds ITCM (then consider C) or a second CPU appears (then A).

**D-04 Private CPU memories (ITCM/DTCM) instead of caches**
- **Why:** deterministic single-cycle access, the CPU never contends with the GPU (that's the core of claim 2), trivial hardware, and no coherence issues.
- **Rejected:**
  - *I/D caches over shared memory*: adds miss handling, refill paths and coherence (D-05);
  - *CPU fetching directly from shared SRAM*: every fetch would contend with the GPU and display.
- **Revisit if:** code/data outgrow TCMs (FPGA_FULL already gives 32/16 KB).

**D-05 No CPU data cache (no coherence problem by construction)**
- **Why:** shared data is accessed uncached through the crossbar; the CPU's private data is in DTCM.
- **Rejected:**
  - *write-through cache + software flush/invalidate*: error-prone, and bugs are intermittent;
  - *hardware coherence (snooping)*: far beyond scope.
- **Revisit if:** CPU access to shared data becomes a measured bottleneck (unlikely; the CPU mostly prepares descriptors).

**D-06 Bus protocol: OBI (Open Bus Interface)**
- **Why:** nearly identical to our v1 protocol (req/gnt + response); adds `rvalid`/`err` for variable-latency slaves; an industry spec (OpenHW Group) used by real cores; small and verifiable.
- **Rejected:**
  - *AXI4*: five channels, bursts, IDs and out-of-order responses solve problems we don't have (on-chip SRAM answers in about 1 cycle; all IP is ours). It means more logic in every block, more verification and known deadlock pitfalls.
  - *AXI4-Lite*: still five channels, no benefit over OBI here.
  - *Wishbone*: viable, but classic Wishbone is less pipelined; OBI matches our existing signals.
  - *TileLink*: good but complex (channels, coherence variants), tied to the Chisel ecosystem.
  - *Custom*: no external reference to verify against.
- **Revisit if:** we integrate AXI IP (e.g. a DDR controller). Then add **one** OBI↔AXI bridge at that boundary.

**D-07 Interconnect topology: crossbar**
- **Why:** parallel transfers between different master/slave pairs, which is what makes CPU/GPU/display concurrency real. At ~9 × 11 ports it's small.
- **Rejected:**
  - *shared bus* (v1): one transfer at a time;
  - *network-on-chip*: routers, packets and latency for a design that fits a crossbar;
  - *hierarchical buses*: harder to reason about fairness and still serialise.
- **Revisit if:** port counts grow so the crossbar fails timing; then split the GPU ports onto a sub-crossbar (cluster-level).

**D-08 Shared SRAM: 8 single-port banks, word-interleaved**
- **Why:** banking gives parallel bandwidth with **single-port** SRAMs (cheap on FPGA and ASIC); word interleaving spreads consecutive addresses (the GPU lane pattern, display lines).
- **Rejected:**
  - *one big SRAM*: one access per cycle total;
  - *multi-port SRAM*: expensive and not available as open ASIC macros;
  - *block interleaving*: a kernel's array would sit in one bank, so lanes collide.
- **Revisit:** the bank count is a scaling-study parameter (4/8/16).

**D-09 No DMA engine**
- **Why:**
  1. The GPU reads and writes shared memory directly (D-10), so nothing is copied between CPU and GPU.
  2. The blocks that move data do so themselves: the display controller fetches lines, and the command processor fetches descriptors and kernels. They're specialised DMAs.
  3. Measurement showed copying wasn't the bottleneck; GPU execution was.
- **Rejected:** *general-purpose DMA*: weeks of design/verification for no measured benefit.
- **Revisit if:** data must stream from outside the chip (SD card, external flash, DDR) into on-chip memory in pieces. Then DMA + double buffering is the right design (a could-have).

**D-10 GPU is a bus master on shared memory (zero-copy)**
- **Rejected:**
  - *private GPU memory + CPU copy* (v1): a byte-wide copy bottleneck; the CPU is busy copying;
  - *private memory + DMA*: solves a problem we can avoid entirely.

**D-11 Asynchronous launch: command processor + ring buffer + fences**
- **Why:** the CPU queues work and returns immediately, and many launches can be queued. It's the real GPU driver model (scaled down), and it makes concurrency the default.
- **Rejected:**
  - *MMIO launch + polling* (v1 style): the CPU babysits;
  - *MMIO launch + interrupt*: one launch at a time, and the CPU must react between kernels.
- **Revisit if:** never; it's central to claim 2.

**D-12 Completion by fence-in-memory + interrupt**
- **Why:** the fence is a durable record (any task can check `cc_done` later); the interrupt wakes sleepers.
- **Rejected:**
  - *interrupt only*: lost if masked or missed, and there's no per-launch status;
  - *polling a status register*: wastes CPU cycles.

**D-13 Single 50 MHz clock domain; VGA via 25 MHz pixel enable**
- **Why:** no clock-domain-crossing logic or verification.
- **Rejected:** *separate 25.175 MHz pixel clock*: needs asynchronous FIFOs and CDC checks for no visible benefit (25.0 MHz is accepted by typical monitors).
- **Revisit if:** a monitor rejects 25.0 MHz (then use an asynchronous FIFO on the display side only).

### 8.3 GPU

**D-14 32-bit data: integer + fixed-point (MULQ with selectable shift), no floating point**
- **Why:**
  - 8-bit (tiny-gpu) wraps at 255 and can't do real work;
  - 32-bit fixed-point covers Mandelbrot, filters and matmul;
  - the selectable shift supports Q16.16 and Q8.24 (the latter reused from IEEE-Core-Cascade).
- **Rejected:**
  - *16-bit*: too little precision for Mandelbrot zoom;
  - *FP32*: large area (adder/multiplier/normaliser per lane) plus IEEE-754 verification burden.
- **Revisit if:** a workload truly needs dynamic range (not planned).

**D-15 Fork tiny-gpu and redesign it into GPU v2**
- **Why:** gives our own GPU contribution while reusing tiny-gpu's proven concepts (dispatcher, block/thread model). Its own README lists exactly our roadmap items (divergence, coalescing, pipelining, warp scheduling, caching) as open work.
- **Rejected:**
  - *keep tiny-gpu unmodified*: slower than our CPU, no contribution;
  - *Vortex (RISC-V GPGPU)*: large and complex, and adopting it removes our contribution;
  - *design from scratch with no reference*: higher risk with no added value.

**D-16 Our own GPU ISA (v2), not RISC-V-based**
- **Why:**
  - the compiler backend becomes a genuine from-scratch CS contribution;
  - the ISA is tailored to SIMT (guards on every instruction, SPLIT/JOIN, special registers, MULQ);
  - the encoding stays simple for the hardware.
- **Rejected:**
  - *keep tiny-gpu's 16-bit ISA*: 4-bit opcodes, 8-bit immediates, no predicates/divergence/32-bit;
  - *RISC-V + SIMT extensions (Vortex-style)*: reuses LLVM, but the CS work becomes "patch LLVM", which is much harder and less original, and the GPU then needs full RV32 decode;
  - *VLIW*: wrong model for SIMT.
- **Revisit if:** never (the ISA freeze is in S3).

**D-17 One resident block per core**
- **Why:** the scratchpad and barrier belong to exactly one block; dispatch is simple.
- **Rejected:** *multiple blocks per core*: needs partitioned scratchpad/barriers. The latency hiding it gives is already provided by W warps per block.
- **Revisit if:** the scaling study shows low occupancy for small blocks.

**D-18 Barrel (fine-grained multithreaded) pipeline; at most one instruction per warp in flight**
- **Why:** eliminates forwarding and hazard logic entirely; hides memory and multiply latency by switching warps; reaches about 1 instruction/cycle with W ≥ pipeline depth. It's the simplest design that's actually fast.
- **Rejected:**
  - *keep the multi-step FSM* (tiny-gpu): about 10 cycles per instruction;
  - *single-warp pipeline with forwarding*: hazard logic, and memory latency stalls everything;
  - *superscalar/out-of-order*: far beyond scope and area.
- **Trade-off accepted:** a single warp runs at 1/4 speed, so kernels need enough threads (≥ W×L per core) to hit peak. Benchmarks are sized accordingly.

**D-19 No GPU atomics in v2**
- **Why:** none of our benchmarks require them (histogram is done with per-block scratchpad bins + barrier + merge).
- **Rejected:** *atomic add/CAS at the banks*: crossbar and bank read-modify-write support plus verification.
- **Revisit if:** a showcase needs them.

**D-20 Divergence: per-warp active mask + reconvergence stack with compiler-inserted SPLIT/JOIN**
- **Why:** correct for structured control flow with minimal hardware (a small stack of PC + mask). The compiler knows where reconvergence is (the immediate post-dominator), so the hardware doesn't have to discover it.
- **Rejected:**
  - *no divergence* (tiny-gpu): incorrect for any data-dependent `if`;
  - *predication only*: executes both sides always, poor for long or nested branches (Mandelbrot's escape loop);
  - *hardware-discovered reconvergence*: complex;
  - *independent thread scheduling* (Volta-style): far beyond scope.
- **Both are kept:** guards (predication) for short `if`s, the stack for long ones; the compiler chooses (that choice is part of the compiler ablation).

**D-21 Kernel delivery: per-core program RAM, loaded by the command processor**
- **Why:** the fetch path is simple, single-cycle and contention-free. Kernels are small (≤ 512 instructions on FPGA). Reloads are skipped when the same kernel is reused.
- **Rejected:**
  - *shared program memory* (tiny-gpu): one fetch channel shared by cores, the other measured bottleneck;
  - *instruction cache over shared memory*: misses and refill logic. Kept as v2.4 stretch.
- **Revisit if:** kernels exceed program RAM.

**D-22 Parameterised GPU; cluster arbiter with P ports (default one per core)**
- **Why:** one RTL for FPGA, ASIC and the scaling study. Grouping cores behind a cluster arbiter keeps the system crossbar small and fast.
- **Rejected:**
  - *fixed configuration*: no scaling study;
  - *every lane its own crossbar master*: a huge, slow crossbar.
- **Defaults:** FPGA 4 cores (8 stretch), ASIC_LITE 2 (4 if it fits). Final numbers come from the scaling study.

**D-23 Per-core scratchpad + barrier (not a data cache)**
- **Why:** explicit, deterministic, and the standard GPU programming model (CUDA shared memory); enables tiled matmul/convolution; needs no tags or miss handling.
- **Rejected:** *L1 data cache per core*: tag/miss logic, plus coherence with CPU and other cores.

### 8.4 Software

**D-24 Kernel language: small C-like "CCK", our own compiler in Python**
- **Why:** a full compiler pipeline (parse → IR → uniformity analysis → register allocation → codegen) at a scale three students can finish; uniformity analysis and SPLIT/JOIN placement are real GPU-compiler research topics.
- **Rejected:**
  - *LLVM backend for ISA v2*: weeks of LLVM learning before the first instruction; large and fragile;
  - *OpenCL C via clang front end + our backend*: still LLVM IR handling;
  - *assembly only*: fails G3;
  - *MLIR*: too heavy.
- **Revisit if:** never; the language grows by need.

**D-25 Compiler implementation language: Python**
- **Why:** fastest to write and change; shares code with the assembler and simulator; compile speed is irrelevant for small kernels.
- **Rejected:** *C++/Rust*: slower development; no performance need.

**D-26 Scheduler: cooperative first (S4), FreeRTOS later (S5)**
- **Why:** the cooperative scheduler needs no traps or timer and shows concurrency early; FreeRTOS is the credible "real OS" once traps and timer are verified.
- **Rejected:**
  - *bare-metal superloop only*: weak concurrency story;
  - *Zephyr*: larger, heavier build system;
  - *Linux*: needs an MMU and far more memory.
- **Fallback:** if the FreeRTOS port slips, the cooperative scheduler stays (the claims still hold).

**D-27 Debug: UART debug bridge, not a RISC-V JTAG debug module**
- **Why:** the bridge already exists (the boot loader). Extending it for runtime peek/poke gives most debugging value at about zero cost.
- **Rejected:** *RISC-V Debug Spec module + OpenOCD + GDB*: a large, complex block with its own verification.
- **Stretch:** a GDB remote stub over UART in firmware.

**D-28 Asynchronous runtime with fences and callbacks**
- **Why:** it exposes concurrency to applications (D-11).
- **Rejected:** *blocking launch API only*: hides the hardware's main feature. A blocking `cc_launch_sync` is provided as a convenience wrapper.

**D-29 ISA defined once in a machine-readable table, generators for everything**
- **Why:** RTL decoder, assembler, simulator and docs can't drift.
- **Rejected:** *hand-maintained copies*: the classic source of "works in sim, fails in RTL".

**D-30 Kernel language deliberately minimal (no recursion, function pointers, dynamic memory, structs in v1)**
- **Why:** scope control. Every feature costs parser, IR, codegen, tests and GPU support.
- **Revisit if:** a benchmark can't be written; add the smallest feature that unblocks it.

**D-31 Simulator is functional only; performance is measured on RTL**
- **Why:** halves the simulator effort, and RTL numbers are the honest ones (the scaling study runs RTL configurations in Verilator).
- **Rejected:** *cycle-accurate simulator*: must be kept in sync with every microarchitecture change, which is a second design to maintain.

### 8.5 Platform, verification, process

**D-32 FPGA platform: Nexys 4 DDR, block-RAM memories (no DDR)**
- **Why:** the team already has constraints and experience (IEEE-Core-Cascade); about 600 KB of block RAM covers FPGA_FULL; VGA, buttons, switches and UART are on board.
- **Rejected:**
  - *using the board's DDR2 via Xilinx MIG*: AXI IP, calibration, latency, and not portable to ASIC;
  - *another board*: no benefit.
- **Revisit if:** framebuffers plus data exceed block RAM (then MIG + an OBI↔AXI bridge, as a could-have).

**D-33 Verification stack: cocotb + Icarus for units, Verilator for system, SymbiYosys for formal, RISCOF for compliance**
- **Why:** each tool where it's strongest:
  - Icarus models unknown (X) values (catches reset bugs);
  - Verilator is 100–1000× faster for long system runs;
  - formal proves the crossbar never loses or starves transactions;
  - RISCOF is the official RISC-V compliance check.
- **Rejected:**
  - *only Icarus*: system runs too slow (a Mandelbrot frame = tens of millions of cycles);
  - *only Verilator*: misses X bugs;
  - *UVM*: no licensed simulator.

**D-34 Monorepo with CI**
- **Why:** one commit = one consistent state of RTL + software + tests; CI catches integration breakage the day it happens.
- **Rejected:** *separate repos* (today: one git repo, two untracked trees): version skew, lost work.

**D-35 RTL coding standard: Verilog-2005 style with a SystemVerilog subset only where every tool accepts it (or via sv2v)**
- **Why:** must pass Icarus, Verilator, Yosys, Vivado and LibreLane.
- **Rejected:**
  - *full SystemVerilog*: uneven open-tool support;
  - *Chisel/SpinalHDL*: a new language for everyone plus generated-Verilog debugging.
- **GPU v2 rewrite:** no blocking assignments in clocked blocks, no latches, explicit resets.

**D-36 GDS only; actual tapeout out of scope**
- **Why:** fabrication depends on external shuttle availability and months of turnaround, likely beyond graduation. A clean, timing-closed GDS is a strong and fully controllable result.
- **Rejected:** *tapeout via academic or open shuttles*: access and schedule risk outside our control.

**D-37 GDS of ASIC_LITE (all features, small memories), not of FPGA_FULL**
- **Why:** with sky130 open SRAM macros of about 1–2 KB, FPGA_FULL's ~290 KB means about 150 macros and tens of mm², multi-hour runs and harder timing (long wires to far banks), and it shows nothing new (it's the same logic plus more SRAM copies). ASIC_LITE (~40 KB) still runs the real software stack.
- **Rejected:** *full-size GDS*: cost without insight. ASIC_MID (64–128 KB) is a stretch for showing scaling.

**D-38 PDK and flow: sky130 + LibreLane (OpenLane 2)**
- **Why:** the most mature open flow and PDK, with SRAM macros available and the most examples. No foundry relationship is needed since we don't fabricate.
- **Rejected:**
  - *GF180*: lower density, fewer examples;
  - *IHP SG13G2*: good and improving, but fewer flow examples;
  - *commercial tools* (Cadence/Synopsys): licence access uncertain, results not reproducible by others.
- **Revisit if:** the university provides commercial tools and the guide prefers them.

**D-39 Hierarchical hardening**
- **Why:** shorter runs (laptop-friendly), timing isolated per block, reusable macros.
- **Rejected:** *flat run*: hours per iteration, and every change re-runs everything.

**D-40 Memories in ASIC: sky130 SRAM macros first, DFFRAM fallback**
- **Why:** macros are dense. DFFRAM (flip-flop/latch RAM generated in the flow) is a reliable fallback if macro integration (power connections, timing models, LVS) causes trouble.

**D-41 Keep v1 as a tagged baseline (`soc-v1`)**
- **Why:** every v2 improvement is reported against v1 (and against the CPU), so the evaluation has a fixed reference.

---

## 9. Roadmap

### 9.1 Capacity model
- Assumption: 3 people × ~12 productive weeks × ~12 h/week ≈ **36 person-weeks (pw) per semester**.
- Task sizes: **S** ≈ 1–2 pw, **M** ≈ 3–5 pw, **L** ≈ 6–10 pw.
- Each semester below is estimated at **35–38 pw: there is no slack.** Expect 20–30 % slip and use §10's cut order.
- Semester length assumed about 16 weeks: weeks 1–14 for work, weeks 15–16 for evaluations/exams. Adjust to the actual academic calendar.

Roles: **GPU** (GPU lead), **PLT** (platform lead), **SW** (software lead), **ALL**.

### 9.2 Before Semester 3 (break: strongly recommended)
| ID | Task | Owner | Size |
|---|---|---|---|
| S0-1 | Create the monorepo (§15.1), import CPU, SoC, fork of tiny-gpu; commit everything; tag `soc-v1` | SW | S |
| S0-2 | CI: run the CPU suite + SoC suite + Yosys lint on every push | SW | S |
| S0-3 | FPGA wrapper (`nexys4ddr_top`, XDC, Vivado script) for the v1 SoC | PLT | S |

### 9.3 Semester 3: "Foundation: everything can run at once" (≈ 35 pw)
| ID | Task | Weeks | Owner | Size | Depends on |
|---|---|---|---|---|---|
| S3-01 | FPGA bring-up of v1: live UART boot, matadd/matmul; record LUT/BRAM/fmax baseline | 1–3 | PLT | S | S0-3 |
| S3-02 | Assembler for tiny-gpu ISA (retire hand binary in v1 firmware) | 1–2 | SW | S | — |
| S3-03 | Verilator virtual board v1 (ELF load, UART ↔ terminal) | 1–4 | SW | M | S0-1 |
| S3-04 | ISA v2 draft → review → **freeze (week 5)**; `isa_v2.yaml` + generators | 2–5 | GPU+SW | S | — |
| S3-05 | OBI spec + memory map v2 → **freeze (week 5)** | 2–5 | PLT | S | — |
| S3-06 | OBI crossbar + 8-bank shared SRAM + peripheral bridge + v1-protocol adapters; unit tests with protocol checkers | 4–9 | PLT | M | S3-05 |
| S3-07 | CPU: ITCM (dual-port) / DTCM split, OBI master port | 6–9 | PLT | S | S3-06 |
| S3-08 | ISA v2 assembler/disassembler | 5–7 | SW | S | S3-04 |
| S3-09 | ISA v2 functional simulator (incl. divergence semantics, ahead of hardware) | 5–9 | SW | M | S3-04 |
| S3-10 | **GPU v2.0 RTL**: 32-bit datapath, decoder, lanes as OBI masters via cluster arbiter, 1-cycle handshake, parameterised N; program RAM via MMIO | 5–12 | GPU | L | S3-04, S3-06 |
| S3-11 | RTL ↔ simulator trace comparison harness | 9–11 | SW+GPU | S | S3-09, S3-10 |
| S3-12 | Driver v1 (pointer args, blocking launch) + HAL + firmware ported to memory map v2 | 8–11 | SW | S | S3-07 |
| S3-13 | Benchmark harness + results CSV + plotting (`cc-bench`) | 9–11 | SW | S | S3-03 |
| S3-14 | LibreLane trial run on v1 SoC (learn flow, macro hookup, first timing report) | 10–12 | PLT | S | S0-1 |
| S3-15 | Integration: Mandelbrot (ISA v2 assembly) on FPGA_FULL + virtual board; CPU benchmark running concurrently; measurements | 12–14 | ALL | M | all above |

- **Midsem checkpoint (≈ week 7):** v1 live on FPGA; ISA v2 + OBI + memory map frozen; crossbar unit tests passing; v2 assembler working; virtual board running v1 firmware.
- **Endsem demo:** GPU v2.0 (4 cores) renders Mandelbrot from shared memory **while the CPU runs a benchmark**; the image is shown on the PC (sent over UART / dumped from the virtual board).
- **Exit criteria:**
  1. GPU v2.0 beats the CPU on Mandelbrot (target ≥ 2×).
  2. RTL matches the simulator on every kernel (trace comparison).
  3. CPU slowdown during GPU work measured.
  4. Everything in CI.
  5. First LibreLane report on v1.

### 9.4 Semester 4: "A real GPU, an asynchronous system, a display" (≈ 37 pw: slightly over)
| ID | Task | Weeks | Owner | Size | Depends on |
|---|---|---|---|---|---|
| S4-01 | **GPU v2.1 divergence** (mask + stack, SPLIT/JOIN, error model) | 1–5 | GPU | M | S3-10 |
| S4-02 | **Command processor** (ring, descriptor fetch, kernel broadcast load, dispatch, store drain, fence, IRQ, errors, timeout) | 1–6 | GPU | M | S3-10 |
| S4-03 | CPU: M extension | 1–4 | PLT | S | — |
| S4-04 | CPU: traps (exceptions), `mtval`, CLINT timer, `minstret` | 4–8 | PLT | M | S4-03 |
| S4-05 | Display controller + FPGA VGA + virtual-board frame dump | 5–8 | PLT | M | S3-06 |
| S4-06 | Interrupt controller v2 (priority, claim/complete), UART FIFOs, performance counters | 8–10 | PLT | S | S4-04 |
| S4-07 | **Compiler v1:** front end (wk 1–4), IR + lowering (4–7), uniformity analysis + branch lowering + codegen (7–10), linear-scan register allocation (8–11), tests (10–12) | 1–12 | SW | L | S3-08, S3-09 |
| S4-08 | **GPU v2.2 barrel pipeline** (warp scheduler, 4-stage pipeline, ready bits, LSU return port) + GPU perf counters | 6–13 | GPU | L | S4-01 |
| S4-09 | Asynchronous runtime (`cc_*`) + cooperative scheduler | 6–9 | SW | S | S4-02 |
| S4-10 | ASIC_LITE parameter set; LibreLane runs of CPU and GPU-core macros; timing triage | 9–12 | PLT | S | S3-14 |
| S4-11 | Integration: **interactive Mandelbrot explorer** (queue-driven GPU rendering, page-flip at vsync, buttons + console on CPU), compiled kernels; measurements | 12–14 | ALL | M | all above |

- **Midsem checkpoint:** divergence working in RTL and simulator; command queue end to end (CPU queues several launches, fences complete in order); compiler compiling matadd/saxpy correctly.
- **Endsem demo:** the explorer runs on FPGA (and the virtual board): the GPU renders frame N+1 into the back buffer from the queue, the display scans frame N, and the CPU handles input and live statistics, all concurrently, with kernels written in CCK.
- **Exit criteria:**
  1. GPU ≥ 5× CPU (RV32IM) on Mandelbrot (target).
  2. CPU slowdown < 10 % while rendering.
  3. Compiled kernels pass differential tests.
  4. First ASIC_LITE sub-block timing reports.

### 9.5 Semester 5: "Performance, robustness, layout, evaluation" (≈ 35.5 pw)
| ID | Task | Weeks | Owner | Size | Depends on |
|---|---|---|---|---|---|
| S5-01 | **GPU v2.3** scratchpad + barrier; tiled matmul, 3×3 convolution | 1–5 | GPU | M | S4-08 |
| S5-02 | Compiler optimisations (constant folding/propagation, DCE, CSE, strength reduction, LICM), spilling to scratchpad, **ablation harness** | 1–6 | SW | M | S4-07 |
| S5-03 | FreeRTOS port (trap entry/exit, timer tick, `ecall` yield); runtime on semaphores | 1–4 | SW+PLT | M | S4-04 |
| S5-04 | **ASIC_LITE GDS:** full hierarchical flow (wk 1–3), timing/DRC/LVS closure (3–8), gate-level simulation + power (8–10) | 1–10 | PLT | L | S4-10 |
| S5-05 | **Scaling study:** cores 1/2/4/8 × warps 2/4/8 × banks 4/8/16 (Verilator RTL runs) + Vivado resources | 3–8 | GPU+SW | M | S4-08 |
| S5-06 | Formal: crossbar/arbiter properties (no loss, no duplication, bounded wait); RISCOF RV32IM compliance | 4–8 | PLT+GPU | M | S3-06, S4-04 |
| S5-07 | Showcase application (image-filter pipeline or tiled matmul) + CoreMark on CPU (alone and while GPU renders) | 5–9 | SW | M | S5-01 |
| S5-08 | Profiler + activity timeline | 6–10 | SW | S | S4-06 |
| S5-09 | Hour-long FPGA stress runs; error-path tests (GPU errors, bus errors, timeouts) | 8–10 | ALL | S | — |
| S5-10 | *Stretch:* v2.4 coalescing / 2 ports per core / instruction cache; ASIC_MID | if ahead | GPU/PLT | — | — |
| S5-11 | Final report / paper, documentation pass, final demo freeze | 9–14 | ALL | M | — |

- **Midsem checkpoint:** first complete ASIC_LITE GDS (violations allowed); scaling data collected; FreeRTOS booting.
- **Endsem:** final FPGA demo + GDS sign-off (DRC/LVS clean, timing met, gate-level simulation passing) + report.

> **Calendar warning:** if Semester 5 overlaps placements or internships, it will lose time. That's why LibreLane work starts in S3/S4 and the GDS task starts in S5 week 1. Front-load everything you can.

### 9.6 Critical path
`ISA v2 freeze (S3-04)` → `GPU v2.0 (S3-10)` → `divergence (S4-01)` → `barrel pipeline (S4-08)` → `scratchpad (S5-01)` → `scaling study (S5-05)` → `report`.

Parallel chains:
- `OBI spec → crossbar → TCM → driver` (S3);
- `simulator → compiler v1 → optimisations` (S3→S5);
- `LibreLane trial → ASIC_LITE blocks → GDS closure` (S3→S5).

A slip in the GPU chain slips the scaling study. **Protect S3-10 and S4-08 above everything else.**

---

## 10. Priorities and cut list

| **Must-have** (claims depend on these) | **Should-have** | **Could-have** |
|---|---|---|
| Monorepo + CI; crossbar + banks + ITCM/DTCM; GPU v2.0–v2.2; command processor; display (FPGA) or frame dumps (laptop); assembler; simulator; compiler v1; async runtime; **CPU M extension**; scaling study; ASIC_LITE GDS; measurements | Traps + timer; performance counters; scratchpad + barrier (v2.3); compiler optimisations; FreeRTOS; RISCOF; crossbar formal checks; UART FIFOs | Coalescing / multi-port (v2.4); instruction cache; SPI/SD + DMA; ASIC_MID; profiler GUI; GDB stub; neural-network demo; DDR via MIG |

**Cut order when behind:**
1. Could-haves.
2. FreeRTOS → keep the cooperative scheduler.
3. Scratchpad (v2.3) → tiled benchmarks dropped; the scaling study uses Mandelbrot and naive matmul.
4. Compiler optimisations beyond two passes.
5. Performance counters → measure with simulation timestamps instead.

**Never cut:** the crossbar, the GPU as a bus master, the command queue, the measurements, CI.

---

## 11. Verification plan

### 11.1 Layers
| Layer | Tool | Scope | Pass criterion |
|---|---|---|---|
| Unit | cocotb + Icarus | Every RTL block (crossbar, banks, CPU additions, GPU units, CP, display, peripherals) | Directed + random tests, protocol checkers silent, 100 % in CI |
| Golden model, CPU | cocotb + `rv32.py` ISS | Whole CPU | All registers and memory match after directed/random programs, under random stalls and interrupts |
| Golden model, GPU | Trace compare vs ISA v2 simulator | GPU v2 | Every writeback `{core, warp, pc, mask, rd, value}` matches |
| Formal | SymbiYosys | Crossbar, arbiters, OBI adapters | No lost or duplicated transaction, response-to-correct-master, bounded wait (fairness) |
| Compliance | RISCOF + riscv-arch-test | RV32IM + Zicsr | All applicable tests pass |
| Compiler | pytest | Front end, IR passes, codegen | Golden outputs; differential vs C reference; fuzzing finds no mismatch over N random kernels |
| System | Verilator virtual board | Firmware + runtime + kernels + display | Console output and frame hashes match golden; runs repeated per CI on short workloads |
| Hardware | FPGA | Whole SoC | Self-test firmware passes; hour-long stress with no error |
| ASIC | Gate-level simulation (Icarus with SDF), STA, DRC/LVS | ASIC_LITE | Smoke test passes on post-synthesis (and post-layout) netlist; timing/DRC/LVS clean |
| Test quality | Mutation checks | Periodic (each semester) | Each injected bug is caught |

### 11.2 Definition of done (per component)
1. RTL/code merged with review.
2. Unit tests in CI, passing.
3. Interface documented (spec updated if touched).
4. Integrated into a system-level test.
5. Hardware only: Vivado + Yosys synthesis without latches or warnings that matter; resource numbers recorded.
6. Performance-relevant: a benchmark result recorded in `bench/results.csv`.

---

## 12. Evaluation plan

### 12.1 Benchmarks
| Benchmark | Character | Purpose |
|---|---|---|
| matadd / saxpy | Memory-bound | Shows memory system limits; v1 comparison |
| Mandelbrot (Q8.24 / Q16.16) | Compute-bound, **naturally divergent** | Main demo; divergence and pipeline effectiveness; core scaling |
| matmul naive / tiled | Mixed; scratchpad + barrier | Memory hierarchy benefit |
| 3×3 convolution (blur/edge) | Mixed, 2-D | Image pipeline showcase |
| Reduction (sum) | Barrier-heavy | Synchronisation cost |
| Histogram (per-block bins) | Scratchpad + merge | No-atomics workaround |
| CoreMark | CPU only | CPU credibility; concurrency (score with GPU idle vs rendering) |

### 12.2 Methodology (fairness rules)
1. Same clock for CPU and GPU; CPU code compiled with `-O2 -march=rv32im_zicsr`.
2. Data in shared memory for both CPU and GPU versions.
3. GPU time reported **two ways**: kernel-only (dispatch → done) and end-to-end (`cc_launch` → fence observed).
4. Every result is stored with commit hash + configuration in `bench/results.csv`; plots are regenerated from it.
5. v1 numbers come from the `soc-v1` tag.

### 12.3 Planned figures and tables
1. GPU speedup over CPU per benchmark, for v1, v2.0, v2.2 and v2.3.
2. Speedup vs cores (1/2/4/8) per benchmark: where it flattens shows the memory limit.
3. Speedup vs banks (4/8/16) and warps (2/4/8).
4. CPU benchmark score: GPU idle vs GPU rendering (concurrency).
5. Compiler ablation: cycles with each optimisation pass on or off; predication vs SPLIT/JOIN.
6. FPGA resources per configuration; ASIC_LITE area breakdown (CPU, GPU, SRAM, crossbar), fmax, power.
7. CPU/GPU activity timeline from the profiler during the Mandelbrot explorer.

---

## 13. Risk register
| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | **Work lost** (`soc/` untracked, CPU uncommitted) | High until fixed | Severe | S0-1, immediately |
| R2 | GPU v2 too ambitious | Medium | High | Staged v2.0–v2.4, each usable; protect the critical path |
| R3 | Compiler late | Medium | Medium | Demos use assembly kernels; the compiler is evaluated independently |
| R4 | Crossbar/freeze path misses 50 MHz | Medium | Medium | Register the CPU request; reduce the FPGA target to 40 MHz if needed |
| R5 | No FPGA board access | Low–Medium | Medium | Virtual board; ask the guide now; get access by S4 at the latest |
| R6 | SRAM macro problems in LibreLane | Medium | Medium | Trial in S3; DFFRAM fallback; smaller memories |
| R7 | System simulation too slow | High (Icarus) | Medium | Verilator for system runs; short workloads in CI |
| R8 | Verilator hides X/reset bugs | Medium | Medium | Icarus unit tests + gate-level simulation; explicit resets |
| R9 | Interface drift between members | Medium | High | Frozen, versioned specs; generators from `isa_v2.yaml`; CI on every merge |
| R10 | Team time loss (exams, placements) | High | High | Front-loading; cut list; no single owner of a critical item without a reviewer who can take over |
| R11 | FreeRTOS port problems (trap bugs) | Medium | Low | Cooperative scheduler fallback |
| R12 | Laptop too weak for top-level GDS | Medium | Medium | Hierarchical hardening; ask for a lab workstation |
| R13 | Display timing rejected by monitor | Low | Low | Test the monitor early (S4 wk 5); asynchronous FIFO fallback |
| R14 | BRAM over-subscription on FPGA | Low | Medium | Budget tracked per synthesis; reduce framebuffer to 1 or shared to 192 KB |

---

## 14. Team, roles, process

### 14.1 Roles
| Role | Owns | Reviews |
|---|---|---|
| **GPU lead** | ISA v2 (with SW), GPU v2.0–v2.4, command processor, GPU tests | Crossbar interface, compiler codegen |
| **Platform lead** | FPGA, crossbar, memories, CPU additions, display, peripherals, LibreLane/GDS | GPU bus interface, runtime/HAL |
| **Software lead** | Assembler, simulator, compiler, runtime, scheduler/FreeRTOS, virtual board, CI, benchmarks | ISA v2, command-processor ABI |

Each critical item has an owner **and** a named reviewer who knows it well enough to take over.

### 14.2 Process
- **Weekly sync** (30 min): progress against task IDs, blockers, interface questions.
- **Monthly integration demo:** everything merged runs together on the virtual board (and the FPGA when available).
- **Branching:** `main` protected; feature branches; PR + one review + green CI to merge.
- **Specs** (`docs/spec/`): versioned with a changelog. Changes need all three members' agreement and the generators re-run.
- **This document:** updated in the same PR as any decision change.
- **Issue tracker:** one issue per roadmap task ID, with labels for must/should/could.
- **Writing as you go:** each completed component gets a short design note in `docs/design/`, and results go into `bench/`, so the final report is mostly assembly work.

---

## 15. Repository, tools, environment

### 15.1 Proposed repository layout
```
corecascade/
├── MASTER_PLAN.md                 (this file)
├── docs/
│   ├── spec/        isa_v2.md · bus_obi.md · memory_map.md · driver_abi.md
│   ├── design/      one note per component
│   └── slides/      evaluation decks
├── hw/
│   ├── cpu/         rv32 core (from rv32i-pipeline)
│   ├── gpu/         GPU v2 (forked from tiny-gpu; upstream kept as git history)
│   ├── soc/         crossbar, banks, CP, display, peripherals, soc_top
│   ├── common/      sram wrappers, FIFOs, synchronisers
│   ├── cfg/         fpga_full.vh · asic_lite.vh · asic_mid.vh
│   ├── fpga/        nexys4ddr_top.v, .xdc, Vivado TCL
│   └── asic/        asic_top.v, LibreLane configs, macro wrappers
├── sw/
│   ├── isa/         isa_v2.yaml + generators
│   ├── asm/ · sim/ · compiler/
│   ├── runtime/ · hal/ · rtos/ · libc/ · fw/ · apps/
│   └── tools/       cc-load, cc-prof, cc-bench
├── verif/
│   ├── cpu/ · gpu/ · soc/ · formal/ · compliance/ · gls/
├── sim/verilator/   virtual board harness
├── bench/           benchmarks, results.csv, plot scripts
└── .github/workflows/  CI
```

### 15.2 Tools (currently installed versions)
| Tool | Version | Use |
|---|---|---|
| Icarus Verilog | 13.0 (devel) | Unit simulation, X checks, gate-level simulation |
| cocotb | 2.0.1 | Testbenches |
| Verilator | 5.020 | Virtual board, system runs, scaling study |
| Yosys | 0.61 | Lint, synthesis estimates |
| sv2v | 0.0.12 | tiny-gpu conversion (until the v2 rewrite) |
| clang / ld.lld | 18.1.3 | Firmware (`riscv32`) |
| Vivado | 2024.2 | FPGA synthesis/implementation |
| Python | 3.12 (WSL) | Tools, compiler, simulator |
| To install | — | LibreLane + sky130 PDK (Docker or Nix), SymbiYosys, RISCOF, GTKWave (already present), KLayout |

**Note:** the installed Icarus lacks zlib (no FST waves); VCD is used instead (`make VCD=1`).

---

## 16. Open questions
| # | Question | Ask whom | Needed by |
|---|---|---|---|
| Q1 | Do we have guaranteed access to a Nexys 4 DDR (or similar) for Semesters 3–5? | Guide / lab | Before S3 |
| Q2 | Is a lab workstation (≥ 32 GB RAM) available for LibreLane top-level runs? | Guide / department | S4 |
| Q3 | Exact evaluation dates and format per semester (midsem/endsem)? | Guide | Before S3 |
| Q4 | Does Semester 5 overlap placements/internships? | Team | Before S3 (affects front-loading) |
| Q5 | Is a paper submission expected or encouraged? Which venue? | Guide | S4 |
| Q6 | Are commercial EDA tools available and preferred for the GDS? (affects D-38) | Guide / department | S3 |
| Q7 | Who takes which role (§14.1)? | Team | Before S3 |

---

## 17. Glossary
| Term | Meaning |
|---|---|
| **SoC** | System-on-chip: CPU, GPU, memory and peripherals on one chip |
| **SIMT** | Single Instruction, Multiple Threads: many threads execute the same instruction on different data |
| **Lane / warp / block / grid** | See §5.1 |
| **Divergence / reconvergence** | Threads of a warp taking different branch directions / rejoining afterwards |
| **Barrel pipeline** | A pipeline that issues from a different thread group each cycle, so one group's instructions never overlap |
| **OBI** | Open Bus Interface: a simple request/grant/response bus protocol from the OpenHW Group |
| **Crossbar** | An interconnect letting any master reach any slave, with independent transfers in parallel |
| **Bank / interleaving** | Memory split into independent parts; consecutive addresses placed in different parts |
| **TCM (ITCM/DTCM)** | Tightly-coupled memory: private SRAM wired directly to the CPU |
| **Command processor** | A hardware unit that reads GPU launch requests from memory and executes them |
| **Ring buffer / descriptor** | A circular queue in memory / one entry describing one kernel launch |
| **Fence** | A value written to memory when a launch completes, so software can check completion |
| **DMA** | Direct memory access: hardware that copies data between memories without the CPU |
| **CSR, CLINT, trap** | RISC-V control/status register; core-local timer (`mtime`/`mtimecmp`); an exception or interrupt entry |
| **ISS** | Instruction-set simulator (golden model) |
| **GDS** | The final chip layout file |
| **DRC / LVS** | Design-rule check (geometry legal) / layout-versus-schematic (layout matches netlist) |
| **STA / GLS** | Static timing analysis / gate-level simulation of the synthesised netlist |
| **PDK, macro, DFFRAM** | Process design kit; a pre-built block (e.g. SRAM); RAM built from standard flip-flops/latches |
| **LibreLane (OpenLane 2)** | Open-source flow turning Verilog into GDS |
| **CI** | Continuous integration: automatic tests on every push |

---

## Appendix A: Baseline measurements
(All measured in simulation of the v1 design, 10 ns clock, end of Semester 2.)

| Measurement | Value |
|---|---|
| CPU tests | 16 / 16 pass (directed, random, random bus stalls 40–60 %, CSR, random interrupts) |
| SoC test | Pass: UART boot (2,560 B) → 4 kernels → UART-RX interrupt → GPU memory matches model |
| **matadd, 8 elements: tiny-gpu kernel** | **265 cycles** (GPU only, excludes launch overhead) |
| **Same work on CPU (RV32I loop)** | **96 cycles** (91 in the loop) |
| GPU speedup over CPU | **0.36×** |
| matmul 2×2 on tiny-gpu | 595 cycles |
| tiny-gpu time in memory phases | 168 of 265 cycles (63 %): 16 reads span 112 cycles, 8 writes span 56 cycles (~7 cycles per access, serialised on one channel) |
| tiny-gpu SRAM actually requested | 48 cycles (the SRAM answers in 1 cycle; the handshake dominates) |
| tiny-gpu instruction fetches | 26 (13 instructions × 2 cores), ~10 cycles apart |
| Interrupt latency (`gpu_done` → `irq_take`) | 2 cycles |
| CPU/GPU contention test | 4 refused CPU cycles, all reads correct |
| Firmware size | 2,292 B code + 264 B rodata (clang `-Os`) |
| Yosys generic cells (memories excluded) | CPU 8,646 · tiny-gpu 15,244 · UART boot loader 967 |
| Yosys structural check (full SoC) | Pass: no latches, multiple drivers or combinational loops |

## Appendix B: Current file inventory
```
rv32i-pipeline/ (git; changes UNCOMMITTED)
  pp/pp.srcs/sources_1/new/  ALU.v alu_four.v alu_pc.v bj_det.v controlpath.v csr_unit.v
                             extender_offsethandler.v hazard_unit.v mux_32.v mux_32_3in.v pc_.v
                             pp_stage_2..5.v reg_file_.v rv32i_core.v sram_sp.v top_module.v
  verification/              Makefile rv32.py tb_cpu.v test_pipeline.py waves.v
tiny-gpu/ (upstream clone, unmodified)
soc/ (NOT under version control)
  rtl/    soc_top.v gpu_subsys.v uart_boot.v uart_periph.v uart_rx.v uart_tx.v sysctl.v
  fw/     crt0.S link.ld main.c runtime.c soc.h
  test/   Makefile test_soc.py waves.v soc.gtkw
  tools/  uart_load.py
  Makefile README.md
IEEE-Core-Cascade/ (previous 8-core GPU project; reference for Q8.24 ALU, VGA, Nexys constraints)
```

## Appendix C: References
- tiny-gpu: https://github.com/adam-maj/tiny-gpu (README "Next Steps": instruction cache, branch divergence, memory coalescing, pipelining)
- OpenHW Group OBI (Open Bus Interface) specification
- RISC-V Unprivileged and Privileged ISA specifications (RV32IM, Zicsr, machine mode, CLINT conventions)
- RISCOF and riscv-arch-test (RISC-V architectural compliance)
- FreeRTOS RISC-V port: https://www.freertos.org
- Vortex GPGPU (RISC-V-based GPU; considered and rejected, D-15/D-16)
- NVIDIA Fermi-era SIMT reconvergence (SSY/SYNC); the basis of SPLIT/JOIN (D-20)
- cocotb: https://www.cocotb.org · Verilator: https://verilator.org · Yosys/SymbiYosys (YosysHQ)
- LibreLane / OpenLane 2, SkyWater sky130 PDK, OpenRAM sky130 SRAM macros, DFFRAM
- EEMBC CoreMark
- IEEE-Core-Cascade (team's previous project): Q8.24 fixed-point ALU, VGA Mandelbrot, divider removal for timing
