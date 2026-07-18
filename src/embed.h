#ifndef TAIPAN_EMBED_H
#define TAIPAN_EMBED_H

/* Initialize an isolated CPython with an explicit module search path
 * (stdlib_path first, then extra_sys_path if non-empty), run the script as
 * __main__, finalize, and return an exit code.
 *
 * stdlib_path      — path to stdlib.zip (imported via zipimport) or a dir.
 * executable_path  — absolute launcher path exposed as sys.executable and
 *                    used when multiprocessing re-execs the interpreter.
 * extra_sys_path   — dependency env dir, may be NULL/empty.
 * precompile_extra — if nonzero, run compileall on extra_sys_path after init
 *                    (first run after an install) so later runs never pay
 *                    source->bytecode cost. Best-effort.
 * script_path      — absolute path of the script; becomes __file__ and the
 *                    co_filename shown in tracebacks.
 * script_source    — the script's UTF-8 source, NUL-terminated, BOM already
 *                    stripped. Compiled only on a pyc cache miss.
 * pyc_path         — where the compiled script's marshalled code is cached.
 *                    The name must key runtime + script path + content (the
 *                    Zig side hashes all three) so entries can't go stale.
 *                    Empty/NULL disables the cache.
 * argv becomes sys.argv verbatim (argv[0] should be the script path). */
int taipan_run_file(const char *executable_path, const char *stdlib_path,
                 const char *extra_sys_path,
                 int precompile_extra, const char *script_path,
                 const char *script_source, const char *pyc_path,
                 int argc, char **argv);

#endif
