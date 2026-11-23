# Reconciliation: repository state vs MASTER_PLAN v1.0

| | |
|---|---|
| **Date** | 2026-11-22 |
| **Repository state** | `main` at `9f83491` (one commit, 2026-11-21) |
| **Plan** | `MASTER_PLAN.md` v1.0, 2026-11-01 |
| **Method** | Every RTL, firmware and test file was read against the plan. All three test suites, the Yosys lint target and generic Yosys synthesis were run (see the Appendix). Numbers below are from those runs unless marked otherwise. |

This document does not change any decision. Items that differ from the plan are listed in §5 for the team to accept (as decision entries, per §0 of the plan) or fix.

> **Update 2026-11-23: S3-02, S3-05 and S3-06 are now done.** All are verified from a clean build: assembler 13/13, CPU 21/21, interconnect unit tests 11/11, lint clean, SoC v2 system test and v1 baseline passing.
>
> | Task | What was added |
> |---|---|
> | S3-02 | `sw/asm/tinygpu_asm.py` (assembler + disassembler, 13 tests including an exhaustive round trip). The v2 firmware's kernels are now `soc_v2/fw/kernels/*.s`; the firmware is byte-identical to the hand-coded version. |
> | S3-05 | `docs/spec/bus_obi.md` and `docs/spec/memory_map.md`, frozen v1.0 |
> | S3-06 | `soc_v2/test/unit` (11 tests with a reference model and protocol checkers; 7/7 mutants caught) and the §6 crossbar fix, applied and formally equivalent (13,966 cells) |
>
> The tables below are updated; the rest of the report is as written on 2026-11-22.

---

## 1. Summary

- **The platform chain is largely built, well ahead of schedule.** The OBI crossbar, banked shared SRAM, ITCM/DTCM, command processor, display controller, M extension, precise traps and the CLINT timer are implemented and pass system-level tests. The plan scheduled most of this for S3 weeks 4–9 or for S4. By the §9.1 task sizes that is roughly 15–20 person-weeks of plan work.
- **The critical path has not started.** There is no ISA v2 (S3-04) and no GPU v2 (S3-10). There is also no assembler, simulator or compiler, and no CI, Verilator virtual board, FPGA wrapper or LibreLane run. The GPU is still unmodified tiny-gpu, now behind an OBI wrapper.
- **None of the three final claims can be measured yet.** matadd now takes 184 GPU cycles (v1: 265). The CPU does the same work in 96 cycles (measured on v1), so the GPU is still about 0.5× the CPU. The wrapper and zero-copy memory removed bus overhead. What's left is the tiny-gpu core itself, and only S3-10 changes that.
- **One ordering change:** the command processor was built in front of tiny-gpu, before GPU v2. The plan had v2.0 loading program RAM over MMIO and the CP arriving in v2.1. It is a reasonable choice, but the descriptor and the `cc_*` API are shaped around tiny-gpu and differ from §5.7 and §6.6, so the driver ABI will change when GPU v2 lands.
- **New finding:** the 8×11 crossbar synthesises to about 28.9k generic cells. That is more than the CPU (18.9k) or tiny-gpu (18.0k), and contradicts D-07's "it's small". Half of it comes from how the round-robin loop is written. A 12-line change, proven equivalent, brings it to about 14.0k (§6).

---

## 2. Verified results

| Suite | Result | Detail |
|---|---|---|
| CPU, `rv32i-pipeline/verification` | **21 / 21 pass** | Directed tests, random programs, 40–60 % random bus stalls, CSRs, random interrupts, timer interrupt, MUL/DIV (directed + random), all exception types, external-over-timer priority |
| SoC v2, `soc_v2` → `make test` | **Pass, 7 / 7 firmware tests** | UART boot of 7.8 KB through the crossbar; matadd 184 GPU cycles while the CPU looped 11×; matmul 2×2 500 cycles; 3 queued launches with 1 kernel load; 3 / 3 VGA frames pixel-exact; CP error (code 1) and recovery; exception causes 11 2 4 5 7; 3 timer ticks; 8 launches with 8 completion interrupts; UART-RX interrupt |
| SoC v1 baseline, `soc` → `make test` | **Pass** | Still gives 265 (matadd) and 595 (matmul) GPU cycles, so the Appendix A baseline is reproducible |
| `soc_v2` → `make lint` | **Pass** | Yosys: no latches, `check -assert` clean |

