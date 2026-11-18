# Shared client for the physical-board debug acceptance phases.
#
# Each phase script talks to an already running OpenOCD through its Tcl RPC
# port and records every command and every case result. The harness sources
# live here (SRC); everything a run writes goes to the artifact directory
# (OUT), which is also where the fixture built from payload.S is expected.
#
# Host-specific settings come from the environment, with the lab defaults:
#
#   KARU_BOARD_OUT          artifact directory   (_build/dbg/board-accept)
#   KARU_BOARD_RPC          OpenOCD Tcl RPC      (127.0.0.1:6666)
#   KARU_BOARD_GDB_REMOTE   OpenOCD GDB server   (127.0.0.1:3333)
#   KARU_BOARD_GDB          GDB binary           ($RISCV/bin/riscv64-unknown-elf-gdb)
#   KARU_BOARD_IP           board Linux address  (192.168.42.10)
#   KARU_BOARD_SSH_KEY      lab SSH key          (../karudeb/configs/ssh/karudeb_lab_ed25519)
#   KARU_BOARD_KARUDEB      karudeb checkout     (../karudeb)
#   KARU_BOARD_TFTP_IMAGE   served kernel Image  (/srv/tftp/Image)
#   KARU_BOARD_KERNEL_BUILD kernel build tree    (karudeb's build/linux-riscv64-karu64-rva23s64)
#   KARU_BOARD_KERNEL_LOAD_PA  where _start is loaded (0x80200000)
#   KARU_BOARD_REMOTE_DIR   directory on board   (/root/debug-accept)
#
# The image under test decides where the scratch SRAM is and where the hart
# starts; see IMAGES below. The fixture has to be built for the same map:
#
#   KARU_BOARD_IMAGE        image kind: rom2m-auth, rom2m, rom1m or sim   (rom2m-auth)
#   KARU_BOARD_SCRATCH      scratch SRAM base, in place of the image kind's
#   KARU_BOARD_SCRATCH_SIZE scratch SRAM size, in place of 64 KiB
#   KARU_BOARD_RESET_PC     reset vector, in place of the image kind's
#
# Nothing here names a kernel version: the expected release and kernel symbol
# addresses are read from the kernel build tree that produced the served Image.
#
# The OpenOCD configurations (server.cfg, linux-server.cfg) take the adapter
# from KARU_BOARD_ADAPTER_CFG and the ports from the same variables.
# SPDX-License-Identifier: BSD-2-Clause
import datetime, json, os, shutil, socket, sys, time, traceback, tkinter
from pathlib import Path

SRC = Path(__file__).resolve().parent
ROOT = SRC.parents[2]

def setting(name, default):
    return os.environ.get(name) or str(default)

OUT = Path(setting('KARU_BOARD_OUT', ROOT/'_build/dbg/board-accept')).resolve()
OUT.mkdir(parents=True, exist_ok=True)
RPC_HOST, _, RPC_PORT = setting('KARU_BOARD_RPC', '127.0.0.1:6666').rpartition(':')
GDB_REMOTE = setting('KARU_BOARD_GDB_REMOTE', '127.0.0.1:3333')
GDB = setting('KARU_BOARD_GDB', Path(os.environ['RISCV'])/'bin/riscv64-unknown-elf-gdb'
              if os.environ.get('RISCV') else (shutil.which('riscv64-unknown-elf-gdb') or 'riscv64-unknown-elf-gdb'))
BOARD_IP = setting('KARU_BOARD_IP', '192.168.42.10')
KARUDEB = Path(setting('KARU_BOARD_KARUDEB', ROOT.parent/'karudeb'))
SSH_KEY = setting('KARU_BOARD_SSH_KEY', KARUDEB/'configs/ssh/karudeb_lab_ed25519')
TFTP_IMAGE = Path(setting('KARU_BOARD_TFTP_IMAGE', '/srv/tftp/Image'))
KERNEL_BUILD = Path(setting('KARU_BOARD_KERNEL_BUILD', KARUDEB/'build/linux-riscv64-karu64-rva23s64'))
KERNEL_LOAD_PA = int(setting('KARU_BOARD_KERNEL_LOAD_PA', '0x80200000'), 0)
REMOTE_DIR = setting('KARU_BOARD_REMOTE_DIR', '/root/debug-accept')
SSH = ['ssh', '-i', SSH_KEY, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=60',
       '-o', 'KexAlgorithms=curve25519-sha256', 'root@'+BOARD_IP]

