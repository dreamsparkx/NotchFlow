import AppKit

final class AppKitWaveformView: NSView {
    private let ratios: [CGFloat] = [0.16, 0.44, 0.82, 0.54, 1.0, 0.62, 0.22]
    private var timer: Timer?
    private var displayedColor = NSColor(calibratedRed: 0.38, green: 0.55, blue: 1, alpha: 1)
    private var targetColor = NSColor(calibratedRed: 0.38, green: 0.55, blue: 1, alpha: 1)
    var isAnimating = true {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.advanceColorTransition()
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    func transition(to color: NSColor) {
        targetColor = color.usingColorSpace(.sRGB) ?? color
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let barWidth: CGFloat = 3
        let spacing = (bounds.width - barWidth * CGFloat(ratios.count)) / CGFloat(ratios.count - 1)
        let time = Date.timeIntervalSinceReferenceDate
        displayedColor.setFill()

        for (index, ratio) in ratios.enumerated() {
            let pulse = isAnimating
                ? 0.68 + 0.32 * abs(sin(time * 4.5 + Double(index) * 0.9))
                : 0.74
            let height = max(3, bounds.height * ratio * pulse)
            let rect = NSRect(
                x: CGFloat(index) * (barWidth + spacing),
                y: bounds.midY - height / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func advanceColorTransition() {
        guard let current = displayedColor.usingColorSpace(.sRGB),
              let target = targetColor.usingColorSpace(.sRGB) else {
            displayedColor = targetColor
            return
        }
        let amount: CGFloat = 0.08
        displayedColor = NSColor(
            calibratedRed: current.redComponent + (target.redComponent - current.redComponent) * amount,
            green: current.greenComponent + (target.greenComponent - current.greenComponent) * amount,
            blue: current.blueComponent + (target.blueComponent - current.blueComponent) * amount,
            alpha: 1
        )
    }
}
