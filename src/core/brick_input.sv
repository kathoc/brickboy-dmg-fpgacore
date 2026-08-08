// Pad behaviour: X/Y auto-fire, and brickboy's 4-way D-pad.
//
// AUTO-FIRE
// brickboy's A/B REPEAT holds the button, waits 500 ms, then toggles 33 ms on /
// 33 ms off - about 15 Hz. Here it is TURBO only: the same 15 Hz, but firing
// from the moment the button goes down. The 500 ms variant was a menu entry and
// was spent on the panel-colour switch instead - REPEAT's initial delay only
// makes sense for a key that also has to type one character, and X/Y do not.
//
// X drives A and Y drives B, so the plain A/B buttons keep working normally
// alongside them.
//
// 4-WAY
// No diagonals ever, newest press wins. See the 4-way section below for why the
// second half of brickboy's rule does not carry over to a physical pad.

module brick_input (
	input  wire        clk,          // 33.554432 MHz
	input  wire        reset,

	input  wire        four_way,     // 0 = 8-way, 1 = brickboy's 4-way

	// raw pad, APF cont1_key order
	input  wire        k_up, k_down, k_left, k_right,
	input  wire        k_a,  k_b,    k_x,    k_y,

	output wire        o_up, o_down, o_left, o_right,
	output wire        o_a,  o_b
);

// 33.554432 MHz: 15 Hz is 30 half-cycles a second.
localparam int HALF_TICKS = 33554432 / 30;     // 1,118,481 - 33.3 ms

// ------------------------------------------------------------- auto-fire ---
// One generator per button so X and Y are independent; each starts its own
// clock on its own press, which is what makes tapping feel right.

// Held low, the counter is parked at 0 with the output asserted, so the very
// first press fires on the same cycle - that immediacy IS turbo.
// X
reg [20:0] cx;
reg        px;
always @(posedge clk) begin
	if (reset || !k_x)             begin cx <= 0; px <= 1'b1; end
	else if (cx == HALF_TICKS - 1) begin cx <= 0; px <= ~px;  end
	else                                 cx <= cx + 1'd1;
end

// Y
reg [20:0] cy;
reg        py;
always @(posedge clk) begin
	if (reset || !k_y)             begin cy <= 0; py <= 1'b1; end
	else if (cy == HALF_TICKS - 1) begin cy <= 0; py <= ~py;  end
	else                                 cy <= cy + 1'd1;
end

assign o_a = k_a | (k_x & px);
assign o_b = k_b | (k_y & py);

// ---------------------------------------------------------------- 4-way ---
// Never emit a diagonal; the most RECENTLY pressed direction owns the pad.
//
// brickboy's four-way mode is an angular model for a touch pad: each cardinal
// owns its quadrant (CARD_HALF_4WAY = 45) so no diagonal can be produced at
// all, and it also resists CHANGING direction much harder (R_COMMIT_4WAY =
// 1.6). The first rule is the point of the mode and ports directly. The second
// does not: it exists because a thumb DRIFTS on glass during a long walk, and a
// physical cross-pad has no drift to defend against. Carrying it over would
// only make the pad feel like it was ignoring presses, so the newest press wins
// instead - which is also what a real four-way restrictor does, since pushing a
// new direction physically lifts the lever out of the old one.
localparam bit [1:0] D_U = 2'd0, D_D = 2'd1, D_L = 2'd2, D_R = 2'd3;

wire [3:0] raw = {k_right, k_left, k_down, k_up};

reg  [3:0] raw_r;
wire [3:0] pressed = raw & ~raw_r;      // this clock's new presses

reg [1:0] held;
reg       have;

wire held_down = have && raw[held];

always @(posedge clk) begin
	raw_r <= raw;
	if (reset || raw == 4'd0) begin
		have <= 1'b0;
	end else if (pressed != 4'd0) begin
		// Newest press takes the pad. Two in one clock is a tie no input device
		// can actually produce; resolve it in a fixed order so it is at least
		// deterministic.
		have <= 1'b1;
		held <= pressed[0] ? D_U : pressed[1] ? D_D : pressed[2] ? D_L : D_R;
	end else if (!held_down) begin
		// The owner let go while something else is still down - fall back to it.
		have <= 1'b1;
		held <= raw[0] ? D_U : raw[1] ? D_D : raw[2] ? D_L : D_R;
	end
end

wire f_up    = have && (held == D_U);
wire f_down  = have && (held == D_D);
wire f_left  = have && (held == D_L);
wire f_right = have && (held == D_R);

assign o_up    = four_way ? f_up    : k_up;
assign o_down  = four_way ? f_down  : k_down;
assign o_left  = four_way ? f_left  : k_left;
assign o_right = four_way ? f_right : k_right;

endmodule
