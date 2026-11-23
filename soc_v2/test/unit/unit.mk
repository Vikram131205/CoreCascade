# One cocotb unit bench; invoked by Makefile as `make -f unit.mk UNIT=<name>`
SIM ?= icarus
TOPLEVEL_LANG = verilog

RTL     = ../../rtl
CPU_RTL = ../../../rv32i-pipeline/pp/pp.srcs/sources_1/new

SIM_BUILD           = sim_build_$(UNIT)
COCOTB_RESULTS_FILE = results_$(UNIT).xml
COMPILE_ARGS       += -I$(RTL)
export SEED ?= 1
export PYTHONPATH := $(CURDIR):$(PYTHONPATH)

ifeq ($(UNIT),xbar)
COCOTB_TOPLEVEL     = tb_xbar
COCOTB_TEST_MODULES = test_xbar
VERILOG_SOURCES     = $(RTL)/obi_xbar.v tb_xbar.v
else ifeq ($(UNIT),shared)
COCOTB_TOPLEVEL     = tb_shared
COCOTB_TEST_MODULES = test_shared
VERILOG_SOURCES     = $(RTL)/obi_xbar.v $(RTL)/obi_sram.v $(CPU_RTL)/sram_sp.v tb_shared.v
else ifeq ($(UNIT),sram)
COCOTB_TOPLEVEL     = obi_sram
COCOTB_TEST_MODULES = test_sram
VERILOG_SOURCES     = $(RTL)/obi_sram.v $(CPU_RTL)/sram_sp.v
COMPILE_ARGS       += -Pobi_sram.WORDS=64 -Pobi_sram.ROW_LSB=5
else ifeq ($(UNIT),bridge)
COCOTB_TOPLEVEL     = periph_bridge
COCOTB_TEST_MODULES = test_bridge
VERILOG_SOURCES     = $(RTL)/periph_bridge.v
else
$(error UNIT must be one of: xbar shared sram bridge)
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
