// Map Yosys latch primitives to Nangate45 latch cells.

module $_DLATCH_P_ (input E, input D, output Q);
  DLH_X1 _TECHMAP_REPLACE_ (
    .G(E),
    .D(D),
    .Q(Q)
  );
endmodule

module $_DLATCH_N_ (input E, input D, output Q);
  DLL_X1 _TECHMAP_REPLACE_ (
    .GN(E),
    .D(D),
    .Q(Q)
  );
endmodule
