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
    Processes = @()

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

function Save-Config {
    param(
        [hashtable]$Config
    )

    $processes = @($Config.Processes | ForEach-Object { "'{0}'" -f ([string]$_).Replace("'", "''") })
    $outDir = ([string]$Config.OutDir).Replace("'", "''")

    $configContent = @(
        '@{'
        '    # process names without .exe'
        "    Processes = @($($processes -join ', '))"
        ''
        '    # process polling interval (sec)'
        "    PollSeconds = $([int]$Config.PollSeconds)"
        ''
        '    # summary file update interval (sec)'
        "    FlushSummarySeconds = $([int]$Config.FlushSummarySeconds)"
        ''
        '    # log unloading folder (empty = script folder)'
        "    OutDir = '$outDir'"
        '}'
    ) -join [Environment]::NewLine

    Set-Content -Path $ConfigPath -Value $configContent -Encoding UTF8
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

function Get-ProcessMonitorState {
    param(
        [string]$ProcessName
    )

    if ([string]::IsNullOrWhiteSpace($ProcessName)) {
        return $false
    }

    $normalizedName = ([string]$ProcessName).Trim()
    if ($normalizedName -match '(?i)\.exe$') {
        $normalizedName = $normalizedName.Substring(0, $normalizedName.Length - 4)
    }

    $matchedProcesses = Get-Process -Name $normalizedName -ErrorAction SilentlyContinue
    return $null -ne $matchedProcesses
}

function Normalize-ProcessName {
    param(
        [string]$ProcessName
    )

    if ([string]::IsNullOrWhiteSpace($ProcessName)) {
        return ""
    }

    $normalizedName = $ProcessName.Trim()
    if ($normalizedName -match '(?i)\.exe$') {
        $normalizedName = $normalizedName.Substring(0, $normalizedName.Length - 4)
    }

    return $normalizedName
}

function Show-ProcessStatus {
    param(
        [bool]$IsRunning
    )

    if ($IsRunning) {
        Write-Host "running" -ForegroundColor Green
    }
    else {
        Write-Host "not found" -ForegroundColor Red
    }
}

function Show-ProcessItemMenu {
    param(
        [int]$ProcessIndex
    )

    while ($true) {
        $config = Get-Config
        if ($null -eq $config) {
            return
        }

        $processes = @($config.Processes)
        if ($ProcessIndex -lt 0 -or $ProcessIndex -ge $processes.Count) {
            return
        }

        $processName = [string]$processes[$ProcessIndex]
        $isRunning = Get-ProcessMonitorState -ProcessName $processName

        Show-Header
        Write-Host ""
        Write-Host "Settings"
        Write-Host " - Processes"
        Write-Host "   - $processName " -NoNewline
        Show-ProcessStatus -IsRunning $isRunning
        Write-Host ""
        Write-Host "r) return"
        Write-Host "c) replace"
        Write-Host "d) delete"
        Write-Host ""

        $itemChoice = Read-Host "Select option"

        switch ($itemChoice.ToLowerInvariant()) {
            'r' { return }
            'c' {
                $replacement = Normalize-ProcessName -ProcessName (Read-Host "New process name")
                if ([string]::IsNullOrWhiteSpace($replacement)) {
                    Write-Host "Process name cannot be empty" -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }

                $existing = @($config.Processes)
                $hasDuplicate = $false
                for ($i = 0; $i -lt $existing.Count; $i++) {
                    if ($i -ne $ProcessIndex -and [string]$existing[$i] -eq $replacement) {
                        $hasDuplicate = $true
                        break
                    }
                }

                if ($hasDuplicate) {
                    Write-Host "Process already exists" -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    continue
                }

                $existing[$ProcessIndex] = $replacement
                $config.Processes = @($existing)
                Save-Config -Config $config
                continue
            }
            'd' {
                $updatedProcesses = New-Object System.Collections.ArrayList
                foreach ($proc in @($config.Processes)) {
                    [void]$updatedProcesses.Add($proc)
                }
                $updatedProcesses.RemoveAt($ProcessIndex)
                $config.Processes = @($updatedProcesses)
                Save-Config -Config $config
                return
            }
            default {
                Write-Host "Invalid choice" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-ProcessesMenu {
    while ($true) {
        $config = Get-Config
        if ($null -eq $config) {
            return
        }

        Show-Header
        Write-Host ""
        Write-Host "Settings"
        Write-Host " - Processes"
        Write-Host ""
        Write-Host "Processes under the monitor's supervision: $(@($config.Processes).Count)"
        Write-Host ""
        Write-Host "r) return"
        Write-Host "a) add process"
        Write-Host ""

        $index = 1
        foreach ($processName in @($config.Processes)) {
            Write-Host "$index) $processName - " -NoNewline
            Show-ProcessStatus -IsRunning (Get-ProcessMonitorState -ProcessName ([string]$processName))
            $index++
        }

        Write-Host ""
        $processChoice = Read-Host "Select option"
        $normalizedChoice = $processChoice.ToLowerInvariant()

        if ($normalizedChoice -eq 'r') {
            return
        }

        if ($normalizedChoice -eq 'a') {
            $newProcess = Normalize-ProcessName -ProcessName (Read-Host "Process name")
            if ([string]::IsNullOrWhiteSpace($newProcess)) {
                Write-Host "Process name cannot be empty" -ForegroundColor Red
                Start-Sleep -Seconds 1
                continue
            }

            if (@($config.Processes) -contains $newProcess) {
                Write-Host "Process already exists" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                continue
            }

            $config.Processes = @($config.Processes) + $newProcess
            Save-Config -Config $config
            continue
        }

        $selectedIndex = 0
        if ([int]::TryParse($processChoice, [ref]$selectedIndex)) {
            if ($selectedIndex -ge 1 -and $selectedIndex -le @($config.Processes).Count) {
                Show-ProcessItemMenu -ProcessIndex ($selectedIndex - 1)
                continue
            }
        }

        Write-Host "Invalid choice" -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
}

function Show-SettingsMenu {
    while ($true) {
        $config = Get-Config

        if ($null -eq $config) {
            Show-Header
            Write-Host ""
            Write-Host "Config file is corrupted." -ForegroundColor Red
            $recreate = Read-Host "Would you like to recreate it? (y/n)"

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
        Write-Host "4) Log dir: $([string]$config.OutDir)"
        Write-Host ""
        $settingsChoice = Read-Host "Select option"

        switch ($settingsChoice) {
            "r" { return }
            "R" { return }
            "1" { Show-ProcessesMenu }
            "2" {
                $pollInput = Read-Host "Process IP check interval (sec)"
                $pollSeconds = 0
                if (-not [int]::TryParse($pollInput, [ref]$pollSeconds) -or $pollSeconds -lt 1) {
                    Write-Host "Invalid value" -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }

                $config.PollSeconds = $pollSeconds
                Save-Config -Config $config
            }
            "3" {
                $summaryInput = Read-Host "ip_summary.csv update interval (sec)"
                $summarySeconds = 0
                if (-not [int]::TryParse($summaryInput, [ref]$summarySeconds) -or $summarySeconds -lt 1) {
                    Write-Host "Invalid value" -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }

                $config.FlushSummarySeconds = $summarySeconds
                Save-Config -Config $config
            }
            "4" { Write-Host "Option is not available yet"; Start-Sleep -Seconds 1 }
            default { Write-Host "Invalid choice" -ForegroundColor Red; Start-Sleep -Seconds 1 }
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
        default { Write-Host "Invalid choice" -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
