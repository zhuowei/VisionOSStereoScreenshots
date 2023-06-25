#!/bin/bash
set -e
rsync -a . mini2:~/Documents/stereoscreenshots
ssh mini2 "cd ~/Documents/stereoscreenshots && bash build.sh"
