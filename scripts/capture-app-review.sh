#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/capture-app-review.sh MODEL [NEW_OUTPUT_DIRECTORY]

Follow the prompts to select a file in Finder, open Quick Look with Space, inspect the model, and click Open with Spacebar 3D. The script then records the viewer, Settings, Help and Privacy chapters. It writes app-review.mp4 under build/media-captures unless an output directory is specified.

Requires macOS 26+, the Swift command-line tools, FFmpeg with drawtext and subtitles, and Screen & System Audio Recording access for the terminal. The selected file must have an interactive Finder Quick Look preview. Open the same file in the installed Spacebar 3D app when prompted. Close any current Finder Quick Look preview and viewer document with the same filename before recording. Keep your terminal visible so you can follow the prompts. Accessibility and Automation permissions are unnecessary.

SPACEBAR3D_REVIEW_APP overrides /Applications/Spacebar 3D.app.
SPACEBAR3D_REVIEW_CAPTURE_APP selects a capture-enabled app for the viewer tour. By default the script builds one separately using the normal development build setup.
SPACEBAR3D_REVIEW_ANIMATION_MODEL optionally selects a second model for demonstrating animation playback.
USAGE
}

fail() { printf 'capture-app-review: %s\n' "$*" >&2; exit 1; }

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then usage; exit 0; fi
if [[ $# -lt 1 || $# -gt 2 ]]; then usage >&2; exit 2; fi
[[ $(uname -s) == Darwin ]] || fail 'This command requires macOS.'
[[ -f "$1" && -r "$1" ]] || fail 'The model must be a readable regular file.'
command -v ffmpeg >/dev/null || fail 'Install FFmpeg with drawtext and subtitles support.'
command -v ffprobe >/dev/null || fail 'Install ffprobe alongside FFmpeg.'
xcrun --find swiftc >/dev/null || fail 'Install the Swift command-line tools.'
filters=$(ffmpeg -hide_banner -filters 2>/dev/null)
[[ "$filters" == *drawtext* && "$filters" == *subtitles* ]] || fail 'This FFmpeg build needs drawtext and subtitles support.'

script_directory=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
model=$1
app=${SPACEBAR3D_REVIEW_APP:-/Applications/Spacebar 3D.app}
if [[ $# -eq 2 ]]; then
    [[ -n "$2" ]] || fail 'Provide a path for the output directory.'
    output_parent=$(dirname -- "$2")
    output_name=$(basename -- "$2")
    case "$output_name" in .|..|/) fail 'Provide a new output directory path.' ;; esac
    [[ ! -e "$output_parent/$output_name" && ! -L "$output_parent/$output_name" ]] || fail 'The output directory must be new.'
else
    output_parent="$script_directory/../build/media-captures"
fi
mkdir -p -- "$output_parent"
output_parent=$(CDPATH='' cd -- "$output_parent" && pwd -P)

# FFmpeg filter text paths are kept under /tmp so user-supplied path punctuation
# cannot be interpreted as filter syntax. The completed file is published from
# a private directory on the destination filesystem.
work=$(mktemp -d /tmp/spacebar3d-app-review.XXXXXXXX)
stage=''
cleanup() {
    [[ ! -d "$work" ]] || rm -R -- "$work"
    [[ -z "$stage" || ! -d "$stage" ]] || rm -R -- "$stage"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
stage=$(mktemp -d "$output_parent/.capture-review.XXXXXXXX")
if [[ $# -eq 1 ]]; then
    output_name="review-$(date -u +%Y%m%dT%H%M%SZ)-${stage##*.}"
fi
media="$stage/$output_name"
mkdir -- "$media"

xcrun swiftc "$script_directory/capture-app-review.swift" -o "$work/capture-app-review"
"$work/capture-app-review" "$model" "$app" "$work"

font='/System/Library/Fonts/SFNS.ttf'
render() {
    local input=$1 title=$2 caption=$3 part=$4 filter=$5
    local heading="$work/$part-heading.txt" detail="$work/$part-detail.txt"
    shift 5
    printf '%s' "$title" > "$heading"
    printf '%s' "$caption" > "$detail"
    ffmpeg -hide_banner -loglevel error -nostdin "$@" -i "$work/$input" \
        -vf "$filter,setsar=1,pad=1920:1080:(ow-iw)/2:104+(866-ih)/2:color=0x101714,drawtext=fontfile=$font:textfile=$heading:expansion=none:fontsize=42:fontcolor=0xebf5ed:x=96:y=29,drawbox=x=96:y=995:w=1728:h=2:color=0x345143:t=fill,drawtext=fontfile=$font:textfile=$detail:expansion=none:fontsize=30:fontcolor=0xb9cec0:x=96:y=1018" \
        -an -c:v libx264 -preset fast -crf 17 -profile:v high -level:v 4.0 -pix_fmt yuv420p -g 60 "$work/$part.mp4"
}

video_filter='setpts=PTS-STARTPTS,fps=30:start_time=0,scale=1728:866:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,tpad=stop_mode=clone:stop_duration=1.1'
selection_caption='Press Space with the model selected to open Finder Quick Look.'
if [[ ! -s "$work/finder.png" ]]; then
    # An instruction card keeps unreadable Finder content out of the recording.
    ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i 'color=0x101714:s=800x90' \
        -frames:v 1 -update 1 "$work/finder.png"
    selection_caption='Select the model in Finder, then press Space to open Quick Look.'
fi
render finder.png '1. Select the model in Finder' "$selection_caption" selection \
    'trim=duration=4,scale=800:90:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos' -loop 1 -framerate 30
preview_start=$(cat "$work/quick-look-start.txt")
preview_end=$(cat "$work/quick-look-end.txt")
app_start=$(cat "$work/app-start.txt")
for timestamp in "$preview_start" "$preview_end" "$app_start"; do
    [[ "$timestamp" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'The capture trim time is invalid.'
done
render quick-look.mov '2. Inspect the model in Finder Quick Look' \
    'Drag to orbit or scroll to zoom. Then open the same file in Spacebar 3D.' quick-look "setpts=PTS-STARTPTS,trim=start=$preview_start:end=$preview_end,$video_filter"
app_crop=$(cat "$work/app-crop.txt")
[[ "$app_crop" =~ ^[0-9]+$ ]] || fail 'The standalone window crop is invalid.'
render app.mov '3. Inspect the same model in Spacebar 3D' \
    'The same file is open in Spacebar 3D. Drag to orbit or scroll to zoom.' standalone "setpts=PTS-STARTPTS,trim=start=$app_start,crop=iw:ih-$app_crop:0:$app_crop,$video_filter"

printf "file '%s/selection.mp4'\nfile '%s/quick-look.mp4'\nfile '%s/standalone.mp4'\n" "$work" "$work" "$work" > "$work/segments.txt"
walkthrough="$work/walkthrough.mp4"
ffmpeg -hide_banner -loglevel error -nostdin -f concat -safe 0 -i "$work/segments.txt" \
    -map 0:v:0 -c copy -movflags +faststart "$walkthrough"
ffmpeg -hide_banner -loglevel error -xerror -nostdin -i "$walkthrough" -f null -
info=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,avg_frame_rate,nb_frames -of csv=p=0 "$walkthrough")
IFS=, read -r width height rate frames <<< "$info"
[[ "$width" == 1920 && "$height" == 1080 && "$rate" == 30/1 && "$frames" =~ ^[0-9]+$ && "$frames" -gt 120 ]] || fail 'The walkthrough export did not verify.'
"$script_directory/capture-review-features.sh" "$model" "$walkthrough" "$media/app-review.mp4" >/dev/null
# Move the complete directory without replacing a destination created while capturing.
mv -n -- "$media" "$output_parent/"
[[ ! -d "$media" ]] || fail 'The output directory was created while capture ran.'
printf '%s\n' "$output_parent/$output_name/app-review.mp4"