Every result claimed in the root README reproduces. The suites also pass on Ubuntu 24.04's stock Icarus 12 (the plan lists 13-devel), so CI can use distribution packages.

---

## 3. Task status

**Done**: meets the task as written · **Partial**: some of the task's scope exists · **Not started**

### Before Semester 3
| ID | Task | Status | Evidence / gap |
|---|---|---|---|
| S0-1 | Monorepo, commit everything, tag `soc-v1` | Partial | One repo, everything committed and pushed, so R1 (lost work) is resolved. v1 is frozen in `soc/` with its own CPU snapshot (`soc/rtl/cpu_v1/`). **Missing:** the `soc-v1` tag; history is squashed into one commit; layout differs from §15.1; tiny-gpu is an upstream submodule, not a fork |
| S0-2 | CI on every push | Not started | No `.github/` |
| S0-3 | FPGA wrapper for v1 | Not started | No top-level wrapper, XDC or Vivado script |

### Semester 3
| ID | Task | Status | Evidence / gap |
|---|---|---|---|
| S3-01 | FPGA bring-up of v1 | Not started | |
| S3-02 | tiny-gpu assembler | **Done (2026-11-23)** | `sw/asm/tinygpu_asm.py`; firmware kernels in `soc_v2/fw/kernels/*.s`. v1 firmware left frozen; its hand-encoded kernels are part of the assembler's tests |
| S3-03 | Verilator virtual board | Not started | |
| S3-04 | **ISA v2 freeze + `isa_v2.yaml` + generators** | **Not started** | Critical path |
| S3-05 | OBI spec + memory map v2 freeze | **Done (2026-11-23)**: `docs/spec/bus_obi.md`, `docs/spec/memory_map.md` v1.0. Before that: Partial | Implemented in RTL and matches §4.2 and §4.4, except the performance-counter block at `0x4000_6000`. No `docs/spec/bus_obi.md` or `memory_map.md`; the only description is RTL header comments and the README |
| S3-06 | Crossbar + 8 banks + peripheral bridge, unit tests with protocol checkers | **Done (2026-11-23)**: `soc_v2/test/unit`, 11 tests, 7/7 mutants caught. Before that: Partial | RTL done: `obi_xbar.v` (8 masters × 11 slaves, per-slave round-robin, display priority, unmapped → `err`), `obi_sram.v` (word-interleaved on `addr[4:2]`), `periph_bridge.v`. **Missing:** unit tests and protocol checkers; it is verified only through the system test. v1-protocol adapters aren't needed (everything speaks OBI). See §6 for size |
| S3-07 | CPU ITCM / DTCM + OBI master | Done | `cpu_subsys.v`: ITCM port A for fetch, port B on the crossbar; DTCM local with a crossbar port B; non-DTCM data on the OBI master |
| S3-08 | ISA v2 assembler | Not started | Depends on S3-04 |
| S3-09 | ISA v2 functional simulator | Not started | Depends on S3-04 |
| S3-10 | **GPU v2.0 RTL** | **Not started** | Critical path. `gpu_tiny_wrap.v` already gives tiny-gpu 4 OBI ports with a 1-cycle-response handshake on shared memory (zero-copy), which is part of v2.0's goal. 8-bit data, the 16-bit ISA, the FSM core and 2 cores × 4 threads remain |
| S3-11 | RTL ↔ simulator trace comparison | Not started | Depends on S3-09 and S3-10 |
| S3-12 | Driver v1 + HAL + firmware on memory map v2 | Done, mostly | Firmware runs on map v2 and the driver is already asynchronous (`fw/cc.c`), which goes beyond the plan's blocking v1 driver. No separate HAL: register macros live in `soc.h`. No pointer arguments (tiny-gpu has none) |
| S3-13 | Benchmark harness + `bench/results.csv` | Not started | Numbers are printed to the console only |
| S3-14 | LibreLane trial on v1 | Not started | |
| S3-15 | Mandelbrot integration + measurements | Not started | Needs GPU v2.0 |

