#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let rulesets = require("singbox.rulesets");

const CACHE_DIR = getenv("FORKOP_RULESET_CACHE_DIR") || "/etc/forkop/ruleset-cache";
const MANIFEST_PATH = getenv("FORKOP_RULESET_CACHE_MANIFEST") || CACHE_DIR + "/manifest.json";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";

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

function valid_binary(path) {
    let output = CACHE_DIR + "/.validate-" + cache_key(path) + ".json";
    fs.unlink(output);
    let ok = command_success([ "sing-box", "rule-set", "decompile", path, "-o", output ]) && valid_source(output);
    fs.unlink(output);
    return ok;
}

function valid_cache(path, format) {
    return format == "source" ? valid_source(path) : valid_binary(path);
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

    for (let candidate in candidate_urls(url)) {
        if (!download_candidate(candidate, temporary, proxy_address)) {
            fs.unlink(temporary);
            continue;
        }
        if (!valid_cache(temporary, format)) {
            fs.unlink(temporary);
            continue;
        }
        let old_data = fs.readfile(target);
        let new_data = fs.readfile(temporary);
        if (old_data != null && new_data != null && old_data == new_data) {
            fs.unlink(temporary);
            return false;
        }
        if (fs.rename(temporary, target)) {
            command_success([ "chmod", "0600", target ]);
            return true;
        }
        fs.unlink(temporary);
        return false;
    }
    return false;
}

function empty_ruleset_path(url) {
    let path = CACHE_DIR + "/empty-" + cache_key(url) + ".json";
    if (!valid_source(path))
        common.write_json_file(path, { version: 1, rules: [] });
    command_success([ "chmod", "0600", path ]);
    return path;
}

function local_rule_set(rule_set, manifest, allow_download) {
    let url = as_string(rule_set.url);
    let format = as_string(rule_set.format) == "source" ? "source" : "binary";
    let key = cache_key(url);
    let entry = { url, format };
    manifest[key] = entry;

    let path = cache_path(url, format);
    if (allow_download && !valid_cache(path, format))
        refresh_entry(entry, "");

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
    let config = common.read_json_file(config_path);
    if (type(config) != "object")
        return false;
    let route = common.object_or_empty(config.route);
    let values = common.array_or_empty(route.rule_set);
    let manifest = {};
    for (let i = 0; i < length(values); i++)
        if (type(values[i]) == "object" && values[i].type == "remote")
            values[i] = local_rule_set(values[i], manifest, allow_download);
    route.rule_set = values;
    config.route = route;
    if (!common.write_json_file(config_path, config))
        return false;
    if (common.write_json_file(MANIFEST_PATH, manifest) == null)
        return false;
    return command_success([ "chmod", "0600", MANIFEST_PATH ]);
}

function refresh_manifest(proxy_address) {
    if (!ensure_cache_dir())
        return false;
    let manifest = common.object_or_empty(common.read_json_file(MANIFEST_PATH));
    let changed = false;
    for (let key, entry in manifest)
        if (refresh_entry(entry, proxy_address))
            changed = true;
    return changed;
}

function refresh_and_reload(proxy_address) {
    if (!refresh_manifest(proxy_address))
        return;
    system(command_from_args([ SERVICE_INIT, "reload", "ruleset-cache" ]) + " >/dev/null 2>&1 1000>&- &");
}

let mode = ARGV[0] || "";
if (mode == "materialize-config")
    exit(materialize_config(ARGV[1], as_string(ARGV[2]) != "cache-only") ? 0 : 1);
else if (mode == "refresh")
    exit(refresh_manifest(ARGV[1]) ? 0 : 1);
else if (mode == "refresh-and-reload")
    refresh_and_reload(ARGV[1]);
else if (mode == "fallback-urls")
    for (let url in fallback_urls(ARGV[1]))
        print(url, "\n");
else {
    warn("Usage: singbox/ruleset_cache.uc <materialize-config|refresh|refresh-and-reload|fallback-urls> ...\n");
    exit(1);
}
