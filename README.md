# ffdvfx

Two-pass FFmpeg pipeline. Bakes 16:9 anamorphic `dvvideo` compression artifacts, noise and exponential 35mm highlight halation into digital video, rendering four 25p Rec.709 files simultaneously. (Youtube 4k, UHD BD, HD BD, generic web)

```bash
chmod +x ffdvfx.sh && ./ffdvfx.sh input.mp4 
```

## Outputs (All 25 fps, Rec.709, 48kHz Stereo)

1. `*_yt4k.mp4`: 4K HEVC (`55M`, `hvc1`) + AAC `320k` (`+faststart`). Forces YouTube's high-bitrate VP9/AV1 tier to preserve grain.
2. `*_uhd_bd.m2ts`: 4K UHD-BD HEVC (`50M`, `-g 25 -bf 0`) + `pcm_bluray`. Bitrate-capped for stutter-free playback on cheap 25GB BD-R media.
3. `*_1080p_bd.m2ts`: Standard BD H.264 (`35M`, `fake-interlaced=1:bluray-compat=1`) + `pcm_bluray`.
4. `*_mobile.mp4`: 1080p H.264 (`crf 20`, max `12M`, `yuv420p`) + AAC `192k` for universal phone/Telegram inline streaming.

## Architecture & Hardware

* **Pass 1:** `1440x1080` (`4:3` SAR) `dvvideo` (`yuv422p`, `topleft` chroma) with pre-encode YUV noise (`12:6:6`) to force 8x8 DCT shimmer across static areas.
* **Pass 2:** Dual-radius `gbrp` screen-blended halation (`sigma=3.0` core + `sigma=16` tail, `>70%` luma power ramp) at 1080p, followed by 4K Lanczos upscale + `unsharp`.
* **GPU Auto-Detect:** Uses `hevc_videotoolbox` (Apple Silicon), `hevc_vaapi` via `/dev/dri/renderD128` (Linux AMD/Intel), or falls back to `libx265`.

## Quirks & Obscure Details

* **DV Metadata Stripping (`in_range=tv`):** The legacy `dvvideo` bitstream lacks header fields for `bt709` and `tv` (`16-235`) color range, stripping them to `unknown` (`ffprobe` confirms `color_range=unknown` on the `.avi` intermediate despite valid `tv`/`bt709` tags on source camera files). Pass 2 explicitly re-locks `in_color_matrix=bt709` and `in_range=tv` before RGB conversion so `swscale` never misinterprets untagged DV frames.
* **Panasonic TZ10 & HC-W580 Quirks:** Consumer Panasonic cameras record `tv` range with super-white overshoot (`236-254`) and broken MP4 edit lists (`timestamp: 3600`). Do not auto-detect `full` range via `YMAX` (causes false positives and milky blacks), and pass `-ignore_editlist 1`.
* **50p Stutter (HC-W580):** Dropping high-shutter `50p` straight to `25p` causes staccato motion. Shoot with shutter locked to `1/50s`, blend in your NLE, or prepend `tmix=frames=2:weights='1 1',fps=25,` to Pass 1's `-vf`.
* **Disk Intermediate vs. Pipe:** Piping throttles `dvvideo` threading; sequential `.avi` I/O maximizes throughput.
* **Why `-bf 0` on UHD `.m2ts`:** `hevc_videotoolbox` open-GOP B-frames break POC/RPS headers in MPEG-TS muxers, causing seek/decode errors in `mpv` and `tsMuxeR`.
* **Why `pcm_bluray`:** Standard `.m2ts` muxers flag little-endian `pcm_s16le` as unrecognized private data (no audio).
* **Why `fake-interlaced=1`:** Legacy 1080p Blu-ray forbids `1080p25`; encoding as `1080i50` PsF passes strict authoring checks without interlacing artifacts.
* **End-to-End 8-Bit:** Source footage, `dvvideo`, and `gbrp` blends are 8-bit. Pre-DV grain acts as natural dithering against banding, maximizes bitrate efficiency for grain retention, and avoids 10-bit VA-API bugs on older Intel QuickSync (e.g., 7th-gen Kaby Lake).

