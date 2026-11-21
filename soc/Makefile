# ============================================================
#  CPU + GPU SoC  (run from WSL)
#    make          - build GPU netlist + firmware, run SoC simulation
#    make fw       - firmware only (build/firmware.elf + .lst)
#    make clean
#  Needs: sv2v, clang/ld.lld (riscv32 target), iverilog, cocotb
# ============================================================

GPU_SRC := ../tiny-gpu/src
BUILD   := build
CC      := clang
OBJDUMP := $(firstword $(shell which llvm-objdump llvm-objdump-18 2>/dev/null))
CFLAGS  := --target=riscv32 -march=rv32i_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib \
           -fno-pic -mno-relax -Wall -Wextra
LDFLAGS := -fuse-ld=lld -T fw/link.ld -Wl,--gc-sections
FW_SRC  := fw/crt0.S fw/main.c fw/runtime.c

CPU_RTL := rtl/cpu_v1
CPU_SRC := $(addprefix $(CPU_RTL)/, ALU.v alu_four.v alu_pc.v bj_det.v controlpath.v \
           extender_offsethandler.v hazard_unit.v mux_32.v mux_32_3in.v pc_.v \
           pp_stage_2.v pp_stage_3.v pp_stage_4.v pp_stage_5.v reg_file_.v csr_unit.v sram_sp.v rv32i_core.v)
SOC_SRC := $(CPU_SRC) $(BUILD)/gpu.v $(addprefix rtl/, gpu_subsys.v uart_tx.v uart_rx.v \
           uart_periph.v uart_boot.v sysctl.v soc_top.v)

.PHONY: all test fw gpu lint clean

all: test

test: fw gpu
	$(MAKE) -C test

# Yosys elaboration + structural checks (latches, multiple drivers, loops)
lint: gpu
	yosys -q -l $(BUILD)/yosys.log -p "read_verilog $(SOC_SRC); prep -top soc_top; check -assert; stat"
	@! grep -E '^Latch inferred' $(BUILD)/yosys.log && echo "lint OK: no latches, check passed"

fw: $(BUILD)/firmware.elf
gpu: $(BUILD)/gpu.v

$(BUILD)/firmware.elf: $(FW_SRC) fw/soc.h fw/link.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(FW_SRC) -o $@
	$(OBJDUMP) -d -j .text $@ > $(BUILD)/firmware.lst

# tiny-gpu is SystemVerilog; convert to Verilog-2005 for iverilog/yosys/OpenLane
$(BUILD)/gpu.v: $(wildcard $(GPU_SRC)/*.sv) | $(BUILD)
	echo '`timescale 1ns / 1ps' > $@
	sv2v $(GPU_SRC)/*.sv >> $@

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
	$(MAKE) -C test clean
