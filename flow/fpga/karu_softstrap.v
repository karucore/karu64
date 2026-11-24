//	karu_softstrap.v
//	=== A one-bit strap that lives in the bitstream, not on a pin.
//
//	The output is a constant, VALUE, held in a look-up table that synthesis
//	must not touch. Logic that reads it is built for both values. The value
//	can therefore be changed in the routed design by setting the table's
//	INIT, with nothing placed or routed again (flow/fpga/strap_variant.tcl,
//	make vcu118-strap-variant): two images that differ in a strap have the
//	same placement and the same routing, wire for wire. That matters for the
//	ring oscillators of the entropy source, whose frequencies follow their
//	routing: a measurement made on one variant describes the rings of the
//	other.
//
//	A strap is static. It is not a register and has no reset; software
//	cannot change it.
//
//	SIM = 1: a plain constant, for simulation without the vendor's cells.
//	SPDX-License-Identifier: BSD-2-Clause

module karu_softstrap #(
	parameter integer SIM   = 0,
	parameter [0:0]   VALUE = 1'b0
) (
	output wire o
);
	generate if (SIM == 0) begin : g_lut
		//	O = INIT[I0], and I0 is 0: bit 0 of INIT is the value. Both bits
		//	are set alike, so the value does not depend on the input.
		(* DONT_TOUCH = "true" *) LUT1 #(.INIT(VALUE ? 2'b11 : 2'b00)) strap (.I0(1'b0), .O(o));
	end else begin : g_sim
		assign o = VALUE;
	end endgenerate
endmodule
