// BrickBoy video: capture the DMG's 2-bit stream and scan it out on the
// BrickBoy raster.
//
// The raster is 896 x 627 at 33.554432 MHz. That is exactly 561,792 clocks -
// one GB frame (70224 cpu cycles x 8) - so the scanout locks to the emulated
// frame with no drift and no resampling: 59.7275 Hz on both sides.
//
// Geometry (output pixels):
//   active   640 x 576   the game area, 1 GB dot = 4x4
//   blanking 256 x 51
//
// The module margin (exposed reflector + printed mask) is NOT part of the
// active area. This matches brickboy's own default, Fill mode: the game runs
// edge to edge and the module border falls off-screen - on the Pocket, the
// bezel plays that part. Shadows cast by the outermost dots get clipped at the
// edge, exactly as they do in brickboy's Fill mode.
//
// Phase: h/v reset on the GB's vsync (start of vblank). The GB then spends 10
// lines of vblank before drawing row 0, while the raster spends V_BEG+16 lines
// before reading it, and the arithmetic works out so the reader is always at
// least ~2.4 GB lines behind the writer and never a whole frame behind - i.e.
// tear-free with about one frame of latency, the same discipline the upstream
// lcd.v used. Fast-forward breaks the lockstep and may roll; normal play never
// does.
//
// M4: the scanout no longer reads shades - it reads rows that brick_color has
// pushed through the brickboy colour stage (palette, bleed, density, offTint,
// crosstalk, gamma, saturation, warm, tone, black lift), processed one native
// row ahead of display into a pair of RGB888 line buffers.

module brick_video (
	input  wire        clk_sys,      // 33.554432 MHz; also the pixel clock domain
	input  wire        ce,           // 4.194304 MHz strobe (cpu clock enable)

	input  wire        lcd_clkena,
	input  wire [1:0]  lcd_data,
	input  wire [1:0]  lcd_mode,     // 01 = vblank
	input  wire        lcd_on,
	input  wire        lcd_vsync,

	output reg         hs,
	output reg         vs,
	output reg         de,
	output reg  [23:0] rgb
);

// ---------------------------------------------------------------- capture ---
// Same discipline as upstream lcd.v: a write pointer that advances on every
// lcd_clkena pixel and resets on any edge of "lcd off" (off or vblank).

localparam FB_SIZE = 160 * 144;

reg [1:0]  fb[FB_SIZE];
reg [14:0] wptr;
reg        lcd_off_r;

// read port for the colour stage
wire [14:0] col_fb_addr;
reg  [1:0]  col_fb_q;
always @(posedge clk_sys) col_fb_q <= fb[col_fb_addr];

wire lcd_off = ~lcd_on || (lcd_mode == 2'd1);

always @(posedge clk_sys) begin
	if (ce) begin
		if (lcd_clkena) begin
			fb[wptr] <= lcd_data;
			wptr     <= (wptr == FB_SIZE - 1) ? 15'd0 : wptr + 1'd1;
		end
		lcd_off_r <= lcd_off;
		if (lcd_off_r ^ lcd_off) wptr <= 0;
	end
end

// ----------------------------------------------------------------- raster ---

localparam H_TOT = 896, V_TOT = 627;
localparam GX0 = 208, GY0 = 35;             // game area top-left

// ------------------------------------------------------------ colour stage ---
// Row triggers: row 0 is prepared two raster lines before the game area, and
// each subsequent row on the first raster line of the row before it - four
// lines (3584 clocks) ahead of when the scanout needs it, against a stage that
// takes ~490.

wire [7:0] disp_row = (v - GY0) >> 2;

reg [9:0] h, v;
reg       vsync_r;

always @(posedge clk_sys) begin
	vsync_r <= lcd_vsync;
	if (~vsync_r & lcd_vsync) begin
		h <= 0;
		v <= 0;
	end else if (h == H_TOT - 1) begin
		h <= 0;
		v <= (v == V_TOT - 1) ? 10'd0 : v + 1'd1;
	end else begin
		h <= h + 1'd1;
	end
end

wire start_frame = (v == GY0 - 2) && (h == 0);
wire row_tick    = (v >= GY0) && (v < GY0 + 572) && (((v - GY0) & 10'd3) == 0) && (h == 0);

wire [7:0]  lb_waddr;
wire [23:0] lb_wdata;
wire        lb_wren, lb_wbank;

brick_color color (
	.clk         ( clk_sys      ),
	.start_frame ( start_frame  ),
	.row_tick    ( row_tick     ),
	.row_disp    ( disp_row     ),
	.fb_addr     ( col_fb_addr  ),
	.fb_q        ( col_fb_q     ),
	.lb_waddr    ( lb_waddr     ),
	.lb_wdata    ( lb_wdata     ),
	.lb_wren     ( lb_wren      ),
	.lb_wbank    ( lb_wbank     )
);

// processed rows, double-buffered by native-row parity
reg [23:0] lb[0:511];
always @(posedge clk_sys) if (lb_wren) lb[{lb_wbank, lb_waddr}] <= lb_wdata;

// Fetch pipeline: the line buffer has a registered address and the colour is
// registered once more, so coordinates are taken 2 clocks ahead. The lookahead
// only wraps a line inside blanking (H_BEG >= 2), where it does not matter.

wire [9:0] h_pre = (h >= H_TOT - 2) ? h - (H_TOT - 2) : h + 10'd2;

wire       pre_game = (h_pre >= GX0) && (h_pre < GX0 + 640) &&
                      (v >= GY0)     && (v < GY0 + 576);

wire [7:0] nx = (h_pre - GX0) >> 2;         // native dot 0..159
wire [7:0] ny = (v - GY0) >> 2;             // native dot 0..143

reg [23:0] lb_q;
reg        p1_game;
always @(posedge clk_sys) begin
	lb_q    <= lb[{ny[0], nx}];
	p1_game <= pre_game;
end

always @(posedge clk_sys) begin
	de  <= p1_game;
	rgb <= p1_game ? lb_q : 24'h000000;

	// Single-cycle sync pulses; hs sits at h=8 so it never overlaps vs.
	vs <= (v == 0) && (h == 0);
	hs <= (h == 8);
end

endmodule
