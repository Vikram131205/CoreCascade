# cocotb simulation of soc_top (invoked by ../Makefile)

SIM ?= icarus
TOPLEVEL_LANG = verilog
COCOTB_TOPLEVEL     = soc_top
COCOTB_TEST_MODULES = test_soc

CPU_RTL = ../rtl/cpu_v1
VERILOG_SOURCES = \
    $(CPU_RTL)/ALU.v \
    $(CPU_RTL)/alu_four.v \
    $(CPU_RTL)/alu_pc.v \
    $(CPU_RTL)/bj_det.v \
    $(CPU_RTL)/controlpath.v \
    $(CPU_RTL)/extender_offsethandler.v \
    $(CPU_RTL)/hazard_unit.v \
    $(CPU_RTL)/mux_32.v \
    $(CPU_RTL)/mux_32_3in.v \
    $(CPU_RTL)/pc_.v \
    $(CPU_RTL)/pp_stage_2.v \
    $(CPU_RTL)/pp_stage_3.v \
    $(CPU_RTL)/pp_stage_4.v \
    $(CPU_RTL)/pp_stage_5.v \
    $(CPU_RTL)/reg_file_.v \
    $(CPU_RTL)/csr_unit.v \
    $(CPU_RTL)/sram_sp.v \
    $(CPU_RTL)/rv32i_core.v \
    ../build/gpu.v \
    ../rtl/gpu_subsys.v \
    ../rtl/uart_tx.v \
    ../rtl/uart_rx.v \
    ../rtl/uart_periph.v \
    ../rtl/uart_boot.v \
    ../rtl/sysctl.v \
    ../rtl/soc_top.v

# fast UART in simulation (8 clocks per bit); silicon default is 434 (115200 @ 50 MHz)
UART_DIV ?= 8
COMPILE_ARGS += -Psoc_top.UART_DIV=$(UART_DIV)
export UART_DIV

export FIRMWARE ?= $(abspath ../build/firmware.elf)

# make VCD=1 -> test/soc.vcd (open with gtkwave soc.gtkw)
ifeq ($(VCD),1)
VERILOG_SOURCES += waves.v
COMPILE_ARGS += -s soc_waves
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
