import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT=Path(__file__).resolve().parents[1]/'stream.sh'
class StreamTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.bin=self.root/'bin';self.bin.mkdir()
        fake=self.bin/'ffmpeg'
        fake.write_text(f'#!{sys.executable}\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        fake.chmod(0o755)
        self.env={**os.environ,'PATH':str(self.bin)+os.pathsep+os.environ['PATH']}
        self.media=self.root/'a movie.mp4';self.media.touch()
    def run_stream(self,*args,input=None):
        return subprocess.run(['/bin/bash',str(SCRIPT),*map(str,args)],cwd=self.root,env=self.env,
                              input=input,capture_output=True,text=True,timeout=10)
    def arguments(self,result):
        self.assertEqual(result.returncode,0,result.stderr)
        return json.loads(result.stdout)
    def test_recursive_case_insensitive_search_and_nul_listing(self):
        sub=self.root/'sub';sub.mkdir()
        wanted=sub/'DEMO clip.MKV';wanted.touch()
        (sub/'loop').symlink_to(self.root,target_is_directory=True)
        result=self.run_stream('--list','--recursive','--search','demo','--null')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'./sub/DEMO clip.MKV\0')
    def test_custom_output_and_unsupported_protocol(self):
        args=self.arguments(self.run_stream('--file',self.media,'--output','rtmps://example.test/live/key'))
        self.assertEqual(args[-1],'rtmps://example.test/live/key')
        self.assertEqual(self.run_stream('--file',self.media,'--output','https://example.test').returncode,2)
    def test_dry_run_preserves_shell_metacharacters(self):
        import shlex
        weird=self.root/'a;$(whoami) clip.mp4';weird.touch()
        result=self.run_stream('--file',weird,'--dry-run')
        self.assertEqual(result.returncode,0,result.stderr)
        args=shlex.split(result.stdout)
        self.assertEqual(args[args.index('-i')+1],str(weird))
    def test_missing_ffmpeg_is_actionable(self):
        self.env['FFMPEG_BIN']=str(self.root/'missing')
        result=self.run_stream('--file',self.media)
        self.assertEqual(result.returncode,2)
        self.assertIn('FFmpeg is required',result.stderr)
    def test_seek_validation_and_legacy_option(self):
        self.assertEqual(self.run_stream('--file',self.media,'--start-time','1:90:00').returncode,2)
        args=self.arguments(self.run_stream('--file',self.media,'--start_time','00:00:05.5'))
        self.assertLess(args.index('-ss'),args.index('-i'))
        self.assertEqual(args[args.index('-ss')+1],'00:00:05.5')
    def test_volume_validation_prevents_filter_injection(self):
        for volume in ['9,amix','NaN','100','-80']:
            self.assertEqual(self.run_stream('--file',self.media,'--volume',volume).returncode,2)
        args=self.arguments(self.run_stream('--file',self.media,'--volume','-3dB'))
        self.assertEqual(args[args.index('-af')+1],'volume=-3dB')
    def test_fps_updates_keyframe_interval(self):
        args=self.arguments(self.run_stream('--file',self.media,'--fps','24','--bitrate','1500k'))
        self.assertEqual(args[args.index('-g')+1],'48')
        self.assertEqual(args[args.index('-b:v')+1],'1500k')
        self.assertEqual(self.run_stream('--file',self.media,'--fps','0').returncode,2)
    def test_encoding_profiles(self):
        args=self.arguments(self.run_stream('--file',self.media,'--profile','low-latency'))
        self.assertEqual(args[args.index('-tune')+1],'zerolatency')
        args=self.arguments(self.run_stream('--file',self.media,'--profile','low-bandwidth'))
        self.assertEqual(args[args.index('-b:v')+1],'900k')
    def test_duration_is_an_output_option(self):
        args=self.arguments(self.run_stream('--file',self.media,'--duration','3.5'))
        self.assertGreater(args.index('-t'),args.index('-i'))
        self.assertEqual(args[args.index('-t')+1],'3.5')
    def test_optional_audio_and_compatible_pixel_format(self):
        args=self.arguments(self.run_stream('--file',self.media))
        self.assertIn('0:a:0?',args)
        self.assertEqual(args[args.index('-pix_fmt')+1],'yuv420p')
    def test_muting_omits_audio_filters(self):
        args=self.arguments(self.run_stream('--file',self.media,'--mute'))
        self.assertIn('-an',args)
        self.assertNotIn('-af',args)
    def test_help_and_unknown_option(self):
        self.assertEqual(self.run_stream('--help').returncode,0)
        self.assertEqual(self.run_stream('--typo').returncode,2)
    def test_missing_values(self):
        for option in ['--file','--search','--start-time','--volume']:
            self.assertEqual(self.run_stream(option).returncode,2)
    def test_filename_with_spaces_is_one_argument(self):
        args=self.arguments(self.run_stream('--file',self.media))
        self.assertEqual(args[args.index('-i')+1],str(self.media))
    def test_noninteractive_selection_does_not_hang(self):
        self.assertEqual(self.run_stream().returncode,2)
