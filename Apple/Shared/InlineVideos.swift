import AVFoundation

/// Muted autoplay for the browse feed. A partly visible card can show its paused frame before
/// it is far enough into view to play. A few recently used players stay paused with their items.
@MainActor
final class InlineVideos<Host: AnyObject> {
    @MainActor private final class Slot {
        weak var host: Host?
        let player: AVPlayer
        let mediaId: String
        let url: URL
        var wantsPlayback: Bool
        var ready = false
        var playing = false

        init(host: Host, player: AVPlayer, item: FeedItem, playing: Bool) {
            self.host = host
            self.player = player
            mediaId = item.mediaId
            url = item.fileURL
            wantsPlayback = playing
        }

        func matches(_ item: FeedItem) -> Bool { mediaId == item.mediaId && url == item.fileURL }
    }

    typealias Card = (host: Host, item: FeedItem, playing: Bool)

    private var slots: [ObjectIdentifier: Slot] = [:]
    private var idle: [AVPlayer] = []
    private var parked: [Slot] = []
    private var positions: [String: CMTime] = [:]
    private let frames = NSCache<NSURL, CGImage>()
    private var frameRequests: [(url: URL, generator: AVAssetImageGenerator)] = []
    private let attach: (Host, AVPlayer) -> Void
    private let detach: (ObjectIdentifier, Host?) -> Void
    private let frameReady: (URL, CGImage) -> Void
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// The card's own player stays on the card and is also used by the full-screen viewer.
    private var lent: Slot?
    private var returned: Slot?

    init(attach: @escaping (Host, AVPlayer) -> Void,
         detach: @escaping (ObjectIdentifier, Host?) -> Void,
         frameReady: @escaping (URL, CGImage) -> Void) {
        self.attach = attach
        self.detach = detach
        self.frameReady = frameReady
        frames.totalCostLimit = 24 * 1024 * 1024
        observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let item = n.object as? AVPlayerItem,
                      let slot = self.slots.values.first(where: { $0.player.currentItem === item }),
                      slot.playing else { return }
                slot.player.seek(to: .zero)
                slot.player.play()
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func position(for mediaId: String) -> CMTime { positions[mediaId] ?? .zero }
    func frame(for url: URL) -> CGImage? { frames.object(forKey: url as NSURL) }

    func prefetchFrame(for item: FeedItem) {
        guard item.kind == .video, frameRequests.count < 2 else { return }
        let url = item.fileURL
        let time = position(for: item.mediaId)
        guard time > .zero, frame(for: url) == nil,
              !frameRequests.contains(where: { $0.url == url }) else { return }
        generateFrame(at: time, from: AVURLAsset(url: url), url: url)
    }

    func savePosition(_ time: CMTime, for mediaId: String) {
        guard time.isNumeric, time >= .zero, time != position(for: mediaId) else { return }
        positions[mediaId] = time == .zero ? nil : time
        // A separate full-screen player may have moved past this parked player.
        if let index = parked.firstIndex(where: { $0.mediaId == mediaId }) {
            recycle(parked.remove(at: index).player)
        }
    }

    /// Keeps partial cards paused. Only videos that already have a position prepare before
    /// reaching the autoplay threshold, so a fling doesn't start decoding each passing card.
    func show(_ wanted: [Card]) {
        let visible = Dictionary(uniqueKeysWithValues: wanted.map { (ObjectIdentifier($0.host), $0) })
        for (id, slot) in slots {
            guard let card = visible[id], slot.host === card.host, slot.matches(card.item) else {
                stop(id)
                continue
            }
            slot.wantsPlayback = card.playing
            updatePlayback(slot)
        }
        if let r = returned, let host = r.host, let card = visible[ObjectIdentifier(host)], r.matches(card.item) {
            start(card)
        }
        for card in wanted where slots[ObjectIdentifier(card.host)] == nil {
            if card.playing || position(for: card.item.mediaId) > .zero { start(card) }
        }
    }

    func lend(for host: Host, item: FeedItem) -> AVPlayer? {
        let id = ObjectIdentifier(host)
        guard let slot = slots[id], slot.host === host, slot.matches(item), slot.ready else { return nil }
        slots.removeValue(forKey: id)
        lent = slot
        NSLog("TwimShelf video: lent to the viewer at %.2f s", slot.player.currentTime().seconds)
        return slot.player
    }

    func giveBack(_ player: AVPlayer) {
        guard let lent, lent.player === player else { return }
        self.lent = nil
        player.isMuted = true
        // as it really is (paused in the viewer, it starts again when the card wants it to)
        lent.playing = player.rate != 0
        rememberFrame(lent)
        returned = lent
        NSLog("TwimShelf video: given back at %.2f s", player.currentTime().seconds)
    }

    func stop(where match: (Host) -> Bool) {
        for (id, slot) in slots where slot.host.map(match) ?? true { stop(id) }
    }

    func stopAll() {
        for id in Array(slots.keys) { stop(id) }
        for slot in parked { recycle(slot.player) }
        parked.removeAll()
    }

    func dropReturned() {
        guard let slot = returned else { return }
        returned = nil
        detachOriginal(slot)
        park(slot)
    }

    private func detachOriginal(_ slot: Slot) {
        guard let host = slot.host else { return }
        let id = ObjectIdentifier(host)
        if slots[id] == nil { detach(id, host) }
    }

    private func start(_ card: Card) {
        let (host, item, playing) = card
        let id = ObjectIdentifier(host)
        let slot: Slot
        if let previous = returned, previous.matches(item) {
            returned = nil
            if previous.host !== host { detachOriginal(previous) }
            slot = previous
        } else if let index = parked.firstIndex(where: { $0.matches(item) }) {
            slot = parked.remove(at: index)
        } else {
            let player = idle.popLast() ?? {
                let player = AVPlayer()
                player.isMuted = true
                player.actionAtItemEnd = .none
                player.automaticallyWaitsToMinimizeStalling = false
                return player
            }()
            slot = Slot(host: host, player: player, item: item, playing: playing)
        }
        slot.host = host
        slot.wantsPlayback = playing
        slots[id] = slot
        if slot.ready {
            attach(host, slot.player)
            updatePlayback(slot)
            return
        }

        let asset = AVURLAsset(url: slot.url)
        Task { [weak self, weak slot] in
            guard (try? await asset.load(.isPlayable)) == true, let self, let slot,
                  self.slots[id] === slot else { return }
            slot.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            let time = self.position(for: slot.mediaId)
            if time > .zero {
                // Attach the layer only after the seek completes so the first decoded frame
                // from the new item can never cover the card's still frame.
                guard await slot.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero),
                      self.slots[id] === slot else { return }
            }
            guard let host = slot.host else { return }
            slot.ready = true
            self.attach(host, slot.player)
            self.updatePlayback(slot)
        }
    }

