# CoreCascade SoC: RV32I host CPU + tiny-gpu

A single compute chip: an RV32I 5-stage pipelined CPU (`../rv32i-pipeline`)
acts as the host for tiny-gpu (`../tiny-gpu`, used unmodified). They share
on-chip SRAM through one valid/grant bus. The chip boots over UART and
interrupts the CPU when a GPU kernel finishes.

```
      uart_rx ──┬──────────────────────────────┐
                ▼                              ▼
          uart_boot (FSM)                 rv32i_core ◄── irq ── sysctl (IRQ ctl)
           bus master #0                  bus master #1
           (only while boot)            imem port │ dmem port
                │                            │    │
                └──────── master mux ────────┼────┘
                               │             │
                   address decoder / response mux
    ┌─────────┬─────────┬──────┴────┬──────────┬──────────┬──────────┐
  IMEM      DMEM     GPU mems     GPU ctrl    SYSCTL      UART
  4 KB      4 KB   prog 256x16    CTRL/DCR/   GPIO/EXIT/   DATA/
                   data 256x8     STATUS/     IRQ_EN/      STATUS
                        ▲         CYCLES      IRQ_PEND
                   tiny-gpu (2 cores x 4 threads; wins memory conflicts)
```

## Pins

| Pin | Dir | Function |
|---|---|---|
| `clk`, `reset` | in | clock, synchronous active-high reset |
| `boot` | in | strap: 1 = wait for a program on the UART after reset |
| `uart_rx`, `uart_tx` | in/out | boot loader, then CPU console (8N1, `UART_DIV` clocks/bit) |
| `gpio_in[7:0]`, `gpio_out[7:0]` | in/out | general-purpose I/O |
| `halted` | out | firmware wrote the EXIT register |

## Memory map

| Address | Region | Registers / notes |
|---|---|---|
| `0x0000_0000` | IMEM | CPU code; written by the boot loader |
| `0x1000_0000` | DMEM | `.rodata/.data/.bss/stack` |
| `0x2000_0000` | GPU data | 256 bytes, one byte per address (`SB`/`LBU`) |
| `0x2000_1000` | GPU program | 256 x 16-bit, one instruction per 32-bit word |
| `0x3000_0000` | GPU ctrl | `+0` CTRL (b0 START, b1 RESET), `+4` DCR (threads), `+8` STATUS (b0 DONE, b1 BUSY), `+C` CYCLES |
| `0x4000_0000` | SYSCTL | `+0` GPIO_OUT, `+4` EXIT, `+8` IRQ_EN, `+C` IRQ_PEND (b0 GPU done W1C, b1 UART RX), `+10` GPIO_IN |
| `0x4000_1000` | UART | `+0` DATA (write = send, bus waits while busy; read = pop RX), `+4` STATUS |

**CPU:** RV32I, plus Zicsr and machine-mode interrupts (`mstatus`, `mie`,
`mip`, `mtvec`, `mepc`, `mcause`, `mscratch`, `mcycle`, `MRET`).

**Boot protocol** (`rtl/uart_boot.v`):
- `'W' addr[4] count[2] data[4*count]` writes words; the loader replies `K`.
- `'R' addr[4] count[2]` reads words back.
- `'G'` replies `K` and releases the CPU.

All fields are little-endian.

## Files

| Path | What |
|---|---|
| `rtl/soc_top.v` | top level: master mux, decoder, memories, peripherals |
| `rtl/gpu_subsys.v` | tiny-gpu + program/data SRAM + control registers + arbitration |
| `rtl/uart_boot.v` | hardware UART boot loader (bus master) |
| `rtl/uart_periph.v`, `uart_tx.v`, `uart_rx.v` | UART |
| `rtl/sysctl.v` | GPIO, EXIT, interrupt controller |
| `fw/` | C firmware (`main.c`), drivers (`soc.h`), startup, linker script |
| `test/test_soc.py` | cocotb: boots over UART, runs kernels, checks everything |
| `tools/uart_load.py` | load firmware on real hardware over a serial port |

## Run (WSL: sv2v, clang + ld.lld, iverilog, cocotb)

```bash
make        # sv2v tiny-gpu -> build/gpu.v, build firmware, simulate
make lint   # yosys elaboration + structural checks
```
