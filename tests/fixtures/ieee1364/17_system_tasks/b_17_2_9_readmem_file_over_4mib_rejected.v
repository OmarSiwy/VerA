// An engine limit, not a language rule: IEEE 1364-2005 §17.2.9 reads a memory
// file of any size. VerA reads it whole and stops at 4 MiB
// (docs/Vague_Decisions.md), so a larger file is refused with a message that
// names the bound, not reported as a file that cannot be read.
//
// /dev/zero is a file every POSIX host has and that never ends, so it stands
// in for a file past any bound without committing one to the tree. Legal
// neighbour: audit_readmem_address_restart.v loads a small file.
// digital-runner: reject
//! reject E1100
//! reject larger than the 4194304 bytes VerA reads
module b_17_2_9_readmem_file_over_4mib_rejected;
  reg [7:0] mem [0:3];
  initial begin
    $readmemh("/dev/zero", mem);
    $display("accepted");
  end
endmodule
