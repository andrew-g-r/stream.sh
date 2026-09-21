#!/usr/bin/env bash
# Stream local media with Bash 3.2+ and FFmpeg.
set -eo pipefail

usage() {
    cat <<'HELP'
Usage: stream.sh [options]
      --retries N         Retry failed streams up to N times (default 0, max 10)
      --retry-delay N     Seconds between retries (default 2, max 60)
      --shuffle           Randomize playlist order
      --playlist PATH     Stream a UTF-8 M3U playlist of local files
  -f, --file PATH          Stream one local media file
  -s, --search TEXT        Filter the interactive file picker
      --audio-bitrate RATE  AAC bitrate (default 128k)
      --loop N            Repeat input N times; -1 loops until interrupted
      --continue-on-error Continue playlists after exhausted retries; still exit nonzero
      --overwrite         Explicitly replace an existing local output file
      --copy-video        Copy existing H.264 video without re-encoding
      --normalize-audio   Apply single-pass EBU R128 loudness normalization
      --mute              Omit audio from the output
      --duration TIME     Stop after this many seconds or HH:MM:SS
  -t, --start-time TIME    Start at seconds or HH:MM:SS (default 0)
  -v, --volume DB          Audio gain in dB (default 0)
      --log-level LEVEL   quiet, error, warning, info, or debug
      --progress          Write FFmpeg key=value progress to stdout
      --doctor            Check Bash, FFmpeg, FFprobe, and H.264 support
      --probe             Show media metadata as JSON without streaming
      --dry-run           Print the shell-escaped FFmpeg command without running it
      --profile NAME      standard, low-bandwidth, or low-latency
      --preset NAME       x264 encoding preset (default medium)
      --height N          Scale to an even height while preserving aspect ratio
      --fps N             Frame rate, 1–120 (default 30)
      --bitrate RATE      Video bitrate, e.g. 2500k or 4M
      --output TARGET     RTMP/RTMPS URL or local .flv file (or STREAM_URL)
      --list              List matching media without streaming
      --null              Separate --list results with NUL for scripts
      --directory PATH    Browse this directory (default current directory)
      --include-hidden    Include hidden files and directories in discovery
      --recursive         Include subdirectories, without following symlinks
  -h, --help               Show this help
HELP
}

