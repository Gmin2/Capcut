import AppKit
import AVFoundation

/// Left column: every take on disk, newest first, plus the record button.
public final class RecordingsSidebar: ThemedView {

    public var onSelect: ((URL) -> Void)?
    public var onPlay: ((URL) -> Void)?
    public var onNewRecording: (() -> Void)?

    private let list = FlippedStack()
    private let countChip = Chip("0")
    public let newButton = FillButton("New Recording")
    private var cards: [TakeCard] = []

    public override init(frame: NSRect) {
        super.init(frame: frame)

        let back = IconButton(.chevronLeft, transparent: true)
        let title = Theme.label("Recordings", .body, color: Theme.textPrimary)
        let group = Theme.label("All takes", .bodyStrong, color: Theme.textPrimary)
        newButton.showsDot = true
        newButton.onClick = { [weak self] in self?.onNewRecording?() }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        list.orientation = .vertical
        list.spacing = 8
        list.alignment = .leading

        emptyNote.maximumNumberOfLines = 3
        emptyNote.alignment = .center
        // Theme.label truncates by default, which eats the second line
        emptyNote.lineBreakMode = .byWordWrapping
        emptyNote.preferredMaxLayoutWidth = 200
        for v in [back, title, group, countChip, newButton, scroll, emptyNote] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        list.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            back.widthAnchor.constraint(equalToConstant: 24),
            back.heightAnchor.constraint(equalToConstant: 24),
            title.centerYAnchor.constraint(equalTo: back.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),

            group.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 14),
            group.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            countChip.centerYAnchor.constraint(equalTo: group.centerYAnchor),
            countChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            newButton.topAnchor.constraint(equalTo: group.bottomAnchor, constant: 12),
            newButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            newButton.heightAnchor.constraint(equalToConstant: 30),

            emptyNote.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 40),
            emptyNote.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyNote.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shown instead of the list on a first run, since an empty sidebar
    /// looks broken rather than new.
    private let emptyNote = Theme.label("No takes yet.\nPress New Recording to make one.",
                                        .body, color: Theme.textTertiary)

    public func reload(selected: URL) {
        cards.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        cards = Paths.allRecordings().map { url in
            let card = TakeCard(url: url)
            card.onClick = { [weak self] in self?.onSelect?(url) }
            card.onPlay = { [weak self] in self?.onPlay?(url) }
            return card
        }
        for card in cards {
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            card.heightAnchor.constraint(equalToConstant: 104).isActive = true
        }
        countChip.text = "\(cards.count)"
        emptyNote.isHidden = !cards.isEmpty
        setSelected(selected)
    }

    // Compared by path: directory listings hand back urls with a trailing
    // slash, and URL equality treats that as a different location.
    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public func setSelected(_ url: URL) {
        let target = Self.key(url)
        for card in cards { card.selected = Self.key(card.url) == target }
    }

    public func setPlaying(_ url: URL?, _ playing: Bool) {
        let target = url.map(Self.key)
        for card in cards { card.playing = playing && Self.key(card.url) == target }
    }
}

final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// One take: its name, a small waveform, how long it runs.
final class TakeCard: Control {
    let url: URL
    var selected = false { didSet { needsDisplay = true } }
    var playing = false { didSet { needsDisplay = true } }
    var onPlay: (() -> Void)?

    private let title: String
    private let duration: Double
    private var peaks: [Float] = []

    private static var peakCache: [URL: [Float]] = [:]

    init(url: URL) {
        self.url = url
        title = url.lastPathComponent
        duration = Manifest.load(from: url.appendingPathComponent("recording.json"))?.screen.duration ?? 0
        super.init(frame: .zero)
        loadPeaks()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var playRect: NSRect { NSRect(x: bounds.maxX - 32, y: bounds.maxY - 32, width: 24, height: 24) }

    private func loadPeaks() {
        if let hit = TakeCard.peakCache[url] { peaks = hit; return }
        let manifest = Manifest.load(from: url.appendingPathComponent("recording.json"))
        guard let track = Waveform.preferredTrack(in: url, manifest: manifest) else { return }
        Task { [weak self, url] in
            let p = await Waveform.peaks(from: track, buckets: 48)
            await MainActor.run {
                TakeCard.peakCache[url] = p
                self?.peaks = p
                self?.needsDisplay = true
            }
        }
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.radiusCard, yRadius: Theme.radiusCard)
        (selected ? Theme.fillSelected : (hovering ? Theme.fill : Theme.inset)).setFill()
        path.fill()
        if selected {
            path.lineWidth = Theme.borderSelected
            Theme.cardOutline.setStroke()
            path.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.Text.body.font,
            .foregroundColor: selected ? Theme.textPrimary : Theme.textSecondary,
        ]
        let titleRect = NSRect(x: 10, y: 9, width: bounds.width - 20, height: 18)
        (title as NSString).draw(with: titleRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                 attributes: attrs)

        drawWave(in: NSRect(x: 10, y: 32, width: bounds.width - 20, height: 34))

        let time = String(format: "%d:%02d", Int(duration) / 60, Int(duration.rounded()) % 60)
        let tattrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.meta.font,
                                                     .foregroundColor: Theme.textPrimary]
        (time as NSString).draw(at: NSPoint(x: 10, y: bounds.maxY - 26), withAttributes: tattrs)

