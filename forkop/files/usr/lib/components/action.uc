#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let netstat = require("core.netstat");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constants.FORKOP_CONFIG_NAME || "forkop";
const BIN_PATH = getenv("FORKOP_BIN") || constants.FORKOP_BIN || "/usr/bin/forkop";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || constants.FORKOP_SERVICE_INIT || "/etc/init.d/forkop";
const FORKOP_VERSION = getenv("FORKOP_VERSION") || constants.FORKOP_VERSION || "";
const FORKOP_RELEASE_REPO = getenv("FORKOP_RELEASE_REPO") || constants.FORKOP_RELEASE_REPO || "Screamshow/forkop";
const FORKOP_MIRROR_BASE_URL = getenv("FORKOP_MIRROR_BASE_URL") || constants.FORKOP_MIRROR_BASE_URL || "";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const MANAGED_UPGRADE_SING_BOX_MARKER = getenv("FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER") || "/tmp/forkop-managed-upgrade-sing-box";
const PACKAGE_UPGRADE_STATE = getenv("FORKOP_PACKAGE_UPGRADE_STATE") || "/tmp/forkop-package-was-running";
const PACKAGE_UPGRADE_QUIESCE_FILE = getenv("FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE") || RUNTIME_STATE_DIR + "/package-upgrade.quiesce";
const FORKOP_UPGRADE_IDLE_WAIT_SECONDS = int(getenv("FORKOP_UPGRADE_IDLE_WAIT_SECONDS") || "180");
const COMPRESSED_UPGRADE_BACKUP = "/tmp/forkop-compressed-upgrade";
const SYSTEM_INFO_CACHE_FILE = getenv("FORKOP_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const COMPONENT_LOCK_DIR = getenv("UPDATES_LOCK_DIR") || RUNTIME_STATE_DIR + "/component-action.lock";
const TMP_STALE_TTL_MINUTES = getenv("UPDATES_TMP_STALE_TTL_MINUTES") || "30";
const TMP_FILE_STALE_TTL_MINUTES = getenv("UPDATES_TMP_FILE_STALE_TTL_MINUTES") || "10";
const SB_MANAGED_SERVICE_MARKER = getenv("SB_MANAGED_SERVICE_MARKER") || constants.SB_MANAGED_SERVICE_MARKER || "Forkop managed sing-box service for binary variants";
const TORRSERVER_DIRECT_INIT = getenv("FORKOP_TORRSERVER_DIRECT_INIT") || "/etc/init.d/forkop-torrserver-direct";
const TORRSERVER_DIRECT_UC = LIB_DIR + "/torrserver/direct.uc";

let tmp_dir = "";
let lock_held = false;
let forkop_was_running = false;
let forkop_stopped_for_sing_box_change = false;
let last_logged_output = "";
let sing_box_target_dependency_files = [];
let sing_box_rollback_dependency_files = [];

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));
    return join(" ", parts);
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success(command) {
    return command_status("(" + command + ") >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value)) != null;
}

function read_file(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? "" : as_string(data);
}

function parse_json_object(value) {
    try {
        let parsed = json(as_string(value));
        return type(parsed) == "object" ? parsed : {};
    }
    catch (e) {
        return {};
    }
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", as_string(path) ]);
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && int(stat.size || 0) > 0;
}

function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
}

function now_seconds() {
    return int(clock()[0]);
}

function owner_pid() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function pid_running(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] " + as_string(message) ]);
}

