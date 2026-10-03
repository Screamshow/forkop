// Keep only bounded, redacted error/health lines. Raw logs never enter the API.
let fs = require('fs');
let dir = getenv('FORKOP_SUPPORT_DIR') || '/var/run/forkop/support';
let key = trim(fs.readfile(dir + '/auth.key') || '');
let lines = [];
for (let name in ['daemon.log', 'auth.log']) {
    let file = fs.open(dir + '/' + name, 'r');
    if (!file) continue;
    let value = file.read(262144) || '';
    file.close();
    for (let line in split(value, '\n')) {
        if (!match(line, /error|failed|http [45][0-9][0-9]|x509|certificate|timeout|TryLogin|loggedIn|Running|Logged out/i)) continue;
        if (match(line, /AuthURL|https?:\/\/login\.tailscale\.com\//i)) continue;
        if (key != '') line = replace(line, key, '[redacted]');
        line = replace(line, /tskey-[A-Za-z0-9_-]+/g, '[redacted]');
        line = replace(line, /Bearer [A-Za-z0-9._-]+/gi, 'Bearer [redacted]');
        push(lines, substr(line, 0, 512));
    }
}
fs.writefile(dir + '/auth-detail.txt', substr(join('\n', slice(lines, -12)), 0, 4096));
