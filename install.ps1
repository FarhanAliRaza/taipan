# Install taipan on Windows:
#
#   powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/FarhanAliRaza/taipan/main/install.ps1 | iex"
#
# Downloads the Windows binary from the latest GitHub release, installs it as
# taipan.exe, and adds the install directory to your user PATH.
#
# Environment variables:
#   TAIPAN_VERSION      release tag to install (e.g. v0.2.0); defaults to latest
#   TAIPAN_INSTALL_DIR  directory to install into; defaults to %LOCALAPPDATA%\Programs\taipan

$ErrorActionPreference = 'Stop'

$Repo = 'FarhanAliRaza/taipan'

if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    throw 'Windows ARM64 is not supported yet. See https://github.com/FarhanAliRaza/taipan#roadmap'
}
if (-not [Environment]::Is64BitOperatingSystem) {
    throw '32-bit Windows is not supported.'
}

$Asset = 'taipan-windows-x86_64.exe'
$Url = if ($env:TAIPAN_VERSION) {
    "https://github.com/$Repo/releases/download/$($env:TAIPAN_VERSION)/$Asset"
} else {
    "https://github.com/$Repo/releases/latest/download/$Asset"
}

$InstallDir = if ($env:TAIPAN_INSTALL_DIR) {
    $env:TAIPAN_INSTALL_DIR
} else {
    Join-Path $env:LOCALAPPDATA 'Programs\taipan'
}
$null = New-Item -ItemType Directory -Force -Path $InstallDir
$Dest = Join-Path $InstallDir 'taipan.exe'

# Windows PowerShell 5.1 defaults to TLS 1.0 and a slow progress bar.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

Write-Host "Downloading $Url"
$Tmp = "$Dest.download"
try {
    Invoke-WebRequest -Uri $Url -OutFile $Tmp -UseBasicParsing
    Move-Item -Force $Tmp $Dest
} finally {
    if (Test-Path $Tmp) { Remove-Item -Force $Tmp }
}

Write-Host "Installed taipan to $Dest"

$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($UserPath -split ';') -contains $InstallDir)) {
    $NewPath = if ($UserPath) { "$InstallDir;$UserPath" } else { $InstallDir }
    [Environment]::SetEnvironmentVariable('Path', $NewPath, 'User')
    Write-Host "Added $InstallDir to your user PATH. Open a new terminal to pick it up."
}
$env:Path = "$InstallDir;$env:Path"
