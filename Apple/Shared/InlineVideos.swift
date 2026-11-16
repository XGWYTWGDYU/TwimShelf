import AVFoundation

/// The home feed's autoplaying videos: every video card that is (at least half) in view plays,
/// muted and looping, each with a player of its own; there is no limit on how many.
/// A card that leaves gives its player back (paused and emptied), and the next card takes it.
@MainActor
final class InlineVideos<Host: AnyObject> {
    private struct Slot {
        weak var host: Host?
        let player: AVPlayer
        let url: URL
    }

    private var slots: [ObjectIdentifier: Slot] = [:]
    private var idle: [AVPlayer] = []
    /// Players kept for the next cards (a player without an item holds no decoder).
    private let keep = 12
    /// Puts the player on the card and gives it the video; called once per start.
    private let attach: (Host, AVPlayer, URL) -> Void
    /// Takes the player off the card (`nil` when the card itself is gone); the key is the card's.
    private let detach: (ObjectIdentifier, Host?) -> Void
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// Puts a player that is already playing this card's video back on it (the full-screen player
    /// gives back the card's own player: no new item, no seek).
    private let adopt: ((Host, AVPlayer) -> Void)?
    /// A player given back by the full-screen player, waiting for its card to show again.
    private var returned: (player: AVPlayer, url: URL)?

    init(attach: @escaping (Host, AVPlayer, URL) -> Void, detach: @escaping (ObjectIdentifier, Host?) -> Void, adopt: ((Host, AVPlayer) -> Void)? = nil) {
        self.attach = attach
        self.detach = detach
        self.adopt = adopt
        observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let item = n.object as? AVPlayerItem,
                      let p = self.slots.values.first(where: { $0.player.currentItem === item })?.player else { return }
                p.seek(to: .zero)
                p.play()
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var isEmpty: Bool { slots.isEmpty }

    /// The player playing on this card, if one is.
    func player(for host: Host) -> AVPlayer? {
        guard let s = slots[ObjectIdentifier(host)], s.host === host else { return nil }
        return s.player
    }

    /// The player of the first playing card that matches.
    func player(where match: (Host) -> Bool) -> AVPlayer? {
        slots.values.first { $0.host.map(match) ?? false }?.player
    }

    /// Plays exactly these cards' videos: the others stop, the new ones start, the rest go on.
    func show(_ wanted: [(Host, URL)]) {
        var going = Set<ObjectIdentifier>()
        for (h, u) in wanted {
            let id = ObjectIdentifier(h)
            if let s = slots[id], s.host === h, s.url == u { going.insert(id) }
        }
        for id in Array(slots.keys) where !going.contains(id) { stop(id) }
        for (h, u) in wanted where !going.contains(ObjectIdentifier(h)) { start(h, u) }
    }

    /// The full-screen player opens this card's video: the card's player, taken off the card as it
    /// is (still playing, at its moment), or nil when the card plays nothing now.
    func lend(for host: Host) -> AVPlayer? {
        let id = ObjectIdentifier(host)
        guard adopt != nil, let s = slots[id], s.host === host else { return nil }
        // the card keeps showing it (one player can draw on two layers): while the viewer opens
        // over the feed and closes again, the card shows the moment playing, not its still frame
        slots.removeValue(forKey: id)
        NSLog("TwimShelf video: lent to the viewer at %.2f s", s.player.currentTime().seconds)
        return s.player
    }

    /// `lend(for:)` for the first playing card that matches.
    func lend(where match: (Host) -> Bool) -> AVPlayer? {
        guard let h = slots.values.first(where: { $0.host.map(match) ?? false })?.host else { return nil }
        return lend(for: h)
    }

    /// The full-screen player is done with a card's player: the card takes it back when it shows
    /// again (see `show`), and goes on from where it was.
    func giveBack(_ player: AVPlayer, url: URL) {
        returned = (player, url)
        NSLog("TwimShelf video: given back at %.2f s", player.currentTime().seconds)
    }

    func stop(where match: (Host) -> Bool) {
        for (id, s) in slots where s.host.map(match) ?? true { stop(id) }
    }

    func stopAll() {
        for id in Array(slots.keys) { stop(id) }
    }

    /// A given-back player whose card did not show again: it goes (paused and emptied).
    func dropReturned() {
        guard let r = returned else { return }
        returned = nil
        r.player.pause()
        r.player.replaceCurrentItem(with: nil)
    }

    private func start(_ host: Host, _ url: URL) {
        let id = ObjectIdentifier(host)
        stop(id)
        // the card's own player, back from the full-screen player: on the card as it is
        if let r = returned, r.url == url, let adopt {
            returned = nil
            r.player.isMuted = true
            slots[id] = Slot(host: host, player: r.player, url: url)
            adopt(host, r.player)
            NSLog("TwimShelf video: back on the card at %.2f s (same player)", r.player.currentTime().seconds)
            return
        }
        let p = idle.popLast() ?? {
            let p = AVPlayer()
            p.isMuted = true
            p.actionAtItemEnd = .none
            p.automaticallyWaitsToMinimizeStalling = false
            return p
        }()
        slots[id] = Slot(host: host, player: p, url: url)
        attach(host, p, url)
    }

    private func stop(_ id: ObjectIdentifier) {
        guard let s = slots.removeValue(forKey: id) else { return }
        s.player.pause()
        s.player.replaceCurrentItem(with: nil)
        detach(id, s.host)
        if idle.count < keep { idle.append(s.player) }
    }
}