die() { printf 'stream.sh: %s\n' "$*" >&2; exit 2; }
need_value() { [[ -n "${2-}" ]] || die "$1 requires a value"; }
file=''
playlist=''
shuffle=0
retries=0
retry_delay=2
search=''
start_time='0'
duration=''
volume='0'
audio_bitrate=128k
mute=0
normalize_audio=0
copy_video=0
overwrite=0
continue_on_error=0
playlist_result=0
loop_count=0
media_dir='.'
recursive=0
include_hidden=0
fps=30
height=''
bitrate=2500k
preset=medium
profile=standard
bitrate_set=0
fps_set=0
preset_set=0
list_only=0
dry_run=0
ffmpeg_bin=${FFMPEG_BIN:-ffmpeg}
ffprobe_bin=${FFPROBE_BIN:-ffprobe}
probe_only=0
doctor=0
log_level=warning
progress=0
null_output=0
output=${STREAM_URL:-rtmp://127.0.0.1/live_stream/main}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --retries) need_value "$1" "${2-}"; retries=$2; shift 2 ;;
        --retry-delay) need_value "$1" "${2-}"; retry_delay=$2; shift 2 ;;
        --shuffle) shuffle=1; shift ;;
        --playlist) need_value "$1" "${2-}"; playlist=$2; shift 2 ;;
        -f|--file) need_value "$1" "${2-}"; file=$2; shift 2 ;;
        -s|--search) need_value "$1" "${2-}"; search=$2; shift 2 ;;
        --audio-bitrate) need_value "$1" "${2-}"; audio_bitrate=$2; shift 2 ;;
        --loop) need_value "$1" "${2-}"; loop_count=$2; shift 2 ;;
        --continue-on-error) continue_on_error=1; shift ;;
        --overwrite) overwrite=1; shift ;;
        --copy-video) copy_video=1; shift ;;
        --normalize-audio) normalize_audio=1; shift ;;
        --mute) mute=1; shift ;;
        --duration) need_value "$1" "${2-}"; duration=$2; shift 2 ;;
        -t|--start-time|--start_time) need_value "$1" "${2-}"; start_time=$2; shift 2 ;;
        -v|--volume) need_value "$1" "${2-}"; volume=$2; shift 2 ;;
        --log-level) need_value "$1" "${2-}"; log_level=$2; shift 2 ;;
        --progress) progress=1; shift ;;
        --doctor) doctor=1; shift ;;
        --probe) probe_only=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --profile) need_value "$1" "${2-}"; profile=$2; shift 2 ;;
        --preset) need_value "$1" "${2-}"; preset=$2; preset_set=1; shift 2 ;;
        --height) need_value "$1" "${2-}"; height=$2; shift 2 ;;
        --fps) need_value "$1" "${2-}"; fps=$2; fps_set=1; shift 2 ;;
        --bitrate) need_value "$1" "${2-}"; bitrate=$2; bitrate_set=1; shift 2 ;;
        --output) need_value "$1" "${2-}"; output=$2; shift 2 ;;
        --list) list_only=1; shift ;;
        --null) null_output=1; shift ;;
        --directory) need_value "$1" "${2-}"; media_dir=$2; shift 2 ;;
        --include-hidden) include_hidden=1; shift ;;
        --recursive) recursive=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; [[ $# -eq 1 ]] || die 'Expected one file after --'; file=$1; shift ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done

if [[ "$doctor" -eq 1 ]]; then
    printf 'Bash: %s\n' "$BASH_VERSION"
    for executable in "$ffmpeg_bin" "$ffprobe_bin"; do
        command -v "$executable" >/dev/null 2>&1 || die "Missing dependency: $executable"
        "$executable" -version
    done
    encoders=$("$ffmpeg_bin" -hide_banner -encoders 2>/dev/null)
    [[ "$encoders" == *libx264* ]] || die 'FFmpeg needs the libx264 encoder'
    printf 'H.264 encoder: available\n'
    exit 0
fi
case "$profile" in
    standard) ;;
    low-bandwidth)
        [[ "$bitrate_set" -eq 1 ]] || bitrate=900k
        [[ "$fps_set" -eq 1 ]] || fps=24
        ;;
    low-latency) [[ "$preset_set" -eq 1 ]] || preset=veryfast ;;
    *) die 'Profile must be standard, low-bandwidth, or low-latency' ;;
esac
case "$preset" in ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;; *) die 'Unknown x264 preset' ;; esac
valid_time() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ || "$1" =~ ^[0-9]+:[0-5][0-9]:[0-5][0-9]([.][0-9]+)?$ ]]
}
[[ "$fps" =~ ^[1-9][0-9]{0,2}$ && "$fps" -le 120 ]] || die 'FPS must be an integer from 1 to 120'
[[ "$bitrate" =~ ^[1-9][0-9]{0,5}[kKmM]$ ]] || die 'Bitrate must be a positive number followed by k or M'
[[ "$audio_bitrate" =~ ^[1-9][0-9]{0,3}k$ ]] || die 'Audio bitrate must be a positive integer followed by k'
[[ "$loop_count" == -1 || "$loop_count" =~ ^[0-9]{1,6}$ ]] || die 'Loop count must be -1 or a nonnegative integer up to 999999'
[[ "$retries" =~ ^(0|[1-9][0-9]?)$ && "$retries" -le 10 ]] || die 'Retries must be 0–10'
[[ "$retry_delay" =~ ^(0|[1-9][0-9]?)$ && "$retry_delay" -le 60 ]] || die 'Retry delay must be 0–60 seconds'
case "$log_level" in quiet|error|warning|info|debug) ;; *) die 'Unsupported log level' ;; esac
if [[ -n "$height" ]]; then
    [[ "$height" =~ ^[1-9][0-9]{1,3}$ && "$height" -ge 16 && "$height" -le 2160 ]] || die 'Height must be 16–2160'
    [[ $((height % 2)) -eq 0 ]] || die 'Height must be even for H.264'
