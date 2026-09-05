using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

public sealed record ImportResolvableRow(string FullName, string VersionText, bool WasSubstituted);
public sealed record ImportInstalledRow(string FullName, string VersionText);
public sealed record ImportUnresolvableRow(string FullName, string Reason);

/// <summary>
/// Backs the "Import Profile" window, opened from the Profiles dialog's
/// "Import…" button: paste a share code — Bifrost's own native base64, or
/// an r2modman/Thunderstore Mod Manager profile code, auto-detected via
/// <see cref="ProfileShare.LooksLikeR2ModManCode"/> — or pick a
/// <c>.bifrostprofile</c> file. Either way, review the resulting
/// <see cref="ProfileShare.ImportPlan"/> before confirming installs
/// everything resolvable and creates a new profile from it. Mirrors the
/// macOS app's <c>ImportProfileSheetView.swift</c>.
/// </summary>
public partial class ImportProfileViewModel : ViewModelBase
{
    private readonly AppServices _services;
    private List<ThunderstorePackage> _index = new();

    [ObservableProperty] private string _codeText = "";
    [ObservableProperty] private bool _isParsing;
    [ObservableProperty] private bool _isApplying;
    [ObservableProperty] private string? _errorLine;
    [ObservableProperty] private string? _progressLine;

    private ProfileShare.ImportPlan? _plan;
    [ObservableProperty] private Profile? _createdProfile;

    [ObservableProperty] private string _importedName = "";
    public ObservableCollection<ImportResolvableRow> ResolvableRows { get; } = new();
    public ObservableCollection<ImportInstalledRow> AlreadyInstalledRows { get; } = new();
    public ObservableCollection<ImportUnresolvableRow> UnresolvableRows { get; } = new();

    [ObservableProperty] private bool _hasPlan;
    public bool ShowPasteStep => !HasPlan && CreatedProfile is null;
    public bool ShowPlanStep => HasPlan && CreatedProfile is null;
    public bool ShowDoneStep => CreatedProfile is not null;
    public bool PlanIsEmpty => ResolvableRows.Count == 0 && AlreadyInstalledRows.Count == 0;
    public int InstallableCount => ResolvableRows.Count + AlreadyInstalledRows.Count;
    public bool HasResolvableRows => ResolvableRows.Count > 0;
    public bool HasAlreadyInstalledRows => AlreadyInstalledRows.Count > 0;
    public bool HasUnresolvableRows => UnresolvableRows.Count > 0;

    partial void OnHasPlanChanged(bool value)
    {
        OnPropertyChanged(nameof(ShowPasteStep));
        OnPropertyChanged(nameof(ShowPlanStep));
    }

    partial void OnCreatedProfileChanged(Profile? value)
    {
        OnPropertyChanged(nameof(ShowPasteStep));
        OnPropertyChanged(nameof(ShowPlanStep));
        OnPropertyChanged(nameof(ShowDoneStep));
    }

    public ImportProfileViewModel(AppServices services)
    {
        _services = services;
    }

    [RelayCommand]
    private async Task ParseCodeAsync()
    {
        var trimmed = CodeText.Trim();
        if (trimmed.Length == 0)
        {
            return;
        }
        IsParsing = true;
        ErrorLine = null;
        try
        {
            var index = await LoadIndexAsync();
            var manifest = _services.ModManager.LoadManifest();
            var plan = ProfileShare.LooksLikeR2ModManCode(trimmed)
                ? await ProfileShare.ImportR2CodeAsync(trimmed, index, manifest)
                : ProfileShare.Plan(trimmed, index, manifest);
            ApplyPlan(plan);
        }
        catch (Exception ex)
        {
            ErrorLine = $"Couldn't import: {ex.Message}";
        }
        finally
        {
            IsParsing = false;
        }
    }

