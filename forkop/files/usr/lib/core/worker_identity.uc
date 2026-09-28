let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe) return "";
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? as_string(data) : "";
}

function start_ticks(pid) {
    let stat = as_string(fs.readfile("/proc/" + pid + "/stat"));
    let marker = index(stat, ") ");
    if (marker < 0) return "";
    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    return length(fields) >= 20 && match(fields[19], /^[0-9]+$/) != null ? fields[19] : "";
}

function snapshot(pid, script, lib_dir) {
    pid = trim(as_string(pid));
    if (match(pid, /^[1-9][0-9]*$/) == null) return null;
    let before = start_ticks(pid);
    if (before == "") return null;
    let exe = trim(output("readlink " + shell_quote("/proc/" + pid + "/exe")));
    if (match(exe, /\/ucode( \(deleted\))?$/) == null) return null;
    let argv = split(as_string(fs.readfile("/proc/" + pid + "/cmdline")), "\0");
    if (length(argv) < 5 ||
        (argv[0] != "ucode" && match(argv[0], /\/ucode$/) == null) ||
        argv[1] != "-L" || argv[2] != lib_dir || argv[3] != script || argv[4] != "worker")
        return null;
    let after = start_ticks(pid);
    return after != "" && before == after ? { pid, ticks: after } : null;
}

function pid_record(path) {
    let data = as_string(fs.readfile(path));
    let fields = split(data, "\n");
    return { pid: trim(fields[0] || ""), ticks: trim(fields[1] || "") };
}

function record_started(path, script, lib_dir) {
    let pid = pid_record(path).pid;
    for (let attempt = 0; attempt < 10; attempt++) {
        let identity = snapshot(pid, script, lib_dir);
        if (identity != null)
            return fs.writefile(path, pid + "\n" + identity.ticks + "\n") != null;
        system("sleep 0.1");
    }
    return false;
}

function stop(path, script, lib_dir) {
    let record = pid_record(path);
    let first = snapshot(record.pid, script, lib_dir);
    let second = first != null ? snapshot(record.pid, script, lib_dir) : null;
    let owned = first != null && second != null && first.ticks == second.ticks &&
        (record.ticks == "" || record.ticks == second.ticks);
    if (owned)
        system("kill " + shell_quote(record.pid) + " >/dev/null 2>&1");
    else if (first != null)
        return false;
    try { fs.unlink(path); } catch (e) {}
    return true;
}

return { snapshot, record_started, stop };
