#!/bin/bash
# should be run from root directory: ./scripts/ci_build.sh
set -e
rootdir="$PWD"

cd third_party/x264
rm -r build_visionos out_visionos || true
mkdir build_visionos
cd build_visionos
bash "$rootdir/third_party/alvr/miniserver/scripts/visionos_build.sh"
make -j8 install
cd "$rootdir"

cd third_party/alvr
./dashboard_build.sh
./build.sh
cd "$rootdir"

rm -r *.dylib *.o *.metallib release || true

./metalbuild.sh
./build.sh
./scripts/release.sh