    /// <summary>Called from the view's code-behind after a file picker resolves a <c>.bifrostprofile</c> path.</summary>
    public async Task ParseFileAsync(string path)
    {
        IsParsing = true;
        ErrorLine = null;
        try
        {
            var index = await LoadIndexAsync();
            var manifest = _services.ModManager.LoadManifest();
            var plan = ProfileShare.PlanFromFile(path, index, manifest);
            ApplyPlan(plan);
        }
        catch (Exception ex)
        {
            ErrorLine = $"Couldn't import: {ex.Message}";
        }
        finally
        {
            IsParsing = false;
        }
    }

    private async Task<List<ThunderstorePackage>> LoadIndexAsync()
    {
        _index = await _services.ThunderstoreClient.FetchIndexAsync(force: false);
        return _index;
    }

    private void ApplyPlan(ProfileShare.ImportPlan plan)
    {
        ImportedName = plan.ImportedName;
        ResolvableRows.Clear();
        foreach (var mod in plan.Resolvable)
        {
            ResolvableRows.Add(new ImportResolvableRow(mod.FullName, mod.WasSubstituted ? $"v{mod.RequestedVersion} → v{mod.ResolvedVersion}" : $"v{mod.ResolvedVersion}", mod.WasSubstituted));
        }
        AlreadyInstalledRows.Clear();
        foreach (var mod in plan.AlreadyInstalled)
        {
            AlreadyInstalledRows.Add(new ImportInstalledRow(mod.FullName, $"v{mod.InstalledVersion}"));
        }
        UnresolvableRows.Clear();
        foreach (var mod in plan.Unresolvable)
        {
            UnresolvableRows.Add(new ImportUnresolvableRow(mod.FullName, Explain(mod.Reason)));
        }
        _plan = plan;
        HasPlan = true;
        OnPropertyChanged(nameof(PlanIsEmpty));
        OnPropertyChanged(nameof(InstallableCount));
        OnPropertyChanged(nameof(HasResolvableRows));
        OnPropertyChanged(nameof(HasAlreadyInstalledRows));
        OnPropertyChanged(nameof(HasUnresolvableRows));
    }

    private static string Explain(ProfileShare.ImportPlan.UnresolvableReason reason) => reason switch
    {
        ProfileShare.ImportPlan.UnresolvableReason.NotInIndex =>
            "Not found in the Thunderstore index — it may have been removed, made private, or your index cache is stale.",
        ProfileShare.ImportPlan.UnresolvableReason.NexusOnly { ModId: { } modId } =>
            $"Hosted on Nexus Mods (id {modId}) — install it there, then add it to this profile manually.",
        ProfileShare.ImportPlan.UnresolvableReason.NexusOnly =>
            "Hosted on Nexus Mods — install it there, then add it to this profile manually.",
        _ => "Can't be resolved.",
    };

    [RelayCommand]
    private void Back()
    {
        HasPlan = false;
        _plan = null;
        ErrorLine = null;
    }

    [RelayCommand]
    private async Task ApplyAsync()
    {
        if (_plan is null)
        {
            return;
        }
        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            ErrorLine = "Locate Valheim first (Home tab).";
            return;
        }
        IsApplying = true;
        ErrorLine = null;
        try
        {
            var index = await LoadIndexAsync();
            var profile = await ProfileShare.ApplyAsync(
                _plan, index, _services.ModManager, _services.ProfileStore, gameDir,
                onProgress: p => ProgressLine = Describe(p));
            await Task.Run(() => _services.ProfileStore.SyncActiveProfile());
            CreatedProfile = profile;
        }
        catch (Exception ex)
        {
            ErrorLine = $"Couldn't install: {ex.Message}";
        }
        finally
        {
            IsApplying = false;
        }
    }

    private static string Describe(ModManager.Progress progress) => progress.Stage switch
    {
        ModManager.ProgressStage.InstallingLoader => "Installing BepInEx…",
        ModManager.ProgressStage.Downloading => $"Downloading {progress.FullName}…",
        ModManager.ProgressStage.Extracting => $"Extracting {progress.FullName}…",
        ModManager.ProgressStage.CopyingFiles => $"Installing {progress.FullName}…",
        ModManager.ProgressStage.Done => $"Installed {progress.FullName}",
        _ => "Working…",
    };
}
