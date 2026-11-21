`timescale 1ns / 1ps
// Waveform dump for `make VCD=1` (simulation only, extra top-level module).
// By default recording starts when the boot loader releases the CPU, which
// skips ~200k cycles of UART download. Add PLUSARGS=+waves_boot to record it.
module soc_waves;
    initial begin
        $dumpfile("soc.vcd");
        $dumpvars(0, soc_top);
        if (!$test$plusargs("waves_boot")) begin
            $dumpoff;
            wait (soc_top.reset === 1'b1);
            wait (soc_top.reset === 1'b0);
            wait (soc_top.u_boot.active === 1'b0);
            $dumpon;
        end
    end
endmodule
