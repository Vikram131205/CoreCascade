# cocotb simulation of soc_top v2 (invoked by ../Makefile)

SIM ?= icarus
TOPLEVEL_LANG = verilog
COCOTB_TOPLEVEL     = soc_top
COCOTB_TEST_MODULES = test_soc

CPU_RTL = ../../rv32i-pipeline/pp/pp.srcs/sources_1/new
VERILOG_SOURCES = \
    $(addprefix $(CPU_RTL)/, ALU.v alu_four.v alu_pc.v bj_det.v controlpath.v \
        extender_offsethandler.v hazard_unit.v mux_32.v mux_32_3in.v pc_.v \
        pp_stage_2.v pp_stage_3.v pp_stage_4.v pp_stage_5.v reg_file_.v csr_unit.v mdu.v \
        sram_sp.v rv32i_core.v) \
    ../build/gpu.v \
    $(addprefix ../rtl/, sram_dp.v obi_sram.v obi_xbar.v periph_bridge.v rst_sync.v \
        cpu_subsys.v uart_tx.v uart_rx.v uart_periph.v uart_boot.v sysctl.v timer.v \
        irq_ctrl.v gpu_tiny_wrap.v gpu_cp.v display_ctrl.v soc_top.v)

# Simulation configuration: fast UART (8 clocks/bit) and a small display
# (16x16 framebuffer, 32x32 visible, short porches) so frames take ~2.8k cycles.
UART_DIV ?= 8
COMPILE_ARGS += -Psoc_top.UART_DIV=$(UART_DIV) \
    -Psoc_top.FB_W=16 -Psoc_top.FB_H=16 \
    -Psoc_top.H_FP=2 -Psoc_top.H_SYNC=4 -Psoc_top.H_BP=2 \
    -Psoc_top.V_FP=1 -Psoc_top.V_SYNC=1 -Psoc_top.V_BP=1
export UART_DIV

export FIRMWARE ?= $(abspath ../build/firmware.elf)

ifeq ($(VCD),1)
VERILOG_SOURCES += waves.v
COMPILE_ARGS += -s soc_waves
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
