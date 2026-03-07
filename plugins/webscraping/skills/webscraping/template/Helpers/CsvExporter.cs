using System.Globalization;
using CsvHelper;
using CsvHelper.Configuration;
using Microsoft.EntityFrameworkCore;

namespace Scraper.Helpers;

/// <summary>
/// Streaming CSV export using <c>IAsyncEnumerable</c> — true constant memory.
/// </summary>
public static class CsvExporter
{
    /// <summary>
    /// Export all rows of a DbSet to CSV using streaming (constant memory).
    /// </summary>
    /// <returns>Number of rows written.</returns>
    public static async Task<int> ExportAsync<T>(
        IQueryable<T> query,
        string outputPath,
        CsvConfiguration? config = null,
        CancellationToken ct = default) where T : class
    {
        config ??= new CsvConfiguration(CultureInfo.InvariantCulture)
        {
            HasHeaderRecord = true,
        };

        await using var writer = new StreamWriter(outputPath);
        await using var csv = new CsvWriter(writer, config);

        csv.WriteHeader<T>();
        await csv.NextRecordAsync();

        var count = 0;
        await foreach (var row in query.AsNoTracking().AsAsyncEnumerable().WithCancellation(ct))
        {
            csv.WriteRecord(row);
            await csv.NextRecordAsync();
            count++;

            // Flush periodically to avoid buffering too much
            if (count % 10_000 == 0)
                await writer.FlushAsync(ct);
        }

        return count;
    }

    /// <summary>
    /// Export any async enumerable to CSV (not tied to EF Core).
    /// </summary>
    public static async Task<int> ExportAsync<T>(
        IAsyncEnumerable<T> source,
        string outputPath,
        CancellationToken ct = default)
    {
        var config = new CsvConfiguration(CultureInfo.InvariantCulture);
        await using var writer = new StreamWriter(outputPath);
        await using var csv = new CsvWriter(writer, config);

        csv.WriteHeader<T>();
        await csv.NextRecordAsync();

        var count = 0;
        await foreach (var row in source.WithCancellation(ct))
        {
            csv.WriteRecord(row);
            await csv.NextRecordAsync();
            count++;
        }

        return count;
    }
}
