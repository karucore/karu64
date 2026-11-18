# Host side of the post-detach Linux regression: wait for SSH, copy the
# selftests and post-linux.sh to the board, run them, collect the evidence.
# The verdict is the board's status.tsv, not the SSH exit status alone.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import subprocess,csv
start=time.monotonic();ready=False
for attempt in range(90):
    try:
        with socket.create_connection((BOARD_IP,22),timeout=2): pass
        p=subprocess.run(SSH+['uname -r; uptime'],capture_output=True,text=True,timeout=120)
        if p.returncode: print('SSH readiness attempt',attempt,p.returncode,p.stderr.strip(),flush=True)
        if p.returncode==0:
            (OUT/'post-linux-ssh-ready.log').write_text(p.stdout+p.stderr)
            ready=True;break
    except (OSError,subprocess.TimeoutExpired): pass
    time.sleep(10)
if not ready: raise RuntimeError('Linux SSH did not become ready within readiness bound')
print('Linux SSH ready:',datetime.datetime.now(datetime.timezone.utc).isoformat(),flush=True)
remote=REMOTE_DIR;name=Path(remote).name;parent=str(Path(remote).parent)
subprocess.run(SSH+['mkdir -p '+remote],check=True,timeout=180)
base=Path(setting('KARU_BOARD_SELFTESTS',KARUDEB/'build/selftests-7.2.4'))
if not (base/'out-riscv/vector').is_dir():
    raise RuntimeError(f'Linux selftest build not found at {base}; set KARU_BOARD_SELFTESTS')
files=[base/'out-kvm/riscv/ebreak_test',base/'out-kvm/arch_timer']+list((base/'out-riscv/vector').iterdir())+[SRC/'post-linux.sh']
subprocess.run(['scp','-i',SSH_KEY,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',*[str(p) for p in files if p.is_file()],'root@'+BOARD_IP+':'+remote+'/'],check=True,timeout=180)
# The kernel the board must be running: by default the release of the local
# kernel build, which is the one this host serves.
expect=os.environ.get('KARU_BOARD_EXPECT_KERNEL') or kernel_release()
with (OUT/'post-linux-run.log').open('w') as log:
    p=subprocess.run(SSH+[f'KARU_BOARD_REMOTE_DIR={remote} KARU_BOARD_EXPECT_KERNEL={expect} bash {remote}/post-linux.sh'],stdout=log,stderr=subprocess.STDOUT,timeout=2400)
print('Post-Linux command exit:',p.returncode,flush=True)
with (OUT/'post-linux-evidence.tgz').open('wb') as f:
    # about 4.5 minutes on the 75 MHz board for 3 MB (2026-11-18)
    subprocess.run(SSH+[f'tar -C {parent} -czf - {name}'],stdout=f,stderr=subprocess.PIPE,check=True,timeout=900)
subprocess.run(['tar','-xzf',str(OUT/'post-linux-evidence.tgz'),'-C',str(OUT)],check=True)
status=OUT/name/'status.tsv'
rows=[r for r in csv.reader(status.open(),delimiter='\t') if len(r)==2] if status.exists() else []
bad=[r[0] for r in rows if r[1]!='0']
verdict=dict(ssh_exit=p.returncode,seconds=round(time.monotonic()-start,3),ready=ready,tests=len(rows),failed=bad)
(OUT/'post-linux-status.json').write_text(json.dumps(verdict,indent=2)+'\n')
print('Post-Linux evidence collected',json.dumps(verdict),flush=True)
# A timed-out OpenSSL matrix is completed by complete_crypto.py, which gives
# its own verdict; every other non-zero status is a failure here.
sys.exit(1 if p.returncode or not rows or bad else 0)
