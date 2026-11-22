#!/bin/sh
# Usage: healthcheck.sh PORT [PORT...]
# Healthy (exit 0) only if PID 1 owns a UDP socket on EVERY given port.
# Works with network_mode: host, where /proc/net/udp* lists all host sockets.
[ $# -gt 0 ] || { echo "usage: $0 PORT [PORT...]" >&2; exit 2; }
fds=$(for fd in /proc/1/fd/*; do readlink "$fd" 2>/dev/null; done)
for port in "$@"; do
    hex=$(printf '%04X' "$port")
    inodes=$(awk -v p=":$hex" '$2 ~ (p "$") {print $10}' /proc/net/udp /proc/net/udp6 2>/dev/null)
    owned=no
    for i in $inodes; do
        case "$fds" in *"socket:[$i]"*) owned=yes; break ;; esac
    done
    [ "$owned" = yes ] || { echo "UDP $port not owned by PID 1"; exit 1; }
done
echo "OK: PID 1 owns UDP $*"
