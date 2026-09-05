using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>One mod's row in the guided "Join a Server" flow's plan review step — wraps a <see cref="ServerJoinPlanner.Item"/> with a checkbox-bound <see cref="Enabled"/> the user can override.</summary>
public partial class ServerJoinItemViewModel : ObservableObject
{
    public string FullName { get; }
    public ModClassification Classification { get; }

    /// <summary>Whether this group offers a per-mod override checkbox at all — the "always stays enabled" group (client-only/server-synced) doesn't, since there's nothing risky to opt out of.</summary>
    public bool ShowsOverride { get; }

    [ObservableProperty] private bool _enabled;

    public string ClassGlyph => Classification.ModClass.Glyph();
    public string ClassLabel => Classification.ModClass.DisplayName();
    public string ClassTooltip => $"{Classification.ModClass.Explanation()} ({Classification.Basis})";

    public ServerJoinItemViewModel(string fullName, ModClassification classification, bool enabled, bool showsOverride)
    {
        FullName = fullName;
        Classification = classification;
        _enabled = enabled;
        ShowsOverride = showsOverride;
    }
}

/// <summary>
/// Backs the guided "Join a Server" window: pick a target profile, review
/// <see cref="ServerJoinPlanner"/>'s computed plan (with per-mod overrides),
/// then apply it — pre-server safety backup first, then reconcile the real
/// install. Mirrors the macOS app's <c>ServerJoinSheetView.swift</c>.
/// Deliberately never disables anything until the final "Apply" step.
/// </summary>
public partial class ServerJoinViewModel : ViewModelBase
{
    public enum WizardStep { ChooseProfile, ReviewPlan, Apply }

    private readonly AppServices _services;

    /// <summary>Called once Apply succeeds, with whichever profile was active before this flow switched away from it (if any) — <c>HomeViewModel</c> uses this to power its "Back to my profile" hint.</summary>
    public Action<Guid?>? OnApplied { get; set; }

    /// <summary>Called when the user taps "Play Modded" on the final step.</summary>
    public Action? OnPlayModded { get; set; }

    /// <summary>Set by the view once Apply succeeds and the user dismisses — code-behind closes the window.</summary>
    public Action? RequestClose { get; set; }

    [ObservableProperty] private WizardStep _step = WizardStep.ChooseProfile;

    public bool IsChooseProfileStep => Step == WizardStep.ChooseProfile;
    public bool IsReviewPlanStep => Step == WizardStep.ReviewPlan;
    public bool IsApplyStep => Step == WizardStep.Apply;
    public bool ShowBackOnApplyStep => Step == WizardStep.Apply && !DidApply;
    public bool ShowApplyFooterButtons => Step == WizardStep.Apply;

    partial void OnStepChanged(WizardStep value)
    {
        OnPropertyChanged(nameof(IsChooseProfileStep));
        OnPropertyChanged(nameof(IsReviewPlanStep));
        OnPropertyChanged(nameof(IsApplyStep));
        OnPropertyChanged(nameof(ShowBackOnApplyStep));
        OnPropertyChanged(nameof(ShowApplyFooterButtons));
    }

    public ObservableCollection<Profile> ExistingProfiles { get; } = new();

    [ObservableProperty] private bool _createNewProfile = true;
    [ObservableProperty] private string _newProfileName = "Server Guest";
    [ObservableProperty] private Profile? _selectedExistingProfile;

    public ObservableCollection<ServerJoinItemViewModel> KeepEnabledItems { get; } = new();
    public ObservableCollection<ServerJoinItemViewModel> AddsItemsWarningItems { get; } = new();
    public ObservableCollection<ServerJoinItemViewModel> DisableItems { get; } = new();
    public bool PlanIsEmpty => KeepEnabledItems.Count == 0 && AddsItemsWarningItems.Count == 0 && DisableItems.Count == 0;
    public bool HasKeepEnabled => KeepEnabledItems.Count > 0;
    public bool HasAddsItemsWarning => AddsItemsWarningItems.Count > 0;
    public bool HasDisable => DisableItems.Count > 0;

    [ObservableProperty] private bool _isApplying;

    [ObservableProperty] private bool _didApply;

    partial void OnDidApplyChanged(bool value) => OnPropertyChanged(nameof(ShowBackOnApplyStep));
    [ObservableProperty] private string? _errorLine;
    [ObservableProperty] private string? _backupSummaryLine;
    [ObservableProperty] private string? _missingSummaryLine;

    private Guid? _priorProfileId;
    private List<ThunderstorePackage> _index = new();

    public string TargetDescription => CreateNewProfile
        ? $"Create \"{(string.IsNullOrWhiteSpace(NewProfileName) ? "Server Guest" : NewProfileName.Trim())}\" from your current mods"
        : $"Switch to \"{SelectedExistingProfile?.Name ?? "profile"}\"";

