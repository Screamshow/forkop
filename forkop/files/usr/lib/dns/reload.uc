let fs = require("fs");
let uci = require("core.uci");
let common = require("core.common");
let as_string = common.as_string;

function quote(v) { return "'" + replace(as_string(v), /'/g, "'\\''") + "'"; }
function output(command, timeout) {
    let dir = null;
    if (type(fs.mkdtemp) == "function") dir = fs.mkdtemp("/tmp/forkop-dns-readiness.XXXXXX");
    else {
        let pipe = fs.popen("mktemp -d /tmp/forkop-dns-readiness.XXXXXX", "r");
        if (pipe) {
            let name = trim(as_string(pipe.read("all")));
            if (pipe.close() == 0 && match(name, /^\/tmp\/forkop-dns-readiness\.[A-Za-z0-9]+$/)) dir = name;
        }
    }
    if (dir == null) return "";
    let path = dir + "/output";
    let status = system("exec " + command + " >" + quote(path), int(timeout || 1000));
    let data = status == 0 ? as_string(fs.readfile(path)) : "";
    fs.unlink(path);
    fs.rmdir(dir);
    return data;
}
function service_instances() {
    try {
        let data = json(output("ubus call service list '{\"name\":\"dnsmasq\"}' 2>/dev/null"));
        return data.dnsmasq.instances;
    } catch (e) { return null; }
}
function select_processes(candidates) {
    let result = {};
    for (let path, group in candidates) {
        let root = null;
        for (let pid, proc in group) {
            if (group[proc.parent] != null) continue;
            if (root != null) return null; // Independent daemons are ambiguous.
            root = proc;
        }
        if (root == null) return null;
        for (let pid, proc in group) {
            let seen = {};
            while (proc.pid != root.pid) {
                if (seen[proc.pid]) return null;
                seen[proc.pid] = true;
                proc = group[proc.parent];
                if (proc == null) return null;
            }
        }
        // dnsmasq's DHCP script helper inherits its executable and -C argument.
        // Keep the parent daemon; ready() still verifies procd and DNS sockets.
        result[path] = root;
    }
    return result;
}
function process_map() {
    let candidates = {};
    for (let entry in fs.lsdir("/proc") || []) {
        if (match(entry, /^[0-9]+$/) == null || fs.readlink("/proc/" + entry + "/exe") != "/usr/sbin/dnsmasq")
            continue;
        let args = split(as_string(fs.readfile("/proc/" + entry + "/cmdline")), "\u0000");
        let path = "";
        for (let i = 0; i + 1 < length(args); i++)
            if (args[i] == "-C") path = args[i + 1];
        let stat = as_string(fs.readfile("/proc/" + entry + "/stat"));
        let fields = split(trim(substr(stat, rindex(stat, ")") + 1)), /[ \t]+/);
        if (path == "" || length(fields) < 20 || fields[0] == "Z") continue;
        if (candidates[path] == null) candidates[path] = {};
        candidates[path][entry] = { pid: entry, parent: fields[1], identity: entry + ":" + fields[19] };
    }
    return select_processes(candidates);
}
function values(v) { return type(v) == "array" ? v : (v == null || v == "" ? [] : [as_string(v)]); }
function contains(items, value) { for (let item in items) if (item == value) return true; return false; }
function options(text, key) {
    let result = [];
    for (let line in split(as_string(text), "\n")) {
        line = trim(line);
        if (line == key) push(result, "");
        else if (substr(line, 0, length(key) + 1) == key + "=") push(result, substr(line, length(key) + 1));
    }
    return result;
}
function expected_config(section, text) {
    let port = as_string(section.port == null ? "53" : section.port);
    if (match(port, /^[0-9]+$/) == null || int(port) > 65535) return false;
    let generated_port = options(text, "port");
    if (length(generated_port) > 1 || as_string(generated_port[0] == null ? "53" : generated_port[0]) != port) return false;
    if (sprintf("%J", options(text, "server")) != sprintf("%J", values(section.server))) return false;
    if ((length(options(text, "no-resolv")) > 0) != common.bool_option(section, "noresolv", false)) return false;
    if (section.cachesize != null && sprintf("%J", options(text, "cache-size")) != sprintf("%J", [as_string(section.cachesize)])) return false;
    return true;
}
function plan() {
    let result = [];
    for (let section in uci.section_objects("dhcp", "dnsmasq")) {
        let name = as_string(section[".name"]);
        if (match(name, /^[A-Za-z0-9_]+$/) == null) return null;
        push(result, { name, section, disabled: common.bool_option(section, "disabled", false),
            path: "/var/etc/dnsmasq.conf." + name, port: int(section.port == null ? "53" : section.port) });
    }
    return length(result) > 0 ? result : null;
}
function owned_loopback_socket(pid, port, table, listening) {
    let inodes = {};
    for (let fd in fs.lsdir("/proc/" + pid + "/fd") || []) {
        let m = match(as_string(fs.readlink("/proc/" + pid + "/fd/" + fd)), /^socket:\[([0-9]+)\]$/);
        if (m) inodes[m[1]] = true;
    }
    for (let line in split(as_string(fs.readfile("/proc/net/" + table)), "\n")) {
        let cols = split(trim(line), /[ \t]+/);
        if (length(cols) < 10 || !inodes[cols[9]]) continue;
        let address = split(cols[1], ":");
        if (length(address) == 2 && (address[0] == "0100007F" || address[0] == "00000000") &&
            address[1] == sprintf("%04X", port) && (!listening || cols[3] == "0A")) return true;
    }
    return false;
}
function monotonic() { let t = clock(true); return t[0] + t[1] / 1000000000.0; }
function ready(entries, before, old_processes, old_instances, deadline) {
    let instances = service_instances();
    let processes = process_map();
    if (instances == null || processes == null) return false;
    let enabled = {};
    for (let entry in entries) {
        if (monotonic() >= deadline) return false;
        let instance = instances[entry.name];
        let proc = processes[entry.path];
        if (entry.disabled) {
            if (proc != null || (instance != null && instance.running)) return false;
            continue;
        }
        enabled[entry.name] = true;
        let text = fs.readfile(entry.path);
        if (instance == null || !instance.running || proc == null || text == null || !expected_config(entry.section, text)) return false;
        // The procd PID can be the jail wrapper. Bind the real daemon to that
        // instance by its parent, exact executable and -C argument.
        if (as_string(instance.pid) != proc.pid && as_string(instance.pid) != proc.parent) return false;
        let old = old_processes == null ? null : old_processes[entry.path];
        if (before[entry.path] != text && old != null && old.identity == proc.identity) return false;
        if (entry.port != 0) {
            if (!owned_loopback_socket(proc.pid, entry.port, "udp", false) ||
                !owned_loopback_socket(proc.pid, entry.port, "tcp", true)) return false;
            // CHAOS is answered locally, without depending on WAN or sing-box.
            // REFUSED is also a valid reply when version disclosure is disabled.
            let timeout = int((deadline - monotonic()) * 1000);
            if (timeout < 1) return false;
            let reply = output("dig @127.0.0.1 -p " + entry.port + " version.bind TXT CH +norecurse +time=1 +tries=1 +noall +comments 2>/dev/null", timeout < 1100 ? timeout : 1100);
            if (match(reply, /status: (NOERROR|REFUSED|NXDOMAIN|NOTIMP),/) == null) return false;
        }
        if (fs.readfile(entry.path) != text || process_map()?.[entry.path]?.identity != proc.identity) return false;
    }
    for (let name, instance in old_instances || {})
        if (!enabled[name] && (instances[name]?.running || processes["/var/etc/dnsmasq.conf." + name] != null)) return false;
    return true;
}
function wait_ready(entries, before, processes, instances, timeout) {
    let deadline = monotonic() + timeout;
    let confirmed = false;
    while (monotonic() < deadline) {
        let ok = ready(entries, before, processes, instances, deadline);
        if (ok && confirmed) return true;
        confirmed = ok;
        sleep(50);
    }
    return false;
}
function apply(init) {
    let entries = plan();
    let before = {};
    let processes = process_map();
    let instances = service_instances();
    let loopback_supported = true;
    for (let entry in entries || []) {
        if (entry.disabled || entry.port == 0) continue;
        let addresses = values(entry.section.listen_address);
        if (length(addresses) > 0 && !contains(addresses, "127.0.0.1") && !contains(addresses, "0.0.0.0"))
            loopback_supported = false;
        for (let iface in values(entry.section.notinterface))
            if (iface == "lo" || iface == "loopback") loopback_supported = false;
        let interfaces = values(entry.section.interface);
        if (length(interfaces) > 0 && !contains(interfaces, "lo") && !contains(interfaces, "loopback"))
            loopback_supported = false;
    }
    // Unknown init/layout and non-loopback listeners retain the existing
    // synchronous restart contract; do not infer readiness from another DNS.
    if (init != "/etc/init.d/dnsmasq" || entries == null || !loopback_supported)
        return system("[ -x " + quote(init) + " ] && " + quote(init) + " restart", 15000) == 0;
    for (let entry in entries) before[entry.path] = fs.readfile(entry.path);
    if (processes != null && instances != null &&
        system("exec " + quote(init) + " reload", 15000) == 0 && wait_ready(entries, before, processes, instances, 4)) return true;
    system("logger -t forkop 'dnsmasq reload not ready; falling back to restart'");
    return system("exec " + quote(init) + " restart", 15000) == 0 && wait_ready(entries, before, processes, instances, 8);
}
return { apply, expected_config, options, plan, process_map, select_processes, service_instances, owned_loopback_socket };
