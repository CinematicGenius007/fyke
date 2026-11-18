using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ReaderTypographyTests
{
    [Fact]
    public async Task LoadsIndependentWeightStepsFromTheDaemonProfile()
    {
        using var config = JsonDocument.Parse("""
            {"ui":{"weights":{"reading":-2,"title":2,"ui":1,"code":-1}},"config_error":null}
            """);
        var client = new FakeClient
        {
            OnCall = (method, _) =>
            {
                Assert.Equal("config.get", method);
                return config.RootElement;
            },
        };

        var typography = await new ReaderData(client).TypographyAsync(CancellationToken.None);

        Assert.Equal(new ReaderTypography(-2, 2, 1, -1), typography);
    }

    [Fact]
    public void ClampsOutOfRangeStepsAndDefaultsInvalidFieldsIndependently()
    {
        using var config = JsonDocument.Parse("""
            {"ui":{"weights":{"reading":-50,"title":9000000000,"ui":"1","code":1.5}}}
            """);

        Assert.Equal(new ReaderTypography(-2, 2, 0, 0), ReaderTypography.FromConfig(config.RootElement));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"ui\":null}")]
    [InlineData("{\"ui\":{\"theme\":\"dark\"}}")]
    [InlineData("{\"ui\":{\"weights\":[]}}")]
    [InlineData("{\"config_error\":\"SyntaxError\",\"ui\":{\"weights\":{\"reading\":2}}}")]
    public void MissingOrUnreadablePreferencesUseDefaults(string json)
    {
        using var config = JsonDocument.Parse(json);

        Assert.Equal(default, ReaderTypography.FromConfig(config.RootElement));
    }

    [Theory]
    [InlineData(ReaderTypography.Regular, -2, 200)]
    [InlineData(ReaderTypography.Regular, 0, 400)]
    [InlineData(ReaderTypography.Regular, 2, 600)]
    [InlineData(ReaderTypography.Semibold, -2, 400)]
    [InlineData(ReaderTypography.Semibold, 2, 800)]
    public void ShiftsTheBaselineByTheSelectedSteps(int baseline, int step, int expected)
    {
        Assert.Equal(expected, ReaderTypography.Shift((ushort)baseline, step));
    }
}
