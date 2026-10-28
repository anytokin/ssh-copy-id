<#
Simple installer for ssh-copy-id on Windows.

Usage (PowerShell):

    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
    irm https://raw.githubusercontent.com/anytokin/ssh-copy-id/main/install.ps1 | iex

Parameters:
    -InstallDir   Optional custom install directory
    -NoModifyPath Do not add the install directory to the user PATH
#>

param(
    [string]$InstallDir,
    [switch]$NoModifyPath
)

$ErrorActionPreference = "Stop"

# Configuration
$RepoOwner = "anytokin"
$RepoName  = "ssh-copy-id"

# GitHub API for latest release (used only for version detection)
$GitHubApiLatestUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"

# Where to download from: latest GitHub release asset
$DownloadUrl = "https://github.com/$RepoOwner/$RepoName/releases/latest/download/ssh-copy-id.exe"

$AppName    = "ssh-copy-id.exe"
$FolderName = "ssh-copy-id"

function Get-LatestGithubVersion {
    param(
        [string]$ApiUrl
    )

    try {
        $headers = @{ "User-Agent" = "ssh-copy-id-installer" }
        $response = Invoke-RestMethod -Uri $ApiUrl -Headers $headers

        $tag = $response.tag_name
        if (-not $tag) {
            return $null
        }

        $tag = $tag.Trim()
        if ($tag.StartsWith("v")) {
            $tag = $tag.Substring(1)
        }

        $clean = $tag.Split("-", 2)[0]

        return [version]$clean
    }
    catch {
        Write-Warning "Could not determine latest version from GitHub: $($_.Exception.Message)"
        return $null
    }
}

function Get-InstalledSshCopyIdVersion {
    param(
        [string]$LocalExePath
    )

    # A copy elsewhere on PATH must not skip installation into InstallDir.
    if ($LocalExePath -and (Test-Path -LiteralPath $LocalExePath -PathType Leaf)) {
        try {
            $output = & $LocalExePath -v 2>$null | Out-String
            if ($output -match '(\d+\.\d+\.\d+)') {
                return [version]$Matches[1]
            }
        }
        catch {
            # An unreadable or broken local copy should be replaced.
        }
    }

    return $null
}

# Default install dir: %LOCALAPPDATA%\Programs\ssh-copy-id
if (-not $InstallDir) {
    if ($env:LOCALAPPDATA) {
        $InstallDir = Join-Path $env:LOCALAPPDATA ("Programs\" + $FolderName)
    }
    else {
        # Fallback: %USERPROFILE%\ssh-copy-id
        $InstallDir = Join-Path $env:USERPROFILE $FolderName
    }
}

# PATH entries must also work when a later terminal uses another directory.
$InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir)

Write-Host "Installing ssh-copy-id to: $InstallDir" -ForegroundColor Cyan

$ExePath = Join-Path $InstallDir $AppName

# Check versions
$latestVersion    = Get-LatestGithubVersion -ApiUrl $GitHubApiLatestUrl
$installedVersion = Get-InstalledSshCopyIdVersion -LocalExePath $ExePath
$downloadRequired = $true

if ($installedVersion -and $latestVersion) {
    if ($installedVersion -ge $latestVersion) {
        Write-Host "ssh-copy-id is already up to date (installed: $installedVersion, latest: $latestVersion)." -ForegroundColor Green
        $downloadRequired = $false
    }
    else {
        Write-Host "Updating ssh-copy-id from $installedVersion to $latestVersion..." -ForegroundColor Cyan
    }
}
elseif ($latestVersion) {
    Write-Host "Installing ssh-copy-id version $latestVersion..." -ForegroundColor Cyan
}
else {
    Write-Host "Installing latest ssh-copy-id (could not determine version from GitHub API)." -ForegroundColor Cyan
}

if ($downloadRequired) {
    # Download beside the executable so a failed update leaves it intact.
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $temporaryPath = Join-Path $InstallDir ([IO.Path]::GetRandomFileName())
    Write-Host "Downloading latest ssh-copy-id from GitHub..." -ForegroundColor Cyan

    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $temporaryPath -UseBasicParsing
        if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf) -or
            (Get-Item -LiteralPath $temporaryPath).Length -eq 0) {
            throw "The downloaded executable is empty."
        }
        Move-Item -LiteralPath $temporaryPath -Destination $ExePath -Force
    }
    catch {
        throw "Failed to download ssh-copy-id from ${DownloadUrl}: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    Write-Host "Downloaded to $ExePath" -ForegroundColor Green
}

# Optionally add to PATH
if (-not $NoModifyPath) {
    $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")

    $paths = $currentUserPath -split ";" | Where-Object { $_ -ne "" }

    if ($paths -notcontains $InstallDir) {
        $newPath = if ($currentUserPath) {
            "$InstallDir;$currentUserPath"
        }
        else {
            $InstallDir
        }

        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "Added '$InstallDir' to your user PATH." -ForegroundColor Green
        Write-Host "You may need to open a new terminal for changes to take effect." -ForegroundColor Yellow
    }
    else {
        Write-Host "Install directory is already on your PATH." -ForegroundColor DarkYellow
    }
}
else {
    Write-Host "Skipping PATH modification because -NoModifyPath was provided." -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "Done! You should now be able to run:" -ForegroundColor Green
Write-Host "    ssh-copy-id user@host" -ForegroundColor Green
