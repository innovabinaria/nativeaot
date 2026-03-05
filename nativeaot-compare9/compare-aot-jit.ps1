param(
  [string]$BaseDir = "path\nativeaot-compare9",
  [string]$ExeName = "HeavyApi9.exe",
  [int]$PortJit = 5077,
  [int]$PortAot = 5078,
  [int]$ColdRuns = 5,
  [int]$Requests = 200,
  [int]$Concurrency = 16,
  [int]$Mb = 32,
  [int]$Rounds = 400
)

$jitExe = Join-Path $BaseDir "out-jit9\$ExeName"
$aotExe = Join-Path $BaseDir "out-aot9\$ExeName"
$dataBin = Join-Path $BaseDir "data.bin"
$jitOut = Join-Path $BaseDir "out-jit9"
$aotOut = Join-Path $BaseDir "out-aot9"

function Assert-Path($p, $name) {
  if (-not (Test-Path $p)) { throw "No existe $($name): $p" }
}

function FolderSizeBytes([string]$path) {
  (Get-ChildItem $path -Recurse -File | Measure-Object -Sum Length).Sum
}

function Percentile([double[]]$sorted, [double]$p) {
  if ($sorted.Count -eq 0) { return [double]::NaN }
  $idx = [math]::Ceiling(($p/100) * $sorted.Count) - 1
  $idx = [math]::Max(0, [math]::Min($idx, $sorted.Count-1))
  return $sorted[$idx]
}

