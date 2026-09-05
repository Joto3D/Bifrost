using System.IO.Pipes;

namespace Bifrost.Core.Services;

/// <summary>
/// Single-instance enforcement plus argument forwarding for the
/// <c>nxm://</c> protocol handoff: Windows launches a brand-new Bifrost.exe
/// process for every "Mod Manager Download" click (a registered URL
/// protocol always spawns a fresh process, it can't hand the URL to an
/// already-running one on its own), so a second launch needs to detect the
/// first instance, forward its command-line argument over, and exit —
/// rather than opening a second confusing Bifrost window per click.
///
/// Mechanism: a named <see cref="Mutex"/> to detect "am I the first
/// instance", and a named pipe to carry the forwarded argument text to
/// whichever process holds it. Both a named mutex and a named pipe are
/// supported cross-platform by .NET (Unix included via file-lock/socket
/// backing), so this exercises for real in <c>--check</c> on this Mac dev
/// machine — nothing here needs a Windows-only shim, unlike the registry
/// protocol registration itself (see <see cref="NxmProtocolRegistrar"/>).
/// </summary>
public sealed class SingleInstance : IDisposable
{
    public const string DefaultMutexName = "Bifrost-SingleInstance-Mutex";
    public const string DefaultPipeName = "Bifrost-SingleInstance-Pipe";

    private readonly string _pipeName;
    private Mutex? _mutex;
    private CancellationTokenSource? _listenerCts;

    /// <param name="mutexName">Defaults to <see cref="DefaultMutexName"/>.</param>
    /// <param name="pipeName">
    /// Defaults to <see cref="DefaultPipeName"/>. Keep any override short:
    /// .NET's named pipes are backed by real Windows named pipes on Windows
    /// (no length concern there) but by a Unix domain socket under the temp
    /// directory on macOS/Linux (<c>&lt;TMPDIR&gt;/CoreFxPipe_&lt;name&gt;</c>) — and
    /// `sockaddr_un` paths are capped at 104 bytes on macOS, so a long name
    /// combined with a long TMPDIR (this is why <c>--check</c>'s own fixture
    /// names stay short) throws <see cref="ArgumentOutOfRangeException"/>
    /// on this dev platform even though the identical name would be fine on
    /// a real Windows install.
    /// </param>
    public SingleInstance(string? mutexName = null, string? pipeName = null)
    {
        MutexName = mutexName ?? DefaultMutexName;
        _pipeName = pipeName ?? DefaultPipeName;
    }

    public string MutexName { get; }

    /// <summary>
    /// Attempts to become the primary instance. Returns true (and holds the
    /// mutex for the lifetime of this <see cref="SingleInstance"/>) if no
    /// other instance currently holds it; false if one already does, in
    /// which case the caller should forward its arguments via
    /// <see cref="TryForward"/> and exit without doing anything else.
    /// </summary>
    public bool AcquirePrimary()
    {
        _mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        if (!createdNew)
        {
            // Someone else holds it — release our own handle immediately,
            // we're not the primary instance.
            _mutex.Dispose();
            _mutex = null;
        }
        return createdNew;
    }

    /// <summary>
    /// Starts a background listener (only meaningful once this process is
    /// the primary instance) that invokes <paramref name="onMessageReceived"/>
    /// on the thread pool for every message a secondary instance forwards.
    /// Runs until <see cref="Dispose"/>. Never throws on connection errors —
    /// a broken/short-lived client is simply skipped and the server loops
    /// back to waiting for the next connection.
    /// </summary>
    public void StartListening(Action<string> onMessageReceived)
    {
        _listenerCts = new CancellationTokenSource();
        var token = _listenerCts.Token;
        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    await using var server = new NamedPipeServerStream(_pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                    await server.WaitForConnectionAsync(token);
                    using var reader = new StreamReader(server);
                    var line = await reader.ReadLineAsync(token);
                    if (!string.IsNullOrEmpty(line))
                    {
                        onMessageReceived(line);
                    }
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch
                {
                    // A client that connected and disconnected without
                    // writing, or any other transient pipe error — loop back
                    // and wait for the next connection rather than crashing
                    // the listener.
                    await Task.Delay(200, CancellationToken.None).ContinueWith(_ => { });
                }
            }
        }, CancellationToken.None);
    }

    /// <summary>
    /// Sends <paramref name="message"/> to whichever process is currently
    /// listening on <paramref name="pipeName"/> (defaulting to
    /// <see cref="DefaultPipeName"/>). Returns false (rather than throwing)
    /// if nothing is listening within <paramref name="timeoutMs"/> — the
    /// caller decides what that means (normally: proceed with a normal
    /// startup instead, since apparently there wasn't really a primary
    /// instance after all).
    /// </summary>
    public static bool TryForward(string message, string? pipeName = null, int timeoutMs = 2000)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", pipeName ?? DefaultPipeName, PipeDirection.Out);
            client.Connect(timeoutMs);
            using var writer = new StreamWriter(client) { AutoFlush = true };
            writer.WriteLine(message);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void Dispose()
    {
        _listenerCts?.Cancel();
        _listenerCts?.Dispose();
        // Deliberately no ReleaseMutex() call: this mutex is held for the
        // whole app session by whatever thread happened to construct it
        // (AcquirePrimary), and Mutex ownership in .NET is thread-affine —
        // calling ReleaseMutex() from a different thread (routine in an
        // async app, where a continuation can easily resume on another
        // thread pool thread) throws ApplicationException. Simply disposing
        // the handle is sufficient: the OS releases the mutex the moment
        // every handle to it closes, which happens here (explicitly) or
        // automatically on process exit either way.
        _mutex?.Dispose();
    }
}
