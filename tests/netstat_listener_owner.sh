#!/bin/sh
set -eu
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
FORKOP_LIB=${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}
ucode -L "$FORKOP_LIB" -e '
let n = require("core.netstat");
let checks = 0;
function check(row, address, port, pid, expected) {
    if (n.tcp_listen_port_owned(row, address, port, pid) != expected)
        die("Unexpected listener ownership: " + row);
    checks++;
}
let tcp = "tcp 0 0 127.0.0.1:4534 0.0.0.0:* LISTEN 4200/sing-box";
check(tcp, "127.0.0.1", 4534, 4200, true);
check(tcp, "127.0.0.1", 4534, 4100, false);
check(tcp, "127.0.0.1", 4534, 420, false);
check(tcp, "127.0.0.1", 45340, 4200, false);
check(tcp, "127.0.0.2", 4534, 4200, false);
check(tcp, "127.0.0.1", 4534, 0, false);
check(replace(tcp, "LISTEN", "ESTABLISHED"), "127.0.0.1", 4534, 4200, false);
check("udp 0 0 127.0.0.1:4534 0.0.0.0:* 4200/sing-box", "127.0.0.1", 4534, 4200, false);
check(replace(tcp, "4200/sing-box", "-"), "127.0.0.1", 4534, 4200, false);
check("tcp6 0 0 :::4534 :::* LISTEN 4200/sing-box", "::1", 4534, 4200, true);
check("tcp6 0 0 [::1]:4534 :::* LISTEN 4200/sing-box", "::1", 4534, 4200, true);
check("tcp 0 0 0.0.0.0:4534 0.0.0.0:* LISTEN 4200/sing-box", "127.0.0.1", 4534, 4200, true);
print("TCP listener ownership checks passed: ", checks, " assertions\n");
'