fi
volume=${volume%dB}
[[ "$volume" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] || die 'Volume must be a number of decibels'
awk -v value="$volume" 'BEGIN{exit !(value>=-60 && value<=30)}' || die 'Volume must be between -60 and +30 dB'
[[ -z "$duration" ]] || valid_time "$duration" || die 'Duration must be nonnegative seconds or HH:MM:SS'
valid_time "$start_time" || die 'Start time must be nonnegative seconds or HH:MM:SS'
[[ "$include_hidden" -eq 0 ]] || shopt -s dotglob
files=()
collect_files() {
    local directory=${1:-$media_dir} candidate
    for candidate in "$directory"/*; do
        if [[ -d "$candidate" && ! -L "$candidate" && "$recursive" -eq 1 ]]; then
            collect_files "$candidate"
        elif [[ -f "$candidate" ]]; then
            local lower_candidate lower_search
            lower_candidate=$(printf '%s' "$candidate" | LC_ALL=C tr '[:upper:]' '[:lower:]')
            lower_search=$(printf '%s' "$search" | LC_ALL=C tr '[:upper:]' '[:lower:]')
            case "$lower_candidate" in
                *.mp4|*.mkv|*.avi|*.mov|*.webm|*.m4v)
                    [[ "$lower_candidate" == *"$lower_search"* ]] && files+=("$candidate")
                    ;;
            esac
        fi
    done
    return 0
}
[[ -d "$media_dir" ]] || die 'Media directory does not exist'
if [[ "$list_only" -eq 1 ]]; then
    collect_files
    if [[ ${#files[@]} -gt 0 ]]; then
        if [[ "$null_output" -eq 1 ]]; then printf '%s\0' "${files[@]}"; else printf '%s\n' "${files[@]}"; fi
    fi
    exit 0
fi
if [[ -n "$playlist" ]]; then
    [[ -z "$file" ]] || die '--playlist and --file are mutually exclusive'
    [[ -r "$playlist" && -f "$playlist" ]] || die 'Playlist is not a readable file'
    playlist_dir=$(cd "$(dirname "$playlist")" && pwd)
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        line=${line#$'\xef\xbb\xbf'}
        [[ -n "$line" && "$line" != \#* ]] || continue
        [[ "$line" != *://* ]] || die 'Playlists support local files only'
        [[ "$line" == /* ]] || line="$playlist_dir/$line"
        [[ -f "$line" && -r "$line" ]] || die "Playlist file is missing or unreadable: $line"
        files+=("$line")
        [[ ${#files[@]} -le 10000 ]] || die 'Playlist exceeds 10000 entries'
    done < "$playlist"
    [[ ${#files[@]} -gt 0 ]] || die 'Playlist contains no media files'
elif [[ -n "$file" ]]; then
    files=("$file")
else
    collect_files
    [[ ${#files[@]} -gt 0 ]] || die 'No matching media files found'
    [[ -t 0 ]] || die 'Use --file for noninteractive streaming'
    PS3='Choose a file (or quit): '
    select selection in "${files[@]}" quit; do
        [[ "$selection" == quit ]] && exit 0
        if [[ -n "$selection" ]]; then file=$selection; break; fi
        printf 'Choose a listed number.\n' >&2
    done
    files=("$file")
fi
if [[ ${#files[@]} -gt 1 && "$output" != rtmp://* && "$output" != rtmps://* && "$probe_only" -eq 0 ]]; then
    die 'Multiple playlist entries require an RTMP target; local output would overwrite earlier entries'
fi
[[ "$loop_count" != -1 || ${#files[@]} -eq 1 ]] || die 'An infinite loop cannot advance through a playlist'
if [[ "$shuffle" -eq 1 ]]; then
    for ((i=${#files[@]}-1;i>0;i--)); do
        j=$((RANDOM % (i+1)))
        temporary=${files[$i]}
        files[i]=${files[j]}
        files[j]=$temporary
    done
fi
for file in "${files[@]}"; do
    [[ -n "$file" && -f "$file" && -r "$file" ]] || die 'Input must be a readable local file'
    [[ "$file" == /* ]] || file="$PWD/$file"
    if [[ "$probe_only" -eq 1 ]]; then
        command -v "$ffprobe_bin" >/dev/null 2>&1 || die 'FFprobe is required for --probe'
        "$ffprobe_bin" -v error -show_format -show_streams -of json "$file"
        continue
    fi
    case "$output" in
        rtmp://*|rtmps://*) [[ "$output" != *$'\n'* && "$output" != *$'\r'* ]] || die 'Output URL contains a newline' ;;
        *.flv) [[ "$output" != -* && "$output" != *://* ]] || die 'Unsupported output target' ;;
        *) die 'Output must be an RTMP/RTMPS URL or a local .flv file' ;;
    esac
    command -v "$ffmpeg_bin" >/dev/null 2>&1 || die 'FFmpeg is required; install it and try again'
    audio_filter="volume=${volume}dB"
    [[ "$normalize_audio" -eq 0 ]] || audio_filter="$audio_filter,loudnorm=I=-16:TP=-1.5:LRA=11"
    audio_args=(-map '0:a:0?' -af "$audio_filter" -c:a aac -b:a "$audio_bitrate" -ar 48000)
    [[ "$mute" -eq 0 ]] || audio_args=(-an)
    duration_args=()
    [[ -z "$duration" ]] || duration_args=(-t "$duration")
    progress_args=()
    [[ "$progress" -eq 0 ]] || progress_args=(-progress pipe:1 -nostats)
    scale_args=()
    [[ -z "$height" ]] || scale_args=(-vf "scale=-2:${height}")
    tune_args=()
    [[ "$profile" != low-latency ]] || tune_args=(-tune zerolatency)
    video_args=(-pix_fmt yuv420p "${scale_args[@]}" -c:v libx264 -preset "$preset" "${tune_args[@]}"
        -r "$fps" -g "$((fps*2))" -keyint_min "$((fps*2))" -sc_threshold 0
        -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$bitrate")
    if [[ "$copy_video" -eq 1 ]]; then
        [[ -z "$height" && "$profile" == standard ]] || die 'Copy mode cannot resize or apply an encoding profile'
        command -v "$ffprobe_bin" >/dev/null 2>&1 || die 'FFprobe is required for --copy-video'
        codec=$("$ffprobe_bin" -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$file") || die 'Cannot inspect video codec'
        [[ "$codec" == h264 ]] || die 'Copy mode requires an H.264 video stream'
        video_args=(-c:v copy)
    fi
    muxer_args=()
    case "$output" in rtmp://*|rtmps://*) muxer_args=(-flvflags no_duration_filesize) ;; esac
    overwrite_arg=-n
    [[ "$overwrite" -eq 0 ]] || overwrite_arg=-y
    command_args=(-hide_banner -loglevel "$log_level" "${progress_args[@]}" -nostdin "$overwrite_arg" -stream_loop "$loop_count" -re -ss "$start_time" -i "$file"
        -map 0:v:0 -sn -dn "${video_args[@]}" "${audio_args[@]}" "${duration_args[@]}" "${muxer_args[@]}" -f flv "$output")
    if [[ "$dry_run" -eq 1 ]]; then
        printf '%q ' "$ffmpeg_bin" "${command_args[@]}"
        printf '\n'
        continue
    fi
    child=''
    # Called by the INT and TERM trap strings below.
    # shellcheck disable=SC2329
    stop_stream() {
        trap - INT TERM
        if [[ -n "$child" ]]; then
            kill -TERM "$child" 2>/dev/null || true
            wait "$child" 2>/dev/null || true
        fi
        exit "$1"
    }
    trap 'stop_stream 130' INT
    trap 'stop_stream 143' TERM
    attempt=0
    while true; do
        "$ffmpeg_bin" "${command_args[@]}" &
        child=$!
        if wait "$child"; then child=''; break; else result=$?; child=''; fi
        if [[ "$attempt" -ge "$retries" ]]; then
            [[ "$continue_on_error" -eq 1 ]] || exit "$result"
            playlist_result=$result
            break
        fi
        attempt=$((attempt+1))
        printf 'Stream failed; retry %s/%s in %s seconds.\n' "$attempt" "$retries" "$retry_delay" >&2
        sleep "$retry_delay" &
        child=$!
        wait "$child" || true
        child=''
    done
done

exit "$playlist_result"