function Kill-ByExe([string]$exePath) {
  $full = (Resolve-Path $exePath).Path
  Get-CimInstance Win32_Process |
    Where-Object { $_.ExecutablePath -eq $full } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-App([string]$exePath, [int]$port) {
  $baseUrl = "http://localhost:$port"
  return Start-Process -FilePath $exePath -ArgumentList @("--urls", $baseUrl) -PassThru -WindowStyle Hidden
}

function Wait-Health([int]$port, [int]$maxMs = 20000) {
  $baseUrl = "http://localhost:$port"
  $url = "$baseUrl/health"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  while ($sw.ElapsedMilliseconds -lt $maxMs) {
    try {
      $r = Invoke-WebRequest -Uri $url -TimeoutSec 1
      if ($r.StatusCode -eq 200) { return $sw.Elapsed.TotalMilliseconds }
    } catch {}
    Start-Sleep -Milliseconds 50
  }
  return $null
}

function Measure-ColdStart([string]$exePath, [int]$port, [int]$runs) {
  $vals = New-Object System.Collections.Generic.List[double]

  for ($i=1; $i -le $runs; $i++) {
    Kill-ByExe $exePath

    $p = Start-App $exePath $port
    try {
      $t = Wait-Health $port 20000
      if ($t -ne $null) { $vals.Add($t) }
    } finally {
      try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
  }

  $arr = $vals.ToArray()
  [Array]::Sort($arr)

  return [pscustomobject]@{
    Runs = $arr.Length
    AvgMs = if ($arr.Length) { ($arr | Measure-Object -Average).Average } else { [double]::NaN }
    P50Ms = Percentile $arr 50
    P95Ms = Percentile $arr 95
  }
}

# --- C# helper para load test concurrente + memoria pico (evita runspace issues) ---
if (-not ("LoadTest" -as [type])) {
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class LoadTestResult
{
    public int Requests { get; set; }
    public int Concurrency { get; set; }
    public string Url { get; set; } = "";
    public double WallSeconds { get; set; }
    public double Rps { get; set; }
    public double AvgMs { get; set; }
    public double P50Ms { get; set; }
    public double P95Ms { get; set; }
    public double P99Ms { get; set; }
    public double PeakWorkingSetMB { get; set; }
    public double PeakPrivateMB { get; set; }
    public int Ok { get; set; }
    public int Fail { get; set; }
}

public static class LoadTest
{
    static double Percentile(double[] sorted, double p)
    {
        if (sorted.Length == 0) return double.NaN;
        var idx = (int)Math.Ceiling((p / 100.0) * sorted.Length) - 1;
        idx = Math.Max(0, Math.Min(idx, sorted.Length - 1));
        return sorted[idx];
    }

    public static LoadTestResult Run(string url, int requests, int concurrency, int pid, int timeoutSeconds)
    {
        var result = new LoadTestResult { Url = url, Requests = requests, Concurrency = concurrency };

        using var client = new HttpClient();
        client.Timeout = TimeSpan.FromSeconds(timeoutSeconds);

        // warmup
        //for (int i = 0; i < Math.Min(10, requests); i++)
        //{
          //  try { client.GetStringAsync(url).GetAwaiter().GetResult(); } catch { }
        //}

        var lat = new List<double>(requests);
        int ok = 0, fail = 0;

        using var sem = new SemaphoreSlim(concurrency, concurrency);

        long peakWs = 0, peakPriv = 0;
        var cts = new CancellationTokenSource();

        Task memTask = Task.Run(() =>
        {
            try
            {
                var proc = Process.GetProcessById(pid);
                while (!cts.Token.IsCancellationRequested)
                {
                    proc.Refresh();
                    peakWs = Math.Max(peakWs, proc.WorkingSet64);
                    peakPriv = Math.Max(peakPriv, proc.PrivateMemorySize64);
                    Thread.Sleep(50);
                }
            }
            catch { }
        });

        var swAll = Stopwatch.StartNew();

        var tasks = new Task[requests];
        for (int i = 0; i < requests; i++)
        {
            tasks[i] = Task.Run(async () =>
            {
                await sem.WaitAsync().ConfigureAwait(false);
                try
                {
                    var sw = Stopwatch.StartNew();
                    using var resp = await client.GetAsync(url).ConfigureAwait(false);
                    resp.EnsureSuccessStatusCode();
                    // leer body para “consumir” respuesta
                    _ = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    sw.Stop();

                    lock (lat) lat.Add(sw.Elapsed.TotalMilliseconds);
                    Interlocked.Increment(ref ok);
                }
                catch
                {
                    Interlocked.Increment(ref fail);
                }
                finally
                {
                    sem.Release();
                }
            });
        }

        Task.WaitAll(tasks);
        swAll.Stop();

        cts.Cancel();
        try { memTask.Wait(2000); } catch { }

        var arr = lat.ToArray();
        Array.Sort(arr);

        result.Ok = ok;
        result.Fail = fail;
        result.WallSeconds = Math.Max(0.001, swAll.Elapsed.TotalSeconds);
        result.Rps = requests / result.WallSeconds;

        result.AvgMs = arr.Length > 0 ? arr.Average() : double.NaN;
        result.P50Ms = Percentile(arr, 50);
        result.P95Ms = Percentile(arr, 95);
        result.P99Ms = Percentile(arr, 99);

        result.PeakWorkingSetMB = peakWs / (1024.0 * 1024.0);
        result.PeakPrivateMB = peakPriv / (1024.0 * 1024.0);

        return result;
    }
}
"@
}

function Load-And-Memory([string]$exePath, [int]$port, [int]$requests, [int]$concurrency, [int]$mb, [int]$rounds) {
  Kill-ByExe $exePath

  $p = Start-App $exePath $port
  try {
    $readyMs = Wait-Health $port 20000
    if ($readyMs -eq $null) { throw "No levantó /health en puerto $port" }

    $url = "http://localhost:$port/heavy?mb=$mb&rounds=$rounds"

    # C# helper: load + memoria pico (timeout 60s por request)
    $res = [LoadTest]::Run($url, $requests, $concurrency, $p.Id, 60)

    return [pscustomobject]@{
      ReadyMs = $readyMs
      Work = "mb=$mb rounds=$rounds"
      Requests = $requests
      Concurrency = $concurrency
      WallSeconds = $res.WallSeconds
      Rps = $res.Rps
      AvgMs = $res.AvgMs
      P50Ms = $res.P50Ms
      P95Ms = $res.P95Ms
      P99Ms = $res.P99Ms
      PeakWorkingSetMB = $res.PeakWorkingSetMB
      PeakPrivateMB = $res.PeakPrivateMB
      Ok = $res.Ok
      Fail = $res.Fail
    }
  }
  finally {
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
}

# --- MAIN ---
Assert-Path $jitExe "JIT exe"
Assert-Path $aotExe "AOT exe"
Assert-Path $dataBin "data.bin"

# Asegura data.bin dentro de cada output (tu API lo busca en AppContext.BaseDirectory)
Copy-Item $dataBin (Join-Path $jitOut "data.bin") -Force
Copy-Item $dataBin (Join-Path $aotOut "data.bin") -Force

# Limpia procesos vivos para evitar conflictos
Kill-ByExe $jitExe
Kill-ByExe $aotExe

$size = [pscustomobject]@{
  JitExeMB    = (Get-Item $jitExe).Length / 1MB
  AotExeMB    = (Get-Item $aotExe).Length / 1MB
  JitFolderMB = (FolderSizeBytes $jitOut) / 1MB
  AotFolderMB = (FolderSizeBytes $aotOut) / 1MB
}

$coldJit = Measure-ColdStart $jitExe $PortJit $ColdRuns
$coldAot = Measure-ColdStart $aotExe $PortAot $ColdRuns

$benchJit = Load-And-Memory $jitExe $PortJit $Requests $Concurrency $Mb $Rounds
$benchAot = Load-And-Memory $aotExe $PortAot $Requests $Concurrency $Mb $Rounds

""
"================== SUMMARY =================="
"BaseDir: $BaseDir"
"Work: mb=$Mb rounds=$Rounds | Requests=$Requests Concurrency=$Concurrency"
""

"--- SIZE (MB) ---"
$size | Format-List

"--- COLD START (ms to /health) ---"
@(
  [pscustomobject]@{Mode="JIT"; Runs=$coldJit.Runs; AvgMs=[math]::Round($coldJit.AvgMs,0); P50Ms=[math]::Round($coldJit.P50Ms,0); P95Ms=[math]::Round($coldJit.P95Ms,0)}
  [pscustomobject]@{Mode="AOT"; Runs=$coldAot.Runs; AvgMs=[math]::Round($coldAot.AvgMs,0); P50Ms=[math]::Round($coldAot.P50Ms,0); P95Ms=[math]::Round($coldAot.P95Ms,0)}
) | Format-Table -AutoSize

"--- SPEED + MEMORY ---"
@(
  $benchJit | Select @{n="Mode";e={"JIT"}}, Work, Requests, Concurrency, WallSeconds, Rps, AvgMs, P95Ms, P99Ms, PeakWorkingSetMB, PeakPrivateMB, Ok, Fail
  $benchAot | Select @{n="Mode";e={"AOT"}}, Work, Requests, Concurrency, WallSeconds, Rps, AvgMs, P95Ms, P99Ms, PeakWorkingSetMB, PeakPrivateMB, Ok, Fail
) | Format-Table -AutoSize
