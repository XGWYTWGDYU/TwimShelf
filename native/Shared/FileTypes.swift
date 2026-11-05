import UniformTypeIdentifiers

extension UTType {
    /// Library export package (zip of manifest.json + media/).
    static let tlpack = UTType(exportedAs: "org.twimshelf.tlpack", conformingTo: .zip)
}

/// Whether a stored media path is a video (MP4 or QuickTime); matches `rules::is_video_path`.
func isVideoPath(_ p: String) -> Bool {
    let l = p.lowercased()
    return l.hasSuffix(".mp4") || l.hasSuffix(".mov")
}
