import SwiftUI
import SceneKit
import AppKit

struct VaultMascotPanel: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var secure: SecureStore
    @EnvironmentObject private var trash: NativeTrashService
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var windowState
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    @AppStorage("showVaultMascot") private var showMascot = true
    @State private var visible = false
    let secureSection: Bool

    private var activity: VaultActivity {
        var input = VaultActivityInput()
        input.hasError = library.loadFailed || (library.operationFailed && library.message != nil) || workspace.error != nil || secure.error != nil || trash.error != nil
        if case .results = workspace.scanPresentation, workspace.reviewFolder, workspace.data.lastScan?.errors.isEmpty == false { input.hasError = true }
        input.authenticating = secure.authenticating
        input.secureSelected = secureSection; input.secureUnlocked = secure.unlocked
        input.scanStage = workspace.scanIsActive ? workspace.activeScan?.stage : nil
        input.discovered = workspace.activeScan?.discovered ?? 0; input.processed = workspace.activeScan?.processed ?? 0
        input.importing = library.busy && !workspace.monitoringActive; input.importProgress = library.progress; input.importTotal = library.total
        input.monitoring = workspace.monitoringActive; input.working = workspace.working; input.processingLabel = workspace.processingLabel
        input.activeFolders = workspace.data.locations.filter { !$0.paused }.count
        input.pausedFolders = workspace.data.locations.filter(\.paused).count
        input.catalogFiles = library.library.files.count
        return VaultActivity.resolve(input)
    }
    private var animating: Bool { visible && cinematicMotion && !reducedMotion && scenePhase == .active && windowState != .inactive }
    var body: some View {
        VStack(spacing: 6) {
            if showMascot {
                MascotScene(kind: activity.kind, animate: animating)
                    .frame(height: 94).allowsHitTesting(false).accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(activity.title).font(.system(size: 10, weight: .semibold)).lineLimit(2)
            }
            Text(activity.detail).font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
            if let progress = activity.progress { ProgressView(value: progress).tint(tint).controlSize(.mini).padding(.top, 3) }
        }.frame(maxWidth: .infinity).padding(.horizontal, 10).padding(.top, showMascot ? 0 : 12).padding(.bottom, 12)
            .quietPanel()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Vault activity")
            .accessibilityValue(activity.title + ". " + activity.detail)
            .onAppear { visible = true }.onDisappear { visible = false }
    }
    private var tint: Color {
        switch activity.kind {
        case .attention: VaultStyle.amber
        case .scanning, .organizing, .monitoring, .unlocked: VaultStyle.teal
        case .paused, .locked: .secondary
        default: VaultStyle.lavender
        }
    }
}

