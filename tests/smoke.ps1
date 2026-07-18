# Smoke-test a built taipan.exe end-to-end, ideally in a python-less Windows
# container (servercore has curl.exe/tar.exe but no python).
# Usage: powershell -ExecutionPolicy Bypass -File smoke.ps1 <taipan.exe> <examples-dir>
param(
    [Parameter(Mandatory = $true)][string]$Bin,
    [Parameter(Mandatory = $true)][string]$Examples
)

$script:fail = 0

function Check($name, $want, $got, $out, $substr) {
    if ($got -ne $want) {
        Write-Host "FAIL [$name]: exit $got (wanted $want). Output: $out"
        $script:fail = 1
    }
    elseif ($substr -and ($out -notmatch [regex]::Escape($substr))) {
        Write-Host "FAIL [$name]: output missing '$substr'. Output: $out"
        $script:fail = 1
    }
    else {
        Write-Host "PASS [$name]"
    }
}

if (Get-Command python -ErrorAction SilentlyContinue) {
    Write-Host "note: a system python exists in this environment; test is weaker than python-less"
}
else {
    Write-Host "environment is python-less - good"
}

$out = & $Bin "$Examples/hello.py" 2>&1 | Out-String
Check hello 0 $LASTEXITCODE $out "hello"

$out = & $Bin "$Examples/pure_dep.py" 2>&1 | Out-String
Check pure-dep-cold 0 $LASTEXITCODE $out

$out = & $Bin "$Examples/pure_dep.py" 2>&1 | Out-String
Check pure-dep-warm 0 $LASTEXITCODE $out

$out = & $Bin "$Examples/compiled_dep.py" 2>&1 | Out-String
Check compiled-dep 0 $LASTEXITCODE $out "WITH C extension"

Set-Content -Path "$env:TEMP\smoke_exit7.py" -Value "import sys; sys.exit(7)"
& $Bin "$env:TEMP\smoke_exit7.py" 2>&1 | Out-Null
Check exit-code 7 $LASTEXITCODE ""

Set-Content -Path "$env:TEMP\smoke_boom.py" -Value "raise ValueError('boom')"
$out = & $Bin "$env:TEMP\smoke_boom.py" 2>&1 | Out-String
Check traceback 1 $LASTEXITCODE $out "ValueError: boom"

# Build inside the container, delete the input scripts, and run with a fresh
# cache plus an invalid uv path. A passing run therefore came entirely from
# the standalone executable.
$work = Join-Path $env:TEMP ("taipan-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
Copy-Item "$Examples\hello.py" "$work\hello.py"
Copy-Item "$Examples\compiled_dep.py" "$work\compiled_dep.py"
Set-Content -Path "$work\exit7.py" -Value "import sys; sys.exit(7)"

$env:TAIPAN_CACHE = "$work\build-cache"
$out = & $Bin build "$work\hello.py" -o "$work\hello-built.exe" 2>&1 | Out-String
Check build-hello 0 $LASTEXITCODE $out "built"
$out = & $Bin build "$work\compiled_dep.py" -o "$work\compiled-built.exe" 2>&1 | Out-String
Check build-compiled-dep 0 $LASTEXITCODE $out "built"
$out = & $Bin build "$work\exit7.py" -o "$work\exit7-built.exe" 2>&1 | Out-String
Check build-exit-code 0 $LASTEXITCODE $out "built"

Remove-Item "$work\hello.py", "$work\compiled_dep.py", "$work\exit7.py"
$env:TAIPAN_CACHE = "$work\run-cache"
$env:TAIPAN_UV = "$work\missing-uv.exe"
$out = & "$work\hello-built.exe" docker-arg 2>&1 | Out-String
Check built-hello 0 $LASTEXITCODE $out "docker-arg"
$out = & "$work\compiled-built.exe" 2>&1 | Out-String
Check built-compiled-dep 0 $LASTEXITCODE $out "WITH C extension"
& "$work\exit7-built.exe" 2>&1 | Out-Null
Check built-exit-code 7 $LASTEXITCODE "" ""

Remove-Item -Recurse -Force $work

if ($script:fail -eq 0) { Write-Host "SMOKE OK"; exit 0 }
Write-Host "SMOKE FAILED"
exit 1
