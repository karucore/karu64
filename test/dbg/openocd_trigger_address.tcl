# Shared actual-hart address-trigger behavior, also run on reference Spike.
# SPDX-License-Identifier: BSD-3-Clause
write_memory 0x80007000 32 {0x00100613 0x00c5a023 0x0005a683 0x00160613 0x00c5a023 0x0005a683 0x0000006f}
write_memory 0x80006000 32 {0}
reg a1 0x80006000
reg a2 0
bp 0x80007000 4 hw
resume 0x80007000
wait_halt 2000
check_equal [read_reg_value pc] 0x80007000 "hardware breakpoint before first instruction"
check_equal [read_reg_value a2] 0 "execute breakpoint preserves destination"
rbp 0x80007000
step
check_equal [read_reg_value a2] 1 "step over hardware breakpoint"

wp 0x80006000 4 w
resume
wait_halt 2000
check_equal [read_reg_value pc] 0x80007004 "write watchpoint before store"
check_equal [lindex [read_memory 0x80006000 32 1] 0] 0 "watched store has not occurred"
rwp 0x80006000
step
check_equal [lindex [read_memory 0x80006000 32 1] 0] 1 "resumed store occurs once"

wp 0x80006000 4 r
resume
wait_halt 2000
check_equal [read_reg_value pc] 0x80007008 "read watchpoint before load"
rwp 0x80006000
step
check_equal [read_reg_value a3] 1 "resumed load returns expected data"
step
wp 0x80006000 4 a
resume
wait_halt 2000
check_equal [read_reg_value pc] 0x80007010 "access watchpoint matches write"
rwp 0x80006000
step
wp 0x80006000 4 a
resume
wait_halt 2000
check_equal [read_reg_value pc] 0x80007014 "access watchpoint matches read"
rwp 0x80006000
step
check_equal [read_reg_value a3] 2 "access watchpoint continuation"

