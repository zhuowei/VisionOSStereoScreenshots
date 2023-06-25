#!/bin/bash
set -e
xcrun simctl spawn booted launchctl debug user/$UID/com.apple.backboardd --environment DYLD_INSERT_LIBRARIES=$PWD/libvisionos_stereo_screenshots.dylib
xcrun simctl spawn booted launchctl kill TERM user/$UID/com.apple.backboardd
