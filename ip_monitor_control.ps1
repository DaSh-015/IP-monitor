$MonitorScript = Join-Path $PSScriptRoot "ip_monitor.ps1"
if (-not (Test-Path $MonitorScript)) {
    Clear-Host
	Write-Host "ip_monitor.ps1 not found in $PSScriptRoot" -ForegroundColor Red
    Start-Sleep 10
    exit
}

$MutexName = "Global\IpMonitorSingleInstance"

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

while ($true) {
    Clear-Host
    Write-Host "===== IP Monitor Control ====="
	Write-Host ""
    Show-Status
	Write-Host ""
    Write-Host "1) Start"
    Write-Host "2) Stop"
    Write-Host ""
    $choice = Read-Host "Select option"

    switch ($choice) {
        "1" { Start-Monitor }
        "2" { Stop-Monitor }
        default { Write-Host "Invalid choice"; Start-Sleep -Seconds 1 }
    }
}