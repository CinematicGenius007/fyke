namespace Fyke.ViewModels;

public static class CommandMatch
{
    /// <summary>Matches typed letters in order and favors word starts and consecutive runs.</summary>
    public static int? Score(string query, string title)
    {
        var at = 0;
        var previous = -2;
        var score = 0;
        var prefix = true;
        foreach (var letter in query)
        {
            if (char.IsWhiteSpace(letter))
            {
                continue;
            }

            var target = char.ToUpperInvariant(letter);
            var found = at;
            while (found < title.Length && char.ToUpperInvariant(title[found]) != target)
            {
                found++;
            }

            if (found == title.Length)
            {
                return null;
            }

            prefix &= found == at;
            score += found == previous + 1 ? 6 : 1;
            if (found == 0 || !char.IsLetterOrDigit(title[found - 1]))
            {
                score += 8;
            }
            else if (char.IsUpper(title[found]) && char.IsLower(title[found - 1]))
            {
                score += 4;
            }

            previous = found;
            at = found + 1;
        }

        return at == 0 ? 0 : (score + (prefix ? 10 : 0)) * 100 - title.Length;
    }
}
