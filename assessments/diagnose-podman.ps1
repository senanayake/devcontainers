#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses Podman + Dev Containers setup on Windows for corporate environments.

.DESCRIPTION
    This script checks:
    - WSL installation and configuration
    - Podman installations (Desktop machine vs native WSL)
    - Socket availability and connectivity
    - Image stores and visibility
    - Registry/proxy configuration for corporate environments
    - VS Code settings recommendations

.NOTES
    Run from PowerShell on Windows (not inside WSL)
#>

param(
    [switch]$Verbose,
    [string]$ArtifactoryUrl = ""
)

$ErrorActionPreference = "Continue"
$script:issues = @()
$script:recommendations = @()

function Write-Header {
    param([string]$Text)
    Write-Host "`n$("=" * 60)" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "$("=" * 60)" -ForegroundColor Cyan
}

function Write-Check {
    param([string]$Name, [bool]$Passed, [string]$Details = "")
    $icon = if ($Passed) { "[OK]" } else { "[!!]" }
    $color = if ($Passed) { "Green" } else { "Red" }
    Write-Host "  $icon " -ForegroundColor $color -NoNewline
    Write-Host $Name -NoNewline
    if ($Details) {
        Write-Host " - $Details" -ForegroundColor Gray
    } else {
        Write-Host ""
    }
}

function Write-Info {
    param([string]$Text)
    Write-Host "      $Text" -ForegroundColor DarkGray
}

function Add-Issue {
    param([string]$Issue)
    $script:issues += $Issue
}

function Add-Recommendation {
    param([string]$Rec)
    $script:recommendations += $Rec
}

# ============================================================================
# SECTION 1: Windows Environment
# ============================================================================
Write-Header "1. Windows Environment"

# Check Windows version
$osInfo = Get-CimInstance Win32_OperatingSystem
$buildNumber = [int]$osInfo.BuildNumber
Write-Check "Windows Version" $true "$($osInfo.Caption) (Build $buildNumber)"

if ($buildNumber -lt 19041) {
    Add-Issue "Windows build $buildNumber is too old. WSL2 requires build 19041+"
}

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Check "Running as Administrator" $true $(if ($isAdmin) { "Yes" } else { "No (some checks may be limited)" })

# Check proxy environment variables
$httpProxy = $env:HTTP_PROXY
$httpsProxy = $env:HTTPS_PROXY
$noProxy = $env:NO_PROXY

if ($httpProxy -or $httpsProxy) {
    Write-Check "Proxy Detected" $true "HTTP_PROXY=$httpProxy"
    Write-Info "HTTPS_PROXY=$httpsProxy"
    Write-Info "NO_PROXY=$noProxy"
} else {
    Write-Check "Proxy Environment" $true "No proxy variables set (open internet or system proxy)"
}

# ============================================================================
# SECTION 2: WSL Status
# ============================================================================
Write-Header "2. WSL Installation"

# Check WSL installed
$wslInstalled = $false
$wslVersion = $null
try {
    $wslVersionOutput = wsl --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $wslInstalled = $true
        $wslVersion = ($wslVersionOutput | Select-String "WSL version" | Out-String).Trim()
    }
} catch {
    $wslInstalled = $false
}

Write-Check "WSL Installed" $wslInstalled $(if ($wslVersion) { $wslVersion } else { "Not found" })

if (-not $wslInstalled) {
    Add-Issue "WSL is not installed. Run: wsl --install"
    Write-Host "`n[FATAL] WSL not installed. Cannot continue diagnostics." -ForegroundColor Red
    exit 1
}

# List WSL distros
Write-Host "`n  WSL Distributions:" -ForegroundColor Yellow
$wslList = wsl -l -v 2>&1
$wslList | ForEach-Object { Write-Info $_ }

# Check for Podman machine distro
$hasPodmanMachine = $wslList | Select-String "podman-machine"
$hasUbuntu = $wslList | Select-String "Ubuntu"

# Check .wslconfig
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfigExists = Test-Path $wslConfigPath
$cgroupsV2Enabled = $false

if ($wslConfigExists) {
    $wslConfigContent = Get-Content $wslConfigPath -Raw
    $cgroupsV2Enabled = $wslConfigContent -match "cgroup_no_v1=all"
    Write-Check ".wslconfig exists" $true $wslConfigPath
    if ($cgroupsV2Enabled) {
        Write-Check "cgroups v2 enabled" $true "kernelCommandLine = cgroup_no_v1=all"
    } else {
        Write-Check "cgroups v2 enabled" $false "Missing cgroup_no_v1=all"
        Add-Recommendation "Add to $wslConfigPath under [wsl2]: kernelCommandLine = cgroup_no_v1=all"
    }
} else {
    Write-Check ".wslconfig exists" $false "File not found"
    Add-Recommendation "Create $wslConfigPath with:`n[wsl2]`nkernelCommandLine = cgroup_no_v1=all"
}

# ============================================================================
# SECTION 3: Podman Desktop Installation
# ============================================================================
Write-Header "3. Podman Desktop (Windows)"

