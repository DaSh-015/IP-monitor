# --- settings ---
$Processes = @("discord", "spotify", "aces", "wtrti")   # names without .exe
$PollSeconds = 10
$FlushSummarySeconds = 60
$OutDir = $PSScriptRoot
$RawDir = Join-Path $OutDir "raw"
$LogRaw = Join-Path $RawDir "ips_raw.log"
$SummaryCsv = Join-Path $OutDir "ip_summary.csv"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $RawDir | Out-Null

# key: "process|ip"
$stats = @{}  # value: PSCustomObject { Process, IP, Hits, FirstSeen, LastSeen }

# process -> poll count (how many iterations the process was observed running)
$procPolls = @{}

$lastFlush = Get-Date

function IsIPv4($s) {
    return ($s -match "^\d+\.\d+\.\d+\.\d+$")
}

# --- single instance guard (named mutex) ---
$MutexName = "Global\IpMonitorSingleInstance"
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$hasHandle = $false

try {
    # wait 0 ms: if already running, exit immediately
    $hasHandle = $mutex.WaitOne(0, $false)
    if (-not $hasHandle) {
        exit
    }
	while ($true) {
		$now = Get-Date

		foreach ($p in $Processes) {
			$procs = Get-Process -Name $p -ErrorAction SilentlyContinue
			foreach ($proc in $procs) {
				$procId = $proc.Id
				if (-not $procPolls.ContainsKey($p)) { $procPolls[$p] = 0 }
				$procPolls[$p] += 1

				$tcp = Get-NetTCPConnection -OwningProcess $procId -ErrorAction SilentlyContinue
				$udp = Get-NetUDPEndpoint -OwningProcess $procId -ErrorAction SilentlyContinue

				$ips = @()
				if ($tcp) { $ips += $tcp.RemoteAddress }
				if ($udp) { $ips += $udp.RemoteAddress }

				foreach ($ip in $ips) {
					if (!(IsIPv4 $ip)) { continue }
					if ($ip -eq "127.0.0.1" -or $ip -eq "0.0.0.0") { continue }

					# raw log (timestamp, process, ip)
					"$($now.ToString('yyyy-MM-dd HH:mm:ss'))`t$p`t$ip" | Out-File -Append -FilePath $LogRaw

					# unique list per process (file: unique_<process>.txt)
					$uniqueFile = Join-Path $RawDir ("unique_{0}.txt" -f $p)
					if (-not (Test-Path $uniqueFile)) {
						New-Item -ItemType File -Path $uniqueFile | Out-Null
					}
					if (-not (Select-String -Path $uniqueFile -Pattern "^$([regex]::Escape($ip))$" -Quiet -ErrorAction SilentlyContinue)) {
						$ip | Out-File -Append -FilePath $uniqueFile
					}

					# stats per (process, ip)
					$key = "$p|$ip"
					if (-not $stats.ContainsKey($key)) {
						$stats[$key] = [pscustomobject]@{
							Process   = $p
							IP        = $ip
							Hits      = 1
							FirstSeen = $now
							LastSeen  = $now
						}
					} else {
						$stats[$key].Hits += 1
						$stats[$key].LastSeen = $now
					}
				}
			}
		}

		# flush summary periodically
		if (($now - $lastFlush).TotalSeconds -ge $FlushSummarySeconds) {
			$rows = foreach ($kv in $stats.GetEnumerator()) {
				$s = $kv.Value
				$spanMin = [math]::Max(0.001, ($s.LastSeen - $s.FirstSeen).TotalMinutes)
				$polls = if ($procPolls.ContainsKey($s.Process)) { [int]$procPolls[$s.Process] } else { 0 }
				$share = if ($polls -gt 0) { [math]::Round($s.Hits / $polls, 6) } else { 0 }

				[pscustomobject]@{
					Process        = $s.Process
					IP             = $s.IP
					Hits           = $s.Hits
					Polls          = $polls
					Share          = $share
					FirstSeen      = $s.FirstSeen.ToString("yyyy-MM-dd HH:mm:ss")
					LastSeen       = $s.LastSeen.ToString("yyyy-MM-dd HH:mm:ss")
					SeenMinutes    = [math]::Round(($s.LastSeen - $s.FirstSeen).TotalMinutes, 3)
					HitsPerMinute  = [math]::Round($s.Hits / $spanMin, 3)
				}
			}

			$rows |
			Sort-Object Process, Hits -Descending |
			Export-Csv -NoTypeInformation -Encoding UTF8 -Path $SummaryCsv

			$lastFlush = $now
		}

		Start-Sleep -Seconds $PollSeconds
	}
}
finally {
    if ($hasHandle) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}