    private func updatePlayback(_ slot: Slot) {
        guard slot.ready, slot.playing != slot.wantsPlayback else { return }
        slot.playing = slot.wantsPlayback
        if slot.playing {
            slot.player.play()
        } else {
            slot.player.pause()
            rememberFrame(slot)
        }
    }

    private func stop(_ id: ObjectIdentifier) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        slot.wantsPlayback = false
        updatePlayback(slot)
        detach(id, slot.host)
        if slot.ready { park(slot) } else { recycle(slot.player) }
    }

    private func park(_ slot: Slot) {
        slot.player.pause()
        slot.playing = false
        slot.host = nil
        if let index = parked.firstIndex(where: { $0.mediaId == slot.mediaId }) {
            recycle(parked.remove(at: index).player)
        }
        parked.append(slot)
        if parked.count > 4 { recycle(parked.removeFirst().player) }
    }

    private func recycle(_ player: AVPlayer) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if idle.count < 12 { idle.append(player) }
    }

    /// Keep a small still frame for the next appearance, even after the cell or decoder is reused.
    private func rememberFrame(_ slot: Slot) {
        let time = slot.player.currentTime()
        guard time.isNumeric, let asset = slot.player.currentItem?.asset else { return }
        savePosition(time, for: slot.mediaId)
        generateFrame(at: time, from: asset, url: slot.url)
    }

    private func generateFrame(at time: CMTime, from asset: AVAsset, url: URL) {
        if let index = frameRequests.firstIndex(where: { $0.url == url }) {
            frameRequests.remove(at: index).generator.cancelAllCGImageGeneration()
        }
        if frameRequests.count >= 4 { frameRequests.removeFirst().generator.cancelAllCGImageGeneration() }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = .zero
        frameRequests.append((url, generator))
        Task { [weak self] in
            let image = try? await generator.image(at: time).image
            guard let self, let index = self.frameRequests.firstIndex(where: { $0.generator === generator }) else { return }
            self.frameRequests.remove(at: index)
            guard let image else { return }
            self.frames.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
            self.frameReady(url, image)
        }
    }
}

/// Keep the still frame visible until this particular player has a frame for the card.
@MainActor
func attachInlineVideo(_ player: AVPlayer, to layer: AVPlayerLayer) -> NSKeyValueObservation? {
    guard layer.player !== player else { return nil }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 0
    layer.player = player
    CATransaction.commit()
    return layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak player] layer, _ in
        guard layer.isReadyForDisplay else { return }
        DispatchQueue.main.async {
            guard let player, layer.player === player, layer.isReadyForDisplay else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 1
            CATransaction.commit()
        }
    }
}
