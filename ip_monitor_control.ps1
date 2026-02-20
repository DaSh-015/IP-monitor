$MonitorScript = Join-Path $PSScriptRoot "ip_monitor.ps1"
if (-not (Test-Path $MonitorScript)) {
    Clear-Host
	Write-Host "ip_monitor.ps1 not found in $PSScriptRoot" -ForegroundColor Red
    Start-Sleep 10
    exit
}

$MutexName = "Global\IpMonitorSingleInstance"
$ConfigPath = Join-Path $PSScriptRoot "ip_monitor_config.psd1"
$CorruptedConfigPath = Join-Path $PSScriptRoot "ip_monitor_config_corrupted.psd1"

function New-DefaultConfig {
    $defaultConfig = @'
@{
    # process names without .exe
    Processes = @("process1", "process2")

    # process polling interval (sec)
    PollSeconds = 10

    # summary file update interval (sec)
    FlushSummarySeconds = 60

    # log unloading folder (empty = script folder)
    OutDir = ""
}
'@

    Set-Content -Path $ConfigPath -Value $defaultConfig -Encoding UTF8
}

function Test-ConfigFormat {
    param(
        [hashtable]$Config
    )

    if ($null -eq $Config) { return $false }
    if (-not ($Config.ContainsKey("Processes") -and $Config.Processes -is [System.Collections.IEnumerable])) { return $false }
    if (-not ($Config.ContainsKey("PollSeconds") -and ($null -ne ($Config.PollSeconds -as [int])))) { return $false }
    if (-not ($Config.ContainsKey("FlushSummarySeconds") -and ($null -ne ($Config.FlushSummarySeconds -as [int])))) { return $false }
    if (-not ($Config.ContainsKey("OutDir") -and $Config.OutDir -is [string])) { return $false }

    return $true
}

function Get-Config {
    if (-not (Test-Path $ConfigPath)) {
        New-DefaultConfig
    }

    try {
        $config = Import-PowerShellDataFile -Path $ConfigPath -ErrorAction Stop
    }
    catch {
        return $null
    }

    if (-not (Test-ConfigFormat -Config $config)) {
        return $null
    }

    return $config
}

function Test-IsRunningByMutex {
    $m = New-Object System.Threading.Mutex($false, $MutexName)
    try {
        if ($m.WaitOne(0, $false)) {
            $m.ReleaseMutex()
            return $false
        } else {
            return $true
        }
    } finally {
        $m.Dispose()
    }
}

function Start-Monitor {
    if (Test-IsRunningByMutex) {
        Write-Host "IP Monitor is already RUNNING: " -ForegroundColor Red
		Start-Sleep -Seconds 1
        return
    }

    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$MonitorScript`""
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList $arg | Out-Null

    Start-Sleep -Milliseconds 400
}

function Stop-Monitor {
    $needle = [regex]::Escape($MonitorScript)

    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
             Where-Object { $_.CommandLine -and ($_.CommandLine -match $needle) }

    if (-not $procs) {
        return
    }

    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 400
}

function Show-Status {
    if (Test-IsRunningByMutex) {
        Write-Host "Status: " -NoNewline
        Write-Host "RUNNING" -ForegroundColor Green
    }
    else {
        Write-Host "Status: " -NoNewline
        Write-Host "NOT running" -ForegroundColor Red
    }
}

function Show-Header {
    Clear-Host
    Write-Host "===== IP Monitor Control ====="
}

function Show-SettingsMenu {
    while ($true) {
        $config = Get-Config

        if ($null -eq $config) {
            Show-Header
            Write-Host ""
            Write-Host "Сonfig file is corrupted." -ForegroundColor Red
            $recreate = Read-Host "Would you like to recreate it? (y/n):"

            if ($recreate -match "^[Yy]$") {
                if (Test-Path $CorruptedConfigPath) {
                    Remove-Item -Path $CorruptedConfigPath -Force
                }
                Rename-Item -Path $ConfigPath -NewName (Split-Path $CorruptedConfigPath -Leaf)
                New-DefaultConfig
                continue
            }
            else {
                Write-Host "Please, correct config file" -ForegroundColor Red
                Start-Sleep -Seconds 3
                return
            }
        }

        Show-Header
        Write-Host ""
        Write-Host "Settings"
        Write-Host ""
        Write-Host "r) return"
        Write-Host "1) Processes: $(@($config.Processes).Count)"
        Write-Host "2) Polling interval: $([int]$config.PollSeconds) sec"
        Write-Host "3) Summary interval: $([int]$config.FlushSummarySeconds) sec"
        Write-Host "4) log dir: $([string]$config.OutDir)"
        Write-Host ""
        $settingsChoice = Read-Host "Select option"

        switch ($settingsChoice) {
            "r" { return }
            "R" { return }
            "1" { Write-Host "Option is not available yet"; Start-Sleep -Seconds 1 }
            "2" { Write-Host "Option is not available yet"; Start-Sleep -Seconds 1 }
            "3" { Write-Host "Option is not available yet"; Start-Sleep -Seconds 1 }
            "4" { Write-Host "Option is not available yet"; Start-Sleep -Seconds 1 }
            default { Write-Host "Invalid choice"; Start-Sleep -Seconds 1 }
        }
    }
}

while ($true) {

    Show-Header
	Write-Host ""
    Show-Status
	Write-Host ""
    Write-Host "1) Start"
    Write-Host "2) Stop"
    Write-Host "3) Settings"
    Write-Host ""
    $choice = Read-Host "Select option"

    switch ($choice) {
        "1" { Start-Monitor }
        "2" { Stop-Monitor }
        "3" { Show-SettingsMenu }
        default { Write-Host "Invalid choice"; Start-Sleep -Seconds 1 }
    }
}
