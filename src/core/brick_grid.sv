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
	input  wire [7:0]  near_d,     // caster darkness ~1.35 dots toward the light
	input  wire [7:0]  far_d,      // ...and ~3.24 dots, the broad penumbra
	input  wire [1:0]  sx,         // sub-pixel position inside the cell
	input  wire [1:0]  sy,
	input  wire signed [9:0] grain, // reflector sheet grain, +-127 = +-1
	input  wire [7:0]  grain_k,    // grain contrast; 8 = brickboy's own

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
// finish.paper 0.01 is the TOTAL luminance sigma the profile asks for, against a
// stored grain sigma of 1/3 - so the multiplier is 0.01 / (1/3) = 0.03, i.e.
// grain_k = 8. It is a runtime value because the Pocket's panel resolves less
// low-luminance contrast than the phone the profile was authored on, so the
// same sigma reads weaker there and is worth being able to drive harder.

localparam bit [7:0] LUT_SS_NEAR[0:255] = '{
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd1, 8'd1, 8'd2, 8'd3, 8'd4, 8'd6, 8'd7,
  8'd9, 8'd11, 8'd13, 8'd15, 8'd17, 8'd19, 8'd22, 8'd24, 8'd27, 8'd30, 8'd33, 8'd36, 8'd39, 8'd42, 8'd45, 8'd49,
  8'd52, 8'd56, 8'd60, 8'd63, 8'd67, 8'd71, 8'd75, 8'd79, 8'd83, 8'd87, 8'd91, 8'd95, 8'd99, 8'd104, 8'd108, 8'd112,
  8'd116, 8'd121, 8'd125, 8'd129, 8'd133, 8'd138, 8'd142, 8'd146, 8'd150, 8'd155, 8'd159, 8'd163, 8'd167, 8'd171, 8'd175, 8'd179,
  8'd183, 8'd187, 8'd191, 8'd195, 8'd198, 8'd202, 8'd205, 8'd209, 8'd212, 8'd215, 8'd219, 8'd222, 8'd225, 8'd227, 8'd230, 8'd233,
  8'd235, 8'd238, 8'd240, 8'd242, 8'd244, 8'd246, 8'd247, 8'd249, 8'd250, 8'd251, 8'd252, 8'd253, 8'd254, 8'd255, 8'd255, 8'd255,
  8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255,
  8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255,
  8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255,
  8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255
};

localparam bit [7:0] LUT_SS_FAR[0:255] = '{
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
  8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd1, 8'd1, 8'd2, 8'd2, 8'd3, 8'd4,
  8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10, 8'd12, 8'd13, 8'd15, 8'd17, 8'd18, 8'd20, 8'd22, 8'd24, 8'd26, 8'd28,
  8'd30, 8'd33, 8'd35, 8'd37, 8'd40, 8'd42, 8'd45, 8'd47, 8'd50, 8'd53, 8'd55, 8'd58, 8'd61, 8'd64, 8'd67, 8'd70,
  8'd73, 8'd76, 8'd79, 8'd82, 8'd85, 8'd88, 8'd91, 8'd94, 8'd97, 8'd100, 8'd104, 8'd107, 8'd110, 8'd113, 8'd117, 8'd120,
  8'd123, 8'd126, 8'd130, 8'd133, 8'd136, 8'd139, 8'd143, 8'd146, 8'd149, 8'd152, 8'd156, 8'd159, 8'd162, 8'd165, 8'd168, 8'd171,
  8'd174, 8'd177, 8'd180, 8'd183, 8'd186, 8'd189, 8'd192, 8'd195, 8'd198, 8'd200, 8'd203, 8'd206, 8'd208, 8'd211, 8'd213, 8'd216,
  8'd218, 8'd221, 8'd223, 8'd225, 8'd227, 8'd229, 8'd231, 8'd233, 8'd235, 8'd237, 8'd239, 8'd240, 8'd242, 8'd244, 8'd245, 8'd246,
  8'd248, 8'd249, 8'd250, 8'd251, 8'd252, 8'd252, 8'd253, 8'd254, 8'd254, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255,
  8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255,
  8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255,
  8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255
};

// The shader's body mask at 4x, sampled the way the shader samples it.
//
// This used to hold the INTEGRAL of the smoothstep over each quarter cell
// (153), which is not what the shader computes. The shader widens the
// smoothstep edge to one device pixel - e = max(margin, fwidth(cc)), and at 4x
// fwidth is 0.25 against a margin of 0.20 - then evaluates it POINTWISE at the
// fragment centre. With e = 0.25 and centres at 0.125/0.375/0.625/0.875 that is
// smoothstep(0, 0.25, 0.125) = 0.5 on the leading and trailing sub-pixel.
// Averaging instead of point-sampling shrank the gap and cost about a fifth of
// the grid modulation. Verified against brickboy's own renderfarm harness at 4x
// (tools/bb_render.mjs). Symmetric, so one axis table serves both.
function automatic [7:0] axis_cov(input [1:0] s);
	case (s)
		2'd0: axis_cov = 8'd128;
		2'd1: axis_cov = 8'd255;
		2'd2: axis_cov = 8'd255;
		2'd3: axis_cov = 8'd128;
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