/// A true 3D, locally rendered SceneKit character. No remote assets or model downloads.
@MainActor
private struct MascotScene: NSViewRepresentable {
    let kind: VaultActivity.Kind
    let animate: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.wantsLayer = true; view.layer?.isOpaque = false
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 24
        context.coordinator.update(view: view, kind: kind, animate: animate)
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) { context.coordinator.update(view: view, kind: kind, animate: animate) }
    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stop(); view.isPlaying = false; view.rendersContinuously = false; view.scene = nil
    }

    @MainActor
    final class Coordinator {
        let scene = SCNScene()
        private let floating = SCNNode()
        private let robot = SCNNode()
        private let orbit = SCNNode()
        private let leftEye = SCNNode(geometry: SCNCapsule(capRadius: 0.055, height: 0.20))
        private let rightEye = SCNNode(geometry: SCNCapsule(capRadius: 0.055, height: 0.20))
        private let signalMaterial = SCNMaterial()
        private var previousKind: VaultActivity.Kind?
        private var previousMotion: Bool?

        init() {
            let camera = SCNNode(); camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true; camera.camera?.orthographicScale = 1.08
            camera.camera?.zNear = 0.1; camera.camera?.zFar = 20
            camera.position = SCNVector3(0, 0.15, 5); scene.rootNode.addChildNode(camera)
            light(type: .ambient, color: NSColor(calibratedWhite: 0.65, alpha: 1), position: SCNVector3(0, 0, 3), intensity: 450)
            light(type: .omni, color: NSColor(red: 0.75, green: 0.69, blue: 1, alpha: 1), position: SCNVector3(-3, 4, 4), intensity: 1000)
            light(type: .omni, color: NSColor(red: 0.30, green: 0.80, blue: 0.88, alpha: 1), position: SCNVector3(3, 0.5, -2), intensity: 900)
            scene.rootNode.addChildNode(floating); floating.addChildNode(robot)
            robot.eulerAngles = SCNVector3(-0.12, -0.20, 0)
            let body = SCNBox(width: 1.35, height: 1.12, length: 0.80, chamferRadius: 0.22)
            body.materials = [material(NSColor(red: 0.30, green: 0.30, blue: 0.45, alpha: 1), metallic: 0.55, roughness: 0.24)]
            robot.addChildNode(SCNNode(geometry: body))
            let face = SCNBox(width: 1.08, height: 0.52, length: 0.10, chamferRadius: 0.13)
            face.materials = [material(NSColor(red: 0.025, green: 0.045, blue: 0.075, alpha: 1), metallic: 0.25, roughness: 0.12)]
            let faceNode = SCNNode(geometry: face); faceNode.position = SCNVector3(0, 0.11, 0.42); robot.addChildNode(faceNode)
            signalMaterial.lightingModel = .physicallyBased; signalMaterial.roughness.contents = 0.2
            leftEye.geometry?.materials = [signalMaterial]; rightEye.geometry?.materials = [signalMaterial]
            leftEye.position = SCNVector3(-0.24, 0.14, 0.50); rightEye.position = SCNVector3(0.24, 0.14, 0.50)
            robot.addChildNode(leftEye); robot.addChildNode(rightEye)
            let mouth = SCNNode(geometry: SCNCapsule(capRadius: 0.017, height: 0.17))
            mouth.geometry?.materials = [signalMaterial]; mouth.eulerAngles.z = .pi / 2
            mouth.position = SCNVector3(0, -0.025, 0.50); robot.addChildNode(mouth)
            let emblem = SCNText(string: "V", extrusionDepth: 0.015); emblem.font = NSFont.systemFont(ofSize: 0.22, weight: .semibold)
            emblem.materials = [signalMaterial]; emblem.flatness = 0.1
            let mark = SCNNode(geometry: emblem); mark.position = SCNVector3(-0.075, -0.39, 0.405); robot.addChildNode(mark)
            for side in [-1.0, 1.0] {
                let ear = SCNNode(geometry: SCNSphere(radius: 0.11)); ear.geometry?.materials = [signalMaterial]
                ear.position = SCNVector3(Float(side * 0.72), 0.08, 0); robot.addChildNode(ear)
            }
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.93, pipeRadius: 0.006))
            ring.geometry?.materials = [material(NSColor(red: 0.5, green: 0.5, blue: 0.8, alpha: 1), metallic: 0.4, roughness: 0.3)]
            ring.eulerAngles.x = 0.18; orbit.position.y = -0.78; orbit.addChildNode(ring)
            let bead = SCNNode(geometry: SCNSphere(radius: 0.035)); bead.geometry?.materials = [signalMaterial]
            bead.position = SCNVector3(0.93, 0, 0); orbit.addChildNode(bead); scene.rootNode.addChildNode(orbit)
        }
        func update(view: SCNView, kind: VaultActivity.Kind, animate: Bool) {
            guard previousKind != kind || previousMotion != animate else { return }
            previousKind = kind; previousMotion = animate
            let color: NSColor
            switch kind {
            case .attention: color = NSColor(red: 1, green: 0.68, blue: 0.26, alpha: 1)
            case .scanning, .organizing, .monitoring, .unlocked: color = NSColor(red: 0.30, green: 0.95, blue: 0.82, alpha: 1)
            case .locked, .paused: color = NSColor(red: 0.65, green: 0.71, blue: 0.85, alpha: 1)
            default: color = NSColor(red: 0.77, green: 0.67, blue: 1, alpha: 1)
            }
            signalMaterial.diffuse.contents = color; signalMaterial.emission.contents = color.withAlphaComponent(0.45)
            stop()
            floating.position = SCNVector3(0, 0, 0); robot.eulerAngles = SCNVector3(-0.12, -0.20, 0)
            leftEye.scale = SCNVector3(1, 1, 1); rightEye.scale = SCNVector3(1, 1, 1)
            if animate {
                let busy = [.scanning, .organizing, .importing, .monitoring, .processing, .authenticating].contains(kind)
                let rise = SCNAction.moveBy(x: 0, y: 0.07, z: 0, duration: busy ? 1.4 : 2.6); rise.timingMode = .easeInEaseOut
                floating.runAction(.repeatForever(.sequence([rise, rise.reversed()])), forKey: "float")
                let turn = SCNAction.rotateBy(x: 0, y: 0.18, z: 0.02, duration: 3.5); turn.timingMode = .easeInEaseOut
                robot.runAction(.repeatForever(.sequence([turn, turn.reversed()])), forKey: "look")
                if busy { orbit.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 6)), forKey: "activity") }
                let closeEye = SCNAction.customAction(duration: 0.08) { @Sendable node, time in
                    node.scale = SCNVector3(1, Float(max(0.15, 1 - time / 0.08 * 0.85)), 1)
                }
                let openEye = SCNAction.customAction(duration: 0.12) { @Sendable node, time in
                    node.scale = SCNVector3(1, Float(min(1, 0.15 + time / 0.12 * 0.85)), 1)
                }
                let blink = SCNAction.sequence([.wait(duration: 5), closeEye, openEye])
                leftEye.runAction(.repeatForever(blink)); rightEye.runAction(.repeatForever(blink))
            }
            scene.isPaused = !animate; view.isPlaying = animate; view.rendersContinuously = animate
            view.needsDisplay = true
        }
        func stop() { floating.removeAllActions(); robot.removeAllActions(); orbit.removeAllActions(); leftEye.removeAllActions(); rightEye.removeAllActions() }
        private func material(_ color: NSColor, metallic: Double, roughness: Double) -> SCNMaterial {
            let material = SCNMaterial(); material.lightingModel = .physicallyBased
            material.diffuse.contents = color; material.metalness.contents = metallic; material.roughness.contents = roughness
            return material
        }
        private func light(type: SCNLight.LightType, color: NSColor, position: SCNVector3, intensity: CGFloat) {
            let node = SCNNode(); node.light = SCNLight(); node.light?.type = type; node.light?.color = color
            node.light?.intensity = intensity; node.position = position; scene.rootNode.addChildNode(node)
        }
    }
}