function updates_log(message, level) {
    log_message("Updates: " + as_string(message), level || "info");
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_output(args) {
    return command_output(module_command(args));
}

function module_success(args) {
    return command_success(module_command(args));
}

function helper_output(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_output(command_args);
}

function helper_success(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

function cleanup_stale_tmp_files() {
    command_success_from_args([ "find", "/tmp", "-maxdepth", "1", "-type", "d", "-name", "forkop-updates.*", "-mmin", "+" + as_string(TMP_STALE_TTL_MINUTES), "-exec", "rm", "-rf", "{}", "+" ]);
    command_success_from_args([ "find", "/tmp", "-maxdepth", "1", "-type", "f", "(", "-name", "forkop-updates-command.*", "-o", "-name", "forkop-updates-http.*", ")", "-mmin", "+" + as_string(TMP_FILE_STALE_TTL_MINUTES), "-delete" ]);
}

function init_tmp_dir() {
    if (tmp_dir != "")
        return true;

    cleanup_stale_tmp_files();
    tmp_dir = trim(command_output_from_args([ "mktemp", "-d", "/tmp/forkop-updates.XXXXXX" ]));
    if (tmp_dir == "") {
        tmp_dir = "/tmp/forkop-updates." + owner_pid();
        if (!ensure_dir(tmp_dir)) {
            tmp_dir = "";
            return false;
        }
    }
    return true;
}

function make_tmp_file(prefix) {
    init_tmp_dir();
    let base = tmp_dir != "" ? tmp_dir + "/" + as_string(prefix) + ".XXXXXX" : "/tmp/forkop-updates-" + as_string(prefix) + ".XXXXXX";
    let path = trim(command_output_from_args([ "mktemp", base ]));
    if (path == "") {
        path = (tmp_dir != "" ? tmp_dir : "/tmp") + "/" + as_string(prefix) + "." + owner_pid() + "." + now_seconds();
        if (!write_file(path, ""))
            return "";
    }
    return path;
}

function helper_output_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return "";
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let output = command_output(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return output;
}

function helper_success_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return false;
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let ok = command_success(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return ok;
}

function cleanup_tmp_dir() {
    if (tmp_dir != "") {
        command_success_from_args([ "rm", "-rf", tmp_dir ]);
        tmp_dir = "";
    }
    cleanup_stale_tmp_files();
}

function acquire_component_lock() {
    ensure_dir(RUNTIME_STATE_DIR);
    if (command_success_from_args([ "mkdir", COMPONENT_LOCK_DIR ])) {
        write_file(COMPONENT_LOCK_DIR + "/pid", owner_pid() + "\n");
        lock_held = true;
        return true;
    }

    let current_owner = trim(read_file(COMPONENT_LOCK_DIR + "/pid"));
    if (current_owner != "" && pid_running(current_owner))
        return false;

    remove_file(COMPONENT_LOCK_DIR + "/pid");
    command_success_from_args([ "rmdir", COMPONENT_LOCK_DIR ]);
    if (!command_success_from_args([ "mkdir", COMPONENT_LOCK_DIR ]))
        return false;

    write_file(COMPONENT_LOCK_DIR + "/pid", owner_pid() + "\n");
    lock_held = true;
    return true;
}

function release_component_lock() {
    if (!lock_held)
        return;
    remove_file(COMPONENT_LOCK_DIR + "/pid");
    command_success_from_args([ "rmdir", COMPONENT_LOCK_DIR ]);
    lock_held = false;
}

function clear_owned_upgrade_quiesce() {
    module_success([ LIB_DIR + "/service/ui.uc", "clear-package-upgrade-quiesce-if-owner", owner_pid() ]);
}

function cleanup_action() {
    clear_owned_upgrade_quiesce();
    cleanup_tmp_dir();
    release_component_lock();
}

function updates_response(success, component, action, message, current_version, latest_version, changed, status, release_url) {
    write_json({
        success: !!success,
        kind: "component",
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: as_string(current_version),
        latest_version: as_string(latest_version),
        changed: int(changed || 0),
        status: as_string(status),
        release_url: as_string(release_url)
    });
}

function restart_forkop_after_failed_sing_box_change() {
    if (!forkop_stopped_for_sing_box_change || !forkop_was_running || !file_exists(SERVICE_INIT))
        return;
    updates_log("Restarting Forkop after failed sing-box component change");
    if (!command_success_from_args([ SERVICE_INIT, "start" ]))
        command_success_from_args([ SERVICE_INIT, "restart" ]);
}

function action_success(component, action, message, current_version, latest_version, changed, status, release_url) {
    updates_response(true, component, action, message, current_version, latest_version, changed || 0, status || "", release_url || "");
    cleanup_action();
    exit(0);
}

function action_fail(component, action, message, current_version, latest_version, status, release_url) {
    updates_log(message, "error");
    restart_forkop_after_failed_sing_box_change();
    updates_response(false, component, action, message, current_version || "", latest_version || "", 0, status || "", release_url || "");
    cleanup_action();
    exit(1);
}

function run_logged(description, command) {
    init_tmp_dir();
    let output_file = make_tmp_file("command");
    if (output_file == "")
        output_file = "/tmp/forkop-updates-command." + owner_pid();

    updates_log(description);
    let status = command_status(as_string(command) + " >" + shell_quote(output_file) + " 2>&1");
    last_logged_output = read_file(output_file);
    for (let line in split(last_logged_output, "\n"))
        if (trim(as_string(line)) != "")
            updates_log(line);
    remove_file(output_file);
    if (status != 0)
        updates_log(description + " failed with exit code " + status, "warn");
    return status == 0;
}

function is_apk() {
    return command_exists("apk");
}

function pkg_is_installed(package_name) {
    package_name = as_string(package_name);
    if (is_apk())
        return command_success_from_args([ "apk", "info", "-e", package_name ]);
    return module_success([ LIB_DIR + "/core/packages.uc", "opkg-installed", package_name ]);
}

function installed_package_version(package_name) {
    package_name = as_string(package_name);
    if (is_apk()) {
        if (!pkg_is_installed(package_name))
            return "";
        return trim(module_output([ LIB_DIR + "/core/packages.uc", "apk-version", package_name ]));
    }
    return trim(module_output([ LIB_DIR + "/core/packages.uc", "opkg-version", package_name ]));
}

function opkg_package_version_from_list(package_name, output) {
    return trim(helper_output_input(output, "updates-opkg-package-version", [ package_name ]));
}

function available_package_version(package_name) {
    package_name = as_string(package_name);
    if (is_apk())
        return trim(module_output([ LIB_DIR + "/core/packages.uc", "apk-available-version", package_name ]));
    return opkg_package_version_from_list(package_name, command_output_from_args([ "opkg", "list", package_name ]));
}

function pkg_list_update_command() {
    return is_apk() ? "apk update </dev/null" : "opkg update </dev/null";
}

function pkg_install_name_command(package_name) {
    return is_apk() ? command_from_args([ "apk", "add", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "install", package_name ]) + " </dev/null";
}

function pkg_install_name_downgrade(package_name, package_version) {
    package_name = as_string(package_name);
    if (is_apk()) {
        package_version = as_string(package_version);
        if (package_version == "")
            return false;
        let package_spec = package_name + "=" + package_version;
        if (pkg_is_installed(package_name))
            return command_success(command_from_args([ "apk", "add", "--force-reinstall", "--upgrade", package_spec ]) + " </dev/null");
        return command_success(command_from_args([ "apk", "add", package_spec ]) + " </dev/null");
    }

    return command_success(command_from_args([ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade", package_name ]) + " </dev/null") ||
        command_success(command_from_args([ "opkg", "install", "--force-downgrade", package_name ]) + " </dev/null");
}

function pkg_install_files_command(files) {
    let args = is_apk() ? [ "apk", "add", "--allow-untrusted" ] : [ "opkg", "install", "--force-overwrite", "--force-downgrade" ];
    for (let file in files)
        push(args, file);
    return command_from_args(args) + " </dev/null";
}

function pkg_install_sing_box_files_command(files) {
    if (!is_apk()) {
        let args = [ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade" ];
        for (let file in files)
            push(args, file);
        return command_from_args(args) + " </dev/null";
    }
    let args = [ "apk", "add", "--no-network", "--allow-untrusted" ];
    for (let file in files)
        push(args, file);
    return command_from_args(args) + " </dev/null";
}

// Keep the exact packages needed for both sides of a variant change in tmpfs.
// A binary alone is not a package-manager rollback.
function ipk_unpacked_bytes(path) {
    let archive = shell_quote(path);
    let command = "(tar -xzOf " + archive + " data.tar.gz 2>/dev/null || " +
        "tar -xzOf " + archive + " ./data.tar.gz 2>/dev/null) | " +
        "tar -tvzf - 2>/dev/null | awk '{ sum += $3 } END { printf \"%.0f\", sum }'";
    return int(trim(command_output(command)));
}

function staged_package_field(path, field) {
    let command = is_apk() ? command_from_args([ "apk", "--allow-untrusted", "adbdump", path ]) :
        "(tar -xzOf " + shell_quote(path) + " control.tar.gz 2>/dev/null || " +
        "tar -xzOf " + shell_quote(path) + " ./control.tar.gz 2>/dev/null) | tar -xzOf - ./control";
    let metadata = command_output(command);
    let key = (is_apk() ? field :
        field == "name" ? "Package" : field == "version" ? "Version" :
        field == "arch" ? "Architecture" : "Installed-Size") + ": ";
    for (let line in split(metadata, "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, length(key)) == key) {
            let value = trim(substr(line, length(key)));
            if (!is_apk() && field == "installed-size") {
                // IPK producers disagree on whether Installed-Size is bytes or KiB.
                // Measure the actual data archive and use the conservative maximum.
                let unpacked = ipk_unpacked_bytes(path);
                return unpacked > 0 ? sprintf("%d", int(value) > unpacked ? int(value) : unpacked) : "";
            }
            return value;
        }
    }
    return "";
}

function staged_package_info(path, expected_name, expected_version) {
    if (!file_nonempty(path))
        return null;
    let name = staged_package_field(path, "name");
    let version = staged_package_field(path, "version");
    let arch = staged_package_field(path, "arch");
    let size = int(staged_package_field(path, "installed-size"));
    if (name != expected_name || version == "" ||
        (as_string(expected_version) != "" && version != expected_version) ||
        arch == "" || size <= 0)
        return null;
    let supported = arch == "all" || arch == "noarch";
    if (is_apk()) {
        // apk has a compatibility table which is broader than --print-arch.
        // For example, an OpenWrt 25 aarch64 APK host accepts the
        // aarch64_cortex-a53 package produced for mediatek/filogic.  Comparing
        // these strings here rejects a valid archive before apk can resolve it.
        // Keep metadata validation above, and let apk validate architecture
        // during the local-file transaction.
        supported = true;
    }
    else {
        for (let line in split(command_output_from_args([ "opkg", "print-architecture" ]), "\n")) {
            let fields = split(trim(line), " ");
            if (length(fields) > 1 && fields[1] == arch)
                supported = true;
        }
    }
    return supported ? { path, name, version, size } : null;
}

function stage_repository_sing_box_package(package_name, expected_version) {
    let ext = is_apk() ? "apk" : "ipk";
    let command = is_apk() ?
        command_from_args([ "apk", "fetch", "-o", tmp_dir, package_name ]) :
        "cd " + shell_quote(tmp_dir) + " && " + command_from_args([ "opkg", "download", package_name ]);
    let downloaded = false;
    for (let attempt = 1; attempt <= 3; attempt++) {
        if (run_logged("Downloading " + package_name + " before changing sing-box (" + attempt + "/3)", command)) {
            downloaded = true;
            break;
        }
    }
    if (!downloaded)
        return null;
    let matches = command_output("find " + shell_quote(tmp_dir) + " -maxdepth 1 -type f -name " +
        shell_quote(is_apk() ? package_name + "-*." + ext : package_name + "_*." + ext));
    for (let path in split(matches, "\n")) {
        let info = staged_package_info(trim(path), package_name, expected_version);
        if (info != null)
            return info;
    }
    return null;
}

function apk_archive_dependencies(path) {
    let dependencies = [];
    let metadata = command_output_from_args([ "apk", "--allow-untrusted", "adbdump", path ]);
    let inside = false;
    for (let line in split(metadata, "\n")) {
        if (match(line, /^  [a-z][a-z-]*:/) != null)
            inside = match(line, /^  depends:/) != null;
        else if (inside && match(line, /^    - /) != null) {
            let name = trim(replace(substr(line, 6), /[<>=~].*$/, ""));
            if (name != "")
                push(dependencies, name);
        }
    }
    return dependencies;
}

function apk_packages_removed_with(package_name) {
    if (!is_apk() || as_string(package_name) == "" || !pkg_is_installed(package_name))
        return [];
    if (!run_logged("Checking packages removed with " + package_name,
        command_from_args([ "apk", "del", "--simulate", package_name ])))
        return null;
    let removed = [];
    for (let line in split(last_logged_output, "\n")) {
        let fields = split(trim(line), " ");
        if (length(fields) > 2 && fields[1] == "Purging")
            push(removed, fields[2]);
    }
    return removed;
}

function array_has(values, item) {
    for (let value in values)
        if (value == item)
            return true;
    return false;
}

function staged_package_by_name(values, name) {
    for (let item in values)
        if (item.name == name)
            return item;
    return null;
}

function stage_apk_dependency_tree(info, removed, staged) {
    if (length(staged) > 32)
        return false;
    for (let dependency in apk_archive_dependencies(info.path)) {
        if (!array_has(removed, dependency) && pkg_is_installed(dependency))
            continue;
        if (staged_package_by_name(staged, dependency) != null)
            continue;
        let expected = pkg_is_installed(dependency) ? installed_package_version(dependency) : "";
        let package = stage_repository_sing_box_package(dependency, expected);
        if (package == null)
            return false;
        push(staged, package);
        if (!stage_apk_dependency_tree(package, removed, staged))
            return false;
    }
    return true;
}

function prepare_sing_box_package_dependencies(target, rollback, previous_variant) {
    sing_box_target_dependency_files = [];
    sing_box_rollback_dependency_files = [];
    if (!is_apk())
        return true;
    let previous_package = previous_variant == "tiny" ? "sing-box-tiny" :
        previous_variant == "stable" ? "sing-box" :
        previous_variant == "extended" ? "sing-box-extended" : "";
    let removed = apk_packages_removed_with(previous_package);
    if (removed == null)
        return false;
    let target_dependencies = [];
    if (!stage_apk_dependency_tree(target, removed, target_dependencies))
        return false;
    for (let item in target_dependencies)
        push(sing_box_target_dependency_files, item.path);
    if (rollback != null) {
        let rollback_dependencies = [];
        if (!stage_apk_dependency_tree(rollback, removed, rollback_dependencies))
            return false;
        for (let item in rollback_dependencies)
            push(sing_box_rollback_dependency_files, item.path);
    }
    return true;
}

function sing_box_target_files(target_path) {
    let files = [];
    for (let path in sing_box_target_dependency_files)
        push(files, path);
    push(files, target_path);
    return files;
}

function sing_box_rollback_files(rollback_path) {
    let files = [];
    for (let path in sing_box_rollback_dependency_files)
        push(files, path);
    push(files, rollback_path);
    return files;
}

function available_kib(path) {
    let output = trim(command_output("df -Pk " + shell_quote(path) + " | tail -n 1 | awk '{print $4}'"));
    return int(output);
}

function file_bytes(path) {
    return int(trim(command_output("wc -c <" + shell_quote(path))));
}

function sing_box_space_error(overlay_kib, tmp_kib, target_bytes, previous_bytes, tmp_backup_bytes, recoverable_bytes) {
    let target_kib = int((target_bytes + 1023) / 1024);
    let previous_kib = int((previous_bytes + 1023) / 1024);
    let recoverable_kib = int(recoverable_bytes / 1024);
    if (recoverable_kib > target_kib)
        recoverable_kib = target_kib;
    // The old package is already reflected in df's available space. A
    // conflicting package is removed before installing the target, and a
    // failed target is removed before rollback. Budget for the larger step.
    let install_need = target_kib + int(target_kib / 4) + 8192 - recoverable_kib;
    let rollback_need = previous_kib > 0 ? previous_kib + int(previous_kib / 4) + 8192 - recoverable_kib : 0;
    let overlay_need = install_need > rollback_need ? install_need : rollback_need;
    let tmp_need = int((tmp_backup_bytes + 1023) / 1024) + 8192;
    if (overlay_kib <= 0 || tmp_kib <= 0 || target_kib <= 0)
        return "Cannot determine storage required for sing-box package change";
    if (overlay_kib < overlay_need)
        return "Not enough flash space for sing-box: need " + overlay_need + " KiB free, have " + overlay_kib + " KiB";
    if (tmp_kib < tmp_need)
        return "Not enough temporary memory for sing-box: need " + tmp_need + " KiB free, have " + tmp_kib + " KiB";
    return "";
}

function sing_box_reclaimable_bytes(previous_variant, target_variant, previous) {
    if (previous == null || previous_variant == target_variant)
        return 0;
    // Only a variant switch removes the old package before installation.
    // A firmware file cannot free overlay blocks; credit only 75% of a
    // verified writable binary to allow for filesystem overhead.
    let old_path = file_exists("/overlay/upper") ?
        "/overlay/upper/usr/bin/sing-box" : "/usr/bin/sing-box";
    return file_exists(old_path) ? int(file_bytes(old_path) * 3 / 4) : 0;
}

function opkg_sing_box_dependencies_to_install(target) {
    if (is_apk())
        return [];

    let simulation = command_from_args([
        "opkg", "--noaction", "--force-space", "install", "--force-overwrite", "--force-downgrade", target.path
    ]);
    if (!run_logged("Checking sing-box package dependencies", simulation)) {
        let pending = "";
        let missing = [];
        for (let line in split(last_logged_output, "\n")) {
            line = trim(line);
            if (match(line, /^[A-Za-z0-9][A-Za-z0-9._+-]*:$/) != null)
                pending = replace(line, /:$/, "");
            if (match(line, /masked in: --no-network/) != null && pending != "") {
                if (!array_has(missing, pending))
                    push(missing, pending);
                pending = "";
            }
        }
        return length(missing) > 0 ? missing : null;
    }

    let dependencies = [];
    for (let line in split(last_logged_output, "\n")) {
        let parsed = match(trim(line), /^Installing ([A-Za-z0-9][A-Za-z0-9._+-]*) \(/);
        if (parsed != null && parsed[1] != target.name && !array_has(dependencies, parsed[1]))
            push(dependencies, parsed[1]);
    }
    return dependencies;
}

function install_opkg_sing_box_dependencies(target) {
    let dependencies = opkg_sing_box_dependencies_to_install(target);
    if (dependencies == null)
        return false;
    for (let package_name in dependencies) {
        if (!run_logged("Installing required sing-box dependency " + package_name,
            pkg_install_name_command(package_name)))
            return false;
    }
    return true;
}

function sing_box_package_preflight(target, previous, tmp_backup_bytes) {
    if (target == null)
        return "Target package is unavailable, invalid, or incompatible with this architecture";
    // The APK solver cannot simulate a variant switch against the old world
    // constraint: --force-broken-world can silently discard the target. Check
    // archive dependencies instead and install exclusively from local files.
    let simulation = is_apk() ? "" :
        command_from_args([ "opkg", "--noaction", "--force-space", "install", "--force-overwrite", "--force-downgrade", target.path ]);
    if (simulation != "" && !run_logged("Checking sing-box package dependencies", simulation)) {
        let pending = "";
        let missing = [];
        for (let line in split(last_logged_output, "\n")) {
            line = trim(line);
            if (match(line, /^[A-Za-z0-9][A-Za-z0-9._+-]*:$/) != null)
                pending = replace(line, /:$/, "");
            if (match(line, /masked in: --no-network/) != null && pending != "") {
                push(missing, pending);
                pending = "";
            }
        }
        if (length(missing) > 0)
            return "Missing installed sing-box dependencies: " + join(", ", missing);
        return "Target package dependencies are incompatible; see package operation log";
    }

    let overlay_kib = available_kib("/usr/bin");
    let tmp_kib = available_kib(tmp_dir);
    let target_dependency_bytes = 0;
    let rollback_dependency_bytes = 0;
    for (let path in sing_box_target_dependency_files)
        target_dependency_bytes += int(staged_package_field(path, "installed-size"));
    for (let path in sing_box_rollback_dependency_files)
        rollback_dependency_bytes += int(staged_package_field(path, "installed-size"));
    let target_kib = int((target.size + target_dependency_bytes + 1023) / 1024);
    let previous_kib = previous == null ? 0 : int((previous.size + rollback_dependency_bytes + 1023) / 1024);
    let target_variant = target.name == "sing-box-extended" ? "extended" :
        target.name == "sing-box-tiny" ? "tiny" : "stable";
    let previous_variant = previous == null ? "" :
        previous.name == "sing-box-extended" ? "extended" :
        previous.name == "sing-box-tiny" ? "tiny" : "stable";
    let recoverable_bytes = sing_box_reclaimable_bytes(previous_variant, target_variant, previous);
    // Reserve 25% plus 8 MiB for extraction, metadata and filesystem
    // overhead. Check rollback separately rather than counting the old
    // package twice against already measured free space.
    let space_error = sing_box_space_error(overlay_kib, tmp_kib, target.size + target_dependency_bytes,
        previous == null ? 0 : previous.size + rollback_dependency_bytes, tmp_backup_bytes, recoverable_bytes);
    if (space_error != "")
        return space_error;
    let recoverable_kib = int(recoverable_bytes / 1024);
    if (recoverable_kib > target_kib)
        recoverable_kib = target_kib;
    let install_need = target_kib + int(target_kib / 4) + 8192 - recoverable_kib;
    let rollback_need = previous_kib > 0 ? previous_kib + int(previous_kib / 4) + 8192 - recoverable_kib : 0;
    let overlay_need = install_need > rollback_need ? install_need : rollback_need;
    let tmp_need = int((tmp_backup_bytes + 1023) / 1024) + 8192;
    updates_log("Sing-box preflight passed: flash " + overlay_kib + "/" + overlay_need +
        " KiB, tmp " + tmp_kib + "/" + tmp_need + " KiB, rollback installed size " + previous_kib +
        " KiB, writable binary credit " + recoverable_kib + " KiB");
    return "";
}

function pkg_install_files(files) {
    return command_success(pkg_install_files_command(files));
}

function pkg_remove_sing_box_conflict(package_name) {
    package_name = as_string(package_name);
    if (!pkg_is_installed(package_name))
        return true;
    if (is_apk())
        return command_success(command_from_args([ "apk", "del", package_name ]) + " </dev/null");
    return command_success(command_from_args([ "opkg", "remove", package_name ]) + " </dev/null");
}

function run_logged_pkg_remove_sing_box_conflict(package_name, description) {
    if (!pkg_is_installed(package_name)) {
        updates_log(description);
        return true;
    }

    let command = is_apk() ?
        command_from_args([ "apk", "del", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", package_name ]) + " </dev/null";
    return run_logged(description, command);
}

function compare_versions(lhs, rhs) {
    lhs = as_string(lhs);
    rhs = as_string(rhs);
    if (lhs == "" || rhs == "")
        return null;
    if (lhs == rhs)
        return 0;

    if (is_apk()) {
        let apk_result = trim(command_output_from_args([ "apk", "version", "-t", lhs, rhs ]));
        if (apk_result == ">")
            return 1;
        if (apk_result == "<")
            return -1;
        if (apk_result == "=")
            return 0;
    }

    if (command_exists("opkg")) {
        if (command_success_from_args([ "opkg", "compare-versions", lhs, ">", rhs ]))
            return 1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "<", rhs ]))
            return -1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "=", rhs ]))
            return 0;
    }

    return module_success([ LIB_DIR + "/core/helpers.uc", "version-at-least", lhs, rhs ]) ? 1 : -1;
}

function status_from_compare(compare_result) {
    if (compare_result == -1)
        return "outdated";
    if (compare_result == 0)
        return "latest";
    if (compare_result == 1)
        return "dev";
    return "";
}

function check_success_compared(component, current_version, latest_version, compare_current_version, compare_latest_version, release_url) {
    let compare_result = compare_versions(compare_current_version, compare_latest_version);
    if (compare_result == null)
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let status = status_from_compare(compare_result);
    if (status == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let result_row = trim(helper_output("updates-check-result-row", [ component, current_version, latest_version, status ]));
    if (result_row == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let fields = split(result_row, "\t");
    let message = as_string(fields[0] || "");
    let log_line = length(fields) > 1 ? as_string(fields[1]) : message;
    updates_log(log_line);
    action_success(component, "check_update", message, current_version, latest_version, 0, status, release_url || "");
}

function check_success(component, current_version, latest_version, release_url) {
    check_success_compared(component, current_version, latest_version, current_version, latest_version, release_url || "");
}

function read_openwrt_release_value(key) {
    return trim(helper_output("openwrt-release-value", [ "/etc/openwrt_release", key ]));
}

function service_proxy_address() {
    if (!file_exists(LIB_DIR + "/singbox/runtime.uc"))
        return "";
    if (file_exists(LIB_DIR + "/service/state.uc") &&
        !module_success([ LIB_DIR + "/service/state.uc", "sing-box-service-running" ]))
        return "";
    return trim(module_output([ LIB_DIR + "/singbox/runtime.uc", "service-proxy-address", "components" ]));
}

function http_get_once(url, output_path, proxy_address, timeout) {
    url = as_string(url);
    output_path = as_string(output_path);
    proxy_address = as_string(proxy_address);
    timeout = as_string(timeout || "30");

    if (command_exists("curl")) {
        let args = [ "curl", "--connect-timeout", "5", "-m", timeout, "-fsSL" ];
        if (proxy_address != "") {
            push(args, "-x");
            push(args, "http://" + proxy_address);
        }
        push(args, url);
        push(args, "-o");
        push(args, output_path);
        return command_success_from_args(args);
    }

    if (command_exists("wget")) {
        let command = command_from_args([ "wget", "-T", timeout, "-q", "-O", output_path, url ]);
        if (proxy_address != "")
            command = command_env({ http_proxy: "http://" + proxy_address, https_proxy: "http://" + proxy_address }) + " " + command;
        return command_success(command);
    }

    return false;
}

function http_get(url) {
    init_tmp_dir();
    let output_path = make_tmp_file("http");
    if (output_path == "")
        return "";

    let proxy_address = service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, "30")) {
            let data = read_file(output_path);
            remove_file(output_path);
            return data;
        }
        remove_file(output_path);
        updates_log("HTTP request via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }

    if (http_get_once(url, output_path, "", "30")) {
        let data = read_file(output_path);
        remove_file(output_path);
        return data;
    }

    remove_file(output_path);
    return "";
}

function download_file_once(url, output_path) {
    let proxy_address = service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, "120"))
            return true;
        remove_file(output_path);
        updates_log("Download via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }
    return http_get_once(url, output_path, "", "120");
}

function download_with_retry(url, output_path, label) {
    for (let attempt = 1; attempt <= 3; attempt++) {
        updates_log("Downloading " + as_string(label) + " (" + attempt + "/3)");
        if (download_file_once(url, output_path) && file_nonempty(output_path))
            return true;
        remove_file(output_path);
        updates_log("Retrying " + as_string(label), "warn");
    }
    return false;
}

function fetch_github_release_json(owner, repo) {
    let response = http_get("https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases/latest");
    if (response == "" || !helper_success_input(response, "github-response-ok", []))
        return "";
    return response;
}

function fetch_github_releases_json(owner, repo, per_page) {
    let response = http_get("https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases?per_page=" + as_string(per_page || "30"));
    if (response == "" || !helper_success_input(response, "github-response-ok", []))
        return "";
    return response;
}

function forkop_update_channel() {
    // A stable build may have inherited update_channel=canary while it was
    // upgraded from a canary release. Never let that stale setting make a
    // stable installation consume pre-release metadata.
    if (match(FORKOP_VERSION, /-canary[.][0-9]+$/) == null)
        return "stable";

    return "canary";
}

function latest_forkop_release_json() {
    if (FORKOP_MIRROR_BASE_URL != "") {
        let response = http_get(FORKOP_MIRROR_BASE_URL + "/forkop/updates/" + forkop_update_channel() + ".json");
        if (response == "")
            return "";
        return response;
    }

    let parts = split(FORKOP_RELEASE_REPO, "/");
    if (length(parts) != 2 || as_string(parts[0]) == "" || as_string(parts[1]) == "")
        return "";
    return fetch_github_release_json(parts[0], parts[1]);
}

function forkop_release_url(value) {
    value = as_string(value);
    if (FORKOP_MIRROR_BASE_URL != "" && substr(value, 0, 1) == "/")
        return FORKOP_MIRROR_BASE_URL + value;
    return value;
}

function forkop_release_page_url(version, fallback) {
    let parts = split(FORKOP_RELEASE_REPO, "/");
    version = as_string(version);
    if (length(parts) == 2 &&
        match(as_string(parts[0]), /^[A-Za-z0-9_.-]+$/) != null &&
        match(as_string(parts[1]), /^[A-Za-z0-9_.-]+$/) != null &&
        match(version, /^[0-9]+[.][0-9]+[.][0-9]+$/) != null)
        return "https://github.com/" + parts[0] + "/" + parts[1] + "/releases/tag/" + version;

    return forkop_release_url(fallback);
}

function latest_forkop_version() {
    let response = latest_forkop_release_json();
    if (response == "")
        return "";
    return trim(helper_output_input(response, "object-get-default", [ "tag_name", "" ]));
}

function fetch_forkop_latest_release_metadata() {
    let response = latest_forkop_release_json();
    if (response == "")
        return "";
    return trim(helper_output_input(response, "release-metadata-tsv", []));
}

function write_forkop_latest_version_cache(value, timestamp) {
    if (as_string(value) == "")
        return;
    write_file("/tmp/forkop.latest-version.cache", as_string(value) + "\n" + as_string(timestamp) + "\n");
}

function retry_resolve(description, fn) {
    for (let attempt = 1; attempt <= 3; attempt++) {
        if (fn())
            return true;
        updates_log(as_string(description) + " failed (" + attempt + "/3)", "warn");
        command_success_from_args([ "sleep", "2" ]);
    }
    return false;
}

function ensure_package_tool(tool_name, package_name, component, action) {
    if (command_exists(tool_name))
        return true;
    if (!run_logged("Updating package lists before installing " + as_string(package_name), pkg_list_update_command()))
        return false;
    return run_logged("Installing bootstrap package " + as_string(package_name), pkg_install_name_command(package_name));
}

function clear_version_caches() {
    remove_file("/tmp/forkop.latest-version.cache");
    remove_file(SYSTEM_INFO_CACHE_FILE);
    remove_file("/tmp/forkop/system-info.json");
}

function managed_sing_box_service_installed() {
    return file_exists("/etc/init.d/sing-box") && index(read_file("/etc/init.d/sing-box"), SB_MANAGED_SERVICE_MARKER) >= 0;
}

function managed_sing_box_service_text() {
    return "#!/bin/sh /etc/rc.common\n" +
        "# " + SB_MANAGED_SERVICE_MARKER + "\n\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"/usr/bin/sing-box\"\n\n" +
        "start_service() {\n" +
        "    config_load \"sing-box\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n\n" +
        "    config_get config_file \"main\" \"conffile\" \"/etc/sing-box/config.json\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"/usr/share/sing-box\"\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"unlimited\"\n" +
        "    procd_set_param limits nofile=\"1000000 1000000\"\n" +
        "    procd_set_param respawn\n" +
        "    procd_close_instance\n" +
        "}\n\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"sing-box\"\n" +
        "}\n";
}

function install_managed_sing_box_service_script() {
    let tmp = "/etc/init.d/sing-box.forkop." + owner_pid();
    if (!write_file(tmp, managed_sing_box_service_text()))
        return false;
    if (!command_success_from_args([ "chmod", "0755", tmp ])) {
        remove_file(tmp);
        return false;
    }
    return fs.rename(tmp, "/etc/init.d/sing-box");
}

function remove_managed_sing_box_service_script() {
    if (!managed_sing_box_service_installed())
        return true;
    command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
    command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    remove_file("/etc/init.d/sing-box");
    return true;
}

function disable_sing_box_service_config() {
    if (!uci_core.available())
        return true;
    if (!uci_core.exists("sing-box.main") && !uci_core.set_section("sing-box.main", "sing-box"))
        return false;
    if (!uci_core.set("sing-box.main.enabled", "0"))
        return false;
    return uci_core.commit("sing-box");
}

function prepare_sing_box_service_disabled() {
    disable_sing_box_service_config();
    if (file_exists("/etc/init.d/sing-box")) {
        command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
        command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    }
}

function prepare_sing_box_package_service_install() {
    prepare_sing_box_service_disabled();
    remove_managed_sing_box_service_script();
}

function forkop_status_running_with_timeout() {
    init_tmp_dir();
    let output_file = make_tmp_file("forkop-status");
    if (output_file == "")
        return false;

    let command = command_from_args([ BIN_PATH, "get_status" ]) + " >" + shell_quote(output_file) + " 2>/dev/null & pid=$!; " +
        "( sleep 6; kill $pid 2>/dev/null || true ) & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; wait $watcher 2>/dev/null || true; exit $rc";
    let ok = command_status("sh -c " + shell_quote(command)) == 0 &&
        match(read_file(output_file), /"running"[ \t]*:[ \t]*1/) != null;
    remove_file(output_file);
    return ok;
}

function forkop_starting() {
    if (!file_exists(LIB_DIR + "/service/ui.uc"))
        return false;
    return trim(module_output([ LIB_DIR + "/service/ui.uc", "active-service-action" ])) == "start";
}

function wait_for_service_action_idle() {
    let remaining = FORKOP_UPGRADE_IDLE_WAIT_SECONDS;
    while (remaining >= 0) {
        if (module_success([ LIB_DIR + "/service/ui.uc", "service-action-idle" ]))
            return true;
        if (remaining == 0)
            break;
        command_success_from_args([ "sleep", "1" ]);
        remaining--;
    }
    return false;
}

function wait_for_forkop_restore() {
    let timeout = 180;
    while (timeout >= 0) {
        let starting = forkop_starting();
        if (!starting && forkop_status_running_with_timeout())
            return true;
        // A package postinst may have detached its start worker from procd.
        // "starting" is an owned transition, not a reason to race it with a
        // second restart. Keep waiting for its explicit terminal state.
        if (!starting && !file_exists(PACKAGE_UPGRADE_STATE))
            return false;
        if (timeout <= 0)
            break;
        command_success_from_args([ "sleep", "1" ]);
        timeout--;
    }
    return false;
}

function capture_forkop_running_state() {
    forkop_was_running = file_exists(BIN_PATH) && forkop_status_running_with_timeout();
}

function capture_managed_upgrade_sing_box_marker() {
    let state_module = LIB_DIR + "/service/state.uc";
    if (!file_exists(state_module))
        return;
    if (module_success([ state_module, "write-managed-upgrade-sing-box-marker", MANAGED_UPGRADE_SING_BOX_MARKER ]))
        updates_log("Recorded managed sing-box provenance for package upgrade");
}

function restart_forkop_after_successful_change() {
    if (!file_exists(SERVICE_INIT))
        return;
    if (!forkop_was_running) {
        updates_log("Forkop was not running before component change; restart skipped");
        prepare_sing_box_service_disabled();
        return;
    }
    run_logged("Restarting Forkop after successful component change", command_from_args([ SERVICE_INIT, "restart" ]));
}

function stop_forkop_before_sing_box_change() {
    if (forkop_stopped_for_sing_box_change)
        return;
    forkop_stopped_for_sing_box_change = true;

    if (forkop_was_running && file_exists(SERVICE_INIT))
        run_logged("Stopping Forkop before sing-box package change", command_from_args([ SERVICE_INIT, "stop" ]));

    if (forkop_was_running && file_exists(BIN_PATH))
        command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);

    prepare_sing_box_service_disabled();
}

function wait_forkop_running_after_sing_box_change() {
    if (!forkop_was_running)
        return true;
    if (!file_exists(BIN_PATH))
        return false;

    let waited = 0;
    while (waited < 180) {
        if (forkop_status_running_with_timeout()) {
            command_success_from_args([ "sleep", "8" ]);
            if (forkop_status_running_with_timeout())
                return true;
        }
        command_success_from_args([ "sleep", "4" ]);
        waited += 4;
    }
    return false;
}

function opkg_arch_list() {
    return trim(helper_output_input(command_output_from_args([ "opkg", "print-architecture" ]), "updates-opkg-arch-list", []));
}

function resolve_arch_candidates() {
    let arch_list = "";
    if (is_apk()) {
        if (file_exists("/etc/apk/arch"))
            arch_list += " " + trim(helper_output("file-whitespace-list", [ "/etc/apk/arch" ]));
        arch_list += " " + trim(command_output_from_args([ "apk", "--print-arch" ]));
    }
    else {
        arch_list = opkg_arch_list();
    }

    let release_arch = read_openwrt_release_value("DISTRIB_ARCH");
    if (release_arch != "")
        arch_list += " " + release_arch;
    if (!helper_success("string-has-whitespace-field", [ arch_list ]))
        arch_list = trim(command_output_from_args([ "uname", "-m" ]));

    let resolved = trim(helper_output("updates-arch-candidates", [ arch_list ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 2 || as_string(fields[0]) == "" || as_string(fields[1]) == "")
        return null;

    updates_log("Detected package architecture candidates: " + fields[1]);
    return {
        target: as_string(fields[0]),
        candidates: as_string(fields[1])
    };
}

function select_inner_package_path(bundle_file, component, arch, ext) {
    return trim(helper_output_input(command_output_from_args([ "unzip", "-l", bundle_file ]), "updates-zip-inner-package-path", [ component, arch, ext ]));
}

function select_archive_member_path(archive_file, member_name) {
    return trim(helper_output_input(command_output_from_args([ "tar", "-tzf", archive_file ]), "updates-archive-member-path", [ member_name ]));
}

function extract_arch_package_version(package_name, package_arch) {
    return trim(helper_output("updates-arch-package-version", [ package_name, package_arch ]));
}

function extract_zapret_bundle_version(bundle_name) {
    return trim(helper_output("updates-zapret-bundle-version", [ bundle_name ]));
}

function extract_zapret2_bundle_version(bundle_name) {
    return trim(helper_output("updates-zapret2-bundle-version", [ bundle_name ]));
}

function normalize_zapret_version(value) {
    return trim(helper_output("updates-normalize-zapret-version", [ value ]));
}

function normalize_sing_box_version(value) {
    return trim(helper_output("updates-normalize-sing-box-version", [ value ]));
}

function resolve_zapret_release(arch) {
    let release_json = fetch_github_release_json("remittor", "zapret-openwrt");
    if (release_json == "")
        return null;
    let resolved = trim(helper_output_input(release_json, "release-select-arch-suffix-asset", [ "zip", arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    let version = extract_zapret_bundle_version(fields[1]);
    if (version == "")
        version = trim(helper_output("string-remove-suffix", [ fields[1], ".zip" ]));
    return {
        arch: fields[0],
        bundle_name: fields[1],
        bundle_url: fields[2],
        release_url: fields[3],
        version
    };
}

function resolve_zapret2_release(arch) {
    let releases_json = fetch_github_releases_json("remittor", "zapret-openwrt", "30");
    if (releases_json == "")
        return null;
    let resolved = trim(helper_output_input(releases_json, "named-release-select-asset", [ "zapret2 ", "zapret2", "zip", arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    let version = extract_zapret2_bundle_version(fields[1]);
    if (version == "")
        version = trim(helper_output("string-remove-suffix", [ fields[1], ".zip" ]));
    return {
        arch: fields[0],
        bundle_name: fields[1],
        bundle_url: fields[2],
        release_url: fields[3],
        version
    };
}

function download_and_extract_zip_package(release, component) {
    let bundle_file = tmp_dir + "/" + release.bundle_name;
    if (!download_with_retry(release.bundle_url, bundle_file, release.bundle_name))
        return null;

    let inner_package_path = is_apk() ?
        select_inner_package_path(bundle_file, component, "", "apk") :
        select_inner_package_path(bundle_file, component, release.arch, "ipk");
    if (inner_package_path == "")
        return null;

    let package_name = path_basename(inner_package_path);
    let package_file = tmp_dir + "/" + package_name;
    if (!command_success(command_from_args([ "unzip", "-p", bundle_file, inner_package_path ]) + " >" + shell_quote(package_file)) ||
        !file_nonempty(package_file))
        return null;

    let version = as_string(release.version || "");
    if (version == "")
        version = component == "zapret2" ? extract_zapret2_bundle_version(release.bundle_name) : extract_zapret_bundle_version(release.bundle_name);
    if (version == "")
        version = extract_arch_package_version(package_name, release.arch);

    return {
        name: package_name,
        file: package_file,
        version
    };
}

function resolve_byedpi_release(arch) {
    let asset_ext = is_apk() ? "apk" : "ipk";
    let release_series = trim(helper_output("openwrt-release-series", [ "/etc/openwrt_release" ]));
    let releases_json = fetch_github_releases_json("DPITrickster", "ByeDPI-OpenWrt", "30");
    if (releases_json == "")
        return null;
    let resolved = trim(helper_output_input(releases_json, "byedpi-select-asset", [ release_series, asset_ext, arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    return {
        arch: fields[0],
        package_name: fields[1],
        package_url: fields[2],
        release_url: fields[3],
        version: extract_arch_package_version(fields[1], fields[0])
    };
}

function download_byedpi_package(release) {
    let package_file = tmp_dir + "/" + release.package_name;
    if (!download_with_retry(release.package_url, package_file, release.package_name) || !file_nonempty(package_file))
        return null;
    let version = as_string(release.version || "");
    if (version == "")
        version = extract_arch_package_version(release.package_name, release.arch);
    return {
        name: release.package_name,
        file: package_file,
        version
    };
}

function disable_standalone_service(name) {
    let init = "/etc/init.d/" + as_string(name);
    if (!file_exists(init))
        return;
    run_logged("Stopping standalone " + as_string(name) + " service", command_from_args([ init, "stop" ]));
    run_logged("Disabling standalone " + as_string(name) + " autostart", command_from_args([ init, "disable" ]));
}

function provider_installed(runtime_module) {
    return module_success([ runtime_module, "installed" ]);
}

function provider_package_version(runtime_module) {
    return trim(module_output([ runtime_module, "package-version" ]));
}

function install_zapret_like(component, action, runtime_module, resolve_fn, label) {
    init_tmp_dir() || action_fail(component, action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail(component, action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving " + label + " package", function() {
        release = resolve_fn(arch);
        return release != null;
    });
    if (release == null)
        action_fail(component, action, "Failed to resolve " + label + " package for this router architecture");

    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_fail(component, action, label + " is not installed", current_version, release.version, "", release.release_url || "");
        check_success_compared(component, current_version, release.version, normalize_zapret_version(current_version), normalize_zapret_version(release.version), release.release_url || "");
    }

    if (!ensure_package_tool("unzip", "unzip", component, action))
        action_fail(component, action, "Failed to install unzip");
    let pkg = download_and_extract_zip_package(release, component);
    if (pkg == null)
        action_fail(component, action, "Failed to download " + label + " package", current_version, release.version, "", release.release_url || "");

    if (!run_logged("Installing " + label + " package " + pkg.name, pkg_install_files_command([ pkg.file ])))
        action_fail(component, action, "Failed to install " + label + " package", current_version, pkg.version, "", release.release_url || "");

    disable_standalone_service(component);
    restart_forkop_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = "unknown";
    action_success(component, action, label + " package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_zapret(action) {
    install_zapret_like("zapret", action, LIB_DIR + "/providers/zapret/runtime.uc", resolve_zapret_release, "zapret");
}

function install_zapret2(action) {
    install_zapret_like("zapret2", action, LIB_DIR + "/providers/zapret2/runtime.uc", resolve_zapret2_release, "zapret2");
}

function install_byedpi(action) {
    init_tmp_dir() || action_fail("byedpi", action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail("byedpi", action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving ByeDPI package", function() {
        release = resolve_byedpi_release(arch);
        return release != null;
    });
    if (release == null)
        action_fail("byedpi", action, "Failed to resolve ByeDPI package for this router architecture");

    let runtime_module = LIB_DIR + "/providers/byedpi/runtime.uc";
    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_fail("byedpi", action, "ByeDPI is not installed", current_version, release.version);
        check_success("byedpi", current_version, release.version, release.release_url || "");
    }

    let pkg = download_byedpi_package(release);
    if (pkg == null)
        action_fail("byedpi", action, "Failed to download ByeDPI package");
    if (!run_logged("Installing ByeDPI package " + pkg.name, pkg_install_files_command([ pkg.file ])))
        action_fail("byedpi", action, "Failed to install ByeDPI package", current_version, pkg.version);

    disable_standalone_service("byedpi");
    restart_forkop_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = "unknown";
    action_success("byedpi", action, "ByeDPI package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_zapret_manager(action) {
    let component = "zapret_manager";
    let manager_url = FORKOP_MIRROR_BASE_URL + "/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh";
    let manager_file = tmp_dir + "/Zapret-Manager.sh";
    let current_version = file_exists("/usr/bin/zms") ? "installed" : "not installed";

    if (FORKOP_MIRROR_BASE_URL == "")
        action_fail(component, action, "Forkop mirror URL is not configured", current_version);
    if (!download_with_retry(manager_url, manager_file, "Zapret-Manager"))
        action_fail(component, action, "Failed to download Zapret-Manager from the mirror", current_version);

    let source = read_file(manager_file);
    let matched = match(source, /ZAPRET_MANAGER_VERSION="([^"]+)"/);
    let latest_version = matched != null ? as_string(matched[1]) : "mirror";
    let wrapper = "#!/bin/sh\nexec sh <(wget -q -O - " + shell_quote(manager_url) + ") \"$@\"\n";
    let auto_wrapper = "#!/bin/sh\nexec sh <(wget -q -O - " + shell_quote(manager_url) + ") \"$@\"\n";

    if (!write_file("/usr/bin/zms", wrapper) || !write_file("/usr/bin/zmsA", auto_wrapper) ||
        !command_success_from_args([ "chmod", "0755", "/usr/bin/zms", "/usr/bin/zmsA" ]))
        action_fail(component, action, "Failed to install Zapret-Manager launchers", current_version, latest_version);

    clear_version_caches();
    action_success(component, action, "Zapret-Manager has been installed from the Forkop mirror", current_version,
        latest_version, 1, "latest", manager_url);
}

function remove_zapret_manager(action) {
    let component = "zapret_manager";
    let managed_marker = "/zapret-manager/proxy/";
    let paths = [ "/usr/bin/zms", "/usr/bin/zmsA" ];
    let removed = 0;

    for (let path in paths) {
        if (!file_exists(path))
            continue;
        if (index(read_file(path), managed_marker) < 0)
            action_fail(component, action, "Existing " + path + " was not created by Forkop X and was not removed");
        remove_file(path);
        if (file_exists(path))
            action_fail(component, action, "Failed to remove " + path);
        removed++;
    }

    clear_version_caches();
    action_success(component, action, removed > 0 ?
        "Zapret-Manager launchers have been removed" :
        "Zapret-Manager launchers are already removed", "installed", "", 1);
}

function remove_optional_component(component, package_name, label, runtime_module) {
    if (!pkg_is_installed(package_name)) {
        if (provider_installed(runtime_module))
            action_fail(component, "remove", label + " exists outside the package manager and was not removed automatically");
        action_success(component, "remove", label + " is already removed", "", "", 0);
    }

    let current_version = provider_package_version(runtime_module);
    let command = is_apk() ?
        command_from_args([ "apk", "del", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null";
    if (!run_logged("Removing " + label + " package", command))
        action_fail(component, "remove", "Failed to remove " + label + " package", current_version);

    clear_version_caches();
    if (provider_installed(runtime_module))
        action_fail(component, "remove", label + " package was removed, but provider files are still present", current_version);
    restart_forkop_after_successful_change();
    action_success(component, "remove", label + " package has been removed", current_version, "", 1);
}

function read_sing_box_binary_version(binary, library_dir) {
    binary = as_string(binary);
    if (binary == "" || !file_exists(binary))
        return "";

    let command = command_from_args([ binary, "version" ]);
    if (as_string(library_dir || "") != "")
        command = command_env({ LD_LIBRARY_PATH: as_string(library_dir) }) + " " + command;

    return trim(helper_output_input(command_output(command), "stdin-first-line-last-field", []));
}

function validate_sing_box_extended_binary(binary, library_dir) {
    let version = read_sing_box_binary_version(binary, library_dir || "");
    return index(version, "extended") >= 0 ? version : "";
}

function move_file_portable(source_path, target_path) {
    if (fs.rename(source_path, target_path))
        return true;

    let staged_path = as_string(target_path) + ".forkop-move." + owner_pid();
    remove_file(staged_path);
    if (!command_success_from_args([ "cp", "-p", source_path, staged_path ]) ||
        !fs.rename(staged_path, target_path)) {
        remove_file(staged_path);
        return false;
    }
    remove_file(source_path);
    return true;
}

function install_staged_file(source_path, target_path, mode) {
    let staged_path = as_string(target_path) + ".forkop-new." + owner_pid();
    remove_file(staged_path);
    if (!command_success_from_args([ "cp", "-f", source_path, staged_path ]) ||
        !command_success_from_args([ "chmod", mode, staged_path ]) ||
        !fs.rename(staged_path, target_path)) {
        remove_file(staged_path);
        return false;
    }
    remove_file(source_path);
    return true;
}

function move_file_to_backup(target_path, backup_path) {
    if (!file_exists(target_path))
        return true;
    remove_file(backup_path);
    return move_file_portable(target_path, backup_path);
}

function restore_sing_box_backup(backup_binary) {
    if (as_string(backup_binary) != "" && file_nonempty(backup_binary)) {
        if (!move_file_portable(backup_binary, "/usr/bin/sing-box"))
            return false;
        return command_success_from_args([ "chmod", "0755", "/usr/bin/sing-box" ]);
    }
    remove_file("/usr/bin/sing-box");
    return true;
}

function restore_file_backup(target_path, backup_path) {
    if (as_string(backup_path) != "" && file_nonempty(backup_path))
        return move_file_portable(backup_path, target_path);
    remove_file(target_path);
    return true;
}

function restore_sing_box_service_from_marker(marker) {
    if (as_string(marker) == "extended-compressed")
        return install_managed_sing_box_service_script();
    if (sing_box_variant_is_package_managed(as_string(marker)) && is_apk() &&
        file_exists("/etc/init.d/sing-box.apk-new") &&
        (managed_sing_box_service_installed() || !file_exists("/etc/init.d/sing-box"))) {
        remove_managed_sing_box_service_script();
        if (!move_file_portable("/etc/init.d/sing-box.apk-new", "/etc/init.d/sing-box"))
            return false;
        return command_success_from_args([ "chmod", "0755", "/etc/init.d/sing-box" ]);
    }
    if (!file_exists("/etc/init.d/sing-box") && file_nonempty("/usr/bin/sing-box"))
        return install_managed_sing_box_service_script();
    remove_managed_sing_box_service_script();
    return true;
}

function resolve_sing_box_extended_arch_suffix() {
    let host_arch = trim(command_output_from_args([ "uname", "-m" ]));
    let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
    return trim(helper_output("sing-box-extended-arch-suffix", [ host_arch, distrib_arch ]));
}

function sing_box_extended_tag_is_stable(tag) {
    tag = lc(as_string(tag));
    return tag != "" && index(tag, "alpha") < 0 && index(tag, "beta") < 0 && index(tag, "rc") < 0;
}

function set_sing_box_extended_release_from_json(release_json, compressed) {
    if (as_string(release_json) == "")
        return null;
    let tag = trim(helper_output_input(release_json, "object-get-default", [ "tag_name", "" ]));
    if (!sing_box_extended_tag_is_stable(tag))
        return null;

    let asset_url = "";
    if (compressed) {
        let arch_suffix = resolve_sing_box_extended_arch_suffix();
        if (arch_suffix == "")
            return null;
        asset_url = trim(helper_output_input(release_json, "sing-box-extended-asset-url", [ arch_suffix, "0", "1" ]));
    }
    else {
        let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
        if (distrib_arch == "")
            return null;
        let asset_ext = is_apk() ? "apk" : "ipk";
        asset_url = trim(helper_output_input(release_json, "sing-box-extended-package-asset-url", [ distrib_arch, asset_ext ]));
    }

    if (asset_url == "")
        return null;

    return {
        tag,
        release_url: forkop_release_url(trim(helper_output_input(release_json, "object-get-default", [ "html_url", "" ]))),
        asset_url: forkop_release_url(asset_url),
        asset_name: path_basename(asset_url)
    };
}

function resolve_sing_box_extended_release(compressed) {
    if (FORKOP_MIRROR_BASE_URL == "")
        return null;
    let release_json = http_get(FORKOP_MIRROR_BASE_URL + "/forkop/sing-box-extended/latest.json");
    return set_sing_box_extended_release_from_json(release_json, compressed);
}

function stage_previous_sing_box_package(variant) {
    let package_name = variant == "tiny" ? "sing-box-tiny" : variant == "stable" ? "sing-box" :
        variant == "extended" ? "sing-box-extended" : "";
    if (package_name == "")
        return null;
    let version = installed_package_version(package_name);
    if (version == "")
        return null;
    if (variant != "extended")
        return stage_repository_sing_box_package(package_name, version);
    let release = resolve_sing_box_extended_release(false);
    if (release == null)
        return null;
    let path = tmp_dir + "/rollback-" + release.asset_name;
    if (!download_with_retry(release.asset_url, path, "previous sing-box-extended package"))
        return null;
    return staged_package_info(path, package_name, version);
}

function sing_box_runtime_output(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return trim(module_output(command_args));
}

function sing_box_runtime_success(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

function write_sing_box_variant_state(marker, version) {
    if (!sing_box_runtime_success("write-variant-marker", [ marker ]))
        updates_log("Failed to write sing-box variant marker", "warn");
    if (!sing_box_runtime_success("write-version-state", [ version ]))
        updates_log("Failed to write sing-box version state", "warn");
}

function restore_sing_box_variant_state(previous_marker, previous_version_state) {
    sing_box_runtime_success("restore-variant-marker", [ previous_marker ]);
    sing_box_runtime_success("restore-version-state", [ previous_version_state ]);
}

function restore_sing_box_extended_package_variant() {
    init_tmp_dir();
    let release = resolve_sing_box_extended_release(false);
    if (release == null)
        return false;
    let package_file = tmp_dir + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, package_file, release.asset_name))
        return false;
    prepare_sing_box_package_service_install();
    pkg_remove_sing_box_conflict("sing-box-tiny");
    pkg_remove_sing_box_conflict("sing-box");
    if (!pkg_install_files([ package_file ])) {
        remove_file(package_file);
        return false;
    }
    remove_file(package_file);
    let new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "")
        return false;
    write_sing_box_variant_state("extended", new_version);
    return true;
}

function replace_sing_box_package_variant(target_package, conflict_package, target_version) {
    prepare_sing_box_package_service_install();
    if ((as_string(conflict_package) == "" || !pkg_is_installed(conflict_package)) &&
        (target_package == "sing-box-extended" || !pkg_is_installed("sing-box-extended")))
        return pkg_install_name_downgrade(target_package, target_version);

    if (target_package != "sing-box-extended" && !pkg_remove_sing_box_conflict("sing-box-extended"))
        return false;
    if (as_string(conflict_package) != "" && !pkg_remove_sing_box_conflict(conflict_package))
        return false;
    return pkg_install_name_downgrade(target_package, target_version);
}

function restore_sing_box_package_variant(previous_variant) {
    if (previous_variant == "tiny")
        return replace_sing_box_package_variant("sing-box-tiny", "sing-box", available_package_version("sing-box-tiny"));
    if (previous_variant == "stable")
        return replace_sing_box_package_variant("sing-box", "sing-box-tiny", available_package_version("sing-box"));
    if (previous_variant == "extended")
        return restore_sing_box_extended_package_variant();
    if (previous_variant == "not-installed") {
        pkg_remove_sing_box_conflict("sing-box-extended");
        pkg_remove_sing_box_conflict("sing-box-tiny");
        pkg_remove_sing_box_conflict("sing-box");
        remove_managed_sing_box_service_script();
        remove_file("/usr/bin/sing-box");
        return true;
    }
    return false;
}

function sing_box_variant_is_package_managed(variant) {
    return variant == "stable" || variant == "tiny" || variant == "extended";
}

function restore_sing_box_install_backup(previous_variant, backup_binary, rollback_file) {
    if (sing_box_variant_is_package_managed(previous_variant)) {
        // The legacy compressed-archive action does not use this package
        // transaction; preserve its existing rollback behavior.
        if (rollback_file == null)
            return restore_sing_box_package_variant(previous_variant) ||
                (as_string(backup_binary) != "" && restore_sing_box_backup(backup_binary));
        let package_name = previous_variant == "tiny" ? "sing-box-tiny" :
            previous_variant == "stable" ? "sing-box" : "sing-box-extended";
        let previous_version = as_string(rollback_file) != "" ? staged_package_field(rollback_file, "version") : "";
        if (previous_version != "" && installed_package_version(package_name) == previous_version &&
            read_sing_box_binary_version("/usr/bin/sing-box", previous_variant == "extended" ? "/usr/lib" : "") != "")
            return true;
        remove_file("/usr/bin/sing-box");
        if (as_string(rollback_file) != "" && file_nonempty(rollback_file) &&
            previous_version != "" &&
            run_logged("Restoring previous sing-box package from local archive",
                pkg_install_sing_box_files_command(sing_box_rollback_files(rollback_file))) &&
            installed_package_version(package_name) == previous_version &&
            read_sing_box_binary_version("/usr/bin/sing-box", "") != "")
            return true;
        updates_log("Previous sing-box package could not be restored; package state may be inconsistent", "error");
        return false;
    }

    if (as_string(backup_binary) != "")
        return restore_sing_box_backup(backup_binary);
    return restore_sing_box_package_variant(previous_variant);
}

function restore_sing_box_after_failed_extended_install(previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched, rollback_file) {
    if (as_string(archive_file) != "")
        remove_file(archive_file);
    let restore_status = true;
    if (cronet_touched)
        restore_file_backup("/usr/lib/libcronet.so", backup_cronet);
    if (!restore_sing_box_install_backup(previous_variant, backup_binary, rollback_file))
        restore_status = false;
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    restore_sing_box_service_from_marker(previous_marker);
    clear_version_caches();
    if (restore_status)
        restart_forkop_after_successful_change();
    return restore_status;
}

function restore_sing_box_after_failed_extended_package_install(previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched, rollback_file) {
    if (as_string(package_file) != "" && package_file != rollback_file)
        remove_file(package_file);
    pkg_remove_sing_box_conflict("sing-box-extended");
    let restore_status = restore_sing_box_install_backup(previous_variant, backup_binary, rollback_file);
    if (cronet_touched) {
        restore_file_backup("/usr/lib/libcronet.so", backup_cronet);
        if (file_nonempty("/usr/lib/libcronet.so"))
            command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]);
    }
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    if (!restore_sing_box_service_from_marker(previous_marker))
        restore_status = false;
    clear_version_caches();
    return restore_status;
}

function restore_sing_box_after_failed_package_install(target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file) {
    pkg_remove_sing_box_conflict(target_package);
    let restore_status = restore_sing_box_install_backup(previous_variant, backup_binary, rollback_file);
    if (cronet_touched) {
        if (!restore_file_backup("/usr/lib/libcronet.so", backup_cronet))
            restore_status = false;
        if (file_nonempty("/usr/lib/libcronet.so") && !command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]))
            restore_status = false;
    }
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    if (!restore_sing_box_service_from_marker(previous_marker))
        restore_status = false;
    if (restore_status) {
        remove_file(backup_binary);
        remove_file(backup_cronet);
    }
    clear_version_caches();
    return restore_status;
}

function fail_package_sing_box_install(action, tiny, reason, current_version, latest_version,
    target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file) {
    let restored = restore_sing_box_after_failed_package_install(
        target_package,
        previous_variant,
        backup_binary,
        backup_cronet,
        previous_marker,
        previous_version_state,
        cronet_touched,
        rollback_file
    );

    let prefix = tiny ? "sing-box-tiny" : "Stable sing-box";
    if (restored)
        action_fail("sing_box", action, prefix + " " + reason + "; previous sing-box variant was restored", current_version, latest_version);
    action_fail("sing_box", action, prefix + " " + reason + " and previous sing-box variant could not be restored", current_version, latest_version);
}

function install_sing_box_extended_package(action) {
    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory");
    let current_version = sing_box_runtime_output("version", []);
    let current_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    let release = resolve_sing_box_extended_release(false);
    if (release == null)
        action_fail("sing_box", action, "Failed to resolve sing-box-extended package release", current_version);
    let latest_version = normalize_sing_box_version(release.tag);

    if (action == "check_update") {
        if (!sing_box_runtime_success("is-extended", [ current_version ]))
            action_fail("sing_box", action, "sing-box-extended is not installed", current_version, latest_version);
        check_success("sing_box", normalize_sing_box_version(current_version), normalize_sing_box_version(latest_version), release.release_url);
    }
    if (action == "install" && current_variant == "extended" &&
        normalize_sing_box_version(current_version) == normalize_sing_box_version(latest_version))
        action_success("sing_box", action, "Installed sing-box-extended package is already up to date",
            current_version, latest_version, 0, "latest", release.release_url);

    let package_file = tmp_dir + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, package_file, release.asset_name))
        action_fail("sing_box", action, "Failed to download sing-box-extended package", current_version, latest_version);

    let target = staged_package_info(package_file, "sing-box-extended", "");
    if (target == null)
        action_fail("sing_box", action, "Downloaded sing-box-extended package has invalid metadata or architecture", current_version, latest_version);

    if (!run_logged("Updating package lists before sing-box-extended package installation", pkg_list_update_command()))
        action_fail("sing_box", action, "Failed to update package lists", current_version, latest_version);

    if (!install_opkg_sing_box_dependencies(target))
        action_fail("sing_box", action, "Failed to install required sing-box dependencies; Tiny was not removed", current_version, latest_version);

    let rollback = sing_box_variant_is_package_managed(current_variant) ?
        (current_variant == "extended" && installed_package_version("sing-box-extended") == target.version ?
            target : stage_previous_sing_box_package(current_variant)) : null;
    if (sing_box_variant_is_package_managed(current_variant) && rollback == null)
        action_fail("sing_box", action, "Cannot cache the exact previous sing-box package for offline rollback", current_version, latest_version);
    let rollback_file = rollback == null ? "" : rollback.path;
    if (!prepare_sing_box_package_dependencies(target, rollback, current_variant))
        action_fail("sing_box", action, "Cannot cache all required sing-box dependencies for offline installation and rollback", current_version, latest_version);
    let tmp_backup_bytes = current_variant == "extended-compressed" ?
        file_bytes("/usr/bin/sing-box") + file_bytes("/usr/lib/libcronet.so") : 0;
    let preflight_error = sing_box_package_preflight(target, rollback, tmp_backup_bytes);
    if (preflight_error != "")
        action_fail("sing_box", action, preflight_error, current_version, latest_version);

    stop_forkop_before_sing_box_change();
    prepare_sing_box_package_service_install();

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (current_variant == "extended-compressed") {
        if (file_exists("/usr/bin/sing-box")) {
            backup_binary = tmp_dir + "/sing-box.forkop-backup";
            if (!move_file_to_backup("/usr/bin/sing-box", backup_binary))
                action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
        }
        if (file_exists("/usr/lib/libcronet.so")) {
            cronet_touched = true;
            backup_cronet = tmp_dir + "/libcronet.so.forkop-backup";
            if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
                let restored = restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched, rollback_file);
                action_fail("sing_box", action, "Failed to backup current libcronet.so; previous variant " + (restored ? "was restored" : "could not be restored"), current_version, latest_version);
            }
        }
    }

    if (!run_logged_pkg_remove_sing_box_conflict("sing-box-tiny", "Removing sing-box-tiny before sing-box-extended package installation")) {
        let restored = restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched, rollback_file);
        action_fail("sing_box", action, "Failed to remove sing-box-tiny; previous variant " + (restored ? "was restored" : "could not be restored"), current_version, latest_version);
    }
    if (!run_logged_pkg_remove_sing_box_conflict("sing-box", "Removing sing-box before sing-box-extended package installation")) {
        let restored = restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched, rollback_file);
        action_fail("sing_box", action, "Failed to remove sing-box; previous variant " + (restored ? "was restored" : "could not be restored"), current_version, latest_version);
    }

    if (!run_logged("Installing sing-box-extended package " + release.asset_name,
        pkg_install_sing_box_files_command(sing_box_target_files(package_file)))) {
        let restored = restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched, rollback_file);
        action_fail("sing_box", action, "Failed to install sing-box-extended package; previous variant " + (restored ? "was restored" : "could not be restored"), current_version, latest_version);
    }
    if (package_file != rollback_file)
        remove_file(package_file);

    let new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "") {
        if (restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched, rollback_file))
            action_fail("sing_box", action, "Installed sing-box-extended package failed validation; previous sing-box variant was restored", current_version, latest_version);
        action_fail("sing_box", action, "Installed sing-box-extended package failed validation and previous sing-box variant could not be restored", current_version, latest_version);
    }

    write_sing_box_variant_state("extended", new_version);
    restart_forkop_after_successful_change();
    if (!wait_forkop_running_after_sing_box_change()) {
        updates_log("sing-box-extended package did not start cleanly; restoring previous sing-box variant", "error");
        if (file_exists(SERVICE_INIT))
            command_success_from_args([ SERVICE_INIT, "stop" ]);
        if (restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched, rollback_file)) {
            remove_file(backup_binary);
            remove_file(backup_cronet);
            action_fail("sing_box", action, "sing-box-extended package was installed but Forkop did not start cleanly; previous sing-box variant was restored", current_version, latest_version);
        }
        action_fail("sing_box", action, "sing-box-extended package was installed but Forkop did not start cleanly and previous sing-box variant could not be restored", current_version, latest_version);
    }

    remove_file(backup_binary);
    remove_file(backup_cronet);
    remove_file(package_file);
    clear_version_caches();
    updates_log("Installed sing-box-extended " + (new_version != "" ? new_version : "unknown") + " from package");
    action_success("sing_box", action, "sing-box-extended has been installed", new_version, latest_version, new_version == current_version ? 0 : 1, "latest", release.release_url);
}

