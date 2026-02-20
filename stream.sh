#!/usr/bin/env bash
# Stream local media with Bash 3.2+ and FFmpeg.
set -eo pipefail

usage() {
    cat <<'HELP'
Usage: stream.sh [options]
  -f, --file PATH          Stream one local media file
  -s, --search TEXT        Filter the interactive file picker
      --duration TIME     Stop after this many seconds or HH:MM:SS
  -t, --start-time TIME    Start at seconds or HH:MM:SS (default 0)
  -v, --volume DB          Audio gain in dB (default 0)
      --dry-run           Print the shell-escaped FFmpeg command without running it
      --profile NAME      standard, low-bandwidth, or low-latency
      --preset NAME       x264 encoding preset (default medium)
      --fps N             Frame rate, 1–120 (default 30)
      --bitrate RATE      Video bitrate, e.g. 2500k or 4M
      --output TARGET     RTMP/RTMPS URL or local .flv file (or STREAM_URL)
      --list              List matching media without streaming
      --null              Separate --list results with NUL for scripts
      --directory PATH    Browse this directory (default current directory)
      --recursive         Include subdirectories, without following symlinks
  -h, --help               Show this help
HELP
}

die() { printf 'stream.sh: %s\n' "$*" >&2; exit 2; }
need_value() { [[ -n "${2-}" ]] || die "$1 requires a value"; }
file=''
search=''
start_time='0'
duration=''
volume='0'
media_dir='.'
recursive=0
fps=30
bitrate=2500k
preset=medium
profile=standard
list_only=0
dry_run=0
ffmpeg_bin=${FFMPEG_BIN:-ffmpeg}
null_output=0
output=${STREAM_URL:-rtmp://127.0.0.1/live_stream/main}
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file) need_value "$1" "${2-}"; file=$2; shift 2 ;;
        -s|--search) need_value "$1" "${2-}"; search=$2; shift 2 ;;
        --duration) need_value "$1" "${2-}"; duration=$2; shift 2 ;;
        -t|--start-time|--start_time) need_value "$1" "${2-}"; start_time=$2; shift 2 ;;
        -v|--volume) need_value "$1" "${2-}"; volume=$2; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --profile) need_value "$1" "${2-}"; profile=$2; shift 2 ;;
        --preset) need_value "$1" "${2-}"; preset=$2; shift 2 ;;
        --fps) need_value "$1" "${2-}"; fps=$2; shift 2 ;;
        --bitrate) need_value "$1" "${2-}"; bitrate=$2; shift 2 ;;
        --output) need_value "$1" "${2-}"; output=$2; shift 2 ;;
        --list) list_only=1; shift ;;
        --null) null_output=1; shift ;;
        --directory) need_value "$1" "${2-}"; media_dir=$2; shift 2 ;;
        --recursive) recursive=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; [[ $# -eq 1 ]] || die 'Expected one file after --'; file=$1; shift ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done

case "$profile" in
    standard) ;;
    low-bandwidth) bitrate=900k; fps=24 ;;
    low-latency) preset=veryfast ;;
    *) die 'Profile must be standard, low-bandwidth, or low-latency' ;;
esac
case "$preset" in ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;; *) die 'Unknown x264 preset' ;; esac
valid_time() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ || "$1" =~ ^[0-9]+:[0-5][0-9]:[0-5][0-9]([.][0-9]+)?$ ]]
}
[[ "$fps" =~ ^[1-9][0-9]*$ && "$fps" -le 120 ]] || die 'FPS must be an integer from 1 to 120'
[[ "$bitrate" =~ ^[1-9][0-9]{0,5}[kKmM]$ ]] || die 'Bitrate must be a positive number followed by k or M'
volume=${volume%dB}
[[ "$volume" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] || die 'Volume must be a number of decibels'
awk -v value="$volume" 'BEGIN{exit !(value>=-60 && value<=30)}' || die 'Volume must be between -60 and +30 dB'
[[ -z "$duration" ]] || valid_time "$duration" || die 'Duration must be nonnegative seconds or HH:MM:SS'
valid_time "$start_time" || die 'Start time must be nonnegative seconds or HH:MM:SS'
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
if [[ -z "$file" ]]; then
    collect_files
    [[ ${#files[@]} -gt 0 ]] || die 'No matching media files found'
    [[ -t 0 ]] || die 'Use --file for noninteractive streaming'
    PS3='Choose a file (or quit): '
    select selection in "${files[@]}" quit; do
        [[ "$selection" == quit ]] && exit 0
        if [[ -n "$selection" ]]; then file=$selection; break; fi
        printf 'Choose a listed number.\n' >&2
    done
fi
[[ -n "$file" && -f "$file" && -r "$file" ]] || die 'Input must be a readable local file'
file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
case "$output" in
    rtmp://*|rtmps://*) [[ "$output" != *$'\n'* && "$output" != *$'\r'* ]] || die 'Output URL contains a newline' ;;
    *.flv) [[ "$output" != -* && "$output" != *://* ]] || die 'Unsupported output target' ;;
    *) die 'Output must be an RTMP/RTMPS URL or a local .flv file' ;;
esac
command -v "$ffmpeg_bin" >/dev/null 2>&1 || die 'FFmpeg is required; install it and try again'
duration_args=()
[[ -z "$duration" ]] || duration_args=(-t "$duration")
tune_args=()
[[ "$profile" != low-latency ]] || tune_args=(-tune zerolatency)
command_args=(-hide_banner -nostdin -n -re -ss "$start_time" -i "$file"
    -c:v libx264 -preset "$preset" "${tune_args[@]}" -r "$fps" -g "$((fps*2))" -keyint_min "$((fps*2))" -sc_threshold 0
    -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$bitrate" -af "volume=${volume}dB"
    -c:a aac -b:a 128k "${duration_args[@]}" -f flv "$output")
if [[ "$dry_run" -eq 1 ]]; then
    printf '%q ' "$ffmpeg_bin" "${command_args[@]}"
    printf '\n'
    exit 0
fi
exec "$ffmpeg_bin" "${command_args[@]}"
