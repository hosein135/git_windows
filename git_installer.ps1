#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

Write-Host "Starting installation script for prerequisites, Git, and TortoiseGit..." -ForegroundColor Cyan

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

function Refresh-ProcessPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
}

function Ensure-MachinePathEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if (!(Test-Path $TargetPath)) { return }

    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $machinePath -split ';' | Where-Object { $_ -ne '' }
    if ($parts -contains $TargetPath) { return }

    $newPath = ($parts + $TargetPath) -join ';'
    [System.Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    Write-Host "Added to system PATH: $TargetPath" -ForegroundColor DarkCyan
}

function Set-GitIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [Parameter(Mandatory = $true)]
        [string]$UserEmail
    )

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        Write-Warning 'Git was not found on PATH; skipping user.name / user.email configuration.'
        return
    }

    & git config --global user.name $UserName
    & git config --global user.email $UserEmail
    Write-Host "Configured git identity: $UserName <$UserEmail>" -ForegroundColor Green
}

function Test-WingetUsable {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    try {
        $null = & winget --version 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Install-WingetIfPossible {
    if (Test-WingetUsable) {
        Write-Host "WinGet is already installed: $(& winget --version)" -ForegroundColor Green
        return $true
    }

    # Package can be installed while 'winget' still has no App Execution Alias (common on Server 2019).
    $desktopAppInstaller = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
    if ($desktopAppInstaller) {
        Write-Host "Desktop App Installer $($desktopAppInstaller.Version) is installed, but 'winget' is not callable." -ForegroundColor Yellow
        Write-Host "This is common on Windows Server 2019 (no App Execution Aliases). Falling back to direct downloads." -ForegroundColor Yellow
        return $false
    }

    Write-Host "WinGet not usable. Attempting bootstrap (may fail on Windows Server 2019)..." -ForegroundColor Yellow

    $progressPreference = 'silentlyContinue'
    $tempDir = Join-Path $env:TEMP 'winget-bootstrap'
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    try {
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
        Add-AppxProvisionedPackage -Online -PackagePath $wingetBundle -LicensePath $licensePath -ErrorAction Stop | Out-Null
        Install-AppxQuietly -PackagePath $wingetBundle

        # Ensure WindowsApps is on PATH for app-execution aliases (client Windows)
        $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
        Refresh-ProcessPath
        if ((Test-Path $windowsApps) -and ($env:Path -notlike "*$windowsApps*")) {
            $env:Path += ";$windowsApps"
        }

        if (Test-WingetUsable) {
            Write-Host "WinGet installed successfully: $(& winget --version)" -ForegroundColor Green
            return $true
        }

        Write-Host "Desktop App Installer is present, but 'winget' is not callable in this session." -ForegroundColor Yellow
        Write-Host "Falling back to direct downloads." -ForegroundColor Yellow
        return $false
    } catch {
        Write-Host "WinGet bootstrap failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Falling back to direct downloads." -ForegroundColor Yellow
        return $false
    } finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NativeInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    Write-Host "Running installer: $DisplayName..." -ForegroundColor Yellow
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
    # Many installers return 0 (success) or 3010 (success, reboot required)
    if ($proc.ExitCode -notin 0, 3010) {
        throw "$DisplayName failed with exit code $($proc.ExitCode)"
    }
    if ($proc.ExitCode -eq 3010) {
        Write-Host "$DisplayName installed (reboot recommended)." -ForegroundColor DarkCyan
    } else {
        Write-Host "$DisplayName installed successfully." -ForegroundColor Green
    }
}

function Install-ViaDirectDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitVersion,
        [Parameter(Mandatory = $true)]
        [string]$TortoiseVer
    )

    $progressPreference = 'silentlyContinue'
    $tempDir = Join-Path $env:TEMP 'git-direct-install'
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    try {
        $vcRedist = Join-Path $tempDir 'vc_redist.x64.exe'
        $gitSetup = Join-Path $tempDir "Git-$GitVersion-64-bit.exe"
        $tortoiseMsi = Join-Path $tempDir "TortoiseGit-$TortoiseVer-64bit.msi"

        Write-Host "Downloading Microsoft Visual C++ Redistributable..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $vcRedist -UseBasicParsing
        Invoke-NativeInstaller -FilePath $vcRedist -ArgumentList @('/install', '/quiet', '/norestart') -DisplayName 'VC++ Redistributable'

        Write-Host "Downloading Git for Windows v$GitVersion..." -ForegroundColor Yellow
        $gitUrl = "https://github.com/git-for-windows/git/releases/download/v$GitVersion.windows.1/Git-$GitVersion-64-bit.exe"
        Invoke-WebRequest -Uri $gitUrl -OutFile $gitSetup -UseBasicParsing
        # Silent Git for Windows install with common defaults
        Invoke-NativeInstaller -FilePath $gitSetup -ArgumentList @(
            '/VERYSILENT',
            '/NORESTART',
            '/NOCANCEL',
            '/SP-',
            '/CLOSEAPPLICATIONS',
            '/RESTARTAPPLICATIONS',
            '/COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh'
        ) -DisplayName "Git for Windows v$GitVersion"

        Write-Host "Downloading TortoiseGit v$TortoiseVer..." -ForegroundColor Yellow
        $tortoiseUrl = "https://download.tortoisegit.org/tgit/$TortoiseVer/TortoiseGit-$TortoiseVer-64bit.msi"
        Invoke-WebRequest -Uri $tortoiseUrl -OutFile $tortoiseMsi -UseBasicParsing
        Invoke-NativeInstaller -FilePath 'msiexec.exe' -ArgumentList @(
            '/i', $tortoiseMsi,
            '/qn',
            '/norestart'
        ) -DisplayName "TortoiseGit v$TortoiseVer"
    } finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-ViaWinget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitVersion,
        [Parameter(Mandatory = $true)]
        [string]$TortoiseVer
    )

    $vcRedistId    = 'Microsoft.VCRedist.2015+.x64'
    $gitId         = 'Git.Git'
    $tortoiseGitId = 'TortoiseGit.TortoiseGit'

    Write-Host "Installing prerequisite: Microsoft Visual C++ Redistributable..." -ForegroundColor Yellow
    winget install --id $vcRedistId --exact --accept-source-agreements --accept-package-agreements --silent

    Write-Host "Installing prerequisite: Git for Windows (v$GitVersion)..." -ForegroundColor Yellow
    winget install --id $gitId --version $GitVersion --exact --accept-source-agreements --accept-package-agreements

    Write-Host "Installing TortoiseGit (v$TortoiseVer)..." -ForegroundColor Yellow
    winget install --id $tortoiseGitId --version $TortoiseVer --exact --accept-source-agreements --accept-package-agreements
}

