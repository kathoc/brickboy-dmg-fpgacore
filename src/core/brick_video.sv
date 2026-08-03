// BrickBoy video: capture the DMG's 2-bit stream and scan it out on the
// BrickBoy raster.
//
// The raster is 896 x 627 at 33.554432 MHz. That is exactly 561,792 clocks -
// one GB frame (70224 cpu cycles x 8) - so the scanout locks to the emulated
// frame with no drift and no resampling: 59.7275 Hz on both sides.
//
// Geometry (output pixels):
//   module   672 x 608   the whole LCD module, 1 GB dot = 4x4
//   game     640 x 576   inset 16 px on every side (brickboy PANEL_MARGIN 4)
//   blanking 224 x 19
//
// Phase: h/v reset on the GB's vsync (start of vblank). The GB then spends 10
// lines of vblank before drawing row 0, while the raster spends V_BEG+16 lines
// before reading it, and the arithmetic works out so the reader is always at
// least ~2.4 GB lines behind the writer and never a whole frame behind - i.e.
// tear-free with about one frame of latency, the same discipline the upstream
// lcd.v used. Fast-forward breaks the lockstep and may roll; normal play never
// does.
//
// This milestone draws the plain image: shade -> 4-level grey, margin dark.
// The brickboy panel pipeline replaces the scanout side next.

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
localparam H_BEG = 192, V_BEG = 19;         // module top-left
localparam MARGIN = 16;                     // exposed module border, output px
localparam GX0 = H_BEG + MARGIN;            // game area
localparam GY0 = V_BEG + MARGIN;

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

// Fetch pipeline: the frame RAM has a registered address and the colour is
// registered once more, so coordinates are taken 2 clocks ahead. The lookahead
// only wraps a line inside blanking (H_BEG >= 2), where it does not matter.

wire [9:0] h_pre = (h >= H_TOT - 2) ? h - (H_TOT - 2) : h + 10'd2;

wire       pre_game = (h_pre >= GX0) && (h_pre < GX0 + 640) &&
                      (v >= GY0)     && (v < GY0 + 576);
wire       pre_mod  = (h_pre >= H_BEG) && (h_pre < H_BEG + 672) &&
                      (v >= V_BEG)    && (v < V_BEG + 608);

wire [7:0] nx = (h_pre - GX0) >> 2;         // native dot 0..159
wire [7:0] ny = (v - GY0) >> 2;             // native dot 0..143

reg [1:0]  fb_q;
reg        p1_game, p1_mod;
always @(posedge clk_sys) begin
	fb_q    <= fb[{ny, 7'b0} + {2'b0, ny, 5'b0} + nx];   // ny*160 + nx
	p1_game <= pre_game;
	p1_mod  <= pre_mod;
end

// Milestone palette: plain 4-level grey; module border a dark neutral.
reg [7:0] shade;
always @(*) begin
	case (fb_q)
		2'd0: shade = 8'hFF;
		2'd1: shade = 8'hAA;
		2'd2: shade = 8'h55;
		2'd3: shade = 8'h00;
	endcase
end

always @(posedge clk_sys) begin
	de  <= p1_mod;
	rgb <= !p1_mod  ? 24'h000000 :
	       !p1_game ? 24'h303028 :            // border placeholder
	                  {3{shade}};

	// Single-cycle sync pulses; hs sits at h=8 so it never overlaps vs.
	vs <= (v == 0) && (h == 0);
	hs <= (h == 8);
end

endmodule
