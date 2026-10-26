import SwiftUI
import VaultCore

/// Shared by the sheet and the persistent status bar; all progress comes from the same job.
struct ScanProgressMeter: View {
    let scan: ScanJob
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(scan.percentCompleted == nil ? (scan.stage.isRunning ? "Calculating total…" : "Total was not calculated") : "Estimated overall progress")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let percent = scan.percentCompleted {
                    Text("\(percent)%").font(compact ? .caption.monospacedDigit().weight(.semibold) : .title2.monospacedDigit().weight(.medium))
                    Text("· \(100 - percent)% remaining").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let fraction = scan.fractionCompleted {
                ProgressView(value: fraction).tint(VaultStyle.teal)
                    .accessibilityLabel("Estimated scan progress")
                    .accessibilityValue("\(scan.percentCompleted ?? 0) percent complete, \(100 - (scan.percentCompleted ?? 0)) percent remaining")
            } else if scan.stage.isRunning {
                ProgressView().progressViewStyle(.linear).tint(VaultStyle.teal)
                    .accessibilityLabel("Counting files to calculate scan progress")
            } else {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 4).accessibilityHidden(true)
            }
            if !compact {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var detail: String {
        guard let progress = scan.progress else { return "Completed catalog entries are saved locally." }
        if !progress.countingComplete {
            return "\(progress.countedEntries.formatted()) entries counted · \(progress.totalFiles.formatted()) matching files so far." + (scan.stage.isRunning ? " A percentage appears after counting finishes." : " Counting did not finish.")
        }
        if scan.stage == .duplicates {
            return "Final review · \(progress.duplicateChecks.formatted()) of \(progress.duplicateTotal.formatted()) catalog entries checked. File counts estimate work, not time remaining."
        }
        return "\(min(progress.indexedFiles, progress.totalFiles).formatted()) of \(progress.totalFiles.formatted()) matching files processed. Includes unchanged and unavailable attempts; errors are listed in results."
    }
}

/// Decorative scan radar. Time only animates the illustration, never the progress value.
struct ScanRadar: View {
    let scan: ScanJob
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var windowState
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    private var moving: Bool {
        scan.stage.isRunning && cinematicMotion && !reducedMotion && contrast != .increased && scenePhase == .active && windowState != .inactive
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !moving)) { timeline in
            let angle = moving ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 * 360 : 45
            ZStack {
                Circle().fill(VaultStyle.teal.opacity(0.07))
                Circle().stroke(VaultStyle.lavender.opacity(0.22), lineWidth: 1).padding(compact ? 3 : 10)
                Circle().stroke(VaultStyle.teal.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [2, 7])).padding(compact ? 7 : 25)
                Circle().trim(from: 0, to: scan.fractionCompleted.map { CGFloat($0) } ?? 0.14)
                    .stroke(AngularGradient(colors: [VaultStyle.lavender, VaultStyle.teal], center: .center), style: StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(compact ? 1 : 4)
                if scan.stage.isRunning {
                    Circle().trim(from: 0, to: 0.22)
                        .stroke(AngularGradient(colors: [.clear, VaultStyle.teal.opacity(0.85)], center: .center), lineWidth: 1)
                        .rotationEffect(.degrees(angle)).padding(compact ? 5 : 18)
                }
                Image(systemName: symbol).font(.system(size: compact ? 13 : 26, weight: .light))
                    .foregroundStyle(scan.stage == .failed ? VaultStyle.amber : VaultStyle.teal)
            }
        }
        .frame(width: compact ? 44 : 116, height: compact ? 44 : 116)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
    private var symbol: String {
        switch scan.stage {
        case .completed: "checkmark"
        case .cancelled, .interrupted: "pause"
        case .failed: "exclamationmark"
        default: "viewfinder"
        }
    }
}

struct ScanStatusBar: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    private var scan: ScanJob? { workspace.activeScan ?? workspace.data.lastScan }
    var body: some View {
        if let scan {
            HStack(spacing: 14) {
                ScanRadar(scan: scan, compact: true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(workspace.scanCancellationRequested ? "Cancelling safely…" : scan.stage.title).font(.callout.weight(.medium))
                        Spacer()
                        Text(scan.stage.isRunning ? "BACKGROUND SCAN" : "\(scan.errors.count) issues")
                            .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    ScanProgressMeter(scan: scan, compact: true)
                }.frame(maxWidth: .infinity)
                Button(scan.stage.isRunning ? "Expand" : "View Results") { workspace.showScanResults() }
                    .help("Open scan details").accessibilityIdentifier("expandScan")
                if scan.stage.isRunning {
                    Button("Cancel") { workspace.cancelScan() }.disabled(workspace.scanCancellationRequested)
                } else {
                    Button { workspace.dismissScanStatus() } label: { Image(systemName: "xmark") }
                        .help("Dismiss scan status").accessibilityLabel("Dismiss scan status")
                }
            }.padding(14).glassSurface(radius: 14, tint: VaultStyle.teal)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .accessibilityIdentifier("backgroundScanStatus")
        }
    }
}
