using System.Text;
using System.Text.Json.Nodes;

namespace ChatGPTMultiAccounts.Core;

/// <summary>Who a ChatGPT folder is signed in to, read from its <c>auth.json</c>.
///
/// ChatGPT keeps its sign-in in <c>&lt;CODEX_HOME&gt;\auth.json</c>: the OAuth tokens and the ID token that names
/// the account. Only the ID token's public claims (email, name, plan, workspace) are read here. The tokens are never
/// copied, sent anywhere or shown, and every copy of ChatGPT signs in on its own, so no two copies ever share (and
/// fight over) one set of tokens.</summary>
public sealed record SignIn(string Mode = "chatgpt", string? Email = null, string? Name = null, string? Plan = null,
                            string? UserId = null, string? WorkspaceId = null)
{
    /// <summary>Two folders signed in to the same person in the same workspace are the same account.</summary>
    public string? Identity => (UserId ?? Email?.ToLowerInvariant()) is string who ? $"{who}|{WorkspaceId}" : null;

    /// <summary>"Plus", "Team"… for the list.</summary>
    public string? PlanName
    {
        get
        {
            if (Mode != "chatgpt") return "API key";
            if (string.IsNullOrEmpty(Plan)) return null;
            return char.ToUpperInvariant(Plan[0]) + Plan[1..];
        }
    }

    /// <summary>The email, or what else names the sign-in.</summary>
    public string Label => Email ?? Name ?? (Mode == "apikey" ? "an API key" : "a ChatGPT account");

    public const string File = "auth.json";
    const string AuthClaims = "https://api.openai.com/auth";

    /// <summary>The sign-in in a CODEX_HOME. Null when it is signed out (or keeps its sign-in elsewhere).</summary>
    public static SignIn? Read(string codexHome)
    {
        if (Files.ReadJson(Path.Combine(codexHome, File)) is not JsonObject json) return null;
        var tokens = json["tokens"] as JsonObject;
        string mode = Str(json["auth_mode"]) ?? (tokens != null ? "chatgpt" : "apikey");
        if (mode == "apikey" || tokens == null)
            return Str(json["OPENAI_API_KEY"]) is { Length: > 0 } ? new SignIn("apikey") : null;
        if (Str(tokens["id_token"]) is not { Length: > 0 } idToken) return null;
        var claims = Claims(idToken) ?? new JsonObject();
        var auth = claims[AuthClaims] as JsonObject ?? new JsonObject();
        return new SignIn(mode,
            Email: Str(claims["email"]),
            Name: Str(claims["name"]),
            Plan: Str(auth["chatgpt_plan_type"]),
            UserId: Str(auth["chatgpt_user_id"]) ?? Str(auth["user_id"]) ?? Str(claims["sub"]),
            WorkspaceId: Str(auth["chatgpt_account_id"]) ?? Str(tokens["account_id"]));
    }

    /// <summary>The payload of a JWT, decoded without checking its signature: it only names the account.</summary>
    public static JsonObject? Claims(string jwt)
    {
        var parts = jwt.Split('.');
        if (parts.Length < 2) return null;
        string base64 = parts[1].Replace('-', '+').Replace('_', '/');
        base64 += new string('=', (4 - base64.Length % 4) % 4);
        try { return JsonNode.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(base64))) as JsonObject; }
        catch { return null; }
    }

    static string? Str(JsonNode? node)
    {
        try { return node?.GetValue<string>(); }
        catch { return null; }
    }
}
