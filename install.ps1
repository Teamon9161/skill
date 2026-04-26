param(
    [string]$Repo = $env:SKILL_INSTALL_REPO,
    [string]$Version = $env:SKILL_VERSION,
    [string]$InstallDir = $env:SKILL_INSTALL_DIR
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = "Teamon9161/skill"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = "latest"
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\skill\bin"
}

$processor = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch -Regex ($processor) {
    "ARM64" { $Arch = "aarch64"; break }
    "AMD64|x86_64" { $Arch = "x86_64"; break }
    default {
        throw "unsupported architecture: $processor"
    }
}

$Archive = "skill-$Arch-windows.zip"
if ($Version -eq "latest") {
    $BaseUrl = "https://github.com/$Repo/releases/latest/download"
} else {
    if ($Version.StartsWith("v")) {
        $Tag = $Version
    } else {
        $Tag = "v$Version"
    }
    $BaseUrl = "https://github.com/$Repo/releases/download/$Tag"
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("skill-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir | Out-Null

try {
    $ArchivePath = Join-Path $TempDir $Archive
    $ChecksumsPath = Join-Path $TempDir "checksums.txt"

    Invoke-WebRequest -Uri "$BaseUrl/$Archive" -OutFile $ArchivePath
    Invoke-WebRequest -Uri "$BaseUrl/checksums.txt" -OutFile $ChecksumsPath

    $ChecksumLine = Get-Content $ChecksumsPath | Where-Object {
        ($_ -split "\s+")[-1] -eq $Archive
    } | Select-Object -First 1

    if (-not $ChecksumLine) {
        throw "checksum not found for $Archive"
    }

    $Expected = ($ChecksumLine -split "\s+")[0].ToLowerInvariant()
    $Actual = (Get-FileHash -Algorithm SHA256 $ArchivePath).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) {
        throw "checksum mismatch for $Archive"
    }

    Expand-Archive -Path $ArchivePath -DestinationPath $TempDir -Force
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    $BinaryPath = Join-Path $TempDir "skill.exe"
    if (-not (Test-Path $BinaryPath)) {
        throw "archive did not contain skill.exe"
    }

    Copy-Item -Path $BinaryPath -Destination (Join-Path $InstallDir "skill.exe") -Force

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $PathParts = @()
    if (-not [string]::IsNullOrWhiteSpace($UserPath)) {
        $PathParts = $UserPath -split ";"
    }

    if ($PathParts -notcontains $InstallDir) {
        $NewUserPath = if ([string]::IsNullOrWhiteSpace($UserPath)) {
            $InstallDir
        } else {
            "$UserPath;$InstallDir"
        }
        [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
    }

    if (($env:Path -split ";") -notcontains $InstallDir) {
        $env:Path = "$env:Path;$InstallDir"
    }

    Write-Host "skill installed to $(Join-Path $InstallDir "skill.exe")"
    Write-Host "Restart your terminal if skill is not found in PATH."
} finally {
    Remove-Item -LiteralPath $TempDir -Recurse -Force
}
