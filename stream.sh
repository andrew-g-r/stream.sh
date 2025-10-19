#!/usr/bin/env bash
# Stream local media with Bash 3.2+ and FFmpeg.
set -eo pipefail

usage() {
    cat <<'HELP'
Usage: stream.sh [options]
  -f, --file PATH          Stream one local media file
  -s, --search TEXT        Filter the interactive file picker
  -t, --start-time TIME    Start at seconds or HH:MM:SS (default 0)
  -v, --volume DB          Audio gain in dB (default 0)
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
volume='0'
media_dir='.'
recursive=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file) need_value "$1" "${2-}"; file=$2; shift 2 ;;
        -s|--search) need_value "$1" "${2-}"; search=$2; shift 2 ;;
        -t|--start-time|--start_time) need_value "$1" "${2-}"; start_time=$2; shift 2 ;;
        -v|--volume) need_value "$1" "${2-}"; volume=$2; shift 2 ;;
        --directory) need_value "$1" "${2-}"; media_dir=$2; shift 2 ;;
        --recursive) recursive=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; [[ $# -eq 1 ]] || die 'Expected one file after --'; file=$1; shift ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done

files=()
collect_files() {
    local directory=${1:-$media_dir} candidate
    for candidate in "$directory"/*; do
        if [[ -d "$candidate" && ! -L "$candidate" && "$recursive" -eq 1 ]]; then
            collect_files "$candidate"
        elif [[ -f "$candidate" ]]; then
            case "$candidate" in *.mp4|*.mkv|*.avi) files+=("$candidate") ;; esac
        fi
    done
}
[[ -d "$media_dir" ]] || die 'Media directory does not exist'
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
command -v ffmpeg >/dev/null 2>&1 || die 'FFmpeg is required; install it and try again'
command_args=(-hide_banner -nostdin -re -ss "$start_time" -i "$file"
    -c:v libx264 -preset medium -r 30 -g 60 -keyint_min 60 -sc_threshold 0
    -b:v 2500k -maxrate 2500k -bufsize 5000k -af "volume=${volume}dB"
    -c:a aac -b:a 128k -f flv rtmp://127.0.0.1/live_stream/main)
exec ffmpeg "${command_args[@]}"
