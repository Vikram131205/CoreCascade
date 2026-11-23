# CoreCascade SoC v2 memory map and registers

| | |
|---|---|
| **Version** | 1.0, frozen 2026-11-23 |
| **Describes** | `soc_v2/rtl/soc_top.v` and the blocks it instantiates; sizes are the FPGA_FULL defaults |
| **Bus** | [`bus_obi.md`](bus_obi.md) |
| **Single source** | Crossbar decode table: `soc_v2/rtl/soc_map.vh`. Firmware register names: `soc_v2/fw/soc.h` |
| **Changing it** | MASTER_PLAN §0: a proposal that edits this file, agreed by all three members, in the same PR as the RTL |

---

## 1. Address map

| Address | Region | Size | Crossbar slave | Notes |
|---|---|---|---|---|
| `0x0000_0000` – `0x0000_7FFF` | **ITCM**: CPU code and constants | 32 KB | 0 (port B) | The CPU fetches through its private port A. Port B serves the boot loader and the CPU's constant reads. Repeats every 32 KB up to `0x0FFF_FFFF`. |
| `0x1000_0000` – `0x1000_3FFF` | **DTCM**: CPU data and stack | 16 KB | 1 (port B) | The CPU accesses it locally, never through the crossbar. A CPU access to `0x1000_4000`–`0x1FFF_FFFF` raises an access fault. Through the crossbar (boot loader) it repeats every 16 KB. |
| `0x2000_0000` – `0x2003_FFFF` | **Shared SRAM**: GPU data, kernels, command ring, framebuffers | 256 KB (8 × 32 KB) | 2–9 | Word-interleaved over 8 banks (§2). Repeats every 256 KB up to `0x2FFF_FFFF`. |
| `0x4000_0000` – `0x4000_5FFF` | **Peripherals** | 6 × 4 KB | 10 (bridge) | §4. Bits `[27:16]` are ignored, so the blocks repeat every 64 KB. Offsets `0x6000`–`0xFFFF` answer `err`. |
| `0x3xxx_xxxx`, `0x5xxx_xxxx`–`0xFxxx_xxxx` | unmapped | — | none | The crossbar answers `err`. The CPU takes a load (5) or store (7) access fault; the GPU and command processor report a bus error. |

### Decode table (`soc_map.vh`)

| Slave | `SLV_BASE` | `SLV_MASK` |
|---|---|---|
| 0 ITCM | `0x0000_0000` | `0xF000_0000` |
| 1 DTCM | `0x1000_0000` | `0xF000_0000` |
| 2 + *b*, bank *b* (0–7) | `0x2000_0000 + 4b` | `0xF000_001C` |
| 10 peripherals | `0x4000_0000` | `0xF000_0000` |

## 2. Shared SRAM interleaving

Consecutive 32-bit words go to consecutive banks:

```
bank = addr[4:2]          row inside the bank = addr[17:5]   (8,192 rows of 32 bits)

word address   0x2000_0000  _0004  _0008  _000C  _0010  _0014  _0018  _001C  _0020  ...
bank                0        1      2      3      4      5      6      7      0     ...
row                 0        0      0      0      0      0      0      0      1     ...
```

GPU threads that read `a[i], a[i+1], …` and a display line fetch both spread over all eight banks, so up to eight masters move data in the same cycle (measured: 7.8–8 words per cycle, see the bus spec).

## 3. Software layout (`soc_v2/fw/link.ld`)

| Section | Region | Contents |
|---|---|---|
| `.text`, `.rodata` | ITCM | Code; constants (read by the CPU through the crossbar) |
| `.data`, `.bss`, stack | DTCM | CPU-private variables. The stack grows down from `0x1000_4000`. |
| `.gpu` | Shared SRAM, from `0x2000_0000` | GPU kernel binaries (`build/kernels.h`, assembled from `fw/kernels/*.s`) |
| `.shared` (not loaded) | Shared SRAM, after `.gpu` | Command ring, fence word, GPU data windows, framebuffers |

## 4. Peripherals