# Check Podman CLI on Windows
$podmanWindows = $null
try {
    $podmanWindows = Get-Command podman -ErrorAction SilentlyContinue
} catch {}

if ($podmanWindows) {
    Write-Check "Podman CLI (Windows)" $true $podmanWindows.Source
    
    # Get Podman version
    $podmanVersion = podman --version 2>&1
    Write-Info "Version: $podmanVersion"
    
    # Check Podman machine status
    Write-Host "`n  Podman Machines:" -ForegroundColor Yellow
    $machineList = podman machine list 2>&1
    $machineList | ForEach-Object { Write-Info $_ }
    
    # Check if any machine is running
    $machineRunning = $machineList | Select-String "Running"
    Write-Check "Podman Machine Running" ($null -ne $machineRunning) $(if ($machineRunning) { "Yes" } else { "No machine running" })
    
    if (-not $machineRunning) {
        Add-Recommendation "Start Podman machine: podman machine start"
    }
    
    # Check Podman system connection
    Write-Host "`n  Podman Connections:" -ForegroundColor Yellow
    $connections = podman system connection list 2>&1
    $connections | ForEach-Object { Write-Info $_ }
    
    # Test Podman connectivity
    $podmanInfo = podman info 2>&1
    $podmanConnected = $LASTEXITCODE -eq 0
    Write-Check "Podman Connectivity" $podmanConnected $(if ($podmanConnected) { "Connected" } else { "Cannot connect to Podman" })
    
    if ($podmanConnected) {
        # List images in Windows Podman
        Write-Host "`n  Images in Podman Machine:" -ForegroundColor Yellow
        $images = podman images --format "{{.Repository}}:{{.Tag}}" 2>&1
        if ($images) {
            $images | ForEach-Object { Write-Info $_ }
        } else {
            Write-Info "(no images)"
        }
    }
} else {
    Write-Check "Podman CLI (Windows)" $false "Not found in PATH"
    Add-Issue "Podman not installed on Windows. Install Podman Desktop from https://podman-desktop.io"
}

# Check named pipe
$podmanPipe = "\\.\pipe\podman-machine-default"
$pipeExists = Test-Path $podmanPipe -ErrorAction SilentlyContinue
Write-Check "Podman Named Pipe" $pipeExists $podmanPipe

# ============================================================================
# SECTION 4: Podman in WSL (Native Installation)
# ============================================================================
Write-Header "4. Podman in WSL (Native)"

# Find WSL distros to check
$distrosToCheck = @()
if ($hasUbuntu) {
    $ubuntuDistro = ($wslList | Select-String "Ubuntu" | Select-Object -First 1).ToString().Trim() -replace '\s+.*', ''
    $ubuntuDistro = $ubuntuDistro -replace '^\*\s*', ''
    $distrosToCheck += $ubuntuDistro
}

foreach ($distro in $distrosToCheck) {
    if ([string]::IsNullOrWhiteSpace($distro)) { continue }
    
    Write-Host "`n  Checking distro: $distro" -ForegroundColor Yellow
    
    # Check if Podman is installed in this distro
    $podmanInWsl = wsl -d $distro -e which podman 2>&1
    $hasPodmanInWsl = $LASTEXITCODE -eq 0
    Write-Check "Podman installed in $distro" $hasPodmanInWsl $(if ($hasPodmanInWsl) { $podmanInWsl.Trim() } else { "Not found" })
    
    if ($hasPodmanInWsl) {
        # Check Podman version in WSL
        $wslPodmanVersion = wsl -d $distro -e podman --version 2>&1
        Write-Info "Version: $wslPodmanVersion"
        
        # Check systemd
        $systemdRunning = wsl -d $distro -e sh -c "ps -p 1 -o comm=" 2>&1
        $hasSystemd = $systemdRunning -match "systemd"
        Write-Check "systemd running" $hasSystemd $(if ($hasSystemd) { "Yes" } else { "No - PID 1 is $systemdRunning" })
        
        if (-not $hasSystemd) {
            Add-Recommendation "Enable systemd in $distro. Add to /etc/wsl.conf:`n[boot]`nsystemd=true`nThen: wsl --shutdown"
        }
        
        # Check Podman socket
        $userId = wsl -d $distro -e id -u 2>&1
        $socketPath = "/run/user/$userId/podman/podman.sock"
        $socketExists = wsl -d $distro -e test -S $socketPath 2>&1
        $hasSocket = $LASTEXITCODE -eq 0
        Write-Check "Podman socket exists" $hasSocket $socketPath
        
        if (-not $hasSocket -and $hasSystemd) {
            Add-Recommendation "Enable Podman socket in $distro (run WITHOUT sudo):`nsystemctl --user enable --now podman.socket"
        }
        
        # List images in WSL Podman
        Write-Host "`n  Images in WSL Podman ($distro):" -ForegroundColor Yellow
        $wslImages = wsl -d $distro -e podman images --format "{{.Repository}}:{{.Tag}}" 2>&1
        if ($LASTEXITCODE -eq 0 -and $wslImages) {
            $wslImages | ForEach-Object { Write-Info $_ }
        } else {
            Write-Info "(no images or cannot connect)"
        }
        
        # Check registries.conf
        $registriesConf = wsl -d $distro -e cat /etc/containers/registries.conf 2>&1
        if ($LASTEXITCODE -eq 0) {
            $hasUnqualified = $registriesConf | Select-String "unqualified-search-registries"
            Write-Check "registries.conf configured" $true "/etc/containers/registries.conf"
            
            # Check for mirrors (Artifactory)
            $hasMirror = $registriesConf | Select-String "mirror"
            if ($hasMirror) {
                Write-Info "Registry mirrors configured"
            }
        }
    }
}

