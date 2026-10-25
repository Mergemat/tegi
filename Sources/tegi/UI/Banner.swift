import AppKit
import QuartzCore
import TegiCore

final class Banner {
    private var panel: NSPanel?
    private var dismiss: DispatchWorkItem?

    func show(_ message: String, for seconds: Double = 4) {
        hide(animated: false)
        guard let screen = NSScreen.main else { return }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = min(720, screen.visibleFrame.width - 80)
        let size = label.fittingSize
        let width = min(size.width, label.preferredMaxLayoutWidth) + 40, height = size.height + 24
        let background = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        background.wantsLayer = true
        background.layer?.backgroundColor = CGColor(gray: 0.12, alpha: 0.97)
        background.layer?.cornerRadius = 12
        background.layer?.borderWidth = 1
        background.layer?.borderColor = CGColor(srgbRed: 1, green: 0.4, blue: 0.4, alpha: 0.6)
        label.frame = CGRect(x: 20, y: 12, width: width - 40, height: size.height)
        background.addSubview(label)

        let panel = NSPanel(contentRect: background.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = background
        let top = screen.visibleFrame.maxY - 12
        panel.setFrameOrigin(CGPoint(x: (screen.visibleFrame.midX - width / 2).rounded(), y: top - height))
        panel.orderFrontRegardless()
        if let layer = background.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let slide = CASpringAnimation(keyPath: "transform.translation.y")
            slide.mass = 1
            slide.stiffness = 1000
            slide.damping = 2 * 0.6 * 1000.squareRoot()
            slide.fromValue = height + 12
            slide.toValue = 0
            slide.duration = slide.settlingDuration
            layer.add(slide, forKey: "slide")
        }
        self.panel = panel
        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide(animated: Bool) {
        dismiss?.cancel()
        dismiss = nil
        guard let panel else { return }
        self.panel = nil
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}