Block *i* is at `0x4000_0000 + i × 0x1000`. These rules hold for every block:
- **Width:** registers are 32 bits; byte enables are ignored, so always use 32-bit accesses.
- **Unlisted offsets:** inside the decoded range, an unlisted offset reads 0 and ignores writes.
- **Aliasing:** a block decodes only the address bits shown in its heading, so its registers repeat beyond that range.
- **Latency:** a register read returns in the cycle after the grant.

| # | Base | Block | RTL |
|---|---|---|---|
| 0 | `0x4000_0000` | System control | `sysctl.v` |
| 1 | `0x4000_1000` | UART (console) | `uart_periph.v` |
| 2 | `0x4000_2000` | Machine timer (CLINT-style) | `timer.v` |
| 3 | `0x4000_3000` | Interrupt controller | `irq_ctrl.v` |
| 4 | `0x4000_4000` | GPU command processor | `gpu_cp.v` |
| 5 | `0x4000_5000` | Display controller | `display_ctrl.v` |

### 4.0 System control, `0x4000_0000` (decodes `addr[4:2]`)

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x00` | `GPIO_OUT` | RW | 0 | `[7:0]` drive the `gpio_o` pins |
| `0x04` | `EXIT` | W / R | 0 | Write: raise the `halted_o` pin and keep the value as the exit code. Read: the exit code |
| `0x08` | `GPIO_IN` | R | — | `[7:0]` the `gpio_i` pins, through a two-flop synchroniser |
| `0x0C` | `SCRATCH` | RW | 0 | Free for software |
| `0x10` | `CHIP_ID` | R | `0xCC50_0002` | CoreCascade SoC v2 |

### 4.1 UART, `0x4000_1000` (decodes `addr[3:2]`)

8N1, `UART_DIV` clock cycles per bit (434 at 50 MHz = 115,200 baud). While the boot loader is active it owns the UART pins, and the console ignores received bytes.

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x0` | `DATA` | W | Send `[7:0]`. While the transmitter is busy, the write waits on the bus (`gnt` low), so firmware never polls. |
| `0x0` | `DATA` | R | `{23'b0, valid, byte}`: the received byte with its valid bit. The read empties the 1-byte receive buffer and clears `RX_OVERRUN`. |
| `0x4` | `STATUS` | R | bit 0 `TX_BUSY`, bit 1 `RX_VALID`, bit 2 `RX_OVERRUN` (a byte arrived before the previous one was read). Offsets `0x8` and `0xC` also read `STATUS`. |

`RX_VALID` is interrupt source 3 (level).

### 4.2 Machine timer, `0x4000_2000` (decodes `addr[3:2]`)

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x0` | `MTIME_LO` | RW | 0 | `mtime[31:0]`. `mtime` counts every clock cycle; a write replaces that half and the other half keeps counting. |
| `0x4` | `MTIME_HI` | RW | 0 | `mtime[63:32]` |
| `0x8` | `MTIMECMP_LO` | RW | `0xFFFF_FFFF` | `mtimecmp[31:0]` |
| `0xC` | `MTIMECMP_HI` | RW | `0xFFFF_FFFF` | `mtimecmp[63:32]` |

The machine timer interrupt `mip.MTIP` is `mtime ≥ mtimecmp` (64-bit unsigned). To avoid a spurious match while updating, write `MTIMECMP_HI = 0xFFFF_FFFF` first, then `MTIMECMP_LO`, then the real `MTIMECMP_HI`.

### 4.3 Interrupt controller, `0x4000_3000` (decodes `addr[3:2]`)

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x0` | `PENDING` | R / W1C | 0 | Read: pending sources. Write 1 to clear an edge source. A new edge in the same cycle wins over the clear. Level sources show the live input. |
| `0x4` | `ENABLE` | RW | 0 | Per-source enable |

`mip.MEIP` (machine external interrupt) is `|(PENDING & ENABLE)`.

| Source | Event | Type |
|---|---|---|
| 0 | Command processor wrote a fence (if the descriptor asked for an interrupt) | edge |
| 1 | Command processor entered the error state | edge |
| 2 | Display: start of vertical blanking (vsync) | edge |
| 3 | UART: received byte waiting | level |
| 4–7 | not connected (read 0) | — |

### 4.4 GPU command processor, `0x4000_4000` (decodes `addr[5:2]`)

