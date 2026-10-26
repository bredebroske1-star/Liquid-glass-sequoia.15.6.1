import AppKit
import SwiftUI

@main
struct GlassDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var glassController = DesktopGlassController.shared

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(glassController)
                .frame(minWidth: 680, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Open Glass Search") {
                    SpotlightPanelController.shared.show()
                }
                .keyboardShortcut(.space, modifiers: [.command, .shift])
                Button("Open Glass Search (alternate shortcut)") {
                    SpotlightPanelController.shared.show()
                }
                .keyboardShortcut(.space, modifiers: [.command, .option])
                Button(glassController.isEnabled ? "Turn Desktop Glass Off" : "Turn Desktop Glass On") {
                    glassController.isEnabled.toggle()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do {
            try GlobalShortcutManager.shared.register()
        } catch {
            NSLog("Unable to register the global Glass Search shortcut: %@", error.localizedDescription)
            GlobalShortcutManager.shared.setError(error.localizedDescription)
        }
    }
}

@MainActor
final class DesktopGlassController: ObservableObject {
    static let shared = DesktopGlassController()

    @Published var isEnabled = false {
        didSet { updatePanels() }
    }

    @Published var intensity = 0.16 {
        didSet { updatePanelContent() }
    }

    private var panels: [NSPanel] = []
    private var launcherPanels: [NSPanel] = []

    private init() {
        updatePanels()
    }

    private func updatePanels() {
        panels.forEach { $0.close() }
        panels.removeAll()
        launcherPanels.forEach { $0.close() }
        launcherPanels.removeAll()

        for screen in NSScreen.screens {
            if isEnabled {
                let tintPanel = NSPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                tintPanel.isOpaque = false
                tintPanel.backgroundColor = .clear
                tintPanel.hasShadow = false
                tintPanel.ignoresMouseEvents = true
                tintPanel.hidesOnDeactivate = false
                tintPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                tintPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
                tintPanel.contentView = NSHostingView(rootView: DesktopTintView(intensity: intensity))
                tintPanel.setFrame(screen.frame, display: true)
                tintPanel.orderFrontRegardless()
                panels.append(tintPanel)
            }

            let launcherSize = NSSize(width: 154, height: 48)
            let visibleFrame = screen.visibleFrame
            let launcherFrame = NSRect(
                x: visibleFrame.minX + 20,
                y: visibleFrame.minY + 20,
                width: launcherSize.width,
                height: launcherSize.height
            )
            let launcher = NSPanel(
                contentRect: NSRect(origin: launcherFrame.origin, size: launcherSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            launcher.isOpaque = false
            launcher.backgroundColor = .clear
            launcher.hasShadow = true
            launcher.hidesOnDeactivate = false
            launcher.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            launcher.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 2)
            launcher.contentView = NSHostingView(rootView: DesktopSearchLauncherView())
            launcher.setFrame(launcherFrame, display: true)
            launcher.orderFrontRegardless()
            launcherPanels.append(launcher)
        }
    }

    private func updatePanelContent() {
        for panel in panels {
            panel.contentView = NSHostingView(rootView: DesktopTintView(intensity: intensity))
        }
    }
}

private struct DesktopSearchLauncherView: View {
    var body: some View {
        Button {
            SpotlightPanelController.shared.show()
        } label: {
            Label("Glass Search", systemImage: "sparkle.magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(2)
    }
}

private struct DesktopTintView: View {
    let intensity: Double

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(intensity * 0.24),
                    Color.cyan.opacity(intensity * 0.12),
                    Color.blue.opacity(intensity * 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
