import UIKit

/// A slim progress bar: a quiet track and a solid fill in the accent colour that follows the value
/// smoothly. With no value (a task whose size is not known) a short piece of fill passes along
/// the track, slowly. Nothing else: no gradient, no shine.
final class SlimProgressBar: UIView {
    private let fill = UIView()
    private var value: Double?
    private var passing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.label.withAlphaComponent(0.1)
        layer.cornerRadius = 2
        layer.cornerCurve = .continuous
        clipsToBounds = true
        fill.backgroundColor = tintColor
        fill.layer.cornerRadius = 2
        fill.layer.cornerCurve = .continuous
        addSubview(fill)
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 4) }

    override func tintColorDidChange() { super.tintColorDidChange(); fill.backgroundColor = tintColor }

    override func layoutSubviews() {
        super.layoutSubviews()
        place(animated: false)
    }

    func set(_ v: Double?, animated: Bool = true) {
        let wasUnknown = value == nil
        value = v.map { min(max($0, 0), 1) }
        place(animated: animated, restart: wasUnknown != (value == nil))
    }

    private func place(animated: Bool, restart: Bool = false) {
        guard bounds.width > 0 else { return }
        fill.layer.removeAllAnimations()
        if let v = value {
            passing = false
            let apply = { self.fill.frame = CGRect(x: 0, y: 0, width: max(self.bounds.height, self.bounds.width * CGFloat(v)), height: self.bounds.height) }
            if animated && !restart { UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: apply) } else { apply() }
        } else {
            // unknown size: a piece of a third of the track passes along it
            let w = bounds.width * 0.32
            fill.frame = CGRect(x: -w, y: 0, width: w, height: bounds.height)
            passing = true
            UIView.animate(withDuration: 1.5, delay: 0, options: [.repeat, .curveEaseInOut]) { self.fill.frame.origin.x = self.bounds.width }
        }
    }
}

/// One running task: flipping thumbnail of the current item, title, detail and progress.
final class ActivityCardView: UIView {
    private let thumb = UIImageView()
    private let thumbHost = UIView()
    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let bar = SlimProgressBar()
    private var previewPath: String?
    private var kind: Activity.Kind?

    init(compact: Bool = false) {
        super.init(frame: .zero)
        thumbHost.layer.cornerRadius = 9
        thumbHost.layer.cornerCurve = .continuous
        thumbHost.clipsToBounds = true
        thumbHost.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15)
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        symbol.tintColor = .tintColor
        symbol.contentMode = .center
        symbol.preferredSymbolConfiguration = .init(pointSize: 17, weight: .semibold)
        [symbol, thumb].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; thumbHost.addSubview($0) }
        titleLabel.font = .systemFont(ofSize: compact ? 14 : 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel, bar])
        text.axis = .vertical
        text.spacing = 4
        text.setCustomSpacing(7, after: detailLabel)
        let row = UIStackView(arrangedSubviews: [thumbHost, text])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let side: CGFloat = compact ? 38 : 46
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbHost.widthAnchor.constraint(equalToConstant: side), thumbHost.heightAnchor.constraint(equalToConstant: side),
            thumb.topAnchor.constraint(equalTo: thumbHost.topAnchor), thumb.bottomAnchor.constraint(equalTo: thumbHost.bottomAnchor),
            thumb.leadingAnchor.constraint(equalTo: thumbHost.leadingAnchor), thumb.trailingAnchor.constraint(equalTo: thumbHost.trailingAnchor),
            symbol.centerXAnchor.constraint(equalTo: thumbHost.centerXAnchor), symbol.centerYAnchor.constraint(equalTo: thumbHost.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func symbolName(_ k: Activity.Kind) -> String {
        switch k { case .download: "arrow.down.circle.fill"; case .model: "shippingbox.fill"; case .tagging: "sparkles"; case .sync: "arrow.triangle.2.circlepath"; case .verify: "checkmark.shield.fill"; case .importing: "square.and.arrow.down.on.square.fill" }
    }

    func update(_ a: Activity) {
        titleLabel.text = a.title
        detailLabel.text = a.detail
        bar.set(a.progress)
        if kind != a.kind {
            kind = a.kind
            // the mascot mode: shopping for a download, the camera for AI tagging
            let mascot: String? = !Mascot.isOn ? nil : a.kind == .download ? "bag" : a.kind == .tagging ? "camera" : nil
            symbol.image = mascot.map { Mascot.icon($0, side: 40) } ?? UIImage(systemName: Self.symbolName(a.kind))
            // the crab lies on the card as it is, with no tile around it
            thumbHost.backgroundColor = mascot != nil ? .clear : UIColor.tintColor.withAlphaComponent(0.15)
            if a.kind == .sync { spin(symbol) } else { symbol.layer.removeAllAnimations() }
        }
        guard a.previewPath != previewPath else { return }
        previewPath = a.previewPath
        guard let path = a.previewPath else {
            UIView.transition(with: thumbHost, duration: 0.3, options: .transitionCrossDissolve) { self.thumb.image = nil; self.symbol.isHidden = false }
            return
        }
        MediaLoader.shared.load(path: path, isVideo: a.previewIsVideo, maxPixel: 160) { [weak self] img in
            guard let self, self.previewPath == path else { return }
            // Each new item flips in like a card being dealt.
            UIView.transition(with: self.thumbHost, duration: 0.45, options: [.transitionFlipFromRight, .allowAnimatedContent]) {
                self.thumb.image = img
                self.symbol.isHidden = img != nil
            }
        }
    }

    private func spin(_ v: UIView) {
        let r = CABasicAnimation(keyPath: "transform.rotation")
        r.toValue = Double.pi * 2
        r.duration = 1.4
        r.repeatCount = .infinity
        v.layer.add(r, forKey: "spin")
    }
}