The CPU writes 32-byte launch descriptors into a ring in shared SRAM and advances `Q_TAIL`. The command processor runs them in order without the CPU:
1. fetch the descriptor;
2. load the kernel, skipped if it is already loaded;
3. run the GPU;
4. wait until every GPU store has been acknowledged;
5. write the fence;
6. raise the interrupt if the descriptor asks for one;
7. advance `Q_HEAD`.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x00` | `CTRL` | RW | 0 | bit 0 `ENABLE`: process the queue |
| `0x04` | `Q_BASE` | RW | 0 | Ring base address in shared SRAM, 32-byte aligned |
| `0x08` | `Q_SIZE` | RW | 1 | Ring entries. **Must be a power of two** (not checked). |
| `0x0C` | `Q_HEAD` | R | 0 | Descriptors consumed (free-running) |
| `0x10` | `Q_TAIL` | RW | 0 | Descriptors queued (free-running). Software writes it after the descriptor is complete. |
| `0x14` | `STATUS` | R | 0 | bit 0 busy (not idle, including the error state), bit 1 error, `[7:4]` error code, `[31:16]` `Q_HEAD[15:0]` (the failing descriptor while in error) |
| `0x18` | `TIMEOUT` | RW | 0 | Watchdog per launch, in cycles (0 = off) |
| `0x1C` | `LAST_FENCE` | R | 0 | Fence value of the last completed launch |
| `0x20` | `KCYCLES` | R | 0 | Cycles the last kernel ran |
| `0x24` | `ERR_CLR` | W | — | In the error state: clear the error, skip the failing descriptor (`Q_HEAD + 1`) and resume |
| `0x28` | `LAUNCHES` | R | 0 | Completed launches |
| `0x2C` | `LOADS` | R | 0 | Kernel loads performed (repeated kernels are not reloaded) |

Change `Q_BASE` and `Q_SIZE` only while the queue is empty and the processor is idle.

**Descriptor (driver ABI v0, tiny-gpu back end).** Slot `Q_BASE + (Q_HEAD mod Q_SIZE) × 32`:

| Word | Field | Description |
|---|---|---|
| 0 | `kernel_addr` | Kernel image: `kernel_words` 32-bit words, each holding one 16-bit instruction in `[15:0]` |
| 1 | `kernel_words` | 1–256 |
| 2 | `threads` | 1–255 |
| 3 | `data_base` | Base of the GPU's data window (below) |
| 4 | `arg_ptr` | Reserved for GPU v2 |
| 5 | `fence_addr` | Where the fence is written |
| 6 | `fence_value` | Value written there on completion |
| 7 | `flags` | bit 0 interrupt on completion, bit 1 force kernel reload, bit 2 byte mode |

**GPU data window.** tiny-gpu addresses 0–255 map into shared SRAM:

| Mode | GPU address *a* → | Load returns | Store writes |
|---|---|---|---|
| Word (flag bit 2 = 0) | `data_base + 4a` | bits `[7:0]` of the word | the full word `{24'b0, value}` |
| Byte (flag bit 2 = 1) | `data_base + a` | the addressed byte | that byte only |

**Errors.** A descriptor that fails stops the queue, sets `STATUS.error` and the code, holds the GPU in reset, and raises interrupt source 1.

| Code | Meaning |
|---|---|
| 1 | Bad descriptor (`kernel_words` or `threads` out of range) |
| 2 | Timeout (`KCYCLES ≥ TIMEOUT`) |
| 3 | Bus error on a descriptor or kernel fetch, or on the fence write |
| 4 | Bus error on a GPU data access |

### 4.5 Display controller, `0x4000_5000` (decodes `addr[3:2]`)

640×480 at 60 Hz from a 25 MHz pixel enable (50 MHz system clock). The framebuffer is `FB_W × FB_H` (320 × 240) bytes in shared SRAM, row-major, one RGB332 byte per pixel (`[7:5]` red, `[4:2]` green, `[1:0]` blue). Every pixel is shown 2 × 2.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x0` | `CTRL` | RW | 0 | bit 0 `ENABLE` (fetch and show; black when off) |
| `0x4` | `FB_BASE` | RW | 0 | Next framebuffer, 4-byte aligned. It takes effect at the next vertical blanking, so a page flip never tears. |
| `0x8` | `STATUS` | R | 0 | `[15:0]` frame counter, bit 30 underflow (sticky until reset), bit 31 in vertical blanking |
| `0xC` | `FB_CUR` | R | 0 | The framebuffer being shown |

Output: 4-4-4 VGA. Red `{R[2:0], R[2]}`, green `{G[2:0], G[2]}`, blue `{B[1:0], B[1:0]}`. Source line *y* is fetched into a line buffer during the line before it; line 0 is fetched during vertical blanking.

## 5. Interrupts into the CPU

| `mcause` | Source | Priority |
|---|---|---|
| `0x8000_000B` (machine external, `MEIP`) | Interrupt controller (§4.3) | Higher |
| `0x8000_0007` (machine timer, `MTIP`) | Timer (§4.2) | Lower |

Enable with `mie.MEIE` / `mie.MTIE` and `mstatus.MIE`. Synchronous exceptions:

| Cause | Exception |
|---|---|
| 2 | Illegal instruction |
| 3 | Breakpoint |
| 4 / 6 | Misaligned load / store |
| 5 / 7 | Load / store access fault |
| 11 | ecall |
| 0 | Misaligned branch or jump target |

## 6. Pins, clock, reset and boot (`soc_top`)

| Pin | Dir | Width | Function |
|---|---|---|---|
| `clk_i` | in | 1 | System clock, 50 MHz target |
| `rst_ni` | in | 1 | Reset, active low. Asserts asynchronously; a two-flop synchroniser releases it on a clock edge. Internal resets are synchronous, active high. |
| `boot_i` | in | 1 | Boot strap. 1: after reset the CPU is held and the UART boot loader waits for a program. 0: the CPU starts from pre-loaded memories. |
| `uart_rx_i` / `uart_tx_o` | in / out | 1 / 1 | Boot loader while booting, console afterwards |
| `gpio_i` / `gpio_o` | in / out | 8 / 8 | General-purpose I/O |
| `halted_o` | out | 1 | Firmware wrote `EXIT` |
| `vga_rgb_o` | out | 12 | 4-4-4 colour |
| `vga_hs_o`, `vga_vs_o` | out | 1 / 1 | Sync, active low |

**UART boot protocol** (`uart_boot.v`, 8N1, little-endian fields):

| Command | Bytes | Reply |
|---|---|---|
| Write | `'W'` `addr[4]` `count[2]` `data[4 × count]` | `'K'` after the last word is written |
| Read | `'R'` `addr[4]` `count[2]` | `4 × count` data bytes |
| Go | `'G'` | `'K'`. The CPU leaves reset and starts at `0x0000_0000`. |

Addresses are bus addresses: the loader reaches ITCM and DTCM through their crossbar ports, as well as shared SRAM and the registers. `soc/tools/uart_load.py` is the host side.

**Parameters** (`soc_top`): `ITCM_WORDS = 8192`, `DTCM_WORDS = 4096`, `BANK_WORDS = 8192`, `UART_DIV = 434`, `GPIO_W = 8`, `FB_W = 320`, `FB_H = 240`, plus the VGA porch and sync widths. The simulation shrinks the display to 16 × 16 and the UART to 8 cycles per bit (`soc_v2/test/Makefile`).

## 7. Differences from MASTER_PLAN §4.2 / §4.8

| Plan | v1.0 | Status |
|---|---|---|
| Performance-counter block at `0x4000_6000` | Not present; `0x4000_6000` answers `err`. Partly covered by CP `KCYCLES`/`LAUNCHES`/`LOADS` and the CPU's `mcycle`/`minstret`. | Planned |
| Interrupt controller with PRIORITY and CLAIM/COMPLETE; GPIO and counter-overflow sources | PENDING/ENABLE, 4 sources | Planned |
| UART with 16-byte FIFOs and a TX-threshold interrupt | 1-byte receive buffer, TX back-pressure through `gnt` | Planned |
| Descriptor: `grid_x | grid_y`, `block_threads`, `arg_ptr` | Driver ABI v0 for tiny-gpu: `threads`, `data_base`; `arg_ptr` reserved | v1 with GPU v2 |
| Boot/debug bridge usable at run time | Boot only (the CPU is held in reset while it is active) | Planned |

## 8. Changelog

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-11-23 | First frozen version, written from the RTL |
