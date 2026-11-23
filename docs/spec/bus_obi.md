# CoreCascade on-chip bus (OBI subset)

| | |
|---|---|
| **Version** | 1.0, frozen 2026-11-23 |
| **Describes** | `soc_v2/rtl/obi_xbar.v`, `periph_bridge.v`, `obi_sram.v`, `cpu_subsys.v` and every master in `soc_top.v` |
| **Address map** | [`memory_map.md`](memory_map.md) |
| **Tests** | `soc_v2/test/unit` (`make -C soc_v2 unit`) and the system test (`make -C soc_v2 test`) |
| **Changing it** | MASTER_PLAN §0: a proposal that edits this file, agreed by all three members, in the same PR as the RTL |

Every block in the SoC that moves data uses one protocol: a subset of the OpenHW Group **Open Bus Interface (OBI)**. It is the protocol the CPU core already spoke in v1 (request/grant), plus a response phase (`rvalid`, `err`) so slaves can take more than one cycle. Decision D-06 in MASTER_PLAN records why OBI rather than AXI, Wishbone or TileLink.

---

## 1. Signals

| Signal | Width | Driven by | Meaning |
|---|---|---|---|
| `req` | 1 | master | A request is presented this cycle |
| `addr` | 32 | master | Byte address |
| `we` | 1 | master | 1 = write, 0 = read |
| `be` | 4 | master | Byte enables: `be[i]` selects byte lane `wdata[8i+7:8i]` |
| `wdata` | 32 | master | Write data, in the lanes selected by `be` |
| `gnt` | 1 | slave | The request is accepted this cycle |
| `rvalid` | 1 | slave | The response is valid this cycle |
| `rdata` | 32 | slave | Read data (reads only) |
| `err` | 1 | slave | The access failed (valid with `rvalid`) |

There is no `rready`, no transaction ID, no burst, no lock and no cache attribute.

## 2. Rules

1. **Handshake.** A request is accepted at the clock edge that ends a cycle in which `req` and `gnt` are both 1.
2. **Stable request.** Once a master raises `req`, it keeps `req`, `addr`, `we`, `be` and `wdata` unchanged until the cycle of `gnt`.
3. **One response per request.** Every accepted request, read or write, gets exactly one cycle with `rvalid = 1`, at least one cycle after the handshake. `err = 1` in that cycle means the access failed.
4. **One outstanding transaction per master.** After a handshake a master raises `req` again no earlier than the cycle its `rvalid` arrives (that same cycle is allowed). Responses therefore return in order, and no IDs are needed.
5. **Masters always accept responses.** A master cannot stall `rvalid`.
6. **Write responses carry no data.** `rdata` with a write response is meaningless, and in simulation it can be X.
7. **Alignment.** Addresses are byte addresses. A 32-bit access must be word-aligned; a 16-bit access must be halfword-aligned. The master puts write data in the byte lanes of the target bytes, e.g. a byte store to `addr[1:0] = 2` uses `wdata[23:16]` and `be = 4'b0100`. Slaves ignore `addr[1:0]`. The CPU raises a misaligned-access trap before an access reaches the bus.
8. **No combinational loop.** A slave may compute `gnt` combinationally from the request in the same cycle (every slave here does). A master must not compute `req` combinationally from `gnt`.

### Timing

```
cycle        0      1      2      3      4      5
req        __/‾‾‾‾‾‾‾‾‾‾‾‾‾‾\__/‾‾‾‾‾‾\__________       read A waits one cycle for gnt,
gnt        _______/‾‾‾‾‾‾\______/‾‾‾‾‾‾\__________       is accepted in cycle 1;
addr       --<  A  >--------<  B  >---------------       read B is issued in the cycle
rvalid     ______________/‾‾‾‾‾‾\______/‾‾‾‾‾‾\___       A's response returns (rule 4)
rdata      --------------< D(A) >------< D(B) >---
```

## 3. Crossbar (`obi_xbar.v`)

