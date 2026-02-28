#!/usr/bin/env bash
set -euo pipefail

# OCR preprocess for faint rubbings (rubbings)
# Requires: ImageMagick (magick)
# Optional: Tesseract OCR
#
# @Author: Kimiya Kitani
# @Version: 1.0
#
# Usage examples:
#   ./ocr_preprocess.sh -p clahe -w 1600 in.jpg
#   ./ocr_preprocess.sh -p bgfix -b 40 -w 2000 -d -t in.jpg
#   ./ocr_preprocess.sh -p bw -A "55x55+12%" -w 2000 in.jpg
#   ./ocr_preprocess.sh -p hard -w 2000 -T 1024 --select stats2 in.jpg
#
# Presets:
#   clahe : grayscale + CLAHE + unsharp + contrast stretch  (recommended first)
#   bgfix : background normalization (divide by blurred clone) + unsharp
#   bw    : clahe + unsharp + local threshold (binarize-ish)
#   hard  : difficult faint rubbings: bgfix(divide) + clahe + sharpen + (lat + invert + tophat + inv) -> pick best -> *_ocr
#
# NOTE (important for Google Vision):
#   Some 1-bit PNG outputs may trigger "Bad image data".
#   This script forces output to 8-bit for PNG/JPG/TIF to improve compatibility.

show_help() {
  cat <<'HELP'
ocr_preprocess.sh - ImageMagick preprocessing for OCR

USAGE:
  ocr_preprocess.sh [options] input_image

OPTIONS:
  -p, --preset PRESET     Processing preset: clahe | bgfix | bw | hard (default: clahe)
  -o, --out PATH          Output file path (default: input_basename + _ocr.png)
                          NOTE: for preset 'hard', this is the final single output path.
  -O, --outdir DIR        Output directory (default: same as input)
  -f, --format EXT        Output format extension: png|jpg|tif (default: png)

  --gray                  Force grayscale (default: on)
  --no-gray               Disable grayscale conversion
  -w, --width PX          Resize to width PX (keeps aspect; default: no resize)

  --clahe ARG             CLAHE args (default: 25x25+128+3)
  --unsharp ARG           Unsharp args (default: 0x1.2+1.0+0.02)
  --stretch ARG           Contrast stretch (default: 0.2%x0.2%)

  -b, --blur RADIUS       (bgfix) background blur radius (default: 40)
  -A, --adaptive ARG      (bw) local threshold args used by -lat (default: 35x35+10%)

  # ----- hard preset options -----
  --hard-blur RADIUS      (hard) background blur radius for Divide (default: 30)
  --lat ARG               (hard) LAT args (default: 25x25-5%)
  --hard-crop             (hard) try trimming borders early (default: on)
  --no-hard-crop          (hard) disable early trim
  -T, --tile PX           (hard) tile size (e.g., 1024). 0 = no tiling (default: 0)

  --keep-variants         (hard) keep all generated variants (default: off)
  --select MODE           (hard) choose best variant by: stats|stats2|tesseract|none (default: stats)
  --tess-lang LANGS       (hard) tesseract languages (e.g., 'eng+jpn' or 'tha') (default: eng)
  --tess-psm N            (hard) tesseract PSM (default: 6)

  --tophat RADIUS         (hard) morphology TopHat disk radius (default: 15)
  --canny ARG             (hard) canny args for stats2 scoring (default: 0x1+10%+30%)

  --no-force-8bit         Do not force 8-bit output (default: force)
  -d, --deskew            Apply deskew 40%
  -t, --trim              Trim borders (single-output presets; for hard use --hard-crop instead)
  -n, --dry-run           Print command only (do not run)
  -q, --quiet             Less output
  -h, --help              Show help

NOTES:
  - Start with preset 'clahe'. If background uneven, try 'bgfix'.
  - For binarization, try 'bw' but Vision OCR sometimes prefers grayscale.
  - For very difficult rubbings where Vision returns 0 chars, use preset 'hard' and feed the single *_ocr output to OCR.
HELP
}

# Defaults
PRESET="clahe"
OUT=""
OUTDIR=""
FORMAT="png"
DO_GRAY=1
WIDTH=""
CLAHE_ARG="25x25+128+3"
UNSHARP_ARG="0x1.2+1.0+0.02"
STRETCH_ARG="0.2%x0.2%"
BLUR_RADIUS="40"
ADAPTIVE_ARG="35x35+10%"
DO_DESKEW=0
DO_TRIM=0
DRYRUN=0
QUIET=0
FORCE_8BIT=1

