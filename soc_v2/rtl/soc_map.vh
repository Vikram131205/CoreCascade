// ============================================================================
//  CoreCascade SoC v2 crossbar address map (docs/spec/memory_map.md, v1.0)
// ============================================================================
//  `include this inside a module, after NS (number of slaves) is declared.
//  Slave s is hit when (addr & SLV_MASK[s]) == SLV_BASE[s]; no hit -> OBI err.
//    s=0 ITCM  s=1 DTCM  s=2..9 shared banks 0..7 (bank = addr[4:2])  s=10 periph
// ============================================================================
localparam [NS*32-1:0] SLV_BASE = {32'h4000_0000,
    32'h2000_001C, 32'h2000_0018, 32'h2000_0014, 32'h2000_0010,
    32'h2000_000C, 32'h2000_0008, 32'h2000_0004, 32'h2000_0000,
    32'h1000_0000, 32'h0000_0000};
localparam [NS*32-1:0] SLV_MASK = {32'hF000_0000,
    {8{32'hF000_001C}},
    32'hF000_0000, 32'hF000_0000};
localparam PRIO_M = 7;        // master 7 (display) wins every slave it requests
