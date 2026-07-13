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

if ($script:fail -eq 0) { Write-Host "SMOKE OK"; exit 0 }
Write-Host "SMOKE FAILED"
exit 1
