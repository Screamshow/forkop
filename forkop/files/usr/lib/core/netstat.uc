function sing_box_standard_ports_listening(netstat, dns_address, tproxy_port, tproxy6_address) {
    netstat = netstat == null ? "" : "" + netstat;
    dns_address = dns_address == null ? "127.0.0.42" : "" + dns_address;
    tproxy_port = tproxy_port == null ? "1602" : "" + tproxy_port;
    tproxy6_address = tproxy6_address == null ? "::1" : "" + tproxy6_address;

    let dns_ok = index(netstat, dns_address + ":53") >= 0;
    let tproxy_suffix = ":" + tproxy_port;
    let tproxy4_ok = index(netstat, "0.0.0.0" + tproxy_suffix) >= 0 ||
        index(netstat, "127.0.0.1" + tproxy_suffix) >= 0;
    let tproxy6_ok = index(netstat, tproxy6_address + tproxy_suffix) >= 0 ||
        index(netstat, "[" + tproxy6_address + "]" + tproxy_suffix) >= 0 ||
        index(netstat, "0:0:0:0:0:0:0:1" + tproxy_suffix) >= 0 ||
        index(netstat, ":::" + tproxy_port) >= 0;
    return dns_ok && tproxy4_ok && tproxy6_ok;
}

function netstat_fields(line) {
    line = line == null ? "" : "" + line;
    line = trim(line);
    return line == "" ? [] : split(line, /[ \t\r\n]+/);
}

function netstat_addr_port(addr) {
    addr = addr == null ? "" : "" + addr;
    let colon = rindex(addr, ":");
    return colon >= 0 ? substr(addr, colon + 1) : addr;
}

function netstat_addr_host(addr) {
    addr = addr == null ? "" : "" + addr;
    if (substr(addr, 0, 1) == "[") {
        let end = index(addr, "]");
        return end > 0 ? substr(addr, 1, end - 1) : addr;
    }
    let colon = rindex(addr, ":");
    return colon >= 0 ? substr(addr, 0, colon) : addr;
}

function netstat_addr_matches(addr, listen, port) {
    listen = listen == null ? "" : "" + listen;
    port = port == null ? "" : "" + port;
    if (netstat_addr_port(addr) != port)
        return false;

    let host = netstat_addr_host(addr);
    return host == listen || host == "0.0.0.0" || host == "::" || host == "*";
}

function listen_port_in_use(netstat, listen, port) {
    netstat = netstat == null ? "" : "" + netstat;
    for (let line in split(netstat, "\n")) {
        let fields = netstat_fields(line);
        if (length(fields) < 4 ||
            (index(fields[0], "tcp") != 0 && index(fields[0], "udp") != 0))
            continue;
        if (netstat_addr_matches(fields[3], listen, port))
            return true;
    }
    return false;
}

return { sing_box_standard_ports_listening, listen_port_in_use };
