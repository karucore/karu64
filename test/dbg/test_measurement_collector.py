#!/usr/bin/env python3
"""Small independent fixtures for measurement parsing and evidence integrity.
SPDX-License-Identifier: BSD-3-Clause
"""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec=importlib.util.spec_from_file_location('collect_measurements',Path(__file__).resolve().parents[2]/'dbg/collect_measurements.py')
collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.source=self.root/'rtl.v';self.source.write_text('module example; endmodule\n')
        self.lib=self.root/'typical.lib';self.lib.write_text('library(test) { cell(NAND2_X1) { area : 0.798; } }\n')
        self.tools={name:self.root/name for name in ('YOSYS','YOSYS_ABC','OPENSTA')}
        for name,path in self.tools.items():path.write_text('binary fixture '+name)
    def tearDown(self):self.temp.cleanup()
    def fixture(self,name='base',kind='area',area=798000):
        directory=self.root/(kind+'_'+name);(directory/'log').mkdir(parents=True,exist_ok=True)
        (directory/'reports/timing').mkdir(parents=True,exist_ok=True)
        inputs={str(path):collector.sha(path) for path in (self.source,self.lib)}
        raw=''.join(f'{value}  {path}\n' for path,value in inputs.items())
        (directory/'log/inputs.before.sha256').write_text(raw)
        metadata=f'KARU_TOP=karudbg_top\nKARU_CLK_PS=5000\nKARU_DEFINES=KARU_DBG {" ".join(sorted(collector.FEATURES[name]))}\nKARU_NO_STA={1 if kind=="area" else 0}\nKARU_ABC_FAST={1 if kind=="area" else 0}\n'
        for tool,path in self.tools.items():metadata+=f'{tool}_EXECUTABLE={path}\n{collector.sha(path)}  {path}\n'
        (directory/'log/manifest.txt').write_text(metadata+raw)
        (directory/'log/syn.log').write_text(f'1. Executing Liberty frontend: {self.lib}\n')
        (directory/'reports/area.rpt').write_text(f"Chip area for module '\\leaf': 17.5\nChip area for top module '\\karudbg_top': {area}\n")
        if kind=='timing':
            for group in collector.GROUPS:
                (directory/f'reports/timing/{group}.csv.rpt').write_text('clock_a,end_a,-0.2500\nclock_b,end_b,-0.5000\n' if group=='reg2reg' else '')
            (directory/'reports/timing/summary.rpt').write_text('worst slack max -0.75\ntns max -42.50\n')
            (directory/'log/sta.log').write_text('OpenSTA completed\n')
        (directory/'log/inputs.after.sha256').write_text(raw)
        return directory
    def test_top_area_and_full_summary_not_csv_sum(self):
        self.fixture(kind='timing');row=collector.collect_row(self.root,'base','timing')
        self.assertEqual(row['state'],'complete')
        self.assertEqual(row['metrics']['area_kGE'],1000)
        self.assertEqual(row['metrics']['groups']['reg2reg']['minimum_slack_ns'],-.5)
        self.assertEqual(row['metrics']['tns_ns'],-42.5)
        self.assertEqual(collector.timing_summary('worst slack -0.75\ntns -42.50\n')['tns_ns'],-42.5)
        self.assertIsNone(row['metrics']['groups']['in2out']['minimum_slack_ns'])
    def test_changed_source_tool_or_library_withholds_metrics(self):
        for file in (self.source,self.tools['YOSYS'],self.lib):
            with self.subTest(file=file.name):
                original=file.read_bytes();self.fixture()
                self.assertEqual(collector.collect_row(self.root,'base','area')['state'],'complete')
                file.write_bytes(original+b' changed')
                row=collector.collect_row(self.root,'base','area')
                self.assertEqual(row['state'],'stale');self.assertNotIn('metrics',row)
                file.write_bytes(original)
    def test_exact_source_proof_cannot_waive_library_changes(self):
        directory=self.fixture();old_hash=collector.sha(self.source)
        self.source.write_text(self.source.read_text()+' // inactive-feature edit\n')
        current_hash=collector.sha(self.source)
        raw=(directory/'log/inputs.before.sha256').read_text().replace(old_hash,current_hash)
        (directory/'log/inputs.after.sha256').write_text(raw)
        (directory/'log/source-equivalence.json').write_text('{}')
        path=str(self.source)
        with mock.patch.object(collector,'PROVABLE_SOURCES',{path}), \
             mock.patch.object(collector,'verify_equivalence',return_value={path:current_hash}) as verifier:
            row=collector.collect_row(self.root,'base','area')
            self.assertEqual(row['state'],'complete')
            self.assertFalse(row['source_equivalence']['raw_fingerprints_identical'])
            self.assertEqual(row['provenance']['input_hashes'][path],old_hash)
            self.assertEqual(row['provenance']['effective_input_hashes'][path],current_hash)
            verifier.assert_called_once_with(directory,{path})
            verifier.reset_mock();self.lib.write_text(self.lib.read_text()+' changed')
            row=collector.collect_row(self.root,'base','area')
            self.assertEqual(row['state'],'stale');self.assertNotIn('metrics',row)
            verifier.assert_not_called()
    def test_dm_sequential_proof_only_applies_with_autoexec_disabled(self):
        self.source=self.root/'dbg/karudbg.v'
        self.source.parent.mkdir()
        self.source.write_text('module karudbg; endmodule\n')
        path=str(self.source)
        for name in ('base','sba','triggers','autoexec','full','full4'):
            with self.subTest(name=name):
                directory=self.fixture(name)
                self.source.write_text(self.source.read_text()+' // capture change\n')
                current=collector.sha(self.source)
                (directory/'log/source-equivalence.json').write_text('{}')
                with mock.patch.object(collector,'REPO',self.root), \
                     mock.patch.object(collector,'verify_equivalence',return_value={path:current}) as verifier:
                    row=collector.collect_row(self.root,name,'area')
                    if name in ('base','sba','triggers'):
                        self.assertEqual(row['state'],'complete')
                        self.assertEqual(row['source_equivalence']['methods'][path],
                                         'Yosys AUTOEXEC=0 sequential equivalence')
                        verifier.assert_called_once_with(directory,{path})
                    else:
                        self.assertEqual(row['state'],'stale')
                        self.assertNotIn('metrics',row)
                        verifier.assert_not_called()

    def test_trigger_proof_cannot_waive_active_vlsu_changes(self):
        self.source=self.root/'rtl/karu_vlsu.v'
        self.source.parent.mkdir()
        self.source.write_text('module karu_vlsu; endmodule\n')
        directory=self.fixture('triggers')
        self.source.write_text(self.source.read_text()+' // live stage change\n')
        (directory/'log/source-equivalence.json').write_text('{}')
        path=str(self.source)
        with mock.patch.object(collector,'REPO',self.root), \
             mock.patch.object(collector,'PROVABLE_SOURCES',{path}), \
             mock.patch.object(collector,'verify_equivalence',return_value={path:collector.sha(self.source)}) as verifier:
            row=collector.collect_row(self.root,'triggers','area')
            self.assertEqual(row['state'],'stale')
            self.assertNotIn('metrics',row)
            verifier.assert_not_called()

    def test_pending_and_comparable_delta(self):
        directory=self.fixture();(directory/'log/inputs.after.sha256').unlink()
        self.assertEqual(collector.collect_row(self.root,'base','area')['state'],'pending')
        self.fixture();self.fixture('autoexec',area=805980)
        rows={name:{kind:collector.collect_row(self.root,name,kind) for kind in ('area','timing')} for name in collector.ROWS}
        collector.deltas(rows)
        self.assertEqual(rows['autoexec']['area']['metrics']['delta_kGE'],10)
        self.assertEqual(rows['autoexec']['area']['metrics']['delta_percent'],1)
        # Keep a valid absolute measurement but withhold an apples-to-oranges delta.
        rows['autoexec']['area']['provenance']['config']['KARU_ABC_FAST']='0'
        collector.deltas(rows)
        self.assertFalse(rows['autoexec']['area']['comparison_to_base']['compatible'])
        self.assertNotIn('delta_kGE',rows['autoexec']['area']['metrics'])

if __name__=='__main__':unittest.main()
