using System.Text.Json;
using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Owns settings.json — Bifrost's persisted preference toggles (see
/// <see cref="AppSettings"/>). The Windows counterpart of the macOS reference
/// implementation's <c>UserDefaults</c>-backed <c>@AppStorage</c> properties;
/// same read-or-default-on-missing-or-corrupt behavior as
/// <see cref="ModManager.LoadManifest"/>/<see cref="ProfileStore.Load"/>.
/// </summary>
public sealed class AppSettingsStore
{
    public string SettingsPath { get; }

    public AppSettingsStore(string? settingsPath = null)
    {
        SettingsPath = settingsPath ?? BifrostPaths.SettingsPath;
    }

    public AppSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
            {
                return new AppSettings();
            }
            var json = File.ReadAllText(SettingsPath);
            return JsonSerializer.Deserialize<AppSettings>(json, BifrostJson.Options) ?? new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings, BifrostJson.Options));
    }
}
