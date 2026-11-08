# SPDX-License-Identifier: MIT
# Windows bootstrap for the liuqin Fedora installer.
#
#   powershell -ExecutionPolicy Bypass -File installer\windows\install-liuqin.ps1 doctor
#
# It only prepares host-side tools under %LOCALAPPDATA%\liuqin-install and then
# runs installer\liuqin-install.py.  It never flashes, repartitions or changes
# the tablet; those steps stay behind install.py --yes-write-device.  No WSL,
# no Visual Studio build tools and no administrator rights are required.
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$entry = $null
foreach ($candidate in @($here, (Split-Path -Parent $here), (Split-Path -Parent (Split-Path -Parent $here)))) {
    foreach ($name in @('installer\liuqin-install.py', 'liuqin-install.py')) {
        $path = Join-Path $candidate $name
        if (Test-Path $path) { $entry = $path; break }
    }
    if ($entry) { break }
}
if (-not $entry) {
    throw 'repository or release image is incomplete: liuqin-install.py is missing'
}
$root = Split-Path -Parent $entry
$work = Join-Path $env:LOCALAPPDATA 'liuqin-install'
$tools = Join-Path $work 'tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null

function Write-Step([string]$Message) {
    Write-Host "STAGE $Message"
}

function Test-Python([string]$Exe) {
    if (-not $Exe) { return $null }
    try {
        $version = & $Exe -c "import sys; print('%d.%d.%d' % sys.version_info[:3])" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $parts = $version.Trim().Split('.')
        if ([int]$parts[0] -gt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 11)) {
            return $Exe
        }
    } catch {
        return $null
    }
    return $null
}

function Find-Python {
    foreach ($name in @('python', 'python3')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            $found = Test-Python $command.Source
            if ($found) { return $found }
        }
    }
    $py = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $exe = & $py.Source -3 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $found = Test-Python $exe.Trim()
                if ($found) { return $found }
            }
        } catch { }
    }
    foreach ($candidate in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
            'C:\Python312\python.exe',
            'C:\Python313\python.exe')) {
        if (Test-Path $candidate) {
            $found = Test-Python $candidate
            if ($found) { return $found }
        }
    }
    return $null
}

function Install-EmbeddedPython {
    Write-Step 'python-download: no Python 3.11+ found; using a private embeddable copy'
    $version = '3.12.10'
    $target = Join-Path $tools 'python'
    $exe = Join-Path $target 'python.exe'
    if (Test-Path $exe) { return $exe }
    $zip = Join-Path $tools "python-$version-embed-amd64.zip"
    $url = "https://www.python.org/ftp/python/$version/python-$version-embed-amd64.zip"
    if (-not (Test-Path $zip)) {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    }
    $signature = Get-AuthenticodeSignature $zip
    if ($signature.Status -ne 'Valid') {
        throw "python.org download is not signed as expected: $($signature.Status)"
    }
    Expand-Archive -Path $zip -DestinationPath $target -Force
    if (-not (Test-Path $exe)) { throw 'could not unpack the embeddable Python' }
    return $exe
}

function Ensure-Python {
    $python = Find-Python
    if ($python) { return $python }
    $winget = Get-Command 'winget' -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Step 'python-install: trying a per-user Python through winget'
        try {
            & $winget.Source install --id Python.Python.3.12 --exact --scope user --silent `
                --accept-package-agreements --accept-source-agreements | Out-Null
        } catch {
            Write-Host "winget did not install Python: $($_.Exception.Message)"
        }
        $python = Find-Python
        if ($python) { return $python }
    }
    return Install-EmbeddedPython
}

function Ensure-PlatformTools {
    Write-Step 'platform-tools: locate fastboot.exe'
    $existing = Get-Command 'fastboot' -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $target = Join-Path $tools 'platform-tools'
    $exe = Join-Path $target 'fastboot.exe'
    if (-not (Test-Path $exe)) {
        $zip = Join-Path $tools 'platform-tools-latest-windows.zip'
        $url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
        if (-not (Test-Path $zip)) {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
        }
        Expand-Archive -Path $zip -DestinationPath $tools -Force
    }
    if (-not (Test-Path $exe)) { throw 'platform-tools did not contain fastboot.exe' }
    return $exe
}

$python = Ensure-Python
$fastboot = Ensure-PlatformTools
$env:FASTBOOT = $fastboot
$env:PATH = (Split-Path -Parent $fastboot) + ';' + (Split-Path -Parent $python) + ';' + $env:PATH

if (-not $Arguments -or $Arguments.Count -eq 0) {
    $Arguments = @('doctor')
}

Write-Host "Using Python: $python"
Write-Host "Using fastboot: $fastboot"
& $python $entry @Arguments
exit $LASTEXITCODE