function install_sing_box_extended(action, compressed) {
    if (!compressed) {
        install_sing_box_extended_package(action);
        return;
    }

    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory");
    let label = "sing-box-extended compressed";
    let current_version = sing_box_runtime_output("version", []);
    let current_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    let release = resolve_sing_box_extended_release(true);
    if (release == null)
        action_fail("sing_box", action, "Failed to resolve " + label + " release", current_version);
    let latest_version = normalize_sing_box_version(release.tag);

    if (action == "check_update") {
        if (!sing_box_runtime_success("is-extended", [ current_version ]))
            action_fail("sing_box", action, "sing-box-extended is not installed", current_version, latest_version);
        if (!sing_box_runtime_success("marker-is", [ "extended-compressed" ]))
            action_fail("sing_box", action, "sing-box-extended compressed is not installed", current_version, latest_version);
        check_success("sing_box", normalize_sing_box_version(current_version), normalize_sing_box_version(latest_version), release.release_url);
    }

    let archive_file = tmp_dir + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, archive_file, release.asset_name))
        action_fail("sing_box", action, "Failed to download " + label, current_version, latest_version);

    let binary_path = select_archive_member_path(archive_file, "sing-box");
    if (binary_path == "") {
        remove_file(archive_file);
        action_fail("sing_box", action, "sing-box binary was not found in the downloaded archive", current_version, latest_version);
    }
    let cronet_path = select_archive_member_path(archive_file, "libcronet.so");
    let extract_error = tmp_dir + "/sing-box-extract.err";
    let tmp_binary = tmp_dir + "/sing-box.compressed." + owner_pid();
    let tmp_cronet = "";
    if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", binary_path ]) + " >" + shell_quote(tmp_binary) + " 2>" + shell_quote(extract_error)) ||
        !file_nonempty(tmp_binary) ||
        !command_success_from_args([ "chmod", "0755", tmp_binary ])) {
        for (let line in split(read_file(extract_error), "\n"))
            if (trim(as_string(line)) != "")
                updates_log(line);
        remove_file(tmp_binary);
        remove_file(archive_file);
        action_fail("sing_box", action, "Failed to extract " + label, current_version, latest_version);
    }

    if (cronet_path != "") {
        tmp_cronet = tmp_dir + "/libcronet.so";
        if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", cronet_path ]) + " >" + shell_quote(tmp_cronet) + " 2>" + shell_quote(extract_error)) ||
            !file_nonempty(tmp_cronet) ||
            !command_success_from_args([ "chmod", "0644", tmp_cronet ])) {
            for (let line in split(read_file(extract_error), "\n"))
                if (trim(as_string(line)) != "")
                    updates_log(line);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to extract libcronet.so from sing-box-extended archive", current_version, latest_version);
        }
    }

    // A package switch removes the old binary before writing the new one.
    // Count only a conservative share of a verified writable-layer file.
    let reclaim_bytes = current_variant != "not-installed" ?
        sing_box_reclaimable_bytes(current_variant, "extended-compressed", {}) : 0;
    let overlay_free_kib = available_kib("/usr/bin");
    let overlay_need_kib = int((file_bytes(tmp_binary) + file_bytes(tmp_cronet) + 1023) / 1024) +
        8192 - int(reclaim_bytes / 1024);
    if (overlay_free_kib <= 0 || overlay_free_kib < overlay_need_kib) {
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        remove_file(archive_file);
        action_fail("sing_box", action, "Not enough flash space for " + label + ": need " + overlay_need_kib + " KiB free, have " + overlay_free_kib + " KiB", current_version, latest_version);
    }

    remove_file(archive_file);
    let package_variant = sing_box_variant_is_package_managed(current_variant);
    let rollback = package_variant ? stage_previous_sing_box_package(current_variant) : null;
    if (package_variant && rollback == null)
        action_fail("sing_box", action, "Cannot cache the installed sing-box package for rollback", current_version, latest_version);
    let rollback_file = rollback == null ? null : rollback.path;
    stop_forkop_before_sing_box_change();
    let new_version = validate_sing_box_extended_binary(tmp_binary, tmp_dir);
    if (new_version == "") {
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Downloaded " + label + " failed validation", current_version, latest_version);
    }

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (!package_variant && file_exists("/usr/bin/sing-box")) {
        backup_binary = tmp_dir + "/sing-box.forkop-backup";
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary)) {
            remove_file(backup_binary);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
        }
    }
    if (cronet_path != "") {
        cronet_touched = true;
        if (file_exists("/usr/lib/libcronet.so")) {
            backup_cronet = "/usr/lib/libcronet.so.forkop-backup." + owner_pid();
            if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
                restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched, rollback_file);
                remove_file(tmp_binary);
                remove_file(tmp_cronet);
                action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
            }
        }
    }

    for (let item in [
        [ "sing-box-extended", "Removing sing-box-extended package before " + label + " installation" ],
        [ "sing-box-tiny", "Removing sing-box-tiny package before " + label + " installation" ],
        [ "sing-box", "Removing sing-box package before " + label + " installation" ]
    ]) {
        if (!run_logged_pkg_remove_sing_box_conflict(item[0], item[1])) {
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched, rollback_file);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            action_fail("sing_box", action, "Failed to remove " + item[0] + " before " + label + " installation", current_version, latest_version);
        }
    }

    // Verify the real free blocks after package removal or the compressed
    // binary's move to tmpfs, before copying the new binary to overlay.
    let overlay_after_remove_kib = available_kib("/usr/bin");
    let full_overlay_need_kib = int((file_bytes(tmp_binary) + file_bytes(tmp_cronet) + 1023) / 1024) + 8192;
    if (overlay_after_remove_kib < full_overlay_need_kib) {
        let restored = restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet,
            previous_marker, previous_version_state, archive_file, cronet_touched, rollback_file);
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Not enough flash space after removing the previous package: need " +
            full_overlay_need_kib + " KiB free, have " + overlay_after_remove_kib + " KiB" +
            (restored ? "" : "; previous variant could not be restored"), current_version, latest_version);
    }

    remove_managed_sing_box_service_script();
    if (!install_managed_sing_box_service_script()) {
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched, rollback_file);
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Failed to install managed sing-box service for " + label, current_version, latest_version);
    }

    remove_file("/usr/bin/sing-box");
    if (!install_staged_file(tmp_binary, "/usr/bin/sing-box", "0755")) {
        remove_file("/usr/bin/sing-box");
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched, rollback_file);
        action_fail("sing_box", action, "Failed to install " + label + " binary", current_version, latest_version);
    }
    if (tmp_cronet != "") {
        remove_file("/usr/lib/libcronet.so");
        if (!install_staged_file(tmp_cronet, "/usr/lib/libcronet.so", "0644")) {
            remove_file("/usr/lib/libcronet.so");
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched, rollback_file);
            action_fail("sing_box", action, "Failed to install libcronet.so for " + label, current_version, latest_version);
        }
    }
    remove_file(archive_file);

    new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "") {
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched, rollback_file))
            action_fail("sing_box", action, "Installed " + label + " failed validation; previous sing-box variant was restored", current_version, latest_version);
        action_fail("sing_box", action, "Installed " + label + " failed validation and previous sing-box variant could not be restored", current_version, latest_version);
    }

    write_sing_box_variant_state("extended-compressed", new_version);
    restart_forkop_after_successful_change();
    if (!wait_forkop_running_after_sing_box_change()) {
        updates_log(label + " did not start cleanly; restoring previous sing-box binary", "error");
        if (file_exists(SERVICE_INIT))
            command_success_from_args([ SERVICE_INIT, "stop" ]);
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched, rollback_file)) {
            remove_file(backup_binary);
            remove_file(backup_cronet);
            action_fail("sing_box", action, label + " was installed but Forkop did not start cleanly; previous sing-box variant was restored", current_version, latest_version);
        }
        action_fail("sing_box", action, label + " was installed but Forkop did not start cleanly and previous sing-box variant could not be restored", current_version, latest_version);
    }

    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    updates_log("Installed " + label + " " + (new_version != "" ? new_version : "unknown"));
    action_success("sing_box", action, label + " has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

function install_package_sing_box(action, tiny) {
    let package_name = tiny ? "sing-box-tiny" : "sing-box";
    let conflict = tiny ? "sing-box" : "sing-box-tiny";
    let label = tiny ? "tiny sing-box" : "stable sing-box";
    let package_version = installed_package_version(package_name);
    let binary_version = sing_box_runtime_output("version", []);
    let current_version = package_version;
    if (sing_box_runtime_success("is-extended", [ binary_version ]))
        current_version = binary_version;
    if (current_version == "")
        current_version = binary_version;
    let latest_version = available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);

    if (action == "check_update") {
        if (latest_version == "")
            action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);
        if (tiny && !sing_box_runtime_success("is-tiny", [ binary_version ]))
            action_fail("sing_box", action, "sing-box-tiny is not installed", current_version, latest_version);
        check_success("sing_box", current_version, latest_version, "");
    }

    if (!run_logged("Updating package lists before " + package_name + " installation", pkg_list_update_command()))
        action_fail("sing_box", action, "Failed to update package lists", current_version, latest_version);
    latest_version = available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);
    if (latest_version == "")
        action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);

    let previous_variant = sing_box_runtime_output("variant", []);
    if (action == "install" && previous_variant == (tiny ? "tiny" : "stable") &&
        current_version == latest_version)
        action_success("sing_box", action, "Installed sing-box package is already up to date",
            current_version, latest_version, 0, "latest");

    let target = stage_repository_sing_box_package(package_name, latest_version);
    if (target == null)
        action_fail("sing_box", action, "Cannot download or validate the selected sing-box package", current_version, latest_version);
    let rollback = sing_box_variant_is_package_managed(previous_variant) ?
        (previous_variant == (tiny ? "tiny" : "stable") &&
            installed_package_version(package_name) == target.version ? target :
            stage_previous_sing_box_package(previous_variant)) : null;
    if (sing_box_variant_is_package_managed(previous_variant) && rollback == null)
        action_fail("sing_box", action, "Cannot cache the exact previous sing-box package for offline rollback", current_version, latest_version);
    let rollback_file = rollback == null ? "" : rollback.path;
    if (!prepare_sing_box_package_dependencies(target, rollback, previous_variant))
        action_fail("sing_box", action, "Cannot cache all required sing-box dependencies for offline installation and rollback", current_version, latest_version);
    let tmp_backup_bytes = previous_variant == "extended-compressed" ?
        file_bytes("/usr/bin/sing-box") + file_bytes("/usr/lib/libcronet.so") : 0;
    let preflight_error = sing_box_package_preflight(target, rollback, tmp_backup_bytes);
    if (preflight_error != "")
        action_fail("sing_box", action, preflight_error, current_version, latest_version);

    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    stop_forkop_before_sing_box_change();

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    let backup_on_tmpfs = previous_variant == "extended-compressed";
    if (backup_on_tmpfs && file_exists("/usr/bin/sing-box")) {
        backup_binary = backup_on_tmpfs ? tmp_dir + "/sing-box.forkop-backup" :
            "/usr/bin/sing-box.forkop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary))
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
    }
    if (backup_on_tmpfs && file_exists("/usr/lib/libcronet.so")) {
        cronet_touched = true;
        backup_cronet = backup_on_tmpfs ? tmp_dir + "/libcronet.so.forkop-backup" :
            "/usr/lib/libcronet.so.forkop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
            restore_sing_box_backup(backup_binary);
            action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
        }
    }

    prepare_sing_box_package_service_install();
    if (!run_logged_pkg_remove_sing_box_conflict("sing-box-extended", "Removing sing-box-extended before " + label + " installation") ||
        !run_logged_pkg_remove_sing_box_conflict(conflict, "Removing conflicting sing-box package") ||
        !run_logged("Installing " + label + " package",
            pkg_install_sing_box_files_command(sing_box_target_files(target.path))))
        fail_package_sing_box_install(action, tiny, "package installation failed", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);

    let new_version = read_sing_box_binary_version("/usr/bin/sing-box", "");
    if (new_version == "")
        fail_package_sing_box_install(action, tiny, "package was installed, but sing-box binary is not available", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);
    if (sing_box_runtime_success("is-extended", [ new_version ]))
        fail_package_sing_box_install(action, tiny, "package was installed, but the active binary is still sing-box-extended", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);
    write_sing_box_variant_state(tiny ? "tiny" : "stable", new_version);
    restart_forkop_after_successful_change();
    if (!wait_forkop_running_after_sing_box_change())
        fail_package_sing_box_install(action, tiny, "was installed, but Forkop did not start cleanly", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);
    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    action_success("sing_box", action, label + " has been installed", new_version, latest_version,
        normalize_sing_box_version(new_version) == normalize_sing_box_version(current_version) ? 0 : 1, "latest");
}