`NM` masters × `NS` slaves (8 × 11 in the SoC). Transfers between different master/slave pairs happen **in the same cycle**, so the CPU, the four GPU channels, the command processor and the display proceed in parallel as long as they use different slaves.

- **Decode.** Master *m* hits slave *s* when `(addr & SLV_MASK[s]) == SLV_BASE[s]`. The table lives in `soc_v2/rtl/soc_map.vh` and is listed in [`memory_map.md`](memory_map.md).
- **Unmapped addresses.** A request that hits no slave is never forwarded. The crossbar grants it at once and answers the next cycle itself with `rvalid = 1`, `err = 1`, `rdata = 0`. In the cycle that error response is delivered, the same master's next unmapped request is not granted; it is granted one cycle later.
- **Arbitration, per slave, combinational in the request cycle (no added latency):**
  1. Master `PRIO_M` (7, the display controller) wins whenever it requests the slave.
  2. Otherwise **round robin**: the first requesting master after the one this slave granted last, wrapping around. The pointer resets to 0, so master 1 comes first after reset. Every grant moves the pointer, priority grants included.
- **One transaction per slave.** A slave is offered a new request only when it has no response pending, or in the cycle its pending response returns. A slave that answers in one cycle therefore accepts one transfer every cycle.
- **Response routing.** The crossbar remembers which master owns each slave's pending response and returns `rvalid`, `rdata` and `err` to that master in the same cycle. A master with no response that cycle sees `rvalid = 0`, `err = 0`, `rdata = 0`.
- **Latency.** The crossbar adds no cycles: a shared-SRAM bank answers in the cycle after the grant.

### Known properties (accepted in v1.0)

| # | Property | Impact | Note |
|---|---|---|---|
| P1 | While a slave holds `gnt` low, the request presented to it can change from one cycle to the next: a higher-priority master, or a master earlier in round-robin order, can take over. | A slave must not assume that a request it stalls stays the same. | Every current slave decides `gnt` combinationally and holds no state until the handshake, so nothing is affected. A future stateful slave would need the arbiter to lock its choice. |
| P2 | A priority (display) grant also moves the round-robin pointer to 7, so the next round-robin search restarts at master 0. | When the display hits one slave often, lower-numbered masters get more turns there. Measured with the display requesting the same bank 30 % of the time: CPU 373 grants vs command processor 40. | In the SoC the display reads each bank about once every 16 cycles during a line fetch, so the skew is small. Possible change (v1.1, needs agreement): update the pointer only on round-robin grants. |
| P3 | A master that requests a slave every cycle with priority would starve the others there. | Only the display has priority. | The display issues at most one request every two cycles, spread over the 8 banks. |
| P4 | Decoding uses only the bits in `SLV_MASK`. | Regions repeat (alias) within their 256 MB windows. | See the memory map. Software uses only the documented ranges. |

### Measured (unit tests, `soc_v2/test/unit`)

| Scenario | Result |
|---|---|
| 8 masters, each streaming to its own bank | **7.99 transfers per cycle** (8 in parallel every cycle) |
| 8 masters streaming one array, staggered by one word (real banks) | **7.80 words per cycle** |
| 8 masters on one bank | 0.98 words per cycle (fully serialised) |
| Masters 0–6 hammering one bank, display idle | Equal shares (201 grants each); worst wait 6 cycles |
| Display requesting a contended bank | Granted in the cycle it asks, every time |
| Size, Yosys generic synthesis | 13,966 cells (was 28,879 before the v1.0 arbiter rewrite, which is formally proven equivalent) |

## 4. Masters in the SoC

