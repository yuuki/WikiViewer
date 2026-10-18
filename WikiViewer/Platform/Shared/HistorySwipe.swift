//
//  HistorySwipe.swift
//  WikiViewer
//
//  Going back and forward with a horizontal swipe. On macOS, the trackpad's
//  swipe between pages (System Settings > Trackpad > More Gestures), as in
//  Safari: it follows the fingers and goes once it passes the threshold. On
//  iOS the system's swipe goes back; a swipe in from the right edge goes
//  forward. An arrow at the edge shows how far the swipe has come.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension View {
    #if os(macOS)
    /// Back and forward in `navigation` with a horizontal swipe over this view.
    func historySwipe(_ navigation: NavigationModel) -> some View {
        modifier(HistorySwipeModifier(navigation: navigation))
    }
    #else
    /// Forward in `navigation` with a swipe in from the right edge. Goes
    /// inside the NavigationStack (its root screen); the indicator goes on
    /// the stack, over every screen.
    func historySwipeTracker(_ navigation: NavigationModel, progress: Binding<CGFloat>) -> some View {
        background(HistorySwipeTracker(navigation: navigation, progress: progress))
    }
    #endif

    /// How far a swipe through the history has come, -1...1: positive goes back.
    func historySwipeIndicator(_ progress: CGFloat) -> some View {
        overlay(alignment: progress > 0 ? .leading : .trailing) {
            if progress != 0 { SwipeIndicator(progress: progress) }
        }
    }
}

#if os(macOS)
private struct HistorySwipeModifier: ViewModifier {
    let navigation: NavigationModel
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(HistorySwipeTracker(navigation: navigation, progress: $progress))
            .historySwipeIndicator(progress)
    }
}
#endif

/// A chevron that slides in from the edge the swipe goes toward, and fills
/// in once letting go would go there.
private struct SwipeIndicator: View {
    let progress: CGFloat

    var body: some View {
        let amount = min(abs(progress), 1)
        let ready = amount >= 1
        Image(systemName: progress > 0 ? "chevron.backward" : "chevron.forward")
            .font(.title2.weight(.semibold))
            .foregroundStyle(ready ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 44, height: 44)
            .background(ready ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial), in: .circle)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            .padding(.horizontal, 12)
            .offset(x: (progress > 0 ? -1 : 1) * 60 * (1 - amount))
            .opacity(Double(amount))
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.15), value: ready)
    }
}

#if os(macOS)
/// Watches the window's scroll and swipe events over its own frame.
private struct HistorySwipeTracker: NSViewRepresentable {
    let navigation: NavigationModel
    @Binding var progress: CGFloat

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.navigation = navigation
        view.setProgress = { progress = $0 }
    }

    final class TrackerView: NSView {
        var navigation: NavigationModel?
        var setProgress: (CGFloat) -> Void = { _ in }
        private var monitor: Any?
        private var tracking = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        /// Whether the event became a swipe through the history.
        private func handle(_ event: NSEvent) -> Bool {
            guard let navigation, !tracking, HistorySwipeClaims.count == 0,
                  let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
            switch event.type {
            case .swipe:
                // A three-finger swipe, when the system is set to it.
                if event.deltaX > 0, navigation.canGoBack {
                    navigation.back()
                } else if event.deltaX < 0, navigation.canGoForward {
                    navigation.forward()
                } else {
                    return false
                }
                return true
            case .scrollWheel:
                return trackSwipe(from: event, navigation: navigation)
            default:
                return false
            }
        }

        /// A two-finger scroll that starts sideways becomes a swipe, unless
        /// it is over something that scrolls sideways (a wide table).
        private func trackSwipe(from event: NSEvent, navigation: NavigationModel) -> Bool {
            guard NSEvent.isSwipeTrackingFromScrollEventsEnabled, event.phase == .began,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                  navigation.canGoBack || navigation.canGoForward,
                  !overHorizontalScroller(event) else { return false }
            tracking = true
            var goes = false
            event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                                  dampenAmountThresholdMin: navigation.canGoForward ? -1 : 0,
                                  max: navigation.canGoBack ? 1 : 0) { [weak self] amount, phase, isComplete, _ in
                guard let self else { return }
                if phase == .ended, amount != 0, !goes {
                    goes = true
                    amount > 0 ? navigation.back() : navigation.forward()
                }
                if isComplete {
                    self.tracking = false
                    self.setProgress(0)
                } else if !goes {
                    self.setProgress(amount)
                }
            }
            return true
        }

        private func overHorizontalScroller(_ event: NSEvent) -> Bool {
            guard let content = window?.contentView,
                  var view = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
            while let superview = view.superview {
                if let scrollView = view as? NSScrollView, let document = scrollView.documentView,
                   document.frame.width > scrollView.contentView.bounds.width + 1 {
                    return true
                }
                view = superview
            }
            return false
        }
    }
}

/// Views that take the trackpad's sideways scrolling for themselves (the
/// graph pans with it) while the pointer is over them.
@MainActor
enum HistorySwipeClaims {
    static var count = 0
}

#else

/// A swipe to the left from the right edge of the navigation stack goes
/// forward. (The system's own swipe goes back.)
private struct HistorySwipeTracker: UIViewRepresentable {
    let navigation: NavigationModel
    @Binding var progress: CGFloat

    func makeUIView(context: Context) -> TrackerView { TrackerView() }

    func updateUIView(_ view: TrackerView, context: Context) {
        view.navigation = navigation
        view.setProgress = { progress = $0 }
    }

    static func dismantleUIView(_ view: TrackerView, coordinator: ()) {
        view.detach()
    }

    final class TrackerView: UIView, UIGestureRecognizerDelegate {
        var navigation: NavigationModel?
        var setProgress: (CGFloat) -> Void = { _ in }
        /// How far in the finger has to come to go forward.
        private let distance: CGFloat = 120
        /// How close to the right edge the swipe has to start.
        private let edge: CGFloat = 30
        // A plain pan that starts at the edge rather than a screen-edge pan,
        // which the Simulator's touches never start.
        private lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            recognizer.delegate = self
            return recognizer
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // On the navigation controller's view, which holds every
            // screen pushed after this one; a sheet over it or another tab
            // does not get the swipe. It stays there while this screen is
            // covered by the ones pushed after it (and out of the window).
            guard recognizer.view == nil, window != nil,
                  let controller = sequence(first: self as UIResponder, next: \.next)
                      .first(where: { $0 is UINavigationController }) as? UINavigationController else { return }
            controller.view.addGestureRecognizer(recognizer)
        }

        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard navigation?.canGoForward == true, let view = gestureRecognizer.view else { return false }
            return touch.location(in: view).x >= view.bounds.width - edge
        }

        /// Only a swipe to the left: a drag down the edge still scrolls.
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
            let velocity = recognizer.velocity(in: recognizer.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
        }

        /// Alongside the list's or note's scrolling, which would otherwise
        /// take the touch first.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }

        /// The system's swipe back, which takes any sideways drag once
        /// there is a screen to go back to, waits for this one to fail.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && !(other.view is UIScrollView)
        }

        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let navigation, navigation.canGoForward else { return setProgress(0) }
            let translation = -recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .began, .changed:
                setProgress(-min(max(translation / distance, 0), 1))
            case .ended:
                let velocity = -recognizer.velocity(in: recognizer.view).x
                setProgress(0)
                if translation >= distance || (translation > distance / 3 && velocity > 500) {
                    navigation.forward()
                }
            default:
                setProgress(0)
            }
        }
    }
}
#endif
