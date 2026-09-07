#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let rulesets = require("singbox.rulesets");

const CACHE_DIR = getenv("FORKOP_RULESET_CACHE_DIR") || "/etc/forkop/ruleset-cache";
const MANIFEST_PATH = getenv("FORKOP_RULESET_CACHE_MANIFEST") || CACHE_DIR + "/manifest.json";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const TEMPORARY_FILE_MAX_AGE = int(getenv("FORKOP_RULESET_CACHE_TEMP_MAX_AGE") || "3600");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let escaped = [];
    for (let arg in args)
        push(escaped, shell_quote(arg));
    return join(" ", escaped);
}

function command_success(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function ensure_cache_dir() {
    return command_success([ "mkdir", "-p", CACHE_DIR ]) &&
        command_success([ "chmod", "0700", CACHE_DIR ]);
}

function cleanup_stale_temporary_file(path, now, max_age) {
    let name = substr(path, length(CACHE_DIR) + 1);
    let managed = match(name, /^[0-9a-f]{12}\.(srs|json)\.download\.[0-9]+\.[0-9]+(\.validated)?$/) != null ||
        match(name, /^manifest\.json\.[0-9]+\.[0-9]+\.tmp$/) != null ||
        match(name, /^\.validate-[0-9a-f]{12}\.json$/) != null;
    if (!managed)
        return;

    let stat = fs.stat(path);
    let mtime = stat == null ? 0 : int(stat.mtime || 0);
    if (mtime <= 0 || now < mtime || now - mtime >= max_age)
        fs.unlink(path);
}

function cleanup_stale_temporary_files() {
    let now = int(clock()[0]);
    let max_age = TEMPORARY_FILE_MAX_AGE >= 0 ? TEMPORARY_FILE_MAX_AGE : 3600;

    for (let path in fs.glob(CACHE_DIR + "/*"))
        cleanup_stale_temporary_file(path, now, max_age);
    // BusyBox/ucode globbing does not include dotfiles in '*'.
    for (let path in fs.glob(CACHE_DIR + "/.*"))
        cleanup_stale_temporary_file(path, now, max_age);
}

function append_unique(values, value) {
    value = as_string(value);
    if (value == "")
        return;
    for (let existing in values)
        if (as_string(existing) == value)
            return;
    push(values, value);
}

function fallback_urls(url) {
    url = as_string(url);
    let result = [];
    let main_prefix = as_string(constants.SRS_MAIN_URL) + "/";
    if (substr(url, 0, length(main_prefix)) == main_prefix)
        append_unique(result, as_string(constants.SRS_FALLBACK_MAIN_URL) + "/" + substr(url, length(main_prefix)));
    if (url == as_string(constants.SRS_ADS_HAGEZI_PRO_URL))
        append_unique(result, constants.SRS_FALLBACK_ADS_HAGEZI_PRO_URL);
    if (url == as_string(constants.SRS_SUPERCELL_URL))
        append_unique(result, constants.SRS_FALLBACK_SUPERCELL_URL);
    if (url == as_string(constants.SRS_GITHUB_URL))
        append_unique(result, constants.SRS_FALLBACK_GITHUB_URL);
    return result;
}

function candidate_urls(url) {
    let result = [];
    append_unique(result, url);
    for (let fallback in fallback_urls(url))
        append_unique(result, fallback);
    return result;
}

function identity_url(url) {
    let fallbacks = fallback_urls(url);
    return length(fallbacks) > 0 ? as_string(fallbacks[0]) : as_string(url);
}

function cache_key(url) {
    return rulesets.hash12(identity_url(url));
}

function cache_path(url, format) {
    return CACHE_DIR + "/" + cache_key(url) + (format == "source" ? ".json" : ".srs");
}

function valid_source(path) {
    let value = common.read_json_file(path);
    return type(value) == "object" && type(value.rules) == "array";
}

function binary_validation_path(path) {
    return as_string(path) + ".validated";
}

function binary_stat_signature(path) {
    let stat = fs.stat(path);
    if (stat == null)
        return "";
    return join(":", [ stat.inode, stat.size, stat.mtime, stat.ctime ]);
}

function mark_binary_valid(path) {
    let signature = binary_stat_signature(path);
    return signature != "" && fs.writefile(binary_validation_path(path), signature + "\n") != null;
}

function valid_binary(path) {
    let signature = binary_stat_signature(path);
    let validation_path = binary_validation_path(path);
    if (signature == "") {
        fs.unlink(validation_path);
        return false;
    }
    if (trim(as_string(fs.readfile(validation_path))) == signature)
        return true;

    let output = CACHE_DIR + "/.validate-" + cache_key(path) + ".json";
    fs.unlink(output);
    let ok = command_success([ "sing-box", "rule-set", "decompile", path, "-o", output ]) && valid_source(output);
    fs.unlink(output);
    if (ok)
        mark_binary_valid(path);
    else
        fs.unlink(validation_path);
    return ok;
}

function valid_cache(path, format) {
    return format == "source" ? valid_source(path) : valid_binary(path);
}

function duration_seconds(value) {
    let rest = as_string(value);
    if (rest == "")
        return 86400;
    let total = 0;
    let multipliers = { s: 1, m: 60, h: 3600, d: 86400 };
    while (rest != "") {
        let matched = match(rest, /^([0-9]+)([smhd])(.*)$/);
        if (matched == null)
            return 86400;
        total += int(matched[1]) * multipliers[matched[2]];
        rest = matched[3];
    }
    return total > 0 ? total : 86400;
}

function entry_is_due(entry) {
    entry = common.object_or_empty(entry);
    let format = as_string(entry.format) == "source" ? "source" : "binary";
    if (!valid_cache(cache_path(entry.url, format), format))
        return true;
    let last = int(entry.last_success || "0");
    let now = int(clock()[0]);
    let interval = duration_seconds(entry.update_interval);
    if (last <= 0)
        return true;
    if (now < last)
        return last - now > interval;
    return now - last >= interval;
}

function write_manifest(manifest) {
    let stamp = clock();
    let temporary = MANIFEST_PATH + "." + as_string(stamp[0]) + "." + as_string(stamp[1]) + ".tmp";
    fs.unlink(temporary);
    if (common.write_json_file(temporary, manifest) == null || !command_success([ "chmod", "0600", temporary ])) {
        fs.unlink(temporary);
        return false;
    }
    if (!fs.rename(temporary, MANIFEST_PATH)) {
        fs.unlink(temporary);
        return false;
    }
    return true;
}

function download_candidate(url, target, proxy_address) {
    let args = [ "curl", "--fail", "--location", "--silent", "--show-error", "--connect-timeout", "8", "--max-time", "30" ];
    if (as_string(proxy_address) != "")
        push(args, "--proxy", "http://" + as_string(proxy_address));
    push(args, "--output", target, url);
    return command_success(args);
}

function refresh_entry(entry, proxy_address) {
    entry = common.object_or_empty(entry);
    let url = as_string(entry.url);
    let format = as_string(entry.format) == "source" ? "source" : "binary";
    let target = cache_path(url, format);
    let stamp = clock();
    let temporary = target + ".download." + as_string(stamp[0]) + "." + as_string(stamp[1]);
    fs.unlink(temporary);
    fs.unlink(binary_validation_path(temporary));

    for (let candidate in candidate_urls(url)) {
        if (!download_candidate(candidate, temporary, proxy_address)) {
            fs.unlink(temporary);
            fs.unlink(binary_validation_path(temporary));
            continue;
        }
        if (!valid_cache(temporary, format)) {
            fs.unlink(temporary);
            fs.unlink(binary_validation_path(temporary));
            continue;
        }
        let old_data = fs.readfile(target);
        let new_data = fs.readfile(temporary);
        if (old_data != null && new_data != null && old_data == new_data) {
            fs.unlink(temporary);
            fs.unlink(binary_validation_path(temporary));
            mark_binary_valid(target);
            return { ok: true, changed: false };
        }
        if (fs.rename(temporary, target)) {
            fs.unlink(binary_validation_path(temporary));
            mark_binary_valid(target);
            command_success([ "chmod", "0600", target ]);
            return { ok: true, changed: true };
        }
        fs.unlink(temporary);
        fs.unlink(binary_validation_path(temporary));
        return { ok: false, changed: false };
    }
    return { ok: false, changed: false };
}

function empty_ruleset_path(url) {
    let path = CACHE_DIR + "/empty-" + cache_key(url) + ".json";
    if (!valid_source(path))
        common.write_json_file(path, { version: 1, rules: [] });
    command_success([ "chmod", "0600", path ]);
    return path;
}

function prune_stale_cache(manifest) {
    let keep = {};
    for (let key, entry in common.object_or_empty(manifest)) {
        let format = as_string(entry.format) == "source" ? "source" : "binary";
        let path = cache_path(entry.url, format);
        keep[path] = true;
        keep[CACHE_DIR + "/empty-" + cache_key(entry.url) + ".json"] = true;
        if (format == "binary")
            keep[binary_validation_path(path)] = true;
    }

    for (let path in fs.glob(CACHE_DIR + "/*")) {
        let name = substr(path, length(CACHE_DIR) + 1);
        let managed = match(name, /^[0-9a-f]{12}\.(srs|json)(\.validated)?$/) ||
            match(name, /^empty-[0-9a-f]{12}\.json$/);
        if (managed && !keep[path])
            fs.unlink(path);
    }
}

function local_rule_set(rule_set, manifest, previous_manifest, allow_download) {
    let url = as_string(rule_set.url);
    let format = as_string(rule_set.format) == "source" ? "source" : "binary";
    let key = cache_key(url);
    let entry = {
        url,
        format,
        update_interval: as_string(rule_set.update_interval) == "" ? "1d" : as_string(rule_set.update_interval),
        last_success: 0
    };
    let previous = common.object_or_empty(common.object_or_empty(previous_manifest)[key]);
    if (as_string(previous.url) == url && as_string(previous.format) == format)
        entry.last_success = int(previous.last_success || "0");
    manifest[key] = entry;

    let path = cache_path(url, format);
    if (allow_download && !valid_cache(path, format)) {
        let result = refresh_entry(entry, "");
        if (result.ok)
            entry.last_success = int(clock()[0]);
    }

    let local_format = format;
    if (!valid_cache(path, format)) {
        path = empty_ruleset_path(url);
        local_format = "source";
        warn("rule-set cache unavailable for tag ", as_string(rule_set.tag), "; starting with an empty local rule-set\n");
    }

    return {
        type: "local",
        tag: rule_set.tag,
        format: local_format,
        path
    };
}

function materialize_config(config_path, allow_download) {
    if (!ensure_cache_dir())
        return false;
    cleanup_stale_temporary_files();
    let config = common.read_json_file(config_path);
    if (type(config) != "object")
        return false;
    let route = common.object_or_empty(config.route);
    let values = common.array_or_empty(route.rule_set);
    let previous_manifest = common.object_or_empty(common.read_json_file(MANIFEST_PATH));
    let manifest = {};
    for (let i = 0; i < length(values); i++)
        if (type(values[i]) == "object" && values[i].type == "remote")
            values[i] = local_rule_set(values[i], manifest, previous_manifest, allow_download);
    route.rule_set = values;
    config.route = route;
    if (!common.write_json_file(config_path, config))
        return false;
    if (!write_manifest(manifest))
        return false;
    prune_stale_cache(manifest);
    return true;
}

function refresh_manifest(proxy_address, due_only) {
    if (!ensure_cache_dir())
        return false;
    cleanup_stale_temporary_files();
    let manifest = common.object_or_empty(common.read_json_file(MANIFEST_PATH));
    let changed = false;
    let failed = false;
    let attempted = false;
    for (let key, entry in manifest) {
        if (due_only && !entry_is_due(entry))
            continue;
        attempted = true;
        let result = refresh_entry(entry, proxy_address);
        if (!result.ok) {
            failed = true;
            continue;
        }
        entry.last_success = int(clock()[0]);
        if (result.changed)
            changed = true;
    }
    if (attempted && !write_manifest(manifest))
        failed = true;
    // Entries are independent and each refresh is atomically renamed over its
    // own last-known-good file. Apply successful changes even if another entry
    // failed; failed entries keep their old cache and remain due for retry.
    if (failed && !changed)
        return 2;
    return changed ? 0 : 1;
}

function refresh_and_reload(proxy_address) {
    if (refresh_manifest(proxy_address, false) != 0)
        return;
    system(command_from_args([ SERVICE_INIT, "reload", "ruleset-cache" ]) + " >/dev/null 2>&1 1000>&- &");
}

function refresh_if_due_and_reload(proxy_address) {
    if (refresh_manifest(proxy_address, true) != 0)
        return;
    system(command_from_args([ SERVICE_INIT, "reload", "ruleset-cache" ]) + " >/dev/null 2>&1 1000>&- &");
}

let mode = ARGV[0] || "";
if (mode == "materialize-config")
    exit(materialize_config(ARGV[1], as_string(ARGV[2]) != "cache-only") ? 0 : 1);
else if (mode == "refresh")
    exit(refresh_manifest(ARGV[1], false));
else if (mode == "refresh-if-due")
    exit(refresh_manifest(ARGV[1], true));
else if (mode == "refresh-and-reload")
    refresh_and_reload(ARGV[1]);
else if (mode == "refresh-if-due-and-reload")
    refresh_if_due_and_reload(ARGV[1]);
else if (mode == "fallback-urls")
    for (let url in fallback_urls(ARGV[1]))
        print(url, "\n");
else {
    warn("Usage: singbox/ruleset_cache.uc <materialize-config|refresh|refresh-and-reload|fallback-urls> ...\n");
    exit(1);
}
