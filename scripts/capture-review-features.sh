#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/capture-review-features.sh MODEL WALKTHROUGH_MP4 NEW_OUTPUT_MP4

Append a captioned viewer tour and settings walkthrough to the genuine
Finder, Quick Look and Spacebar 3D walkthrough. Requires FFmpeg with
drawtext and subtitles support.

SPACEBAR3D_REVIEW_CAPTURE_APP selects a capture-enabled Spacebar 3D build.
SPACEBAR3D_REVIEW_ANIMATION_MODEL optionally selects a second model for
demonstrating animation playback and clip selection.
EOF
}

fail() { printf 'capture-review-features: %s\n' "$*" >&2; exit 1; }

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then usage; exit 0; fi
if [[ $# -ne 3 ]]; then usage >&2; exit 2; fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
model=$1
walkthrough=$2
output=$3
[[ -r "$model" && -f "$model" ]] || fail 'The model must be a readable regular file.'
[[ -r "$walkthrough" && -f "$walkthrough" ]] || fail 'The walkthrough video must be a readable regular file.'
[[ "$output" == *.mp4 ]] || fail 'Provide a new .mp4 output path.'
[[ ! -e "$output" && ! -L "$output" ]] || fail 'The output file already exists.'
animation_model=${SPACEBAR3D_REVIEW_ANIMATION_MODEL:-}
if [[ -n "$animation_model" ]]; then
    [[ -r "$animation_model" && -f "$animation_model" ]] || fail 'The animation model must be a readable regular file.'
fi

command -v ffmpeg >/dev/null || fail 'Install FFmpeg with drawtext and subtitles support.'
command -v ffprobe >/dev/null || fail 'Install ffprobe alongside FFmpeg.'
command -v swift >/dev/null || fail 'Install the Swift command-line tools.'
filters=$(ffmpeg -hide_banner -filters 2>/dev/null)
[[ "$filters" == *drawtext* && "$filters" == *subtitles* ]] || fail 'This FFmpeg build needs drawtext and subtitles support.'

output_parent=$(dirname -- "$output")
output_name=$(basename -- "$output")
mkdir -p -- "$output_parent"
output_parent=$(CDPATH='' cd -- "$output_parent" && pwd -P)

# Keep text and subtitle paths free of FFmpeg filter punctuation, even when
# the model and destination are in directories with spaces or apostrophes.
work=$(mktemp -d /tmp/spacebar3d-review-features.XXXXXXXX)
stage=''
cleanup() {
    [[ ! -d "$work" ]] || rm -R -- "$work"
    [[ -z "$stage" || ! -d "$stage" ]] || rm -R -- "$stage"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
stage=$(mktemp -d "$output_parent/.review-features.XXXXXXXX")
raw="$work/raw"
mkdir -- "$raw"

capture_app=${SPACEBAR3D_REVIEW_CAPTURE_APP:-}
if [[ -z "$capture_app" ]]; then
    printf 'Building a separate capture-enabled viewer\n' >&2
    SPACEBAR3D_BUILD_DIR="$work/DerivedData" SPACEBAR3D_BUILD_MEDIA_CAPTURE=1 \
        "$script_directory/build.sh" >&2
    capture_app="$work/DerivedData/Build/Products/Release/Spacebar 3D.app"
fi
[[ -d "$capture_app" ]] || fail 'The capture-enabled app bundle does not exist.'

printf 'Recording the viewer and settings chapters\n' >&2
SPACEBAR3D_REVIEW_FEATURES=1 SPACEBAR3D_APP="$capture_app" \
    swift "$script_directory/capture-media.swift" "$model" "$raw" >&2

font='/System/Library/Fonts/SFNS.ttf'
caption_style='FontName=Helvetica,FontSize=9,PrimaryColour=&H00C0CEB9,Alignment=1,MarginL=19,MarginR=19,MarginV=5,Outline=0,Shadow=0'
video_filter='setpts=PTS-STARTPTS,fps=30:start_time=0,scale=1728:866:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,setsar=1,pad=1920:1080:(ow-iw)/2:104+(866-ih)/2:color=0x101714'

render() {
    local chapter="$1" title="$2"
    local source="$raw/$chapter.mov" subtitles="$raw/$chapter.srt"
    local heading="$work/$chapter-title.txt"
    local edit=''
    if [[ -s "$raw/$chapter.keep" ]]; then
        # Apply the captions on the source timeline, then cut the off-screen setup.
        edit=",select='$(cat "$raw/$chapter.keep")',setpts=N"
    fi
    [[ -s "$source" && -s "$subtitles" ]] || fail "Missing footage or captions for $title."
    printf '%s' "$title" > "$heading"
    ffmpeg -hide_banner -loglevel error -xerror -nostdin -i "$source" \
        -vf "$video_filter,drawtext=fontfile=$font:textfile=$heading:fontsize=42:fontcolor=0xebf5ed:x=96:y=29,drawbox=x=96:y=995:w=1728:h=2:color=0x345143:t=fill,subtitles=$subtitles:force_style='$caption_style'${edit}" \
        -an -c:v libx264 -preset fast -crf 17 -profile:v high -level:v 4.0 -pix_fmt yuv420p -g 60 "$work/$chapter.mp4"
}

render review-features 'Explore the viewer controls'
segments=(walkthrough review-features)
if [[ -n "$animation_model" || -e "$raw/review-animation.mov" ]]; then
    render review-animation 'Preview animation clips'
    segments+=(review-animation)
fi
render review-settings 'Settings, Help and Privacy'
segments+=(review-settings)

if [[ "$walkthrough" != /* ]]; then walkthrough="$PWD/$walkthrough"; fi
ln -s -- "$walkthrough" "$work/walkthrough.mp4"
manifest="$work/segments.txt"
expected_frames=0
for chapter in "${segments[@]}"; do
    info=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,avg_frame_rate,nb_frames -of csv=p=0 "$work/$chapter.mp4")
    IFS=, read -r codec width height rate frames <<< "$info"
    [[ "$codec" == h264 && "$width" == 1920 && "$height" == 1080 && "$rate" == 30/1 &&
        "$frames" =~ ^[0-9]+$ && "$frames" -gt 0 ]] || fail "Unexpected video format in $chapter."
    expected_frames=$((expected_frames + frames))
    printf "file '%s.mp4'\n" "$chapter" >> "$manifest"
    LC_ALL=C awk -v frames="$frames" 'BEGIN { printf "duration %.6f\n", frames / 30 }' >> "$manifest"
done

review="$stage/$output_name"
ffmpeg -hide_banner -loglevel error -xerror -nostdin -f concat -safe 1 -i "$manifest" \
    -map 0:v:0 -c copy -movflags +faststart "$review"
ffmpeg -hide_banner -loglevel error -xerror -nostdin -i "$review" -f null -
info=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate,nb_frames -of csv=p=0 "$review")
[[ "$info" == "30/1,$expected_frames" ]] || fail 'The combined walkthrough did not verify.'

mv -n -- "$review" "$output_parent/"
[[ ! -e "$review" ]] || fail 'The output file was created while capture ran.'
printf '%s\n' "$output_parent/$output_name"
