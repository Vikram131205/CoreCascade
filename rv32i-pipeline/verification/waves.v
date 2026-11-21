`timescale 1ns / 1ps
// Waveform dump for `make VCD=1` (simulation only, extra top-level module).
module cpu_waves;
    initial begin
        $dumpfile("cpu.vcd");
        $dumpvars(0, tb_cpu);
    end
endmodule
