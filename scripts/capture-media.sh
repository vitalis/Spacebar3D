#!/usr/bin/env bash
set -euo pipefail

feature_loop="${SPACEBAR3D_FEATURE_LOOP:-0}"
screenshots_only="${SPACEBAR3D_SCREENSHOTS:-0}"

usage() {
  if [[ "$screenshots_only" == 1 ]]; then
    cat <<'EOF'
Usage: ./scripts/capture-screenshots.sh MODEL [OUTPUT_DIRECTORY]

Capture four 2560x1600 PNG screenshots in Spacebar 3D. OUTPUT_DIRECTORY
must be a new path. The default is a unique screenshots directory under
build/media-captures.

EOF
  elif [[ "$feature_loop" == 1 ]]; then
    cat <<'EOF'
Usage: ./scripts/capture-feature-loop.sh MODEL [OUTPUT_DIRECTORY]

Capture three render styles and write a 15-second feature-loop.mp4.
OUTPUT_DIRECTORY must be a new path. The default is a unique directory
under build/media-captures.

EOF
  else
    cat <<'EOF'
Usage: ./scripts/capture-media.sh MODEL [OUTPUT_DIRECTORY]

Capture Spacebar 3D on macOS and write a 30-second preview.mp4, four PNG
screenshots, and demo.gif. OUTPUT_DIRECTORY must be a new path. The
default is a unique directory under build/media-captures.

EOF
  fi
  cat <<'EOF'
Install FFmpeg with `brew install ffmpeg` and allow Screen Recording for
your terminal. The script builds a separate copy of the app using the
regular development build prerequisites and signing setup. To use an
existing capture-enabled build, set SPACEBAR3D_APP to its .app path.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ "$screenshots_only" == 1 && "$feature_loop" == 1 ]]; then
  fail "Choose either screenshots or the feature loop."
fi

