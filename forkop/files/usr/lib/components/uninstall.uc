#!/usr/bin/env ucode

let lib = getenv("FORKOP_LIB") || "/usr/lib/forkop";
function quote(value) { return "'" + replace(value, /'/g, "'\\''") + "'"; }
exit(system("sh " + quote(lib + "/full-uninstall.sh") + " start"));
