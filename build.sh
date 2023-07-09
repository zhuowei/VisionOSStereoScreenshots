#!/bin/sh
set -e
CFLAGS="-target arm64-apple-xros1.0-simulator -Os -g -Wall -fmodules -fobjc-arc -Ithird_party/x264/out_visionos/include"
xcrun -sdk xrsimulator clang $CFLAGS -c visionos_stereo_screenshots.m
xcrun -sdk xrsimulator clang++ $CFLAGS -c -std=c++17 miniserver.mm
xcrun -sdk xrsimulator clang++ $CFLAGS -c -std=c++17 third_party/alvr/miniserver/NalParsing.cpp
xcrun -sdk xrsimulator clang++ $CFLAGS -c -std=c++17 third_party/alvr/miniserver/EncodePipelineSW.cpp
xcrun -sdk xrsimulator clang++ $CFLAGS -shared -o libvisionos_stereo_screenshots.dylib -fvisibility=hidden \
	visionos_stereo_screenshots.o miniserver.o NalParsing.o EncodePipelineSW.o \
	third_party/x264/out_visionos/lib/libx264.a third_party/alvr/target/aarch64-apple-ios/debug/libalvr_server.a \
	RealitySystemSupport.tbd CoreRE.tbd \
	-framework Foundation -framework CoreFoundation -framework Security -framework AudioToolbox -framework Metal \
	-Wl,-exported_symbols_list -Wl,exported_symbols.txt -Wl,-dead_strip \
	2>&1|grep -v "built for iOS"
