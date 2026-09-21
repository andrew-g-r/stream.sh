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
    def test_loop_is_an_input_option(self):
        args=self.arguments(self.run_stream('--file',self.media,'--loop','2'))
        self.assertLess(args.index('-stream_loop'),args.index('-i'))
        self.assertEqual(args[args.index('-stream_loop')+1],'2')
    def test_playlist_resolves_relative_names_and_crlf(self):
        other=self.root/'second clip.MKV';other.touch()
        playlist=self.root/'shows.m3u'
        playlist.write_bytes(b'#EXTM3U\r\na movie.mp4\r\nsecond clip.MKV\r\n')
        result=self.run_stream('--playlist',playlist)
        self.assertEqual(result.returncode,0,result.stderr)
        commands=[json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([args[args.index('-i')+1] for args in commands],[str(self.media),str(other)])
    def test_retry_count_is_bounded_and_failure_is_propagated(self):
        fake=self.bin/'ffmpeg'
        fake.write_text('#!/bin/sh\nprintf "attempt\\n"\nexit 7\n');fake.chmod(0o755)
        result=self.run_stream('--file',self.media,'--retries','2','--retry-delay','0')
        self.assertEqual(result.returncode,7)
        self.assertEqual(result.stdout.splitlines(),['attempt']*3)
    def test_termination_stops_child_and_skips_retries(self):
        import signal,time
        marker=self.root/'started'
        fake=self.bin/'ffmpeg'
        fake.write_text(f'#!{sys.executable}\nimport os,time\nfrom pathlib import Path\nPath({str(marker)!r}).write_text(str(os.getpid()))\ntime.sleep(30)\n')
        fake.chmod(0o755)
        process=subprocess.Popen(['/bin/bash',str(SCRIPT),'--file',str(self.media),'--retries','3'],cwd=self.root,env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        try:
            for _ in range(100):
                if marker.exists():break
                time.sleep(.02)
            self.assertTrue(marker.exists())
            child=int(marker.read_text())
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode,143)
            with self.assertRaises(ProcessLookupError):os.kill(child,0)
        finally:
            if process.poll() is None:os.killpg(process.pid,signal.SIGKILL);process.communicate()
    def test_probe_does_not_start_ffmpeg(self):
        probe=self.bin/'ffprobe'
        probe.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"streams":[]}\'\n');probe.chmod(0o755)
        result=self.run_stream('--file',self.media,'--probe')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout),{'streams':[]})
    def test_progress_is_machine_readable(self):
        args=self.arguments(self.run_stream('--file',self.media,'--progress'))
        self.assertEqual(args[args.index('-progress')+1],'pipe:1')
        self.assertIn('-nostats',args)
    def test_loudness_normalization_follows_gain(self):
        args=self.arguments(self.run_stream('--file',self.media,'--normalize-audio','--volume','-2'))
        self.assertEqual(args[args.index('-af')+1],'volume=-2dB,loudnorm=I=-16:TP=-1.5:LRA=11')
    def test_resize_keeps_an_even_width(self):
        args=self.arguments(self.run_stream('--file',self.media,'--height','720'))
        self.assertEqual(args[args.index('-vf')+1],'scale=-2:720')
        self.assertEqual(self.run_stream('--file',self.media,'--height','721').returncode,2)
    def test_video_copy_checks_codec_and_omits_encoder_flags(self):
        probe=self.bin/'ffprobe';probe.write_text('#!/bin/sh\nprintf "h264\\n"\n');probe.chmod(0o755)
        args=self.arguments(self.run_stream('--file',self.media,'--copy-video'))
        self.assertEqual(args[args.index('-c:v')+1],'copy')
        self.assertNotIn('-preset',args)
        probe.write_text('#!/bin/sh\nprintf "hevc\\n"\n')
        self.assertEqual(self.run_stream('--file',self.media,'--copy-video').returncode,2)
    def test_overwrite_requires_explicit_flag(self):
        args=self.arguments(self.run_stream('--file',self.media,'--output','preview.flv'))
        self.assertIn('-n',args)
        args=self.arguments(self.run_stream('--file',self.media,'--output','preview.flv','--overwrite'))
        self.assertIn('-y',args)
        self.assertNotIn('-n',args)
    def test_playlist_can_continue_but_preserves_failure_status(self):
        second=self.root/'second.mp4';second.touch()
        playlist=self.root/'shows.m3u';playlist.write_text('a movie.mp4\nsecond.mp4\n')
        fake=self.bin/'ffmpeg';fake.write_text('#!/bin/sh\nprintf "attempt\\n"\nexit 7\n');fake.chmod(0o755)
        result=self.run_stream('--playlist',playlist,'--continue-on-error')
        self.assertEqual(result.returncode,7)
        self.assertEqual(len(result.stdout.splitlines()),2)
    def test_hidden_media_is_opt_in(self):
        hidden=self.root/'.hidden.mp4';hidden.touch()
        self.assertNotIn('.hidden.mp4',self.run_stream('--list').stdout)
        self.assertIn('.hidden.mp4',self.run_stream('--list','--include-hidden').stdout)
    def test_explicit_options_override_profile_defaults(self):
        args=self.arguments(self.run_stream('--file',self.media,'--profile','low-bandwidth','--fps','30','--bitrate','1800k'))
        self.assertEqual(args[args.index('-r')+1],'30')
        self.assertEqual(args[args.index('-b:v')+1],'1800k')
    def test_leading_dash_and_newline_filenames_are_preserved(self):
        name='-clip\npart.mp4';path=self.root/name;path.touch()
        args=self.arguments(self.run_stream('--file',name))
        self.assertEqual(Path(args[args.index('-i')+1]).name,name)
        self.assertEqual(Path(args[args.index('-i')+1]).resolve(),path.resolve())
    def test_playlist_cannot_overwrite_a_single_local_output(self):
        playlist=self.root/'shows.m3u';playlist.write_text('a movie.mp4\na movie.mp4\n')
        result=self.run_stream('--playlist',playlist,'--output','one.flv','--overwrite')
        self.assertEqual(result.returncode,2)
    def test_live_outputs_do_not_require_seekable_headers(self):
        args=self.arguments(self.run_stream('--file',self.media))
        self.assertEqual(args[args.index('-flvflags')+1],'no_duration_filesize')
        args=self.arguments(self.run_stream('--file',self.media,'--output','out.flv'))
        self.assertNotIn('-flvflags',args)
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
