#include <Python.h>
#include <stdio.h>

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
    if (extra_sys_path && extra_sys_path[0]) {
        status = add_search_path(&config.module_search_paths, extra_sys_path);
        if (PyStatus_Exception(status)) goto fail;
    }

    status = PyConfig_SetBytesArgv(&config, argc, argv);
    if (PyStatus_Exception(status)) goto fail;

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

fail:
    PyConfig_Clear(&config);
    if (PyStatus_IsExit(status))
        return status.exitcode;
    Py_ExitStatusException(status); /* prints and aborts */
    return 1;
}