function check_forkop() {
    let metadata = fetch_forkop_latest_release_metadata();
    let fields = split(metadata, "\t");
    let latest_version = length(fields) > 0 && as_string(fields[0]) != "" ? as_string(fields[0]) : "unknown";
    let release_url = forkop_release_page_url(latest_version,
        length(fields) > 1 ? as_string(fields[1]) : "");
    if (latest_version == "unknown")
        action_fail("forkop", "check_update", "Failed to check Forkop updates", FORKOP_VERSION, latest_version);

    write_forkop_latest_version_cache(latest_version, now_seconds());
    if (!helper_success("forkop-release-version-valid", [ FORKOP_VERSION ])) {
        updates_log("Forkop current version is not a release version (" + FORKOP_VERSION + ")");
        action_success("forkop", "check_update", "Installed version is newer than release", FORKOP_VERSION, latest_version, 0, "dev", release_url);
    }

    let compare = trim(helper_output("forkop-release-version-compare", [ FORKOP_VERSION, latest_version ]));
    if (compare == "")
        action_fail("forkop", "check_update", "Failed to compare Forkop versions", FORKOP_VERSION, latest_version);
    let status = status_from_compare(int(compare));
    if (status == "")
        action_fail("forkop", "check_update", "Failed to compare Forkop versions", FORKOP_VERSION, latest_version);
    if (status == "latest") {
        updates_log("Forkop is already up to date (" + FORKOP_VERSION + ")");
        action_success("forkop", "check_update", "Latest version is installed", FORKOP_VERSION, latest_version, 0, status, release_url);
    }
    if (status == "outdated") {
        updates_log("Forkop update found: " + FORKOP_VERSION + " -> " + latest_version);
        action_success("forkop", "check_update", "Update is available", FORKOP_VERSION, latest_version, 0, status, release_url);
    }
    updates_log("Forkop installed version is newer than upstream release: " + FORKOP_VERSION + " -> " + latest_version);
    action_success("forkop", "check_update", "Installed version is newer than release", FORKOP_VERSION, latest_version, 0, status, release_url);
}

