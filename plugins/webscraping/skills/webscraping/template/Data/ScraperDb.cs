using Microsoft.EntityFrameworkCore;

namespace Scraper.Data;

// --- Entities ---

public class Checkpoint
{
    public string Key { get; set; } = "";
    public DateTime CompletedAt { get; set; } = DateTime.UtcNow;
}

public class Progress
{
    public string Key { get; set; } = "";
    public int LastPage { get; set; }
    public int? TotalPages { get; set; }
    public string? Extra { get; set; }
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
}

/// <summary>
/// EF Core DbContext for scraper data with built-in checkpoint/progress tracking.
///
/// <para>Usage:</para>
/// <code>
/// await using var db = ScraperDb.Create("data.db");
/// await db.Database.EnsureCreatedAsync();
///
/// // Add your own entity:
/// // public DbSet&lt;Product&gt; Products =&gt; Set&lt;Product&gt;();
///
/// if (!await db.IsCompletedAsync("product::123"))
/// {
///     db.Products.Add(new Product { ... });
///     await db.SaveChangesAsync();
///     await db.CompleteWorkAsync("product::123");
/// }
/// </code>
/// </summary>
public class ScraperDb : DbContext
{
    public DbSet<Checkpoint> Checkpoints => Set<Checkpoint>();
    public DbSet<Progress> Progress => Set<Progress>();

    private readonly string _dbPath;

    public ScraperDb(string dbPath)
    {
        _dbPath = dbPath;
    }

    // DbContextOptions constructor for DI scenarios
    public ScraperDb(DbContextOptions<ScraperDb> options) : base(options) { }

    /// <summary>Quick factory: create a context for a given database file.</summary>
    public static ScraperDb Create(string dbPath = "data.db")
    {
        var db = new ScraperDb(dbPath);
        db.Database.ExecuteSqlRaw("PRAGMA journal_mode = WAL");
        db.Database.ExecuteSqlRaw("PRAGMA synchronous = NORMAL");
        return db;
    }

    protected override void OnConfiguring(DbContextOptionsBuilder options)
    {
        if (!options.IsConfigured)
            options.UseSqlite($"Data Source={_dbPath}");
    }

    protected override void OnModelCreating(ModelBuilder m)
    {
        m.Entity<Checkpoint>(e =>
        {
            e.ToTable("_checkpoints");
            e.HasKey(c => c.Key);
        });

        m.Entity<Progress>(e =>
        {
            e.ToTable("_progress");
            e.HasKey(p => p.Key);
        });
    }

    // --- Checkpoint API ---

    /// <summary>Check if a work unit has been completed.</summary>
    public Task<bool> IsCompletedAsync(string key, CancellationToken ct = default) =>
        Checkpoints.AnyAsync(c => c.Key == key, ct);

    /// <summary>Check if a work unit has been completed (sync).</summary>
    public bool IsCompleted(string key) =>
        Checkpoints.Any(c => c.Key == key);

    /// <summary>
    /// Atomically delete progress and mark a work unit as completed.
    /// Safe against crash: both operations are in a single transaction.
    /// </summary>
    public async Task CompleteWorkAsync(string key, CancellationToken ct = default)
    {
        await using var tx = await Database.BeginTransactionAsync(ct);
        await Progress.Where(p => p.Key == key).ExecuteDeleteAsync(ct);
        if (!await Checkpoints.AnyAsync(c => c.Key == key, ct))
            Checkpoints.Add(new Checkpoint { Key = key });
        await SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
    }

    /// <summary>Build a composite checkpoint key from parts.</summary>
    public static string MakeKey(params object[] parts) =>
        string.Join("::", parts);

    // --- Progress API ---

    /// <summary>Update page progress for an in-flight work unit.</summary>
    public async Task UpdateProgressAsync(
        string key, int lastPage, int? totalPages = null,
        string? extra = null, CancellationToken ct = default)
    {
        var existing = await Progress.FindAsync([key], ct);
        if (existing is not null)
        {
            existing.LastPage = lastPage;
            existing.TotalPages = totalPages;
            existing.Extra = extra;
            existing.UpdatedAt = DateTime.UtcNow;
        }
        else
        {
            Progress.Add(new Progress
            {
                Key = key,
                LastPage = lastPage,
                TotalPages = totalPages,
                Extra = extra,
            });
        }
        await SaveChangesAsync(ct);
    }

    /// <summary>Get progress for a work unit, or null if none.</summary>
    public Task<Progress?> GetProgressAsync(string key, CancellationToken ct = default) =>
        Progress.FindAsync([key], ct).AsTask();

    /// <summary>List all in-flight work units (useful for resume reporting).</summary>
    public async Task<List<Progress>> ListInFlightAsync(CancellationToken ct = default) =>
        await Progress.OrderBy(p => p.Key).ToListAsync(ct);

    /// <summary>List all completed keys (useful for stats).</summary>
    public async Task<List<string>> ListCompletedKeysAsync(CancellationToken ct = default) =>
        await Checkpoints.Select(c => c.Key).OrderBy(k => k).ToListAsync(ct);

    // --- Bulk operations ---

    /// <summary>
    /// Add a batch of entities and save. Uses a transaction for atomicity.
    /// Call with your own entity type: <c>await db.AddBatchAsync(products);</c>
    /// </summary>
    public async Task AddBatchAsync<T>(
        IEnumerable<T> entities, CancellationToken ct = default) where T : class
    {
        await using var tx = await Database.BeginTransactionAsync(ct);
        AddRange(entities);
        await SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
    }

    /// <summary>
    /// Stream all rows of a given entity type as an async enumerable.
    /// Use for memory-efficient export of large tables.
    /// </summary>
    public IAsyncEnumerable<T> StreamAllAsync<T>(CancellationToken ct = default) where T : class =>
        Set<T>().AsNoTracking().AsAsyncEnumerable();
}
