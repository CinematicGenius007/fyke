using System.Text.Json;
using System.Text.Json.Nodes;

namespace Fyke.Client;

/// <summary>
/// The <c>params</c> member of a request. The daemon reads a missing member as "not given",
/// so a member whose value is null is left out at any depth.
/// </summary>
public static class DaemonParameters
{
    public static void Write(Utf8JsonWriter writer, JsonObject? parameters)
    {
        ArgumentNullException.ThrowIfNull(writer);
        WriteWithoutNulls(writer, parameters ?? []);
    }

    /// <summary>The parameters as the daemon receives them.</summary>
    public static JsonElement ToElement(JsonObject? parameters)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            Write(writer, parameters);
        }

        using var document = JsonDocument.Parse(stream.ToArray());
        return document.RootElement.Clone();
    }

    private static void WriteWithoutNulls(Utf8JsonWriter writer, JsonNode node)
    {
        switch (node)
        {
            case JsonObject members:
                writer.WriteStartObject();
                foreach (var (name, value) in members)
                {
                    if (value is not null)
                    {
                        writer.WritePropertyName(name);
                        WriteWithoutNulls(writer, value);
                    }
                }

                writer.WriteEndObject();
                break;
            case JsonArray items:
                writer.WriteStartArray();
                foreach (var item in items)
                {
                    if (item is null)
                    {
                        writer.WriteNullValue();
                    }
                    else
                    {
                        WriteWithoutNulls(writer, item);
                    }
                }

                writer.WriteEndArray();
                break;
            default:
                node.WriteTo(writer);
                break;
        }
    }

}
