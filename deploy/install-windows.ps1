# Installs or updates watchman-agent on a Windows worker. deploy-windows.sh
# copies this script and watchman-agent.exe into the SSH user's home and
# runs it there; the session must be elevated (an administrator account).
param([string]$AgentHostname = "")

$ErrorActionPreference = "Stop"
$TaskName = "watchman-agent"
$InstallDir = Join-Path $env:ProgramFiles "watchman"
$Exe = Join-Path $InstallDir "watchman-agent.exe"
$Staged = Join-Path $PSScriptRoot "watchman-agent.exe"

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run as an administrator: the agent runs as SYSTEM from Program Files."
    exit 1
}

Write-Host "  Stopping existing agent..."
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName
}
Get-Process watchman-agent -ErrorAction SilentlyContinue | Stop-Process -Force
Wait-Process -Name watchman-agent -Timeout 10 -ErrorAction SilentlyContinue

# Program Files, not ProgramData: standard users can create files in
# ProgramData subfolders, so they could plant a DLL beside an exe that
# runs as SYSTEM.
Write-Host "  Copying binary to $Exe..."
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Move-Item -Force $Staged $Exe

Write-Host "  Registering scheduled task..."
$actionArgs = @{ Execute = $Exe }
if ($AgentHostname) {
    $actionArgs.Argument = "--hostname $AgentHostname"
}
$action = New-ScheduledTaskAction @actionArgs

# Start at boot, plus a clock trigger that re-runs the task every minute
# forever. IgnoreNew makes that a no-op while the agent is up, so a crashed
# agent is back within a minute, the closest Task Scheduler gets to systemd's
# Restart=always. The repeat can't hang off the boot trigger: that schedule
# only begins at the next boot, leaving a freshly installed agent unwatched.
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1))
)

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# A zero time limit disables Task Scheduler's default 72-hour kill.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal `
    -Settings $settings -Description "Watchman agent: system metrics over HTTP on port 8085" -Force | Out-Null

Write-Host "  Opening firewall for HTTP 8085 and mDNS on Private networks..."
foreach ($name in "watchman-agent-http", "watchman-agent-mdns") {
    Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
}
New-NetFirewallRule -Name "watchman-agent-http" -DisplayName "Watchman agent (HTTP 8085)" -Direction Inbound `
    -Protocol TCP -LocalPort 8085 -Program $Exe -Profile Private -Action Allow | Out-Null
New-NetFirewallRule -Name "watchman-agent-mdns" -DisplayName "Watchman agent (mDNS)" -Direction Inbound `
    -Protocol UDP -LocalPort 5353 -Program $Exe -Profile Private -Action Allow | Out-Null

Write-Host "  Starting agent..."
Start-ScheduledTask -TaskName $TaskName

# 127.0.0.1, not localhost: Windows resolves localhost to ::1 first, the
# agent listens on IPv4 only, and a refused connection is retried for
# about two seconds before any fallback, which outlasts the timeout.
Write-Host "  Verifying..."
$healthy = $false
foreach ($i in 1..10) {
    Start-Sleep -Seconds 1
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:8085/health" | Out-Null
        $healthy = $true
        break
    } catch {}
}

Remove-Item $PSCommandPath

if ($healthy) {
    Write-Host "  OK: $env:COMPUTERNAME is healthy"
} else {
    Write-Warning "$env:COMPUTERNAME health check failed (may need a moment to start)"
}
