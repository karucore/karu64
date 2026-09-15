// Physical access permissions for the standard Karu address map.
// Included inside modules (no include guard: each needs its own function).
// Integrations with another map supply karu_pma_ok and karu_pma_io via
// KARU_PMA_CUSTOM_HEADER. Regions must have 4 KiB-aligned boundaries: the
// vector translator caches permissions by page. Check the full PA before
// narrowing it to the 32-bit AXI bus. Slave errors remain authoritative.
`ifdef KARU_PMA_CUSTOM_HEADER
`include `KARU_PMA_CUSTOM_HEADER
`else
// Physical devices are non-idempotent IO unless a nonzero PBMT overrides
// that attribute. Ordinary loads/stores keep native access widths and never
// touch inactive bytes. CBO.ZERO instead zeros its complete aligned 64-byte
// block with eight 8-byte writes; software must not use it on device registers.
function automatic karu_pma_io(input [63:0] a);
    begin
        karu_pma_io = (a[63:32] == 0) &&
            (a[31:16] == 16'h0200 ||   // CLINT
             a[31:24] == 8'h0c ||     // PLIC
             a[31:12] == 20'h10000 || // UART
             a[31:20] == 12'h110 ||   // Ethernet
             a[31:12] == 20'h12000);  // SPI flash controller
    end
endfunction
function automatic karu_pma_ok(input [63:0] a, input [1:0] acc);
    reg ram, rom, scratch, device;
    begin
        ram = a[31];                         // 0x80000000..0xffffffff
        rom = a[31:12] >= 20'h00001 && a[31:12] < 20'h00101;
        scratch = a[31:12] >= 20'h00101 && a[31:12] < 20'h00111;
        device = karu_pma_io(a);
        // acc: fetch=0, load=1, store/AMO=2, CBO read-or-write=3.
        karu_pma_ok = (a[63:32] == 0) &&
            (ram || scratch || (rom && acc != 2) || (device && acc != 0));
    end
endfunction
`endif
