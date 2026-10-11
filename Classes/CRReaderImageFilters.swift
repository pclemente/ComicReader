import CoreImage
import UIKit

@objc(CRReaderImageFilters)
@MainActor
public final class CRReaderImageFilters: NSObject {
    @objc public static let names = ["Original", "Clear Ink", "Grayscale", "Warm Paper"]
    private static let preferenceKey = "readerImageFilter"
    private static let context = CIContext(options: [.cacheIntermediates: false])

    @objc public static var selectedIndex: Int {
        let index = UserDefaults.standard.integer(forKey: preferenceKey)
        return names.indices.contains(index) ? index : 0
    }

    @objc public static var effectiveIndex: Int {
        CRPlusStore.sharedStore.isUnlocked ? selectedIndex : 0
    }

    /// Returning to the original artwork is always available.
    @objc public static func select(_ index: Int) -> Bool {
        guard names.indices.contains(index), index == 0 || CRPlusStore.sharedStore.isUnlocked else { return false }
        UserDefaults.standard.set(index, forKey: preferenceKey)
        return true
    }

    @objc public static func displayImage(_ image: UIImage) -> UIImage {
        render(image, preset: effectiveIndex)
    }

    // Separate deterministic rendering from the StoreKit gate for regression tests.
    static func render(_ image: UIImage, preset: Int) -> UIImage {
        guard preset > 0, names.indices.contains(preset), let cgImage = image.cgImage else { return image }
        let input = CIImage(cgImage: cgImage)
        var output = input
        switch preset {
        case 1:
            output = input.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.15])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35])
        case 2:
            output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case 3:
            output = input.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.55])
        default:
            return image
        }
        guard let rendered = context.createCGImage(output.cropped(to: input.extent), from: input.extent) else { return image }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}

@objc public protocol CRReaderImageFiltersDelegate: AnyObject {
    func readerImageFiltersDidChange()
    func readerImageFiltersDidRequestClose()
}

@objc(CRReaderImageFiltersViewController)
public final class CRReaderImageFiltersViewController: UITableViewController {
    @objc public weak var delegate: CRReaderImageFiltersDelegate?
    @objc public init() { super.init(style: .insetGrouped) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Image Filters"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 70
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: CRPlusStore.entitlementDidChangeNotification, object: CRPlusStore.sharedStore)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    public override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); tableView.reloadData() }
    @objc private func refresh() { tableView.reloadData() }
    @objc private func close() { delegate?.readerImageFiltersDidRequestClose() }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { CRReaderImageFilters.names.count }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Clear Ink, Grayscale and Warm Paper are included with ComicReader Plus. Filters only change the display; your comic files remain untouched. Original is always available."
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = CRReaderImageFilters.names[indexPath.row]
        content.secondaryText = ["Unchanged artwork", "Slightly stronger contrast and sharper lines", "Remove color while keeping the artwork", "A gentle sepia tone"][indexPath.row]
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        if indexPath.row > 0 && !CRPlusStore.sharedStore.isUnlocked { content.secondaryText! += " · Plus" }
        cell.contentConfiguration = content
        cell.accessoryType = indexPath.row == CRReaderImageFilters.effectiveIndex ? .checkmark : .none
        cell.accessibilityIdentifier = "reader.filter.\(indexPath.row)"
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if CRReaderImageFilters.select(indexPath.row) {
            tableView.reloadData()
            delegate?.readerImageFiltersDidChange()
        } else {
            navigationController?.pushViewController(CRPlusViewController(), animated: true)
        }
    }
}
