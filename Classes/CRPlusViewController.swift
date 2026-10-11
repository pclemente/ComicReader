import UIKit

public let CRPlusSyncRequestedNotification = Notification.Name("CRPlusSyncRequestedNotification")

@objc(CRPlusViewControllerDelegate)
public protocol CRPlusViewControllerDelegate: AnyObject {
    func plusViewControllerDidRequestSync(_ viewController: CRPlusViewController)
}

@objc(CRPlusViewController)
@MainActor
public final class CRPlusViewController: UITableViewController {
    @objc public class var syncRequestedNotification: NSNotification.Name {
        CRPlusSyncRequestedNotification
    }

    @objc public weak var delegate: CRPlusViewControllerDelegate?

    @objc public var showsOnlyCloud = false

    private enum Section {
        case features
        case plus
        case freeSync
        case iCloud
    }

    private var sections: [Section] { showsOnlyCloud ? [.iCloud] : [.plus, .features, .freeSync] }
    private func section(at index: Int) -> Section? {
        sections.indices.contains(index) ? sections[index] : nil
    }

    private enum PlusRow: Int, CaseIterable {
        case purchase
        case restore
    }

    private enum CloudRow: Int, CaseIterable {
        case toggle
        case syncNow
        case status
    }

    private let store = CRPlusStore.sharedStore
    private let cloud = CRCloudSyncManager.sharedManager
    private var isUpdatingCloudPreference = false
    private var didInstallObservers = false

