#!/bin/sh
set -e
xcrun -sdk xrsimulator clang -target arm64-apple-xros1.0-simulator -Os -g -Wall -fmodules -fobjc-arc -shared -o libvisionos_stereo_screenshots.dylib visionos_stereo_screenshots.m CoreRE.tbd
