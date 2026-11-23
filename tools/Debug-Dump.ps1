# DEBUG (game-tests-debug only): prints the thread state of a hung process.
param([Parameter(Mandatory = $true)][int]$ProcessId)
$ErrorActionPreference = 'Continue'
"=== DUMP pid $ProcessId at $([DateTime]::UtcNow.ToString('HH:mm:ss.fff'))"
if ($IsLinux) {
    & ps -o pid,ppid,stat,etime,pcpu,cmd -p $ProcessId 2>&1
    & ps -o pid,ppid,stat,etime,pcpu,cmd --ppid $ProcessId 2>&1
    foreach ($t in (Get-ChildItem "/proc/$ProcessId/task" -ErrorAction SilentlyContinue)) {
        $d = "/proc/$ProcessId/task/$($t.Name)"
        $st = ((Get-Content "$d/stat" -Raw) -split '\) ', 2)[1].Split(' ')[0]
        "task $($t.Name) comm=$((Get-Content "$d/comm" -Raw).Trim()) state=$st wchan=$((Get-Content "$d/wchan" -Raw -ErrorAction SilentlyContinue))"
    }
    "--- gdb"
    & sudo gdb -p $ProcessId -batch -ex 'set pagination off' -ex 'info threads' -ex 'thread apply all bt 40' 2>&1 | Select-Object -First 700
}
elseif ($IsWindows) {
    $pr = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($pr) { $pr.Threads | ForEach-Object { "thread $($_.Id) $($_.ThreadState) wait=$(try { $_.WaitReason } catch { '-' }) cpu=$($_.TotalProcessorTime)" } }
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" | ForEach-Object { "child $($_.ProcessId) $($_.CommandLine)" }
    $cdb = @('C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe', 'C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($cdb) {
        "--- cdb $cdb"
        & $cdb -p $ProcessId -pv -c '.symfix;.reload;~*k 40;qd' 2>&1 | Select-Object -First 900
    }
    else { '--- no cdb found' }
}
'--- dotnet-stack'
& dotnet-stack report -p $ProcessId 2>&1 | Select-Object -First 400
"=== END DUMP pid $ProcessId"
