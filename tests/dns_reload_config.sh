#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
ucode -L "$ROOT/forkop/files/usr/lib" -e '
let m = require("dns.reload");
function proc(pid, parent) { return {pid, parent, identity:pid + ":100"}; }
let daemon = proc("10", "1");
let helper = proc("11", "10");
for (let group in [{"10":daemon,"11":helper}, {"11":helper,"10":daemon}]) {
    if (m.select_processes({conf:group})?.conf?.pid != "10") die("DHCP helper rejected\n");
}
if (m.select_processes({conf:{"10":daemon,"12":proc("12","1")}}) != null) die("independent daemons accepted\n");
if (m.select_processes({conf:{"10":proc("10","11"),"11":helper}}) != null) die("cyclic ancestry accepted\n");
if (m.select_processes({one:{"10":daemon},two:{"12":proc("12","1")}})?.two?.pid != "12") die("separate instances rejected\n");
function check(section, text, expected) {
    if (m.expected_config(section,text) != expected) die("generated DNS expectation failed\n");
}
check({server:["127.0.0.42"],noresolv:1,cachesize:0},"server=127.0.0.42\nno-resolv\ncache-size=0\n",true);
check({server:["127.0.0.42"],noresolv:1,cachesize:0},"server=8.8.8.8\nno-resolv\ncache-size=0\n",false);
check({server:["1.1.1.1","8.8.8.8"],port:1053},"server=1.1.1.1\nserver=8.8.8.8\nport=1053\n",true);
check({server:["1.1.1.1","8.8.8.8"],port:1053},"server=8.8.8.8\nserver=1.1.1.1\nport=1053\n",false);
check({port:0},"port=0\n",true);
check({port:0},"",false);
check({port:1053},"port=53\n",false);
check({port:1053},"port=1053\nport=53\n",false);
check({port:70000},"port=70000\n",false);
check({noresolv:0},"no-resolv\n",false);
check({cachesize:0},"cache-size=1000\n",false);
check({},"# server=127.0.0.42\n",true);
print("DNS generated-config expectations passed\n");
'
