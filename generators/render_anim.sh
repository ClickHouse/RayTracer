#!/usr/bin/env bash
# Render a turntable animation of the sphere-banner ray tracer.
#
# Each frame is the SAME ClickHouse query (generators/gen_anim.py) run with a
# different {FRAME} parameter; the camera-orbit math is all in SQL. The only
# work outside ClickHouse is this frame loop and the final ffmpeg mux, since
# ClickHouse renders PNGs but cannot encode an mp4.
#
# Usage:
#   generators/render_anim.sh [W] [H] [SAMPLES] [DEPTH] [TEXT] [FRAMES] [FPS] [OUT] [anim=NAME param=val ...]
# Examples:
#   generators/render_anim.sh 320 128 4 4 ClickHouse 48 24 turntable.mp4 anim=turntable sweep=35
#   generators/render_anim.sh 320 128 4 4 ClickHouse 48 24 light.mp4     anim=light arc=360 radius=28
#   generators/render_anim.sh 1 1 1 1 X 1 1 - anim=list      # list anims + their params
set -euo pipefail

W=${1:-320}; H=${2:-128}; SAMPLES=${3:-4}; DEPTH=${4:-4}
TEXT=${5:-ClickHouse}; FRAMES=${6:-48}; FPS=${7:-24}; OUT=${8:-anim.mp4}
shift $(( $# < 8 ? $# : 8 )) || true   # remaining args ($@) are anim=NAME / param=val

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$(cd "$HERE/.." && pwd)/images"
FRAMEDIR="$(mktemp -d)"
SQL="$FRAMEDIR/anim.sql"
trap 'rm -rf "$FRAMEDIR"' EXIT

echo ">> ${W}x${H}, ${SAMPLES} spp, depth ${DEPTH}, ${FRAMES} frames [$*] -> ${OUT}"
python3 "$HERE/gen_anim.py" "$W" "$H" "$SAMPLES" "$DEPTH" "$TEXT" "$@" > "$SQL"

for ((f=0; f<FRAMES; f++)); do
  printf '\r   frame %d/%d' "$((f+1))" "$FRAMES"
  clickhouse local \
    --output_format_image_width="$W" --output_format_image_height="$H" \
    --param_SAMPLES="$SAMPLES" --param_FRAME="$f" --param_FRAMES="$FRAMES" \
    --queries-file "$SQL" > "$(printf '%s/frame_%04d.png' "$FRAMEDIR" "$f")"
done
printf '\n>> muxing %d frames at %d fps\n' "$FRAMES" "$FPS"

# yuv420p + even-dimension scale for broad player compatibility.
ffmpeg -y -loglevel error -framerate "$FPS" -i "$FRAMEDIR/frame_%04d.png" \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=neighbor,format=yuv420p" \
  -c:v libx264 -crf 18 "$OUTDIR/$OUT"

echo ">> wrote $OUTDIR/$OUT"