    private let headerTitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .title1)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = .label
        label.numberOfLines = 0
        label.text = "ComicReader Plus"
        return label
    }()

    private let headerBodyLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.text = "Find that line. Save that page. Make your next read your own."
        return label
    }()

    @objc public init() {
        super.init(style: .insetGrouped)
    }

    public override init(style: UITableView.Style) {
        super.init(style: style)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        title = showsOnlyCloud ? "iCloud Sync" : "ComicReader Plus"
        if showsOnlyCloud {
            headerTitleLabel.text = "iCloud Sync"
            headerBodyLabel.text = "Pick up where you left off on iPhone, iPad and Mac. Your comics, read status and current page sync using your own iCloud Drive storage. Free for everyone."
        }
        view.backgroundColor = .systemGroupedBackground
        tableView.backgroundColor = .systemGroupedBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                             target: self,
                                                             action: #selector(done))
        configureHeader()
        installObserversIfNeeded()

        if !showsOnlyCloud { store.start() }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeaderToFit()
    }

    private func configureHeader() {
        let header = UIView()
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 12, trailing: 24)

        let imageView = UIImageView(image: UIImage(systemName: showsOnlyCloud ? "icloud.and.arrow.up.fill" : "books.vertical.fill"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = view.tintColor
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityElementsHidden = true

        let stack = UIStackView(arrangedSubviews: [imageView, headerTitleLabel, headerBodyLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        stack.setCustomSpacing(8, after: imageView)
        header.addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: header.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: header.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: header.layoutMarginsGuide.bottomAnchor)
        ])
        tableView.tableHeaderView = header
    }

    private func sizeHeaderToFit() {
        guard let header = tableView.tableHeaderView else {
            return
        }

        let width = tableView.bounds.width
        guard width > 0 else {
            return
        }
        header.frame.size.width = width
        let fittingSize = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let height = header.systemLayoutSizeFitting(fittingSize,
                                                   withHorizontalFittingPriority: .required,
                                                   verticalFittingPriority: .fittingSizeLevel).height
        if abs(header.frame.height - height) > 0.5 {
            header.frame.size.height = height
            tableView.tableHeaderView = header
        }
    }

    private func installObserversIfNeeded() {
        guard !didInstallObservers else {
            return
        }
        didInstallObservers = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(storeDidChange(_:)),
                                               name: CRPlusStore.didChangeNotification,
                                               object: store)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cloudDidChange(_:)),
                                               name: Notification.Name(CRCloudSyncManager.statusDidChangeNotification),
                                               object: cloud)
    }

    @objc private func storeDidChange(_ notification: Notification) {
        tableView.reloadData()
    }

    @objc private func cloudDidChange(_ notification: Notification) {
        isUpdatingCloudPreference = false
        tableView.reloadData()
    }

    @objc private func done() {
        if let navigationController, navigationController.viewControllers.first != self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    public override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    public override func tableView(_ tableView: UITableView,
                                   numberOfRowsInSection section: Int) -> Int {
        switch self.section(at: section) {
        case .features:
            return 4
        case .plus:
            return PlusRow.allCases.count
        case .freeSync:
            return 1
        case .iCloud:
            return CloudRow.allCases.count
        case .none:
            return 0
        }
    }

    public override func tableView(_ tableView: UITableView,
                                   titleForHeaderInSection section: Int) -> String? {
        switch self.section(at: section) {
        case .features:
            return "Included with Plus"
        case .plus:
            return store.isUnlocked ? "Your upgrade" : "One purchase · No subscription"
        case .freeSync:
            return "Included free for everyone"
        case .iCloud:
            return "iCloud sync"
        case .none:
            return nil
        }
    }

    public override func tableView(_ tableView: UITableView,
                                   titleForFooterInSection section: Int) -> String? {
        switch self.section(at: section) {
        case .features:
            return "Search indexes, quotes, lists and bookmarks stay on this device. Current-page text, copying and sharing are free. Your original comic files stay untouched."
        case .plus:
            if let error = store.error {
                return error.localizedDescription
            }
            return purchaseStatusText

        case .freeSync:
            return "Use the same Apple Account to restore Plus on iPhone, iPad and Mac. iCloud sync needs no purchase and uses your personal iCloud storage."

        case .iCloud:
            return "Sync is optional and stays off until you turn it on. When enabled, ComicReader uploads every comic file in this library and your reading progress to your personal iCloud Drive storage. An internet connection and iCloud Drive are required for first-time setup."

        case .none:
            return nil
        }
    }

    public override func tableView(_ tableView: UITableView,
                                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = self.section(at: indexPath.section) else {
            return UITableViewCell()
        }

        switch section {
        case .features:
            let cell = subtitleCell(reuseIdentifier: "Feature")
            var content = cell.defaultContentConfiguration()
            content.text = ["Find a line. Keep a quote.", "Choose your next read", "Remember a favorite page", "Make the artwork your own"][indexPath.row]
            content.secondaryText = ["Search every indexed page of the comic you’re reading. Jump to matches and save editable quotes. Recognition happens on this device.", "Build reading lists across folders. Smart queues gather in-progress, unread and read comics automatically.", "Give a page a name and jump back to it with a bookmark.", "Preview Clear Ink, Grayscale and Warm Paper. Filters change the display, never the original file."][indexPath.row]
            content.image = UIImage(systemName: ["text.magnifyingglass", "list.bullet.rectangle", "bookmark", "camera.filters"][indexPath.row])
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = indexPath.row == 3 ? .default : .none
            cell.accessoryType = indexPath.row == 3 ? .disclosureIndicator : .none
            cell.accessibilityIdentifier = ["plus.comicTextFeature", "plus.readingListsFeature", "plus.bookmarksFeature", "plus.imageFiltersFeature"][indexPath.row]
            return cell
        case .freeSync:
            let cell = subtitleCell(reuseIdentifier: "FreeSync")
            var content = cell.defaultContentConfiguration()
            content.text = "Your library, across iPhone, iPad and Mac"
            content.secondaryText = "Free iCloud sync for comics and reading progress. Reading and importing stay free too."
            content.image = UIImage(systemName: "icloud")
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "plus.freeSync"
            return cell
        case .plus:
            guard let row = PlusRow(rawValue: indexPath.row) else {
                return UITableViewCell()
            }
            switch row {
            case .purchase:
                return purchaseCell()
            case .restore:
                return restoreCell()
            }

        case .iCloud:
            guard let row = CloudRow(rawValue: indexPath.row) else {
                return UITableViewCell()
            }
            switch row {
            case .toggle:
                return cloudToggleCell()
            case .syncNow:
                return syncNowCell()
            case .status:
                return cloudStatusCell()
            }
        }
    }

    public override func tableView(_ tableView: UITableView,
                                   didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = self.section(at: indexPath.section) else {
            return
        }

        switch section {
        case .features:
            if indexPath.row == 3 {
                navigationController?.pushViewController(CRPlusFilterPreviewController(), animated: true)
            }
        case .freeSync:
            let controller = CRPlusViewController()
            controller.showsOnlyCloud = true
            navigationController?.pushViewController(controller, animated: true)
        case .plus:
            switch PlusRow(rawValue: indexPath.row) {
            case .purchase:
                purchase()
            case .restore:
                restore()
            case .none:
                break
            }

        case .iCloud:
            if CloudRow(rawValue: indexPath.row) == .syncNow {
                requestSync()
            }
        }
    }

    private func purchaseCell() -> UITableViewCell {
        let cell = subtitleCell(reuseIdentifier: "Purchase")
        var content = cell.defaultContentConfiguration()
        content.image = UIImage(systemName: store.isUnlocked ? "checkmark.seal.fill" : "sparkles")
        content.imageProperties.tintColor = store.isUnlocked ? .systemGreen : view.tintColor
        content.text = store.isUnlocked ? "ComicReader Plus" : purchaseTitle
        content.secondaryText = store.isUnlocked ? "Unlocked with your Apple Account · Thank you" : "All Plus tools · iPhone, iPad and Mac"
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.textProperties.color = store.isUnlocked ? .label : view.tintColor
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = store.isUnlocked ? .checkmark : .disclosureIndicator
        cell.accessoryView = store.status == .purchasing ? activityIndicator() : nil
        cell.selectionStyle = store.isUnlocked || store.isBusy ? .none : .default
        cell.isUserInteractionEnabled = !store.isUnlocked && !store.isBusy
        cell.accessibilityIdentifier = "plus.purchase"
        cell.accessibilityValue = store.isUnlocked ? "Unlocked" : "Not purchased"
        cell.accessibilityHint = store.isUnlocked ? "ComicReader Plus is active." : "Starts the App Store purchase flow."
        return cell
    }

    private func restoreCell() -> UITableViewCell {
        let cell = subtitleCell(reuseIdentifier: "Restore")
        var content = cell.defaultContentConfiguration()
        content.image = UIImage(systemName: "arrow.clockwise")
        content.imageProperties.tintColor = view.tintColor
        content.text = "Restore Purchases"
        content.secondaryText = "Check this Apple Account for ComicReader Plus"
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.accessoryView = store.status == .restoring ? activityIndicator() : nil
        cell.selectionStyle = store.isBusy ? .none : .default
        cell.isUserInteractionEnabled = !store.isBusy
        cell.accessibilityIdentifier = "plus.restore"
        cell.accessibilityHint = "Checks the App Store for an earlier ComicReader Plus purchase."
        return cell
    }

    private func cloudToggleCell() -> UITableViewCell {
        let cell = subtitleCell(reuseIdentifier: "CloudToggle")
        var content = cell.defaultContentConfiguration()
        content.image = UIImage(systemName: "icloud")
        content.imageProperties.tintColor = view.tintColor
        content.text = "Sync with iCloud"
        content.secondaryText = "Free · Optional"
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content

        let toggle = UISwitch()
        toggle.isOn = cloudSwitchIsOn
        toggle.isEnabled = !isUpdatingCloudPreference &&
            (cloud.optedIn || cloud.configured)
        toggle.addTarget(self, action: #selector(cloudSwitchChanged(_:)), for: .valueChanged)
        toggle.accessibilityLabel = "Sync all comics with iCloud"
        toggle.accessibilityHint = toggle.isOn ? "Turns iCloud sync off on this device." : "Shows what will be uploaded before asking for consent."
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = "plus.icloudToggle"
        return cell
    }

    private func syncNowCell() -> UITableViewCell {
        let cell = subtitleCell(reuseIdentifier: "SyncNow")
        let enabled = cloud.enabled && !cloud.isSyncing && !isUpdatingCloudPreference
        var content = cell.defaultContentConfiguration()
        content.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        content.imageProperties.tintColor = enabled ? view.tintColor : .tertiaryLabel
        content.text = "Sync Now"
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.color = enabled ? view.tintColor : .tertiaryLabel
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryView = cloud.isSyncing ? activityIndicator() : nil
        cell.selectionStyle = enabled ? .default : .none
        cell.isUserInteractionEnabled = enabled
        cell.accessibilityIdentifier = "plus.syncNow"
        cell.accessibilityHint = "Starts iCloud sync for the current library."
        return cell
    }

    private func cloudStatusCell() -> UITableViewCell {
        let cell = subtitleCell(reuseIdentifier: "CloudStatus")
        var content = cell.defaultContentConfiguration()
        content.image = UIImage(systemName: cloudStatusSymbolName)
        content.imageProperties.tintColor = cloud.lastError == nil ? .secondaryLabel : .systemRed
        content.text = "Sync Status"
        content.secondaryText = cloudStatusText
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = cloud.lastError == nil ? .secondaryLabel : .systemRed
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = cloud.isSyncing ? activityIndicator() : nil
        cell.accessibilityIdentifier = "plus.syncStatus"
        return cell
    }

    private func subtitleCell(reuseIdentifier: String) -> UITableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier) {
            cell.accessoryView = nil
            cell.accessoryType = .none
            cell.isUserInteractionEnabled = true
            return cell
        }
        return UITableViewCell(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }

    private func activityIndicator() -> UIActivityIndicatorView {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        indicator.accessibilityLabel = "In progress"
        return indicator
    }

    private var purchaseTitle: String {
        if let price = store.displayPrice {
            return "Get Plus · \(price) once"
        }
        return "Buy ComicReader Plus"
    }

    private var purchaseStatusText: String {
        switch store.status {
        case .idle:
            return "Connect to the internet to load the current one-time price."
        case .loading:
            return "Checking your purchase and loading the current App Store price…"
        case .ready:
            return store.isUnlocked ? "ComicReader Plus is active." : "The price shown is supplied by the App Store for your account and region."
        case .purchasing:
            return "Completing your purchase with the App Store…"
        case .purchasePending:
            return "The purchase is waiting for approval. ComicReader Plus will unlock after the App Store confirms it."
        case .purchaseCancelled:
            return "The purchase was cancelled."
        case .restoring:
            return "Checking this Apple Account for an earlier purchase…"
        case .restored:
            return store.isUnlocked ? "ComicReader Plus was restored." : "No ComicReader Plus purchase was found for this Apple Account."
        case .failed:
            return store.error?.localizedDescription ?? "The App Store request could not be completed."
        @unknown default:
            return "The App Store status is unavailable."
        }
    }

    private var cloudSwitchIsOn: Bool {
        cloud.optedIn
    }

    private var cloudStatusText: String {
        var components = [cloud.lastError?.localizedDescription ?? cloud.statusMessage]
        if let lastSyncDate = cloud.lastSyncDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            components.append("Last synced \(formatter.string(from: lastSyncDate))")
        }
        return components.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var cloudStatusSymbolName: String {
        switch cloud.status {
        case .ready:
            return "checkmark.icloud"
        case .syncing, .downloading:
            return "arrow.triangle.2.circlepath.icloud"
        case .waitingForNetwork:
            return "wifi.slash"
        case .quotaExceeded, .failed, .iCloudUnavailable, .accountChanged:
            return "exclamationmark.icloud"
        case .disabled, .notEntitled, .optInRequired:
            return "icloud.slash"
        @unknown default:
            return "icloud"
        }
    }

    private func purchase() {
        guard !store.isUnlocked, !store.isBusy else {
            return
        }
        store.purchase { [weak self] unlocked, error in
            guard let self else {
                return
            }
            self.tableView.reloadData()
            if let error {
                self.presentError(error, title: "Purchase Could Not Be Completed")
            } else if !unlocked, self.store.status == .purchasePending {
                self.presentMessage(title: "Purchase Pending",
                                    message: "The App Store will notify ComicReader after the purchase is approved.")
            }
        }
    }

    private func restore() {
        guard !store.isBusy else {
            return
        }
        store.restore { [weak self] unlocked, error in
            guard let self else {
                return
            }
            self.tableView.reloadData()
            if let error {
                self.presentError(error, title: "Restore Could Not Be Completed")
            } else if unlocked {
                self.presentMessage(title: "Purchase Restored",
                                    message: "ComicReader Plus is active on this device.")
            } else {
                self.presentMessage(title: "No Purchase Found",
                                    message: "No ComicReader Plus purchase was found for this Apple Account.")
            }
        }
    }

    @objc private func cloudSwitchChanged(_ sender: UISwitch) {
        if sender.isOn {
            sender.setOn(false, animated: true)
            presentCloudConsent()
        } else {
            setCloudOptedIn(false)
        }
    }

    private func presentCloudConsent() {
        guard cloud.configured else {
            return
        }

        let alert = UIAlertController(
            title: "Turn On iCloud Sync?",
            message: "ComicReader will upload every comic file in this library, including read and unread status and the current page, to your personal iCloud Drive storage. The files can use significant iCloud storage and will sync to your devices signed in to this iCloud account. Nothing is uploaded until you choose Turn On.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Turn On", style: .default) { [weak self] _ in
            self?.setCloudOptedIn(true)
        })
        present(alert, animated: true)
    }

    private func setCloudOptedIn(_ optedIn: Bool) {
        guard !isUpdatingCloudPreference else {
            return
        }
        isUpdatingCloudPreference = true
        tableView.reloadData()
        cloud.setOptedIn(optedIn) { [weak self] error in
            guard let self else {
                return
            }
            self.isUpdatingCloudPreference = false
            self.tableView.reloadData()
            if let error {
                self.presentError(error, title: "iCloud Sync Could Not Be Changed")
            } else if optedIn {
                self.requestSync()
            }
        }
    }

    private func requestSync() {
        guard cloud.enabled, !cloud.isSyncing else {
            return
        }
        if let delegate {
            delegate.plusViewControllerDidRequestSync(self)
        } else {
            NotificationCenter.default.post(name: CRPlusSyncRequestedNotification, object: self)
        }
    }

    private func presentError(_ error: NSError, title: String) {
        presentMessage(title: title, message: error.localizedDescription)
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else {
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}


/// A real rendering preview that never changes the reader’s paid preferences.
@MainActor
private final class CRPlusFilterPreviewController: UITableViewController {
    private let artwork = CRPlusFilterPreviewController.sampleArtwork()
    private let preview = UIImageView()
    private var selectedPreset = 0

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Preview Image Filters"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        preview.contentMode = .scaleAspectFit
        preview.image = artwork
        preview.accessibilityIdentifier = "plus.filterPreview.image"
        preview.isAccessibilityElement = true
        preview.accessibilityLabel = "Original sample comic artwork"
        tableView.tableHeaderView = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = min(280, max(140, tableView.bounds.width * 0.62))
        if preview.frame.height != height || preview.frame.width != tableView.bounds.width {
            preview.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height)
            tableView.tableHeaderView = preview
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        CRReaderImageFilters.names.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Try every filter on this sample for free. Plus applies them to your comics. This preview does not change your reading settings or comic files."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = CRReaderImageFilters.names[indexPath.row]
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = selectedPreset == indexPath.row ? .checkmark : .none
        cell.accessibilityIdentifier = "plus.filterPreview.\(indexPath.row)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedPreset = indexPath.row
        preview.image = CRReaderImageFilters.render(artwork, preset: selectedPreset)
        preview.accessibilityLabel = "\(CRReaderImageFilters.names[selectedPreset]) sample comic artwork"
        tableView.reloadData()
    }

    private static func sampleArtwork() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 380), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 380))
            let panels = [CGRect(x: 20, y: 20, width: 220, height: 340), CGRect(x: 255, y: 20, width: 325, height: 160), CGRect(x: 255, y: 195, width: 325, height: 165)]
            let colors = [UIColor(red: 0.22, green: 0.67, blue: 0.75, alpha: 1), UIColor(red: 1, green: 0.77, blue: 0.30, alpha: 1), UIColor(red: 0.87, green: 0.39, blue: 0.37, alpha: 1)]
            for (index, panel) in panels.enumerated() {
                colors[index].setFill()
                context.fill(panel)
                UIColor.black.setStroke()
                let border = UIBezierPath(rect: panel)
                border.lineWidth = 4
                border.stroke()
            }
            UIColor(red: 1, green: 0.83, blue: 0.37, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 96, y: 58, width: 90, height: 90)).fill()
            UIColor(red: 0.13, green: 0.21, blue: 0.28, alpha: 1).setFill()
            let hill = UIBezierPath()
            hill.move(to: CGPoint(x: 22, y: 300))
            hill.addLine(to: CGPoint(x: 100, y: 185))
            hill.addLine(to: CGPoint(x: 165, y: 267))
            hill.addLine(to: CGPoint(x: 238, y: 222))
            hill.addLine(to: CGPoint(x: 238, y: 358))
            hill.addLine(to: CGPoint(x: 22, y: 358))
            hill.close()
            hill.fill()
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 275, y: 38, width: 283, height: 83), cornerRadius: 25).fill()
            ("One more chapter…" as NSString).draw(in: CGRect(x: 294, y: 64, width: 260, height: 45), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.black])
            for x in stride(from: 277, through: 551, by: 18) {
                for y in stride(from: 217, through: 331, by: 18) {
                    UIColor.black.withAlphaComponent(0.24).setFill()
                    UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 4, height: 4)).fill()
                }
            }
            ("THE STORY CONTINUES" as NSString).draw(in: CGRect(x: 278, y: 264, width: 280, height: 45), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 19), .foregroundColor: UIColor.black])
        }
    }
}
