using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>
/// Backs the profiles management dialog: create/duplicate/rename/delete.
/// Mirrors the macOS app's ProfilesSheetView.swift.
/// </summary>
public partial class ProfilesViewModel : ViewModelBase
{
    private readonly AppServices _services;

    /// <summary>Exposed so the view's code-behind can build/upload share codes (<see cref="ProfileShare"/>) and open the Import dialog against the same service instances.</summary>
    public AppServices Services => _services;

    public ObservableCollection<Profile> Profiles { get; } = new();

    [ObservableProperty] private Profile? _selectedProfile;
    [ObservableProperty] private string _newProfileName = "";
    [ObservableProperty] private string _statusMessage = "";

    public ProfilesViewModel(AppServices services)
    {
        _services = services;
        _ = RefreshAsync();
    }

    [RelayCommand]
    public async Task RefreshAsync()
    {
        var file = await Task.Run(() => _services.ProfileStore.LoadOrMigrate());
        Profiles.Clear();
        foreach (var profile in file.Profiles)
        {
            Profiles.Add(profile);
        }
        SelectedProfile = Profiles.FirstOrDefault(p => p.Id == file.ActiveProfileId) ?? Profiles.FirstOrDefault();
    }

    [RelayCommand]
    private async Task CreateEmptyAsync()
    {
        if (string.IsNullOrWhiteSpace(NewProfileName))
        {
            return;
        }
        await Task.Run(() => _services.ProfileStore.Create(NewProfileName, fromCurrent: false));
        NewProfileName = "";
        await RefreshAsync();
    }

    [RelayCommand]
    private async Task CreateFromCurrentAsync()
    {
        if (string.IsNullOrWhiteSpace(NewProfileName))
        {
            return;
        }
        await Task.Run(() => _services.ProfileStore.Create(NewProfileName, fromCurrent: true));
        NewProfileName = "";
        await RefreshAsync();
    }

    [RelayCommand]
    private async Task DuplicateAsync()
    {
        if (SelectedProfile is null)
        {
            return;
        }
        await Task.Run(() => _services.ProfileStore.Duplicate(SelectedProfile.Id, $"{SelectedProfile.Name} Copy"));
        await RefreshAsync();
    }

    [RelayCommand]
    private async Task RenameAsync()
    {
        if (SelectedProfile is null || string.IsNullOrWhiteSpace(NewProfileName))
        {
            return;
        }
        await Task.Run(() => _services.ProfileStore.Rename(SelectedProfile.Id, NewProfileName));
        NewProfileName = "";
        await RefreshAsync();
    }

    [RelayCommand]
    private async Task DeleteAsync()
    {
        if (SelectedProfile is null)
        {
            return;
        }
        try
        {
            await Task.Run(() => _services.ProfileStore.Delete(SelectedProfile.Id));
            await RefreshAsync();
        }
        catch (Exception ex)
        {
            StatusMessage = ex.Message;
        }
    }
}
