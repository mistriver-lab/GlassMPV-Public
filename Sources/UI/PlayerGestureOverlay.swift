import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

enum PlayerGestureMath: Sendable {
    enum HorizontalZone: Equatable, Sendable {
        case left
        case center
        case right
    }

    static func zone(forX x: Double, inWidth width: Double) -> HorizontalZone {
        guard width > 1 else { return .center }
        let ratio = x / width
        if ratio < 0.30 { return .left }
        if ratio > 0.70 { return .right }
        return .center
    }

    static func seekDeltaSeconds(translationX: Double, viewWidth: Double, duration: Double) -> Double {
        guard viewWidth > 1 else { return 0 }
        let norm = translationX / viewWidth
        let sign: Double = norm >= 0 ? 1.0 : -1.0
        let mag = abs(norm)
        // 轻微非线性：慢滑精确微调，大跨度全屏滑动可快速跨 45s~180s
        let spanSeconds: Double
        if duration.isFinite && duration > 10 {
            spanSeconds = min(max(duration * 0.25, 45.0), 180.0)
        } else {
            spanSeconds = 60.0
        }
        let curved = pow(mag, 1.18) * spanSeconds
        return sign * curved
    }

    static func adjustedLevel(start: Double, translationY: Double, viewHeight: Double) -> Double {
        let clampedStart = min(1.0, max(0.0, start.isFinite ? start : 0.5))
        guard viewHeight > 1 else { return clampedStart }
        let delta = -translationY / max(120.0, viewHeight * 0.62)
        return min(1.0, max(0.0, clampedStart + delta))
    }
}

enum PlayerGestureFeedbackState: Equatable {
    case none
    case skip(seconds: Int, isRight: Bool)
    case scrub(target: Double, duration: Double, delta: Double)
    case brightness(Double)
    case volume(Double)
}

