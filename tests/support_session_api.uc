// Exercise the API projection and request identity without changing procd/UCI.
let fs = require('fs');
let root = getenv('TEST_ROOT');
let source = fs.readfile(getenv('LIB') + '/session.uc');
source = replace(source, "const DIR = '/var/run/forkop/support';", "const DIR = '" + root + "/session';");
source = replace(source, "const LITE = '/usr/lib/forkop-support';", "const LITE = '" + root + "/lite';");
source = replace(source, "const SERVICE = '/etc/init.d/forkop-support';", "const SERVICE = '" + root + "/service';");
fs.writefile(root + '/session.uc', source);
let module = loadfile(root + '/session.uc')();
let requested = module.request({operation: 'start', auth_key: 'tskey-auth-synthetic-fixture-not-real', consent: 'full-router-access'});
if (!requested.active || requested.phase != 'starting' || !match(requested.session_id, /^[a-f0-9-]{36}$/)) die('start identity failed');
let deadline = json(fs.readfile(root + '/session/status.json')).deadline;
let id = requested.session_id;
for (let phase in ['connected', 'degraded', 'recovering']) {
    fs.writefile(root + '/session/status.json', sprintf('%J', {schema: 2, session_id: id, deadline, phase, recovery_attempts: 2}));
    let status = module.status();
    if (!status.active || status.phase != phase || status.session_id != id || status.recovery_attempts != 2) die('phase projection failed');
    if (phase != 'connected' && status.address != '') die('unhealthy address exposed');
    if (status.remaining_seconds > 1800 || status.remaining_seconds < 1790) die('deadline projection failed');
    if (phase != 'connected' && module.request({operation: 'announce', session_id: id}).announcement_granted) die('unhealthy announcement granted');
    if (phase == 'connected') {
        if (module.request({operation: 'announce', session_id: 'wrong-session'}).announcement_granted) die('wrong session announcement');
        if (!module.request({operation: 'announce', session_id: id}).announcement_granted) die('first announcement denied');
        if (module.request({operation: 'announce', session_id: id}).announcement_granted) die('duplicate announcement granted');
    }
}
let stopped = module.request({operation: 'stop'});
if (stopped.active || stopped.phase != 'stopped' || fs.stat(root + '/session/auth.key') != null) die('stop projection failed');
if (module.request({operation: 'announce', session_id: id}).announcement_granted) die('stopped announcement granted');
let second = module.request({operation: 'start', auth_key: 'tskey-auth-synthetic-fixture-not-real', consent: 'full-router-access'});
if (second.session_id == id) die('identity reused');
module.request({operation: 'stop'});
printf('API identity, phases, deadline and cancellation passed\n');
