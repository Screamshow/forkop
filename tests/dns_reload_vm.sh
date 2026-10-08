#!/bin/sh
set -eu
D=/tmp/forkop-next-dns-test
umask 077
mkdir -p "$D"
cp /etc/config/dhcp "$D/dhcp.before"
cp /etc/init.d/dnsmasq "$D/dnsmasq"
chmod +x "$D/dnsmasq"
if command -v apk >/dev/null; then apk list --installed; else opkg list-installed; fi > "$D/packages.before"
ubus call service list > "$D/services.before"
finish() {
    rc=$?
    trap - EXIT
    cp "$D/dnsmasq" /etc/init.d/dnsmasq
    cp "$D/dhcp.before" /etc/config/dhcp
    /etc/init.d/dnsmasq restart > "$D/recovery-dns.log" 2>&1
    /usr/bin/forkop restart > "$D/recovery-forkop.log" 2>&1
    cmp "$D/dnsmasq" /etc/init.d/dnsmasq
    /usr/bin/forkop get_status
    dig @127.0.0.1 example.com A +time=3 +tries=1 +short
    echo "RESTORED rc=$rc"
    exit "$rc"
}
trap finish EXIT
apply() {
    ucode -L /usr/lib/forkop -L /tmp -e 'let m = require("reload_candidate"); let t=clock(true); let ok=m.apply("/etc/init.d/dnsmasq"); let e=clock(true); printf("DNS_APPLY ok=%J elapsed=%.3f\n",ok,e[0]-t[0]+(e[1]-t[1])/1000000000.0); exit(ok?0:1);'
}
uci set 'dhcp.@dnsmasq[0].dhcpscript=/bin/true'
uci commit dhcp
apply
ucode -L /usr/lib/forkop -L /tmp -e 'let m=require("reload_candidate"); let p=m.process_map(); if(p==null) die("DHCP helper caused ambiguous DNS ownership\n"); print(sprintf("DHCP_HELPER_PROCESS_MAP=%J\n",p));'
echo DHCP_SCRIPT_HELPER_PASSED
uci set 'dhcp.@dnsmasq[0].cachesize=117'
uci commit dhcp
apply
echo CHANGED_CONFIG_PASSED
uci set dhcp.forkop_probe=dnsmasq
uci set dhcp.forkop_probe.port=1053
uci set dhcp.forkop_probe.listen_address=127.0.0.1
uci set dhcp.forkop_probe.noresolv=1
uci set dhcp.forkop_probe.localuse=0
uci set dhcp.forkop_probe.cachesize=118
uci add_list dhcp.forkop_probe.server=127.0.0.42
uci commit dhcp
apply
dig @127.0.0.1 -p 1053 version.bind TXT CH +norecurse +time=1 +tries=1 +noall +comments | grep -Eq 'status: (NOERROR|REFUSED|NXDOMAIN|NOTIMP)'
echo MULTI_CUSTOM_PORT_PASSED
uci set dhcp.forkop_probe.port=0
uci commit dhcp
apply
echo PORT_ZERO_PASSED
uci set dhcp.forkop_probe.disabled=1
uci commit dhcp
apply
echo DISABLED_INSTANCE_PASSED
cat > /etc/init.d/dnsmasq <<'SH'
#!/bin/sh
echo "$1" >> /tmp/forkop-next-dns-test/calls
if [ "$1" = reload ]; then
    case "$(cat /tmp/forkop-next-dns-test/mode)" in
        noop) exit 0;;
        error) exit 1;;
        failboth) exit 1;;
        noopboth) exit 0;;
        stop) /tmp/forkop-next-dns-test/dnsmasq stop; exit 0;;
    esac
fi
[ "$(cat /tmp/forkop-next-dns-test/mode)" != failboth ] || exit 1
[ "$(cat /tmp/forkop-next-dns-test/mode)" != noopboth ] || exit 0
exec /tmp/forkop-next-dns-test/dnsmasq "$@"
SH
chmod +x /etc/init.d/dnsmasq
for mode in error noop stop; do
    echo "$mode" > "$D/mode"
    : > "$D/calls"
    uci set "dhcp.@dnsmasq[0].cachesize=$( [ "$mode" = error ] && echo 119 || echo 120 )"
    uci commit dhcp
    apply
    grep -qx reload "$D/calls"
    grep -qx restart "$D/calls"
    echo "FALLBACK_${mode}_PASSED"
done
echo failboth > "$D/mode"
uci set 'dhcp.@dnsmasq[0].cachesize=121'
uci commit dhcp
if apply; then echo FALSE_SUCCESS; exit 1; fi
echo BOTH_FAILURES_REJECTED
echo noopboth > "$D/mode"
if apply; then echo FALSE_READY_SUCCESS; exit 1; fi
echo BOTH_READINESS_TIMEOUTS_REJECTED
cp "$D/dnsmasq" /etc/init.d/dnsmasq
apply
echo RECOVERY_AFTER_FAILURE_PASSED
