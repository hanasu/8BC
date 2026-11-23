# DEBUG (game-tests-debug only): runs a test file N times directly (not through
# the runner, so DEBUG lines print), with per-iteration EBC_DEBUG_LOG traces.
# Prints each run's wall time and result lines, and the full trace for a run
# with a FAIL or a hang. A run past -FileTimeout dumps the file and its children.
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string[]]$Tree = @(''),
    [int]$Iterations = 10,
    [int]$FileTimeout = 400
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Process -Id $PID).Path
$logRoot = Join-Path $repo 'build/debug-logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$times = @()
$bad = 0
for ($i = 1; $i -le $Iterations; $i++) {
    foreach ($t in $Tree) {
        $tag = '{0}-{1}-{2}' -f ([IO.Path]::GetFileNameWithoutExtension($File)), $(if ($t) { $t } else { 'pair' }), $i
        $log = Join-Path $logRoot "$tag.log"
        $priv = Join-Path ([IO.Path]::GetTempPath()) "dbg-$tag"
        New-Item -ItemType Directory -Force -Path $priv | Out-Null
        $psi = [Diagnostics.ProcessStartInfo]::new($pwsh)
        $a = @('-NoProfile', '-File', (Join-Path $repo $File))
        if ($t) { $a += @('-Tree', $t, '-VpmZip', (Join-Path $repo "src/$t/build/game-tests/eballchp.zip")) }
        foreach ($x in $a) { $psi.ArgumentList.Add($x) }
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $repo
        $psi.Environment['EBC_DEBUG_LOG'] = $log
        $psi.Environment['EBC_PRIVATE_DIR'] = $priv
        $psi.Environment['NO_COLOR'] = '1'
        $psi.Environment['EBC_BUILT_TREES'] = 'originals,loop-score-change,8bc-deluxe'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $p = [Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        $hung = $false
        if (-not $p.WaitForExit($FileTimeout * 1000)) {
            $hung = $true
            "DEBUG-LOOP $tag file still running after $FileTimeout s; dumping it and its children"
            $ids = @($p.Id)
            if ($IsLinux) { $ids += @((& ps -o pid= --ppid $p.Id) -split '\s+' | Where-Object { $_ } | ForEach-Object { [int]$_ }) }
            elseif ($IsWindows) { $ids += @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" | ForEach-Object { [int]$_.ProcessId }) }
            foreach ($id in $ids) { & (Join-Path $PSScriptRoot 'Debug-Dump.ps1') -ProcessId $id }
            $p.Kill($true)
        }
        $p.WaitForExit()
        $sec = $clock.Elapsed.TotalSeconds
        $out = @(); try { if ($o.Wait(10000)) { $out = @($o.Result -split "`r?`n") } } catch { }
        $err = @(); try { if ($e.Wait(10000)) { $err = @($e.Result -split "`r?`n") } } catch { }
        $fails = @($out | Where-Object { $_ -like 'FAIL *' })
        $code = if ($hung) { 'hung' } else { $p.ExitCode }
        $times += [PSCustomObject]@{ Tag = $tag; Seconds = $sec; Code = $code; Fails = $fails.Count }
        'DEBUG-LOOP {0} {1:N1} s exit {2} fails {3}' -f $tag, $sec, $code, $fails.Count
        $out | Where-Object { $_ -match '^(FAIL|DEBUG|INFO) ' } | ForEach-Object { "  $_" }
        if ($hung -or $fails.Count) {
            $bad++
            '  --- stdout (non-result lines)'; $out | Where-Object { $_ -and $_ -notmatch '^(PASS|FAIL|INFO|DEBUG) ' } | Select-Object -First 1500 | ForEach-Object { "  $_" }
            '  --- stderr'; $err | Where-Object { $_ } | Select-Object -Last 40 | ForEach-Object { "  $_" }
            "  --- trace $log"
            if (Test-Path $log) { Get-Content $log | Where-Object { $_ -notmatch ' hb ' -or $_ -match 'stopping=True' -or $_ -match 'paused=False' } | Select-Object -Last 400 | ForEach-Object { "  $_" } }
        }
        Remove-Item -LiteralPath $priv -Recurse -Force -ErrorAction SilentlyContinue
    }
}
"DEBUG-LOOP summary for ${File}: $bad bad of $($times.Count) runs"
$times | Sort-Object Seconds -Descending | Select-Object -First 10 | ForEach-Object { '  slowest {0} {1:N1} s {2}' -f $_.Tag, $_.Seconds, $_.Code }
