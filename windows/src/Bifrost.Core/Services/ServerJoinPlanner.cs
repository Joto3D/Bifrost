using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Builds and applies the guided "Join a Server" flow's plan: which
/// installed mods stay enabled, which get disabled, and which land in the
/// "adds items" warning group — computed from <see cref="ModClassifier"/>'s
/// classification of each installed mod, with per-mod overrides layered on
/// top. Ported from the macOS reference implementation's
/// <c>ServerJoinPlanner.swift</c>.
///
/// Deliberately never disables anything by itself: <see cref="BuildPlan"/>
/// is pure computation over already-loaded state, and <see cref="Apply"/> is
/// the only thing here that touches disk — and only when the guided flow's
/// final "Apply" step explicitly calls it. Bifrost's own multiplayer-safety
/// stance is "explain and let the user decide," never silent auto-disabling.
/// </summary>
public static class ServerJoinPlanner
{
    /// <summary>One mod's entry in a built plan.</summary>
    public sealed record Item(string FullName, ModClassification Classification, bool Enabled);

    /// <summary>A built plan, grouped for the guided flow's Step 2 display.</summary>
    public sealed class Plan
    {
        /// <summary><see cref="ModClass.ClientOnly"/> + <see cref="ModClass.ServerSynced"/> — always enabled. No override is offered for this group: there's nothing risky here to opt out of.</summary>
        public List<Item> KeepEnabled { get; init; } = new();

        /// <summary><see cref="ModClass.AddsItems"/> — defaults to enabled (the safer default: disabling an items mod risks hiding/stranding inventory items already picked up), surfaced with a prominent warning and a per-mod override to disable anyway.</summary>
        public List<Item> AddsItemsWarning { get; init; } = new();

        /// <summary><see cref="ModClass.WorldAltering"/> + <see cref="ModClass.Unknown"/> — defaults to disabled, with a per-mod override to keep enabled anyway.</summary>
        public List<Item> Disable { get; init; } = new();

        public bool IsEmpty => KeepEnabled.Count == 0 && AddsItemsWarning.Count == 0 && Disable.Count == 0;

        /// <summary>Every item across all three groups — what <see cref="Apply"/> writes into the target profile's mod list.</summary>
        public List<Item> AllItems => KeepEnabled.Concat(AddsItemsWarning).Concat(Disable).ToList();
    }

    /// <summary>
    /// Builds a plan from <paramref name="manifest"/>'s installed mods,
    /// classified against <paramref name="index"/>.
    /// <paramref name="overrides"/>[fullName], when present, replaces that
    /// mod's group default with the given enabled state — this is how the
    /// guided flow's per-mod checkboxes feed back into a rebuilt plan.
    /// </summary>
    public static Plan BuildPlan(InstalledManifest manifest, IReadOnlyList<ThunderstorePackage> index, IReadOnlyDictionary<string, bool>? overrides = null)
    {
        overrides ??= new Dictionary<string, bool>();
        var keepEnabled = new List<Item>();
        var addsItemsWarning = new List<Item>();
        var disable = new List<Item>();

        foreach (var mod in manifest.Mods.OrderBy(m => m.FullName, StringComparer.Ordinal))
        {
            var classification = ModClassifier.Classify(mod, index);
            switch (classification.ModClass)
            {
                case ModClass.ClientOnly:
                case ModClass.ServerSynced:
                    keepEnabled.Add(new Item(mod.FullName, classification, overrides.GetValueOrDefault(mod.FullName, true)));
                    break;
                case ModClass.AddsItems:
                    addsItemsWarning.Add(new Item(mod.FullName, classification, overrides.GetValueOrDefault(mod.FullName, true)));
                    break;
                case ModClass.WorldAltering:
                case ModClass.Unknown:
                    disable.Add(new Item(mod.FullName, classification, overrides.GetValueOrDefault(mod.FullName, false)));
                    break;
            }
        }

        return new Plan { KeepEnabled = keepEnabled, AddsItemsWarning = addsItemsWarning, Disable = disable };
    }

    public sealed record ApplyOutcome(SaveBackup.BackupOutcome BackupOutcome, ProfileStore.ApplyResult ApplyResult);

    /// <summary>
    /// Applies <paramref name="plan"/> to <paramref name="profileId"/>:
    ///  1. Takes a "pre-server" safety backup of the current saves FIRST,
    ///     via <paramref name="saveBackup"/> — surfaced back to the caller
    ///     as <see cref="ApplyOutcome.BackupOutcome"/> rather than
    ///     swallowed, since a Skipped result (no save data yet) is a normal,
    ///     worth-showing thing to see here.
    ///  2. Writes the plan's per-mod enabled decisions into
    ///     <paramref name="profileId"/>'s own mod list, marking it a guest
    ///     profile (<see cref="ProfileStore.SetMods"/>,
    ///     <see cref="Profile.IsServerGuest"/>) so the Home tab can offer a
    ///     "Back to my profile" hint afterward regardless of whether
    ///     <paramref name="profileId"/> was freshly created or an existing
    ///     profile the caller repurposed.
    ///  3. Reconciles the real install to match via
    ///     <see cref="ProfileStore.Apply"/> — exactly the same
    ///     enable/disable/report-missing behavior any other profile switch
    ///     gets.
    /// </summary>
    public static ApplyOutcome Apply(Plan plan, Guid profileId, string gameDir, ProfileStore profileStore, SaveBackup saveBackup)
    {
        var backupOutcome = saveBackup.BackupNow("pre-server");

        var mods = plan.AllItems.Select(i => new Profile.ProfileMod { FullName = i.FullName, Enabled = i.Enabled }).ToList();
        profileStore.SetMods(profileId, mods, isServerGuest: true);

        var applyResult = profileStore.Apply(profileId, gameDir);
        return new ApplyOutcome(backupOutcome, applyResult);
    }
}
