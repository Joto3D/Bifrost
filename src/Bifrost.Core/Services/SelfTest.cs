namespace Bifrost.Core.Services;

/// <summary>
/// Headless diagnostics, mirroring the macOS app's `Bifrost --check` mode
/// (Sources/Bifrost/DebugCheck.swift + Services/Diagnostics.swift). Each
/// check is a cheap, non-destructive sanity probe that can run with no UI.
/// Real probes (game locator, BepInEx installer, Thunderstore reachability,
/// manifest read/write) get filled in as those services are ported.
/// </summary>
public static class SelfTest
{
    public readonly record struct Result(string Name, bool Passed, string Detail);

    public static IReadOnlyList<Result> RunAll()
    {
        return new[]
        {
            new Result("Bifrost.Core loaded", true, "Assembly resolved and executing."),
        };
    }
}