# ============================================================================
# SECTION 5: VS Code Configuration
# ============================================================================
Write-Header "5. VS Code Configuration"

# Check VS Code installed
$vscode = Get-Command code -ErrorAction SilentlyContinue
Write-Check "VS Code installed" ($null -ne $vscode) $(if ($vscode) { $vscode.Source } else { "Not found" })

# Check VS Code settings
$vsCodeSettingsPath = Join-Path $env:APPDATA "Code\User\settings.json"
if (Test-Path $vsCodeSettingsPath) {
    Write-Check "VS Code settings.json" $true $vsCodeSettingsPath
    
    try {
        $settings = Get-Content $vsCodeSettingsPath -Raw | ConvertFrom-Json
        
        $dockerPath = $settings.'dev.containers.dockerPath'
        $dockerSocketPath = $settings.'dev.containers.dockerSocketPath'
        $dockerHost = $settings.'docker.host'
        
        Write-Host "`n  Current Dev Container Settings:" -ForegroundColor Yellow
        Write-Info "dev.containers.dockerPath: $(if ($dockerPath) { $dockerPath } else { '(not set - defaults to docker)' })"
        Write-Info "dev.containers.dockerSocketPath: $(if ($dockerSocketPath) { $dockerSocketPath } else { '(not set)' })"
        Write-Info "docker.host: $(if ($dockerHost) { $dockerHost } else { '(not set)' })"
        
        if ($dockerPath -ne "podman") {
            Add-Recommendation "Set VS Code setting: `"dev.containers.dockerPath`": `"podman`""
        }
    } catch {
        Write-Info "Could not parse settings.json"
    }
} else {
    Write-Check "VS Code settings.json" $false "File not found"
}

# ============================================================================
# SECTION 6: Corporate Environment Checks
# ============================================================================
Write-Header "6. Corporate Environment"

# Check for Artifactory connectivity
if ($ArtifactoryUrl) {
    Write-Host "`n  Testing Artifactory: $ArtifactoryUrl" -ForegroundColor Yellow
    try {
        $response = Invoke-WebRequest -Uri $ArtifactoryUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Check "Artifactory reachable" $true "HTTP $($response.StatusCode)"
    } catch {
        Write-Check "Artifactory reachable" $false $_.Exception.Message
        Add-Issue "Cannot reach Artifactory at $ArtifactoryUrl"
    }
}

# Check auth.json
$authJsonPath = Join-Path $env:USERPROFILE ".config\containers\auth.json"
if (Test-Path $authJsonPath) {
    Write-Check "Container auth.json" $true $authJsonPath
    try {
        $authJson = Get-Content $authJsonPath -Raw | ConvertFrom-Json
        $registries = $authJson.auths.PSObject.Properties.Name
        Write-Info "Configured registries: $($registries -join ', ')"
    } catch {
        Write-Info "Could not parse auth.json"
    }
} else {
    Write-Check "Container auth.json" $false "Not found (no registry logins)"
    Write-Info "Login to registries with: podman login <registry-url>"
}

# ============================================================================
# SECTION 7: Summary and Recommendations
# ============================================================================
Write-Header "7. Summary"

if ($script:issues.Count -eq 0) {
    Write-Host "`n  [OK] No critical issues found!" -ForegroundColor Green
} else {
    Write-Host "`n  Issues Found:" -ForegroundColor Red
    $script:issues | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}

if ($script:recommendations.Count -gt 0) {
    Write-Host "`n  Recommendations:" -ForegroundColor Yellow
    $i = 1
    $script:recommendations | ForEach-Object { 
        Write-Host "`n    $i. $_" -ForegroundColor Yellow
        $i++
    }
}

# Generate recommended VS Code settings
Write-Header "8. Recommended VS Code Settings"

$recommendedSettings = @"
// Add to your VS Code settings.json:
{
    "dev.containers.dockerPath": "podman",
"@

if ($pipeExists) {
    $recommendedSettings += @"

    "dev.containers.dockerSocketPath": "npipe:////./pipe/podman-machine-default"
"@
} elseif ($distrosToCheck.Count -gt 0 -and $hasSocket) {
    $recommendedSettings += @"

    "docker.host": "unix:///run/user/$userId/podman/podman.sock"
"@
}

$recommendedSettings += @"

}
"@

Write-Host $recommendedSettings -ForegroundColor Cyan

Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
Write-Host " Diagnostic complete. Run with -Verbose for more details." -ForegroundColor Cyan
Write-Host ("=" * 60) + "`n" -ForegroundColor Cyan