if [[ $# == 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 2
fi

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
repo_dir="$(dirname -- "$script_dir")"
model="$1"
if [[ "$model" != /* ]]; then
  model="$PWD/$model"
fi
[[ -f "$model" && -r "$model" ]] || fail "Cannot read model file: $model"

command -v ffmpeg >/dev/null || fail "ffmpeg is required. Run 'brew install ffmpeg'."
if [[ "$screenshots_only" != 1 ]]; then
  command -v ffprobe >/dev/null || fail "ffprobe is required. Run 'brew install ffmpeg'."
fi
command -v swift >/dev/null || fail "Swift is required. Install Xcode and its command line tools."

app="${SPACEBAR3D_APP:-}"
if [[ -n "$app" ]]; then
  if [[ "$app" != /* ]]; then
    app="$PWD/$app"
  fi
  [[ -d "$app" ]] || fail "Cannot find the app at SPACEBAR3D_APP: $app"
fi

if [[ $# == 2 ]]; then
  [[ -n "$2" ]] || fail "Provide a path for the output directory."
  output_parent="$(dirname -- "$2")"
  output_name="$(basename -- "$2")"
  case "$output_name" in
    . | .. | /) fail "Provide a new directory path for the output." ;;
  esac
  if [[ "$output_parent" != /* ]]; then
    output_parent="$PWD/$output_parent"
  fi
  [[ ! -e "$output_parent/$output_name" && ! -L "$output_parent/$output_name" ]] || \
    fail "Output path already exists: $output_parent/$output_name"
else
  output_parent="$repo_dir/build/media-captures"
fi

mkdir -p "$output_parent"
output_parent="$(CDPATH='' cd -- "$output_parent" && pwd -P)"
stage="$(mktemp -d "$output_parent/.capture.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $# == 1 ]]; then
  output_prefix=capture
  if [[ "$screenshots_only" == 1 ]]; then
    output_prefix=screenshots
  elif [[ "$feature_loop" == 1 ]]; then
    output_prefix=feature-loop
  fi
  output_name="$output_prefix-$(date -u +%Y%m%dT%H%M%SZ)-${stage##*.}"
fi
raw="$stage/raw"
media="$stage/media/$output_name"
mkdir -p "$raw" "$media"

if [[ -z "$app" ]]; then
  printf 'Building a capture-enabled copy of Spacebar 3D\n'
  SPACEBAR3D_BUILD_DIR="$stage/DerivedData" SPACEBAR3D_BUILD_MEDIA_CAPTURE=1 \
    "$script_dir/build.sh"
  app="$stage/DerivedData/Build/Products/Release/Spacebar 3D.app"
fi

printf 'Capturing %s\n' "$model"
raw_stills="$stage/stills"
if [[ "$feature_loop" != 1 ]]; then
  mkdir -p "$raw_stills"
  SPACEBAR3D_SCREENSHOTS=1 SPACEBAR3D_APP="$app" swift "$script_dir/capture-media.swift" "$model" "$raw_stills"
fi
if [[ "$screenshots_only" != 1 ]]; then
  SPACEBAR3D_APP="$app" swift "$script_dir/capture-media.swift" "$model" "$raw"
fi

# Discard the native recording's lead-in before using its first presented frame.
video_filter='setpts=PTS-STARTPTS,trim=start=0.75,setpts=PTS-STARTPTS,fps=30:start_time=0,scale=1920:1080:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p'
# Use H.264 filler to keep static shots within the target bitrate range.
video_args=(
  -c:v libx264 -profile:v high -level:v 4.0 -pix_fmt yuv420p
  -b:v 11M -minrate 11M -maxrate 11M -bufsize 11M -x264-params nal-hrd=vbr:filler=1
  -color_primaries bt709 -color_trc bt709 -colorspace bt709
)
audio_args=(-c:a aac_at -aac_at_mode cbr -b:a 256k)

check_source_duration() {
  local source="$1" minimum="$2" duration
  [[ -s "$source" ]] || fail "Capture did not produce $(basename -- "$source")."
  duration="$(ffprobe -v error -select_streams v:0 -show_entries stream=duration \
    -of default=noprint_wrappers=1:nokey=1 "$source")"
  if ! LC_ALL=C awk -v duration="$duration" -v minimum="$minimum" 'BEGIN { exit !(duration + 0 >= minimum) }'; then
    fail "$(basename -- "$source") needs at least $minimum seconds of video. Got ${duration:-no video}."
  fi
}

check_video() {
  local video="$1" seconds="$2" info
  info="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,level,width,height,pix_fmt,avg_frame_rate,bit_rate,nb_frames,duration:format=duration \
    -of default "$video")"
  if ! LC_ALL=C awk -F= -v seconds="$seconds" '
    $1 == "codec_name" { codec = $2 }
    $1 == "profile" { profile = $2 }
    $1 == "level" { level = $2 }
    $1 == "width" { width = $2 }
    $1 == "height" { height = $2 }
    $1 == "pix_fmt" { pix_fmt = $2 }
    $1 == "avg_frame_rate" { rate = $2 }
    $1 == "bit_rate" { bitrate = $2 + 0 }
    $1 == "nb_frames" { frames = $2 }
    $1 == "duration" && $2 + 0 == seconds { exact_durations++ }
    END {
      exit !(codec == "h264" && profile == "High" && level == 40 &&
             width == 1920 && height == 1080 && pix_fmt == "yuv420p" && rate == "30/1" && frames == 30 * seconds && exact_durations == 2 &&
             bitrate >= 10000000 && bitrate <= 12000000)
    }
  ' <<< "$info"; then
    printf '%s\n' "$info" >&2
    fail "The export does not match the expected H.264 format, duration, or bitrate."
  fi
  ffmpeg -hide_banner -loglevel error -nostdin -xerror -i "$video" -f null -
}

publish() {
  # Move the complete directory on the same filesystem. Passing the parent to
  # mv makes -n protect the destination even if another capture created it.
  mv -n "$media" "$output_parent/"
  [[ ! -d "$media" ]] || fail "Output path already exists: $output_parent/$output_name"
  printf 'Media saved in %s\n' "$output_parent/$output_name"
}

encode_feature_loop() {
  local loop="$1" shot filters
  for shot in 01 02 03; do
    check_source_duration "$raw/feature-$shot.mov" 6.25
  done

  printf 'Encoding the 15-second feature loop\n'
  # Save 15 opening frames for the final dissolve. Playback then resumes at
  # the next opening frame without repeating the start of the first shot.
  filters="
    [0:v]${video_filter},split[opening][opening_head];
    [opening]trim=start_frame=15:end_frame=165,setpts=PTS-STARTPTS[shot_one];
    [opening_head]trim=end_frame=15,setpts=PTS-STARTPTS[head];
    [1:v]${video_filter},trim=end_frame=150,setpts=PTS-STARTPTS[shot_two];
    [2:v]${video_filter},split[closing][closing_tail];
    [closing]trim=end_frame=135,setpts=PTS-STARTPTS[shot_three];
    [closing_tail]trim=start_frame=135:end_frame=150,setpts=PTS-STARTPTS[tail];
    [tail][head]blend=all_expr='A*(16-N)/15+B*(N-1)/15':shortest=1[dissolve];
    [shot_one][shot_two][shot_three][dissolve]concat=n=4:v=1:a=0,fps=30[loop]"
  ffmpeg -hide_banner -loglevel error -nostdin -xerror \
    -i "$raw/feature-01.mov" -i "$raw/feature-02.mov" -i "$raw/feature-03.mov" \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000:d=14.97 \
    -filter_complex "$filters" -map '[loop]' -map 3:a:0 -map_metadata -1 \
    "${video_args[@]}" "${audio_args[@]}" -movflags +faststart "$loop"
  check_video "$loop" 15
}

if [[ "$feature_loop" == 1 ]]; then
  encode_feature_loop "$media/feature-loop.mp4"
  publish
  exit 0
fi

first_screenshot=01-textured.png
if [[ ! -s "$raw_stills/$first_screenshot" ]]; then
  first_screenshot=01-solid.png
fi
screenshots=("$first_screenshot" 02-wireframe.png 03-normals.png 04-hologram.png)
for file in "${screenshots[@]}"; do
  [[ -s "$raw_stills/$file" ]] || fail "Capture did not produce $file."
done

printf 'Preparing the screenshots\n'
srgb_profile='/System/Library/ColorSync/Profiles/sRGB Profile.icc'
for screenshot in "${screenshots[@]}"; do
  still="$stage/$screenshot"
  sips --matchTo "$srgb_profile" "$raw_stills/$screenshot" --out "$still" >/dev/null
  # Composite any translucent window edges onto black before dropping alpha.
  ffmpeg -hide_banner -loglevel error -nostdin -xerror \
    -i "$still" \
    -vf 'scale=2560:1600:force_original_aspect_ratio=decrease:flags=lanczos,pad=2560:1600:(ow-iw)/2:(oh-ih)/2,format=gbrap,premultiply=inplace=1:planes=7,format=rgb24,setsar=1' \
    -frames:v 1 -update 1 "$media/$screenshot"
  sips --embedProfile "$srgb_profile" "$media/$screenshot" >/dev/null
  image_info="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$media/$screenshot")"
  if ! awk '
    $1 == "pixelWidth:" { width = $2 }
    $1 == "pixelHeight:" { height = $2 }
    $1 == "hasAlpha:" { alpha = $2 }
    END { exit !(width == 2560 && height == 1600 && alpha == "no") }
  ' <<< "$image_info"; then
    fail "$screenshot must be an opaque 2560x1600 PNG."
  fi
done

if [[ "$screenshots_only" == 1 ]]; then
  publish
  exit 0
fi

preview="$media/preview.mp4"
check_source_duration "$raw/video.mov" 30.75

printf 'Encoding the Mac App Store preview\n'
# Leave one AAC frame of headroom so encoder padding cannot extend the movie.
ffmpeg -hide_banner -loglevel error -nostdin -xerror \
  -i "$raw/video.mov" -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000:d=29.97 \
  -map 0:v:0 -map 1:a:0 -map_metadata -1 -t 30 \
  -vf "$video_filter" "${video_args[@]}" "${audio_args[@]}" -movflags +faststart "$preview"
check_video "$preview" 30

gif_source="$preview"
if [[ -s "$raw/feature-01.mov" ]]; then
  gif_source="$stage/feature-loop.mp4"
  encode_feature_loop "$gif_source"
fi
printf 'Encoding the README GIF\n'
gif="$media/demo.gif"
gif_limit=$((10 * 1024 * 1024))
for size in 704:8 608:7 512:6 416:6 360:5; do
  width="${size%:*}"
  fps="${size#*:}"
  ffmpeg -hide_banner -loglevel error -nostdin -xerror -y \
    -i "$gif_source" \
    -filter_complex "fps=$fps,scale=$width:-1:flags=lanczos,split[frames][colors];[colors]palettegen=stats_mode=diff[palette];[frames][palette]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    -an -loop 0 "$gif"
  gif_size="$(wc -c < "$gif")"
  if (( gif_size > 0 && gif_size <= gif_limit )); then
    break
  fi
done
(( gif_size > 0 && gif_size <= gif_limit )) || fail "Could not encode a GIF within 10 MiB."

publish