@MainActor
struct PlayerGestureOverlay: UIViewRepresentable {
    let isLocked: Bool
    let currentTime: Double
    let duration: Double
    let onSingleTap: () -> Void
    let onTogglePlayPause: () -> Void
    let onDoubleTapSkip: (Double) -> Void
    let onHoldSpeedChanged: (Bool) -> Void
    let onScrubChanged: (Double, Double) -> Void
    let onScrubEnded: (Double) -> Void
    let onBrightnessChanged: (Double) -> Void
    let onVolumeChanged: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> GestureHostView {
        let view = GestureHostView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let coord = context.coordinator

        let singleTap = UITapGestureRecognizer(target: coord, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.numberOfTouchesRequired = 1
        singleTap.delegate = coord

        let doubleTap = UITapGestureRecognizer(target: coord, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.delegate = coord

        singleTap.require(toFail: doubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: coord, action: #selector(Coordinator.handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = coord

        let longPress = UILongPressGestureRecognizer(target: coord, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 20
        longPress.delegate = coord

        let pan = UIPanGestureRecognizer(target: coord, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = coord

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(twoFingerTap)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(pan)

        coord.setupVolumeHelper(in: view)
        return view
    }

    func updateUIView(_ uiView: GestureHostView, context: Context) {
        context.coordinator.parent = self
    }

    final class GestureHostView: UIView {
        let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        enum PanMode {
            case undecided
            case horizontalScrub
            case leftBrightness
            case rightVolume
        }

        var parent: PlayerGestureOverlay
        private weak var hostView: GestureHostView?
        private var panMode: PanMode = .undecided
        private var startTime: Double = 0
        private var startLevel: Double = 0.5
        private var lastScrubTarget: Double = 0

        init(parent: PlayerGestureOverlay) {
            self.parent = parent
        }

        func setupVolumeHelper(in view: GestureHostView) {
            hostView = view
            view.volumeView.alpha = 0.001
            view.volumeView.isUserInteractionEnabled = false
            view.addSubview(view.volumeView)
        }

        private func findVolumeSlider() -> UISlider? {
            guard let volumeView = hostView?.volumeView else { return nil }
            for subview in volumeView.subviews {
                if let slider = subview as? UISlider {
                    return slider
                }
            }
            return nil
        }

        private func currentSystemVolume() -> Double {
            if let slider = findVolumeSlider() {
                return Double(slider.value)
            }
            return Double(AVAudioSession.sharedInstance().outputVolume)
        }

        private func setSystemVolume(_ level: Double) {
            let clamped = Float(min(1.0, max(0.0, level)))
            if let slider = findVolumeSlider() {
                slider.setValue(clamped, animated: false)
                slider.sendActions(for: .valueChanged)
            }
        }

        private func currentBrightness(in view: UIView) -> Double {
            Double(view.window?.windowScene?.screen.brightness ?? 0.5)
        }

        private func setBrightness(_ level: Double, in view: UIView) {
            view.window?.windowScene?.screen.brightness = CGFloat(min(1.0, max(0.0, level)))
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onSingleTap()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !parent.isLocked, let view = recognizer.view else { return }
            let loc = recognizer.location(in: view)
            let zone = PlayerGestureMath.zone(forX: Double(loc.x), inWidth: Double(view.bounds.width))
            let haptic = UIImpactFeedbackGenerator(style: .light)
            haptic.impactOccurred()
            switch zone {
            case .left:
                parent.onDoubleTapSkip(-10)
            case .right:
                parent.onDoubleTapSkip(10)
            case .center:
                parent.onTogglePlayPause()
            }
        }

        @objc func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !parent.isLocked else { return }
            let haptic = UIImpactFeedbackGenerator(style: .light)
            haptic.impactOccurred()
            parent.onTogglePlayPause()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard !parent.isLocked else {
                if recognizer.state == .ended || recognizer.state == .cancelled {
                    parent.onHoldSpeedChanged(false)
                }
                return
            }
            switch recognizer.state {
            case .began:
                let haptic = UIImpactFeedbackGenerator(style: .medium)
                haptic.impactOccurred()
                parent.onHoldSpeedChanged(true)
            case .ended, .cancelled, .failed:
                parent.onHoldSpeedChanged(false)
            default:
                break
            }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard !parent.isLocked, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)

            switch recognizer.state {
            case .began:
                panMode = .undecided
                startTime = parent.currentTime
                lastScrubTarget = parent.currentTime
                let loc = recognizer.location(in: view)
                startLevel = (loc.x < view.bounds.width * 0.5)
                    ? currentBrightness(in: view)
                    : currentSystemVolume()

            case .changed:
                if panMode == .undecided {
                    if abs(translation.x) < 10 && abs(translation.y) < 10 {
                        return
                    }
                    if abs(translation.x) > abs(translation.y) {
                        panMode = .horizontalScrub
                    } else {
                        let loc = recognizer.location(in: view)
                        if loc.x < view.bounds.width * 0.5 {
                            panMode = .leftBrightness
                            startLevel = currentBrightness(in: view)
                        } else {
                            panMode = .rightVolume
                            startLevel = currentSystemVolume()
                        }
                    }
                }

                switch panMode {
                case .undecided:
                    break
                case .horizontalScrub:
                    let delta = PlayerGestureMath.seekDeltaSeconds(
                        translationX: Double(translation.x),
                        viewWidth: Double(view.bounds.width),
                        duration: parent.duration
                    )
                    let maxDur = parent.duration > 1 ? parent.duration : (startTime + 600)
                    let target = min(maxDur, max(0, startTime + delta))
                    lastScrubTarget = target
                    parent.onScrubChanged(target, target - startTime)
                case .leftBrightness:
                    let next = PlayerGestureMath.adjustedLevel(
                        start: startLevel,
                        translationY: Double(translation.y),
                        viewHeight: Double(view.bounds.height)
                    )
                    setBrightness(next, in: view)
                    parent.onBrightnessChanged(next)
                case .rightVolume:
                    let next = PlayerGestureMath.adjustedLevel(
                        start: startLevel,
                        translationY: Double(translation.y),
                        viewHeight: Double(view.bounds.height)
                    )
                    setSystemVolume(next)
                    parent.onVolumeChanged(next)
                }

            case .ended, .cancelled, .failed:
                if panMode == .horizontalScrub {
                    parent.onScrubEnded(lastScrubTarget)
                } else if panMode == .leftBrightness {
                    parent.onBrightnessChanged(-1)
                } else if panMode == .rightVolume {
                    parent.onVolumeChanged(-1)
                }
                panMode = .undecided

            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

struct PlayerGestureFeedbackOverlay: View {
    let feedback: PlayerGestureFeedbackState
    let isHoldFastForwarding: Bool

    var body: some View {
        ZStack {
            if isHoldFastForwarding {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "forward.fill")
                            .font(.caption.weight(.bold))
                            .symbolEffect(.pulse)
                        Text("2.0× 快进中")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.cyan))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .padding(.top, 22)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            switch feedback {
            case .none:
                EmptyView()

            case .skip(let seconds, let isRight):
                HStack {
                    if isRight { Spacer() }
                    VStack(spacing: 6) {
                        Image(systemName: isRight ? "goforward.10" : "gobackward.10")
                            .font(.title2.weight(.bold))
                        Text(seconds >= 0 ? "+\(seconds)s" : "\(seconds)s")
                            .font(.caption.monospacedDigit().weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.black.opacity(0.65))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                            )
                    )
                    .padding(.horizontal, 44)
                    if !isRight { Spacer() }
                }
                .transition(.opacity)

            case .scrub(let target, let duration, let delta):
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: delta >= 0 ? "forward.frame.fill" : "backward.frame.fill")
                            .foregroundStyle(.cyan)
                        Text(formatClock(target))
                            .font(.title3.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                        if duration > 1 {
                            Text("/ \(formatClock(duration))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }

                    Text(formatDelta(delta))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.cyan)

                    if duration > 1 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.22))
                                Capsule()
                                    .fill(Color.cyan)
                                    .frame(width: max(4, geo.size.width * min(1, max(0, target / duration))))
                            }
                        }
                        .frame(width: 176, height: 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.75))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                        )
                )

            case .brightness(let level):
                meterCapsule(
                    icon: level > 0.5 ? "sun.max.fill" : "sun.min.fill",
                    title: "亮度",
                    level: level,
                    tint: .yellow
                )

            case .volume(let level):
                meterCapsule(
                    icon: level <= 0.01 ? "speaker.slash.fill" : (level > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"),
                    title: "音量",
                    level: level,
                    tint: .cyan
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func meterCapsule(icon: String, title: String, level: Double, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("\(Int((level * 100).rounded()))%")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, geo.size.width * min(1, max(0, level))))
                    }
                }
                .frame(width: 128, height: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
    }

    private func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func formatDelta(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : "-"
        let absSec = Int(abs(delta).rounded())
        let m = absSec / 60
        let s = absSec % 60
        return m > 0 ? "\(sign)\(m)分\(s)秒" : "\(sign)\(s)秒"
    }
}
