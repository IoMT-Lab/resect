#!/bin/bash

rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1600x1000x24 -ac >/tmp/xvfb.log 2>&1 &
sleep 1
x11vnc -display :99 -forever -nopw -shared -rfbport 5900 >/tmp/x11vnc.log 2>&1 &
sleep 1
export DISPLAY=:99

resect