#!/bin/bash
# Record video from the IMX681 at a bitrate that does not destroy the image.
#
#   ./sp11-record.sh [-o FILE] [-t SECONDS] [-w WIDTH] [-h HEIGHT]
#                    [-b MBPS] [-f FPS] [-c CODEC] [-a]
#
#   -o  output file                    (default sp11-<timestamp>.<ext>)
#   -t  duration in seconds            (default 15)
#   -w  width                          (default 1920)
#   -h  height                         (default 1080)
#   -b  video bitrate in Mbit/s        (default 8)
#   -f  frame rate                     (default 30)
#   -c  h264 | hevc | vp8              (default h264, hardware)
#   -a  record audio as well           (default video only)
#
# WHY THIS EXISTS
#
# GNOME Snapshot records 1080p30 at roughly 0.5 Mbit/s. The preview looks
# excellent and the file is a blocky mess, because the two go down different
# paths: the preview is libcamera's frames straight to the screen, while the
# recording goes through `vp8enc`, whose GStreamer default `target-bitrate` is
# **256000** -- 256 kbit/s, a sane default for 2010-era web video and about an
# order of magnitude too little for 1080p30. Snapshot exposes no setting for it.
#
# Measured on this machine, same camera, same scene, ~12 s of 1080p30:
#
#     GNOME Snapshot        940,806 bytes   (~0.5 Mbit/s)   heavy blocking
#     this script at 8      8,041,107 bytes  (8 Mbit/s)     clean
#
# So a poor recording from this camera is not a camera fault, and not worth
# debugging as one. Check the bitrate first.
#
# THERE IS A HARDWARE ENCODER, AS OF MISSION 19
#
# An earlier version of this file said there was not. That was wrong twice
# over: the firmware was never missing (it is in the Windows driver store, now
# at /lib/firmware/qcom/x1e80100/microsoft/Denali/qcvss8380.mbn) and the driver
# was never absent -- `hamoa.dtsi` ships `iris: video-codec@aa00000` with
# `status = "disabled"` because the blob is vendor-signed and each board must
# name its own. Our device tree now does. iris binds through the sm8550
# fallback and registers a decoder and an encoder:
#
#     encode   H.264, HEVC
#     decode   H.264, HEVC, VP9, AV1
#
# **No VP8, either direction.** VP8 here is still software on the CPU, so `-c
# vp8` is kept only for compatibility with what Snapshot writes.
#
# Two things the hardware encoder needs that are not obvious:
#
# 1. **Pin the profile and level in caps.** With nothing downstream to constrain
#    it, GStreamer fixates the encoder's src caps to the first value in each
#    list -- Baseline, level 1. Level 1 permits 99 macroblocks; 1080p is 8160.
#    The stream decodes anyway under ffmpeg, but GStreamer's own caps
#    negotiation then refuses it, so `v4l2h264dec` cannot play back what
#    `v4l2h264enc` just wrote. Pinning `profile=main,level=4` fixes both ends.
#
# 2. **Divide the bitrate by the frame rate.** iris treats
#    `V4L2_CID_MPEG_VIDEO_BITRATE` as bits per *frame*, where V4L2 defines it as
#    bits per second. Measured by asking for 2 Mbit/s at three frame rates:
#
#        30 fps -> 60.04 Mbit/s   (30.0x)
#        15 fps -> 30.02 Mbit/s   (15.0x)
#        60 fps -> 119.98 Mbit/s  (60.0x)
#
#    The factor is the frame rate to three digits. Dividing the request by FPS
#    lands it: asking 266,667 gave 8,006,250 bit/s off the camera. If a future
#    driver fixes the units, this correction has to come out in the same commit
#    -- the symptom would be recordings at 1/30 of the requested bitrate.

set -u

OUT=""
SECS=15
W=1920
H=1080
MBPS=8
FPS=30
CODEC=h264
AUDIO=0

