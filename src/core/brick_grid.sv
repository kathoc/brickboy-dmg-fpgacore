// BrickBoy dot structure - the HW form of brickboy's FRAG_GRID.
//
// Runs at the output pixel rate: every raster pixel is one sub-pixel of a 4x4
// cell, so this stage sees each native dot four times across and four down.
//
// What the shader does per fragment and what happens here instead:
//
//   body mask        smoothstep with fwidth prefiltering. The scale is fixed at
//                    4x, so the coverage of each sub-pixel is a compile-time
//                    constant - the 4x4 table below is the integral of the
//                    shader's smoothstep over each quarter of the cell, at
//                    pixel_size 0.80 (margin 0.20). No derivatives needed.
//   gap              bgTint * (1 - shadowOpacity*0.4). The gap shows the
//                    reflector, NOT a dark grid line - darkening it puts a
//                    black lattice over the light shades and reads wrong.
//   grid contrast    (v - 0.5)*0.95 + 0.5, then mixed in by grid.strength 0.62
//   drop shadow      the air gap between the cell layer and the reflector. The
//                    shader samples the pre-grid image toward the light with a
//                    blur, twice (near umbra + broad penumbra). Here the caster
//                    is the neighbouring cell's own darkness, taken from a
//                    3-entry history of native dots - the light is upper-left,
//                    so the caster is up and to the left, which is exactly what
//                    a line buffer already holds.
//
// Not yet: reflector grain (paper) and the printed mask border - the border is
// outside the active area now that the game fills the screen, and the grain
// needs its coarse band baked into RAM. Both are M9.

(* multstyle = "logic" *)
module brick_grid (
	input  wire        clk,

	input  wire [23:0] cell_rgb,   // colour of the dot this sub-pixel belongs to
	input  wire [23:0] up_rgb,     // same column, the native row above
	input  wire [23:0] left_rgb,   // same row, the native dot to the left
	input  wire [23:0] ul_rgb,     // up-left diagonal
	input  wire [1:0]  sx,         // sub-pixel position inside the cell
	input  wire [1:0]  sy,

	output reg  [23:0] out_rgb
);

// grid.bgTint x255, and the gap value it produces at shadowOpacity 0.6:
//   gap = bgTint * (1 - 0.6*0.4) = bgTint * 0.76
localparam [7:0] GAP_R = 8'd180, GAP_G = 8'd165, GAP_B = 8'd113;
localparam [7:0] BG_R  = 8'd237, BG_G  = 8'd217, BG_B  = 8'd149;

localparam [7:0] K_BASEA  = 8'd26;    // baselineAlpha 0.10
localparam [7:0] K_GRIDC  = 8'd243;   // grid contrast 0.95
localparam [7:0] K_STR    = 8'd159;   // grid strength 0.62
localparam [7:0] K_DROP   = 8'd87;    // shadowOpacity 0.34
// shadowColor [0.397, 0.391, 0.222] x255
localparam [7:0] DROP_R = 8'd101, DROP_G = 8'd100, DROP_B = 8'd57;

// Integral of the shader's smoothstep over each quarter of the cell at
// pixel_size 0.80. Symmetric, so one axis table serves both.
function automatic [7:0] axis_cov(input [1:0] s);
	case (s)
		2'd0: axis_cov = 8'd153;
		2'd1: axis_cov = 8'd255;
		2'd2: axis_cov = 8'd255;
		2'd3: axis_cov = 8'd153;
	endcase
endfunction

function automatic [7:0] mix8(input [7:0] a, input [7:0] b, input [7:0] k);
	reg signed [17:0] d;
	begin
		d = ($signed({1'b0, b}) - $signed({1'b0, a})) * $signed({1'b0, k});
		mix8 = a + d[15:8];
	end
endfunction

function automatic [7:0] sat8(input signed [19:0] v);
	sat8 = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
endfunction

function automatic [7:0] luma8(input [7:0] r, input [7:0] g, input [7:0] b);
	reg [16:0] t;
	begin
		t = 17'd77*r + 17'd150*g + 17'd29*b;
		luma8 = t[15:8];
	end
endfunction

// contrast around mid grey
function automatic [7:0] gcon(input [7:0] v);
	reg signed [19:0] t;
	begin
		t = ((($signed({1'b0, v}) - 20'sd128) * $signed({1'b0, K_GRIDC})) >>> 8) + 20'sd128;
		gcon = sat8(t);
	end
endfunction

// ---- s0: coverage and the shadow caster --------------------------------------
reg [7:0]  body;
reg [23:0] base1, cast1;
reg [1:0]  sx1, sy1;

wire [15:0] bodyw = axis_cov(sx) * axis_cov(sy);

// Light upper-left: the shadow falling on this sub-pixel comes from the cell
// up and/or left of it. Only the leading sub-pixels of a cell can be shadowed,
// which is what gives the offset its direction.
wire top  = (sy == 2'd0);
wire lft  = (sx == 2'd0);
wire [23:0] caster = (top && lft) ? ul_rgb : top ? up_rgb : lft ? left_rgb : cell_rgb;

always @(posedge clk) begin
	body  <= bodyw[15:8];
	base1 <= cell_rgb;
	cast1 <= caster;
	sx1 <= sx; sy1 <= sy;
end

// ---- s1: the two endpoints of the cell ---------------------------------------
// The gridded colour is a straight interpolation between "all gap" and "all
// dot" by the coverage, and both endpoints already have the contrast and the
// grid strength folded in. Computing them per cell instead of per sub-pixel
// takes this stage from nine multiplies to three.
reg [23:0] e_gap, e_dot;
reg [7:0]  body1;
reg [23:0] base2;
reg [7:0]  cast_d1;

wire [7:0] lit_r = mix8(BG_R, base1[23:16], 8'd255 - K_BASEA);
wire [7:0] lit_g = mix8(BG_G, base1[15:8],  8'd255 - K_BASEA);
wire [7:0] lit_b = mix8(BG_B, base1[7:0],   8'd255 - K_BASEA);

always @(posedge clk) begin
	body1 <= body;
	base2 <= base1;
	cast_d1 <= 8'd255 - luma8(cast1[23:16], cast1[15:8], cast1[7:0]);
	e_gap <= { mix8(base1[23:16], gcon(GAP_R), K_STR),
	           mix8(base1[15:8],  gcon(GAP_G), K_STR),
	           mix8(base1[7:0],   gcon(GAP_B), K_STR) };
	e_dot <= { mix8(base1[23:16], gcon(lit_r), K_STR),
	           mix8(base1[15:8],  gcon(lit_g), K_STR),
	           mix8(base1[7:0],   gcon(lit_b), K_STR) };
end

// ---- s1b: coverage blend + shadow amount -------------------------------------
reg [23:0] grid2;
reg [7:0]  amt2;

wire [15:0] amtw = cast_d1 * (8'd255 - body1);

always @(posedge clk) begin
	grid2 <= { mix8(e_gap[23:16], e_dot[23:16], body1),
	           mix8(e_gap[15:8],  e_dot[15:8],  body1),
	           mix8(e_gap[7:0],   e_dot[7:0],   body1) };
	amt2  <= (amtw[15:8] * K_DROP) >> 8;
end

// ---- s2: lay the shadow ------------------------------------------------------
always @(posedge clk) begin
	out_rgb <= { mix8(grid2[23:16], DROP_R, amt2),
	             mix8(grid2[15:8],  DROP_G, amt2),
	             mix8(grid2[7:0],   DROP_B, amt2) };
end

endmodule