| # | Master | RTL | Traffic |
|---|---|---|---|
| 0 | CPU data port | `cpu_subsys.v` | Every data access that is not to DTCM (`0x1xxx_xxxx` is served locally). Issued from the EX stage; the pipeline freezes while waiting for `gnt` or `rvalid`. Reads ITCM constants through the crossbar. |
| 1 | UART boot loader | `uart_boot.v` | Only while the CPU is held in reset. 32-bit accesses (`be = 1111`). Ignores `err`. |
| 2–5 | GPU data channels 0–3 | `gpu_tiny_wrap.v` | One OBI port per tiny-gpu data channel (word or byte mode, see the command processor in the memory map) |
| 6 | GPU command processor | `gpu_cp.v` | Descriptor and kernel fetches, fence writes |
| 7 | Display controller | `display_ctrl.v` | Framebuffer line fetches; **highest priority** |

## 5. Slaves in the SoC

| # | Slave | `gnt` | Response | `err` | Byte enables |
|---|---|---|---|---|---|
| 0 | ITCM port B | always 1 | next cycle | never | honoured |
| 1 | DTCM port B | always 1 | next cycle | never | honoured |
| 2–9 | Shared SRAM banks 0–7 (`obi_sram.v`) | always 1 | next cycle | never | honoured |
| 10 | Peripheral bridge (`periph_bridge.v`) | the addressed register block's `p_ready` (UART DATA writes wait while the transmitter is busy) | next cycle | unknown block (index ≥ 6) | **ignored**: registers take 32-bit writes only |

## 6. Peripheral bridge and register blocks

The bridge is one crossbar slave in front of six register blocks. Block *i* sits at `0x4000_0000 + i × 0x1000` and is selected by `addr[15:12]`.

| Signal | Width | Meaning |
|---|---|---|
| `p_req[i]` | 1 per block | The bridge presents a request to block *i* (only while `req` is high and the index is valid) |
| `p_we`, `p_be`, `p_wdata` | 1, 4, 32 | Passed through from the OBI request |
| `p_addr` | 12 | `addr[11:0]`, the offset inside the block |
| `p_ready[i]` | 1 per block | Block *i* can take the request this cycle (it becomes the bridge's `gnt`) |
| `p_rdata[i]` | 32 per block | Read data, registered by the block |

A block acts on `p_req & p_ready` and registers its read data at that clock edge. The bridge returns that data with `rvalid` in the next cycle. An index ≥ 6 is granted at once and answered with `err = 1`, `rdata = 0`.

## 7. Verification

| Test | Checks |
|---|---|
| `test_xbar.py` (6 tests) | A cycle-accurate reference model of §3 predicts `s_req`, the winner of every slave and every `gnt`. A protocol checker follows each transaction from request to response: correct slave and fields, no second request to a busy slave, response routed to its owner in the right cycle with the slave's `rdata`/`err`, unmapped → `err` the next cycle, display priority, exact round robin, nothing lost or duplicated. Random traffic over all masters and slaves with slave stalls, latencies 1–5, slave errors and back-to-back requests. |
| `test_shared.py` (2 tests) | Crossbar plus the real SRAM banks: 12,883 concurrent random reads and writes with byte enables all return the right data, and every physical bank holds exactly the words the interleaving rule puts there. Bandwidth figures above. |
| `test_sram.py` (2 tests) | One bank: `gnt` = 1, `err` = 0, `rvalid` exactly one cycle after each request and never during reset, byte enables, row = `addr[5 +: AW]` with the bank-select bits ignored |
| `test_bridge.py` (1 test) | One-hot `p_req`, pass-through fields, `gnt` from `p_ready` (back-pressure), `rvalid` one cycle after the handshake, registered read data, `err` for unknown blocks |
| Mutation check | Seven deliberately broken RTL copies (wrong response routing, no priority, frozen round-robin pointer, busy slave offered a request, no error responder, broken bank interleaving, ignored back-pressure). Every one fails the tests. |
| System test | Firmware boots over UART and exercises all eight masters through the real SoC |

## 8. Changelog

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-11-23 | First frozen version, written from the RTL. Arbiter loop rewritten (13,966 cells instead of 28,879; formally equivalent). Address map moved to `soc_map.vh`. |