function parse_forkop_release_plan(plan, latest_version, i18n_required) {
    // The final two TSV fields are intentionally empty when i18n is absent.
    plan = replace(as_string(plan), /[\r\n]+$/, "");
    let fields = split(plan, "\t");
    if (length(fields) < 7 || as_string(fields[1]) == "" || as_string(fields[2]) == "" || as_string(fields[3]) == "" || as_string(fields[4]) == "")
        return null;
    if (i18n_required == "1" && (as_string(fields[5]) == "" || as_string(fields[6]) == ""))
        return null;
    return {
        release_url: forkop_release_page_url(latest_version, fields[0]),
        backend_name: fields[1],
        backend_url: forkop_release_url(fields[2]),
        app_name: fields[3],
        app_url: forkop_release_url(fields[4]),
        i18n_name: fields[5],
        i18n_url: forkop_release_url(fields[6])
    };
}

function resolve_forkop_release(latest_version) {
    let release_json = latest_forkop_release_json();
    if (release_json == "")
        return null;
    let asset_ext = is_apk() ? "apk" : "ipk";
    let i18n_required = pkg_is_installed("luci-i18n-forkop-ru") ? "1" : "0";
    let plan = helper_output_input(release_json, "forkop-release-plan", [ latest_version, asset_ext, i18n_required ]);
    return parse_forkop_release_plan(plan, latest_version, i18n_required);
}