### Semester 4 (much of the platform half is already built)
| ID | Task | Status | Evidence / gap |
|---|---|---|---|
| S4-01 | GPU v2.1 divergence | Not started | |
| S4-02 | Command processor | Done (tiny-gpu back end) | `gpu_cp.v`: ring buffer, descriptor fetch, kernel load skipped when unchanged, fence written only after all GPU stores are acknowledged (§4.10 rule 1), IRQ, error stop with `ERR_CLR` skip, timeout watchdog with GPU reset. Descriptor and registers differ from §5.7 (see §5.1) |
| S4-03 | CPU M extension | Done | `mdu.v`; `test_mul_div`, `test_random_m_ext`. MUL holds EX for 3 cycles and is not pipelined (§5.3) |
| S4-04 | Traps, `mtval`, CLINT timer, `minstret` | Done | `rv32i_core.v`, `csr_unit.v`, `timer.v`. Exceptions 2/3/4/5/6/7/11 plus misaligned branch/jump target; timer and external interrupts with priority. Tested in both the CPU suite and the firmware |
| S4-05 | Display controller + FPGA VGA + virtual-board frame dump | Partial | `display_ctrl.v` matches §4.7 (RGB332, 2×2, ping-pong line buffers, `FB_BASE` latched at vblank, vsync IRQ, underflow flag) and is checked pixel-exact from the VGA pins in simulation. No FPGA pins/XDC; no frame dump (there is no virtual board) |
| S4-06 | IRQ controller v2, UART FIFOs, performance counters | Partial | `irq_ctrl.v` has PENDING/ENABLE with edge or level sources only (§5.3). The UART is unchanged from v1 (1-byte RX buffer). There is no performance-counter block |
| S4-07 | Compiler v1 | Not started | |
| S4-08 | **GPU v2.2 barrel pipeline** | **Not started** | Critical path |
| S4-09 | Async runtime + cooperative scheduler | Partial | `cc_init / cc_launch / cc_done / cc_wait / cc_irq / cc_clear_error` exist. No `cc_alloc/cc_free`, `cc_on_complete` or `cc_status`, and no scheduler: `cc_wait` spins on the fence word in shared SRAM, which is a crossbar access per poll |
| S4-10 | ASIC_LITE parameter set + LibreLane block runs | Not started | `soc_top` already exposes memory sizes as parameters; no `hw/cfg/` |
| S4-11 | Mandelbrot explorer integration | Not started | |

### Semester 5
Not started; none of it was due yet. Traps, the timer and `ecall` (S4-04) now exist, so S5-03 (FreeRTOS) has its hardware prerequisites.

### S3 midsem checkpoint (plan ≈ week 7)
| Checkpoint item | State |
|---|---|
| v1 live on FPGA | No |
| ISA v2 frozen | No |
| OBI + memory map frozen | Yes (2026-11-23): v1.0 specs |
| Crossbar unit tests passing | Yes (2026-11-23): 11 unit tests |
| v2 assembler working | ISA v2 not defined yet; the tiny-gpu assembler (S3-02) works |
| Virtual board running v1 firmware | No |

---

## 4. Success criteria (§2.3)

| Claim | Target | Today |
|---|---|---|
| GPU accelerates: Mandelbrot | ≥ 5× CPU | Not measurable: no Mandelbrot kernel, and tiny-gpu's 8-bit datapath can't run one |
| GPU accelerates: matmul | ≥ 2× CPU | No CPU baseline yet; GPU 2×2 = 500 cycles. On matadd the GPU is ~0.52× the CPU (184 vs 96 cycles) |
| Concurrent | < 10 % CPU slowdown | Not measured. The evidence so far is a spin counter (11 iterations during a 184-cycle kernel), not a CPU benchmark's slowdown |
| Scales 1 → 4 cores | ≥ 3× | Not measurable: the wrapper fixes tiny-gpu at 2 cores |
| Programmable | within 1.5× of hand assembly | No compiler |
| FPGA clock | ≥ 50 MHz | Never synthesised in Vivado |
| GDS | DRC/LVS clean, timing met | No flow run |
| Quality | CI green | No CI; all suites pass locally (§2) |

---

## 5. Deviations from the plan