// ---- s0: coverage ------------------------------------------------------------
// The casters arrive already sampled at the two offsets brick_video walks back
// along the light direction; see there. They used to be the IMMEDIATELY
// adjacent cells for both layers, which put the shadow one dot from its caster
// instead of 1.35 and 3.24, and made it fade about three times too fast.
reg [7:0]  body;
reg [23:0] base1;
reg [7:0]  near1, far1;
reg [1:0]  sx1, sy1;

wire [15:0] bodyw = axis_cov(sx) * axis_cov(sy);

always @(posedge clk) begin
	body  <= bodyw[15:8];
	base1 <= cell_rgb;
	near1 <= near_d;
	far1  <= far_d;
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
reg [7:0]  near2, far2;

wire [7:0] lit_r = mix8(BG_R, base1[23:16], 8'd255 - K_BASEA);
wire [7:0] lit_g = mix8(BG_G, base1[15:8],  8'd255 - K_BASEA);
wire [7:0] lit_b = mix8(BG_B, base1[7:0],   8'd255 - K_BASEA);

always @(posedge clk) begin
	body1 <= body;
	base2 <= base1;
	near2 <= near1;
	far2  <= far1;
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

// The shader thresholds the caster's darkness twice - a sharp near umbra and a
// broad, weaker penumbra - and then suppresses the whole thing where the pixel
// is already dark itself. Each threshold gets its OWN caster, sampled at its own
// distance; feeding both from the same adjacent cell (what this did) collapses
// the two layers into one and takes the depth cue with it.
wire [7:0]  ss_near = LUT_SS_NEAR[near2];
wire [7:0]  ss_far  = LUT_SS_FAR[far2];
wire [9:0]  ss_sum  = {2'b0, ss_near} + (({2'b0, ss_far} * 10'd115) >> 8);   // + 0.45x
wire [7:0]  ss_cl   = (ss_sum > 10'd255) ? 8'd255 : ss_sum[7:0];
wire [15:0] amt_w   = ss_cl * K_DROP;

always @(posedge clk) begin
	grid2 <= { mix8(e_gap[23:16], e_dot[23:16], body1),
	           mix8(e_gap[15:8],  e_dot[15:8],  body1),
	           mix8(e_gap[7:0],   e_dot[7:0],   body1) };
	amt2  <= amt_w[15:8];
end

// ---- s2: own-darkness suppression -------------------------------------------
// A pixel that is dark in its own right does not show a shadow on top.
reg [23:0] grid3;
reg [7:0]  amt3;

wire [7:0]  own    = LUT_SS_NEAR[8'd255 - luma8(grid2[23:16], grid2[15:8], grid2[7:0])];
wire [15:0] amt_s  = amt2 * (8'd255 - own);

always @(posedge clk) begin
	grid3 <= grid2;
	amt3  <= amt_s[15:8];
end

// ---- s3: lay the shadow, then the reflector grain ---------------------------
// The grain is a reflectance variation of the sheet seen through the LC, so it
// scales whatever light comes back: plain on the light shades, all but
// invisible in the ink. brick_grain supplies the fine and coarse bands already
// summed; see there for how they are split.
reg [23:0] shad4;
reg signed [9:0] gr4;

wire [23:0] shad_w = { mix8(grid3[23:16], DROP_R, amt3),
                       mix8(grid3[15:8],  DROP_G, amt3),
                       mix8(grid3[7:0],   DROP_B, amt3) };

always @(posedge clk) begin
	shad4 <= shad_w;
	gr4   <= grain;
end

wire [15:0] gm_r = shad4[23:16] * grain_k;
wire [15:0] gm_g = shad4[15:8]  * grain_k;
wire [15:0] gm_b = shad4[7:0]   * grain_k;

function automatic [7:0] grainy(input [7:0] v, input [15:0] scaled, input signed [9:0] g);
	reg signed [27:0] d;
	begin
		// +16384 rounds. A plain arithmetic shift floors, so it biases every
		// negative sample down a level while leaving positives alone - a dark
		// cast that follows the noise, on top of coarser quantisation.
		d = ($signed({12'b0, scaled}) * g + 28'sd16384) >>> 15;
		grainy = sat8($signed({12'b0, v}) + d);
	end
endfunction

always @(posedge clk) begin
	out_rgb <= { grainy(shad4[23:16], gm_r, gr4),
	             grainy(shad4[15:8],  gm_g, gr4),
	             grainy(shad4[7:0],   gm_b, gr4) };
end

endmodule