/// Floating glass panel above the feed's bottom bar listing every running task.
final class ActivityPanel: UIView {
    private let stack = UIStackView()
    private var cards: [Activity.Kind: ActivityCardView] = [:]
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) { effect = UIGlassEffect() } else { effect = UIBlurEffect(style: .systemChromeMaterial) }
        let bg = UIVisualEffectView(effect: effect)
        bg.layer.cornerRadius = 22
        bg.layer.cornerCurve = .continuous
        bg.clipsToBounds = true
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: topAnchor), bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor), bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        isHidden = true
        alpha = 0
        accessibilityIdentifier = "activityPanel"
        observer = NotificationCenter.default.addObserver(forName: ActivityCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render(ActivityCenter.shared.activities) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func render(_ list: [Activity]) {
        let kinds = Set(list.map(\.kind))
        for (k, v) in cards where !kinds.contains(k) {
            cards[k] = nil
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: { v.alpha = 0; v.isHidden = true }) { _ in v.removeFromSuperview() }
        }
        for a in list {
            let card = cards[a.kind] ?? {
                let c = ActivityCardView(compact: true)
                c.alpha = 0
                c.isHidden = true
                stack.addArrangedSubview(c)
                cards[a.kind] = c
                return c
            }()
            card.update(a)
            if card.isHidden { UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { card.isHidden = false; card.alpha = 1 } }
        }
        let show = !list.isEmpty
        guard show == isHidden else { return }
        if show {
            isHidden = false
            transform = CGAffineTransform(translationX: 0, y: 20).scaledBy(x: 0.96, y: 0.96)
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.4) { self.alpha = 1; self.transform = .identity }
        } else {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: { self.alpha = 0; self.transform = CGAffineTransform(translationX: 0, y: 16) }) { _ in
                self.isHidden = true; self.transform = .identity
            }
        }
    }
}

/// Library totals (posts · photos · videos · tags) with a bounce when a number changes.
final class StatsCardView: UIView {
    private var values: [UILabel] = []
    private var last: [Int] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        let items: [(String, String, UIColor)] = [(L("common.posts"), "text.bubble.fill", .systemBlue), (L("search.kw.photo.word"), "photo.fill", .systemOrange),
                                                  (L("place.videos"), "play.rectangle.fill", .systemPink), (L("common.tags"), "tag.fill", .systemPurple)]
        let cols = items.map { (name, sym, color) -> UIView in
            let icon = UIImageView(image: UIImage(systemName: sym))
            icon.tintColor = color
            icon.preferredSymbolConfiguration = .init(pointSize: 13, weight: .semibold)
            let v = UILabel()
            v.font = .systemFont(ofSize: 24, weight: .bold).rounded
            v.text = "—"
            v.adjustsFontSizeToFitWidth = true
            v.minimumScaleFactor = 0.6
            values.append(v)
            let l = UILabel()
            l.text = name
            l.font = .systemFont(ofSize: 12, weight: .medium)
            l.textColor = .secondaryLabel
            let head = UIStackView(arrangedSubviews: [icon, l]); head.spacing = 4
            let st = UIStackView(arrangedSubviews: [v, head])
            st.axis = .vertical; st.alignment = .leading; st.spacing = 2
            return st
        }
        let row = UIStackView(arrangedSubviews: cols)
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                                     row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor)])
        accessibilityIdentifier = "statsCard"
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ s: LibraryStats?) {
        let nums = [s?.posts, s?.photos, s?.videos, s?.tags].map { $0 ?? 0 }
        for (i, l) in values.enumerated() {
            let changed = last.count == nums.count && last[i] != nums[i]
            l.text = "\(nums[i])"
            l.accessibilityLabel = "\(nums[i])"
            if changed {
                l.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
                UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.8) { l.transform = .identity }
            }
        }
        last = nums
    }
}

extension UIFont {
    var rounded: UIFont { fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: pointSize) } ?? self }
}
