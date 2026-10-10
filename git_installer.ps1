#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

Write-Host "Starting installation script for WinGet, prerequisites, and TortoiseGit..." -ForegroundColor Cyan

function Install-AppxQuietly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath
    )

    try {
        Add-AppxPackage -Path $PackagePath -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -match '0x80073D06|0x80073CFB|already installed|higher version') {
            Write-Host "$(Split-Path $PackagePath -Leaf) is already present; continuing." -ForegroundColor DarkCyan
        } else {
            throw
        }
    }
}

## 1. CHECK AND INSTALL WINGET
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
$wingetNeedsRepair = $false
if ($wingetCmd) {
    try {
        $null = & winget --version 2>&1
        if ($LASTEXITCODE -ne 0) { $wingetNeedsRepair = $true }
    } catch {
        $wingetNeedsRepair = $true
    }
}

if ((-not $wingetCmd) -or $wingetNeedsRepair) {
    if ($wingetNeedsRepair) {
        Write-Host "WinGet is present but not licensed/usable. Repairing install..." -ForegroundColor Yellow
    } else {
        Write-Host "WinGet not found. Installing WinGet and its dependencies..." -ForegroundColor Yellow
    }

    $progressPreference = 'silentlyContinue'
    $tempDir = Join-Path $env:TEMP 'winget-bootstrap'
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    # Matching winget-cli release (installer + deps + license)
    $wingetTag = 'v1.29.380'
    $releaseBase = "https://github.com/microsoft/winget-cli/releases/download/$wingetTag"
    $depsZip = Join-Path $tempDir 'DesktopAppInstaller_Dependencies.zip'
    $depsDir = Join-Path $tempDir 'dependencies'
    $wingetBundle = Join-Path $tempDir 'Microsoft.DesktopAppInstaller.msixbundle'
    $licensePath = Join-Path $tempDir 'e53e159d00e04f729cc2180cffd1c02e_License1.xml'

    Write-Host "Downloading WinGet dependencies..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "$releaseBase/DesktopAppInstaller_Dependencies.zip" -OutFile $depsZip -UseBasicParsing
    if (Test-Path $depsDir) { Remove-Item $depsDir -Recurse -Force }
    Expand-Archive -Path $depsZip -DestinationPath $depsDir -Force

    $archDir = Join-Path $depsDir 'x64'
    if (!(Test-Path $archDir)) {
        throw "x64 dependency packages were not found in DesktopAppInstaller_Dependencies.zip"
    }

    Get-ChildItem -Path $archDir -Filter *.appx | ForEach-Object {
        Write-Host "Installing dependency: $($_.Name)..." -ForegroundColor Yellow
        Install-AppxQuietly -PackagePath $_.FullName
    }

    Write-Host "Downloading Desktop App Installer and license..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "$releaseBase/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile $wingetBundle -UseBasicParsing
    Invoke-WebRequest -Uri "$releaseBase/e53e159d00e04f729cc2180cffd1c02e_License1.xml" -OutFile $licensePath -UseBasicParsing

    Write-Host "Provisioning Desktop App Installer (WinGet) with license..." -ForegroundColor Yellow
    # Server/LTSC often need provisioned install + license; Add-AppxPackage alone leaves winget unlicensed
    Add-AppxProvisionedPackage -Online -PackagePath $wingetBundle -LicensePath $licensePath -ErrorAction Stop | Out-Null

    # Also register for the current user session
    Install-AppxQuietly -PackagePath $wingetBundle

    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if ($env:Path -notlike "*$windowsApps*") {
        $env:Path += ";$windowsApps"
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')

    # Resolve winget again after provisioning
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        throw "WinGet installed, but 'winget' is still not available. Open a new elevated PowerShell window and re-run this script."
    }

    try {
        $ver = & winget --version
        Write-Host "WinGet installed successfully: $ver" -ForegroundColor Green
    } catch {
        throw "WinGet is still not licensed/usable after provisioning. Reboot and re-run, or check AppX licensing policy."
    }
} else {
    Write-Host "WinGet is already installed: $(& winget --version)" -ForegroundColor Green
}

## 2. REFRESH POWERSHELL PATH FOR WINGET
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

## 3. INSTALL PREREQUISITES AND TORTOISEGIT WITH SPECIFIC VERSIONS
$gitVersion     = '2.45.0'
$vcRedistId     = 'Microsoft.VCRedist.2015+.x64'
$gitId          = 'Git.Git'
$tortoiseGitId  = 'TortoiseGit.TortoiseGit'
$tortoiseVer    = '2.16.0.0'

Write-Host "Installing prerequisite: Microsoft Visual C++ Redistributable..." -ForegroundColor Yellow
winget install --id $vcRedistId --exact --accept-source-agreements --accept-package-agreements --silent

Write-Host "Installing prerequisite: Git for Windows (v$gitVersion)..." -ForegroundColor Yellow
winget install --id $gitId --version $gitVersion --exact --accept-source-agreements --accept-package-agreements

Write-Host "Installing TortoiseGit (v$tortoiseVer)..." -ForegroundColor Yellow
winget install --id $tortoiseGitId --version $tortoiseVer --exact --accept-source-agreements --accept-package-agreements

## 4. UPDATE POWERSHELL ENVIRONMENT PATH
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

$commonPaths = @(
    'C:\Program Files\Git\cmd',
    'C:\Program Files\Git\bin',
    'C:\Program Files\TortoiseGit\bin'
)

foreach ($targetPath in $commonPaths) {
    if ((Test-Path $targetPath) -and ($env:Path -notlike "*$targetPath*")) {
        $env:Path += ";$targetPath"
        Write-Host "Added to session path: $targetPath" -ForegroundColor DarkCyan
    }
}

## 5. VERIFICATION
Write-Host "`nVerifying installations in current session:" -ForegroundColor Cyan
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "-> Git version: $(git --version)" -ForegroundColor Green
} else {
    Write-Warning 'Git command could not be found directly. Try restarting your terminal.'
}

if (Get-Command TortoiseGitProc -ErrorAction SilentlyContinue) {
    Write-Host '-> TortoiseGit is successfully installed and available.' -ForegroundColor Green
} else {
    Write-Host '-> TortoiseGit installed. (Note: TortoiseGit is a shell extension/GUI wrapper, verify via right-click context menu or TortoiseGitProc).' -ForegroundColor Green
}

Write-Host "`nSetup complete! Please restart your terminal/PowerShell window if any paths fail to resolve." -ForegroundColor Cyan