# hard defaults
HARD_BLUR_RADIUS="30"
HARD_LAT_ARG="25x25-5%"
HARD_CROP=1
HARD_TILE=0

KEEP_VARIANTS=0
SELECT_MODE="stats"   # stats|stats2|tesseract|none
TESS_LANG="eng"
TESS_PSM="6"
TOPHAT_RADIUS="15"
CANNY_ARG="0x1+10%+30%"

# Parse args
if [[ $# -eq 0 ]]; then show_help; exit 1; fi
INPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--preset) PRESET="${2:-}"; shift 2;;
    -o|--out) OUT="${2:-}"; shift 2;;
    -O|--outdir) OUTDIR="${2:-}"; shift 2;;
    -f|--format) FORMAT="${2:-}"; shift 2;;

    --gray) DO_GRAY=1; shift;;
    --no-gray) DO_GRAY=0; shift;;

    -w|--width) WIDTH="${2:-}"; shift 2;;

    --clahe) CLAHE_ARG="${2:-}"; shift 2;;
    --unsharp) UNSHARP_ARG="${2:-}"; shift 2;;
    --stretch) STRETCH_ARG="${2:-}"; shift 2;;

    -b|--blur) BLUR_RADIUS="${2:-}"; shift 2;;
    -A|--adaptive) ADAPTIVE_ARG="${2:-}"; shift 2;;

    --hard-blur) HARD_BLUR_RADIUS="${2:-}"; shift 2;;
    --lat) HARD_LAT_ARG="${2:-}"; shift 2;;
    --hard-crop) HARD_CROP=1; shift;;
    --no-hard-crop) HARD_CROP=0; shift;;
    -T|--tile) HARD_TILE="${2:-0}"; shift 2;;

    --keep-variants) KEEP_VARIANTS=1; shift;;
    --select) SELECT_MODE="${2:-stats}"; shift 2;;
    --tess-lang) TESS_LANG="${2:-eng}"; shift 2;;
    --tess-psm) TESS_PSM="${2:-6}"; shift 2;;
    --tophat) TOPHAT_RADIUS="${2:-15}"; shift 2;;
    --canny) CANNY_ARG="${2:-0x1+10%+30%}"; shift 2;;

    --no-force-8bit) FORCE_8BIT=0; shift;;
    -d|--deskew) DO_DESKEW=1; shift;;
    -t|--trim) DO_TRIM=1; shift;;
    -n|--dry-run) DRYRUN=1; shift;;
    -q|--quiet) QUIET=1; shift;;
    -h|--help) show_help; exit 0;;

    --) shift; break;;
    -*)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
    *)
      INPUT="$1"; shift;;
  esac
done

if [[ -z "${INPUT}" ]]; then
  echo "ERROR: input_image is required" >&2
  show_help
  exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
  echo "ERROR: ImageMagick 'magick' not found. Install ImageMagick first." >&2
  exit 1
fi

# Build output path
in_dir="$(cd "$(dirname "$INPUT")" && pwd)"
in_base="$(basename "$INPUT")"
in_name="${in_base%.*}"
out_dir="${OUTDIR:-$in_dir}"

mkdir -p "$out_dir"

FORMAT="$(echo "$FORMAT" | tr '[:upper:]' '[:lower:]')"

say() { [[ "$QUIET" -eq 0 ]] && echo "$*" || true; }

supports_option() {
  local opt="$1"
  magick -help 2>/dev/null | tr "\r" "\n" | grep -qi -- "$opt"
}

force8_args() {
  local fmt="$1"
  if [[ "$FORCE_8BIT" -ne 1 ]]; then
    return 0
  fi
  case "$fmt" in
    png)  echo "-depth 8 -type Grayscale -define png:color-type=0 -define png:bit-depth=8" ;;
    jpg|jpeg) echo "-alpha remove -alpha off -depth 8" ;;
    tif|tiff) echo "-depth 8" ;;
    *) echo "" ;;
  esac
}