### 5.1 Command processor built before GPU v2. Action: record as a decision.
- **Plan:** GPU v2.0 loads program RAM via MMIO; the CP comes in v2.1 (S4-02).
- **Built:** the CP in front of tiny-gpu, now.
- **Descriptor differences from §5.7:** word 2 is `threads` (plan: `grid_x | grid_y`); word 3 is `data_base` (plan: `block_threads`); word 4 `arg_ptr` is reserved and unused; flag bit 2 is `byte mode`.
- **Register differences:** `CTRL` has only ENABLE (plan: enable, reset, irq_en). It adds `KCYCLES`, `ERR_CLR`, `LAUNCHES` and `LOADS`. Its error codes (bad descriptor, timeout, CP bus error, GPU bus error) are a tiny-gpu subset of §5.8.
- **Recommendation:** accept the reorder. Write the current layout down as driver ABI **v0 (tiny-gpu)** in `docs/spec/driver_abi.md`. Freeze **v1** (grid, block, args) together with ISA v2, so the CP change is planned rather than discovered.

### 5.2 Runtime API differs from §6.6. Action: none until GPU v2.
`cc_launch(kernel, threads, data, flags)` replaces `cc_launch(kernel, grid_x, grid_y, block_threads, args, args_size)`. That follows from tiny-gpu. Missing pieces are listed under S4-09.

### 5.3 Simplified blocks. Action: update the plan text or keep them on the S4-06 list.
- **Interrupt controller:** PENDING/ENABLE only, 4 sources (CP fence, CP error, vsync, UART RX). §4.8 specifies PRIORITY, CLAIM/COMPLETE and GPIO and perf-overflow sources.
- **MUL:** holds EX for 3 cycles, not 2-cycle pipelined; DIV takes about 35 cycles, not about 33. The effect is small, so updating §4.3 is enough.
- **Still owed:** UART FIFOs; the performance-counter block (partly covered by CP `KCYCLES/LAUNCHES/LOADS` and CPU `mcycle/minstret`); the runtime debug bridge (D-27): the boot loader holds the CPU in reset while active, so it can't peek or poke a running system.

### 5.4 Process. Action: S0 tasks.
- One squashed commit, no `soc-v1` tag (D-41), no CI (D-34).
- The repository layout doesn't follow §15.1 (`rv32i-pipeline/`, `soc/`, `soc_v2/` instead of `hw/`, `sw/`, `verif/`).
- §0 says the three specs in `docs/spec/` are authoritative, but none exist yet.

---

## 6. Crossbar size (affects D-07, R4, G5)

Generic gate counts from Yosys 0.33 `synth -flatten`. The method was calibrated against Appendix A: the v1 CPU gives 8,617 cells here vs 8,646 there.

| Block | Generic cells |
|---|---|
| CPU v1 (calibration) | 8,617 |
| CPU v2 (RV32IM, traps, counters; includes a 33×33 multiplier, which maps to DSP slices on the FPGA) | 18,939 |
| tiny-gpu (2 cores × 4 threads, 4 data channels) | 17,960 |
| **`obi_xbar` 8×11, as committed** | **28,879** |
| `obi_xbar` 8×11, arbiter rewritten (patch below) | 13,960 |
| `gpu_cp` | 3,058 |

**Cause.** The round-robin loop indexes `m_req[ai]` and `hit[ai*NS+as_]` with a 32-bit `integer ai`. Unrolled over 11 slaves × 8 masters, that builds 88 wide adders and variable shifters over the 88-bit `hit` vector.

**Fix.** Build each slave's request vector with constant indices, and keep the rotating index MW+1 bits wide. The fix works for any `NM`, which matters because the scaling study changes NM = 4 + P.
- Yosys `equiv_make` / `equiv_induct` proves it equivalent to the committed RTL (3,528 of 3,528 equivalence points).
- The SoC v2 system test also passes with it (run on a scratch copy).
- It is **not applied** to the repo. *(Applied 2026-11-23, with default assignments added so Yosys infers no latches; equivalence re-proven, 13,966 cells.)*

