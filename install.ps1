param(
    [string]$Repo = $env:SKILL_INSTALL_REPO,
    [string]$Version = $env:SKILL_VERSION,
    [string]$InstallDir = $env:SKILL_INSTALL_DIR,
    [string]$CurrentVersion = $env:SKILL_CURRENT_VERSION
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

if ($Version -eq "latest" -and -not [string]::IsNullOrWhiteSpace($CurrentVersion)) {
    try {
        $ApiUrl = "https://api.github.com/repos/$Repo/releases/latest"
        $Release = Invoke-RestMethod -Uri $ApiUrl -Headers @{ "User-Agent" = "skill-updater" }
        $LatestVersion = $Release.tag_name.TrimStart("v")
        if ([Version]$CurrentVersion -ge [Version]$LatestVersion) {
            Write-Host "skill $CurrentVersion is already up to date"
            exit 0
        }
        Write-Host "Updating skill $CurrentVersion -> $LatestVersion..."
    } catch {
        Write-Host "Warning: could not check latest version, proceeding with update..."
    }
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

    Write-Host "Downloading $Archive..."
    Invoke-WebRequest -Uri "$BaseUrl/$Archive" -OutFile $ArchivePath
    Write-Host "Downloading checksums..."
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

    $Target = Join-Path $InstallDir "skill.exe"
    $OldExe = Join-Path $InstallDir "skill.exe.old"
    if (Test-Path $OldExe) { Remove-Item $OldExe -Force -ErrorAction SilentlyContinue }
    if (Test-Path $Target) { Rename-Item -Path $Target -NewName "skill.exe.old" -Force }
    Copy-Item -Path $BinaryPath -Destination $Target -Force
    Remove-Item $OldExe -Force -ErrorAction SilentlyContinue

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
