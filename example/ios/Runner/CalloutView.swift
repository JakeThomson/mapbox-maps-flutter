import SwiftUI
import UIKit
import mapbox_maps_flutter

// MARK: - View Model
class CalloutViewModel: ObservableObject {
    @Published var emoji: String = ""
    @Published var selected: Bool = false

    // Visibility state from Mapbox collision detection
    var visibility: ViewAnnotationVisibility?
}

// MARK: - SwiftUI View
struct CalloutViewContent: View {
    @ObservedObject var viewModel: CalloutViewModel
    @ObservedObject var visibility: ViewAnnotationVisibility

    // Constants
    private let smallSize: CGFloat = 32
    private let largeSize: CGFloat = 48
    private let arrowHeight: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // 1. Background Circle
                Circle()
                    .fill(Color.white)
                    // We define the frame explicitly here so SwiftUI controls the animation curve
                    // regardless of what the UIKit parent frame does.
                    .frame(
                        width: viewModel.selected ? largeSize : smallSize,
                        height: viewModel.selected ? largeSize : smallSize
                    )
                    // Animate the border specifically
                    .overlay(
                        Circle()
                            .strokeBorder(Color.black, lineWidth: viewModel.selected ? 4 : 0)
                    )
                    // Shadow for depth (optional, matches map marker style)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)

                // 2. Emoji Label
                Text(viewModel.emoji)
                    // Trick: Set font to the LARGEST size, then scale down.
                    // This prevents pixelation and allows smooth animation.
                    .font(.system(size: 28))
                    .scaleEffect(viewModel.selected ? 1.0 : (24/28))
                    .foregroundColor(.black)
            }
            // Ensure the ZStack stays on top of the arrow visually
            .zIndex(1)

            // 3. Arrow Indicator
            Triangle()
                .fill(Color.black)
                .frame(width: 16, height: arrowHeight)
                // Instead of if/else, we keep it in the hierarchy and animate props
                .opacity(viewModel.selected ? 1 : 0)
                .offset(y: viewModel.selected ? 0 : -10) // Slide up into the circle when hiding
                .frame(height: viewModel.selected ? arrowHeight : 0) // Collapse space
                .zIndex(0)
        }
        // This is the magic sauce:
        // We allow the content to exceed the bounds during animation if needed
        .compositingGroup()
        // Visibility animation (for collision detection show/hide)
        .scaleEffect(visibility.isVisible ? 1 : 0)
        .opacity(visibility.isVisible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: visibility.isVisible)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: viewModel.selected)
    }
}

// MARK: - Triangle Shape
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - UIKit Wrapper
class CalloutView: UIView {

    private let viewModel = CalloutViewModel()
    private var visibility: ViewAnnotationVisibility
    private var hostingController: UIHostingController<CalloutViewContent>?

    // Mark as @objc dynamic to expose to Key-Value Coding for ViewAnnotationController updates
    @objc dynamic var emoji: String? {
        didSet { viewModel.emoji = emoji ?? "" }
    }

    // Mark as @objc dynamic to expose to Key-Value Coding for ViewAnnotationController updates
    @objc dynamic var selected: Bool = false {
        didSet {
            // 1. Trigger SwiftUI Animation (handles internal circle growth, border, arrow)
            withAnimation {
                viewModel.selected = selected
            }

            // 2. Animate the Mapbox Container Frame
            // Mapbox ViewAnnotations are just UIViews. We need to animate the layout update
            // to smooth out the frame resize (32px -> 48px) so it doesn't clip during animation.
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [], animations: {
                self.invalidateIntrinsicContentSize()
                self.superview?.layoutIfNeeded()
            }, completion: nil)
        }
    }

    // Keep for compatibility, but not used
    @objc dynamic var label: String?

    /// Initialize with visibility object for animation support.
    init(visibility: ViewAnnotationVisibility) {
        self.visibility = visibility
        super.init(frame: .zero)
        setupView()
    }

    override init(frame: CGRect) {
        self.visibility = ViewAnnotationVisibility()
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        self.visibility = ViewAnnotationVisibility()
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear
        clipsToBounds = false

        viewModel.visibility = visibility
        let contentView = CalloutViewContent(viewModel: viewModel, visibility: visibility)
        let hostingController = UIHostingController(rootView: contentView)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.centerXAnchor.constraint(equalTo: centerXAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        self.hostingController = hostingController
    }

    override var intrinsicContentSize: CGSize {
        // Delegate to SwiftUI content - the hosting controller knows its actual size
        return hostingController?.view.intrinsicContentSize ?? .zero
    }

}