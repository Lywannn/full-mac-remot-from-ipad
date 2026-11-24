import AppKit
import IPadModeCore

/// The "keep or revert" dialog (§7.2, R51): a floating panel on the main display, which is the virtual display in
/// Remote mode. One dialog at a time; each `confirm` gets exactly one answer, whichever of keep, revert, the timeout
/// and `cancel` comes first. Return keeps, Escape reverts.
@MainActor public final class ConfirmPanel: Confirmer {
    private var panel: NSPanel?
    private var body: NSTextField?
    /// The buttons' targets: a button holds its target weakly.
    private var targets: [ButtonAction] = []
    private var countdown: Timer?
    private var deadline: ContinuousClock.Instant?
    /// The frame of the screen the panel was last centred on.
    private var placedOn: NSRect?
    private var waiting: CheckedContinuation<ConfirmOutcome, Never>?

    public init() {}

    public func confirm(seconds: Int) async -> ConfirmOutcome {
        answer(.cancelled)   // a dialog still waiting is answered first
        guard seconds > 0 else { return .timedOut }
        return await withCheckedContinuation { waiting in
            self.waiting = waiting
            show(seconds: seconds)
        }
    }

    /// Closes the dialog; a waiting `confirm` returns `.cancelled`. Does nothing when no dialog is waiting.
    public func cancel() {
        answer(.cancelled)
    }

    /// The one answer of the waiting dialog, if any; the panel closes either way.
    private func answer(_ outcome: ConfirmOutcome) {
        countdown?.invalidate()
        countdown = nil
        deadline = nil
        panel?.orderOut(nil)
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume(returning: outcome)
    }

    private func show(seconds: Int) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        deadline = .now + .seconds(seconds)
        body?.stringValue = Messages.confirmBody(seconds)   // the widest it gets: the panel is sized to it
        if let content = panel.contentView { panel.setContentSize(content.fittingSize) }
        placedOn = nil
        place(panel)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)   // also while a menu or a drag tracks the mouse
        countdown = timer
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()   // in front even if the activation is refused
    }

    /// Counts down to the deadline rather than counting ticks, so that a late or skipped tick cannot stretch the
    /// window; the last tick may land a hair before the deadline. Follows the main display if it changed since the
    /// panel was placed.
    private func tick() {
        guard let deadline, let panel else { return }
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .milliseconds(50) else {
            answer(.timedOut)
            return
        }
        body?.stringValue = Messages.confirmBody(Self.wholeSeconds(left))
        place(panel)
    }

    /// Centred on the main display (`NSScreen.screens.first`), unless already placed on it.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first else {
            panel.center()
            return
        }
        guard screen.frame != placedOn else { return }
        placedOn = screen.frame
        let area = screen.visibleFrame, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded()))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = Messages.confirmTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let title = NSTextField(labelWithString: Messages.confirmTitle)
        title.font = .boldSystemFont(ofSize: 15)
        let body = NSTextField(labelWithString: Messages.confirmBody(Config.Remote().confirmSeconds))
        body.font = .systemFont(ofSize: 13)
        let revert = button(Messages.revert, key: "\u{1b}") { [weak self] in self?.answer(.revert) }   // Escape
        let keep = button(Messages.keep, key: "\r") { [weak self] in self?.answer(.keep) }   // Return
        let buttons = NSStackView(views: [revert, keep])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(18, after: body)
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 32, bottom: 22, right: 32)   // the top clears the title bar
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        panel.contentView = stack
        panel.defaultButtonCell = keep.cell as? NSButtonCell
        self.body = body
        return panel
    }

    private func button(_ title: String, key: String, _ action: @escaping @MainActor () -> Void) -> NSButton {
        let target = ButtonAction(action)
        targets.append(target)
        let button = NSButton(title: title, target: target, action: #selector(ButtonAction.fire(_:)))
        button.keyEquivalent = key
        button.bezelStyle = .rounded
        return button
    }

    /// Rounded up, so that the countdown never shows 0 while it still runs.
    private static func wholeSeconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) + (parts.attoseconds > 0 ? 1 : 0)
    }
}

/// Short messages (R51): a small panel at the top centre of the main display that closes by itself. It never takes
/// focus or clicks. Notices that arrive close together are shown together (`NoticeLines`); each new line keeps it
/// up for the whole time again.
@MainActor public final class NoticePanel: Notifier {
    private static let maxTextWidth: CGFloat = 560
    private static let padding = NSSize(width: 20, height: 12)

    private let autoDismiss: TimeInterval
    private var lines = NoticeLines()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var dismissal: Timer?

    public init(autoDismiss: Duration = .seconds(4)) {
        let parts = autoDismiss.components
        self.autoDismiss = TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    public func notice(_ text: String) {
        guard lines.add(text) else { return }   // shown already
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label?.stringValue = lines.text
        layOut(panel)
        panel.orderFrontRegardless()
        dismissal?.invalidate()
        let timer = Timer(timeInterval: autoDismiss, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissal = timer
    }

    private func dismiss() {
        dismissal?.invalidate()
        dismissal = nil
        panel?.orderOut(nil)
        lines.removeAll()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        background.addSubview(label)
        panel.contentView = background
        self.label = label
        return panel
    }

    /// Sized to the text, at most `maxTextWidth` wide, centred just below the top of the main display's usable area.
    private func layOut(_ panel: NSPanel) {
        guard let label, let content = panel.contentView else { return }
        let bounds = NSRect(x: 0, y: 0, width: Self.maxTextWidth, height: 10_000)
        let fit = label.cell?.cellSize(forBounds: bounds) ?? NSSize(width: Self.maxTextWidth, height: 20)
        let text = NSSize(width: ceil(min(fit.width, Self.maxTextWidth)), height: ceil(fit.height))
        let size = NSSize(width: text.width + 2 * Self.padding.width, height: text.height + 2 * Self.padding.height)
        let area = NSScreen.screens.first?.visibleFrame ?? NSRect(origin: .zero, size: size)
        panel.setFrame(NSRect(x: (area.midX - size.width / 2).rounded(), y: area.maxY - size.height - 12,
                              width: size.width, height: size.height), display: false)
        content.frame = NSRect(origin: .zero, size: size)
        label.frame = NSRect(origin: NSPoint(x: Self.padding.width, y: Self.padding.height), size: text)
    }
}

/// A button's target and action, without making the panel an NSObject. AppKit sends it on the main thread.
@MainActor private final class ButtonAction: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func fire(_ sender: Any?) {
        action()
    }
}