```diff
--- a/soc_v2/rtl/obi_xbar.v
+++ b/soc_v2/rtl/obi_xbar.v
@@ -71,6 +71,8 @@
     reg [NS*MW-1:0] win;
     reg [NS-1:0]    any;
+    reg [NM-1:0]    rq;
+    reg [MW:0]      ai3;
     always @(*) begin
@@ -81,12 +83,14 @@
             end else begin
+                for (ak = 0; ak < NM; ak = ak + 1)
+                    rq[ak] = m_req[ak] & hit[ak*NS+as_];       // static indices
                 for (ak = 1; ak <= NM; ak = ak + 1) begin
-                    ai = last[as_*MW +: MW] + ak;
-                    if (ai >= NM) ai = ai - NM;
-                    if (!any[as_] && m_req[ai] && hit[ai*NS+as_]) begin
+                    ai3 = {1'b0, last[as_*MW +: MW]} + ak[MW:0];   // narrow, any NM
+                    if (ai3 >= NM) ai3 = ai3 - NM;
+                    if (!any[as_] && rq[ai3[MW-1:0]]) begin
                         any[as_] = 1'b1;
-                        win[as_*MW +: MW] = ai;
+                        win[as_*MW +: MW] = ai3[MW-1:0];
                     end
```

Even at about 14k cells the crossbar is as large as the CPU. Its request path is combinational end to end (CPU EX address → slave decode → arbitration → `gnt` → pipeline freeze), which is exactly the path R4 suspects. A Vivado timing number (S0-3) should come before more is built on it.

---

## 7. Documentation drift

- **`rv32i-pipeline/README.md`** still describes the old core: "RV32I", "16/16 pass", ECALL/EBREAK executing as NOPs, and a CSR list without `mtval` or `minstret`. The core is now RV32IM with precise traps and 21 tests.
- **`MASTER_PLAN.md`** §1, §3, D-02, R1 and Appendix B describe the end-of-Semester-2 baseline: untracked `soc/`, uncommitted CPU, 16 tests. That is correct as a historical baseline. Add a pointer to this document rather than rewriting those sections.
- **Undeclared dependency:** `soc_v2/Makefile` and `soc/Makefile` call `llvm-objdump` for the firmware listing, but the README's requirements don't list it.

---

## 8. Recommended next steps (in order)

1. **Start S3-04 now.** Everything GPU- and software-side waits on the ISA v2 freeze. The plan says "protect S3-10 and S4-08 above everything else", and both are still at zero.
2. **Move freed capacity to the critical path.** Much of the platform lead's S3/S4 work is done. Put that time into S3-10 (L) and S4-07 (L), not into the remaining peripheral polish (FIFOs, perf counters, IRQ priority), which is should-have.
3. **Close S0.**
   - Tag `soc-v1` at `9f83491`.
   - Add CI. Everything needed is stock Ubuntu 24.04 packages plus the sv2v release binary and pip cocotb. The full suite took about 3 minutes of simulation here: CPU 15 s, v1 30 s, v2 146 s.
4. **Write the three specs from the RTL (S3-05).** The memory map and OBI rules are de facto frozen already. Version the CP descriptor as v0 and plan v1 alongside ISA v2 (§5.1).
5. **Apply the crossbar fix, then get real timing** (S0-3, then S3-14) before relying on 50 MHz.
6. **Record §5.1 and §5.3 as decision entries** through the §0 change process.
7. **Measure concurrency properly.** S3 exit criterion 3 needs a CPU benchmark's slowdown while the GPU runs, not a spin count.

---

## Appendix: how this was verified

| Tool | Version | Source |
|---|---|---|
| Icarus Verilog | 12.0 | Ubuntu 24.04 package |
| Yosys + yosys-abc | 0.33 | Ubuntu 24.04 packages |
| clang / ld.lld | 18.1.3 | Ubuntu 24.04 packages |
| sv2v | 0.0.12 | GitHub release binary |
| cocotb | 2.0.1 | pip |
| Python | 3.12 | |

```bash
git submodule update --init
make -C rv32i-pipeline/verification                 # 21 CPU tests
make -C soc test OBJDUMP=true                       # v1 baseline
make -C soc_v2 test OBJDUMP=true && make -C soc_v2 lint
# gate counts, per block:
yosys -p "read_verilog <files>; synth -flatten -top <module>; stat"
```

`OBJDUMP=true` skips the firmware listing because `llvm-objdump` wasn't installed (§7).
