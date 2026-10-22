import UIKit

@objc public protocol CRWhatsNewBannerDelegate: AnyObject {
    func whatsNewDidRequestCloud()
    func whatsNewDidRequestPlus()
    func whatsNewDidDismiss()
}

/// A dismissible announcement that leaves the library and saved-comic resume usable.
@objc(CRWhatsNewBannerView)
public final class CRWhatsNewBannerView: UIView {
    @objc public weak var delegate: CRWhatsNewBannerDelegate?
    private let bodyScroll = UIScrollView()
    private let content = UIStackView()
    private let heading = UILabel()
    private let plus = UIButton(type: .system)

    @objc public init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "library.whatsNew"
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16
        directionalLayoutMargins = .init(top: 12, leading: 16, bottom: 12, trailing: 12)

        heading.text = "Open up your comics on iPhone Duo."
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.adjustsFontForContentSizeCategory = true
        heading.numberOfLines = 0
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = "Dismiss What’s New"
        close.accessibilityIdentifier = "news.dismiss"
        close.addTarget(self, action: #selector(dismissNews), for: .touchUpInside)
        let titleRow = UIStackView(arrangedSubviews: [heading, close])
        titleRow.spacing = 8
        titleRow.alignment = .center
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleRow)

        let message = UILabel()
        message.text = "New in 1.5: open Duo for a larger comic view. Keep your page and zoom as the screen changes, with pages and controls clear of the fold. Duo support and iCloud sync across iPhone, iPad and Mac are free. Plus is still one purchase, no subscription."
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.numberOfLines = 0
        let cloud = UIButton(type: .system)
        cloud.setTitle("Free iCloud Sync", for: .normal)
        cloud.accessibilityIdentifier = "news.icloud"
        cloud.addTarget(self, action: #selector(openCloud), for: .touchUpInside)
        refreshEntitlement()
        plus.accessibilityIdentifier = "news.plus"
        plus.addTarget(self, action: #selector(openPlus), for: .touchUpInside)
        for button in [cloud, plus] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        let actions = UIStackView(arrangedSubviews: [cloud, plus])
        actions.distribution = .fillEqually
        actions.spacing = 12
        content.axis = .vertical
        content.spacing = 4
        content.addArrangedSubview(message)
        content.addArrangedSubview(actions)
        content.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.addSubview(content)
        addSubview(bodyScroll)
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            titleRow.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            titleRow.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            bodyScroll.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 2),
            bodyScroll.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            bodyScroll.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            content.topAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: bodyScroll.frameLayoutGuide.widthAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshEntitlement), name: CRPlusStore.entitlementDidChangeNotification, object: CRPlusStore.sharedStore)
    }

    public required init?(coder: NSCoder) { fatalError("Use init()") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refreshEntitlement() {
        plus.setTitle(CRPlusStore.sharedStore.isUnlocked ? "Your Plus Tools" : "Explore Plus", for: .normal)
    }

    @objc public func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let contentWidth = max(1, width - 28)
        let titleHeight = max(44, heading.sizeThatFits(.init(width: max(1, contentWidth - 52), height: .greatestFiniteMagnitude)).height)
        let bodyHeight = content.systemLayoutSizeFitting(.init(width: contentWidth, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        return ceil(24 + titleHeight + 2 + bodyHeight)
    }

    @objc private func dismissNews() { delegate?.whatsNewDidDismiss() }
    @objc private func openCloud() { delegate?.whatsNewDidRequestCloud() }
    @objc private func openPlus() { delegate?.whatsNewDidRequestPlus() }
}
