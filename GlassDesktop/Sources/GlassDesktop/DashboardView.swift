import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var glassController: DesktopGlassController
    @ObservedObject private var shortcutManager = GlobalShortcutManager.shared

    private let columns = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18)
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.22, blue: 0.38), Color(red: 0.23, green: 0.34, blue: 0.48)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    LazyVGrid(columns: columns, spacing: 18) {
                        ClockWidget()
                        DateWidget()
                        FocusWidget()
                        DesktopGlassWidget()
                    }
                    AppLibraryView()
                    Text("Search shortcut: \(shortcutManager.status). macOS does not expose a supported way to restyle other apps or Apple widgets.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(30)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Glass Desktop")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("A reversible Liquid Glass-inspired desktop companion")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                SpotlightPanelController.shared.show()
            } label: {
                Label("Search & Ask", systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Image(systemName: "sparkles")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
        }
    }
}

private struct AppLibraryEntry: Identifiable {
    let url: URL
    let name: String

    var id: String { url.path }
}

private struct AppLibraryView: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
    @State private var apps: [AppLibraryEntry] = []
    @State private var searchText = ""
    @State private var loadError: String?

    private var filteredApps: [AppLibraryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("APP LIBRARY", systemImage: "square.grid.2x2")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("\(apps.count) apps")
                            .font(.title2.weight(.medium))
                    }
                    Spacer()
                    TextField("Filter apps", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if filteredApps.isEmpty {
                    Text(apps.isEmpty ? "No apps found in Applications." : "No apps match your filter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredApps) { app in
                            Button {
                                NSWorkspace.shared.open(app.url)
                            } label: {
                                VStack(spacing: 8) {
                                    GlassAppIcon(url: app.url, size: 42)
                                    Text(app.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, minHeight: 78)
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .help("Open \(app.name)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadApps)
    }

    private func loadApps() {
        guard apps.isEmpty else { return }
        let fileManager = FileManager.default
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Applications")
        ]
        var seen = Set<String>()
        var foundApps: [AppLibraryEntry] = []
        var failures: [String] = []

        for directory in directories {
            do {
                let urls = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                for url in urls where url.pathExtension.lowercased() == "app" {
                    guard seen.insert(url.path).inserted else { continue }
                    let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    foundApps.append(AppLibraryEntry(url: url, name: name))
                }
            } catch {
                if fileManager.fileExists(atPath: directory.path) {
                    failures.append("\(directory.path): \(error.localizedDescription)")
                }
            }
        }

        apps = foundApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !failures.isEmpty {
            loadError = "Some apps could not be listed: \(failures.joined(separator: "; "))"
        }
    }
}

private struct ClockWidget: View {
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("LOCAL TIME", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 46, weight: .light, design: .rounded))
                        .contentTransition(.numericText())
                }
                Text("Your Mac's current time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        }
    }
}

private struct DateWidget: View {
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("TODAY", systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(Date.now.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                Text(Date.now.formatted(.dateTime.month(.wide).day().year()))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        }
    }
}

private struct FocusWidget: View {
    @State private var isFocused = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("FOCUS", systemImage: "moon.stars")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(isFocused ? "Quiet mode" : "Take a moment")
                    .font(.title2.weight(.medium))
                Toggle(isOn: $isFocused) {
                    Text(isFocused ? "Focus is on" : "Focus is off")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .tint(.cyan)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        }
    }
}

private struct DesktopGlassWidget: View {
    @EnvironmentObject private var glassController: DesktopGlassController

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("DESKTOP", systemImage: "macwindow.on.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(glassController.isEnabled ? "Glass is active" : "Desktop tint is off")
                    .font(.title2.weight(.medium))
                Toggle("Tint desktop", isOn: $glassController.isEnabled)
                    .toggleStyle(.switch)
                    .tint(.cyan)
                HStack(spacing: 10) {
                    Text("Intensity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $glassController.intensity, in: 0.05...0.30)
                        .disabled(!glassController.isEnabled)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        }
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.38), .white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
}
