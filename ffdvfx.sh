#!/usr/bin/env bash
set -euo pipefail

INPUT="$1"
if [ -z "$INPUT" ]; then
  echo "Usage: ./ffdvfx.sh input.mkv"
  exit 1
fi

BASENAME="${INPUT%.*}"
TEMP_DV="${BASENAME}_temp_dv.avi"

OUT_YT="${BASENAME}_yt4k.mp4"
OUT_UHD_BD="${BASENAME}_uhd_bd.m2ts"
OUT_HD_BD="${BASENAME}_1080p_bd.m2ts"
OUT_PHONE="${BASENAME}_mobile.mp4"

# --- Unified 8-bit platform & hardware acceleration detection ---
OS="$(uname -s)"
VAAPI_INIT=""

if [ "$OS" = "Darwin" ]; then
  HW_MODE="Apple Silicon 8-bit (VideoToolbox)"
  HEVC_YT="-c:v hevc_videotoolbox -profile:v main -pix_fmt nv12 -b:v 55M -maxrate 80M -bufsize 80M -r 25 -g 50 -tag:v hvc1"
  HEVC_BD="-c:v hevc_videotoolbox -profile:v main -pix_fmt nv12 -b:v 50M -maxrate 65M -bufsize 65M -r 25 -g 25 -bf 0 -tag:v hvc1"
  V_YT_FILTER="format=nv12"
  V_UHD_FILTER="format=nv12"

elif [ "$OS" = "Linux" ] && [ -e "/dev/dri/renderD128" ]; then
  HW_MODE="Linux GPU 8-bit VA-API (AMD / Intel)"
  VAAPI_INIT="-vaapi_device /dev/dri/renderD128"
  HEVC_YT="-c:v hevc_vaapi -profile:v main -b:v 55M -maxrate 80M -bufsize 80M -r 25 -g 50 -tag:v hvc1"
  HEVC_BD="-c:v hevc_vaapi -profile:v main -b:v 50M -maxrate 65M -bufsize 65M -r 25 -g 25 -bf 0 -tag:v hvc1"
  V_YT_FILTER="format=nv12,hwupload"
  V_UHD_FILTER="format=nv12,hwupload"

else
  HW_MODE="CPU 8-bit Fallback (libx265)"
  HEVC_YT="-c:v libx265 -profile:v main -pix_fmt yuv420p -preset fast -b:v 55M -maxrate 80M -bufsize 80M -r 25 -g 50 -tag:v hvc1"
  HEVC_BD="-c:v libx265 -profile:v main -pix_fmt yuv420p -preset fast -b:v 50M -maxrate 65M -bufsize 65M -r 25 -g 25 -x265-params uhd-bd=1:level-idc=5.1:high-tier=1:keyint=25:min-keyint=1:open-gop=1"
  V_YT_FILTER="format=yuv420p"
  V_UHD_FILTER="format=yuv420p"
fi

echo "----------------------------------------------------"
echo "Platform:       $HW_MODE"
echo "Input:          $INPUT"
echo "----------------------------------------------------"

echo "Step 1: Creating 16:9 anamorphic DV intermediate (1440x1080 @ 25 fps)..."
ffmpeg -y -ignore_editlist 1 -i "$INPUT" \
  -vf "scale=1440:1080:flags=lanczos,noise=c0s=12:c1s=6:c2s=6:allf=t+p,setparams=chroma_location=topleft" \
  -c:v dvvideo -pix_fmt yuv422p -r 25 -an \
  "$TEMP_DV"

echo "Step 2: Rendering YouTube 4K + UHD-BD + 1080p-BD + Mobile/Telegram..."
ffmpeg -y $VAAPI_INIT -i "$TEMP_DV" -ignore_editlist 1 -vn -i "$INPUT" \
  -filter_complex "\
    [0:v]scale=1920:1080:flags=lanczos:in_color_matrix=bt709:out_color_matrix=bt709:in_range=tv:out_range=tv,setsar=1/1,format=gbrp,split=2[base][g1]; \
    [g1]split=2[g1a][g1b]; \
    [g1a]lutrgb=r='pow(max(0,val-179)/76,4.2)*255':g='pow(max(0,val-194)/61,4.8)*90':b=0,gblur=sigma=3.0[halo_core]; \
    [g1b]lutrgb=r='pow(max(0,val-189)/66,4.8)*255':g='pow(max(0,val-204)/51,5.5)*40':b=0,gblur=sigma=16[halo_tail]; \
    [base][halo_core]blend=all_mode=screen:all_opacity=1.0[step1]; \
    [step1][halo_tail]blend=all_mode=screen:all_opacity=0.38,setsar=1/1,split=2[hd_split][to_4k]; \
    [hd_split]split=2[v_1080p_bd][v_phone]; \
    [to_4k]scale=3840:2160:flags=lanczos:in_color_matrix=bt709:out_color_matrix=bt709:in_range=tv:out_range=tv,unsharp=3:3:0.35,setsar=1/1,split=2[yt_raw][uhd_raw]; \
    [yt_raw]${V_YT_FILTER}[v_yt]; \
    [uhd_raw]${V_UHD_FILTER}[v_uhd]" \
  \
  `# --- Output 1: YouTube 4K (.mp4) ---` \
  -map "[v_yt]" -map 1:a? \
  $HEVC_YT -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -b:a 320k -ar 48000 -ac 2 \
  -movflags +faststart \
  "$OUT_YT" \
  \
  `# --- Output 2: 4K UHD Blu-ray (.m2ts, BD-25 safe) ---` \
  -map "[v_uhd]" -map 1:a? \
  $HEVC_BD -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_bluray -ar 48000 -ac 2 \
  "$OUT_UHD_BD" \
  \
  `# --- Output 3: Standard 1080p Blu-ray (.m2ts, 1080i50 PsF compliant) ---` \
  -map "[v_1080p_bd]" -map 1:a? \
  -c:v libx264 -profile:v high -level:v 4.1 -preset fast -pix_fmt yuv420p \
  -b:v 35M -maxrate 38M -bufsize 30M -r 25 \
  -x264-params "bluray-compat=1:fake-interlaced=1:keyint=25:min-keyint=1:open-gop=1:slices=4:colorprim=bt709:transfer=bt709:colormatrix=bt709" \
  -c:a pcm_bluray -ar 48000 -ac 2 \
  "$OUT_HD_BD" \
  \
  `# --- Output 4: Smartphone / Telegram / Cloud Drive (.mp4) ---` \
  -map "[v_phone]" -map 1:a? \
  -c:v libx264 -profile:v high -level:v 4.1 -preset medium -crf 20 -pix_fmt yuv420p \
  -maxrate 12M -bufsize 24M -r 25 -g 50 \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart \
  "$OUT_PHONE"

rm -f "$TEMP_DV"
echo "----------------------------------------------------"
echo "Done on $HW_MODE!"
echo " -> YouTube 4K:     $OUT_YT"
echo " -> 4K UHD-BD:      $OUT_UHD_BD"
echo " -> 1080p Blu-ray:  $OUT_HD_BD"
echo " -> Smartphone/TG:  $OUT_PHONE"

