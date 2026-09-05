using System.Runtime.InteropServices;
using System.Text;

namespace Bifrost.Core.Services;

/// <summary>
/// Minimal credential read/write/delete wrapper for a single generic
/// credential per target name — the Windows counterpart of the macOS
/// reference implementation's <c>Keychain.swift</c>. Used to store the
/// user's personal Nexus Mods API key
/// (<see cref="NexusApiKeyTarget"/>, "Bifrost-NexusAPIKey") via the Windows
/// Credential Manager (<c>advapi32.dll</c>'s <c>CredWrite</c>/<c>CredRead</c>/
/// <c>CredDelete</c>), deliberately never a plain settings file, for the
/// same reason the macOS app avoids <c>UserDefaults</c> for this: a
/// plist/JSON-backed store can end up in a backup or a stray file read in
/// cleartext.
///
/// On a non-Windows dev machine (this Mac), <see cref="OperatingSystem.IsWindows"/>
/// is false, so the real Credential Manager P/Invoke calls are never made —
/// instead, a plaintext dev-only fallback file under the app-data directory
/// backs the same Save/Read/Delete surface, so <c>--check</c> can still
/// exercise the round-trip logic here. That fallback is never used on a real
/// Windows install.
/// </summary>
public static class WindowsCredentials
{
    /// <summary>
    /// The real target name the app's Nexus Mods integration reads/writes in
    /// normal use. <c>--check</c>'s credential-round-trip section
    /// deliberately uses its own <c>"Bifrost-NexusAPIKey-check"</c> target
    /// instead, so it never touches whatever real key this developer has
    /// configured.
    /// </summary>
    public const string NexusApiKeyTarget = "Bifrost-NexusAPIKey";

    private static string DevFallbackPath(string target) =>
        Path.Combine(BifrostPaths.AppDataDir, "dev-credentials", $"{Sanitize(target)}.txt");

    private static string Sanitize(string target) =>
        string.Concat(target.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));

    public static void Save(string value, string target)
    {
        if (OperatingSystem.IsWindows())
        {
            SaveWindows(value, target);
            return;
        }

        // Dev-only fallback: plaintext, clearly marked, never used on a real
        // Windows install (guarded by IsWindows above).
        var path = DevFallbackPath(target);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, value);
    }

    public static string? Read(string target)
    {
        if (OperatingSystem.IsWindows())
        {
            return ReadWindows(target);
        }

        var path = DevFallbackPath(target);
        try
        {
            return File.Exists(path) ? File.ReadAllText(path) : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Returns true if an item existed and was removed, or if none existed to begin with (both are a successful "not there anymore").</summary>
    public static bool Delete(string target)
    {
        if (OperatingSystem.IsWindows())
        {
            return DeleteWindows(target);
        }

        var path = DevFallbackPath(target);
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
            return true;
        }
        catch
        {
            return false;
        }
    }

    // MARK: - Windows Credential Manager P/Invoke

    private const int CredTypeGeneric = 1;
    private const int CredPersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
    private static extern void CredFree(IntPtr credentialPtr);

    private static void SaveWindows(string value, string target)
    {
        // Single-item-per-target store: CredWrite already upserts (replaces
        // whatever's there for the same TargetName+Type), so no explicit
        // delete-first step is needed the way the macOS Keychain wrapper
        // needs before SecItemAdd.
        var bytes = Encoding.Unicode.GetBytes(value);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new CREDENTIAL
            {
                Type = CredTypeGeneric,
                TargetName = target,
                CredentialBlobSize = bytes.Length,
                CredentialBlob = blob,
                Persist = CredPersistLocalMachine,
                UserName = "Bifrost",
            };
            if (!CredWrite(ref credential, 0))
            {
                throw new InvalidOperationException($"CredWrite failed with error {Marshal.GetLastWin32Error()}");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    private static string? ReadWindows(string target)
    {
        if (!CredRead(target, CredTypeGeneric, 0, out var credentialPtr))
        {
            return null;
        }
        try
        {
            var credential = Marshal.PtrToStructure<CREDENTIAL>(credentialPtr);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return null;
            }
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.Unicode.GetString(bytes);
        }
        finally
        {
            CredFree(credentialPtr);
        }
    }

    private static bool DeleteWindows(string target)
    {
        // CredDelete fails with ERROR_NOT_FOUND when there's nothing to
        // delete — treated as success, same "not there anymore either way"
        // contract the macOS Keychain wrapper's delete() has.
        const int errorNotFound = 1168;
        if (CredDelete(target, CredTypeGeneric, 0))
        {
            return true;
        }
        return Marshal.GetLastWin32Error() == errorNotFound;
    }
}