# ---- the image under test: memory map and reset vector ----
# The 64 KiB scratch SRAM (read/write/execute) starts directly above the
# boot ROM (rtl/karu_bootmap.vh), and the hart starts at the RESET_PC of
# flow/fpga/vcu118_ddr_top.v. Neither is the same for every image:
#
#   rom2m-auth  the default debug image (KARU_DBG_FULL KARU_DBG_AUTH
#               KARU_ZKR): 2 MiB boot ROM; the hart starts in the
#               authentication island, in every lifecycle
#   rom2m       a debug image built without KARU_DBG_AUTH
#               (VCU118_DBG_EXT_DEFINES=KARU_DBG_FULL): 2 MiB boot ROM
#   rom1m       images built before 2026-11-17, with the 1 MiB boot ROM:
#               bitstream d5e603cd..., the board-accepted 0b994847...
#   sim         the simulated JTAG target of rehearse.py
#               (test/dbg/tb_jtag_core.v with test/dbg/karudbg_test_ram.sv)
IMAGES = {'rom2m-auth': dict(scratch=0x201000, reset_pc=0x10000),
          'rom2m':      dict(scratch=0x201000, reset_pc=0x1000),
          'rom1m':      dict(scratch=0x101000, reset_pc=0x1000),
          'sim':        dict(scratch=0x201000, reset_pc=0x80000000)}
DEFAULT_IMAGE = 'rom2m-auth'

def refuse(reason):
    """Stop a phase before it touches the target; the reason is the whole error."""
    raise SystemExit('board harness: '+reason)

def image_map(env=os.environ):
    """The selected image kind with its scratch base and size and its reset vector."""
    name = env.get('KARU_BOARD_IMAGE') or DEFAULT_IMAGE
    if name not in IMAGES:
        refuse(f'KARU_BOARD_IMAGE={name} is not an image kind. The kinds are '+', '.join(IMAGES)
               +'; for another map set KARU_BOARD_SCRATCH and KARU_BOARD_RESET_PC')
    image = dict(image=name, scratch=IMAGES[name]['scratch'], size=0x10000, reset_pc=IMAGES[name]['reset_pc'], overrides=[])
    for key, var in (('scratch','KARU_BOARD_SCRATCH'), ('size','KARU_BOARD_SCRATCH_SIZE'), ('reset_pc','KARU_BOARD_RESET_PC')):
        if env.get(var):
            try: image[key] = int(env[var], 0)
            except ValueError: refuse(f'{var}={env[var]} is not a number')
            image['overrides'].append(f'{var}={env[var]}')
    return image

def describe(image):
    """One line that names a map in errors and results."""
    return (f"{' with '.join([image['image']]+image['overrides'])} (scratch SRAM {image['scratch']:#x}.."
            f"{image['scratch']+image['size']-1:#x}, reset vector {image['reset_pc']:#x})")

IMAGE = image_map()
SCRATCH, SCRATCH_SIZE, RESET_PC = IMAGE['scratch'], IMAGE['size'], IMAGE['reset_pc']

# What the phases use of the scratch SRAM: offset from its base, and bytes.
# The offsets are those of the 2026-11-16 campaign, when the scratch SRAM
# started at 0x101000 and these were 0x108000, 0x108700 and so on.
AREAS = {'fixture': (0x7000, 0x700),    # payload.S is linked here (dbg/board.mk asks this file)
         'probe':   (0x7700, 0x100),    # privilege_phase: the store that watchpoints stop
         'code':    (0x7800, 0x100),    # crypto_aperture_phase: Keccak and isolation snippets
         'vector':  (0x7900, 0x100),    # privilege_phase: vector load/store snippet
         'patch':   (0x8000, 0x1000),   # extended_phase: code replaced over SBA
         'matrix':  (0xb000, 0x1000),   # baremetal_phase and soak_phase: mixed-width traffic
         'data':    (0xd000, 0x1000),   # DATA: watchpoint, vector and GDB data
         'page':    (0xe000, 0x1000)}   # translation-board.tcl: page named by a G-stage PTE

def area(name, image=None):
    """Address of one of the scratch areas in the selected image's map."""
    return (image or IMAGE)['scratch'] + AREAS[name][0]

FIXTURE = area('fixture')

