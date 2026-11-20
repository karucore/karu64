#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Revocation with an SBA transaction in flight, beyond dbg-auth-sba-revoke-test.

doc/debug-auth-plan.md, milestone A4, lists what the make target does not
cover. This runner builds test/dbg/tb_auth_sba_revoke.sv in the missing
configurations and runs every scenario in each:

  iv4-base      the make target's own build (Icarus, four-state, KARU_ASIC),
                as the reference for scenario names and check counts
  vl2-base      the same configuration, two-state with Verilator
  vl2-icache    with KARU_ICACHE
  vl2-rva23     with the vector unit: KARU_RVA23S64, KARU_ICACHE and the
                vector pipeline options of the other debug benches
  iv4-icache, iv4-rva23
                the last two again in four state
  iv4-vector    the core's default extensions (F, D and V, no instruction
                cache, no H), in four state
  vl2-xbar      AUTH_REVOKE_XBAR: flow/fpga/karu_ddr_xbar.v and the AXI memory
                model behind its DDR port as the responder (36 scenarios)
  vl2-xbar-rva23, iv4-xbar
                the crossbar with the instruction cache and the vector unit,
                and in four state (there with test/dbg/karu_eth_idle.v in
                place of the Ethernet device, which Icarus cannot simulate)
  iv4-jtag, vl2-jtag
                AUTH_REVOKE_JTAG: the debugger on the JTAG side of the
                transport, dbg/karudbg_jtag.v, with five more scenarios in
                which a read of sbdata0 is crossing the transport when
                debug_enable falls (29 scenarios)

Each configuration is also built with the three RTL mutants of the make
target (test/dbg/auth_sba_revoke_mut_*.patch, applied to copies under the
output directory). A mutant must fail, with the bench check named for it and
with none of the excluded ones. A Verilator build that passes is run a second
time with every uninitialised variable randomised.

    python3 test/dbg/run_auth_revoke_ext.py --out _build/dbg/auth-revoke-ext

