// Manage only the temporary support line, preserving other authorized keys.
let fs = require('fs');
let path = getenv('FORKOP_SUPPORT_AUTHORIZED_KEYS') || '/etc/dropbear/authorized_keys';
let keypath = getenv('FORKOP_SUPPORT_PUBLIC_KEY') || '/usr/lib/forkop/support/operator.pub';
let info = fs.lstat(path);
if (info && info.type != 'file') die('Unsupported authorized_keys file type');
let before = fs.readfile(path) || '';
let after = replace(before, /\ncommand="\/usr\/lib\/forkop\/support\/ssh-gate.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 [A-Za-z0-9+\/=]+ forkop-support-temporary\n/g, '');
if (ARGV[0] == 'add') {
    let key = trim(fs.readfile(keypath) || '');
    let parts = match(key, /^ssh-ed25519 ([A-Za-z0-9+\/=]+)( [^\r\n]*)?$/);
    if (!parts) die('Invalid support public key');
    after += '\ncommand="/usr/lib/forkop/support/ssh-gate.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 ' + parts[1] + ' forkop-support-temporary\n';
} else if (ARGV[0] != 'remove') die('Invalid SSH key operation');
if (after != before) {
    if (after == '' && !fs.unlink(path)) die('Cannot remove temporary SSH authorization');
    if (after != '') {
        let file = fs.open(path + '.forkop-new', 'w', 0600);
        if (!file) die('Cannot write temporary SSH authorization');
        if (file.write(after) != length(after)) { file.close(); fs.unlink(path + '.forkop-new'); die('Cannot write temporary SSH authorization'); }
        file.close();
        fs.chmod(path + '.forkop-new', 0600);
        if ((fs.readfile(path) || '') != before || !fs.rename(path + '.forkop-new', path)) {
            fs.unlink(path + '.forkop-new'); die('SSH authorization changed concurrently');
        }
    }
}
