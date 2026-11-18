# GDB client checks through OpenOCD's GDB server.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import subprocess,re,xml.etree.ElementTree as ET
import baremetal_phase as bm
bm.b.close(); b=Board('gdb'); bm.b=b
S=bm.SYMS; DATA=bm.DATA
def eq(expr,val):
    return f'if ({expr}) != {val:#x}\n echo FAIL {expr}\\n\n quit 1\nend\n'
def client(name,body,marker):
    script=OUT/(name+'.gdb')
    prefix=f'set pagination off\nset confirm off\nset remotetimeout 15\nset trace-commands on\nfile {OUT}/payload.elf\ntarget extended-remote {GDB_REMOTE}\nmonitor halt\n'
    script.write_text(prefix+body+f'\nset $pc={S["_start"]:#x}\ndetach\nquit\n')
    with (OUT/(name+'.log')).open('w') as f:
        r=subprocess.run([GDB,'--batch','-nx','-x',str(script)],stdout=f,stderr=subprocess.STDOUT,timeout=180)
    text=(OUT/(name+'.log')).read_text()
    b.equal(r.returncode,0,name+' client exit'); b.require(marker in text,name+' marker')
    return text
def main_registers():
    bm.prep(); b.rw('pc',S['_start']); b.cmd('riscv exec_progbuf 0x13')
    body='set $mstatus=0x6600\nset $dcsr=0x3b403\n'
    for name,val in [('a0',0x0123456789abcdef),('a1',0xfedcba9876543210),('mscratch',0x5a5aa5a512345678)]:
        body+=f'set ${name}={val:#x}\n'+eq('$'+name,val)
    for width,typ in [(8,'unsigned char'),(16,'unsigned short'),(32,'unsigned int'),(64,'unsigned long long')]:
        v=0x0123456789abcdef&((1<<width)-1)
        body+=f'set {{{typ}}}{DATA:#x}={v:#x}\n'+eq(f'*({typ}*){DATA:#x}',v)
    body+='maintenance print xml-tdesc\necho PASS_GDB_DISCOVERY_REGISTERS_MEMORY\\n\n'
    text=client('gdb-registers',body,'PASS_GDB_DISCOVERY_REGISTERS_MEMORY')
    m=re.search(r'<target\b.*?</target>',text,re.S)
    b.require(m is not None,'target XML present')
    regs={};n=0
    for r in ET.fromstring(m.group()).iter('reg'):
        n=int(r.get('regnum',str(n))); regs[r.get('name')]=(n,int(r.get('bitsize')));n+=1
    (OUT/'gdb-register-description.json').write_text(json.dumps(regs,indent=2))
    for name in ['v0','v31']: b.equal(regs[name][1],256,'GDB vector width')
    return {'registers':len(regs)}
def raw_context():
    regs=json.loads((OUT/'gdb-register-description.json').read_text())
    names=[n for n,(num,bits) in regs.items() if n.startswith('v') and n[1:].isdigit()]
    fp=[n for n in ['ft0','ft1','ft2','ft3','ft4','ft5','ft6','ft7','fs0','fs1','fa0','fa1','fa2','fa3','fa4','fa5','fa6','fa7','fs2','fs3','fs4','fs5','fs6','fs7','fs8','fs9','fs10','fs11','ft8','ft9','ft10','ft11'] if n in regs]
    body='set $mstatus=0x6600\n'; patterns={}
    for i,name in enumerate(fp+names):
        n,bits=regs[name];pattern=bytes(((j*17+i*23)&255) for j in range(bits//8)).hex();patterns[name]=pattern
        body+=f'echo WRITE_{name}_BEGIN\\n\nmaintenance packet P{n:x}={pattern}\necho WRITE_{name}_END\\n\n'
    for name in fp+names:
        n,bits=regs[name];body+=f'echo READ_{name}_BEGIN\\n\nmaintenance packet p{n:x}\necho READ_{name}_END\\n\n'
    body+='echo PASS_GDB_ALL_FP_VECTOR_RAW_PACKETS\\n\n'
    text=client('gdb-context',body,'PASS_GDB_ALL_FP_VECTOR_RAW_PACKETS')
    for name,pattern in patterns.items():
        write=text.split('WRITE_'+name+'_BEGIN',1)[1].split('WRITE_'+name+'_END',1)[0]
        read=text.split('READ_'+name+'_BEGIN',1)[1].split('READ_'+name+'_END',1)[0]
        b.require('received: "OK"' in write,'GDB raw write '+name)
        b.require(pattern in read.lower(),'GDB raw read '+name)
    return {'FP_registers':len(fp),'vector_registers':len(names)}
def stepping_triggers():
    body='set $mstatus=0x6600\nset $dcsr=0x3b403\n'
    body+=f'set $pc={S["step_0"]:#x}\nstepi\n'+eq('$pc',S['step_1'])+eq('$a0',42)
    body+='stepi\n'+eq('$pc',S['step_2'])+eq('$a0',43)
    body+='stepi\n'+eq('$pc',S['step_3'])+eq('$a0',44)
    body+='stepi\n'+eq('$pc',S['step_end'])+eq('$a0',46)
    body+=f'set {{unsigned int}}{DATA:#x}=0\nset $a1={DATA:#x}\nset $a2=0\nset $pc={S["watch_case"]:#x}\nhbreak *{S["watch_case"]:#x}\ncontinue\n'
    body+=eq('$pc',S['watch_case'])+eq('$a2',0)+'delete breakpoints\nstepi\n'+eq('$a2',1)
    body+=f'watch -l *(unsigned int*){DATA:#x}\ncontinue\n'+eq(f'*(unsigned int*){DATA:#x}',1)+'delete breakpoints\n'
    body+=f'set $pc={S["watch_load"]:#x}\nrwatch -l *(unsigned int*){DATA:#x}\ncontinue\ndelete breakpoints\nstepi\n'+eq('$a3',1)
    body+=f'set $pc={S["watch_store"]:#x}\nset $a2=2\nawatch -l *(unsigned int*){DATA:#x}\ncontinue\ndelete breakpoints\nstepi\n'+eq(f'*(unsigned int*){DATA:#x}',2)
    body+=f'set $a0=0\nset $pc={S["branch_case"]:#x}\nbreak *{S["branch_taken"]:#x}\ncontinue\n'+eq('$pc',S['branch_taken'])+eq('$a0',1)+'delete breakpoints\nstepi\n'+eq('$a0',3)
    body+='echo PASS_GDB_STEP_HW_SW_BREAK_WATCHPOINTS\\n\n'
    client('gdb-step-triggers',body,'PASS_GDB_STEP_HW_SW_BREAK_WATCHPOINTS')
b.case('GDB target XML, scalar registers, CSR and memory widths',main_registers)
b.case('GDB all FP/vector raw register packets',raw_context)
b.case('GDB compressed stepping, software/hardware breakpoints, read/write/access watchpoints',stepping_triggers)
sys.exit(b.finish())
