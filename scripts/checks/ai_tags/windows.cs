#!/usr/bin/env dotnet
// The Windows parser of model replies (windows/TwimShelf/AI/TagReply.cs) against the cases every
// app's parser follows (cases.json). On Windows, from the repository root:
//   dotnet run scripts/checks/ai_tags/windows.cs
#:property TargetFramework=net11.0
#:property Nullable=enable
#:property ImplicitUsings=enable
#:include ../../../windows/TwimShelf/AI/TagReply.cs
using System.Text.Json.Nodes;
using TwimShelf.AI;

var cases = JsonNode.Parse(File.ReadAllText("scripts/checks/ai_tags/cases.json"))!["cases"]!.AsArray();
var failed = 0;
foreach (var c in cases)
{
    var reply = (string)c!["reply"]!;
    string got;
    try { got = "tags " + string.Join("|", TagReply.Parse(reply)); }
    catch (ExternalFailure e) { got = e.Kind == ExternalFailureKind.NoTags ? "error none" : e.Kind == ExternalFailureKind.BadTags ? "error bad" : "error " + e.Kind; }
    var want = c["tags"] is JsonArray t ? "tags " + string.Join("|", t.Select(x => (string)x!)) : "error " + (string)c["error"]!;
    if (got != want) { Console.WriteLine($"ai_tags: {reply}: got {got}, want {want}"); failed++; }
}
if (failed > 0) return 1;
Console.WriteLine($"ai_tags (Windows): {cases.Count} cases");
return 0;

// the app's string catalog is not part of this check: keys stand in for texts
namespace TwimShelf.Services { static class Strings { public static string L(string key, params object?[] args) => key; } }
