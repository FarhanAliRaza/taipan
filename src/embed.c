#include <Python.h>
#include <stdio.h>
#include <string.h>

#include "embed.h"

static PyStatus add_search_path(PyWideStringList *list, const char *path) {
    wchar_t *w = Py_DecodeLocale(path, NULL);
    if (w == NULL)
        return PyStatus_Error("taipan: cannot decode search path");
    PyStatus status = PyWideStringList_Append(list, w);
    PyMem_RawFree(w);
    return status;
}

int taipan_run_file(const char *stdlib_path, const char *extra_sys_path,
                 int precompile_extra, const char *script_path,
                 int argc, char **argv) {
    PyStatus status;
    PyConfig config;

    /* Isolated: ignore PYTHON* env vars, no user site dir. On top of that,
     * skip the `site` module entirely and never write .pyc files — both are
     * startup cost we don't want, and sys.path is fully explicit below. */
    PyConfig_InitIsolatedConfig(&config);
    config.site_import = 0;
    config.write_bytecode = 0;
    config.parse_argv = 0;

    status = PyConfig_SetBytesString(&config, &config.program_name, "taipan");
    if (PyStatus_Exception(status)) goto fail;

    /* No config.home, no path probing: sys.path is exactly what we say. */
    config.module_search_paths_set = 1;
    status = add_search_path(&config.module_search_paths, stdlib_path);
    if (PyStatus_Exception(status)) goto fail;

#ifdef MS_WINDOWS
    /* On Windows the stdlib C extensions are separate .pyd files, extracted
     * to a DLLs/ dir next to stdlib.zip. Their support DLLs (OpenSSL,
     * sqlite3, libffi) sit beside them and resolve via the loader's
     * DLL-load-dir search. Paths from the Zig side always use '/'. */
    {
        const char *slash = strrchr(stdlib_path, '/');
        if (slash != NULL) {
            char dlls_dir[4096];
            int n = snprintf(dlls_dir, sizeof dlls_dir, "%.*s/DLLs",
                             (int)(slash - stdlib_path), stdlib_path);
            if (n > 0 && (size_t)n < sizeof dlls_dir) {
                status = add_search_path(&config.module_search_paths, dlls_dir);
                if (PyStatus_Exception(status)) goto fail;
            }
        }
    }
#endif

    if (extra_sys_path && extra_sys_path[0]) {
        status = add_search_path(&config.module_search_paths, extra_sys_path);
        if (PyStatus_Exception(status)) goto fail;
    }

    status = PyConfig_SetBytesArgv(&config, argc, argv);
    if (PyStatus_Exception(status)) goto fail;

#ifdef MS_WINDOWS
    /* Run the script via Py_RunMain instead of PyRun_SimpleFile: a FILE*
     * must never cross the shim/python313.dll boundary (separate CRT state). */
    status = PyConfig_SetBytesString(&config, &config.run_filename, script_path);
    if (PyStatus_Exception(status)) goto fail;
#endif

    status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) goto fail;
    PyConfig_Clear(&config);

    /* One-time bytecode precompile of a fresh dependency env, in-process so
     * no external python is ever needed. Failure only costs speed. */
    if (precompile_extra && extra_sys_path && extra_sys_path[0]) {
        char buf[4200];
        int n = snprintf(buf, sizeof buf,
                         "import compileall\n"
                         "compileall.compile_dir('%s', quiet=2)\n",
                         extra_sys_path);
        if (n > 0 && (size_t)n < sizeof buf && PyRun_SimpleString(buf) != 0)
            PyErr_Clear();
    }

#ifdef MS_WINDOWS
    /* Runs config.run_filename in __main__, finalizes, returns the exit
     * code (SystemExit included). */
    return Py_RunMain();
#else
    FILE *fp = fopen(script_path, "rb");
    if (fp == NULL) {
        fprintf(stderr, "taipan: cannot open %s\n", script_path);
        Py_FinalizeEx();
        return 1;
    }

    /* Runs in __main__ with __file__ set; closeit=1 hands fp to CPython. */
    int rc = PyRun_SimpleFileExFlags(fp, script_path, 1, NULL);

    if (Py_FinalizeEx() < 0 && rc == 0)
        rc = 120;
    return rc != 0 ? 1 : 0;
#endif

fail:
    PyConfig_Clear(&config);
    if (PyStatus_IsExit(status))
        return status.exitcode;
    Py_ExitStatusException(status); /* prints and aborts */
    return 1;
}