function upgrade_sing_box_ticks(pid) {
    let stat = read_file("/proc/" + pid + "/stat");
    let marker = index(stat, ") ");
    if (marker < 0)
        return null;
    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    return length(fields) >= 20 && match(fields[19], /^[0-9]+$/) != null ? fields[19] : null;
}

function upgrade_sing_box_processes() {
    let processes = {};
    for (let exe in fs.glob("/proc/[0-9]*/exe")) {
        let path = trim(command_output_from_args([ "readlink", exe ]));
        let name = replace(path, /^.*\//, "");
        if (name != "sing-box" && name != "sing-box (deleted)")
            continue;
        let pid = split(exe, "/")[2];
        let ticks = upgrade_sing_box_ticks(pid);
        if (ticks == null)
            return null;
        processes[pid] = ticks;
    }
    return processes;
}

function upgrade_sing_box_count(processes) {
    let count = 0;
    for (let _ in processes)
        count++;
    return count;
}

function upgrade_procd_owns_all(processes) {
    let data = command_output_from_args([ "ubus", "call", "service", "list" ]);
    let service;
    try { service = json(data)["sing-box"]; } catch (e) { return false; }
    let instances = service && type(service.instances) == "object" ? service.instances : {};
    for (let pid, ticks in processes) {
        let owned = false;
        for (let _, instance in instances) {
            if (type(instance) != "object")
                continue;
            let command = instance.command;
            if (instance.running === true && as_string(instance.pid) == pid &&
                type(command) == "array" && length(command) >= 4 &&
                command[0] == "/usr/bin/sing-box" && command[1] == "run" &&
                command[2] == "-c" && command[3] == "/etc/sing-box/config.json" &&
                upgrade_sing_box_ticks(pid) == ticks)
                owned = true;
        }
        if (!owned)
            return false;
    }
    return true;
}

function upgrade_bounded_stop(script) {
    let seconds = int(getenv("FORKOP_UPGRADE_STOP_TIMEOUT_SECONDS") || "60");
    if (seconds < 1)
        seconds = 60;
    let command = command_from_args([ script, "stop" ]) + " >/dev/null 2>&1 & pid=$!; " +
        "( sleep " + seconds + "; kill $pid 2>/dev/null || true ) & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; " +
        "wait $watcher 2>/dev/null || true; exit $rc";
    return command_status("sh -c " + shell_quote(command)) == 0;
}

function stop_old_sing_box_before_forkop_upgrade() {
    if (file_exists(SERVICE_INIT))
        upgrade_bounded_stop(SERVICE_INIT);

    let processes = upgrade_sing_box_processes();
    if (processes == null)
        return false;
    if (upgrade_sing_box_count(processes) == 0)
        return true;
    if (!upgrade_procd_owns_all(processes))
        return false;

    let confirmed = upgrade_sing_box_processes();
    if (confirmed == null || upgrade_sing_box_count(confirmed) != upgrade_sing_box_count(processes))
        return false;
    for (let pid, ticks in processes)
        if (confirmed[pid] != ticks)
            return false;
    if (!upgrade_procd_owns_all(confirmed) || !file_exists("/etc/init.d/sing-box"))
        return false;

    upgrade_bounded_stop("/etc/init.d/sing-box");
    let quiet = 0;
    for (let attempt = 0; attempt < 17; attempt++) {
        let remaining = upgrade_sing_box_processes();
        if (remaining == null)
            return false;
        quiet = upgrade_sing_box_count(remaining) == 0 ? quiet + 1 : 0;
        if (quiet >= 2)
            return true;
        command_success_from_args([ "sleep", "1" ]);
    }
    return false;
}

function install_forkop() {
    let latest_version = latest_forkop_version();
    if (latest_version == "")
        latest_version = "unknown";
    if (latest_version == "unknown")
        action_fail("forkop", "install", "Failed to resolve Forkop release", FORKOP_VERSION, latest_version);

    write_forkop_latest_version_cache(latest_version, now_seconds());
    init_tmp_dir() || action_fail("forkop", "install", "Failed to create temporary directory", FORKOP_VERSION, latest_version);
    updates_log("Resolving Forkop release " + latest_version + " packages");
    let release = resolve_forkop_release(latest_version);
    if (release == null)
        action_fail("forkop", "install", "Failed to resolve Forkop release packages", FORKOP_VERSION, latest_version);

    let backend_file = tmp_dir + "/" + release.backend_name;
    let app_file = tmp_dir + "/" + release.app_name;
    let i18n_file = release.i18n_url != "" ? tmp_dir + "/" + release.i18n_name : "";
    if (!download_with_retry(release.backend_url, backend_file, release.backend_name) ||
        !download_with_retry(release.app_url, app_file, release.app_name) ||
        (release.i18n_url != "" && !download_with_retry(release.i18n_url, i18n_file, release.i18n_name)))
        action_fail("forkop", "install", "Failed to download Forkop release packages", FORKOP_VERSION, latest_version);

    if (!module_success([ LIB_DIR + "/service/ui.uc", "begin-package-upgrade-quiesce", owner_pid() ]))
        action_fail("forkop", "install", "Another Forkop service transition or package upgrade is starting", FORKOP_VERSION, latest_version);
    if (!wait_for_service_action_idle())
        action_fail("forkop", "install", "Timed out waiting for the current Forkop service action before upgrade", FORKOP_VERSION, latest_version);
    capture_forkop_running_state();

    // Capture before apk/opkg runs the currently installed package's prerm.
    // The new lifecycle will accept only this exact PID/starttime for a short
    // bounded exit wait, then re-run the normal ownership guard.
    capture_managed_upgrade_sing_box_marker();

    if (!stop_old_sing_box_before_forkop_upgrade())
        action_fail("forkop", "install", "Old sing-box processes have ambiguous ownership or did not stop", FORKOP_VERSION, latest_version);

    // Releases before this fix remove the unmanaged compressed binary in
    // their prerm. Save it before the package manager invokes that old hook.
    if (sing_box_runtime_output("read-variant-marker", []) == "extended-compressed") {
        for (let name in [ "sing-box", "sing-box.init", "libcronet.so" ])
            remove_file(COMPRESSED_UPGRADE_BACKUP + "/" + name);
        let service = read_file("/etc/init.d/sing-box");
        if (!file_nonempty("/usr/bin/sing-box") || index(service, SB_MANAGED_SERVICE_MARKER) < 0 ||
            !ensure_dir(COMPRESSED_UPGRADE_BACKUP) ||
            !command_success_from_args([ "cp", "-p", "/usr/bin/sing-box", COMPRESSED_UPGRADE_BACKUP + "/sing-box" ]) ||
            !command_success_from_args([ "cp", "-p", "/etc/init.d/sing-box", COMPRESSED_UPGRADE_BACKUP + "/sing-box.init" ]) ||
            (file_exists("/usr/lib/libcronet.so") &&
             !command_success_from_args([ "cp", "-p", "/usr/lib/libcronet.so", COMPRESSED_UPGRADE_BACKUP + "/libcronet.so" ])))
            action_fail("forkop", "install", "Failed to preserve compressed sing-box before upgrade", FORKOP_VERSION, latest_version);
    }

    let remaining_sing_box = upgrade_sing_box_processes();
    if (remaining_sing_box == null || upgrade_sing_box_count(remaining_sing_box) != 0)
        action_fail("forkop", "install", "Old sing-box processes appeared before package installation", FORKOP_VERSION, latest_version);

    // apk refreshes repository indexes for every `add` invocation. Install the
    // release files in one transaction on APK systems to retain dependency
    // resolution while avoiding two redundant index refreshes. Keep opkg's
    // established ordering unchanged.
    if (is_apk()) {
        let files = [ app_file ];
        if (i18n_file != "")
            push(files, i18n_file);
        push(files, backend_file);
        if (!run_logged("Installing Forkop release packages", pkg_install_files_command(files)))
            action_fail("forkop", "install", "Failed to install Forkop release packages", FORKOP_VERSION, latest_version);
    }
    else {
        if (!run_logged("Installing LuCI app package " + release.app_name, pkg_install_files_command([ app_file ])))
            action_fail("forkop", "install", "Failed to install LuCI app package", FORKOP_VERSION, latest_version);
        if (i18n_file != "" && !run_logged("Installing LuCI Russian i18n package " + release.i18n_name, pkg_install_files_command([ i18n_file ])))
            action_fail("forkop", "install", "Failed to install LuCI Russian i18n package", FORKOP_VERSION, latest_version);
        if (!run_logged("Installing Forkop package " + release.backend_name, pkg_install_files_command([ backend_file ])))
            action_fail("forkop", "install", "Failed to install Forkop package", FORKOP_VERSION, latest_version);
    }

    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    if (file_exists("/etc/init.d/rpcd") && !command_success_from_args([ "/etc/init.d/rpcd", "reload" ]))
        command_success_from_args([ "/etc/init.d/rpcd", "restart" ]);
    command_success_from_args([ "killall", "-HUP", "rpcd" ]);

    // The backend package post-install hook has already restored a Forkop
    // instance that was running before this release upgrade. Avoid a second
    // full restart and its readiness wait, but retain the restart fallback
    // if the package lifecycle did not leave Forkop healthy.
    if (forkop_was_running && wait_for_forkop_restore())
        updates_log("Forkop was restored by the package upgrade; final restart skipped");
    else
        restart_forkop_after_successful_change();
    clear_version_caches();
    let new_version = installed_package_version("forkop");
    if (new_version == "")
        new_version = latest_version;
    updates_log("Forkop updated to " + new_version);
    action_success("forkop", "install", "Forkop has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

function dispatch_sing_box(action) {
    if (action == "install_extended") {
        install_sing_box_extended(action, false);
        return;
    }
    if (action == "install_extended_compressed") {
        install_sing_box_extended(action, true);
        return;
    }
    if (action == "install_tiny") {
        install_package_sing_box(action, true);
        return;
    }
    if (action == "install_stable") {
        install_package_sing_box(action, false);
        return;
    }

    let variant = sing_box_runtime_output("variant", []);
    if (variant == "extended-compressed")
        install_sing_box_extended(action, true);
    else if (variant == "extended")
        install_sing_box_extended(action, false);
    else if (variant == "tiny")
        install_package_sing_box(action, true);
    else
        install_package_sing_box(action, false);
}

function set_packet_steering(action) {
    let init_script = "/etc/init.d/packet_steering";
    let config_path = "network.@globals[0].packet_steering";
    let current_mode = trim(uci_core.get(config_path));
    let target_mode = action == "enable" ? "2" : "1";

    if (!file_exists(init_script))
        action_fail("packet_steering", action, "Packet Steering service is not available", current_mode, target_mode);
    if (!uci_core.available() ||
        !uci_core.set(config_path, target_mode) ||
        !uci_core.commit("network") ||
        !command_success_from_args([ init_script, "restart" ]))
        action_fail("packet_steering", action, "Failed to apply Packet Steering mode " + target_mode, current_mode, target_mode);

    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success("packet_steering", action,
        target_mode == "2" ? "Packet Steering mode 2 has been enabled" : "Packet Steering normal mode has been restored",
        target_mode, target_mode, current_mode == target_mode ? 0 : 1, "", "");
}

function set_direct_proxy(action) {
    let enabled_path = CONFIG_NAME + ".settings.direct_proxy_enabled";
    let port_path = CONFIG_NAME + ".settings.direct_proxy_port";
    let current_enabled = trim(uci_core.get(enabled_path)) == "1" ? "1" : "0";
    let target_enabled = action == "enable" ? "1" : "0";
    let current_port = trim(uci_core.get(port_path));
    let current_port_number = match(current_port, /^[0-9]+$/) != null ? int(current_port, 10) : 0;
    let target_port = current_port_number >= 1 && current_port_number <= 65535 ? current_port : "2080";

    if (!file_exists(SERVICE_INIT))
        action_fail("direct_proxy", action, "Forkop service is not available", current_enabled, target_enabled);
    if (target_enabled == "1" && current_enabled != "1") {
        let listen = trim(module_output([ LIB_DIR + "/singbox/runtime.uc", "service-listen-address" ]));
        if (listen == "")
            action_fail("direct_proxy", action, "Failed to determine the Direct Proxy LAN address", current_enabled, target_enabled);
        if (!command_exists("netstat"))
            action_fail("direct_proxy", action, "Failed to verify whether Direct Proxy port " + target_port + " is available", current_enabled, target_enabled);
        let listeners = command_output_from_args([ "netstat", "-ln" ]);
        if (listeners == "")
            action_fail("direct_proxy", action, "Failed to verify whether Direct Proxy port " + target_port + " is available", current_enabled, target_enabled);
        if (netstat.listen_port_in_use(listeners, listen, target_port))
            action_fail("direct_proxy", action, "Direct Proxy port " + target_port + " is already in use", current_enabled, target_enabled);
    }
    if (!uci_core.available() ||
        !uci_core.set(enabled_path, target_enabled) ||
        !uci_core.set(port_path, target_port) ||
        !uci_core.commit(CONFIG_NAME))
        action_fail("direct_proxy", action, "Failed to save Direct Proxy settings", current_enabled, target_enabled);

    if (!command_success_from_args([ SERVICE_INIT, "restart" ])) {
        uci_core.set(enabled_path, current_enabled);
        if (current_port != "")
            uci_core.set(port_path, current_port);
        else
            uci_core.delete(port_path);
        uci_core.commit(CONFIG_NAME);
        command_success_from_args([ SERVICE_INIT, "restart" ]);
        action_fail("direct_proxy", action, "Failed to apply Direct Proxy settings", current_enabled, target_enabled);
    }

    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success("direct_proxy", action,
        target_enabled == "1" ? "Direct Proxy has been enabled" : "Direct Proxy has been disabled",
        target_enabled, target_enabled, current_enabled == target_enabled ? 0 : 1, "", "");
}

function set_torrserver_direct(action) {
    let enabled_path = CONFIG_NAME + ".settings.torrserver_direct_enabled";
    let current_enabled = trim(uci_core.get(enabled_path)) == "1" ? "1" : "0";
    let target_enabled = action == "enable" ? "1" : "0";

    if (!file_exists(TORRSERVER_DIRECT_INIT) || !file_exists(TORRSERVER_DIRECT_UC))
        action_fail("torrserver_direct", action, "TorrServer Direct service is not available", current_enabled, target_enabled);
    if (target_enabled == "1") {
        if (!command_success_from_args([ "modprobe", "nft_socket" ]) &&
            (!run_logged("Installing TorrServer Direct kernel support", pkg_install_name_command("kmod-nft-socket")) ||
             !command_success_from_args([ "modprobe", "nft_socket" ])))
            action_fail("torrserver_direct", action, "This firmware does not provide kmod-nft-socket required for TorrServer Direct", current_enabled, target_enabled);
        let status = parse_json_object(module_output([ TORRSERVER_DIRECT_UC, "status" ]));
        if (type(status) != "object" || int(status.running || 0) != 1)
            action_fail("torrserver_direct", action, "TorrServer is not running", current_enabled, target_enabled);
        if (int(status.available || 0) != 1)
            action_fail("torrserver_direct", action, "TorrServer does not have a dedicated cgroup", current_enabled, target_enabled);
    }
    if (!uci_core.available() || !uci_core.set(enabled_path, target_enabled) || !uci_core.commit(CONFIG_NAME))
        action_fail("torrserver_direct", action, "Failed to save TorrServer Direct settings", current_enabled, target_enabled);

    let applied = target_enabled == "1"
        ? command_success_from_args([ TORRSERVER_DIRECT_INIT, "enable" ]) &&
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "restart" ]) &&
            module_success([ TORRSERVER_DIRECT_UC, "reconcile" ])
        : command_success_from_args([ TORRSERVER_DIRECT_INIT, "stop" ]) &&
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "disable" ]);
    if (!applied) {
        uci_core.set(enabled_path, current_enabled);
        uci_core.commit(CONFIG_NAME);
        action_fail("torrserver_direct", action, "Failed to apply TorrServer Direct settings", current_enabled, target_enabled);
    }
    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success("torrserver_direct", action,
        target_enabled == "1" ? "TorrServer Direct has been enabled" : "TorrServer Direct has been disabled",
        target_enabled, target_enabled, current_enabled == target_enabled ? 0 : 1, "", "");
}

