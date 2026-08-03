// Reflector sheet grain - brickboy's reflector.ts, split by band.
//
// reflector.ts bakes three bands into one texture at 4 texels per dot:
//
//   fine   ~0.45 dot   the わら半紙 read, sigma 0.307 of full scale
//   mottle ~5 dots     evaluated once per dot and bilinearly expanded
//   blotch ~18 dots    likewise, at half weight
//
// The whole module at 4 texels/dot is 3.2 Mbit - more than this device has - so
// the bands are split the way reflector.ts already splits them internally:
//
//   fine    generated at runtime, one hash per 2x2 output pixels. reflector.ts
//           uses two decorrelated value-noise octaves at 0.45 and 0.77 dot; a
//           blocky hash at 0.5 dot has the same feature size and the same sigma,
//           and at 0.11 mm on the Pocket's panel the difference is well under
//           what the panel resolves.
//   coarse  baked by tools/bake_grain.py using reflector.ts's own hash2/vnoise/
//           fbm and seed, on a lattice every 4 dots, bilinearly interpolated
//           here exactly as reflector.ts interpolates its per-dot `coarse`.
//
// What this replaces: one independent hash per OUTPUT pixel and no coarse band
// at all. That is white noise - it averages away completely over any area, so
// on the Pocket it read as no grain at all, while brickboy's stays visible.
// Measured on brickboy's own renderfarm output at 4x: the per-dot grain sigma is
// 0.87% of mean and still 0.52% after averaging over 16x16 dots. White noise
// would be 0.05%. The surviving 60% is the coarse band, and it was missing.
//
// The grain field is not registered to the dot grid - it is a separate physical
// sheet behind the LC - so the pipeline delay through here does not need to line
// up with the grid stage to the pixel.

module brick_grain (
	input  wire        clk,
	input  wire [9:0]  gx,      // output pixel within the game area, 0..639
	input  wire [9:0]  gy,      // 0..575
	input  wire [7:0]  seed,
	output reg  signed [8:0] g  // +-127 = +-1 of the stored grain range
);

`include "brick_grain_coarse.svh"

localparam int COLS = 41;      // lattice columns; 160 dots / 4 + 1
// Scales the uniform hash so the fine band matches reflector.ts's sigma at the
// DOT, not at the texel: the hash's 2x2 blocks are independent where value noise
// is correlated, so it would otherwise fade faster than the original under any
// averaging - and sub-dot detail is below what the Pocket's panel resolves
// anyway. tools/bake_grain.py prints this number.
localparam [8:0] K_FINE = 9'd167;

// ---- s0: lattice address and the fine hash's first mix ----------------------
// One lattice step is 4 dots = 16 output pixels, so the cell index is gx[9:4]
// and the interpolation weight is gx[3:0].

wire [5:0] cx = gx[9:4];
wire [5:0] cy = gy[9:4];
wire [3:0] fx = gx[3:0];
wire [3:0] fy = gy[3:0];

// cy * 41 = cy<<5 + cy<<3 + cy
wire [11:0] rowbase = {cy, 5'b0} + {cy, 3'b0} + cy;

reg [11:0] a0, a1;
reg [3:0]  fx1, fy1;

// reflector.ts hash2, on the 2x2 output-pixel block.
wire [31:0] hseed = seed * 32'd1442695041;
wire [31:0] hmix  = {22'b0, gx[9:1]} * 32'd374761393
                  + {22'b0, gy[9:1]} * 32'd668265263 + hseed;

reg [31:0] h1;

always @(posedge clk) begin
	a0  <= rowbase + cx;
	a1  <= rowbase + cx + 12'd1;
	fx1 <= fx;
	fy1 <= fy;
	h1  <= hmix ^ (hmix >> 13);
end

// ---- s1: both lattice columns, and the hash's second mix -------------------
// Two copies so the left and right lattice columns come out in the same cycle;
// one array with two read ports turns the ROM into logic. Each word holds the
// two lattice ROWS the bilinear needs: {row cy+1, row cy}.
// 36 lattice rows of PAIRS (576 output rows / 16), each word carrying rows
// cy and cy+1, so the 37th lattice row lives in the last word's high half.
reg [15:0] rom_a[0:COLS*36-1];
reg [15:0] rom_b[0:COLS*36-1];
initial begin
	rom_a = GRAIN_COARSE;
	rom_b = GRAIN_COARSE;
end

reg [15:0] q0, q1;
reg [3:0]  fx2, fy2;
reg [31:0] h2;

always @(posedge clk) begin
	q0  <= rom_a[a0];
	q1  <= rom_b[a1];
	fx2 <= fx1;
	fy2 <= fy1;
	h2  <= h1 * 32'd1274126177;
end

// ---- s2: interpolate down the two columns, and finish the hash -------------
wire signed [8:0] c00 = {q0[7],  q0[7:0]};    // row cy,   column cx
wire signed [8:0] c01 = {q0[15], q0[15:8]};   // row cy+1, column cx
wire signed [8:0] c10 = {q1[7],  q1[7:0]};
wire signed [8:0] c11 = {q1[15], q1[15:8]};

function automatic signed [8:0] lerp4(input signed [8:0] a,
                                      input signed [8:0] b,
                                      input [3:0] f);
	reg signed [13:0] d;
	begin
		d = ($signed(b) - $signed(a)) * $signed({1'b0, f});
		lerp4 = a + d[12:4];
	end
endfunction

reg signed [8:0] cl, cr;
reg [3:0]        fx3;
reg [31:0]       h3;

always @(posedge clk) begin
	cl  <= lerp4(c00, c01, fy2);
	cr  <= lerp4(c10, c11, fy2);
	fx3 <= fx2;
	h3  <= h2 ^ (h2 >> 16);
end

// ---- s3: interpolate across, add the fine band -----------------------------
wire signed [8:0]  coarse = lerp4(cl, cr, fx3);
wire signed [8:0]  fine   = $signed({1'b0, h3[31:24]}) - 9'sd128;
wire signed [17:0] fine_s = fine * $signed({1'b0, K_FINE});
wire signed [10:0] sum    = coarse + fine_s[16:8];

always @(posedge clk) begin
	g <= (sum >  11'sd127) ?  9'sd127 :
	     (sum < -11'sd127) ? -9'sd127 : sum[8:0];
end

endmodule
