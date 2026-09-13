import AppKit

/// Renders the component kit offscreen, for checking it against the design
/// references without launching the app or needing capture permission.
enum Gallery {

    static func render(dark: Bool, to url: URL) throws {
        let size = NSSize(width: 860, height: 470)
        let root = Surface(Theme.canvas, radius: 0)
        root.frame = NSRect(origin: .zero, size: size)
        root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        func place(_ v: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat? = nil, _ h: CGFloat? = nil) {
            let s = v.intrinsicContentSize
            v.frame = NSRect(x: x, y: y,
                             width: w ?? (s.width > 0 ? s.width : 120),
                             height: h ?? (s.height > 0 ? s.height : 28))
            root.addSubview(v)
        }

        // record controls, as in the light reference
        let bar = Surface(Theme.panel)
        place(bar, 16, 16, 828, 108)
        let start = FillButton("Start Recording")
        start.showsDot = true
        start.trailingChevron = true
        place(start, 30, 30)
        place(FillButton("Mic Off", icon: .micOff), 220, 30)
        place(Theme.label("Camera:", .body, color: Theme.textSecondary), 330, 35, 60, 18)
        let cam = Switch(false)
        place(cam, 392, 35)
        place(Dropdown(["Logitech C920", "FaceTime HD"], selected: "Logitech C920"), 430, 30)
        place(FillButton("Settings", icon: .gear), 600, 30)
        let d = Divider()
        place(d, 30, 70, 800, 1)
        place(Theme.label("Capture:", .body, color: Theme.textSecondary), 30, 86, 60, 18)
        let area = Dropdown(["Display", "Window", "Area"], selected: "Area")
        area.focused = true
        place(area, 94, 81)
        place(SliderPill("Desktop Audio", value: 0.8), 210, 80, 300, 30)

        // player row, as in the dark reference
        let tabs = Tabs(["Player", "Studio"])
        place(tabs, 16, 146)
        place(TransportButton(.back), 250, 144)
        place(TransportButton(.pause, prominent: true), 286, 144)
        let time = NSTextField(labelWithString: "")
        let attr = NSMutableAttributedString(string: "4:56", attributes: [
            .font: Theme.Text.time.font, .foregroundColor: Theme.textStrong])
        attr.append(NSAttributedString(string: " / 3:16:19", attributes: [
            .font: Theme.Text.body.font, .foregroundColor: Theme.textSecondary]))
        time.attributedStringValue = attr
        place(time, 326, 145, 150, 28)
        place(TransportButton(.forward), 470, 144)
        place(IconButton(.gear, transparent: true), 700, 144)
        place(FillButton("Export", icon: .download), 736, 144)

        // cards and rows
        let idle = Surface(Theme.inset, radius: Theme.radiusCard)
        place(idle, 16, 196, 190, 96)
        place(Theme.label("Podcast Joe Rogan", .body, color: Theme.textSecondary), 28, 206, 170, 18)
        let chosen = Surface(Theme.fillSelected, radius: Theme.radiusCard, border: Theme.cardOutline)
        place(chosen, 218, 196, 190, 96)
        place(Theme.label("Naval 44 Harsh Truths", .body), 230, 206, 170, 18)

        place(SectionHeader("Key Points", icon: .bookmark), 430, 198, 200, 22)
        place(Chip("Group"), 640, 198)
        place(Chip("EP 1"), 700, 198)
        for (i, (t, title, on)) in [("00:00", "Is Success Worth It?", true),
                                    ("07:43", "Ways To Shortcut Our Life", false)].enumerated() {
            let y = 228 + CGFloat(i) * 36
            let row = Surface(Theme.inset, radius: Theme.radiusCard,
                              border: on ? Theme.accentBorder : nil)
            place(row, 430, y, 410, 30)
            let b = Surface(on ? Theme.accent : Theme.badge, radius: 4)
            place(b, 436, y + 5, 20, 20)
            place(Theme.label("\(i + 1)", .caption, color: on ? Theme.onAccent : Theme.textSecondary),
                  442, y + 7, 12, 16)
            place(Theme.label(t, .bodyStrong, color: Theme.textStrong), 466, y + 6, 50, 18)
            place(Theme.label(title, .body, color: Theme.textPrimary), 520, y + 6, 300, 18)
        }

        place(SectionHeader("Recording", icon: .transcript), 16, 312, 200, 22)
        place(ScrubField("Cursor size", value: 1.7, range: 0.8...3, step: 0.1), 16, 340, 260, 30)
        place(ScrubField("Motion blur", value: 0.85, range: 0...2), 16, 376, 260, 30)
        let newRec = FillButton("New Recording")
        newRec.showsDot = true
        place(newRec, 300, 340)
        let off = FillButton("Disabled", icon: .trash)
        off.isEnabled = false
        place(off, 300, 376)

        var x: CGFloat = 450
        for icon in [Icon.mic, .camera, .volume, .keyboard, .display, .area, .scissors, .zoom,
                     .layers, .sidebar, .expand, .folder, .plus, .undo] {
            place(IconButton(icon), x, 342)
            x += 34
            if x > 820 { x = 450 }
        }

        root.appearance!.performAsCurrentDrawingAppearance {
            let scale: CGFloat = 2
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: Int(size.width * scale),
                                             pixelsHigh: Int(size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = size
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