        let pr = playRect
        (selected ? Theme.textStrong : Theme.fill).setFill()
        NSBezierPath(roundedRect: pr, xRadius: 5, yRadius: 5).fill()
        (selected ? Theme.canvas : Theme.icon).setFill()
        let c = NSPoint(x: pr.midX, y: pr.midY)
        if playing {
            NSRect(x: c.x - 4, y: c.y - 5, width: 3, height: 10).fill()
            NSRect(x: c.x + 1, y: c.y - 5, width: 3, height: 10).fill()
        } else {
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: c.x - 3, y: c.y - 5))
            tri.line(to: NSPoint(x: c.x + 5, y: c.y))
            tri.line(to: NSPoint(x: c.x - 3, y: c.y + 5))
            tri.close()
            tri.fill()
        }
    }

    private func drawWave(in rect: NSRect) {
        let mid = rect.midY
        let color = selected ? Theme.textTertiary : Theme.waveform
        color.setFill()
        guard peaks.count > 2 else {
            NSRect(x: rect.minX, y: mid - 0.5, width: rect.width, height: 1).fill()
            return
        }
        let path = NSBezierPath()
        let n = peaks.count
        func px(_ i: Int) -> CGFloat { rect.minX + rect.width * CGFloat(i) / CGFloat(n - 1) }
        func amp(_ i: Int) -> CGFloat {
            let lo = max(0, i - 1), hi = min(n - 1, i + 1)
            return CGFloat(peaks[lo...hi].reduce(0, +) / Float(hi - lo + 1)) * rect.height / 2
        }
        path.move(to: NSPoint(x: px(0), y: mid))
        for i in 0..<n { path.line(to: NSPoint(x: px(i), y: mid - max(1, amp(i)))) }
        for i in stride(from: n - 1, through: 0, by: -1) { path.line(to: NSPoint(x: px(i), y: mid + max(1, amp(i)))) }
        path.close()
        path.fill()
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        let p = convert(event.locationInWindow, from: nil)
        if playRect.insetBy(dx: -4, dy: -4).contains(p) { onPlay?() }
        else if bounds.contains(p) { onClick?() }
    }
}

/// What was said, with the part already spoken brought forward.
public final class TranscriptPanel: ThemedView, NSTextViewDelegate {

    private let text = NSTextView()
    private var words: [(t: Double, end: Double, text: String, range: NSRange)] = []
    private var lastSpoken = -2
    private var empty = true
    private var cut: [Segment] = []
    private var duration: Double = 0

    /// Editing by reading: pick words, and the video loses them.
    public var onRemove: ((ClosedRange<Double>) -> Void)?
    public var onRestore: ((ClosedRange<Double>) -> Void)?
    public var onRemoveFillers: (() -> Void)?
    public var onTighten: (() -> Void)?
    public var onSeek: ((Double) -> Void)?
    private let removeButton = FillButton("Remove")
    private let restoreButton = FillButton("Bring back")
    private let hint = Theme.label("", .meta, color: Theme.textTertiary)

