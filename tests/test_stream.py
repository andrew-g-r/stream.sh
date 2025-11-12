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
