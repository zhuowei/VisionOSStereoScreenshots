#!/bin/bash
set -e
rsync -a --exclude .git --exclude third_party . mini2:~/Documents/stereoscreenshots
ssh mini2 "cd ~/Documents/stereoscreenshots && bash build.sh"
