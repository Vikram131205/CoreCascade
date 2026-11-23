# ============================================================
#  SoC v2 interconnect unit tests (cocotb + Icarus)
#    make            - all units
#    make xbar       - one unit: xbar | shared | sram | bridge
#    make SEED=7     - another random seed
#    make clean
# ============================================================
UNITS := xbar shared sram bridge

.PHONY: all clean $(UNITS)

all: $(UNITS)

$(UNITS):
	$(MAKE) -f unit.mk UNIT=$@

clean:
	rm -rf sim_build_* results_*.xml __pycache__
