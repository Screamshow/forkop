// status --json exposes Health as English strings in upstream and Forkop Lite.
// Self.Online alone is not reliable evidence of a failed control connection.
let fs = require('fs');
let status;
try { status = json(fs.readfile(ARGV[0]) || ''); } catch (e) { exit(1); }
if (type(status) != 'object' || type(status.BackendState) != 'string') exit(1);
if (status.BackendState != 'Running') exit(1);
if (status.Health != null && type(status.Health) != 'array') exit(1);
for (let warning in status.Health || []) {
    if (type(warning) == 'string' && match(lc(warning), /coordination server|network map|control server|control plane/))
        exit(1);
}
exit(0);
