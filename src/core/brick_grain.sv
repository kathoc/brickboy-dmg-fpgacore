// Reflector sheet grain generator.
//
// The integer hash is brickboy's own (reflector.ts hash2): the same xorshift /
// multiply mix, so one seed gives one console's sheet. brickboy bakes a texture
// because evaluating noise per fragment costs a GPU ~28 hashes; here a single
// hash per output pixel is nearly free, and at 4x upscale one output pixel sits
// at the measured feature size of the dominant fine band (0.3-0.5 dot), which
// is the band the docs call the わら半紙 read.
//
// The two slower bands (mottle ~5 dots, blotch ~18 dots) are not generated.
// They carry a third of the weight and overlap finish.gradient, which is a
// separate low-frequency term.

module brick_grain (
	input  wire        clk,
	input  wire [9:0]  x,
	input  wire [9:0]  y,
	input  wire [7:0]  seed,
	output reg  [7:0]  g       // 128 = flat
);

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

reg [31:0] h1;
always @(posedge clk) begin
	h1 <= {6'b0, y, 6'b0, x} * 32'h9e3779b9 ^ {16'b0, seed, 8'b0};
	g  <= mix32(h1) >> 24;
end

endmodule
