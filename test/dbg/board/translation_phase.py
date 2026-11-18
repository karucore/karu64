# OpenOCD software address translation probes. With a pristine OpenOCD this
# phase is expected to FAIL (and exit non-zero): see dbg/BOARD_ACCEPTANCE.md.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
bm.b.close();b=bm.b=Board('translation');bm.prep()
def test():
    b.cmd(f"set board_scratch_page {area('page'):#x}")
    b.cmd('source '+str(SRC/'translation-board.tcl'))
    count=int(b.cmd('set checks'));issues=b.cmd('set board_translation_issues')
    b.require(count>=27,'translation fixtures completed')
    (OUT/'translation-issues.txt').write_text(issues+'\n')
    b.require(not issues,'pristine OpenOCD returned data for rejected mappings: '+issues)
    return {'fixture_checks':count}
b.case('new pristine OpenOCD Sv39/Sv39x4 software walker and hardware controls',test)
sys.exit(b.finish(bm.prep))
