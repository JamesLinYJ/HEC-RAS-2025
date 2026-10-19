import RASWorkspaceCore
import SwiftUI

/// Draws only particles derived from the selected Result's real stored
/// culvert arrays. The canvas shares the owning map camera and does not accept
/// pointer input, so ProjectMapView keeps one selection/pan route.
struct StoredCulvertParticleCanvas: View {
    @ObservedObject var session: StoredCulvertProfileSession
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    let cellSize: Double?
    let isActive: Bool

    var body: some View {
        Group {
            if isActive, session.isAnimationEnabled, session.canAnimate,
               let snapshot = session.snapshot {
                let animationEpoch = session.animationEpoch
                let velocityScalar = session.velocityScalar
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        let transform = MapTransform(points: points, size: size,
                            scale: scale, offset: offset)
                        Self.draw(snapshot, elapsed: timeline.date.timeIntervalSince(animationEpoch),
                            velocityScalar: velocityScalar, cellSize: cellSize,
                            transform: transform, in: &context)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(_ snapshot: MapResultCulvertProfileSnapshot,
                             elapsed: TimeInterval,
                             velocityScalar: Double,
                             cellSize: Double?,
                             transform: MapTransform,
                             in context: inout GraphicsContext) {
        let maximumFlow = snapshot.flow.map(abs).max() ?? 0
        for index in snapshot.barrels.indices {
            let flow = snapshot.flow[index]
            let velocity = snapshot.outletVelocity[index]
            // The source receives the live screen raster's cell size. Without
            // a real active Result raster, skip moving particles instead of
            // guessing a map-unit cell size. Zero-flow markers have fixed
            // source size and do not depend on that value.
            let sourceCellSize: Double
            if abs(flow) < 0.001 {
                sourceCellSize = cellSize ?? 1
            } else if let cellSize {
                sourceCellSize = cellSize
            } else {
                continue
            }
            let frames = StoredCulvertParticleAnimation.frame(
                barrel: snapshot.barrels[index], flow: flow,
                outletVelocity: velocity, maxAbsoluteFlow: maximumFlow,
                elapsed: elapsed, cellSize: sourceCellSize,
                velocityScalar: velocityScalar)
            for frame in frames {
                let center = transform.screen(frame.position)
                let diameter = max(CGFloat(frame.diameter), 1)
                let marker = Path(ellipseIn: CGRect(x: center.x - diameter / 2,
                    y: center.y - diameter / 2, width: diameter, height: diameter))
                if frame.isZeroFlow {
                    context.stroke(marker, with: .color(Self.lightBlue), lineWidth: 2)
                } else {
                    context.fill(marker, with: .color(Self.lightBlue))
                    context.stroke(marker, with: .color(.black), lineWidth: 1)
                }
            }
        }
    }

    private static let lightBlue = Color(.sRGB, red: 173 / 255, green: 216 / 255,
                                        blue: 230 / 255, opacity: 1)
}

/// Per-map runtime controls matching the culvert animation's source settings.
/// These settings are not written to .vis or to the selected Result HDF.
struct StoredCulvertParticleSettingsButton: View {
    @ObservedObject var session: StoredCulvertProfileSession
    @State private var isPresented = false

    var body: some View {
        if session.capture != nil {
            Button { isPresented.toggle() } label: {
                Label(L10n.text("Particle Settings…"), systemImage: "circle.dotted")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .workspaceGlass()
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                settings
                    .frame(width: 300)
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            .help(L10n.text("Particle Settings"))
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Particle Settings")).font(.headline)
            Toggle(isOn: $session.isAnimationEnabled) {
                Text(L10n.text("Draw Particle Tracing"))
            }
            .disabled(!session.canAnimate)

            VStack(alignment: .leading, spacing: 6) {
                Slider(value: $session.velocityScalar, in: 1...1_000, step: 0.25) {
                    Text(L10n.text("Velocity Scalar"))
                }
                HStack {
                    Text(L10n.text("Velocity Scalar"))
                    Spacer()
                    Text(session.velocityScalar.formatted(.number.precision(.fractionLength(0...2))))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if session.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !session.canAnimate, let diagnostic = session.diagnostic {
                Text(L10n.text(diagnostic))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
