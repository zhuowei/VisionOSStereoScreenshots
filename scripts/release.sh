#!/bin/sh
set -e
rm -rf release || true
mkdir -p release/alvr_visionos_streaming
cp libvisionos_stereo_screenshots.dylib inject.sh README.md default.metallib release/alvr_visionos_streaming/
cp third_party/alvr/target/debug/alvr_dashboard release/alvr_visionos_streaming/
cd release
7z a alvr_visionos_streaming.zip alvr_visionos_streaming
