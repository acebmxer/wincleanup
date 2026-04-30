#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 11 Disk Cleanup Script
.DESCRIPTION
    Cleans up Windows Update remnants, temp files, hibernation file,
    Delivery Optimization cache, and manages shadow copy storage.
    Self-elevates to Administrator if not already running elevated.
.NOTES
    Author  : PozzaTech
    Version : 1.0
    Tested  : Windows 11
#>

# ─────────────────────────────────────────────
#  SELF-ELEVATION
# ─────────────────────────────────────────────
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Not running as Administrator. Attempting to re-launch elevated..." -ForegroundColor Yellow
    $shell = if ($PSVersionTable.PSVersion.Major -ge 6) { "pwsh.exe" } else { "powershell.exe" }
    Start-Process -FilePath $shell `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`"" `
        -Verb RunAs
    exit
}

# ─────────────────────────────────────────────
#  HELPER FUNCTION
# ─────────────────────────────────────────────
function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-Status {
    param([string]$Message, [string]$Color = "White")
    Write-Host "  ► $Message" -ForegroundColor $Color
}

function Remove-ItemsSafely {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Cleaned: $Path" Green
        } catch {
            Write-Status "Partial clean (some files in use): $Path" Yellow
        }
    } else {
        Write-Status "Path not found, skipping: $Path" DarkGray
    }
}

# ─────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  ██╗    ██╗██╗███╗   ██╗ ██████╗██╗     ███████╗ █████╗ ███╗   ██╗" -ForegroundColor Cyan
Write-Host "  ██║    ██║██║████╗  ██║██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║" -ForegroundColor Cyan
Write-Host "  ██║ █╗ ██║██║██╔██╗ ██║██║     ██║     █████╗  ███████║██╔██╗ ██║" -ForegroundColor Cyan
Write-Host "  ██║███╗██║██║██║╚██╗██║██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║" -ForegroundColor Cyan
Write-Host "  ╚███╔███╔╝██║██║ ╚████║╚██████╗███████╗███████╗██║  ██║██║ ╚████║" -ForegroundColor Cyan
Write-Host "   ╚══╝╚══╝ ╚═╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Windows 11 Disk Cleanup Script  |  PozzaTech" -ForegroundColor White
Write-Host "  Running as: $env:USERNAME on $env:COMPUTERNAME" -ForegroundColor DarkGray
Write-Host ""

# ─────────────────────────────────────────────
#  PRE-FLIGHT: DISM HEALTH CHECK
# ─────────────────────────────────────────────
Write-Section "Step 1 of 6 — DISM Health Check"
Write-Status "Checking Windows image health before cleanup..."
$dismCheck = dism /online /cleanup-image /checkhealth 2>&1
if ($dismCheck -match "No component store corruption detected") {
    Write-Status "Image is healthy. Proceeding." Green
} else {
    Write-Status "DISM health check returned warnings — review output below:" Yellow
    Write-Host ($dismCheck | Out-String) -ForegroundColor DarkYellow
}

# ─────────────────────────────────────────────
#  STEP 2: DISM COMPONENT STORE CLEANUP
# ─────────────────────────────────────────────
Write-Section "Step 2 of 6 — Windows Update / Component Store Cleanup"
Write-Status "Running DISM component cleanup with /resetbase..."
Write-Status "This may take several minutes. Please wait." Yellow

dism /online /cleanup-image /startcomponentcleanup /resetbase | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Status "Component store cleanup completed successfully." Green
} else {
    Write-Status "DISM returned exit code $LASTEXITCODE — check Event Viewer if issues arise." Yellow
}

# ─────────────────────────────────────────────
#  STEP 3: TEMP FILES
# ─────────────────────────────────────────────
Write-Section "Step 3 of 6 — Temp File Cleanup"

# User temp
Remove-ItemsSafely -Path $env:TEMP

# Windows temp
Remove-ItemsSafely -Path "C:\Windows\Temp"

# Prefetch (safe to clear, Windows rebuilds it)
Remove-ItemsSafely -Path "C:\Windows\Prefetch"

# ─────────────────────────────────────────────
#  STEP 4: DELIVERY OPTIMIZATION CACHE
# ─────────────────────────────────────────────
Write-Section "Step 4 of 6 — Delivery Optimization Cache"
Write-Status "Clearing Delivery Optimization cache..."
try {
    Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
    Write-Status "Delivery Optimization cache cleared." Green
} catch {
    # Fallback for systems where the cmdlet isn't available
    Remove-ItemsSafely -Path "C:\Windows\SoftwareDistribution\DeliveryOptimization"
}

# Also clear SoftwareDistribution\Download (update downloads, safe after DISM cleanup)
Write-Status "Stopping Windows Update service to clear download cache..."
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-ItemsSafely -Path "C:\Windows\SoftwareDistribution\Download"
Start-Service -Name wuauserv -ErrorAction SilentlyContinue
Write-Status "Windows Update service restarted." Green

# ─────────────────────────────────────────────
#  STEP 5: HIBERNATION FILE
# ─────────────────────────────────────────────
Write-Section "Step 5 of 6 — Hibernation File (hiberfil.sys)"

$hibernateStatus = (powercfg /query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 2>&1)
$hibernateEnabled = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled

if ($hibernateEnabled -eq 1) {
    Write-Host ""
    Write-Host "  Hibernation is currently ENABLED." -ForegroundColor Yellow
    Write-Host "  Disabling it will delete hiberfil.sys and free ~12+ GiB." -ForegroundColor Yellow
    Write-Host "  Sleep/restart are NOT affected — only hibernate (Shut down > Hibernate)." -ForegroundColor DarkGray
    Write-Host ""
    $confirm = Read-Host "  Disable hibernation and reclaim disk space? (Y/N)"
    if ($confirm -match "^[Yy]$") {
        powercfg /hibernate off
        Write-Status "Hibernation disabled. hiberfil.sys removed." Green
    } else {
        Write-Status "Skipped — hibernation left enabled." DarkGray
    }
} else {
    Write-Status "Hibernation is already disabled. No action needed." DarkGray
}

# ─────────────────────────────────────────────
#  STEP 6: SHADOW COPY / SYSTEM RESTORE STORAGE
# ─────────────────────────────────────────────
Write-Section "Step 6 of 6 — Shadow Copy Storage (System Restore)"

$vssadmin = "$env:SystemRoot\System32\vssadmin.exe"
if (-not (Test-Path $vssadmin)) {
    Write-Status "vssadmin.exe not available on this system — skipping shadow copy management." Yellow
    Write-Status "(If unexpected, run: DISM /Online /Cleanup-Image /RestoreHealth, then sfc /scannow.)" DarkGray
} else {
    Write-Status "Current shadow storage allocation:"
    $shadowOutput = & $vssadmin list shadowstorage 2>&1
    $shadowLines  = $shadowOutput | Where-Object { $_ -match "Maximum|Used|Allocated" }

    if (-not $shadowLines) {
        Write-Status "No shadow storage configured for this volume — System Restore may be disabled." DarkGray
        Write-Status "Skipping shadow copy resize." DarkGray
    } else {
        $shadowLines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ""
        Write-Host "  Recommend capping shadow storage at 5 GiB to limit growth." -ForegroundColor Yellow
        $confirmVss = Read-Host "  Set maximum shadow copy storage to 5 GiB? (Y/N)"
        if ($confirmVss -match "^[Yy]$") {
            & $vssadmin resize shadowstorage /for=C: /on=C: /maxsize=5GB
            Write-Status "Shadow copy storage capped at 5 GiB." Green
        } else {
            Write-Status "Skipped — shadow copy storage unchanged." DarkGray
        }
    }
}

# ─────────────────────────────────────────────
#  BUILT-IN DISK CLEANUP (CLEANMGR)
# ─────────────────────────────────────────────
Write-Section "Bonus — Windows Disk Cleanup (cleanmgr)"
Write-Host ""
Write-Host "  Launching Disk Cleanup with all categories pre-selected." -ForegroundColor White
Write-Host "  Review selections and click OK to proceed." -ForegroundColor DarkGray
Write-Host ""

# Preset all cleanmgr flags via registry (StateFlags0001)
$cleanmgrKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
Get-ChildItem $cleanmgrKey | ForEach-Object {
    Set-ItemProperty -Path $_.PSPath -Name StateFlags0001 -Value 2 -Type DWord -ErrorAction SilentlyContinue
}

Start-Process -FilePath cleanmgr -ArgumentList "/sagerun:1" -Wait
Write-Status "Disk Cleanup completed." Green

# ─────────────────────────────────────────────
#  DONE
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Cleanup Complete!" -ForegroundColor Green
Write-Host "  A reboot is recommended to finalize changes." -ForegroundColor Green
Write-Host "═══════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

$reboot = Read-Host "  Reboot now? (Y/N)"
if ($reboot -match "^[Yy]$") {
    Restart-Computer -Force
} else {
    Write-Host "  Remember to reboot when convenient." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit"
}
