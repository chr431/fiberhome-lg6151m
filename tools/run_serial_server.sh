#!/bin/sh
# run_serial_server.sh -- supervisor: keep the serial console daemon alive.
while true; do
    python "$(dirname "$0")/serial_server.py"
    echo "serial_server exited rc=$? -- restarting in 3s" >&2
    sleep 3
done
