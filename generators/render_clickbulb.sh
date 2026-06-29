#!/usr/bin/env bash
# Render the ClickBulb desk-lamp homage (generators/gen_clickbulb.py): a sphere
# lamp hops in, leaps behind the banner, rakes its light through the letter gaps,
# then pokes its head through a gap to peer at the camera.
#
# Each frame is the SAME ClickHouse query run with a different {FRAME}; all of
# the lamp's articulated pose is computed in SQL. The only work outside
# ClickHouse is this frame loop and the final ffmpeg mux.
#
# Usage:
#   generators/render_clickbulb.sh [W] [H] [SAMPLES] [DEPTH] [TEXT] [FRAMES] [FPS] [OUT] [target=IDX gap=N]
# Example (super low res, quick):
#   generators/render_clickbulb.sh 240 108 5 3 CLICKHOUSE 60 24 clickbulb.mp4
set -euo pipefail

W=${1:-300}; H=${2:-132}; SAMPLES=${3:-7}; DEPTH=${4:-3}
TEXT=${5:-CLICKHOUSE}; FRAMES=${6:-72}; FPS=${7:-24}; OUT=${8:-clickbulb.mp4}
shift $(( $# < 8 ? $# : 8 )) || true   # any remaining args ($@) -> gen_clickbulb.py (e.g. target=IDX gap=N)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$(cd "$HERE/.." && pwd)/images"
FRAMEDIR="$(mktemp -d)"
SQL="$FRAMEDIR/clickbulb.sql"
trap 'rm -rf "$FRAMEDIR"' EXIT

echo ">> ${W}x${H}, ${SAMPLES} spp, depth ${DEPTH}, ${FRAMES} frames [$*] -> ${OUT}"
python3 "$HERE/gen_clickbulb.py" "$W" "$H" "$SAMPLES" "$DEPTH" "$TEXT" "$@" > "$SQL"

for ((f=0; f<FRAMES; f++)); do
  printf '\r   frame %d/%d' "$((f+1))" "$FRAMES"
  clickhouse local \
    --output_format_image_width="$W" --output_format_image_height="$H" \
    --param_SAMPLES="$SAMPLES" --param_FRAME="$f" --param_FRAMES="$FRAMES" \
    --queries-file "$SQL" > "$(printf '%s/frame_%04d.png' "$FRAMEDIR" "$f")"
done
printf '\n>> muxing %d frames at %d fps\n' "$FRAMES" "$FPS"

ffmpeg -y -loglevel error -framerate "$FPS" -i "$FRAMEDIR/frame_%04d.png" \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=neighbor,format=yuv420p" \
  -c:v libx264 -crf 18 "$OUTDIR/$OUT"

echo ">> wrote $OUTDIR/$OUT"
