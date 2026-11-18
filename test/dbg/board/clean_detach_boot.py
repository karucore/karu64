# Clean boot after debugging: reset-halt, clear the DCSR EBREAK controls and
# the step bit, resume through raw DMI and shut OpenOCD down. Without this
# the next firmware boot stops at OpenSBI's semihosting probe (see
# dbg/BOARD_ACCEPTANCE.md). Run it against linux-server.cfg.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
b=Board('clean-detach-boot')
def detach():
    for mode in ['m','s','u']: b.cmd(f'riscv set_ebreak{mode} off')
    b.reset_halt();b.cmd('poll off');b.rawwrite(0x7b0,0x403)
    dc=b.rawread(0x7b0);pc=b.rawread(0x7b1)
    b.equal(dc&0x3b000,0,'EBREAK controls clear');b.equal(pc,RESET_PC,'reset-halt DPC')
    b.dmi(0x10,0x40000001);time.sleep(.2)
    status=b.dmi(0x11)
    b.require(status&0xc00==0xc00,'hart running')
    return {'dcsr':hex(dc),'dpc':hex(pc),'dmstatus':hex(status)}
passed=b.case('reset-halt, EBREAK-policy cleanup, raw resume',detach)
try:b.cmd('shutdown')
except (RuntimeError,OSError):pass
sys.exit(b.finish())