while getopts 'o:t:w:h:b:f:c:a?' o; do
    case $o in
        o) OUT=$OPTARG ;;
        t) SECS=$OPTARG ;;
        w) W=$OPTARG ;;
        h) H=$OPTARG ;;
        b) MBPS=$OPTARG ;;
        f) FPS=$OPTARG ;;
        c) CODEC=$OPTARG ;;
        a) AUDIO=1 ;;
        *) sed -n '2,15p' "$0"; exit 0 ;;
    esac
done

BITRATE=$(( MBPS * 1000000 ))

case $CODEC in
    h264|hevc)
        # See note 2 above: the control is per-frame on this encoder.
        PERFRAME=$(( BITRATE / FPS ))
        if [[ $CODEC == h264 ]]; then
            enc=( v4l2h264enc extra-controls="c,video_bitrate=$PERFRAME"
                  ! "video/x-h264,level=(string)4,profile=(string)main"
                  ! h264parse )
            need=( v4l2h264enc h264parse )
        else
            enc=( v4l2h265enc extra-controls="c,video_bitrate=$PERFRAME"
                  ! "video/x-h265,level=(string)4,profile=(string)main"
                  ! h265parse )
            need=( v4l2h265enc h265parse )
        fi
        mux=mp4mux; ext=mp4; aenc=opusenc
        ;;
    vp8)
        # Software. deadline=1 / cpu-used=4 keeps 1080p30 real-time here.
        enc=( vp8enc target-bitrate=$BITRATE deadline=1 cpu-used=4 keyframe-max-dist=60 )
        need=( vp8enc )
        mux=webmmux; ext=webm; aenc=vorbisenc
        ;;
    *)  echo "unknown codec '$CODEC' (h264, hevc, vp8)" >&2; exit 2 ;;
esac

[[ -n $OUT ]] || OUT="sp11-$(date +%Y%m%d-%H%M%S).$ext"

for e in "${need[@]}" "$mux" libcamerasrc; do
    gst-inspect-1.0 "$e" >/dev/null 2>&1 || {
        echo "missing GStreamer element '$e'." >&2
        echo "h264parse/h265parse live in gstreamer1.0-plugins-bad." >&2
        exit 1; }
done

echo "recording ${W}x${H}@${FPS} for ${SECS}s, $CODEC at ${MBPS} Mbit/s -> $OUT"

# libcamera picks the smallest sensor mode that covers the request, so the
# requested size decides which sensor mode runs. See design/native for the
# history -- one of the six modes used to deliver nothing at all, and every
# small request landed on it.
pipeline=(
    libcamerasrc
    ! "video/x-raw,width=$W,height=$H"
    ! videoconvert
    ! "${enc[@]}"
    ! queue
    ! "$mux" name=mux
    ! filesink location="$OUT"
)

if (( AUDIO )); then
    pipeline+=( autoaudiosrc ! audioconvert ! audioresample ! "$aenc" ! queue ! mux. )
fi

# Duration is enforced by interrupting gst-launch, not by an `identity
# eos-after=N` on the video branch. eos-after ends only the branch it sits in,
# so with -a the audio branch keeps producing, the muxer never sees EOS on every
# pad, and the recording runs until something else kills it -- a 5 s request
# produced a 1 m 42 s file. SIGINT with -e sends EOS through the whole graph.
timeout -s INT "$SECS" gst-launch-1.0 -e "${pipeline[@]}"
rc=$?
# 124 is timeout's own "I killed it", which here is the normal path.
if (( rc != 0 && rc != 124 && rc != 130 )); then
    echo "gst-launch failed with $rc" >&2
    exit 1
fi

if [[ -f $OUT ]]; then
    bytes=$(stat -c %s "$OUT")
    echo "wrote $OUT  $(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes")B" \
         "-> $(( bytes * 8 / (SECS * 1000000) )) Mbit/s actual"
fi
