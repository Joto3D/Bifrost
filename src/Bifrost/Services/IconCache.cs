using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using Avalonia.Media.Imaging;
using Bifrost.Core.Services;

namespace Bifrost.Services;

/// <summary>
/// Downloads Thunderstore mod icons and caches them under
/// <c>%AppData%\Bifrost\icons\&lt;sha1(url)&gt;.png</c> so revisiting Browse
/// or Installed doesn't re-download the same icon every time. In-memory
/// task de-duplication (<see cref="_inflight"/>) means concurrently
/// requesting the same URL from several rows only downloads it once.
/// </summary>
public static class IconCache
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private static readonly ConcurrentDictionary<string, Task<Bitmap?>> Inflight = new();

    public static Task<Bitmap?> GetAsync(string url) => Inflight.GetOrAdd(url, LoadAsync);

    private static string CacheDir => Path.Combine(BifrostPaths.AppDataDir, "icons");

    private static async Task<Bitmap?> LoadAsync(string url)
    {
        try
        {
            Directory.CreateDirectory(CacheDir);
            var fileName = Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(url))) + ".png";
            var path = Path.Combine(CacheDir, fileName);

            if (File.Exists(path))
            {
                try
                {
                    return new Bitmap(path);
                }
                catch
                {
                    // Corrupt cache entry — fall through and re-download.
                }
            }

            var bytes = await Http.GetByteArrayAsync(url);
            using (var stream = new MemoryStream(bytes))
            {
                var bitmap = new Bitmap(stream);
                try
                {
                    await File.WriteAllBytesAsync(path, bytes);
                }
                catch
                {
                    // Best-effort disk cache — an in-memory result is still fine.
                }
                return bitmap;
            }
        }
        catch
        {
            return null;
        }
    }
}
