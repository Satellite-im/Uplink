#!/bin/sh
# Compiles windows/runner/call_video.cpp over the stand-ins here and runs it (check.cpp), then makes a picture of the
# first layout and of the second from the frames it wrote: <out>/first.png, <out>/second.png. Needs clang and ffmpeg.
#   sh tool/voicebench/call_video_stub/run.sh <a scratch folder>
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?a folder for what is made}
mkdir -p "$out"
clang++ -std=c++17 -Wall -Wextra -Wshadow -Wconversion -Wno-sign-conversion -O1 -I "$here" -I "$here/../../../windows/runner" \
  "$here/check.cpp" "$here/../../../windows/runner/call_video.cpp" -o "$out/check"
"$out/check" "$out/video.mp4"
echo "frames: $(wc -l < "$out/video.mp4.times")"
ffmpeg -v error -y -f rawvideo -pix_fmt nv12 -s 1280x720 -i "$out/video.mp4.nv12" -vf "select=eq(n\,8)" -frames:v 1 "$out/first.png"
ffmpeg -v error -y -f rawvideo -pix_fmt nv12 -s 1280x720 -i "$out/video.mp4.nv12" -vf "select=eq(n\,24)" -frames:v 1 "$out/second.png"
