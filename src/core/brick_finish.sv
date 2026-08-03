// Screen-space finish - the HW form of brickboy's FRAG_PASSTHROUGH.
//
// The last pass in brickboy's chain lays three screen-space terms over the
// finished panel. They are what a reflective panel under room light actually
// looks like, and leaving them out is why this port came out uniformly darker
// than brickboy and why its reflector grain vanished at a distance:
//
//   gradient  brighter toward the reflection source at module-uv (0.30, 0.72),
//             +-8%. This is the term that was missing: it is worth ~3% at the
//             centre of the screen, and it is most of the low-frequency
//             variation that survives when the eye averages the grain.
//   vignette  corner darkening, 8% at the corners, 0 at the centre.
//   grain     a matte luma grain, one hash per output pixel, +-1.2% added
//             equally to all channels. White noise by design - it is the
//             viewer's screen, not the console's reflector sheet, so it does
//             NOT get the coarse bands brick_grain carries.
//
//     prox = 1 - clamp(distance(vUv, SHEEN_CENTER), 0, 1)
//     col *= 1 + uGradient * (prox - 0.5) * 2
//     col *= 1 - uVignette * dot(vUv - 0.5, vUv - 0.5) * 2
//     col += (hash21(floor(vUv * uResolution)) - 0.5) * uGrain
//
// Computed arithmetically rather than from a table: a lattice ROM would have
// been simpler, but M10K is the resource this design is short of and DSP is
// not. Coordinates are module-uv - brickboy renders the whole 168 x 152 module
// and the Pocket only shows the 160 x 144 dot field, so the game area sits at
// (16, 16) of 672 x 608 output pixels.

module brick_finish (
	input  wire        clk,
	input  wire [9:0]  gx,          // output pixel within the game area
	input  wire [9:0]  gy,
	input  wire [23:0] in_rgb,
	output reg  [23:0] out_rgb
);

localparam [15:0] CX = 16'd19661;   // 0.30 in Q0.16
localparam [15:0] CY = 16'd47186;   // 0.72
localparam [15:0] HALF = 16'd32768;

// 65536 / 672 and 65536 / 608, as Q6.10 multipliers
localparam [16:0] SX = 17'd99864;   // 97.5238 * 1024
localparam [16:0] SY = 17'd110376;  // 107.7895 * 1024

localparam [15:0] K_GRAD = 16'd10486;   // 0.08 * 2 in Q0.16
localparam [15:0] K_VIGN = 16'd10486;   // 0.08 * 2
localparam [7:0]  K_FGRAIN = 8'd3;      // 0.012 * 255

// sqrt(x) for x in [0,1), Q0.16 in and out, indexed by the top 8 bits.
localparam bit [15:0] LUT_SQRT[0:255] = '{
`include "brick_sqrt.svh"
};

// ---- s0: module-uv ----------------------------------------------------------
// vUv.y is measured up from the bottom, so the flip is folded in here.
reg [15:0] ux, uy;
reg [23:0] c0;
reg [9:0]  x0, y0;

wire [26:0] uxw = ({17'd0, gx} + 27'd16) * SX;
wire [26:0] uyw = ({17'd0, gy} + 27'd16) * SY;

always @(posedge clk) begin
	ux <= uxw[25:10];
	uy <= 16'd65535 - uyw[25:10];
	c0 <= in_rgb;
	x0 <= gx; y0 <= gy;
end

// ---- s1: the two squared distances ------------------------------------------
reg [31:0] r2_sheen, r2_centre;
reg [23:0] c1;
reg [9:0]  x1, y1;

wire signed [16:0] dx = $signed({1'b0, ux}) - $signed({1'b0, CX});
wire signed [16:0] dy = $signed({1'b0, uy}) - $signed({1'b0, CY});
wire signed [16:0] vx = $signed({1'b0, ux}) - $signed({1'b0, HALF});
wire signed [16:0] vy = $signed({1'b0, uy}) - $signed({1'b0, HALF});

always @(posedge clk) begin
	r2_sheen  <= dx * dx + dy * dy;
	r2_centre <= vx * vx + vy * vy;
	c1 <= c0;
	x1 <= x0; y1 <= y0;
end

// ---- s2: distance, and the two scale terms ----------------------------------
reg signed [17:0] grad2, vign2;
reg [23:0] c2;
reg [9:0]  x2, y2;

// r2 is Q0.32 of a value that never exceeds 1.0 here, so the top 16 bits are
// Q0.16. Saturate anyway - the shader clamps the distance to 1.
wire [15:0] r2s = (r2_sheen[31:16] > 16'd65535) ? 16'd65535 : r2_sheen[31:16];
wire [15:0] sqdist = LUT_SQRT[r2s[15:8]];
wire signed [17:0] prox = 18'sd65536 - $signed({2'b0, sqdist});

wire signed [33:0] gradw = (prox - 18'sd32768) * $signed({2'b0, K_GRAD});
wire [31:0]        vignw = r2_centre[31:16] * K_VIGN;

always @(posedge clk) begin
	grad2 <= gradw[33:16];
	vign2 <= $signed({2'b0, vignw[31:16]});
	c2 <= c1;
	x2 <= x1; y2 <= y1;
end

// ---- s3: apply ---------------------------------------------------------------
// One factor for all three channels, then the matte grain added equally.
reg signed [17:0] fac3;
reg [23:0] c3;
reg signed [9:0] fg3;

function automatic [31:0] mix32(input [31:0] v);
	reg [31:0] t;
	begin
		t = v ^ (v >> 16);
		t = t * 32'h7feb352d;
		t = t ^ (t >> 15);
		t = t * 32'h846ca68b;
		mix32 = t ^ (t >> 16);
	end
endfunction

wire [31:0] fh = mix32({6'b0, y2, 6'b0, x2} ^ 32'h5bd1e995);

always @(posedge clk) begin
	fac3 <= 18'sd65536 + grad2 - vign2;
	c3   <= c2;
	fg3  <= $signed({2'b0, fh[31:24]}) - 10'sd128;
end

function automatic [7:0] sat8(input signed [19:0] v);
	sat8 = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
endfunction

function automatic [7:0] apply(input [7:0] v, input signed [17:0] f,
                               input signed [9:0] g);
	reg signed [27:0] p;
	reg signed [19:0] q;
	begin
		p = $signed({10'b0, v}) * f + 28'sd32768;
		q = $signed(p[27:16]) + (($signed({10'b0, K_FGRAIN}) * g) >>> 7);
		apply = sat8(q);
	end
endfunction

always @(posedge clk) begin
	out_rgb <= { apply(c3[23:16], fac3, fg3),
	             apply(c3[15:8],  fac3, fg3),
	             apply(c3[7:0],   fac3, fg3) };
end

endmodule
