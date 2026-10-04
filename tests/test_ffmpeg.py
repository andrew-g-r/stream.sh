"""Real codec and muxer smoke tests; no broadcast or network service needed."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "stream.sh"


@unittest.skipUnless(
    shutil.which("ffmpeg") and shutil.which("ffprobe"),
    "FFmpeg and FFprobe are optional for local tests",
)
class FFmpegTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.video = self.root / "sample clip.mp4"
        self.silent = self.root / "silent.mp4"
        base = [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=160x120:rate=24:duration=0.8",
        ]
        subprocess.run(
            base
            + [
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=48000:duration=0.8",
                "-c:v",
                "libx264",
                "-preset",
                "ultrafast",
                "-c:a",
                "aac",
                str(self.video),
            ],
            check=True,
            capture_output=True,
            timeout=15,
        )
        subprocess.run(
            base + ["-c:v", "libx264", "-preset", "ultrafast", str(self.silent)],
            check=True,
            capture_output=True,
            timeout=15,
        )

    def stream(self, source, *options):
        target = self.root / "output.flv"
        env = {
            **os.environ,
            "FFMPEG_BIN": shutil.which("ffmpeg"),
            "FFPROBE_BIN": shutil.which("ffprobe"),
        }
        result = subprocess.run(
            [
                "/bin/bash",
                str(SCRIPT),
                "--file",
                str(source),
                "--duration",
                "0.5",
                "--output",
                str(target),
                *options,
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = subprocess.run(
            ["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(target)],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
        return json.loads(data.stdout)["streams"]

    def test_normalized_resized_h264_and_aac(self):
        streams = self.stream(
            self.video, "--normalize-audio", "--height", "64", "--preset", "ultrafast"
        )
        self.assertEqual(streams[0]["codec_name"], "h264")
        self.assertEqual(streams[0]["height"], 64)
        audio = next(s for s in streams if s["codec_type"] == "audio")
        self.assertEqual(audio["codec_name"], "aac")
        self.assertEqual(audio["sample_rate"], "48000")

    def test_silent_video_and_copy_mode(self):
        streams = self.stream(self.silent, "--copy-video")
        self.assertEqual([s["codec_type"] for s in streams], ["video"])

    def test_local_rtmp_round_trip_delivers_decodable_frames(self):
        import socket

        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        url = f"rtmp://127.0.0.1:{port}/live/test"
        received = self.root / "received.flv"
        receiver = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-listen", "1", "-i", url, "-c", "copy", str(received)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            sender = subprocess.run(
                [
                    "/bin/bash",
                    str(SCRIPT),
                    "--file",
                    str(self.video),
                    "--duration",
                    "0.6",
                    "--preset",
                    "ultrafast",
                    "--output",
                    url,
                    "--retries",
                    "3",
                    "--retry-delay",
                    "1",
                ],
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(sender.returncode, 0, sender.stderr)
            receiver.communicate(timeout=10)
            self.assertEqual(receiver.returncode, 0)
            probe = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-count_frames",
                    "-show_entries",
                    "stream=codec_name,nb_read_frames",
                    "-of",
                    "json",
                    str(received),
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=10,
            )
            streams = json.loads(probe.stdout)["streams"]
            video = next(s for s in streams if s["codec_name"] == "h264")
            self.assertGreater(int(video["nb_read_frames"]), 0)
        finally:
            if receiver.poll() is None:
                receiver.terminate()
                receiver.communicate(timeout=5)
