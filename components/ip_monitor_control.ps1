$ProgramRoot = Split-Path -Parent $PSScriptRoot
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

    # log unloading folder (empty = program folder)
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
        '    # log unloading folder (empty = program folder)'
        "    OutDir = '$outDir'"
        '}'
    ) -join [Environment]::NewLine

    Set-Content -Path $ConfigPath -Value $configContent -Encoding UTF8
}


function Save-ConfigAndRestart {
    param(
        [hashtable]$Config
    )
    Save-Config -Config $Config
	
    if (Test-IsRunningByMutex) {
		Write-ControlLifecycleEvent -Message "Restarting monitor process to apply settings..." -Level INFO
        Stop-Monitor
        Start-Monitor
    }
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

function Get-StopSignalPath {
    $config = Get-Config
    if ($null -eq $config) {
        return $null
    }

    $outDir = [string]$config.OutDir
    if ([string]::IsNullOrWhiteSpace($outDir)) {
        $outDir = $ProgramRoot
    }

    New-Item -ItemType Directory -Path $outDir -Force -ErrorAction SilentlyContinue | Out-Null
    return (Join-Path $outDir "ip_monitor.stop.signal")
}


function Get-LifecycleLogPath {
    $config = Get-Config
    if ($null -eq $config) {
        return (Join-Path $ProgramRoot "ip_monitor_lifecycle.log")
    }

    $outDir = [string]$config.OutDir
    if ([string]::IsNullOrWhiteSpace($outDir)) {
        $outDir = $ProgramRoot
    }

    New-Item -ItemType Directory -Path $outDir -Force -ErrorAction SilentlyContinue | Out-Null
    return (Join-Path $outDir "ip_monitor_lifecycle.log")
}

function Write-ControlLifecycleEvent {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $lifecycleLogPath = Get-LifecycleLogPath
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [$Level] $Message" | Out-File -FilePath $lifecycleLogPath -Append -Encoding UTF8
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
	
	Write-Host "Starting. Please wait..." -ForegroundColor Yellow
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$MonitorScript`""
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList $arg | Out-Null
	
    Start-Sleep -Seconds 1
}

function Stop-Monitor {
	Write-Host "Stopping. Please wait..." -ForegroundColor Yellow
    $stopReason = "by user from control script"
    $stopSignalPath = Get-StopSignalPath
    if ($stopSignalPath) {
        $stopReason | Out-File -FilePath $stopSignalPath -Encoding UTF8 -Force
    }

    $config = Get-Config
    $pollSeconds = 10
    if ($null -ne $config -and ($config.PollSeconds -as [int])) {
        $pollSeconds = [Math]::Max(1, [int]$config.PollSeconds)
    }
    $gracefulTimeoutSeconds = [Math]::Max(5, $pollSeconds + 2)

    $needle = [regex]::Escape($MonitorScript)

    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
             Where-Object { $_.CommandLine -and ($_.CommandLine -match $needle) }

    if (-not $procs) {
        Write-ControlLifecycleEvent -Message "Stop requested by user, but monitor process was not found." -Level WARN
        return
    }

    foreach ($p in $procs) {
        Wait-Process -Id $p.ProcessId -Timeout $gracefulTimeoutSeconds -ErrorAction SilentlyContinue

        if (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue) {
            Write-ControlLifecycleEvent -Message "Stop signal was sent by user, but monitor did not exit gracefully in $gracefulTimeoutSeconds sec. Forcing process stop (PID=$($p.ProcessId))." -Level WARN
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
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
        Write-Host "Settings > processes > $processName " -NoNewline
        Show-ProcessStatus -IsRunning $isRunning
        Write-Host ""
        Write-Host "1/c - replace"
        Write-Host "2/d - delete"
		Write-Host "0/r - return"
		Write-Host "h - main menu"
        Write-Host ""

        $itemChoice = Read-Host "Select option"
        $normalizedItemChoice = $itemChoice.ToLowerInvariant()

        if ($normalizedItemChoice -eq '1') {
            $normalizedItemChoice = 'c'
        }
        elseif ($normalizedItemChoice -eq '2') {
            $normalizedItemChoice = 'd'
        }
        elseif ($normalizedItemChoice -eq '0') {
            $normalizedItemChoice = 'r'
        }

        switch ($normalizedItemChoice) {
            'c' {
                $replacement = Normalize-ProcessName -ProcessName (Read-Host "New process name")
                if ([string]::IsNullOrWhiteSpace($replacement)) {
                    Write-Host "canceled" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 400
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
                Save-ConfigAndRestart -Config $config
                continue
            }
            'd' {
                $updatedProcesses = New-Object System.Collections.ArrayList
                foreach ($proc in @($config.Processes)) {
                    [void]$updatedProcesses.Add($proc)
                }
                $updatedProcesses.RemoveAt($ProcessIndex)
                $config.Processes = @($updatedProcesses)
                Save-ConfigAndRestart -Config $config
                return
            }
			'0' { return }
			'r' { return }
			'h' { return 'main' }
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
		Write-Host "Settings > processes"
        Write-Host "Processes under the monitor's supervision: $(@($config.Processes).Count)"
		Write-Host ""

        $index = 1
        foreach ($processName in @($config.Processes)) {
            Write-Host "$index - $processName " -NoNewline
            Show-ProcessStatus -IsRunning (Get-ProcessMonitorState -ProcessName ([string]$processName))
            $index++
        }
		
		Write-Host "$index/a - add process"
		Write-Host "clr - delete all processes"
		Write-Host "0/r - return"
		Write-Host "h - main menu"
        Write-Host ""
        $processChoice = Read-Host "Select option"
        $normalizedChoice = $processChoice.ToLowerInvariant()

        if ($normalizedChoice -eq $index -or $normalizedChoice -eq 'a') {
            $newProcess = Normalize-ProcessName -ProcessName (Read-Host "Process name")
            if ([string]::IsNullOrWhiteSpace($newProcess)) {
                Write-Host "canceled" -ForegroundColor Yellow
                Start-Sleep -Milliseconds 400
                continue
            }

            if (@($config.Processes) -contains $newProcess) {
                Write-Host "Process already exists" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                continue
            }

            $config.Processes = @($config.Processes) + $newProcess
            Save-ConfigAndRestart -Config $config
            continue
        }
		
		if ($normalizedChoice -eq 'clr') {
			$config.Processes = @()
			Save-ConfigAndRestart -Config $config
			continue
        }
		
        if ($normalizedChoice -eq '0' -or $normalizedChoice -eq 'r') {
            return
        }
		
		if ($normalizedChoice -eq 'h') {
			return 'main'
        }

        $selectedIndex = 0
        if ([int]::TryParse($processChoice, [ref]$selectedIndex)) {
            if ($selectedIndex -ge 1 -and $selectedIndex -le @($config.Processes).Count) {
                $itemResult = Show-ProcessItemMenu -ProcessIndex ($selectedIndex - 1)
                if ($itemResult -eq 'main') {
                    return 'main'
                }
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
        $displayOutDir = [string]$config.OutDir
        if ([string]::IsNullOrWhiteSpace($displayOutDir)) {
            $displayOutDir = "$ProgramRoot (same as program folder)"
        }
        Write-Host "1 - processes: $(@($config.Processes).Count)"
        Write-Host "2 - polling interval: $([int]$config.PollSeconds) sec"
        Write-Host "3 - summary interval: $([int]$config.FlushSummarySeconds) sec"
        Write-Host "4 - log dir: $displayOutDir"
        Write-Host "0/r - return"
        Write-Host ""
        $settingsChoice = Read-Host "Select option"

        switch ($settingsChoice) {
            "1" {
                $processesMenuResult = Show-ProcessesMenu
                if ($processesMenuResult -eq 'main') {
                    return
                }
            }
            "2" {
                $pollInput = Read-Host "Process IP check interval (sec)"
                $pollSeconds = 0
                if (-not [int]::TryParse($pollInput, [ref]$pollSeconds) -or $pollSeconds -lt 1) {
                    Write-Host "Invalid value" -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }

                $config.PollSeconds = $pollSeconds
                Save-ConfigAndRestart -Config $config
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
                Save-ConfigAndRestart -Config $config
            }
            "4" {
                $logDirInput = Read-Host 'Log unloading folder (enter "d" to select program folder)'
                if ([string]::IsNullOrWhiteSpace($logDirInput)) {
                    Write-Host "canceled" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 400
                    continue
                }

                if ($logDirInput.Trim().ToLowerInvariant() -eq 'd') {
                    $config.OutDir = ""
                    Save-ConfigAndRestart -Config $config
                    continue
                }

                $selectedPath = $logDirInput.Trim()
                if (-not (Test-Path -Path $selectedPath -PathType Container)) {
                    Write-Host "Invalid or inaccessible path" -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }

                try {
                    $resolvedPath = (Resolve-Path -Path $selectedPath -ErrorAction Stop).ProviderPath
                }
                catch {
                    Write-Host "Invalid or inaccessible path" -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }

                $config.OutDir = $resolvedPath
                Save-ConfigAndRestart -Config $config
            }
			"0" { return }
			"r" { return }
			"h" { return }
			
            default { Write-Host "Invalid choice" -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

while ($true) {

    Show-Header
	Write-Host ""
    Show-Status
	Write-Host ""
    Write-Host "1 - start"
    Write-Host "2 - stop"
    Write-Host "3 - settings"
	Write-Host "0 - refresh"
    Write-Host ""
    $choice = Read-Host "Select option"

    switch ($choice) {
        "1" { Start-Monitor }
        "2" { Stop-Monitor }
        "3" { Show-SettingsMenu }
		"0" {}
        default { Write-Host "Invalid choice" -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
