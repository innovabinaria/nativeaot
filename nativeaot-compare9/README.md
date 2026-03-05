# NativeAOT vs JIT (.NET 9) – Minimal API Benchmark (Local)

This repo contains a **simple, demo-friendly** Minimal API in **.NET 9** built in two modes:

- **JIT** (normal .NET runtime)
- **NativeAOT** (AOT + trimming + speed-focused publish)

It also includes a PowerShell script that runs both binaries locally and prints a **side-by-side comparison**:
- **Cold start** (time to `/health`)
- **Throughput (RPS/TPS)** and **latency** (Avg / P95 / P99) for a “heavy” endpoint
- **Peak memory (Working Set)**
- **Artifact size** (exe + published folder)

---

## What the API does

### `GET /health`
Returns a small JSON payload (`ok`, `utcNow`). Used to measure **cold start** (how fast the process becomes ready).

### `GET /heavy?mb=32&rounds=400`
Simulates a realistic workload with:
- **I/O**: reads `mb` MB from a local file (`data.bin`)
- **CPU**: computes SHA-256 and then repeats hashing `rounds` times

This gives you a knob to make the endpoint:
- more **I/O-bound** (increase `mb`)
- more **CPU-bound** (increase `rounds`)

`data.bin` is read **only** when calling `/heavy`.

---

## Repo layout

```
nativeaot-compare9/
  HeavyApi9/                 # Minimal API project (.NET 9)
    HeavyApi9.csproj
    Program.cs
  out-jit9/                  # publish output (JIT)   -> generated
  out-aot9/                  # publish output (AOT)   -> generated
  data.bin                   # local workload file    -> generated
  compare-aot-jit.ps1        # benchmark script
```

---

## Prerequisites (Windows 10/11 x64)

- **.NET SDK 9.x**
  - Verify: `dotnet --info`
- **Visual Studio 2022** (or Build Tools) with **C++ build tools**
  - Needed for **NativeAOT** on Windows (C/C++ toolchain + linker)
  - Verify from *Developer Command Prompt/PowerShell for VS*:
    - `cl` (MSVC compiler) should work

> Tip: If `cl` works only inside “Developer PowerShell for VS 2022”, that’s OK.

---

## 1) Create the workload file (`data.bin`)

Run from the repo root:

```powershell
$base = (Get-Location).Path
$path = Join-Path $base "data.bin"
$sizeMB = 128

$chunk = New-Object byte[] (1024*1024) # 1MB
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

$fs = [System.IO.File]::Open($path,'Create','Write','None')
try {
  for($i=0; $i -lt $sizeMB; $i++){
    $rng.GetBytes($chunk)
    $fs.Write($chunk,0,$chunk.Length)
  }
} finally {
  $fs.Dispose()
  $rng.Dispose()
}

"OK: $path"
(Get-Item $path).Length
```

---

## 2) Publish JIT

From the repo root:

```powershell
dotnet publish .\HeavyApi9\HeavyApi9.csproj -c Release -r win-x64 --self-contained true -o .\out-jit9
```

---

## 3) Publish NativeAOT

### Option A (recommended – uses the repo’s conditional `AOT` property)
```powershell
dotnet publish .\HeavyApi9\HeavyApi9.csproj -c Release -r win-x64 --self-contained true -p:AOT=true -o .\out-aot9
```

### Option B (direct MSBuild property)
```powershell
dotnet publish .\HeavyApi9\HeavyApi9.csproj -c Release -r win-x64 --self-contained true -p:PublishAot=true -o .\out-aot9
```

---

## 4) Run manually (optional)

JIT:
```powershell
.\out-jit9\HeavyApi9.exe --urls http://localhost:5077
```

AOT:
```powershell
.\out-aot9\HeavyApi9.exe --urls http://localhost:5078
```

Test:
```powershell
Invoke-RestMethod http://localhost:5077/health
Invoke-RestMethod "http://localhost:5077/heavy?mb=8&rounds=5000"
```

---

## 5) Run the benchmark (recommended)

From the repo root:

```powershell
.\compare-aot-jit.ps1
```

You can also override parameters:

```powershell
.\compare-aot-jit.ps1 -ColdRuns 10 -Requests 200 -Concurrency 32 -Mb 8 -Rounds 5000
```

### What the benchmark prints
- **SIZE (MB)**: exe size + folder size for JIT and AOT
- **COLD START**: Avg/P50/P95 ms to first successful `/health`
- **SPEED + MEMORY**: RPS + Avg/P95/P99 latency and peak working set (MB)

---

## Benchmark parameters explained

- `ColdRuns`: how many times to start/stop the process and measure time to `/health`
- `Requests`: total number of `/heavy` requests in the load test
- `Concurrency`: max in-flight requests during the load test
- `Mb`: value passed to `/heavy?mb=...` (I/O intensity)
- `Rounds`: value passed to `/heavy?rounds=...` (CPU intensity)

### Suggested settings for a “wow” demo
CPU-bound (AOT often shines):
```powershell
.\compare-aot-jit.ps1 -ColdRuns 10 -Requests 200 -Concurrency 32 -Mb 8 -Rounds 5000
```

---

## Notes / caveats

- Results vary based on:
  - Windows Defender / antivirus
  - CPU frequency scaling and background processes
  - disk caching
- NativeAOT produces a larger **single exe**, but often a smaller **published folder** (thanks to trimming).
- The project config uses **System.Text.Json source generation** to stay AOT/trimming friendly.


