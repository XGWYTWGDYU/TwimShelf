// Why tagging a picture did not work, as the app shows it (the core's AiException, core/src/ai).
using TwimShelf.Core;
using static TwimShelf.Services.Strings;

namespace TwimShelf.AI;

/// BadTags: the model answered, but not with a list of tags (or with pieces of its syntax as tags);
/// NoTags: its list holds none.
public enum ExternalFailureKind { BadUrl, Http, NoModel, Empty, InvalidResponse, Transport, Timeout, Cancelled, SecretsUnavailable, Unreadable, BadTags, NoTags, NoGpu, Engine }

public sealed class ExternalFailure(ExternalFailureKind kind, int? status = null, string detail = "") : Exception(kind.ToString())
{
    public ExternalFailureKind Kind { get; } = kind;

    /// What the core reported.
    public static ExternalFailure FromCore(AiException e) =>
        new(Enum.TryParse<ExternalFailureKind>(e.Kind, ignoreCase: true, out var k) ? k : ExternalFailureKind.Engine, e.Status, e.Detail);
    public int? Status { get; } = status;
    /// Sanitized server text, never a request, header or credential.
    public string Detail { get; } = detail;

    public string MessageKey => Kind switch
    {
        ExternalFailureKind.BadUrl => "models.external.err.url",
        ExternalFailureKind.Http => "models.external.err.status",
        ExternalFailureKind.NoModel => "models.external.err.noModel",
        ExternalFailureKind.Empty or ExternalFailureKind.InvalidResponse => "models.external.err.empty",
        ExternalFailureKind.Unreadable => "ai.err.unreadable",
        ExternalFailureKind.BadTags => "ai.err.badReply",
        ExternalFailureKind.NoTags => "ai.err.noTags",
        ExternalFailureKind.NoGpu => "ai.err.noGpu",
        _ => "common.notDone",
    };

    public string Text
    {
        get
        {
            var label = Status == null ? L(MessageKey) : L(MessageKey, Status);
            return Detail.Length == 0 ? label : L("format.labelValue", label, Detail);
        }
    }
}
