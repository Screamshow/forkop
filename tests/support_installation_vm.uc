let fs = require('fs');
let root = getenv('TEST_ROOT');
let source = fs.readfile(getenv('LIB') + '/session.uc');
source = replace(source, "const DIR = '/var/run/forkop/support';", "const DIR = '" + root + "/session';");
source = replace(source, "const LITE = '/usr/lib/forkop-support';", "const LITE = '" + root + "/lite';");
source = replace(source, '/proc/[0-9]*/cmdline', root + '/proc/[0-9]*/cmdline');
fs.writefile(root + '/session.uc', source);
let module = loadfile(root + '/session.uc')();
let status = module.status();
let system_installed = getenv('EXPECT_SYSTEM') == 'true';
let lite = getenv('EXPECT_LITE') == 'true';
if (status.system_installed != system_installed || status.lite_installed != lite ||
    status.installed != (system_installed || lite) || status.version != getenv('EXPECT_VERSION'))
    die('installation/version detection failed');
if (lite && status.lite_version != '1.98.3') die('wrong Lite version');
if (system_installed && getenv('EXPECT_VERSION') != '' && status.system_version != '1.82.5')
    die('wrong system version');
if (!lite && status.lite_version != '') die('stale Lite version');
if (!system_installed && status.system_version != '') die('stale system version');
if (status.active) die('status started a service');
fs.mkdir(root + '/proc');
fs.mkdir(root + '/proc/123');
for (let fixture in [
    {argv: ['/usr/sbin/tailscaled', '--state', '/etc/tailscale/state'], running: true},
    {argv: ['tailscaled', '--state', '/etc/tailscale/state'], running: true},
    {argv: ['/usr/lib/forkop-support/tailscaled', '--socket=' + root + '/session/socket'], running: false},
    {argv: ['/usr/bin/ucode', 'tailscaled'], running: false}
]) {
    fs.writefile(root + '/proc/123/cmdline', join(chr(0), fixture.argv) + chr(0));
    let current = module.status();
    if (current.primary_running != fixture.running) die('primary daemon detection failed');
    if (fixture.running && !lite && current.removable) die('running primary daemon removable');
}