run() {
  if [[ "$DRYRUN" -eq 1 ]]; then
    printf 'CMD:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# ---------- preset hard (single-output for GAS) ----------
if [[ "$PRESET" == "hard" ]]; then
  base_png="${out_dir}/${in_name}__hard_base.png"
  crop_png="${out_dir}/${in_name}__hard_crop.png"
  bg_png="${out_dir}/${in_name}__hard_bgfix.png"
  clahe_png="${out_dir}/${in_name}__hard_clahe.png"
  enh_png="${out_dir}/${in_name}__hard_enh.png"

  out_bg="${out_dir}/${in_name}_bgfix.${FORMAT}"
  out_enh="${out_dir}/${in_name}_enh.${FORMAT}"
  out_lat="${out_dir}/${in_name}_lat.${FORMAT}"
  out_ath="${out_dir}/${in_name}_ath.${FORMAT}"
  out_ath_inv="${out_dir}/${in_name}_ath_inv.${FORMAT}"
  out_th="${out_dir}/${in_name}_tophat.${FORMAT}"
  out_th_inv="${out_dir}/${in_name}_tophat_inv.${FORMAT}"

  if [[ -z "$OUT" ]]; then
    final_out="${out_dir}/${in_name}_ocr.${FORMAT}"
  else
    final_out="$OUT"
  fi

  say "Preset : hard"
  say "Input  : $INPUT"
  say "Outdir : $out_dir"
  say "Format : $FORMAT"
  say "Force8 : $FORCE_8BIT"
  say "Select : $SELECT_MODE (keep_variants=$KEEP_VARIANTS)"

  if [[ "$SELECT_MODE" == "tesseract" ]]; then
    if ! command -v tesseract >/dev/null 2>&1; then
      say "WARN: tesseract not found; falling back to stats selection."
      SELECT_MODE="stats"
    fi
  fi

  score_by_stats() {
    local f="$1"
    magick "$f" -format "%[entropy] %[standard-deviation]" info: 2>/dev/null | awk '{printf "%.6f\n", ($1*0.7)+($2*0.3)}'
  }
  score_by_edges() {
    local f="$1"
    magick "$f" -colorspace Gray -canny "$CANNY_ARG" -format "%[mean]" info: 2>/dev/null
  }
  score_by_stats2() {
    local f="$1"
    local s1 s2
    s1="$(score_by_stats "$f")"
    s2="$(score_by_edges "$f")"
    awk -v a="$s1" -v b="$s2" 'BEGIN{printf "%.6f\n", (a*0.55)+(b*0.45)}'
  }
  score_by_tesseract() {
    local f="$1"
    tesseract "$f" stdout -l "$TESS_LANG" --psm "$TESS_PSM" 2>/dev/null | tr -d '\f' | tr -d ' \n\r\t' | wc -m | awk '{print $1+0}'
  }
  pick_best_variant() {
    local best="" best_score="-1" f score
    for f in "$@"; do
      [[ -f "$f" ]] || continue
      if [[ "$SELECT_MODE" == "tesseract" ]]; then
        score="$(score_by_tesseract "$f")"
      elif [[ "$SELECT_MODE" == "none" ]]; then
        score="1"
      else
        if [[ "$SELECT_MODE" == "stats2" ]]; then
          score="$(score_by_stats2 "$f")"
        else
          score="$(score_by_stats "$f")"
        fi
      fi
      if awk -v a="$score" -v b="$best_score" 'BEGIN{exit !(a>b)}'; then
        best_score="$score"; best="$f"
      fi
      if [[ "$SELECT_MODE" == "none" && -n "$best" ]]; then break; fi
    done
    echo "$best"
  }

  cmd0=(magick "$INPUT" -strip)
  if [[ "$DO_GRAY" -eq 1 ]]; then cmd0+=(-colorspace Gray); fi
  if [[ -n "$WIDTH" ]]; then cmd0+=(-resize "${WIDTH}x"); fi
  if [[ "$DO_DESKEW" -eq 1 ]]; then cmd0+=(-deskew 40%); fi
  cmd0+=(-depth 8 -type Grayscale "$base_png")
  run "${cmd0[@]}"

  if [[ "$HARD_CROP" -eq 1 ]]; then
    run magick "$base_png" -trim +repage "$crop_png"
  else
    run cp -f "$base_png" "$crop_png"
  fi

  run magick "$crop_png" \
    \( +clone -blur "0x${HARD_BLUR_RADIUS}" \) -compose Divide -composite \
    -auto-level -normalize -depth 8 -type Grayscale "$bg_png"

  run magick "$bg_png" \
    -clahe "$CLAHE_ARG" -unsharp "$UNSHARP_ARG" -contrast-stretch "$STRETCH_ARG" \
    -depth 8 -type Grayscale "$clahe_png"

  run magick "$clahe_png" -sharpen 0x1 -depth 8 -type Grayscale "$enh_png"

  run magick "$bg_png" $(force8_args "$FORMAT") "$out_bg"
  run magick "$enh_png" $(force8_args "$FORMAT") "$out_enh"
  run magick "$enh_png" -lat "$HARD_LAT_ARG" $(force8_args "$FORMAT") "$out_lat"
  run magick "$enh_png" -lat "$HARD_LAT_ARG" $(force8_args "$FORMAT") "$out_ath"   # IM7: use -lat as adaptive-like
  run magick "$out_ath" -negate $(force8_args "$FORMAT") "$out_ath_inv"

  run magick "$enh_png" -morphology TopHat "Disk:${TOPHAT_RADIUS}" -contrast-stretch "$STRETCH_ARG" \
    $(force8_args "$FORMAT") "$out_th"
  run magick "$out_th" -negate $(force8_args "$FORMAT") "$out_th_inv"

  best="$(pick_best_variant "$out_enh" "$out_th" "$out_th_inv" "$out_ath_inv" "$out_ath" "$out_lat" "$out_bg")"
  [[ -n "$best" ]] || best="$out_enh"
  run cp -f "$best" "$final_out"
  say "Chosen : $(basename "$best") -> $(basename "$final_out")"

  if [[ "${HARD_TILE}" -gt 0 ]]; then
    tdir="${out_dir}/tiles_${in_name}_ocr"
    mkdir -p "$tdir"
    run magick "$final_out" -crop "${HARD_TILE}x${HARD_TILE}" +repage +adjoin \
      $(force8_args "$FORMAT") "${tdir}/tile_%03d.${FORMAT}"
  fi

  if [[ "$KEEP_VARIANTS" -ne 1 ]]; then
    run rm -f "$base_png" "$crop_png" "$bg_png" "$clahe_png" "$enh_png" \
              "$out_bg" "$out_enh" "$out_lat" "$out_ath" "$out_ath_inv" "$out_th" "$out_th_inv"
  fi

  if [[ "$QUIET" -eq 0 ]]; then
    echo "Final:"
    echo "  $final_out"
    echo "Chosen:"
    echo "  $best"
    if [[ "${HARD_TILE}" -gt 0 ]]; then
      echo "Tiles:"
      echo "  ${out_dir}/tiles_${in_name}_ocr/tile_*.${FORMAT}"
    fi
  else
    echo "$final_out"
  fi
  exit 0
fi

# ---------- single-output presets ----------
if [[ -z "$OUT" ]]; then
  OUT="${out_dir}/${in_name}_ocr.${FORMAT}"
fi

cmd=(magick "$INPUT" -strip)

if [[ "$DO_GRAY" -eq 1 ]]; then cmd+=(-colorspace Gray); fi
if [[ -n "$WIDTH" ]]; then cmd+=(-resize "${WIDTH}x"); fi

case "$PRESET" in
  clahe)
    cmd+=(-clahe "$CLAHE_ARG" -unsharp "$UNSHARP_ARG" -contrast-stretch "$STRETCH_ARG")
    ;;
  bgfix)
    cmd+=( \( +clone -blur "0x${BLUR_RADIUS}" \) -compose Divide -composite -auto-level -unsharp "$UNSHARP_ARG" )
    ;;
  bw)
    cmd+=(-clahe "$CLAHE_ARG" -unsharp "$UNSHARP_ARG" -lat "${ADAPTIVE_ARG}")
    ;;
  *)
    echo "ERROR: unknown preset '$PRESET' (use clahe|bgfix|bw|hard)" >&2
    exit 1
    ;;
esac

if [[ "$DO_DESKEW" -eq 1 ]]; then cmd+=(-deskew 40%); fi
if [[ "$DO_TRIM" -eq 1 ]]; then cmd+=(-trim +repage); fi

if [[ "$FORCE_8BIT" -eq 1 ]]; then
  case "$FORMAT" in
    png) cmd+=(-depth 8 -type Grayscale -define png:color-type=0 -define png:bit-depth=8) ;;
    jpg|jpeg) cmd+=(-alpha remove -alpha off -depth 8) ;;
    tif|tiff) cmd+=(-depth 8) ;;
  esac
fi

cmd+=("$OUT")

if [[ "$QUIET" -eq 0 ]]; then
  echo "Preset : $PRESET"
  echo "Input  : $INPUT"
  echo "Output : $OUT"
  echo "Force8 : $FORCE_8BIT"
fi

if [[ "$DRYRUN" -eq 1 ]]; then
  printf 'CMD:'; printf ' %q' "${cmd[@]}"; printf '\n'
  exit 0
fi

"${cmd[@]}"

if [[ "$QUIET" -eq 0 ]]; then echo "Done."; fi
