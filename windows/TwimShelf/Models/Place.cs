// A place of the library: the same set and ids as the other apps' places (browse, the media kinds,
// the folders, the special collections, settings).
using TwimShelf.Core;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Models;

public sealed record Place(string Id, string? Folder = null)
{
    public static readonly Place Browse = new("browse");
    public static readonly Place Photos = new("photos");
    public static readonly Place Videos = new("videos");
    public static readonly Place AllFolders = new("folders");
    public static readonly Place Loose = new("loose");
    public static readonly Place Album = new("album");
    public static readonly Place Favorites = new("favorites");
    public static readonly Place Unreviewed = new("unreviewed");
    public static readonly Place Reviewed = new("reviewed");
    public static readonly Place Bad = new("bad");
    public static readonly Place Trash = new("trash");
    public static readonly Place Settings = new("settings");
    public static Place OfFolder(string name) => new("folder:" + name, name);

    public string Title => Folder ?? L("place." + Id);

    /// Segoe Fluent Icons glyph of this place.
    /// Segoe Fluent Icons glyph of this place (the Mac sidebar's symbols, in Fluent).
    public string Glyph => Id switch
    {
        "browse" => "\uE8B9",     // pictures (photo.on.rectangle.angled)
        "photos" => "\uEB9F",     // photo
        "videos" => "\uE714",     // video
        "folders" => "\uE8F1",    // library (rectangle.stack)
        "loose" => "\uE7C3",      // page (square.dashed)
        "album" => "\uE91B",      // photo collection (photo.on.rectangle)
        "favorites" => "\uE735",  // favorite star (star.fill)
        "unreviewed" => "\uE739", // empty check (seal)
        "reviewed" => "\uE73E",   // check mark (checkmark.seal)
        "bad" => "\uE7BA",        // warning
        "trash" => "\uE74D",      // delete
        "settings" => "\uE713",   // setting (gearshape)
        _ => "\uE8B7",            // folder
    };

    /// The media a grid of this place shows; null for places that are not a grid.
    public FeedFilter? Filter => Id switch
    {
        "photos" => new FeedFilter { Kind = MediaKind.Photo },
        "videos" => new FeedFilter { Kind = MediaKind.Video },
        "loose" => new FeedFilter { LooseOnly = true },
        "album" => new FeedFilter { AlbumOnly = true },
        "favorites" => new FeedFilter { FavoriteOnly = true },
        "unreviewed" => new FeedFilter { Review = ReviewFilter.Unreviewed },
        "reviewed" => new FeedFilter { Review = ReviewFilter.Reviewed },
        "bad" => new FeedFilter { BadOnly = true },
        _ => Folder != null ? new FeedFilter { Folder = Folder } : null,
    };

    public bool IsGrid => Filter != null || Id == "trash";

    public static readonly Place[] MediaKinds = [Photos, Videos];
    static readonly Place[] Others = [Loose, Album, Favorites, Unreviewed, Reviewed, Bad, Trash];
    /// 损坏或丢失 is offered while the maintenance rows of 关于 are out.
    public static IEnumerable<Place> Offered => Others.Where(p => p != Bad || Prefs.Instance.AboutExtras);
}
