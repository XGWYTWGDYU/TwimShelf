import Foundation

/// A place of the library, as the sidebar lists them on the Mac and on a wide iPad (or an open
/// foldable): 浏览, the media kinds, the folders, and the special collections — like the
/// sidebar of Photos.
enum LibraryPlace: Hashable {
    case browse, photos, videos, allFolders, folder(String), loose, album, unreviewed, reviewed, bad, trash, settings

    /// A stable name (sidebar identifiers, accessibility, restoring the selection).
    var id: String {
        switch self {
        case .browse: "browse"
        case .photos: "photos"
        case .videos: "videos"
        case .allFolders: "folders"
        case .folder(let n): "folder:" + n
        case .loose: "loose"
        case .album: "album"
        case .unreviewed: "unreviewed"
        case .reviewed: "reviewed"
        case .bad: "bad"
        case .trash: "trash"
        case .settings: "settings"
        }
    }

    var title: String {
        switch self {
        case .folder(let n): n
        default: L("place." + id)      // i18n-keys: place.*
        }
    }

    var symbol: String {
        switch self {
        case .browse: "photo.on.rectangle.angled"
        case .photos: "photo"
        case .videos: "video"
        case .allFolders: "rectangle.stack"
        case .folder: "folder"
        case .loose: "square.dashed"
        case .album: "photo.on.rectangle"
        case .unreviewed: "seal"
        case .reviewed: "checkmark.seal"
        case .bad: "exclamationmark.triangle"
        case .trash: "trash"
        case .settings: "gearshape"
        }
    }

    /// The media a grid of this place shows (nil: not a grid).
    var filter: FeedFilter? {
        var f = FeedFilter()
        switch self {
        case .photos: f.kind = .photo
        case .videos: f.kind = .video
        case .folder(let n): f.folder = n
        case .loose: f.looseOnly = true
        case .album: f.albumOnly = true
        case .unreviewed: f.review = .unreviewed
        case .reviewed: f.review = .reviewed
        case .bad: f.badOnly = true
        case .browse, .allFolders, .trash, .settings: return nil
        }
        return f
    }

    var folderName: String? { if case .folder(let n) = self { return n }; return nil }
}
