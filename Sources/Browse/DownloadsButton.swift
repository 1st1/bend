import SwiftUI

private typealias DownloadViewState<Value> = SwiftUI.State<Value>

// @lat: [[architecture#Browser downloads]]
struct DownloadsButton: View {
    @ObservedObject var downloads: BrowserDownloads
    @DownloadViewState private var showing = false
    @DownloadViewState private var hovered = false

    var body: some View {
        Group {
            if !downloads.items.isEmpty || downloads.activeCount > 0 || downloads.persistenceError != nil { button }
        }
        .onChange(of: downloads.items.isEmpty) { _, empty in
            if empty && downloads.activeCount == 0 && downloads.persistenceError == nil { showing = false; hovered = false }
        }
    }

    private var button: some View {
        Button { showing.toggle() } label: {
            DownloadProgressIcon(active: downloads.activeCount > 0, fraction: downloads.progressFraction,
                                 highlighted: hovered || showing)
        }
        .buttonStyle(ChromeButtonStyle(prominent: true))
        .help("Downloads")
        .onHover { hovered = $0 }
        .accessibilityLabel("Downloads")
        .accessibilityValue(downloads.activeCount == 0 ? "No active downloads" :
            "\(downloads.activeCount) active downloads" + (downloads.progressFraction.map { ", \(Int($0 * 100)) percent" } ?? ""))
        .background(WindowDragArea(excluded: true))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DownloadsList(downloads: downloads)
        }
    }
}

struct DownloadProgressIcon: View {
    let active: Bool
    let fraction: Double?
    var highlighted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if active {
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 1.5)
                if let fraction {
                    Circle().trim(from: 0, to: min(1, max(0, fraction)))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fraction)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                        Circle().trim(from: 0, to: 0.25)
                            .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(reduceMotion ? -90 : timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 2) * 180 - 90))
                    }
                }
                Image(systemName: "arrow.down").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(highlighted ? 0.85 : 0.65))
            }.frame(width: 16, height: 16).accessibilityHidden(true)
        } else {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.white.opacity(highlighted ? 0.85 : 0.55))
        }
    }
}

struct DownloadsList: View {
    @ObservedObject var downloads: BrowserDownloads

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear Finished") { downloads.clearFinished() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .disabled(!downloads.items.contains { $0.state != .downloading && $0.state != .cancelling })
            }.padding(14)
            Divider()
            if let error = downloads.persistenceError {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { downloads.retryPersistence() }.font(.caption)
                }.padding(14)
                Divider()
            }
            if downloads.items.isEmpty {
                Text(downloads.activeCount > 0 ? "Downloads are still running" : "No downloads yet").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 35)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(downloads.items) { item in
                            DownloadRow(item: item, downloads: downloads)
                            if item.id != downloads.items.last?.id { Divider().padding(.leading, 14) }
                        }
                    }
                }.frame(height: min(380, CGFloat(downloads.items.count) * 82))
            }
        }.frame(width: 360)
        .preferredColorScheme(.dark)
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: BrowserDownload
    let downloads: BrowserDownloads

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.state == .completed ? "doc" : "arrow.down.doc")
                .font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if item.state == .downloading {
                    if item.total > 0 {
                        ProgressView(value: min(Double(item.received), Double(item.total)), total: Double(item.total))
                    } else { ProgressView().controlSize(.small) }
                }
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    .help(item.error ?? item.sourceURL?.host ?? "")
            }.frame(maxWidth: .infinity, alignment: .leading)
            switch item.state {
            case .downloading:
                Button { downloads.cancel(item) } label: { Image(systemName: "xmark") }
                    .buttonStyle(ChromeButtonStyle()).help("Cancel download").accessibilityLabel("Cancel download")
            case .cancelling:
                ProgressView().controlSize(.small).frame(width: 24)
            case .completed:
                Button { downloads.reveal(item) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(ChromeButtonStyle()).help("Show in Finder").accessibilityLabel("Show in Finder")
            case .failed, .cancelled:
                Button { downloads.retry(item) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(ChromeButtonStyle()).disabled(!item.canRetry)
                    .help(item.canRetry ? "Retry download" : "Download this file again from its page")
                    .accessibilityLabel("Retry download")
            }
        }.padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 80)
    }

    private var status: String {
        let received = ByteCountFormatter.string(fromByteCount: max(0, item.received), countStyle: .file)
        switch item.state {
        case .downloading:
            if item.total > 0 {
                return "\(received) of \(ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file))"
            }
            return "\(received) downloaded"
        case .cancelling: return "Cancelling…"
        case .cancelled: return "Cancelled"
        case .failed: return item.error ?? "Download failed"
        case .completed: return "\(received) · Completed"
        }
    }
}
