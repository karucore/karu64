# Hardware execute breakpoint in the live kernel at a high canonical VA.
# The address is that of KARU_BOARD_KERNEL_BP_SYMBOL (default
# __riscv_sys_getpid) in System.map of the local kernel build, which must be
# the build of the served Image: the two Images are compared first. The live
# instruction bytes at the computed physical address are then compared with
# the Image before the trigger is installed, which also checks the assumed
# load address. KARU_BOARD_KERNEL_BP_VA overrides the lookup. Shuts OpenOCD
# down at the end.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import subprocess,hashlib,struct
b=Board('linux-high-va')
SYMBOL=setting('KARU_BOARD_KERNEL_BP_SYMBOL','__riscv_sys_getpid')
LOCAL_IMAGE=Path(setting('KARU_BOARD_KERNEL_IMAGE',KERNEL_BUILD/'arch/riscv/boot/Image'))
VA=PA=None
def kernel_bp():
    global VA,PA
    image=TFTP_IMAGE.read_bytes()
    local=LOCAL_IMAGE.read_bytes()
    b.equal(hashlib.sha256(image).hexdigest(),hashlib.sha256(local).hexdigest(),'matching kernel Image')
    if os.environ.get('KARU_BOARD_KERNEL_BP_VA'):
        VA=int(os.environ['KARU_BOARD_KERNEL_BP_VA'],0)
        PA=int(setting('KARU_BOARD_KERNEL_BP_PA',KERNEL_LOAD_PA+(VA&0x7fffffff)),0)
    else: VA,PA=kernel_symbol(SYMBOL)
    offset=PA-KERNEL_LOAD_PA
    b.require(0<=offset<len(image)-32,'breakpoint address inside the Image')
    b.halt();dcsr=b.rr('dcsr');satp=b.rr('satp')
    actual=b.read(PA,16,16,'sysbus')
    b.equal(b''.join(struct.pack('<H',x) for x in actual),image[offset:offset+32],'live kernel instruction bytes')
    b.cmd(f'bp {VA:#x} {insn_length(image,offset)} hw')
    child=None
    try:
        b.resume()
        log=(OUT/'linux-kernel-bp-workload.log').open('w')
        child=subprocess.Popen(SSH+['/bin/sh -c \'echo KERNEL_HWBP_SYSCALL_OK\''],stdout=log,stderr=subprocess.STDOUT)
        b.cmd('wait_halt 20000')
        b.equal(b.rr('pc'),VA,'canonical kernel VA hardware breakpoint')
        b.equal((b.rr('dcsr')>>6)&7,2,'kernel execute-trigger cause')
        b.equal(b.rr('dcsr')&3,1,'kernel stopped in S mode')
        hit_satp=b.rr('satp'); b.equal(hit_satp>>60,8,'kernel uses Sv39 at breakpoint')
        b.equal(b.rr('satp'),hit_satp,'debug register reads preserve halted SATP')
        b.cmd(f'rbp {VA:#x}');b.resume()
        return {'symbol':SYMBOL,'kernel':kernel_release(),'virtual_pc':hex(VA),'physical_bytes_verified':hex(PA),'satp_before_run':hex(satp),'satp_at_breakpoint':hex(hit_satp)}
    finally:
        try:b.cmd(f'rbp {VA:#x}')
        except (RuntimeError,TypeError):pass
        b.halt();b.cmd('riscv exec_progbuf 0x13');b.cmd('poll off')
        dc=b.rawread(0x7b0);b.rawwrite(0x7b0,dc&~0x3b004);b.dmi(0x10,0x40000001)
        time.sleep(.05);b.require(b.dmi(0x11)&0xc00==0xc00,'Linux running after final detach')
        try:b.cmd('shutdown')
        except (OSError,RuntimeError):pass
        if child is not None:
            try:child.wait(timeout=120)
            except subprocess.TimeoutExpired:child.terminate();child.wait(timeout=10)
            log.close()
b.case('live Linux high-canonical kernel hardware breakpoint and continuation',kernel_bp)
sys.exit(b.finish())
