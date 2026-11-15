#!/usr/bin/env python3
"""Pure harness/parser regressions. Does not execute a native binary or compiler."""
import copy,importlib.util,json,subprocess,sys,tempfile,unittest
from pathlib import Path
from xml.etree import ElementTree as ET
H=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('native_unit_runner',H/'native-unit-tests.py');runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
manifest=runner.expected_manifest(H/'native-unit-expectations.json');names=manifest['tests']
def listing(values):
 text='native test startup log\n';suite=None
 for name in sorted(values):
  group,case=name.split('.')
  if group!=suite:suite=group;text+=suite+'.\n'
  text+='  '+case+'\n'
 return text
def xml(values):
 root=ET.Element('testsuites',tests=str(len(values)),failures='0',errors='0',disabled='0')
 for name in values:
  group,case=name.split('.');s=ET.SubElement(root,'testsuite',name=group)
  ET.SubElement(s,'testcase',name=case,classname=group,status='run',result='completed',time='0.001')
 return root
class NativeRunnerHarnessTest(unittest.TestCase):
 def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
 def tearDown(self):self.tmp.cleanup()
 def parsed(self,root):
  p=self.root/'result.xml';ET.ElementTree(root).write(p);return runner.parse_xml(p,names)
 def test_actual_expected35_complete_discovery(self):self.assertEqual(set(runner.parse_discovery(listing(names),names)),set(names))
 def test_zero_discovery_refused(self):
  with self.assertRaises(runner.Rejected):runner.parse_discovery('0 tests\n',names)
 def test_missing_registration_refused(self):
  with self.assertRaises(runner.Rejected):runner.parse_discovery(listing(names[:-1]),names)
 def test_extra_registration_refused(self):
  with self.assertRaises(runner.Rejected):runner.parse_discovery(listing(names+['OriginalPdfCredit.UnknownNewTest']),names)
 def test_duplicate_registration_refused(self):
  with self.assertRaises(runner.Rejected):runner.parse_discovery(listing(names+[names[0]]),names)
 def test_orphan_test_refused(self):
  with self.assertRaises(runner.Rejected):runner.parse_discovery('  orphan\n',names)
 def test_complete_xml_exact35(self):self.assertEqual(len(self.parsed(xml(names))),35)
 def test_xml_zero_count_refused(self):
  with self.assertRaises(runner.Rejected):self.parsed(xml([]))
 def test_xml_missing_test_refused(self):
  with self.assertRaises(runner.Rejected):self.parsed(xml(names[:-1]))
 def test_xml_duplicate_test_refused(self):
  with self.assertRaises(runner.Rejected):self.parsed(xml(names[:-1]+[names[0]]))
 def test_xml_skipped_test_refused(self):
  x=xml(names);x.find('.//testcase').set('result','skipped')
  with self.assertRaises(runner.Rejected):self.parsed(x)
 def test_xml_suppressed_test_refused(self):
  x=xml(names);x.find('.//testcase').set('status','notrun')
  with self.assertRaises(runner.Rejected):self.parsed(x)
 def test_global_failure_cannot_hide_behind_zero_root_count(self):
  x=xml(names);ET.SubElement(x,'failure',message='outside test failure')
  with self.assertRaises(runner.Rejected):self.parsed(x)
 def test_missing_xml_refused(self):
  with self.assertRaises(runner.Rejected):runner.parse_xml(self.root/'missing.xml',names)
 def test_bad_manifest_duplicate_or_zero_not_allowed(self):
  x=copy.deepcopy(manifest);x['tests'][-1]=x['tests'][0];p=self.root/'manifest.json';p.write_text(json.dumps(x))
  with self.assertRaises(runner.Rejected):runner.expected_manifest(p)
 def test_non_native_executable_refused(self):
  p=self.root/'libcef_static_unittests';p.write_text('#!/bin/sh\nexit0\n');p.chmod(0o700)
  with self.assertRaises(runner.Rejected):runner.macho_arm64_executable(p)
 def test_actual_process_timeout_retains_log_and_reaps_only_own_child(self):
  log=self.root/'timeout.log';r=runner.captured_run([sys.executable,'-c','import time;print("started",flush=True);time.sleep(30)'],self.root,dict(__import__('os').environ),log,0.05)
  self.assertTrue(r['timedOut']);self.assertNotEqual(r['exitCode'],0);self.assertIn('started',log.read_text())
 def test_actual_nonzero_process_is_not_a_pass(self):
  log=self.root/'failure.log';r=runner.captured_run([sys.executable,'-c','print("failed");raise SystemExit(7)'],self.root,dict(__import__('os').environ),log,3)
  self.assertEqual(r['exitCode'],7);self.assertFalse(r['timedOut']);self.assertIn('failed',log.read_text())
if __name__=='__main__':unittest.main()