def fixture_symbols(directory=None, image=None):
    """Symbols of the fixture in the artifact directory, for a fixture phase.

    Refuses (SystemExit with the reason) unless the fixture and the areas the
    phases write fit the selected image's map: every area inside the scratch
    SRAM, the fixture present, linked at this map's fixture address, and
    short enough to end before the next area. A fixture built for another
    map would otherwise fail later and less clearly: writes into ROM, a
    failed readback, wrong PCs.
    """
    directory = Path(directory or OUT); image = image or IMAGE
    end = image['scratch'] + image['size']
    for name, (offset, size) in AREAS.items():
        if image['scratch'] + offset + size > end:
            refuse(f"the '{name}' area {image['scratch']+offset:#x}..{image['scratch']+offset+size-1:#x} that the phases use "
                   f"is outside the scratch SRAM of image map {describe(image)}")
    start = area('fixture', image)
    build = f"make dbg-board-fixture DBG_BOARD_OUT={directory} DBG_BOARD_IMAGE={image['image']}"
    moved = any(o.startswith('KARU_BOARD_SCRATCH=') for o in image['overrides'])
    if moved: build += f" DBG_BOARD_SCRATCH={image['scratch']:#x}"
    try:
        symbols = {p[2]: int(p[0],16) for line in (directory/'payload.symbols').read_text().splitlines() if len(p:=line.split())==3}
        length = (directory/'payload.bin').stat().st_size
    except FileNotFoundError:
        refuse(f'no payload.symbols and payload.bin in {directory}. Build the fixture: {build}')
    if '_start' not in symbols:
        refuse(f'payload.symbols in {directory} has no _start. Build the fixture: {build}')
    if symbols['_start'] != start:
        kinds = [k for k in IMAGES if area('fixture', IMAGES[k]) == symbols['_start']]
        refuse(f"the fixture in {directory} is linked at {symbols['_start']:#x}, but image map {describe(image)} "
               f"has the fixture at {start:#x}. Build it for this map ({build})"
               + (f", or select the image it was built for (KARU_BOARD_IMAGE={' or '.join(kinds)}"
                  + (', without KARU_BOARD_SCRATCH' if moved else '') + ')' if kinds else ''))
    if length > AREAS['fixture'][1]:
        refuse(f"payload.bin in {directory} is {length} bytes; at {start:#x} it would run into the area at "
               f"{start+AREAS['fixture'][1]:#x} that privilege_phase.py writes")
    return symbols

def kernel_release():
    """Release string of the local kernel build, as `uname -r` reports it."""
    return (KERNEL_BUILD/'include/config/kernel.release').read_text().strip()

def kernel_symbol(name, system_map=None):
    """(virtual, physical) address of a kernel symbol.

    The virtual address is System.map's. The physical address assumes the
    Image is loaded with _start at KERNEL_LOAD_PA; a caller that reads
    target memory should compare it with the Image to confirm that.
    """
    symbols={}
    for line in Path(system_map or KERNEL_BUILD/'System.map').read_text().splitlines():
        parts=line.split()
        if len(parts)==3: symbols.setdefault(parts[2],int(parts[0],16))
    if '_start' not in symbols or name not in symbols:
        raise KeyError(f'{name} or _start not in System.map')
    return symbols[name], KERNEL_LOAD_PA+symbols[name]-symbols['_start']

def insn_length(image, offset):
    """Length in bytes of the RISC-V instruction at an Image offset."""
    return 4 if image[offset]&3==3 else 2

