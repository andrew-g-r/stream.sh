# stream.sh

A portable Bash launcher for reliable local-media streaming with FFmpeg. Runs with macOS's bundled Bash 3.2 and current Bash on Linux. Handles quoted filenames, recursive browsing, playlists, profiles, looping, retries, progress, and graceful cancellation.

## Quick start

Install FFmpeg with the `libx264` encoder. FFprobe is included in standard FFmpeg distributions. An RTMP server is needed for network broadcasting; a local `.flv` recording needs no server.

```sh
./stream.sh --doctor
./stream.sh --file '/path/to/movie.mp4' --output preview.flv --duration 10
./stream.sh --file '/path/to/movie.mp4'
```

The default destination is `rtmp://127.0.0.1/live_stream/main`. Set `STREAM_URL` or pass `--output` for your destination. Existing local outputs are protected unless you pass `--overwrite`. Use `--help` for every option.

## Choose media

```sh
./stream.sh --directory '/path/to/media' --recursive --search demo
./stream.sh --directory '/path/to/media' --recursive --list
./stream.sh --directory '/path/to/media' --recursive --list --null
./stream.sh --playlist '/path/to/shows.m3u' --shuffle
```

Interactive selection requires a terminal. Scripts should use `--file`, `--playlist`, or `--list`. Search is case-insensitive. Recognized extensions: MP4, MKV, AVI, MOV, WebM, M4V. Hidden media is opt-in with `--include-hidden`; recursion does not follow directory symlinks. `--null` makes listing safe for filenames containing newlines.

Playlists are UTF-8 M3U files with one local filename per line. Relative filenames resolve beside the playlist; comments and blank lines are ignored. Remote playlist URLs are rejected. Each playlist entry opens a new RTMP connection, so a receiver may briefly reconnect between entries. Multiple playlist entries cannot target one local output file.

## Encoding and playback

```sh
./stream.sh --file movie.mp4 --start-time 00:00:05 --duration 60 --volume -3
./stream.sh --file movie.mp4 --profile low-bandwidth --height 480
./stream.sh --file movie.mp4 --profile low-latency --fps 30 --bitrate 2500k
./stream.sh --file movie.mp4 --normalize-audio --audio-bitrate 128k
./stream.sh --file movie.mp4 --copy-video
./stream.sh --file movie.mp4 --loop -1 --mute
```

The standard profile uses H.264, 30 fps, a two-second keyframe interval, AAC at 48 kHz, and a 2500k video bitrate. Low bandwidth defaults to 900k/24 fps; low latency uses `veryfast` and `zerolatency`. Explicit `--fps`, `--bitrate`, and `--preset` override profile defaults.

`--height` preserves aspect ratio and uses even dimensions. `--copy-video` checks for H.264 and skips video encoding; it cannot resize or use a profile. Its source timestamps/keyframes remain unchanged. Audio is still encoded to AAC unless muted. Files without audio are supported.

Volume is limited to −60 through +30 dB. Loudness normalization is a single-pass `loudnorm` filter targeting −16 LUFS, −1.5 dBTP and LRA 11; it is not an offline two-pass mastering workflow. `--loop N` repeats the input N additional times; `-1` loops forever and is allowed only for a single input. The legacy `--start_time` spelling remains supported.

## Reliability and diagnostics

```sh
./stream.sh --file movie.mp4 --dry-run
./stream.sh --file movie.mp4 --probe
./stream.sh --file movie.mp4 --retries 3 --retry-delay 2 --progress
./stream.sh --playlist shows.m3u --continue-on-error
```

Retries are disabled by default and capped at ten. Each retry restarts the file at the configured start time; it does not resume from the last transmitted frame. INT/TERM stops FFmpeg and prevents retries. Playlist failures normally stop playback; `--continue-on-error` proceeds to the next item but still returns a nonzero exit status.

`--progress` writes FFmpeg `key=value` progress to stdout. Diagnostic messages go to stderr. `--log-level` controls FFmpeg verbosity. `FFMPEG_BIN` and `FFPROBE_BIN` select alternate executables. No command or config file is evaluated as shell code.

Stream URLs may contain private keys. Dry-run output and FFmpeg diagnostics can contain the destination; avoid publishing those logs. Keep credentials in environment variables rather than committed scripts.

## Local nginx / HLS

[examples/nginx.conf](examples/nginx.conf) is a minimal configuration for nginx with [nginx-rtmp-module](https://github.com/arut/nginx-rtmp-module). It binds RTMP and HLS to localhost and restricts publishers and viewers to the local machine. Load the module using your distribution's normal configuration first.

Create an nginx runtime prefix with `logs/` and `hls/` writable by its worker, then validate the config with `nginx -t -p /absolute/runtime/prefix/ -c /absolute/path/to/nginx.conf`. Start nginx with the same prefix/config. After publishing the `main` stream, the HLS playlist is `http://127.0.0.1:8080/hls/main.m3u8`.

Remote viewers require intentional listen/access-rule changes and appropriate network authentication. The example is a local development configuration, not a public streaming service.

## Development

```sh
python3 -m pip install -r requirements-dev.txt
shellcheck stream.sh
bash -n stream.sh
python3 -m unittest discover -s tests -v
```

Python is used only for tests. Unit tests mock FFmpeg and check exact arguments, playlists, failures, and signal handling. When FFmpeg/FFprobe are installed, smoke tests generate tiny videos and verify real H.264/AAC output, normalization, scaling, silent video, and a real localhost RTMP transfer. CI checks macOS and Linux.

Author: Andrew Russell.
