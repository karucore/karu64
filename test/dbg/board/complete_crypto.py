# Collect the post-Linux text evidence and complete the OpenSSL Zvk
# known-answer matrix if the first run timed out. Writes
# openssl-matrix-result.json and exits non-zero unless every expected
# algorithm/capability pair is present and matches both references.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import csv,subprocess,shlex
remote=REMOTE_DIR;name=Path(remote).name;parent=str(Path(remote).parent)
exclude=['arch_timer','ebreak_test','vstate_exec_nolibc','v_exec_initval_nolibc','vstate_prctl','vstate_ptrace','validate_v_ptrace','v_initval']
tarcmd=f'tar -C {parent} -cf - '+' '.join('--exclude='+x for x in exclude)+' '+name
def collect(suffix):
 p=OUT/('post-linux-text-'+suffix+'.tar')
 with p.open('wb') as f:
  subprocess.run(SSH+[tarcmd],stdout=f,stderr=subprocess.PIPE,check=True,timeout=600)
 subprocess.run(['tar','-xf',str(p),'-C',str(OUT)],check=True)

root=OUT/name
if not (root/'openssl-zvk/kat.csv').exists(): collect('initial')
print('Collected initial target text evidence',flush=True)
expected=[tuple(x) for x in json.loads((SRC/'openssl-expected-matrix.json').read_text())]
rows=list(csv.DictReader((root/'openssl-zvk/kat.csv').open()))
print('CSV columns',list(rows[0]) if rows else [],flush=True)
# The installed tool quotes fields; csv handles those independently of shell.
key=lambda r:(r['kat'],r['cap_set'])
seen={key(r) for r in rows}
missing=[x for x in expected if x not in seen]
cases=sorted({x[0] for x in missing})
print('Initial rows',len(rows),'missing pairs',len(missing),'remaining algorithms',cases,flush=True)
(OUT/'openssl-continuation-plan.json').write_text(json.dumps(dict(initial_rows=len(rows),missing=missing,rerun_algorithms=cases),indent=2)+'\n')
more=[];continuation_exit=None
if cases:
 command='openssl_zvk_bench --kat-only --cases '+shlex.quote(','.join(cases))+' --out '+remote+'/openssl-zvk-completion'
 start=time.monotonic()
 with (OUT/'openssl-continuation.log').open('w') as f:
  p=subprocess.run(SSH+['timeout 1800 '+command],stdout=f,stderr=subprocess.STDOUT,timeout=2000)
 continuation_exit=p.returncode
 (OUT/'openssl-continuation-exit.json').write_text(json.dumps(dict(exit_code=p.returncode,seconds=round(time.monotonic()-start,3),command=command),indent=2)+'\n')
 print('Continuation exit',p.returncode,flush=True)
 collect('final')
 print('Collected final target text evidence',flush=True)
 more=list(csv.DictReader((root/'openssl-zvk-completion/kat.csv').open()))
# Verdict over both runs: every expected pair observed, every observation
# matching the expected answer and the scalar reference with exit status 0.
observed=rows+more
bad=sorted({key(r) for r in observed if r['match_expected']!='yes' or r['match_scalar']!='yes' or r['rc']!='0'})
still=[x for x in expected if x not in {key(r) for r in observed}]
result=dict(unique_pairs=len({key(r) for r in observed}),observations=len(observed),initial=len(rows),continuation=len(more),
            continuation_exit=continuation_exit,missing=still,bad=bad)
(OUT/'openssl-matrix-result.json').write_text(json.dumps(result,indent=2)+'\n')
print('OpenSSL matrix',json.dumps(result),flush=True)
sys.exit(1 if still or bad or continuation_exit else 0)
