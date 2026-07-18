$ErrorActionPreference = "Stop"

$repo = if ($env:TAIPAN_REPOSITORY) { $env:TAIPAN_REPOSITORY } else { "FarhanAliRaza/taipan" }
$version = if ($env:TAIPAN_VERSION) { $env:TAIPAN_VERSION } else { "latest" }
$installDir = if ($env:TAIPAN_INSTALL_DIR) {
    $env:TAIPAN_INSTALL_DIR
} else {
    Join-Path $HOME ".local\bin"
}

$osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if (-not [Environment]::Is64BitOperatingSystem -or $osArchitecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
    throw "taipan: only 64-bit x86 Windows is currently supported"
}

$artifact = "taipan-windows-x86_64.exe"
$url = if ($env:TAIPAN_DOWNLOAD_URL) {
    $env:TAIPAN_DOWNLOAD_URL
} elseif ($version -eq "latest") {
    "https://github.com/$repo/releases/latest/download/$artifact"
} else {
    "https://github.com/$repo/releases/download/$version/$artifact"
}

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$dest = Join-Path $installDir "taipan.exe"
$temp = Join-Path $installDir ".taipan.tmp.$PID.exe"

try {
    Write-Host "taipan: downloading $artifact"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $temp
    Move-Item -Force $temp $dest
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $temp
}

Write-Host "taipan: installed to $dest"
$pathEntries = $env:PATH -split ";"
if ($installDir -notin $pathEntries) {
    Write-Host "taipan: add $installDir to PATH, or run & '$dest'"
}
