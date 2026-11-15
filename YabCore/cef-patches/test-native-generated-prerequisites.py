#!/usr/bin/env python3
"""Pure production target-selector tests, no Ninja/compiler invocation."""
from pathlib import Path
import importlib.util,unittest
p=Path(__file__).with_name('native-generated-prerequisites.py');spec=importlib.util.spec_from_file_location('native_generated',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
sources=list(m.VARIANTS)
expected={target for s,blink in m.VARIANTS.items() for target in ['gen/'+s+'.h','gen/'+s+'-shared.h','gen/'+s+'-shared-internal.h']+(['gen/'+s+'-blink.h'] if blink else [])}
class GeneratedPrerequisiteTests(unittest.TestCase):
 def test_exact22_registered_outputs(self):self.assertEqual(len(m.selected_targets(sources,expected)),22)
 def test_frame_blink_required(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources,expected-{'gen/third_party/blink/public/mojom/frame/frame.mojom-blink.h'})
 def test_frame_shared_required(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources,expected-{'gen/third_party/blink/public/mojom/frame/frame.mojom-shared.h'})
 def test_frame_internal_required(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources,expected-{'gen/third_party/blink/public/mojom/frame/frame.mojom-shared-internal.h'})
 def test_audio_blink_required(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources,expected-{'gen/media/mojo/mojom/audio_stream_factory.mojom-blink.h'})
 def test_url_request_blink_required(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources,expected-{'gen/services/network/public/mojom/url_request.mojom-blink.h'})
 def test_media_stream_blink_required(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources,expected-{'gen/third_party/blink/public/mojom/mediastream/media_stream.mojom-blink.h'})
 def test_pdf_unconfigured_blink_not_silently_enabled(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources,expected|{'gen/pdf/mojom/pdf.mojom-blink.h'})
 def test_video_unconfigured_blink_not_silently_enabled(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources,expected|{'gen/services/video_capture/public/mojom/video_source.mojom-blink.h'})
 def test_normal_output_required(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources,expected-{'gen/pdf/mojom/pdf.mojom.h'})
 def test_unknown_input_requires_review(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources+['unknown.mojom'],expected)
 def test_duplicate_input_refused(self):
  with self.assertRaises(RuntimeError):m.selected_targets(sources+[sources[0]],expected)
 def test_input_order_has_no_authority(self):self.assertEqual(m.selected_targets(list(reversed(sources)),expected),expected)
 def test_unrelated_graph_outputs_do_not_expand_generation(self):self.assertEqual(m.selected_targets(sources,expected|{'gen/unrelated/extra.h'}),expected)
if __name__=='__main__':unittest.main()
