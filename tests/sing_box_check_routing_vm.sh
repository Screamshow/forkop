#!/bin/sh
# Run only on an authorized disposable OpenWrt VM with a br-lan network.
set -eu
LIB=${FORKOP_LIB:-/usr/lib/forkop}
work=$(mktemp -d /tmp/forkop-routing-check.XXXXXX)
ns=forkop-check-client
client_ip=192.168.241.250
router_ip=192.168.241.2
state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }
dns() { ucode -L "$LIB" "$LIB/dns/apply.uc" "$@"; }
source_dns() { ucode -L "$LIB" "$LIB/nft/apply.uc" "$1" ForkopTable; }
cp /etc/sing-box/config.json "$work/config.before"
uci export dhcp > "$work/dhcp.before"
opkg list-installed > "$work/packages.before"
ubus call service list > "$work/services.before"
nft list table inet ForkopTable > "$work/nft.before"
ip rule show > "$work/rules.before"
helper=
cleanup() {
    [ -z "$helper" ] || { kill -TERM "$helper" 2>/dev/null; wait "$helper" 2>/dev/null; }
    ip netns delete "$ns" 2>/dev/null || true
    ip link delete fk-check-lan 2>/dev/null || true
    nft delete element inet ForkopTable forkop_dns_sources "{ $client_ip }" 2>/dev/null || true
    source_dns resume-source-dns-redirect || true
    state stop-managed-sing-box-runtime 15 || true
    cp "$work/config.before" /etc/sing-box/config.json
    state start-managed-sing-box-runtime 15 || true
    dns configure force || true
    dns wait-listener || true
    rm -rf "$work"
}
trap cleanup EXIT
state single-ready-sing-box-runtime
state stop-managed-sing-box-runtime 15
cat > "$work/config.uc" <<'UC'
let fs=require("fs");
let c=json(fs.readfile(ARGV[0]));
c.log.level="info";
c.log.output=ARGV[1];
push(c.inbounds,{type:"direct",tag:"source-dns-in",listen:"::",listen_port:1603});
// The installed VM fixture predates per-source DNS. Its generated sniff /
// hijack rule only mentions dns-in, so make this extra test inbound explicit.
unshift(c.route.rules,{inbound:["source-dns-in"],action:"hijack-dns"});
push(c.outbounds,{type:"direct",tag:"routing-test-out"});
push(c.dns.rules,{domain:["example.com"],action:"route",server:"fakeip-server"});
push(c.route.rules,{domain:["example.com"],action:"route",outbound:"routing-test-out"});
fs.writefile(ARGV[0],sprintf("%J\n",c));
UC
ucode "$work/config.uc" /etc/sing-box/config.json "$work/core.log"
ip netns add "$ns"
ip link add fk-check-lan type veth peer name fk-check-peer
ip link set fk-check-peer netns "$ns"
ip link set fk-check-lan master br-lan
ip link set fk-check-lan up
ip -n "$ns" link set lo up
ip -n "$ns" link set fk-check-peer up
ip -n "$ns" addr add "$client_ip/24" dev fk-check-peer
ip -n "$ns" route add default via "$router_ip"
nft add element inet ForkopTable forkop_dns_sources "{ $client_ip }"
state start-managed-sing-box-runtime 15
dns configure force
dns wait-listener
while ! state single-ready-sing-box-runtime; do sleep 1; done
resolve() { ip netns exec "$ns" dig +short +time=3 +tries=1 "@$router_ip" "$1" A; }
get() { ip netns exec "$ns" curl --noproxy '*' --silent --show-error --fail --max-time 12 --resolve "$1:443:$2" "https://$1/" -o /dev/null; }
fake_before=$(resolve example.com | tail -n 1)
case "$fake_before" in 198.18.*|198.19.*) ;; *) echo 'client did not receive fake-IP' >&2; exit 1 ;; esac
get example.com "$fake_before"
grep -q 'routing-test-out' "$work/core.log"
direct_ip=$(resolve example.net | tail -n 1)
get example.net "$direct_ip"
policy() { nft list table inet ForkopTable | sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter packets X bytes Y/g' | md5sum | cut -d ' ' -f 1; }
before_policy=$(policy)
before_config=$(md5sum /etc/sing-box/config.json | cut -d ' ' -f 1)
mkdir "$work/bin"
cat > "$work/bin/sing-box" <<'SH'
#!/bin/sh
touch "$TEST_HOLD_FILE"
trap '' TERM
exec sleep 60
SH
chmod +x "$work/bin/sing-box"
export TEST_HOLD_FILE="$work/holding" FORKOP_LIB="$LIB"
TEST_STATUS=0
FORKOP_SING_BOX_CHECK_TIMEOUT=10 PATH="$work/bin:$PATH" sh "$LIB/service/sing-box-check.sh" rule-set match fixture &
helper=$!
while [ ! -f "$TEST_HOLD_FILE" ]; do kill -0 "$helper"; sleep 1; done
[ "$(state sing-box-process-count)" = 0 ]
native_answer=$(resolve example.com | tail -n 1)
case "$native_answer" in ''|198.18.*|198.19.*) echo 'LAN DNS failed during core pause' >&2; exit 1 ;; esac
get example.net "$direct_ip"
wait "$helper" || TEST_STATUS=$?
helper=
[ "$TEST_STATUS" = 124 ]
state single-ready-sing-box-runtime
fake_after=$(resolve example.com | tail -n 1)
[ "$fake_after" = "$fake_before" ]
get example.com "$fake_after"
get example.net "$direct_ip"
[ "$(policy)" = "$before_policy" ]
[ "$(md5sum /etc/sing-box/config.json | cut -d ' ' -f 1)" = "$before_config" ]
echo 'LAN routing: fake-IP DNS, transparent core outbound and direct HTTPS before/after timeout; source DNS and direct HTTPS during pause; config and nftables restored'