class Board:
    def __init__(self, tag):
        self.tag=tag; self.sock=socket.create_connection((RPC_HOST,int(RPC_PORT)),10)
        self.sock.settimeout(40); self.buf=b''; self.parser=tkinter.Tcl()
        self.trace=(OUT/(tag+'-commands.jsonl')).open('a',buffering=1)
        self.results=[]; self.checks=0
    def cmd(self, command):
        start=time.monotonic()
        wrapped='set __karu_rc [catch {'+command+'} __karu_result]; format "%d\\n%s" $__karu_rc $__karu_result'
        self.sock.sendall(wrapped.encode()+b'\x1a')
        while b'\x1a' not in self.buf:
            chunk=self.sock.recv(65536)
            if not chunk: raise RuntimeError('OpenOCD RPC disconnected')
            self.buf+=chunk
        result,self.buf=self.buf.split(b'\x1a',1)
        result=result.decode(errors='replace'); code,_,reply=result.partition('\n')
        self.trace.write(json.dumps(dict(command=command,result=reply,code=code,seconds=round(time.monotonic()-start,5)))+'\n')
        if code!='0': raise RuntimeError(f'{command}: {reply}')
        return reply
    def equal(self, actual, expected, label=''):
        self.checks+=1
        if actual!=expected: raise AssertionError(f'{label}: {actual!r} != {expected!r}')
    def require(self, cond, label):
        self.checks+=1
        if not cond: raise AssertionError(label)
    def record(self, result):
        self.results.append(result); print(json.dumps(result),flush=True)
        (OUT/(self.tag+'-results.json')).write_text(json.dumps(self.results,indent=2)+'\n')
    def case(self, name, fn):
        start=time.monotonic(); count=self.checks
        try:
            detail=fn(); status='PASS'
        except Exception as e:
            detail=str(e); status='FAIL'; traceback.print_exc()
        self.record(dict(name=name,status=status,checks=self.checks-count,seconds=round(time.monotonic()-start,3),detail=detail))
        return status=='PASS'
    def restore(self, after, fn):
        """Run a restore step between cases. If it raises, that is recorded
        as a failed entry, so it reaches the exit status like a failed case."""
        try:
            fn(); return True
        except Exception as e:
            traceback.print_exc()
            self.record(dict(name='restore after '+after,status='FAIL',checks=0,seconds=0,detail=str(e)))
            return False
    def finish(self, cleanup=None):
        """Run the phase's cleanup, close, and return its process exit status.

        The status is 0 only if every recorded case passed and the cleanup
        raised nothing. A phase keeps running after a failed case, so this is
        what makes the failure visible to the caller: end each phase script
        with sys.exit(b.finish(...)).
        """
        if cleanup is not None:
            try: cleanup()
            except Exception as e:
                traceback.print_exc()
                self.record(dict(name='phase cleanup',status='FAIL',checks=0,seconds=0,detail=str(e)))
        failed=[r['name'] for r in self.results if r['status']!='PASS']
        try: self.close()
        except Exception: traceback.print_exc()
        print(json.dumps(dict(phase=self.tag,cases=len(self.results),failed=failed,image=describe(IMAGE))),flush=True)
        return 1 if failed else 0
    def dmi(self,a,v=None):
        if v is None: return int(self.cmd(f'riscv dmi_read {a:#x}'),0)
        self.cmd(f'riscv dmi_write {a:#x} {v&0xffffffff:#x}')
    def idle(self, expected=0):
        end=time.monotonic()+5
        while time.monotonic()<end:
            s=self.dmi(0x16)
            if not s&0x1000:
                err=(s>>8)&7
                if err!=expected: raise AssertionError(f'abstract cmderr {err}, expected {expected}; abstractcs={s:#x}')
                return s
        raise TimeoutError('abstract busy did not clear')
    def clear(self):
        self.dmi(0x18,0); self.dmi(0x16,0x700)
    def rawread(self, reg, size=3):
        self.dmi(0x17,(size<<20)|0x20000|reg); self.idle()
        return self.dmi(4)|(self.dmi(5)<<32) if size==3 else self.dmi(4)
    def rawwrite(self, reg, value, size=3):
        self.dmi(4,value); self.dmi(5,value>>32)
        self.dmi(0x17,(size<<20)|0x30000|reg); self.idle()
    def rr(self,name):
        if name=='s0': name='fp'
        vals=self.parser.splitlist(self.cmd(f'get_reg -force {{{name}}}'))
        return int(vals[1],0)
    def rw(self,name,value):
        if name=='s0': name='fp'
        self.cmd(f'reg {name} {value:#x}')
    def read(self,addr,width,count=1,method=None):
        if method: self.cmd('riscv mem_access '+method)
        result=self.cmd(f'read_memory {addr:#x} {width} {count} phys')
        return [int(s,0) for s in self.parser.splitlist(result)]
    def write(self,addr,width,values,method=None):
        if method: self.cmd('riscv mem_access '+method)
        self.cmd(f'write_memory {addr:#x} {width} '+'{'+' '.join(hex(v&((1<<width)-1)) for v in values)+'} phys')
    def halt(self):
        self.cmd('halt 5000'); self.equal(self.cmd('karu.cpu curstate'),'halted','halt state')
    def resume(self,addr=None):
        self.cmd('resume'+('' if addr is None else f' {addr:#x}')); self.cmd('poll')
        self.equal(self.cmd('karu.cpu curstate'),'running','resume state')
    def reset_halt(self):
        self.cmd('poll off'); self.dmi(0x10,0x80000003); time.sleep(.05)
        self.dmi(0x10,0x80000001); time.sleep(.05)
        self.cmd('poll on'); self.halt(); self.clear()
        self.equal(self.rawread(0x7b1),RESET_PC,'reset-halt DPC before first instruction')
        self.cmd('riscv exec_progbuf 0x13')
        self.dmi(0x10,0x10000001)
    def close(self): self.sock.close(); self.trace.close()

if __name__=='__main__':
    # make dbg-board-fixture: where to link payload.S for the selected image
    print(f'{FIXTURE:#x}')
