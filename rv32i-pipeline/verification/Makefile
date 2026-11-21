# ============================================================
#  RV32I Pipeline — CocoTB Verification
# ============================================================
#  Usage (run from WSL with cocotb + Icarus Verilog installed):
#    make              — run all tests
#    make SIM=verilator — use Verilator instead
#    make clean        — remove build artifacts
# ============================================================

SIM        ?= icarus
TOPLEVEL_LANG = verilog
COCOTB_TOPLEVEL     = tb_cpu
COCOTB_TEST_MODULES = test_pipeline

# RTL source files
RTL_DIR    = ../pp/pp.srcs/sources_1/new
VERILOG_SOURCES = \
    $(RTL_DIR)/ALU.v \
    $(RTL_DIR)/alu_four.v \
    $(RTL_DIR)/alu_pc.v \
    $(RTL_DIR)/bj_det.v \
    $(RTL_DIR)/controlpath.v \
    $(RTL_DIR)/extender_offsethandler.v \
    $(RTL_DIR)/hazard_unit.v \
    $(RTL_DIR)/mux_32.v \
    $(RTL_DIR)/mux_32_3in.v \
    $(RTL_DIR)/pc_.v \
    $(RTL_DIR)/pp_stage_2.v \
    $(RTL_DIR)/pp_stage_3.v \
    $(RTL_DIR)/pp_stage_4.v \
    $(RTL_DIR)/pp_stage_5.v \
    $(RTL_DIR)/reg_file_.v \
    $(RTL_DIR)/csr_unit.v \
    $(RTL_DIR)/mdu.v \
    $(RTL_DIR)/sram_sp.v \
    $(RTL_DIR)/rv32i_core.v \
    $(RTL_DIR)/top_module.v \
    tb_cpu.v

# make VCD=1 -> cpu.vcd (tip: add COCOTB_TEST_FILTER=test_jal_jalr to dump one test)
ifeq ($(VCD),1)
VERILOG_SOURCES += waves.v
COMPILE_ARGS += -s cpu_waves
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
