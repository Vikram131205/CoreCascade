`timescale 1ns / 1ps
// ============================================================================
//  Display controller (VGA), registers at 0x4000_5000
// ============================================================================
//  Framebuffer FB_W x FB_H, 8 bpp RGB332, in shared SRAM; every pixel is shown
//  2x2, so 320x240 fills 640x480 @ 60 Hz. One clock domain: the pixel clock is
//  a pixel ENABLE every PIX_DIV system cycles (50 MHz / 2 = 25 MHz).
//
//  Two line buffers (ping-pong): while source line y is on screen (two output
//  lines), the OBI master fetches line y+1 into the other buffer. Line 0 is
//  fetched during vertical blanking. FB_BASE is latched at the start of
//  vblank, so a page flip never tears.
//
//  Registers
//    +0x0 CTRL      RW  bit0 ENABLE
//    +0x4 FB_BASE   RW  next framebuffer (takes effect at the next vblank)
//    +0x8 STATUS    R   [15:0] frame counter, bit30 underflow (sticky), bit31 in vblank
//    +0xC FB_CUR    R   framebuffer being scanned out
//  vsync_irq: one-cycle pulse at the start of vblank -> interrupt controller.
// ============================================================================
module display_ctrl #(
    parameter FB_W    = 320,
    parameter FB_H    = 240,
    parameter H_FP    = 16,
    parameter H_SYNC  = 96,
    parameter H_BP    = 48,
    parameter V_FP    = 10,
    parameter V_SYNC  = 2,
    parameter V_BP    = 33,
    parameter PIX_DIV = 2
) (
    input             clk,
    input             reset,

    // registers (peripheral bridge)
    input             p_req,
    input             p_we,
    input      [11:0] p_addr,
    input      [31:0] p_wdata,
    output            p_ready,
    output reg [31:0] p_rdata,

    // OBI master (line fetch)
    output reg        m_req,
    output            m_we,
    output     [3:0]  m_be,
    output reg [31:0] m_addr,
    output     [31:0] m_wdata,
    input             m_gnt,
    input             m_rvalid,
    input      [31:0] m_rdata,
    input             m_err,

    // VGA
    output reg [11:0] vga_rgb,
    output reg        vga_hs,         // active low
    output reg        vga_vs,         // active low
    output reg        vsync_irq,

    // pixel probe for verification (same cycle as vga_rgb)
    output reg        out_active,
    output reg [15:0] out_x,
    output reg [15:0] out_y
);
    localparam H_VIS = 2 * FB_W, V_VIS = 2 * FB_H;
    localparam H_TOT = H_VIS + H_FP + H_SYNC + H_BP;
    localparam V_TOT = V_VIS + V_FP + V_SYNC + V_BP;
    localparam WPL   = FB_W / 4;                          // words per line
    localparam WW    = $clog2(WPL);

    assign p_ready = 1'b1;
    assign m_we    = 1'b0;
    assign m_be    = 4'b1111;
    assign m_wdata = 32'd0;

    // ---------------------------------------------------------------- registers
    reg        enable, underflow;
    reg [31:0] fb_base, fb_cur;
    reg [15:0] frames;
    wire       in_vblank;

    always @(posedge clk) begin
        if (p_req & ~p_we) begin
            case (p_addr[3:2])
                2'd0: p_rdata <= {31'd0, enable};
                2'd1: p_rdata <= fb_base;
                2'd2: p_rdata <= {in_vblank, underflow, 14'd0, frames};
                2'd3: p_rdata <= fb_cur;
            endcase
        end
    end

    // ---------------------------------------------------------------- timing
    reg [$clog2(PIX_DIV)-1:0] div;
    wire pe = (div == PIX_DIV - 1);                       // pixel enable
    reg [15:0] hc, vc;
    assign in_vblank = (vc >= V_VIS);
    wire line_start = pe & (hc == H_TOT - 1);             // next cycle starts a new line
    wire [15:0] vc_next = (vc == V_TOT - 1) ? 16'd0 : vc + 16'd1;

    always @(posedge clk) begin
        if (reset) begin
            div <= 0; hc <= 0; vc <= 0;
        end else begin
            div <= pe ? 0 : div + 1'b1;
            if (pe) begin
                if (hc == H_TOT - 1) begin
                    hc <= 0;
                    vc <= vc_next;
                end else hc <= hc + 16'd1;
            end
        end
    end

    // ---------------------------------------------------------------- line buffers + fetch
    reg [31:0] lbuf [0:(2 << WW)-1];                      // indexed {buffer, word}
    reg        f_busy, f_wait, f_buf;
    reg [WW:0] f_word;
    reg [15:0] f_line;

    // fetch triggers, evaluated when a new line starts
    wire start_vblank = line_start & (vc_next == V_VIS);
    wire start_pair   = line_start & (vc_next < V_VIS) & ~vc_next[0] & ((vc_next >> 1) + 1 < FB_H);
    wire        trig       = enable & (start_vblank | start_pair);
    wire [15:0] trig_line  = start_vblank ? 16'd0 : (vc_next >> 1) + 16'd1;

    always @(posedge clk) begin
        vsync_irq <= 1'b0;
        if (reset) begin
            enable    <= 1'b0;
            underflow <= 1'b0;
            fb_base   <= 32'd0;
            fb_cur    <= 32'd0;
            frames    <= 16'd0;
            f_busy    <= 1'b0;
            f_wait    <= 1'b0;
            m_req     <= 1'b0;
        end else begin
            if (p_req & p_we) begin
                case (p_addr[3:2])
                    2'd0: enable  <= p_wdata[0];
                    2'd1: fb_base <= p_wdata;
                    default: ;
                endcase
            end
            if (start_vblank) begin
                fb_cur    <= fb_base;
                frames    <= frames + 16'd1;
                vsync_irq <= 1'b1;
            end

            if (trig) begin
                if (f_busy) underflow <= 1'b1;            // previous line not finished in time
                f_busy <= 1'b1;
                f_wait <= 1'b0;
                f_buf  <= trig_line[0];
                f_line <= trig_line;
                f_word <= 0;
                m_req  <= 1'b1;
                m_addr <= (start_vblank ? fb_base : fb_cur) + trig_line * FB_W;
            end else if (f_busy) begin
                if (!f_wait) begin
                    if (m_gnt) begin m_req <= 1'b0; f_wait <= 1'b1; end
                end else if (m_rvalid) begin
                    f_wait <= 1'b0;
                    lbuf[{f_buf, f_word[WW-1:0]}] <= m_err ? 32'd0 : m_rdata;
                    if (f_word == WPL - 1) f_busy <= 1'b0;
                    else begin
                        f_word <= f_word + 1'b1;
                        m_addr <= m_addr + 32'd4;
                        m_req  <= 1'b1;
                    end
                end
            end
        end
    end

    // ---------------------------------------------------------------- pixel out
    wire        active = (hc < H_VIS) & (vc < V_VIS);
    wire [15:0] sx = hc >> 1, sy = vc >> 1;
    wire [31:0] pw = lbuf[{sy[0], sx[WW+1:2]}];
    wire [7:0]  px = pw >> (8 * sx[1:0]);

    always @(posedge clk) begin
        if (reset) begin
            vga_rgb <= 12'd0; vga_hs <= 1'b1; vga_vs <= 1'b1; out_active <= 1'b0;
        end else begin
            out_active <= active & enable;
            out_x      <= sx;
            out_y      <= sy;
            vga_rgb    <= (active & enable) ? {px[7:5], px[7], px[4:2], px[4], px[1:0], px[1:0]} : 12'd0;
            vga_hs     <= ~((hc >= H_VIS + H_FP) & (hc < H_VIS + H_FP + H_SYNC));
            vga_vs     <= ~((vc >= V_VIS + V_FP) & (vc < V_VIS + V_FP + V_SYNC));
        end
    end
endmodule