    public override init(frame: NSRect) {
        super.init(frame: frame)
        let header = SectionHeader("Transcript", icon: .transcript)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text

        removeButton.toolTip = "Cut the selected words out of the video"
        removeButton.onClick = { [weak self] in self?.removeSelection() }
        restoreButton.toolTip = "Put the selected words back"
        restoreButton.onClick = { [weak self] in self?.restoreSelection() }
        let fillers = FillButton("Fillers") { [weak self] in self?.onRemoveFillers?() }
        fillers.toolTip = "Remove um, uh and the rest"
        let tighten = FillButton("Pauses") { [weak self] in self?.onTighten?() }
        tighten.toolTip = "Trim the long silences"
        let buttons = NSStackView(views: [removeButton, restoreButton, fillers, tighten])
        buttons.spacing = 6
        for b in [removeButton, restoreButton, fillers, tighten] {
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        text.delegate = self

        for v in [header, buttons, hint, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hint.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The cut list decides which words show as struck through.
    public func show(_ transcript: Transcript?, cut: [Segment] = [], duration: Double = 0) {
        let previousSelection = text.selectedRange()
        self.cut = cut
        self.duration = duration
        words = []
        lastSpoken = -2
        let body = NSMutableAttributedString()
        guard let transcript, !transcript.segments.isEmpty else {
            empty = true
            body.append(NSAttributedString(
                string: "No transcript yet. Record with the mic on, or run cutaway transcribe.",
                attributes: [.font: Theme.Text.body.font, .foregroundColor: Theme.textTertiary]))
            text.textStorage?.setAttributedString(body)
            return
        }
        empty = false
        for seg in transcript.segments {
            let piece = (body.length == 0 ? "" : " ") + seg.text
            let start = body.length + (body.length == 0 ? 0 : 1)
            let gone = duration > 0 && !Cuts.isKept(seg.t + seg.duration / 2, in: cut, duration: duration)
            body.append(NSAttributedString(string: piece, attributes: style(spoken: false, cut: gone)))
            words.append((seg.t, seg.t + seg.duration, seg.text,
                          NSRange(location: start, length: seg.text.utf16.count)))
        }
        text.textStorage?.setAttributedString(body)
        // a cut reloads this panel; keeping the selection means Bring back is
        // still there for the words you just removed
        if previousSelection.length > 0,
           NSMaxRange(previousSelection) <= (text.textStorage?.length ?? 0) {
            text.setSelectedRange(previousSelection)
        }
        updateButtons()
    }

    /// The source span the selected words cover.
    private var selectedSpan: ClosedRange<Double>? {
        let range = text.selectedRange()
        guard range.length > 0 else { return nil }
        let picked = words.filter { NSIntersectionRange($0.range, range).length > 0 }
        guard let first = picked.first, let last = picked.last else { return nil }
        // a little air either side, so a cut never clips the next word
        return max(0, first.t - 0.05)...(last.end + 0.05)
    }

    private func removeSelection() {
        guard let span = selectedSpan else { return }
        onRemove?(span)
    }

    private func restoreSelection() {
        guard let span = selectedSpan else { return }
        onRestore?(span)
    }

    /// Selects a run of words and hands back the span they cover, so the
    /// editing path can be driven without a pointer.
    @discardableResult
    public func selectWords(from: Int, to: Int) -> ClosedRange<Double>? {
        guard from >= 0, to <= words.count, from < to else { return nil }
        let start = words[from].range.location
        let end = NSMaxRange(words[to - 1].range)
        text.setSelectedRange(NSRange(location: start, length: end - start))
        updateButtons()
        return selectedSpan
    }

    public func removeSelected() { removeSelection() }
    public func restoreSelected() { restoreSelection() }
    public func removeFillers() { onRemoveFillers?() }
    public func tightenPauses() { onTighten?() }
    public var wordCount: Int { words.count }

    func selectionChanged() {
        updateButtons()
        // clicking a word is also how you get to that moment
        let range = text.selectedRange()
        if range.length <= 1, let word = words.last(where: { $0.range.location <= range.location }) {
            onSeek?(word.t)
        }
    }

    private func updateButtons() {
        let span = selectedSpan
        removeButton.isEnabled = span != nil
        restoreButton.isEnabled = span != nil
        guard duration > 0 else {
            hint.stringValue = ""
            return
        }
        let kept = Cuts.kept(cut, duration: duration)
        hint.stringValue = kept < duration - 0.05
            ? String(format: "%.0fs of %.0fs kept", kept, duration)
            : "select words, then Remove"
    }

    private func style(spoken: Bool, cut: Bool = false) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        var attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.Text.body.font,
            .foregroundColor: spoken ? Theme.textPrimary : Theme.textSecondary,
            .paragraphStyle: para,
        ]
        if cut {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = Theme.textTertiary
        }
        return attrs
    }

    /// Only restyles when the spoken word changes, not on every frame.
    public func update(time: Double) {
        guard !empty, let storage = text.textStorage else { return }
        let spoken = words.lastIndex { $0.t <= time } ?? -1
        guard spoken != lastSpoken else { return }
        lastSpoken = spoken
        storage.beginEditing()
        for (i, word) in words.enumerated() {
            let gone = duration > 0 && !Cuts.isKept((word.t + word.end) / 2, in: cut, duration: duration)
            storage.addAttributes(style(spoken: i <= spoken, cut: gone), range: word.range)
        }
        storage.endEditing()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let t = lastSpoken
        lastSpoken = -2
        if t >= 0 { update(time: words[t].t) }
    }
}


extension TranscriptPanel {
    /// Selecting words is the whole interaction, so the buttons follow it.
    public func textViewDidChangeSelection(_ notification: Notification) {
        selectionChanged()
    }
}
