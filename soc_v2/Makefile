# ============================================================
#  CoreCascade SoC v2  (run from WSL)
#    make          - build GPU netlist + firmware, run SoC simulation
#    make fw       - firmware only (build/firmware.elf + .lst)
#    make kernels  - assemble fw/kernels/*.s -> build/kernels.h (+ listing)
#    make unit     - interconnect unit tests (test/unit)
#    make lint     - yosys elaboration + structural checks
#    make clean
#  Needs: sv2v, clang/ld.lld (riscv32 target), iverilog, cocotb, python3
#  (llvm-objdump optional: firmware listing)
# ============================================================

GPU_SRC := ../tiny-gpu/src
BUILD   := build
CC      := clang
OBJDUMP := $(firstword $(shell which llvm-objdump llvm-objdump-18 2>/dev/null))
# The simulation uses a 16x16 framebuffer (see test/Makefile); the FPGA build
# overrides FB_W/FB_H with 320/240.
FB_W    ?= 16
FB_H    ?= 16
CFLAGS  := --target=riscv32 -march=rv32im_zicsr -mabi=ilp32 -O2 -ffreestanding -nostdlib \
           -fno-pic -mno-relax -Wall -Wextra -DFB_W=$(FB_W) -DFB_H=$(FB_H)
LDFLAGS := -fuse-ld=lld -T fw/link.ld -Wl,--gc-sections
FW_SRC  := fw/crt0.S fw/main.c fw/cc.c fw/runtime.c
ASM     := python3 ../sw/asm/tinygpu_asm.py
# GPU kernels, in this order in the .gpu section
KERNELS := fw/kernels/matadd.s fw/kernels/matmul.s fw/kernels/pattern.s

CPU_RTL := ../rv32i-pipeline/pp/pp.srcs/sources_1/new
CPU_SRC := $(addprefix $(CPU_RTL)/, ALU.v alu_four.v alu_pc.v bj_det.v controlpath.v \
           extender_offsethandler.v hazard_unit.v mux_32.v mux_32_3in.v pc_.v \
           pp_stage_2.v pp_stage_3.v pp_stage_4.v pp_stage_5.v reg_file_.v csr_unit.v mdu.v \
           sram_sp.v rv32i_core.v)
SOC_SRC := $(CPU_SRC) $(BUILD)/gpu.v $(addprefix rtl/, sram_dp.v obi_sram.v obi_xbar.v \
           periph_bridge.v rst_sync.v cpu_subsys.v uart_tx.v uart_rx.v uart_periph.v uart_boot.v \
           sysctl.v timer.v irq_ctrl.v gpu_tiny_wrap.v gpu_cp.v display_ctrl.v soc_top.v)

.PHONY: all test fw gpu kernels unit lint clean

all: test

test: fw gpu
	$(MAKE) -C test

fw: $(BUILD)/firmware.elf
gpu: $(BUILD)/gpu.v
kernels: $(BUILD)/kernels.h

unit:
	$(MAKE) -C test/unit

$(BUILD)/kernels.h: $(KERNELS) ../sw/asm/tinygpu_asm.py | $(BUILD)
	$(ASM) -o $@ -l $(BUILD)/kernels.lst $(KERNELS)

$(BUILD)/firmware.elf: $(FW_SRC) fw/soc.h fw/cc.h fw/link.ld $(BUILD)/kernels.h | $(BUILD)
	$(CC) $(CFLAGS) -I$(BUILD) $(LDFLAGS) $(FW_SRC) -o $@
	$(if $(OBJDUMP),$(OBJDUMP) -d -j .text $@ > $(BUILD)/firmware.lst,@echo "llvm-objdump not found: skipping build/firmware.lst")

# tiny-gpu is SystemVerilog; convert to Verilog-2005 (the GPU itself is unmodified)
$(BUILD)/gpu.v: $(wildcard $(GPU_SRC)/*.sv) | $(BUILD)
	echo '`timescale 1ns / 1ps' > $@
	sv2v $(GPU_SRC)/*.sv >> $@

lint: gpu
	yosys -q -l $(BUILD)/yosys.log -p "read_verilog -Irtl $(SOC_SRC); prep -top soc_top; check -assert; stat"
	@! grep -E '^Latch inferred' $(BUILD)/yosys.log && echo "lint OK: no latches, check passed"

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
	$(MAKE) -C test clean
	$(MAKE) -C test/unit clean
