#ifndef TAIPAN_EMBED_H
#define TAIPAN_EMBED_H

/* Initialize an isolated CPython with an explicit module search path
 * (stdlib_path first, then extra_sys_path if non-empty), run script_path as
 * __main__, finalize, and return an exit code.
 *
 * stdlib_path      — path to stdlib.zip (imported via zipimport) or a dir.
 * extra_sys_path   — dependency env dir, may be NULL/empty.
 * precompile_extra — if nonzero, run compileall on extra_sys_path after init
 *                    (first run after an install) so later runs never pay
 *                    source->bytecode cost. Best-effort.
 * argv becomes sys.argv verbatim (argv[0] should be the script path). */
int taipan_run_file(const char *stdlib_path, const char *extra_sys_path,
                 int precompile_extra, const char *script_path,
                 int argc, char **argv);

#endif