    public ServerJoinViewModel(AppServices services)
    {
        _services = services;
        _priorProfileId = services.ProfileStore.LoadOrMigrate().ActiveProfileId;
        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        var file = _services.ProfileStore.LoadOrMigrate();
        ExistingProfiles.Clear();
        foreach (var profile in file.Profiles.OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase))
        {
            ExistingProfiles.Add(profile);
        }
        SelectedExistingProfile = ExistingProfiles.FirstOrDefault();

        try
        {
            _index = await _services.ThunderstoreClient.FetchIndexAsync(force: false);
        }
        catch
        {
            _index = new List<ThunderstorePackage>();
        }
    }

    [RelayCommand]
    private void GoToReviewPlan()
    {
        var manifest = _services.ModManager.LoadManifest();
        var plan = ServerJoinPlanner.BuildPlan(manifest, _index);

        KeepEnabledItems.Clear();
        foreach (var item in plan.KeepEnabled)
        {
            KeepEnabledItems.Add(new ServerJoinItemViewModel(item.FullName, item.Classification, item.Enabled, showsOverride: false));
        }
        AddsItemsWarningItems.Clear();
        foreach (var item in plan.AddsItemsWarning)
        {
            AddsItemsWarningItems.Add(new ServerJoinItemViewModel(item.FullName, item.Classification, item.Enabled, showsOverride: true));
        }
        DisableItems.Clear();
        foreach (var item in plan.Disable)
        {
            DisableItems.Add(new ServerJoinItemViewModel(item.FullName, item.Classification, item.Enabled, showsOverride: true));
        }
        OnPropertyChanged(nameof(PlanIsEmpty));
        OnPropertyChanged(nameof(HasKeepEnabled));
        OnPropertyChanged(nameof(HasAddsItemsWarning));
        OnPropertyChanged(nameof(HasDisable));

        Step = WizardStep.ReviewPlan;
    }

    [RelayCommand]
    private void BackToChooseProfile() => Step = WizardStep.ChooseProfile;

    [RelayCommand]
    private void GoToApply() => Step = WizardStep.Apply;

    [RelayCommand]
    private void BackToReviewPlan() => Step = WizardStep.ReviewPlan;

    [RelayCommand]
    private async Task ApplyAsync()
    {
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
            Guid profileId;
            if (CreateNewProfile)
            {
                var name = string.IsNullOrWhiteSpace(NewProfileName) ? "Server Guest" : NewProfileName.Trim();
                var created = await Task.Run(() => _services.ProfileStore.Create(name, new List<Profile.ProfileMod>(), isServerGuest: true));
                profileId = created.Id;
            }
            else if (SelectedExistingProfile is { } existing)
            {
                profileId = existing.Id;
            }
            else
            {
                ErrorLine = "Pick a target profile first.";
                return;
            }

            var plan = new ServerJoinPlanner.Plan
            {
                KeepEnabled = KeepEnabledItems.Select(ToItem).ToList(),
                AddsItemsWarning = AddsItemsWarningItems.Select(ToItem).ToList(),
                Disable = DisableItems.Select(ToItem).ToList(),
            };

            var outcome = await Task.Run(() => ServerJoinPlanner.Apply(plan, profileId, gameDir, _services.ProfileStore, _services.SaveBackup));

            BackupSummaryLine = Describe(outcome.BackupOutcome);
            MissingSummaryLine = outcome.ApplyResult.Missing.Count == 0
                ? null
                : $"Not installed yet: {string.Join(", ", outcome.ApplyResult.Missing)}";
            DidApply = true;
            OnApplied?.Invoke(_priorProfileId);
        }
        catch (Exception ex)
        {
            ErrorLine = $"Couldn't apply: {ex.Message}";
        }
        finally
        {
            IsApplying = false;
        }
    }

    private static ServerJoinPlanner.Item ToItem(ServerJoinItemViewModel vm) => new(vm.FullName, vm.Classification, vm.Enabled);

    private static string Describe(SaveBackup.BackupOutcome outcome) => outcome switch
    {
        SaveBackup.BackupOutcome.Created created => $"Backed up saves ({created.Summary.FileCount} file{(created.Summary.FileCount == 1 ? "" : "s")}) before switching.",
        SaveBackup.BackupOutcome.Skipped skipped => $"Backup skipped: {skipped.Reason}",
        _ => "",
    };

    [RelayCommand]
    private void PlayModded()
    {
        OnPlayModded?.Invoke();
        RequestClose?.Invoke();
    }

    [RelayCommand]
    private void Close() => RequestClose?.Invoke();
}
