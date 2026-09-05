namespace Bifrost.Core.Services;

/// <summary>
/// Runs a batch of mod updates one at a time, collecting a per-mod result
/// rather than aborting the whole batch on the first failure — backs the
/// Installed tab's "Update All" action. Ported from the macOS reference
/// implementation's <c>UpdateAllRunner.swift</c>. Pure and injectable
/// (<paramref name="updater"/> is passed in rather than calling
/// <see cref="ModManager"/> directly), so a <c>--check</c> section can
/// exercise the aggregation logic with a fixture failure without touching
/// any real mod files.
/// </summary>
public static class UpdateAllRunner
{
    public abstract record Outcome
    {
        public sealed record Success : Outcome;
        public sealed record Failure(string Message) : Outcome;
    }

    /// <summary>One mod's outcome from a run.</summary>
    public sealed record ModResult(string FullName, Outcome Outcome);

    public sealed record Summary(List<ModResult> Results)
    {
        public int SucceededCount => Results.Count(r => r.Outcome is Outcome.Success);
        public int FailedCount => Results.Count - SucceededCount;

        public List<(string FullName, string Message)> Failures => Results
            .Where(r => r.Outcome is Outcome.Failure)
            .Select(r => (r.FullName, ((Outcome.Failure)r.Outcome).Message))
            .ToList();
    }

    /// <summary>
    /// Runs <paramref name="updater"/> sequentially for every entry in
    /// <paramref name="fullNames"/>, in order, calling
    /// <paramref name="onProgress"/> immediately before each one starts. A
    /// failure is recorded in the returned summary and the loop continues —
    /// never thrown, never aborts the rest of the batch.
    /// </summary>
    public static async Task<Summary> RunAsync(
        IReadOnlyList<string> fullNames,
        Func<string, Task> updater,
        Action<string>? onProgress = null)
    {
        var results = new List<ModResult>();
        foreach (var fullName in fullNames)
        {
            onProgress?.Invoke(fullName);
            try
            {
                await updater(fullName);
                results.Add(new ModResult(fullName, new Outcome.Success()));
            }
            catch (Exception ex)
            {
                results.Add(new ModResult(fullName, new Outcome.Failure(ex.Message)));
            }
        }
        return new Summary(results);
    }
}
