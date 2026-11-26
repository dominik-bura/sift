import AppKit
import SwiftUI

@MainActor final class UpdatePromptWindow: NSWindowController, NSWindowDelegate {
    private var suppressReminder = false
    private let onClose: (Bool) -> Void

    init(model: AppModel, release: UpdateRelease, onClose: @escaping (Bool) -> Void) {
        self.onClose = onClose
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "\(model.applicationName) Update"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: UpdatePromptView(model: model, release: release))
        panel.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        // Called only following interaction with Sift. Never activate another
        // app or steal focus when a background update check completes.
        window?.makeKeyAndOrderFront(nil)
    }
    func closeQuietly() {
        suppressReminder = true
        close()
    }
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil // Break the host view/model ownership cycle.
        onClose(!suppressReminder)
    }
}

struct UpdatePromptView: View {
    @ObservedObject var model: AppModel
    let release: UpdateRelease
    var applicationIcon: NSImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                Image(nsImage: applicationIcon ?? SiftAssets.applicationIcon).resizable().scaledToFit().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text("A new version is available").font(.headline)
                    Text("\(model.applicationName) \(model.installedVersion) → \(release.version)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if model.isUpdating {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Downloading and verifying…").font(.callout)
                }
                Text("Sift will restart after verification finishes. Cleanup is paused until the update completes.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Install the latest improvements and fixes. Sift will quit and reopen after you approve the update.")
                    .font(.callout).foregroundStyle(.secondary)
                if case let .failed(message) = model.updateState {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(3).help(message)
                }
                Button("Release Notes") { model.openRelease(release) }.buttonStyle(.link).font(.caption)
                HStack(spacing: 10) {
                    Button("Skip This Version") { model.skipUpdateVersion(release) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Update & Relaunch") { model.installUpdate(release) }
                        .buttonStyle(.borderedProminent).tint(SiftChartStyle.accent)
                        .keyboardShortcut(.defaultAction).disabled(!model.canInstallUpdate(release))
                }
                HStack {
                    Spacer()
                    Button("Remind Me Tomorrow") { model.remindUpdateTomorrow(release) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }.padding(22).frame(width: 420, alignment: .leading)
            .frame(minHeight: 380, alignment: .topLeading)
    }
}

/// Observe the actual menu window, not just SwiftUI onAppear (which can run
/// during preloading). Only a key window in an active app counts as interaction.
struct UpdateInteractionMonitor: NSViewRepresentable {
    let allowsPrompt: Bool
    let onChange: (Bool, Bool) -> Void
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.allowsPrompt = allowsPrompt
        view.onChange = onChange
        view.notifyLater()
    }
    final class MonitorView: NSView {
        var allowsPrompt = true
        var onChange: ((Bool, Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
            if let window {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.notifyLater() }
                    })
                }
                for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                    tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.notifyLater() }
                    })
                }
            }
            notifyLater()
        }
        func notifyLater() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onChange?(self.window?.isKeyWindow == true && NSApp.isActive, self.allowsPrompt)
            }
        }
        deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
    }
}
