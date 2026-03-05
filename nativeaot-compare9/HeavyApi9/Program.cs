using System.Buffers;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json.Serialization;

var builder = WebApplication.CreateBuilder(args);


builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default);
});

var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new HealthResponse(true, DateTimeOffset.UtcNow)));


app.MapGet("/heavy", async (int? mb, int? rounds) =>
{
    int readMb = mb.GetValueOrDefault(32);
    if (readMb < 1) readMb = 1;
    if (readMb > 256) readMb = 256;

    int hashRounds = rounds.GetValueOrDefault(400);
    if (hashRounds < 0) hashRounds = 0;
    if (hashRounds > 50_000) hashRounds = 50_000;

    var baseDir = AppContext.BaseDirectory;
    var dataPath = Environment.GetEnvironmentVariable("HEAVY_DATA_PATH")
                  ?? Path.Combine(baseDir, "data.bin");

    if (!File.Exists(dataPath))
        return Results.Problem($"No existe data.bin: {dataPath})");

    long bytesToRead = (long)readMb * 1024 * 1024;

    var sw = Stopwatch.StartNew();

    await using var fs = new FileStream(
        dataPath,
        new FileStreamOptions
        {
            Mode = FileMode.Open,
            Access = FileAccess.Read,
            Share = FileShare.Read,
            Options = FileOptions.SequentialScan | FileOptions.Asynchronous,
            BufferSize = 1024 * 1024
        });

    byte[] buffer = ArrayPool<byte>.Shared.Rent(1024 * 1024);
    long totalRead = 0;

    try
    {
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);

        while (bytesToRead > 0)
        {
            int toRead = (int)Math.Min(buffer.Length, bytesToRead);
            int n = await fs.ReadAsync(buffer.AsMemory(0, toRead));
            if (n <= 0) break;

            hasher.AppendData(buffer, 0, n);
            totalRead += n;
            bytesToRead -= n;
        }

        byte[] hash = hasher.GetHashAndReset();

        for (int i = 0; i < hashRounds; i++)
            hash = SHA256.HashData(hash);

        sw.Stop();

        return Results.Ok(new HeavyResponse(
            ReadMb: (int)(totalRead / (1024 * 1024)),
            HashRounds: hashRounds,
            ElapsedMs: sw.Elapsed.TotalMilliseconds,
            ResultPrefixHex: Convert.ToHexString(hash.AsSpan(0, 6))
        ));
    }
    finally
    {
        ArrayPool<byte>.Shared.Return(buffer);
    }
});

app.Run();

public record HealthResponse(bool Ok, DateTimeOffset UtcNow);
public record HeavyResponse(int ReadMb, int HashRounds, double ElapsedMs, string ResultPrefixHex);

[JsonSerializable(typeof(HealthResponse))]
[JsonSerializable(typeof(HeavyResponse))]
public partial class AppJsonContext : JsonSerializerContext;