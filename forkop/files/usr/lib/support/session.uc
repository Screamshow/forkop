// Temporary support sessions. Credentials never enter argv, UCI or status output.
let fs = require('fs');
const DIR = '/var/run/forkop/support';
const SERVICE = '/etc/init.d/forkop-support';

function output(command) {
    let p = fs.popen('(' + command + ') 2>/dev/null', 'r');
    if (!p) return '';
    let value = p.read('all');
    return p.close() == 0 ? trim(value || '') : '';
}
function read_json(path) {
    try { return json(fs.readfile(path) || '{}'); } catch (e) { return {}; }
}
function uptime() { return int(split(fs.readfile('/proc/uptime') || '0', ' ')[0]); }
function available() {
    return output('command -v tailscale') != '' && output('command -v tailscaled') != '';
}
function packaged() {
    return system('(if command -v apk >/dev/null 2>&1; then apk info -e tailscale; else opkg status tailscale | grep -q "Status: install ok installed"; fi) >/dev/null 2>&1') == 0;
}
function primary_enabled() {
    return system('/etc/init.d/tailscale enabled >/dev/null 2>&1') == 0;
}
function primary_running() {
    for (let path in fs.glob('/proc/[0-9]*/cmdline')) {
        let args = replace(fs.readfile(path) || '', /\x00/g, ' ');
        if (match(args, /(^|\/)tailscaled /) && index(args, DIR + '/socket') == -1)
            return true;
    }
    return false;
}
function status() {
    let state = read_json(DIR + '/status.json');
    let running = output("ubus call service list '{\"name\":\"forkop-support\"}'");
    let active = false;
    try {
        let service = json(running)['forkop-support'];
        for (let name, instance in service?.instances || {})
            if (instance.running) active = true;
    } catch (e) {}
    let managed = packaged();
    let result = {
        installed: available(),
        package_installed: managed,
        removable: managed && !active && !primary_running() && !primary_enabled(),
        version: output('tailscale version | head -n 1'),
        primary_running: primary_running(),
        active,
        phase: active ? (state.phase || 'starting') : (state.phase == 'failed' ? 'failed' : 'stopped'),
        error: state.error || '',
        remaining_seconds: active ? max(0, int(state.deadline || 0) - uptime()) : 0,
        address: ''
    };
    if (active && result.phase == 'connected') {
        let address = output('tailscale --socket=' + DIR + '/socket ip -4');
        if (match(address, /^100\.[0-9]+\.[0-9]+\.[0-9]+$/)) result.address = address;
    }
    return result;
}
function request(data) {
    if (type(data) != 'object') die('Invalid request');
    if (data.operation == 'status') return status();
    if (data.operation == 'stop') {
        if (index(['installing', 'removing'], status().phase) != -1) die('Wait for the package operation to finish');
        system(SERVICE + ' stop >/dev/null 2>&1');
        fs.unlink(DIR + '/auth.key');
        fs.rmdir(DIR + '/lock');
        fs.writefile(DIR + '/status.json', '{"phase":"stopped"}');
        return status();
    }
    if (index(['start', 'install', 'remove'], data.operation) == -1) die('Invalid operation');
    if (fs.stat('/var/run/forkop/component-action.lock') != null ||
        fs.stat('/var/run/forkop/package-upgrade.quiesce') != null ||
        fs.stat('/tmp/forkop-full-uninstall.lock') != null)
        die('Wait for the current package operation to finish');
    if (status().active) die('A support operation is already running');
    if (data.operation == 'start') {
        if (!available()) die('Install Tailscale first');
        if (output('command -v dropbear') == '') die('Dropbear SSH is required');
        if (type(data.auth_key) != 'string' || !match(data.auth_key, /^tskey-auth-[A-Za-z0-9-]{20,200}$/))
            die('Invalid Tailscale auth key');
        if (data.consent != 'full-router-access') die('Explicit consent is required');
    } else if (data.operation == 'remove') {
        if (data.consent != 'remove-tailscale-package') die('Explicit removal consent is required');
        if (!packaged()) die('Tailscale is not managed by the package manager');
        if (primary_running() || primary_enabled()) die('Stop and disable the existing Tailscale service before removing it');
    } else if (available()) {
        return status();
    } else if (primary_running()) {
        die('An existing Tailscale process needs manual inspection');
    }
    fs.mkdir('/var/run/forkop');
    fs.mkdir(DIR, 0700);
    fs.chmod(DIR, 0700);
    if (!fs.mkdir(DIR + '/lock', 0700)) die('A support operation is already starting');
    try {
        fs.writefile(DIR + '/operation', data.operation);
        if (data.operation == 'start') {
            if (system(SERVICE + ' enable >/dev/null 2>&1') != 0) die('Cannot enable boot cleanup');
            let file = fs.open(DIR + '/auth.key', 'w', 0600);
            if (!file) die('Cannot create temporary credential');
            file.write(data.auth_key);
            file.close();
        }
        fs.writefile(DIR + '/status.json', sprintf('%J', {
            phase: data.operation == 'install' ? 'installing' : (data.operation == 'remove' ? 'removing' : 'starting'),
            deadline: uptime() + 1800
        }));
        if (system(SERVICE + ' start >/dev/null 2>&1') != 0) die('Cannot start support service');
    } catch (e) {
        fs.unlink(DIR + '/auth.key');
        fs.rmdir(DIR + '/lock');
        die('Cannot start support operation');
    }
    return status();
}
return { request, status };