## Versions
$gitVersion    = '2.45.0'
$tortoiseVer   = '2.16.0.0'

## Git identity (edit these before running)
$gitUserName  = 'Their Name'
$gitUserEmail = 'their@email.com'

## 1. Prefer WinGet when it actually works; otherwise use direct downloads
$useWinget = Install-WingetIfPossible
Refresh-ProcessPath

if ($useWinget) {
    Install-ViaWinget -GitVersion $gitVersion -TortoiseVer $tortoiseVer
} else {
    Install-ViaDirectDownload -GitVersion $gitVersion -TortoiseVer $tortoiseVer
}

## 2. Ensure Git/TortoiseGit are on system PATH and this session
$commonPaths = @(
    'C:\Program Files\Git\cmd',
    'C:\Program Files\Git\bin',
    'C:\Program Files\TortoiseGit\bin'
)
foreach ($targetPath in $commonPaths) {
    Ensure-MachinePathEntry -TargetPath $targetPath
}
Refresh-ProcessPath
foreach ($targetPath in $commonPaths) {
    if ((Test-Path $targetPath) -and ($env:Path -notlike "*$targetPath*")) {
        $env:Path += ";$targetPath"
        Write-Host "Added to session path: $targetPath" -ForegroundColor DarkCyan
    }
}

## 3. Configure global Git username / email
Set-GitIdentity -UserName $gitUserName -UserEmail $gitUserEmail

## 4. Verification
Write-Host "`nVerifying installations in current session:" -ForegroundColor Cyan
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "-> Git version: $(git --version)" -ForegroundColor Green
    Write-Host "-> Git user.name:  $(git config --global user.name)" -ForegroundColor Green
    Write-Host "-> Git user.email: $(git config --global user.email)" -ForegroundColor Green
} else {
    Write-Warning 'Git command could not be found directly. Try restarting your terminal.'
}

if (Get-Command TortoiseGitProc -ErrorAction SilentlyContinue) {
    Write-Host '-> TortoiseGit is successfully installed and available.' -ForegroundColor Green
} else {
    Write-Host '-> TortoiseGit installed. (Note: TortoiseGit is a shell extension/GUI wrapper; verify via right-click context menu or TortoiseGitProc).' -ForegroundColor Green
}

Write-Host "`nSetup complete! Please restart your terminal/PowerShell window if any paths fail to resolve." -ForegroundColor Cyan