function normalize_component_name(component) {
    component = as_string(component);
    if (component == "sing-box" || component == "singbox")
        return "sing_box";
    if (component == "forkop")
        return "forkop";
    return component;
}

function component_action(component, action) {
    component = normalize_component_name(component);
    action = as_string(action);
    if (!acquire_component_lock())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Another component action is already running");
    if (!init_tmp_dir())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Failed to create temporary directory");
    capture_forkop_running_state();

    if (component == "forkop" && action == "check_update")
        check_forkop();
    else if (component == "forkop" && action == "install")
        install_forkop();
    else if (component == "sing_box" && (action == "check_update" || action == "install" ||
        action == "install_extended" || action == "install_extended_compressed" ||
        action == "install_tiny" || action == "install_stable"))
        dispatch_sing_box(action);
    else if (component == "zapret" && (action == "check_update" || action == "install"))
        install_zapret(action);
    else if (component == "zapret" && action == "remove")
        remove_optional_component("zapret", "zapret", "zapret", LIB_DIR + "/providers/zapret/runtime.uc");
    else if (component == "zapret2" && (action == "check_update" || action == "install"))
        install_zapret2(action);
    else if (component == "zapret2" && action == "remove")
        remove_optional_component("zapret2", "zapret2", "zapret2", LIB_DIR + "/providers/zapret2/runtime.uc");
    else if (component == "byedpi" && (action == "check_update" || action == "install"))
        install_byedpi(action);
    else if (component == "byedpi" && action == "remove")
        remove_optional_component("byedpi", "byedpi", "ByeDPI", LIB_DIR + "/providers/byedpi/runtime.uc");
    else if (component == "zapret_manager" && action == "install")
        install_zapret_manager(action);
    else if (component == "zapret_manager" && action == "remove")
        remove_zapret_manager(action);
    else if (component == "packet_steering" && (action == "enable" || action == "restore"))
        set_packet_steering(action);
    else if (component == "direct_proxy" && (action == "enable" || action == "disable"))
        set_direct_proxy(action);
    else if (component == "torrserver_direct" && (action == "enable" || action == "disable"))
        set_torrserver_direct(action);
    else
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Unknown component action");
}

