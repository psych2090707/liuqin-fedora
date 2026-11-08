# SPDX-License-Identifier: MIT
# Windows bootstrap for the liuqin Fedora installer.
#
#   powershell -ExecutionPolicy Bypass -File installer\windows\install-liuqin.ps1 doctor
#
# It only prepares host-side tools under %LOCALAPPDATA%\liuqin-install and then
# runs liuqin-install.py.  It never flashes, repartitions or changes the tablet;
# those steps stay behind install.py --yes-write-device.  No WSL, no Visual
# Studio build tools and no administrator rights are required.
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Pinned downloads.  The embeddable Python ZIP and the zstd Windows archive are
# not Authenticode-signed files, so verify their published SHA256 instead of
# checking a signature that cannot exist.  Update these together with the
# version strings and keep the test in tests/installer/test-agent-install.py
# in sync.
$PythonVersion = '3.12.10'
$PythonZipUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
$PythonZipSha256 = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'
$ZstdVersion = '1.5.7'
$ZstdZipUrl = "https://github.com/meta/zstd/releases/download/v$ZstdVersion/zstd-v$ZstdVersion-win64.zip"
$ZstdZipSha256 = 'acb4e8111511749dc7a3ebedca9b04190e37a17afeb73f55d4425dbf0b90fad9'
$AndroidRepositoryXml = 'https://dl.google.com/android/repository/repository2-3.xml'
$AndroidRepositoryBase = 'https://dl.google.com/android/repository/'

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
$work = Join-Path $env:LOCALAPPDATA 'liuqin-install'
$tools = Join-Path $work 'tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null

function Write-Step([string]$Message) {
    Write-Host "STAGE $Message"
}

function Get-VerifiedFile([string]$Url, [string]$Path, [string]$Algorithm, [string]$Expected) {
    if (Test-Path $Path) {
        $current = (Get-FileHash -Algorithm $Algorithm -Path $Path).Hash
        if ($current -eq $Expected) { return }
        Remove-Item -Force -Path $Path
    }
    Write-Step "download: $(Split-Path -Leaf $Path)"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
    $actual = (Get-FileHash -Algorithm $Algorithm -Path $Path).Hash
    if ($actual -ne $Expected) {
        Remove-Item -Force -Path $Path
        throw "checksum mismatch for $(Split-Path -Leaf $Path): $actual"
    }
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
    Write-Step 'python-download: no Python 3.11+ found; using a pinned private copy'
    $target = Join-Path $tools 'python'
    $exe = Join-Path $target 'python.exe'
    if (Test-Python $exe) { return $exe }
    $zip = Join-Path $tools "python-$PythonVersion-embed-amd64.zip"
    Get-VerifiedFile $PythonZipUrl $zip 'SHA256' $PythonZipSha256
    if (Test-Path $target) { Remove-Item -Recurse -Force -Path $target }
    Expand-Archive -Path $zip -DestinationPath $target -Force
    if (-not (Test-Python $exe)) { throw 'could not unpack a usable embeddable Python' }
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

function Get-PlatformToolsPackage {
    Write-Step 'platform-tools: read the Google repository checksum'
    $xml = (Invoke-WebRequest -UseBasicParsing -Uri $AndroidRepositoryXml).Content
    $package = [regex]::Match($xml,
        '<remotePackage[^>]*path="platform-tools".*?</remotePackage>',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $package.Success) { throw 'platform-tools is missing from the Google repository XML' }
    $archives = [regex]::Matches($package.Value, '<archive>.*?</archive>',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($archive in $archives) {
        if ($archive.Value -notmatch '<host-os>windows</host-os>') { continue }
        $url = [regex]::Match($archive.Value, '<url>([^<]+)</url>').Groups[1].Value
        $sha1 = [regex]::Match($archive.Value, '<checksum type="sha1">([0-9a-fA-F]+)</checksum>').Groups[1].Value
        if (-not $url -or -not $sha1) { break }
        return @{ Url = $AndroidRepositoryBase + $url; Sha1 = $sha1 }
    }
    throw 'the Google repository XML has no Windows platform-tools archive'
}

function Ensure-PlatformTools {
    Write-Step 'platform-tools: locate fastboot.exe'
    $existing = Get-Command 'fastboot' -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $target = Join-Path $tools 'platform-tools'
    $exe = Join-Path $target 'fastboot.exe'
    if (-not (Test-Path $exe)) {
        $package = Get-PlatformToolsPackage
        $zip = Join-Path $tools 'platform-tools-windows.zip'
        Get-VerifiedFile $package.Url $zip 'SHA1' $package.Sha1
        Expand-Archive -Path $zip -DestinationPath $tools -Force
    }
    if (-not (Test-Path $exe)) { throw 'platform-tools did not contain fastboot.exe' }
    return $exe
}

function Ensure-Zstd {
    # prepare-image.py uses this only for .zst firmware inputs; having it ready
    # keeps a clean Windows host from failing on that optional path.
    $found = Get-Command 'zstd' -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $target = Join-Path $tools "zstd-v$ZstdVersion-win64"
    $exe = Get-ChildItem -Path $target -Filter 'zstd.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $exe) {
        $zip = Join-Path $tools "zstd-v$ZstdVersion-win64.zip"
        Get-VerifiedFile $ZstdZipUrl $zip 'SHA256' $ZstdZipSha256
        Expand-Archive -Path $zip -DestinationPath $tools -Force
        $exe = Get-ChildItem -Path $target -Filter 'zstd.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if (-not $exe) { throw 'zstd archive did not contain zstd.exe' }
    return $exe.FullName
}

$python = Ensure-Python
$fastboot = Ensure-PlatformTools
$zstd = Ensure-Zstd
$env:FASTBOOT = $fastboot
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:PATH = ((Split-Path -Parent $zstd) + ';' + (Split-Path -Parent $fastboot) + ';' +
    (Split-Path -Parent $python) + ';' + $env:PATH)

if (-not $Arguments -or $Arguments.Count -eq 0) {
    $Arguments = @('doctor')
}

Write-Host "Using Python: $python"
Write-Host "Using fastboot: $fastboot"
Write-Host "Using zstd: $zstd"
& $python $entry @Arguments
exit $LASTEXITCODE
