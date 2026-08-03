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

wire [7:0]  cc_x, cc_row;
wire [23:0] cc_rgb;
wire        cc_v, cc_bank;

brick_color color (
	.clk         ( clk_sys      ),
	.start_frame ( start_frame  ),
	.row_tick    ( row_tick     ),
	.row_disp    ( disp_row     ),
	.fb_addr     ( col_fb_addr  ),
	.fb_q        ( col_fb_q     ),
	.lb_waddr    ( cc_x         ),
	.lb_wdata    ( cc_rgb       ),
	.lb_wren     ( cc_v         ),
	.lb_wbank    ( cc_bank      ),
	.lb_wrow     ( cc_row       )
);

// Persistence: the analog cell state, read-modify-written once per native
// pixel per frame. Adds 7 cycles, well inside the 4-line lead.
wire [7:0]  gh_x;
wire [23:0] gh_rgb;
wire        gh_v;

brick_ghost ghost (
	.clk     ( clk_sys ),
	.in_v    ( cc_v    ),
	.in_row  ( cc_row  ),
	.in_x    ( cc_x    ),
	.in_rgb  ( cc_rgb  ),
	.out_v   ( gh_v    ),
	.out_x   ( gh_x    ),
	.out_rgb ( gh_rgb  )
);

// Which line-buffer bank the ghost's output belongs to, delayed to match its
// pipeline. Four banks, indexed by native row mod 4: the scanout needs the
// current row AND the one above for the drop shadow, while the colour stage is
// already writing the row below - three live rows, so two banks is not enough.
reg [1:0] wrow_dly[0:6];
integer wi;
always @(posedge clk_sys) begin
	wrow_dly[0] <= cc_row[1:0];
	for (wi = 1; wi < 7; wi = wi + 1) wrow_dly[wi] <= wrow_dly[wi-1];
end
wire [1:0] lb_wbank = wrow_dly[6];

// processed rows, double-buffered by native-row parity
// Two identical copies so the scanout can read the current row and the row
// above in the same cycle. One write port and one read port each keeps them in
// M10K; asking a single array for four reads turns it into 15k flip-flops.
reg [23:0] lb_a[0:639];
reg [23:0] lb_b[0:639];
always @(posedge clk_sys) if (gh_v) begin
	lb_a[{lb_wbank, gh_x}] <= gh_rgb;
	lb_b[{lb_wbank, gh_x}] <= gh_rgb;
end

// Fetch pipeline: the line buffer has a registered address and the colour is
// registered once more, so coordinates are taken 2 clocks ahead. The lookahead
// only wraps a line inside blanking (H_BEG >= 2), where it does not matter.

wire [9:0] h_pre = (h >= H_TOT - 2) ? h - (H_TOT - 2) : h + 10'd2;

wire       pre_game = (h_pre >= GX0) && (h_pre < GX0 + 640) &&
                      (v >= GY0)     && (v < GY0 + 576);

wire [7:0] nx = (h_pre - GX0) >> 2;         // native dot 0..159
wire [7:0] ny = (v - GY0) >> 2;             // native dot 0..143

// The grid needs the dot above and to the left as shadow casters, so four
// reads: this dot, the one left of it, the row above, and the diagonal. Both
// native rows are live in the two line-buffer banks.
// Only two of the four casters need a RAM read: scanning left to right, the
// dot to the left is the previous cell's value, so it and the diagonal are
// held in registers that update once per cell instead of costing a port.
wire       ny_up_ok = (ny != 8'd0);
wire [1:0] bank_c = ny[1:0];
wire [1:0] bank_u = ny_up_ok ? (ny[1:0] - 2'd1) : ny[1:0];

reg [23:0] q_c, q_u, q_l, q_ul;
reg [1:0]  sx1, sy1;
reg        p1_game;

wire [1:0] sx_now = (h_pre - GX0) & 2'd3;

always @(posedge clk_sys) begin
	q_c <= lb_a[{bank_c, nx}];
	q_u <= lb_b[{bank_u, nx}];
	if (sx_now == 2'd3) begin      // leaving a cell: it becomes the next left
		q_l  <= q_c;
		q_ul <= q_u;
	end
	sx1  <= sx_now;
	sy1  <= (v - GY0) & 2'd3;
	p1_game <= pre_game;
end

wire [23:0] grid_rgb;
brick_grid grid (
	.clk      ( clk_sys  ),
	.cell_rgb ( q_c      ),
	.up_rgb   ( q_u      ),
	.left_rgb ( q_l      ),
	.ul_rgb   ( q_ul     ),
	.sx       ( sx1      ),
	.sy       ( sy1      ),
	.out_rgb  ( grid_rgb )
);

// brick_grid adds 4 cycles, so de follows it
reg [3:0] game_dly;
always @(posedge clk_sys) game_dly <= {game_dly[2:0], p1_game};

always @(posedge clk_sys) begin
	de  <= game_dly[3];
	rgb <= game_dly[3] ? grid_rgb : 24'h000000;

	// Single-cycle sync pulses; hs sits at h=8 so it never overlaps vs.
	vs <= (v == 0) && (h == 0);
	hs <= (h == 8);
end

endmodule