let mode = ARGV[0] || "";

if (mode == "component-action")
    component_action(ARGV[1], ARGV[2]);
else if (mode == "latest-forkop-release-json")
    print(latest_forkop_release_json());
else if (mode == "latest-forkop-version")
    print(latest_forkop_version(), "\n");
else if (mode == "forkop-release-metadata")
    print(fetch_forkop_latest_release_metadata(), "\n");
else if (mode == "forkop-release-plan-fixture") {
    let input = fs.open("/dev/stdin", "r");
    let fixture_input = input ? input.read("all") : "";
    if (input)
        input.close();
    let plan = ARGV[4] == "tsv" ? fixture_input : helper_output_input(fixture_input, "forkop-release-plan", [ ARGV[1], ARGV[2], ARGV[3] ]);
    let release = parse_forkop_release_plan(plan, ARGV[1], ARGV[3]);
    if (release == null)
        exit(1);
    write_json(release);
}
else if (mode == "sing-box-package-info-fixture") {
    let info = staged_package_info(ARGV[1], ARGV[2], ARGV[3]);
    if (info == null)
        exit(1);
    write_json(info);
}
else if (mode == "sing-box-package-preflight-fixture") {
    init_tmp_dir();
    let target = staged_package_info(ARGV[1], ARGV[2], ARGV[3]);
    let previous = ARGV[4] == "" ? null : staged_package_info(ARGV[4], ARGV[5], ARGV[6]);
    let error = sing_box_package_preflight(target, previous, int(ARGV[7] || "0"));
    if (error != "") {
        warn(error, "\n");
        exit(1);
    }
    print("ok\n");
}
else if (mode == "sing-box-space-fixture") {
    let error = sing_box_space_error(int(ARGV[1]), int(ARGV[2]), int(ARGV[3]),
        int(ARGV[4] || "0"), int(ARGV[5] || "0"), int(ARGV[6] || "0"));
    if (error != "") {
        warn(error, "\n");
        exit(1);
    }
    print("ok\n");
}
else {
    warn("Usage: components/action.uc <component-action|latest-forkop-version|forkop-release-metadata> ...\n");
    exit(1);
}