Exit status 0 only if every configuration passed and every mutant was
detected. Progress goes to stdout and to OUT/runner.log; each build and run
has its own log under OUT/<configuration>/<variant>/.
"""
import argparse
import concurrent.futures
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BENCH = 'test/dbg/tb_auth_sba_revoke.sv'
TEST_RAM = 'test/dbg/karudbg_test_ram.sv'
ROM_STUB = 'test/dbg/auth_rom_stub.S'
ETH_IDLE = 'test/dbg/karu_eth_idle.v'
BASE_DEFINES = ['-DKARU_DBG', '-DKARU_DBG_AUTH', '-DKARU_DBG_SBA']
RVA23 = ['-DKARU_RVA23S64', '-DKARU_ICACHE', '-DKARU_V_LANE_PIPE', '-DKARU_V_CWB_STAGE']
NO_V = ['-DKARU_NO_V', '-DKARU_NO_F']

# name, simulator, configuration defines, bench variant ('' the test RAM
# model and direct DMI, 'xbar' the crossbar, 'jtag' the JTAG transport),
# extra sources
CONFIGS = [
    ('iv4-base', 'iverilog', NO_V, '', []),
    ('vl2-base', 'verilator', NO_V, '', []),
    ('vl2-icache', 'verilator', NO_V + ['-DKARU_ICACHE'], '', []),
    ('vl2-rva23', 'verilator', RVA23, '', []),
    ('iv4-icache', 'iverilog', NO_V + ['-DKARU_ICACHE'], '', []),
    ('iv4-rva23', 'iverilog', RVA23, '', ['rtl/karu_vrf_assert.sv']),
    ('iv4-vector', 'iverilog', [], '', ['rtl/karu_vrf_assert.sv']),
    ('vl2-xbar', 'verilator', NO_V, 'xbar', []),
    ('vl2-xbar-rva23', 'verilator', RVA23, 'xbar', []),
    ('iv4-xbar', 'iverilog', NO_V, 'xbar', []),
    ('iv4-jtag', 'iverilog', NO_V, 'jtag', []),
    ('vl2-jtag', 'verilator', NO_V, 'jtag', []),
]
REFERENCE = 'iv4-base'
# The bench's last line names its variant.
VARIANT_TEXT = {'': None, 'xbar': ', DDR crossbar', 'jtag': ', JTAG'}

# name, patched files, the check that must report it, checks that must not
MUTANTS = [
    ('launch', ['dbg/karudbg.v'], 'LAUNCH', 'LEAK|AXI'),
    ('leak', ['dbg/karudbg.v', 'dbg/karudbg_sba.v'], 'LEAK', 'LAUNCH|AXI'),
    ('no_drain', ['dbg/karudbg_sba.v'], 'HART', 'LEAK|LAUNCH|AXI'),
]

PASS_RE = re.compile(r'^karudbg auth SBA revocation(, DDR crossbar|, JTAG)?: PASS \((\d+) checks, (\d+) scenarios\)$',
                     re.M)
SCENARIO_RE = re.compile(r'^scenario (.*?): SBA ', re.M)
FAIL_RE = re.compile(r'FAIL \[([A-Z]+)\]')
# Verilator: the warnings the Makefile turns off for the core (LINT_W), and
# those of the crossbar bench (dbg/sba.mk) for the FPGA sources.
LINT_W = ('-Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-INITIALDLY '
          '-Wno-TIMESCALEMOD -Wno-COMBDLY -Wno-CMPCONST -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME')
XBAR_LINT_W = '-Wno-fatal -Wno-MULTIDRIVEN'

log_lock = threading.Lock()
log_file = None


def say(text):
    with log_lock:
        print(text, flush=True)
        if log_file:
            log_file.write(text + '\n')
            log_file.flush()


def make_variable(name):
    """A Makefile variable, expanded by make itself (nothing is built)."""
    rule = 'revoke-ext-print-%s' % name
    out = subprocess.run(['make', '-s', '--no-print-directory', '--eval', '%s: ; @echo $(%s)' % (rule, name), rule],
                         cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120)
    if out.returncode != 0 or not out.stdout.split():
        sys.exit('cannot read $(%s) from the Makefile (pass it on the command line instead): %s'
                 % (name, out.stderr.strip()[-300:]))
    return out.stdout.split()


def run_logged(cmd, log, timeout, env, cwd=ROOT):
    """Run cmd with its output in log; (return code, seconds). 124 on a timeout."""
    start = time.time()
    with open(log, 'w') as handle:
        handle.write('+ ' + ' '.join(shlex.quote(c) for c in cmd) + '\n')
        handle.flush()
        try:
            code = subprocess.run(cmd, cwd=cwd, env=env, stdout=handle, stderr=subprocess.STDOUT,
                                  timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            handle.write('\nTIMEOUT after %d s\n' % timeout)
            code = 124
    return code, time.time() - start


class Job:
    """One build and run of the bench: a configuration, pristine or with one mutant."""

    def __init__(self, args, config, mutant):
        self.args = args
        self.name, self.sim, self.defines, self.variant_of_bench, self.extra = config
        self.xbar = self.variant_of_bench == 'xbar'
        self.jtag = self.variant_of_bench == 'jtag'
        self.mutant = mutant
        self.variant = 'mut-' + mutant[0] if mutant else 'good'
        self.dir = os.path.join(args.out, self.name, self.variant)
        self.ok = False
        self.note = ''
        self.checks = 0
        self.scenarios = []
        self.seconds = 0.0

    def label(self):
        return '%s/%s' % (self.name, self.variant)

    def sources(self):
        rtl = list(self.args.core_rtl)
        if self.mutant:
            for path in self.mutant[1]:
                if path not in rtl:
                    raise RuntimeError('%s is not in the RTL list' % path)
                rtl[rtl.index(path)] = os.path.join(self.args.out, 'mutants', self.mutant[0], path)
        files = [BENCH] + ([] if self.xbar else [TEST_RAM]) + rtl + self.extra
        if self.jtag:
            files += list(self.args.jtag_rtl)
        if self.xbar and self.sim == 'iverilog':
            # The generated LiteEth core does not get past time 0 in Icarus:
            # an idle stand-in takes the Ethernet device's place there.
            return files + [path for path in self.args.xbar_rtl if '/eth/' not in path] + [ETH_IDLE]
        return files + (list(self.args.xbar_rtl) if self.xbar else [])

    def defines_all(self):
        defs = BASE_DEFINES + self.defines
        if self.sim == 'iverilog':
            defs = defs + ['-DKARU_ASIC']
        if self.xbar:
            defs = defs + ['-DSIM_TB', '-DAUTH_REVOKE_XBAR']
        if self.jtag:
            defs = defs + ['-DAUTH_REVOKE_JTAG']
        return defs

    def build(self, env):
        includes = ['-Irtl', '-Idbg'] + (['-Iflow/fpga'] if self.xbar else [])
        params = {'ROM_HEX': self.args.rom_hex}
        if self.xbar:
            params['XBAR_ROM_HEX'] = os.path.join(self.args.out, 'rom', 'xbar_rom.hex')
        if self.sim == 'iverilog':
            self.binary = [self.args.vvp, '-n', os.path.join(self.dir, 'tb.vvp')]
            cmd = [self.args.iverilog, '-g2012'] + includes + self.defines_all() + ['-s', 'tb_auth_sba_revoke']
            cmd += ['-Ptb_auth_sba_revoke.%s="%s"' % item for item in params.items()]
            cmd += ['-o', os.path.join(self.dir, 'tb.vvp')] + self.sources()
        else:
            obj = os.path.join(self.dir, 'obj')
            self.binary = [os.path.join(obj, 'Vtb_auth_sba_revoke')]
            # The model is compiled without optimisation: the runs take a few
            # seconds either way and the builds a third of the time.
            cmd = [self.args.verilator, '--binary', '--timing', '-j', str(self.args.build_jobs),
                   '--unroll-count', '1', '--output-split', '10000', '-CFLAGS', '-O0']
            cmd += includes + self.defines_all() + LINT_W.split() + (XBAR_LINT_W.split() if self.xbar else [])
            cmd += ['-G%s="%s"' % item for item in params.items()]
            cmd += ['--Mdir', obj, '--top-module', 'tb_auth_sba_revoke'] + self.sources()
        return run_logged(cmd, os.path.join(self.dir, 'build.log'), 900, env)

    def simulate(self, env, log, plusargs=()):
        code, seconds = run_logged(self.binary + list(plusargs), os.path.join(self.dir, log), 600, env)
        with open(os.path.join(self.dir, log), errors='replace') as handle:
            return code, handle.read(), seconds

    def run(self, env):
        start = time.time()
        try:
            self.run_inner(env)
        except Exception as error:   # a broken job is a failed job, with the others still reported
            self.ok, self.note = False, 'runner error: %r' % (error,)
        self.seconds = time.time() - start
        say('%-4s %-26s %5.0f s  %s' % ('ok' if self.ok else 'FAIL', self.label(), self.seconds, self.note))
        return self

    def run_inner(self, env):
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        code, _ = self.build(env)
        if code != 0:
            self.note = 'build failed (%s)' % os.path.join(self.dir, 'build.log')
            return
        code, text, _ = self.simulate(env, 'run.log')
        passed = PASS_RE.search(text)
        tags = FAIL_RE.findall(text)
        if self.mutant:
            _, _, expected, excluded = self.mutant
            if passed or code == 0:
                self.note = 'mutant NOT detected (exit %d%s)' % (code, ', PASS printed' if passed else '')
            elif expected not in tags:
                self.note = 'mutant failed without a [%s] failure (saw %s)' % (expected, sorted(set(tags)) or 'none')
            elif [tag for tag in tags if re.fullmatch(excluded, tag)]:
                self.note = 'mutant caught by an excluded check: %s' % sorted(set(tags))
            else:
                first = next(line for line in text.splitlines() if 'FAIL [%s]' % expected in line)
                self.ok = True
                self.note = '%d [%s] failures, first: %s' % (tags.count(expected), expected, first.strip()[:150])
            return
        self.scenarios = SCENARIO_RE.findall(text)
        if code != 0 or not passed or tags:
            self.note = 'run failed (exit %d, %d FAIL lines, %s)' % (code, len(tags), os.path.join(self.dir, 'run.log'))
            return
        self.checks, count = int(passed.group(2)), int(passed.group(3))
        if passed.group(1) != VARIANT_TEXT[self.variant_of_bench]:
            self.note = 'the wrong variant of the bench was built'
            return
        # Every scenario but the authorized baseline prints one line.
        if count != len(self.scenarios) + 1 or len(set(self.scenarios)) != len(self.scenarios):
            self.note = '%d scenarios reported but %d distinct scenario lines' % (count, len(set(self.scenarios)))
            return
        self.note = '%d checks, %d scenarios' % (self.checks, count)
        if self.sim == 'verilator':
            code, text, _ = self.simulate(env, 'run-rand.log',
                                          ['+verilator+rand+reset+2', '+verilator+seed+%d' % self.args.seed])
            again = PASS_RE.search(text)
            if code != 0 or not again or again.group(2, 3) != passed.group(2, 3) or FAIL_RE.search(text):
                self.note += '; FAILED with randomised initial values (%s)' % os.path.join(self.dir, 'run-rand.log')
                return
            self.note += ', again with randomised initial values'
        self.ok = True


def prepare(args, env):
    """The ROM images and the mutated RTL copies, shared by all jobs."""
    rom_dir = os.path.join(args.out, 'rom')
    os.makedirs(rom_dir, exist_ok=True)
    if not args.rom_hex:
        elf, binary = os.path.join(rom_dir, 'rom.elf'), os.path.join(rom_dir, 'rom.bin')
        args.rom_hex = os.path.join(rom_dir, 'rom.hex')
        for cmd in ([args.xchain + 'gcc', '-march=rv64gc', '-mabi=lp64d', '-nostdlib', '-static',
                     '-Wl,-Ttext=0x10000', '-o', elf, ROM_STUB],
                    [args.xchain + 'objcopy', '-O', 'binary', elf, binary]):
            subprocess.run(cmd, cwd=ROOT, env=env, check=True)
        with open(binary, 'rb') as source, open(args.rom_hex, 'w') as hexfile:
            data = source.read()
            data += bytes(-len(data) % 8)
            for offset in range(0, len(data), 8):
                hexfile.write('%016x\n' % int.from_bytes(data[offset:offset + 8], 'little'))
    args.rom_hex = os.path.abspath(args.rom_hex)
    # The crossbar's own boot ROM: any small image (the hart boots from the
    # island ROM, which is decoded in front of it).
    with open(os.path.join(rom_dir, 'xbar_rom.hex'), 'w') as hexfile:
        hexfile.write(''.join('%016x\n' % word for word in range(8)))
    for name, files, _, _ in MUTANTS:
        mut_dir = os.path.join(args.out, 'mutants', name)
        shutil.rmtree(mut_dir, ignore_errors=True)
        for path in files:
            os.makedirs(os.path.dirname(os.path.join(mut_dir, path)), exist_ok=True)
            shutil.copy(os.path.join(ROOT, path), os.path.join(mut_dir, path))
        with open(os.path.join(ROOT, 'test/dbg/auth_sba_revoke_mut_%s.patch' % name)) as patch:
            done = subprocess.run(['patch', '-s', '-N', '--fuzz=0', '--no-backup-if-mismatch', '-r', '-', '-p1',
                                   '-d', mut_dir], stdin=patch, env=env, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True)
        if done.returncode != 0:
            sys.exit('mutant %s no longer applies: %s' % (name, done.stdout.strip()))
        for path in files:
            with open(os.path.join(ROOT, path), 'rb') as a, open(os.path.join(mut_dir, path), 'rb') as b:
                if a.read() == b.read():
                    sys.exit('mutant %s left %s unchanged' % (name, path))


def main():
    global log_file
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--out', required=True, help='output directory (builds, logs, mutated copies)')
    parser.add_argument('--jobs', type=int, default=8, help='processor budget (default 8)')
    parser.add_argument('--only', default='', help='regular expression: only these configurations')
    parser.add_argument('--no-mutants', action='store_true', help='pristine builds only (not a complete run)')
    parser.add_argument('--seed', type=int, default=1, help='seed of the randomised-initial-value runs')
    parser.add_argument('--rom-hex', default='', help='island ROM stub image (default: built from %s)' % ROM_STUB)
    parser.add_argument('--core-rtl', default='', help='$(DBG_CORE_RTL) (default: asked of make)')
    parser.add_argument('--xbar-rtl', default='', help='$(SBA_XBAR_RTL) (default: asked of make)')
    parser.add_argument('--jtag-rtl', default='', help='$(KARUDBG_JTAG_SRCS) (default: asked of make)')
    parser.add_argument('--xchain', default='riscv64-unknown-elf-')
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--iverilog', default='iverilog')
    parser.add_argument('--vvp', default='vvp')
    args = parser.parse_args()
    args.out = os.path.abspath(args.out)
    os.makedirs(os.path.join(args.out, 'tmp'), exist_ok=True)
    log_file = open(os.path.join(args.out, 'runner.log'), 'w')
    env = dict(os.environ, TMPDIR=os.path.join(args.out, 'tmp'), TMP=os.path.join(args.out, 'tmp'))
    args.core_rtl = args.core_rtl.split() or make_variable('DBG_CORE_RTL')
    args.xbar_rtl = args.xbar_rtl.split() or make_variable('SBA_XBAR_RTL')
    args.jtag_rtl = args.jtag_rtl.split() or make_variable('KARUDBG_JTAG_SRCS')
    # Two compiler processes per Verilator build, and builds side by side up
    # to the budget.
    args.build_jobs = 2 if args.jobs >= 2 else 1
    workers = max(1, args.jobs // args.build_jobs)
    start = time.time()
    prepare(args, env)
    configs = [config for config in CONFIGS if re.search(args.only, config[0])]
    if not configs:
        sys.exit('no configuration matches --only %r' % args.only)
    complete = not args.only and not args.no_mutants
    jobs = [Job(args, config, mutant) for config in configs
            for mutant in [None] + ([] if args.no_mutants else MUTANTS)]
    say('%d builds of %s in %d configurations, %d at a time; log %s'
        % (len(jobs), BENCH, len(configs), workers, os.path.join(args.out, 'runner.log')))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(lambda job: job.run(env), jobs))

    problems = ['%s: %s' % (job.label(), job.note) for job in jobs if not job.ok]
    good = {job.name: job for job in jobs if not job.mutant}
    # Every configuration of the plain bench runs the scenarios and the
    # checks of the reference; the crossbar and the JTAG transport run those
    # scenarios and more.
    reference = good.get(REFERENCE)
    for job in good.values():
        if not job.ok or not reference or not reference.ok:
            continue
        # (With the crossbar the two fw_lock scenarios read the scratch SRAM.)
        names = [name.replace('SBA read of the scratch SRAM, hart', 'SBA read, hart') for name in job.scenarios]
        missing = [name for name in reference.scenarios if name not in names]
        if missing:
            problems.append('%s: scenarios of %s not run: %s' % (job.name, REFERENCE, missing))
        plain = not job.variant_of_bench
        if plain and (job.scenarios != reference.scenarios or job.checks != reference.checks):
            problems.append('%s: %d checks and %d scenario lines, %s has %d and %d'
                            % (job.name, job.checks, len(job.scenarios), REFERENCE, reference.checks,
                               len(reference.scenarios)))
        if not plain and (len(job.scenarios) <= len(reference.scenarios) or job.checks <= reference.checks):
            problems.append('%s: no scenarios of its own' % job.name)
    detected = sum(1 for job in jobs if job.mutant and job.ok)
    mutants = sum(1 for job in jobs if job.mutant)
    passed = [job for job in good.values() if job.ok]
    counts = ('%d of %d configurations (%s), %d scenario runs, %d checks, %d of %d mutant builds detected, %.0f s'
              % (len(passed), len(good), ' '.join('%s:%d' % (job.name, len(job.scenarios) + 1) for job in passed),
                 sum(len(job.scenarios) + 1 for job in passed), sum(job.checks for job in passed),
                 detected, mutants, time.time() - start))
    for problem in problems:
        say('PROBLEM ' + problem)
    if problems:
        say('FAIL auth revocation extended: ' + counts)
        return 1
    if not complete:
        say('PARTIAL auth revocation extended (--only or --no-mutants given): ' + counts)
        return 2
    say('PASS auth revocation extended: ' + counts)
    return 0


if __name__ == '__main__':
    sys.exit(main())
