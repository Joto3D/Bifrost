namespace Bifrost.Core.Models;

/// <summary>
/// Records what Bifrost has installed into a Valheim/BepInEx folder, so it
/// can update or remove mods without touching files it doesn't own.
/// Mirrors the macOS app's InstalledManifest model.
/// </summary>
public sealed class InstalledManifest
{
    public sealed class Entry
    {
        public string PackageId { get; init; } = string.Empty;
        public string InstalledVersion { get; init; } = string.Empty;
        public bool Enabled { get; set; } = true;
        public IReadOnlyList<string> Files { get; init; } = Array.Empty<string>();
    }

    public List<Entry> Entries { get; init; } = new();
}
