# CoreCascade

A heterogeneous **RISC-V CPU + GPU system-on-chip**: an RV32IM 5-stage pipelined CPU and the
[tiny-gpu](https://github.com/adam-maj/tiny-gpu) SIMT core share memory over an OBI crossbar.
The CPU keeps working while the GPU runs kernels, and a VGA display controller scans out a framebuffer.

Capstone project: **Vikram Singh, Rushil Jain, Jainam Sonigara**. Guide: **Dr. Sumam David**.
Targets: FPGA (Nexys 4 DDR) as the main platform, and a sky130 GDS (OpenLane) of a reduced configuration.

## Repository layout

| Path | What it is |
|---|---|
| `rv32i-pipeline/` | RV32IM 5-stage pipelined CPU with precise traps, CSRs, timer/external interrupts, an iterative MUL/DIV unit and an OBI data port. `verification/` holds 21 cocotb tests against a Python ISS. |
| `soc_v2/` | **Current SoC.** CPU with private ITCM/DTCM, an 8-master × 11-slave OBI crossbar, 8-bank interleaved shared SRAM, a GPU command processor (ring buffer, fences, IRQs) in front of unmodified tiny-gpu, a VGA display controller, an interrupt controller, a timer, UART boot and a console. |
| `soc/` | SoC v1 (frozen baseline): CPU + tiny-gpu + shared memory, UART boot. The CPU snapshot it uses is in `soc/rtl/cpu_v1/`. |
| `tiny-gpu/` | Upstream tiny-gpu as a git submodule, **used unmodified**. |
| `MASTER_PLAN.md` | Architecture, decision log (with rejected alternatives) and the 3-semester roadmap. |

## SoC v2 at a glance

```
 masters: CPU · UART boot · GPU ch0-3 · command processor · display
                      │ OBI (req/gnt → rvalid/rdata/err)
              ┌───────┴────────┐
              │  OBI crossbar  │  per-slave round-robin, display priority
              └───────┬────────┘
 slaves:  ITCM · DTCM · 8 shared-SRAM banks (addr[4:2]) · peripherals
          (sysctl, UART, timer, irq_ctrl, command processor, display)
```

- **Launch path:** the CPU writes an 8-word descriptor into a ring buffer in shared SRAM and bumps `Q_TAIL`.
  The command processor fetches it, loads the kernel (skipped if it is already loaded), runs the GPU,
  waits until every store has drained, writes the fence and raises an interrupt. The CPU never polls the GPU.
- **Interrupts:** CP fence, CP error and vsync (edge, write 1 to clear), UART RX (level) → `irq_ctrl` → MEIP;
  a CLINT-style timer → MTIP.

## Results (simulation)

| | v1 | v2 |
|---|---|---|
| 8-element matadd (GPU cycles) | 265 | 184 |
| 2×2 matmul (GPU cycles) | 595 | 500 |
| CPU busy during the kernel | no (polls) | yes (looped 11× in the test) |

The v2 system test boots firmware over UART and runs 7 firmware tests: concurrent matadd, matmul,
queued launches, GPU → framebuffer → VGA (3 frames checked pixel-for-pixel), CP error and recovery,
exceptions, and the timer. It passes, and the CPU's 21 tests pass.

## Running

Requirements: Icarus Verilog, cocotb 2.x, sv2v, clang + ld.lld (RISC-V target), and optionally Yosys.

```bash
git clone --recursive https://github.com/Vikram131205/CoreCascade.git
cd CoreCascade/rv32i-pipeline/verification && make   # CPU tests
cd ../../soc_v2 && make test                         # SoC v2: firmware + GPU kernels + system test
```

## Status

Done: CPU v2, OBI interconnect, memories, command processor, display controller, interrupts, system test.
Next: FPGA top level and constraints, UART FIFOs, performance counters, runtime debug bridge,
GPU v2 (32-bit, pipelined), and OpenLane GDS. See `MASTER_PLAN.md`.
