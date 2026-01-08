import UIKit

class CalloutView: UIView {
    private let emojiLabel = UILabel()
    private let textLabel = UILabel()
    private let containerStack = UIStackView()
    
    var emoji: String? {
        didSet { emojiLabel.text = emoji }
    }
    
    var label: String? {
        didSet { textLabel.text = label }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    convenience init(emoji: String?, label: String?, backgroundColor: UIColor?) {
        self.init(frame: .zero)
        self.emoji = emoji
        self.label = label
        if let bgColor = backgroundColor {
            self.backgroundColor = bgColor
        }
    }
    
    private func setupView() {
        backgroundColor = UIColor(red: 59/255, green: 130/255, blue: 246/255, alpha: 1.0)
        layer.cornerRadius = 8
        clipsToBounds = true
        
        containerStack.axis = .horizontal
        containerStack.spacing = 8
        containerStack.alignment = .center
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        
        emojiLabel.font = UIFont.systemFont(ofSize: 24)
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        
        textLabel.font = UIFont.systemFont(ofSize: 14)
        textLabel.textColor = .white
        textLabel.numberOfLines = 1
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        
        containerStack.addArrangedSubview(emojiLabel)
        containerStack.addArrangedSubview(textLabel)
        addSubview(containerStack)
        
        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200)
        ])
    }
    
    override var intrinsicContentSize: CGSize {
        let stackSize = containerStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: stackSize.width + 24, height: stackSize.height + 24)
    }
}

extension UIColor {
    convenience init(rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

