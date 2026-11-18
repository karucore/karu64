# Software reboot from Linux (system-control register through OpenSBI).
#
# Needs an image and ROM built after 2026-11-17 and Linux reachable over
# SSH; no OpenOCD. Each cycle checks two separate things:
#
#   Linux restarted   a marker in a tmpfs is gone, the boot ID changed and
#                     the uptime is short. This alone would also be true
#                     after a kexec, so it does not show a hardware reset.
#   through the ROM   the UART capture gained a fu-boot banner followed by
#                     an OpenSBI banner between the request and the return
#                     of SSH. Only a reset to the boot ROM prints those.
#
# The UART capture is the lab's running console log (KARU_BOARD_UART_LOG,
# default _build/boot.log). Without it the second check cannot be made and
# the cycle fails, unless KARU_BOARD_REBOOT_UART=0 asks for the Linux restart
# alone; the result then says that the ROM passage was not checked.
#
# An image without the register halts in OpenSBI and never comes back.
# KARU_BOARD_REBOOT_CYCLES sets the count (default 3) and
# KARU_BOARD_REBOOT_TIMEOUT the seconds allowed per boot (default 900; a
# shutdown and NFS boot took about 440 s on the board), and
# KARU_BOARD_SSH_TIMEOUT the seconds allowed for one SSH command (default
# 180; a connection to the 75 MHz board takes 30 to 55 s).
#
# First run on the board on 2026-11-18: three cycles pass with these
# defaults; the earlier 30 s SSH probe never saw the board come back.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import subprocess

CYCLES=int(setting('KARU_BOARD_REBOOT_CYCLES',3))
TIMEOUT=int(setting('KARU_BOARD_REBOOT_TIMEOUT',900))
SSH_TIMEOUT=int(setting('KARU_BOARD_SSH_TIMEOUT',180))
UART_LOG=Path(setting('KARU_BOARD_UART_LOG',ROOT/'_build/boot.log'))
NEED_UART=setting('KARU_BOARD_REBOOT_UART','1')!='0'
MARKER='/run/karu-reboot-marker'
FUBOOT_BANNER='fu-boot: copying boot chain from ROM'
OPENSBI_BANNER='OpenSBI v'
results=[]

def rom_boot_evidence(text):
    """The OpenSBI banner line that follows a fu-boot banner in console
    text, or None. Both are printed only on the way up from the boot ROM."""
    start=text.find(FUBOOT_BANNER)
    if start<0: return None
    at=text.find(OPENSBI_BANNER,start)
    if at<0: return None
    return text[at:].splitlines()[0].strip()

def ssh(command,timeout=None):
    return subprocess.run(SSH+[command],capture_output=True,text=True,timeout=SSH_TIMEOUT if timeout is None else timeout)

def ssh_up():
    try:
        with socket.create_connection((BOARD_IP,22),timeout=2): pass
        return ssh('true').returncode==0
    except (OSError,subprocess.TimeoutExpired):
        return False

def record(name,ok,detail):
    results.append(dict(name=name,status='PASS' if ok else 'FAIL',detail=detail))
    print(json.dumps(results[-1]),flush=True)
    (OUT/'linux-reboot-results.json').write_text(json.dumps(results,indent=2)+'\n')
    return ok

def cycle(n):
    name=f'reboot {n}'
    if NEED_UART and not UART_LOG.is_file():
        return record(name,False,f'no UART capture at {UART_LOG}: cannot show that the restart goes through the boot ROM')
    console_from=UART_LOG.stat().st_size if UART_LOG.is_file() else 0
    before=ssh(f'touch {MARKER} && cat /proc/sys/kernel/random/boot_id && uname -r')
    if before.returncode: return record(name,False,'board not reachable before the reboot: '+before.stderr.strip())
    boot_id,release=before.stdout.split()[:2]
    start=time.monotonic()
    try: ssh('reboot',timeout=30)          # the connection usually drops; the exit status says nothing
    except subprocess.TimeoutExpired: pass
    down=False
    while time.monotonic()-start<TIMEOUT:
        if not ssh_up(): down=True; break
        time.sleep(1)
    if not down: return record(name,False,f'SSH never went away within {TIMEOUT} s')
    while time.monotonic()-start<TIMEOUT:
        if ssh_up(): break
        time.sleep(5)
    else:
        return record(name,False,f'board did not come back within {TIMEOUT} s (halted in OpenSBI?)')
    after=ssh(f'test ! -e {MARKER} && cat /proc/sys/kernel/random/boot_id && uname -r && cut -d. -f1 /proc/uptime')
    seconds=round(time.monotonic()-start,1)
    if after.returncode: return record(name,False,'marker survived or query failed: '+(after.stdout+after.stderr).strip())
    new_id,new_release,uptime=after.stdout.split()[:3]
    detail=dict(seconds=seconds,uptime=int(uptime),kernel=new_release,boot_id_changed=new_id!=boot_id)
    ok=new_id!=boot_id and new_release==release and int(uptime)<TIMEOUT
    if NEED_UART:
        with UART_LOG.open('rb') as f:
            f.seek(console_from); console=f.read().decode(errors='replace')
        banner=rom_boot_evidence(console)
        detail['rom_boot']=banner or 'no fu-boot and OpenSBI banners on the console since the request'
        ok=ok and banner is not None
    else:
        detail['rom_boot']='not checked (KARU_BOARD_REBOOT_UART=0): shows a Linux restart only'
    return record(name,ok,detail)

def main():
    for n in range(1,CYCLES+1):
        if not cycle(n): break
    failed=[r['name'] for r in results if r['status']!='PASS']
    print(json.dumps(dict(phase='linux-reboot',cases=len(results),failed=failed,
                          rom_boot_checked=NEED_UART)),flush=True)
    return 1 if failed or len(results)!=CYCLES else 0

if __name__=='__main__': sys.exit(main())
