#!/bin/sh
exec xcrun simctl spawn booted launchctl kill USR1 user/$UID/com.apple.backboardd
