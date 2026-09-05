using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bifrost.Core.Services;

/// <summary>
/// Writes GUIDs in the same uppercase, hyphenated form Swift's
/// <c>UUID().uuidString</c> produces (e.g.
/// "1B1500D7-B74A-46C6-AAEB-9449DA97D496"), so profiles.json stays
/// byte-shape-compatible with the macOS reference implementation. Reading
/// is unaffected — <see cref="Guid.Parse(string)"/> already accepts either
/// case.
/// </summary>
public sealed class UppercaseGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetGuid();

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}
