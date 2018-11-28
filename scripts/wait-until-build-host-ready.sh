#!/bin/bash

set -e -x -E

attempts=180
while [ $attempts -gt 0 ] && ! systemctl is-system-running; do
    # Wait for init-script to finish.
    sleep 10
    attempts=$(expr $attempts - 1 || true)
done
sudo journalctl -u rc-local | cat || true

if [ $attempts -le 0 ]; then
    exit 1
fi
