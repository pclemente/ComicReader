import Foundation
import UIKit
import WebKit

@MainActor
private protocol CRWebBrowserSessionObserver: AnyObject {
  func webBrowserSession(_ session: CRWebBrowserSession,
                         didUpdate entries: [CRWebDownloadEntry])
  func webBrowserSession(_ session: CRWebBrowserSession, didImport url: URL)
}

@MainActor
private final class CRWebBrowserSession {
  let manager: CRWebDownloadManager
  let isPrivate: Bool
  var libraryDidChangeHandler: (() -> Void)?

  private let observers = NSHashTable<AnyObject>.weakObjects()

  init(libraryRootURL: URL, isPrivate: Bool) throws {
    self.isPrivate = isPrivate
    manager = try CRWebDownloadManager(libraryRootURL: libraryRootURL)
    manager.onChange = { [weak self] entries in
      self?.notifyEntries(entries)
    }
    manager.onImport = { [weak self] url in
      guard let self else { return }
      self.libraryDidChangeHandler?()
      for case let observer as CRWebBrowserSessionObserver in self.observers.allObjects {
        observer.webBrowserSession(self, didImport: url)
      }
    }
  }

  func addObserver(_ observer: CRWebBrowserSessionObserver) {
    observers.add(observer)
    observer.webBrowserSession(self, didUpdate: manager.entries)
  }

  func removeObserver(_ observer: CRWebBrowserSessionObserver) {
    observers.remove(observer)
  }

  func cancelAndPurgePrivateDownloads() {
    guard isPrivate else { return }
    manager.cancelAndRemoveAll()
  }

  private func notifyEntries(_ entries: [CRWebDownloadEntry]) {
    for case let observer as CRWebBrowserSessionObserver in observers.allObjects {
      observer.webBrowserSession(self, didUpdate: entries)
    }
  }
}

@MainActor
private enum CRWebBrowserSessionRegistry {
  private static var standardSessions: [String: CRWebBrowserSession] = [:]

  static func standardSession(for libraryRootURL: URL) throws -> CRWebBrowserSession {
    let key = libraryRootURL.standardizedFileURL.resolvingSymlinksInPath().path
    if let session = standardSessions[key] {
      return session
    }
    let session = try CRWebBrowserSession(libraryRootURL: libraryRootURL, isPrivate: false)
    standardSessions[key] = session
    return session
  }
}

@objc(CRWebBrowserViewController)
@MainActor
public final class CRWebBrowserViewController: UIViewController {
  @objc public var openComicHandler: ((URL) -> Void)?
  @objc public var libraryDidChangeHandler: (() -> Void)? {
    didSet {
      session?.libraryDidChangeHandler = libraryDidChangeHandler
    }
  }

  private enum DestinationSelection {
    case selected(String?)
    case cancelled
  }

  private enum DownloadConversionKey: Hashable {
    case navigationAction(ObjectIdentifier)
    case navigationResponse(ObjectIdentifier)
  }

  private final class PendingDestinationRequest {
    private var completion: ((DestinationSelection) -> Void)?

    init(completion: @escaping (DestinationSelection) -> Void) {
      self.completion = completion
    }

    func resolve(_ selection: DestinationSelection) {
      guard let completion else { return }
      self.completion = nil
      completion(selection)
    }
  }

  private let libraryRootURL: URL
  private let plusStore = CRPlusStore.sharedStore

  private var siteStore: CRBrowserSiteStore = .sharedStore
  private var savedSites: [CRBrowserSite] = []
  private var lastVisitedURL: URL?
  private var session: CRWebBrowserSession?
  private var sessionStartupError: Error?
  private var isPrivateBrowsing = false
  private var didTearDownPrivateSession = false

  private var webView: WKWebView!
  private var progressObservation: NSKeyValueObservation?
  private var pendingDestinationByConversion: [DownloadConversionKey: DestinationSelection] = [:]
  private var pendingDestinationRequest: PendingDestinationRequest?
  private var selectedDestinationCollection: String?
  private var handledPopupActions: Set<ObjectIdentifier> = []
  private var pendingJavaScriptDialogCancellation: (() -> Void)?
  private var latestEntries: [CRWebDownloadEntry] = []
  private var currentDocumentIsPDF = false

  private let progressView: UIProgressView = {
    let view = UIProgressView(progressViewStyle: .bar)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    view.accessibilityIdentifier = "library.browser.pageProgress"
    return view
  }()

  private let contentView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var homeTableView: UITableView = {
    let table = UITableView(frame: .zero, style: .insetGrouped)
    table.translatesAutoresizingMaskIntoConstraints = false
    table.dataSource = self
    table.delegate = self
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 64
    table.keyboardDismissMode = .interactive
    table.accessibilityIdentifier = "library.browser.home"
    return table
  }()

  private let homeHeaderView = UIView()

  private let homeIconView: UIImageView = {
    let imageView = UIImageView(image: UIImage(systemName: "globe"))
    imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 42, weight: .regular)
    imageView.tintColor = .systemBlue
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = false
    return imageView
  }()

  private let homeTitleLabel: UILabel = {
    let label = UILabel()
    label.text = "Read from the Web"
    label.font = .preferredFont(forTextStyle: .title2)
    label.adjustsFontForContentSizeCategory = true
    label.textAlignment = .center
    label.numberOfLines = 0
    return label
  }()

  private let homeExplanationLabel: UILabel = {
    let label = UILabel()
    label.text = "Sign in on a publisher’s website, then use Plus to download a CBZ, CBR, or PDF directly to your library. Your website sessions stay on this device. Some sign-in providers require Safari."
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.numberOfLines = 0
    return label
  }()

  private lazy var homeAddressField: UITextField = {
    let field = UITextField()
    field.borderStyle = .roundedRect
    field.placeholder = "example.com"
    field.font = .preferredFont(forTextStyle: .body)
    field.adjustsFontForContentSizeCategory = true
    field.keyboardType = .URL
    field.textContentType = .URL
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.clearButtonMode = .whileEditing
    field.returnKeyType = .go
    field.delegate = self
    field.accessibilityLabel = "Website address"
    field.accessibilityIdentifier = "library.browser.homeAddress"
    return field
  }()

  private lazy var visitButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = "Open Website"
    configuration.image = UIImage(systemName: "arrow.right")
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 8
    configuration.cornerStyle = .medium
    button.configuration = configuration
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.addTarget(self, action: #selector(openHomeAddress), for: .touchUpInside)
    button.accessibilityIdentifier = "library.browser.openWebsite"
    return button
  }()

  private lazy var continueButton: UIButton = {
    let button = UIButton(type: .system)
    button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.addTarget(self, action: #selector(continueLastPage), for: .touchUpInside)
    button.accessibilityIdentifier = "library.browser.continue"
    button.isHidden = true
    return button
  }()

  private let privateNoticeLabel: UILabel = {
    let label = UILabel()
    label.font = .preferredFont(forTextStyle: .footnote)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .systemPurple
    label.textAlignment = .center
    label.numberOfLines = 0
    label.text = "Private Browsing: this session’s pages, sign-ins, saved sites, and download details are discarded when it closes. Comics already imported remain in your library."
    label.accessibilityIdentifier = "library.browser.privateNotice"
    label.isHidden = true
    return label
  }()

  private lazy var homeHeaderStack: UIStackView = {
    let stack = UIStackView(arrangedSubviews: [homeIconView,
                                               homeTitleLabel,
                                               homeExplanationLabel,
                                               homeAddressField,
                                               visitButton,
                                               continueButton,
                                               privateNoticeLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 14
    stack.setCustomSpacing(8, after: homeTitleLabel)
    stack.setCustomSpacing(20, after: homeExplanationLabel)
    stack.setCustomSpacing(8, after: visitButton)
    return stack
  }()

  private lazy var addressField: UITextField = {
    let field = UITextField(frame: CGRect(x: 0, y: 0, width: 280, height: 36))
    field.borderStyle = .roundedRect
    field.placeholder = "Website address"
    field.font = .preferredFont(forTextStyle: .subheadline)
    field.adjustsFontForContentSizeCategory = true
    field.keyboardType = .URL
    field.textContentType = .URL
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.clearButtonMode = .whileEditing
    field.returnKeyType = .go
    field.delegate = self
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.accessibilityLabel = "Current website address"
    field.accessibilityIdentifier = "library.browser.address"
    return field
  }()

  private let errorView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .systemBackground
    view.isHidden = true
    view.accessibilityIdentifier = "library.browser.error"
    return view
  }()

  private let errorLabel: UILabel = {
    let label = UILabel()
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.textAlignment = .center
    label.textColor = .secondaryLabel
    label.numberOfLines = 0
    return label
  }()

  private lazy var errorRetryButton: UIButton = {
    let button = UIButton(type: .system)
    button.setTitle("Try Again", for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.addTarget(self, action: #selector(retryPage), for: .touchUpInside)
    button.accessibilityIdentifier = "library.browser.retryPage"
    return button
  }()

  private lazy var backButton = toolbarButton(image: "chevron.backward",
                                               label: "Back",
                                               action: #selector(goBack))
  private lazy var forwardButton = toolbarButton(image: "chevron.forward",
                                                  label: "Forward",
                                                  action: #selector(goForward))
  private lazy var reloadButton = toolbarButton(image: "arrow.clockwise",
                                                 label: "Reload",
                                                 action: #selector(reloadOrStop))
  private lazy var downloadsButton = toolbarButton(image: "arrow.down.circle",
                                                    label: "Downloads",
                                                    action: #selector(showDownloads))
  private lazy var moreItem = UIBarButtonItem(title: nil,
                                               image: UIImage(systemName: "ellipsis.circle"),
                                               primaryAction: nil,
                                               menu: makeMoreMenu())

  @objc(initWithLibraryRootURL:)
  public init(libraryRootURL: URL) {
    self.libraryRootURL = libraryRootURL.standardizedFileURL.resolvingSymlinksInPath()
    super.init(nibName: nil, bundle: nil)
  }

  public required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    progressObservation?.invalidate()
    NotificationCenter.default.removeObserver(self)
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = "Web"
    view.accessibilityIdentifier = "library.browser"

    configureNavigation()
    configureHome()
    configureErrorView()
    configureLayout()
    installSession(privateBrowsing: false)
    replaceWebView(privateBrowsing: false)
    reloadSavedSites(presentErrors: false)
    plusStore.start()
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(plusEntitlementChanged),
                                           name: CRPlusStore.entitlementDidChangeNotification,
                                           object: plusStore)
    updateControls()
  }

  public override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setToolbarHidden(false, animated: animated)
    session?.addObserver(self)
    updateControls()
  }

  public override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      cancelPendingWebKitInteractions()
      tearDownPrivateSessionIfNeeded()
    }
  }

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateHomeHeaderHeight()
  }

  public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
      updateHomeHeaderHeight()
    }
  }

  private func configureNavigation() {
    navigationItem.titleView = addressField
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                        target: self,
                                                        action: #selector(done))
    navigationItem.leftBarButtonItem?.accessibilityIdentifier = "library.browser.done"
    moreItem.accessibilityLabel = "More"
    moreItem.accessibilityIdentifier = "library.browser.more"

    let flexible = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace,
                                     target: nil,
                                     action: nil) }
    toolbarItems = [UIBarButtonItem(customView: backButton), flexible(),
                    UIBarButtonItem(customView: forwardButton), flexible(),
                    UIBarButtonItem(customView: reloadButton), flexible(),
                    UIBarButtonItem(customView: downloadsButton), flexible(),
                    moreItem]
  }

  private func configureHome() {
    homeHeaderView.backgroundColor = .clear
    homeHeaderView.addSubview(homeHeaderStack)
    NSLayoutConstraint.activate([
      homeIconView.heightAnchor.constraint(equalToConstant: 54),
      homeHeaderStack.leadingAnchor.constraint(equalTo: homeHeaderView.layoutMarginsGuide.leadingAnchor,
                                               constant: 12),
      homeHeaderStack.trailingAnchor.constraint(equalTo: homeHeaderView.layoutMarginsGuide.trailingAnchor,
                                                constant: -12),
      homeHeaderStack.topAnchor.constraint(equalTo: homeHeaderView.topAnchor, constant: 28),
      homeHeaderStack.bottomAnchor.constraint(equalTo: homeHeaderView.bottomAnchor, constant: -20)
    ])
    sizeHomeHeader(toWidth: max(view.bounds.width, 1))
    homeTableView.tableHeaderView = homeHeaderView
  }

  private func configureErrorView() {
    let imageView = UIImageView(image: UIImage(systemName: "exclamationmark.triangle"))
    imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34)
    imageView.tintColor = .secondaryLabel
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = false

    let stack = UIStackView(arrangedSubviews: [imageView, errorLabel, errorRetryButton])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 16
    errorView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: errorView.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: errorView.trailingAnchor, constant: -28),
      stack.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
      errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
    ])
  }

  private func configureLayout() {
    view.addSubview(progressView)
    view.addSubview(contentView)
    contentView.addSubview(homeTableView)
    contentView.addSubview(errorView)
    NSLayoutConstraint.activate([
      progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
      contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      homeTableView.topAnchor.constraint(equalTo: contentView.topAnchor),
      homeTableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      homeTableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      homeTableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      errorView.topAnchor.constraint(equalTo: contentView.topAnchor),
      errorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      errorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      errorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
    ])
  }

  private func installSession(privateBrowsing: Bool) {
    session?.removeObserver(self)
    do {
      let newSession = privateBrowsing
        ? try CRWebBrowserSession(libraryRootURL: libraryRootURL, isPrivate: true)
        : try CRWebBrowserSessionRegistry.standardSession(for: libraryRootURL)
      newSession.libraryDidChangeHandler = libraryDidChangeHandler
      session = newSession
      sessionStartupError = nil
      newSession.addObserver(self)
    } catch {
      session = nil
      sessionStartupError = error
    }
  }

  private func replaceWebView(privateBrowsing: Bool) {
    progressObservation?.invalidate()
    progressObservation = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView?.removeFromSuperview()

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = privateBrowsing ? .nonPersistent() : .default()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let newWebView = WKWebView(frame: .zero, configuration: configuration)
    newWebView.translatesAutoresizingMaskIntoConstraints = false
    newWebView.navigationDelegate = self
    newWebView.uiDelegate = self
    newWebView.allowsBackForwardNavigationGestures = true
    newWebView.accessibilityIdentifier = "library.browser.webView"
    contentView.insertSubview(newWebView, belowSubview: homeTableView)
    NSLayoutConstraint.activate([
      newWebView.topAnchor.constraint(equalTo: contentView.topAnchor),
      newWebView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      newWebView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      newWebView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
    ])
    webView = newWebView
    progressObservation = newWebView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
      guard let self else { return }
      self.progressView.progress = Float(webView.estimatedProgress)
      self.progressView.isHidden = !webView.isLoading || webView.estimatedProgress >= 1
    }
    showHome()
  }

  private func toolbarButton(image: String,
                             label: String,
                             action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
    button.setImage(UIImage(systemName: image), for: .normal)
    button.addTarget(self, action: action, for: .touchUpInside)
    button.accessibilityLabel = label
    button.accessibilityIdentifier = "library.browser.\(label.lowercased())"
    return button
  }

  private func updateHomeHeaderHeight() {
    let width = homeTableView.bounds.width
    guard width > 0 else { return }
    sizeHomeHeader(toWidth: width)
  }

  private func sizeHomeHeader(toWidth width: CGFloat) {
    let margins = homeHeaderView.layoutMargins
    let stackWidth = max(1, width - margins.left - margins.right - 24)
    let fitting = homeHeaderStack.systemLayoutSizeFitting(
      CGSize(width: stackWidth, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    let targetHeight = ceil(fitting.height + 28 + 20)
    guard targetHeight.isFinite,
          targetHeight > 0 else { return }
    let sizeChanged = abs(homeHeaderView.frame.width - width) > 0.5 ||
      abs(homeHeaderView.frame.height - targetHeight) > 0.5
    guard sizeChanged else { return }
    homeHeaderView.frame.size.width = width
    homeHeaderView.frame.size.height = targetHeight
    if homeTableView.tableHeaderView === homeHeaderView {
      homeTableView.tableHeaderView = homeHeaderView
    }
  }
}

private extension CRWebBrowserViewController {
  @objc func done() {
    cancelPendingWebKitInteractions()
    tearDownPrivateSessionIfNeeded()
    dismiss(animated: true)
  }

  @objc func openHomeAddress() {
    navigate(toUserInput: homeAddressField.text ?? "")
  }

  @objc func continueLastPage() {
    guard let lastVisitedURL else { return }
    loadPage(lastVisitedURL)
  }

  @objc func goBack() {
    webView.goBack()
  }

  @objc func goForward() {
    webView.goForward()
  }

  @objc func reloadOrStop() {
    if webView.isLoading {
      webView.stopLoading()
      progressView.isHidden = true
    } else if errorView.isHidden {
      webView.reload()
    } else {
      retryPage()
    }
    updateControls()
  }

  @objc func retryPage() {
    errorView.isHidden = true
    if let url = webView.url {
      webView.load(URLRequest(url: url))
    } else if let lastVisitedURL, !isPrivateBrowsing {
      loadPage(lastVisitedURL)
    } else {
      showHome()
    }
  }

  @objc func showDownloads() {
    guard let session else {
      presentError(sessionStartupError ?? NSError(domain: CRBrowserSiteStore.errorDomain,
                                                   code: CRBrowserSiteErrorCode.storageUnavailable.rawValue,
                                                   userInfo: [NSLocalizedDescriptionKey:
                                                    "Downloads are unavailable for this library."]))
      return
    }
    let controller = CRWebDownloadsViewController(
      session: session,
      webView: webView,
      openHandler: { [weak self] url in self?.openImportedComic(url) },
      plusHandler: { [weak self] in self?.showPlus() }
    )
    navigationController?.pushViewController(controller, animated: true)
  }

  @objc func plusEntitlementChanged() {
    updateControls()
  }

  func navigate(toUserInput input: String) {
    do {
      let url = try CRBrowserSiteStore.normalizedWebsiteURL(from: input)
      homeAddressField.resignFirstResponder()
      addressField.resignFirstResponder()
      loadPage(url)
    } catch {
      presentError(error)
    }
  }

  func loadPage(_ url: URL) {
    loadNavigationRequest(URLRequest(url: url,
                                     cachePolicy: .useProtocolCachePolicy,
                                     timeoutInterval: 60))
  }

  func loadNavigationRequest(_ request: URLRequest) {
    guard let url = request.url, isAllowedMainPageURL(url) else {
      presentError(NSError(domain: CRBrowserSiteStore.errorDomain,
                           code: CRBrowserSiteErrorCode.invalidURL.rawValue,
                           userInfo: [NSLocalizedDescriptionKey:
                            "ComicReader can open only HTTP and HTTPS website pages."]))
      return
    }
    errorView.isHidden = true
    currentDocumentIsPDF = false
    homeTableView.isHidden = true
    webView.isHidden = false
    navigationItem.titleView = addressField
    addressField.text = url.absoluteString
    webView.load(request)
    updateControls()
  }

  func handlePopupNavigation(_ navigationAction: WKNavigationAction) {
    let identifier = ObjectIdentifier(navigationAction)
    guard handledPopupActions.insert(identifier).inserted else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.handledPopupActions.remove(identifier)
    }
    guard let url = navigationAction.request.url, isAllowedMainPageURL(url) else {
      if let url = navigationAction.request.url {
        presentUnsupportedPageAlert(url: url)
      }
      return
    }
    loadNavigationRequest(navigationAction.request)
  }

  func showHome() {
    webView?.stopLoading()
    webView?.isHidden = true
    errorView.isHidden = true
    homeTableView.isHidden = false
    progressView.isHidden = true
    currentDocumentIsPDF = false
    navigationItem.titleView = nil
    addressField.text = nil
    homeAddressField.text = nil
    reloadSavedSites(presentErrors: false)
    updateControls()
  }

  func showPageError(_ error: Error) {
    let nsError = error as NSError
    // WebKit reports a frame interruption when our navigation policy cancels
    // a download or converts a response into WKDownload. The website remains
    // usable; covering it with an error would block the next download attempt.
    let policyInterrupted = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
    guard !policyInterrupted,
          nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else {
      progressView.isHidden = true
      updateControls()
      return
    }
    progressView.isHidden = true
    homeTableView.isHidden = true
    webView.isHidden = false
    if nsError.domain == NSURLErrorDomain,
       nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
      errorLabel.text = "This website requires a secure HTTPS address. ComicReader permits HTTP only for local-network sites."
    } else {
      errorLabel.text = nsError.localizedDescription
    }
    errorView.isHidden = false
    UIAccessibility.post(notification: .screenChanged, argument: errorLabel)
    updateControls()
  }

  func updateControls() {
    guard isViewLoaded else { return }
    backButton.isEnabled = webView?.canGoBack == true
    forwardButton.isEnabled = webView?.canGoForward == true
    let isLoading = webView?.isLoading == true
    reloadButton.setImage(UIImage(systemName: isLoading ? "xmark" : "arrow.clockwise"), for: .normal)
    reloadButton.accessibilityLabel = isLoading ? "Stop Loading" : "Reload"

    let activeCount = latestEntries.filter { !$0.isTerminal }.count
    downloadsButton.accessibilityValue = activeCount == 0 ? "No active downloads" :
      "\(activeCount) active \(activeCount == 1 ? "download" : "downloads")"
    downloadsButton.tintColor = activeCount > 0 ? .systemBlue : nil
    moreItem.menu = makeMoreMenu()
    navigationItem.prompt = isPrivateBrowsing ? "Private Browsing" : nil
    addressField.accessibilityHint = isPrivateBrowsing
      ? "Pages and sign-ins from this private session are discarded when it closes."
      : nil
  }

  func reloadSavedSites(presentErrors: Bool) {
    do {
      savedSites = try siteStore.sites()
      lastVisitedURL = try siteStore.lastVisitedURL()
      if let host = lastVisitedURL?.host, !isPrivateBrowsing {
        continueButton.setTitle("Continue at \(host)", for: .normal)
        continueButton.isHidden = false
      } else {
        continueButton.isHidden = true
      }
      privateNoticeLabel.isHidden = !isPrivateBrowsing
      homeTableView.reloadData()
      updateHomeHeaderHeight()
    } catch {
      savedSites = []
      lastVisitedURL = nil
      homeTableView.reloadData()
      if presentErrors {
        presentError(error)
      }
    }
  }

  func isAllowedMainPageURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil else {
      return false
    }
    return true
  }

  func makeMoreMenu() -> UIMenu {
    let hasPage = webView?.url.map(isAllowedMainPageURL) == true && homeTableView.isHidden
    let canSave = hasPage && !isPrivateBrowsing
    let currentIsPDF = currentDocumentIsPDF || webView?.url?.pathExtension.lowercased() == "pdf"

    let home = UIAction(title: "Browser Home", image: UIImage(systemName: "house")) { [weak self] _ in
      self?.showHome()
    }
    let save = UIAction(title: "Save This Website",
                        image: UIImage(systemName: "bookmark"),
                        attributes: canSave ? [] : [.disabled]) { [weak self] _ in
      self?.promptToSaveCurrentSite()
    }
    let manage = UIAction(title: "Manage Saved Websites",
                          image: UIImage(systemName: "list.bullet"),
                          attributes: (!isPrivateBrowsing && !savedSites.isEmpty) ? [] : [.disabled]) { [weak self] _ in
      guard let self else { return }
      self.showHome()
      self.homeTableView.setEditing(true, animated: true)
    }
    let clearSaved = UIAction(title: "Clear Saved Websites",
                              image: UIImage(systemName: "bookmark.slash"),
                              attributes: (!isPrivateBrowsing && !savedSites.isEmpty) ? [.destructive] : [.disabled]) { [weak self] _ in
      self?.confirmClearSavedSites()
    }

    let importPDF = UIAction(title: "Import Current Comic",
                             image: UIImage(systemName: "square.and.arrow.down"),
                             attributes: (hasPage && currentIsPDF) ? [] : [.disabled]) { [weak self] _ in
      self?.importCurrentComic()
    }
    let safari = UIAction(title: "Open in Safari",
                          image: UIImage(systemName: "safari"),
                          attributes: hasPage ? [] : [.disabled]) { [weak self] _ in
      self?.openCurrentPageInSafari()
    }

    let clearSite = UIAction(title: "Clear Data for This Website",
                             image: UIImage(systemName: "person.crop.circle.badge.xmark"),
                             attributes: hasPage ? [.destructive] : [.disabled]) { [weak self] _ in
      self?.confirmClearCurrentSiteData()
    }
    let clearAll = UIAction(title: isPrivateBrowsing ? "Clear Private Session Data" : "Clear All Website Data",
                            image: UIImage(systemName: "trash"),
                            attributes: [.destructive]) { [weak self] _ in
      self?.confirmClearAllWebsiteData()
    }

    let privateAction = UIAction(title: isPrivateBrowsing ? "Return to Standard Browsing" : "New Private Session",
                                 image: UIImage(systemName: isPrivateBrowsing ? "globe" : "hand.raised"),
                                 state: isPrivateBrowsing ? .on : .off) { [weak self] _ in
      self?.confirmSwitchBrowsingMode()
    }

    return UIMenu(children: [
      UIMenu(options: .displayInline, children: [home, save, manage, clearSaved]),
      UIMenu(options: .displayInline, children: [importPDF, safari]),
      UIMenu(options: .displayInline, children: [clearSite, clearAll]),
      UIMenu(options: .displayInline, children: [privateAction])
    ])
  }

  func promptToSaveCurrentSite() {
    guard !isPrivateBrowsing, let url = webView.url, isAllowedMainPageURL(url) else { return }
    let suggestedName = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let alert = UIAlertController(title: "Save Website",
                                  message: "Only the page address without its query or fragment will be saved.",
                                  preferredStyle: .alert)
    alert.addTextField { field in
      field.text = (suggestedName?.isEmpty == false ? suggestedName : url.host) ?? "Website"
      field.placeholder = "Website name"
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
      guard let self else { return }
      do {
        _ = try self.siteStore.saveSite(name: alert?.textFields?.first?.text ?? "", url: url)
        self.reloadSavedSites(presentErrors: true)
      } catch {
        self.presentError(error)
      }
    })
    present(alert, animated: true)
  }

  func renameSavedSite(_ site: CRBrowserSite) {
    let alert = UIAlertController(title: "Rename Website", message: site.url.host,
                                  preferredStyle: .alert)
    alert.addTextField { field in
      field.text = site.name
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
      guard let self else { return }
      do {
        _ = try self.siteStore.renameSite(identifier: site.identifier,
                                          name: alert?.textFields?.first?.text ?? "")
        self.reloadSavedSites(presentErrors: true)
      } catch {
        self.presentError(error)
      }
    })
    present(alert, animated: true)
  }

  func confirmClearSavedSites() {
    let alert = UIAlertController(title: "Clear Saved Websites?",
                                  message: "This removes every saved website shortcut. Website sign-ins and data are not changed.",
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
      guard let self else { return }
      do {
        try self.siteStore.deleteAllSites()
        self.reloadSavedSites(presentErrors: true)
      } catch {
        self.presentError(error)
      }
    })
    present(alert, animated: true)
  }

  func confirmSwitchBrowsingMode() {
    let enteringPrivate = !isPrivateBrowsing
    let title = enteringPrivate ? "Start Private Session?" : "End Private Session?"
    let message = enteringPrivate
      ? "Private pages, sign-ins, saved sites, and download details are discarded when the private session closes. Standard website data and downloads continue separately."
      : "Private downloads will be cancelled and private website data will be discarded. Comics already imported remain in your library."
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: enteringPrivate ? "Start Private" : "End Private",
                                  style: enteringPrivate ? .default : .destructive) { [weak self] _ in
      self?.switchBrowsingMode(privateBrowsing: enteringPrivate)
    })
    present(alert, animated: true)
  }

  func switchBrowsingMode(privateBrowsing: Bool) {
    guard privateBrowsing != isPrivateBrowsing else { return }
    cancelPendingWebKitInteractions()
    if isPrivateBrowsing {
      tearDownPrivateSessionIfNeeded()
    }
    session?.removeObserver(self)
    isPrivateBrowsing = privateBrowsing
    didTearDownPrivateSession = false
    latestEntries = []
    siteStore = privateBrowsing ? CRBrowserSiteStore(privateBrowsing: true) : .sharedStore
    installSession(privateBrowsing: privateBrowsing)
    replaceWebView(privateBrowsing: privateBrowsing)
    reloadSavedSites(presentErrors: false)
    updateControls()
    UIAccessibility.post(notification: .screenChanged, argument: homeTitleLabel)
  }

  func tearDownPrivateSessionIfNeeded() {
    guard isPrivateBrowsing, !didTearDownPrivateSession else { return }
    didTearDownPrivateSession = true
    cancelPendingWebKitInteractions()
    webView?.stopLoading()
    let dataStore = webView?.configuration.websiteDataStore
    dataStore?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                          modifiedSince: .distantPast,
                          completionHandler: {})
    session?.cancelAndPurgePrivateDownloads()
    session?.removeObserver(self)
    session = nil
  }

  func openCurrentPageInSafari() {
    guard let url = webView.url, isAllowedMainPageURL(url) else { return }
    UIApplication.shared.open(url)
  }

  func openImportedComic(_ url: URL) {
    guard let openComicHandler else { return }
    openComicHandler(url)
  }

  func showPlus() {
    navigationController?.pushViewController(CRPlusViewController(), animated: true)
  }

  func presentPlusRequired() {
    let alert = UIAlertController(
      title: "ComicReader Plus",
      message: "Web browsing and sign-ins are free. Downloading and importing a comic into the library requires ComicReader Plus.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
    alert.addAction(UIAlertAction(title: "View Plus", style: .default) { [weak self] _ in
      self?.showPlus()
    })
    present(alert, animated: true)
  }

  func presentError(_ error: Error) {
    presentError(error, attempt: 0)
  }

  private func presentError(_ error: Error, attempt: Int) {
    guard isViewLoaded, view.window != nil else { return }
    if presentedViewController != nil, attempt < 10 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.presentError(error, attempt: attempt + 1)
      }
      return
    }
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: "Couldn’t Complete That",
                                  message: (error as NSError).localizedDescription,
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  func cancelPendingWebKitInteractions() {
    let destinationRequest = pendingDestinationRequest
    pendingDestinationRequest = nil
    destinationRequest?.resolve(.cancelled)
    pendingDestinationByConversion.removeAll()
    handledPopupActions.removeAll()
    let cancelJavaScriptDialog = pendingJavaScriptDialogCancellation
    pendingJavaScriptDialogCancellation = nil
    cancelJavaScriptDialog?()
  }
}

private extension CRWebBrowserViewController {
  private func requestDownloadAuthorization(for conversionKey: DownloadConversionKey,
                                            completion: @escaping (Bool) -> Void) {
    requestDestinationSelection { [weak self] selection in
      guard let self else {
        completion(false)
        return
      }
      switch selection {
      case .cancelled:
        completion(false)
      case .selected:
        self.pendingDestinationByConversion[conversionKey] = selection
        completion(true)
      }
    }
  }

  private func requestDestinationSelection(completion: @escaping (DestinationSelection) -> Void) {
    guard plusStore.isUnlocked else {
      presentPlusRequired()
      completion(.cancelled)
      return
    }
    guard session != nil else {
      presentError(sessionStartupError ?? NSError(domain: CRBrowserSiteStore.errorDomain,
                                                   code: CRBrowserSiteErrorCode.storageUnavailable.rawValue,
                                                   userInfo: [NSLocalizedDescriptionKey:
                                                    "Downloads are unavailable for this library."]))
      completion(.cancelled)
      return
    }
    guard pendingDestinationRequest == nil else {
      completion(.cancelled)
      return
    }

    pendingDestinationRequest = PendingDestinationRequest(completion: completion)
    chooseDownloadDestination()
  }

  private func resolveDestinationRequest(_ selection: DestinationSelection) {
    guard let request = pendingDestinationRequest else { return }
    pendingDestinationRequest = nil
    request.resolve(selection)
  }

  private func chooseDownloadDestination() {
    guard let manager = session?.manager else {
      resolveDestinationRequest(.cancelled)
      return
    }

    let collections: [String]
    do {
      collections = try manager.availableCollections()
    } catch {
      resolveDestinationRequest(.cancelled)
      presentError(error)
      return
    }

    let alert = UIAlertController(title: "Choose Library Destination",
                                  message: "Select where this comic should be imported.",
                                  preferredStyle: .actionSheet)
    let rootTitle = selectedDestinationCollection == nil ? "Library Root  ✓" : "Library Root"
    alert.addAction(UIAlertAction(title: rootTitle, style: .default) { [weak self] _ in
      self?.selectedDestinationCollection = nil
      self?.resolveDestinationRequest(.selected(nil))
    })
    for collection in collections {
      let isSelected = collection == selectedDestinationCollection
      alert.addAction(UIAlertAction(title: collection + (isSelected ? "  ✓" : ""),
                                    style: .default) { [weak self] _ in
        self?.selectedDestinationCollection = collection
        self?.resolveDestinationRequest(.selected(collection))
      })
    }
    alert.addAction(UIAlertAction(title: "New Collection…",
                                  style: .default) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.promptNewCollection()
      }
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
      self?.resolveDestinationRequest(.cancelled)
    })
    if let popover = alert.popoverPresentationController {
      popover.sourceView = downloadsButton
      popover.sourceRect = downloadsButton.bounds
    }
    present(alert, animated: true)
  }

  private func promptNewCollection() {
    let alert = UIAlertController(title: "New Collection",
                                  message: "Create a folder directly inside your ComicReader library.",
                                  preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "Collection name"
      field.clearButtonMode = .whileEditing
      field.autocapitalizationType = .words
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
      self?.resolveDestinationRequest(.cancelled)
    })
    alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
      guard let self else { return }
      guard let manager = self.session?.manager else {
        self.resolveDestinationRequest(.cancelled)
        return
      }
      do {
        let name = try manager.createCollection(named: alert?.textFields?.first?.text ?? "")
        self.selectedDestinationCollection = name
        self.resolveDestinationRequest(.selected(name))
      } catch {
        self.resolveDestinationRequest(.cancelled)
        self.presentError(error)
      }
    })
    present(alert, animated: true)
  }

  func importCurrentComic() {
    guard let url = webView.url, isAllowedMainPageURL(url) else { return }
    requestDestinationSelection { [weak self] selection in
      guard let self, case .selected = selection else { return }
      self.webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
        guard let self else {
          download.cancel { _ in }
          return
        }
        self.adopt(download: download, selection: selection)
      }
    }
  }

  private func adopt(download: WKDownload, conversionKey: DownloadConversionKey) {
    let selection = pendingDestinationByConversion.removeValue(forKey: conversionKey)
    adopt(download: download, selection: selection)
  }

  private func adopt(download: WKDownload, selection: DestinationSelection?) {
    guard case .selected(let collection) = selection, let manager = session?.manager else {
      download.cancel { _ in }
      return
    }
    do {
      try manager.adopt(download: download, destinationCollection: collection)
      showDownloads()
    } catch {
      download.cancel { _ in }
      if let importError = error as? CRWebImportError,
         case .plusRequired = importError {
        presentPlusRequired()
      } else {
        presentError(error)
      }
    }
  }

  func confirmClearCurrentSiteData() {
    guard let host = webView.url?.host else { return }
    let alert = UIAlertController(title: "Clear Data for \(host)?",
                                  message: "Cookies, caches, and other data for this website will be removed. You will be signed out.",
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Clear and Sign Out", style: .destructive) { [weak self] _ in
      self?.clearWebsiteData(forHost: host)
    })
    present(alert, animated: true)
  }

  func confirmClearAllWebsiteData() {
    let title = isPrivateBrowsing ? "Clear Private Session Data?" : "Clear All Website Data?"
    let message = isPrivateBrowsing
      ? "All website data in this private session will be removed and every private website will be signed out."
      : "All cookies, caches, and other website data will be removed. Every website in ComicReader will be signed out."
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Clear and Sign Out", style: .destructive) { [weak self] _ in
      self?.clearAllWebsiteData()
    })
    present(alert, animated: true)
  }

  func clearWebsiteData(forHost host: String) {
    let dataStore = webView.configuration.websiteDataStore
    let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
    dataStore.fetchDataRecords(ofTypes: dataTypes) { [weak self] records in
      let normalizedHost = host.lowercased()
      let matching = records.filter { record in
        let domain = record.displayName.lowercased()
        return domain == normalizedHost || normalizedHost.hasSuffix(".\(domain)") ||
          domain.hasSuffix(".\(normalizedHost)")
      }
      dataStore.removeData(ofTypes: dataTypes, for: matching) { [weak self] in
        DispatchQueue.main.async {
          self?.webView.reloadFromOrigin()
          UIAccessibility.post(notification: .announcement,
                               argument: "Website data cleared. The website has been signed out.")
        }
      }
    }
  }

  func clearAllWebsiteData() {
    let dataStore = webView.configuration.websiteDataStore
    dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) { [weak self] in
      DispatchQueue.main.async {
        self?.showHome()
        UIAccessibility.post(notification: .announcement,
                             argument: "Website data cleared. Websites have been signed out.")
      }
    }
  }
}

extension CRWebBrowserViewController: UITableViewDataSource, UITableViewDelegate {
  public func numberOfSections(in tableView: UITableView) -> Int {
    1
  }

  public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    savedSites.count
  }

  public func tableView(_ tableView: UITableView,
                        titleForHeaderInSection section: Int) -> String? {
    isPrivateBrowsing ? nil : "Saved Websites"
  }

  public func tableView(_ tableView: UITableView,
                        titleForFooterInSection section: Int) -> String? {
    if isPrivateBrowsing {
      return "Saved websites are unavailable in private browsing."
    }
    if savedSites.isEmpty {
      return "Open a website, then use the More menu to save a shortcut. Saved addresses never include query or fragment values."
    }
    return "Saved addresses never include query or fragment values."
  }

  public func tableView(_ tableView: UITableView,
                        cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let identifier = "BrowserSite"
    let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ??
      UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
    let site = savedSites[indexPath.row]
    cell.textLabel?.text = site.name
    cell.textLabel?.font = .preferredFont(forTextStyle: .body)
    cell.textLabel?.adjustsFontForContentSizeCategory = true
    cell.detailTextLabel?.text = site.url.absoluteString
    cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
    cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.accessoryType = .disclosureIndicator
    cell.accessibilityIdentifier = "library.browser.savedSite"
    return cell
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    loadPage(savedSites[indexPath.row].url)
  }

  public func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    !isPrivateBrowsing
  }

  public func tableView(_ tableView: UITableView,
                        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    guard !isPrivateBrowsing else { return nil }
    let site = savedSites[indexPath.row]
    let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
      guard let self else {
        completion(false)
        return
      }
      do {
        try self.siteStore.deleteSite(identifier: site.identifier)
        self.reloadSavedSites(presentErrors: true)
        completion(true)
      } catch {
        self.presentError(error)
        completion(false)
      }
    }
    delete.image = UIImage(systemName: "trash")
    let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, completion in
      self?.renameSavedSite(site)
      completion(true)
    }
    rename.image = UIImage(systemName: "pencil")
    let configuration = UISwipeActionsConfiguration(actions: [delete, rename])
    configuration.performsFirstActionWithFullSwipe = false
    return configuration
  }
}

extension CRWebBrowserViewController: UITextFieldDelegate {
  public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    navigate(toUserInput: textField.text ?? "")
    return true
  }
}

extension CRWebBrowserViewController: WKNavigationDelegate {
  public func webView(_ webView: WKWebView,
                      decidePolicyFor navigationAction: WKNavigationAction,
                      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }

    if navigationAction.targetFrame?.isMainFrame != false && !isAllowedMainPageURL(url) {
      // about:blank is WebKit's harmless initial document and is never exposed
      // as a user-entered main page.
      if url.absoluteString == "about:blank" {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
        presentUnsupportedPageAlert(url: url)
      }
      return
    }

    if navigationAction.shouldPerformDownload {
      guard isAllowedMainPageURL(url) else {
        decisionHandler(.cancel)
        return
      }
      let conversionKey = DownloadConversionKey.navigationAction(ObjectIdentifier(navigationAction))
      requestDownloadAuthorization(for: conversionKey) { authorized in
        decisionHandler(authorized ? .download : .cancel)
      }
      return
    }

    if navigationAction.targetFrame == nil {
      decisionHandler(.cancel)
      handlePopupNavigation(navigationAction)
      return
    }
    decisionHandler(.allow)
  }

  public func webView(_ webView: WKWebView,
                      decidePolicyFor navigationResponse: WKNavigationResponse,
                      decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    guard let url = navigationResponse.response.url else {
      decisionHandler(navigationResponse.isForMainFrame ? .cancel : .allow)
      return
    }

    let response = navigationResponse.response
    let mimeType = response.mimeType?.lowercased() ?? ""
    let suggestedExtension = (response.suggestedFilename as NSString?)?.pathExtension.lowercased() ?? ""
    let urlExtension = url.pathExtension.lowercased()
    let supportedExtensions: Set<String> = ["cbz", "zip", "cbr", "rar", "pdf"]
    let isSupportedFile = supportedExtensions.contains(suggestedExtension) ||
      supportedExtensions.contains(urlExtension) || mimeType == "application/pdf"
    let contentDisposition = (response as? HTTPURLResponse)?
      .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
    let isAttachment = contentDisposition.contains("attachment")

    let shouldDownload = isSupportedFile && (isAttachment || !navigationResponse.canShowMIMEType)
    if shouldDownload {
      guard isAllowedMainPageURL(url) else {
        decisionHandler(.cancel)
        return
      }
      let conversionKey = DownloadConversionKey.navigationResponse(ObjectIdentifier(navigationResponse))
      requestDownloadAuthorization(for: conversionKey) { authorized in
        decisionHandler(authorized ? .download : .cancel)
      }
      return
    }

    guard navigationResponse.isForMainFrame else {
      decisionHandler(.allow)
      return
    }
    guard isAllowedMainPageURL(url) else {
      decisionHandler(.cancel)
      return
    }

    guard navigationResponse.canShowMIMEType else {
      decisionHandler(.cancel)
      presentError(NSError(domain: CRBrowserSiteStore.errorDomain,
                           code: CRBrowserSiteErrorCode.invalidURL.rawValue,
                           userInfo: [NSLocalizedDescriptionKey:
                            "This file type cannot be displayed or imported. ComicReader supports CBZ, CBR, and PDF comics."]))
      return
    }
    // PDFs that WebKit can display stay in the browser. The More menu exposes
    // an explicit Import Current Comic action rather than importing on sight.
    currentDocumentIsPDF = mimeType == "application/pdf" || urlExtension == "pdf"
    decisionHandler(.allow)
  }

  public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    errorView.isHidden = true
    currentDocumentIsPDF = false
    progressView.progress = 0
    progressView.isHidden = false
    updateControls()
  }

  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    if let url = webView.url, isAllowedMainPageURL(url) {
      addressField.text = url.absoluteString
    }
    homeTableView.isHidden = true
    errorView.isHidden = true
    webView.isHidden = false
    updateControls()
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    progressView.isHidden = true
    if let url = webView.url, isAllowedMainPageURL(url) {
      addressField.text = url.absoluteString
      if !isPrivateBrowsing {
        do {
          try siteStore.recordLastVisitedURL(url)
          lastVisitedURL = try siteStore.lastVisitedURL()
        } catch {
          // A persistence error must not disrupt a successful web navigation.
          // It will be surfaced if the user next manages saved sites.
        }
      }
    }
    updateControls()
  }

  public func webView(_ webView: WKWebView,
                      didFailProvisionalNavigation navigation: WKNavigation!,
                      withError error: Error) {
    showPageError(error)
  }

  public func webView(_ webView: WKWebView,
                      didFail navigation: WKNavigation!,
                      withError error: Error) {
    showPageError(error)
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    showPageError(NSError(domain: WKError.errorDomain,
                          code: WKError.webContentProcessTerminated.rawValue,
                          userInfo: [NSLocalizedDescriptionKey:
                           "This website stopped responding. You can reload it safely."]))
  }

  @available(iOS 14.5, macCatalyst 14.5, *)
  public func webView(_ webView: WKWebView,
                      navigationAction: WKNavigationAction,
                      didBecome download: WKDownload) {
    adopt(download: download,
          conversionKey: .navigationAction(ObjectIdentifier(navigationAction)))
  }

  @available(iOS 14.5, macCatalyst 14.5, *)
  public func webView(_ webView: WKWebView,
                      navigationResponse: WKNavigationResponse,
                      didBecome download: WKDownload) {
    adopt(download: download,
          conversionKey: .navigationResponse(ObjectIdentifier(navigationResponse)))
  }

  public func webView(_ webView: WKWebView,
                      didReceive challenge: URLAuthenticationChallenge,
                      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    // Let WebKit and the OS manage website credentials. ComicReader never
    // inspects, copies, or separately stores them.
    completionHandler(.performDefaultHandling, nil)
  }

  private func presentUnsupportedPageAlert(url: URL) {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(
      title: "Open This Page in Safari?",
      message: "ComicReader’s embedded browser opens HTTP and HTTPS pages only. Some sign-in providers also require Safari.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    let safariURL = isAllowedMainPageURL(url) ? url : webView.url.flatMap {
      isAllowedMainPageURL($0) ? $0 : nil
    }
    if let safariURL {
      alert.addAction(UIAlertAction(title: "Open in Safari", style: .default) { _ in
        UIApplication.shared.open(safariURL)
      })
    }
    present(alert, animated: true)
  }
}

extension CRWebBrowserViewController: WKUIDelegate {
  public func webView(_ webView: WKWebView,
                      createWebViewWith configuration: WKWebViewConfiguration,
                      for navigationAction: WKNavigationAction,
                      windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard navigationAction.targetFrame == nil else {
      return nil
    }
    handlePopupNavigation(navigationAction)
    return nil
  }

  public func webViewDidClose(_ webView: WKWebView) {
    showHome()
  }

  public func webView(_ webView: WKWebView,
                      runJavaScriptAlertPanelWithMessage message: String,
                      initiatedByFrame frame: WKFrameInfo,
                      completionHandler: @escaping () -> Void) {
    guard beginJavaScriptDialog(cancel: completionHandler) else {
      completionHandler()
      return
    }
    let alert = UIAlertController(title: javaScriptDialogTitle(frame: frame, webView: webView),
                                  message: safeJavaScriptMessage(message),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
      guard let self else {
        completionHandler()
        return
      }
      self.completeJavaScriptDialog(completionHandler)
    })
    present(alert, animated: true)
  }

  public func webView(_ webView: WKWebView,
                      runJavaScriptConfirmPanelWithMessage message: String,
                      initiatedByFrame frame: WKFrameInfo,
                      completionHandler: @escaping (Bool) -> Void) {
    guard beginJavaScriptDialog(cancel: { completionHandler(false) }) else {
      completionHandler(false)
      return
    }
    let alert = UIAlertController(title: javaScriptDialogTitle(frame: frame, webView: webView),
                                  message: safeJavaScriptMessage(message),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
      guard let self else {
        completionHandler(false)
        return
      }
      self.completeJavaScriptDialog { completionHandler(false) }
    })
    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
      guard let self else {
        completionHandler(false)
        return
      }
      self.completeJavaScriptDialog { completionHandler(true) }
    })
    present(alert, animated: true)
  }

  public func webView(_ webView: WKWebView,
                      runJavaScriptTextInputPanelWithPrompt prompt: String,
                      defaultText: String?,
                      initiatedByFrame frame: WKFrameInfo,
                      completionHandler: @escaping (String?) -> Void) {
    guard beginJavaScriptDialog(cancel: { completionHandler(nil) }) else {
      completionHandler(nil)
      return
    }
    let alert = UIAlertController(title: javaScriptDialogTitle(frame: frame, webView: webView),
                                  message: safeJavaScriptMessage(prompt),
                                  preferredStyle: .alert)
    alert.addTextField { field in
      field.text = defaultText
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
      guard let self else {
        completionHandler(nil)
        return
      }
      self.completeJavaScriptDialog { completionHandler(nil) }
    })
    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
      guard let self else {
        completionHandler(nil)
        return
      }
      let value = alert?.textFields?.first?.text
      self.completeJavaScriptDialog { completionHandler(value) }
    })
    present(alert, animated: true)
  }

  private func safeJavaScriptMessage(_ message: String) -> String {
    let limit = 1_000
    guard message.count > limit else { return message }
    return String(message.prefix(limit)) + "…"
  }

  private func javaScriptDialogTitle(frame: WKFrameInfo, webView: WKWebView) -> String {
    if frame.isMainFrame {
      return webView.url?.host ?? "Website"
    }
    let origin = frame.securityOrigin
    let host = origin.host.isEmpty ? "unknown origin" : origin.host
    let scheme = origin.protocol.isEmpty ? nil : origin.protocol
    var originDescription = scheme.map { "\($0)://\(host)" } ?? host
    let usesDefaultPort = (scheme == "https" && origin.port == 443) ||
      (scheme == "http" && origin.port == 80)
    if origin.port != 0 && !usesDefaultPort {
      originDescription += ":\(origin.port)"
    }
    return "Embedded content from \(originDescription)"
  }

  private func beginJavaScriptDialog(cancel: @escaping () -> Void) -> Bool {
    guard presentedViewController == nil,
          pendingJavaScriptDialogCancellation == nil else { return false }
    pendingJavaScriptDialogCancellation = cancel
    return true
  }

  private func completeJavaScriptDialog(_ completion: () -> Void) {
    guard pendingJavaScriptDialogCancellation != nil else { return }
    pendingJavaScriptDialogCancellation = nil
    completion()
  }
}

extension CRWebBrowserViewController: CRWebBrowserSessionObserver {
  fileprivate func webBrowserSession(_ session: CRWebBrowserSession,
                                      didUpdate entries: [CRWebDownloadEntry]) {
    guard session === self.session else { return }
    latestEntries = entries
    updateControls()
  }

  fileprivate func webBrowserSession(_ session: CRWebBrowserSession, didImport url: URL) {
    guard session === self.session else { return }
    UIAccessibility.post(notification: .announcement,
                         argument: "\(url.deletingPathExtension().lastPathComponent) was added to the library.")
  }
}

@MainActor
private final class CRWebDownloadCell: UITableViewCell {
  private let titleLabel = UILabel()
  private let detailLabel = UILabel()
  private let progressView = UIProgressView(progressViewStyle: .default)

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)

    titleLabel.font = .preferredFont(forTextStyle: .body)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.numberOfLines = 2
    detailLabel.font = .preferredFont(forTextStyle: .caption1)
    detailLabel.adjustsFontForContentSizeCategory = true
    detailLabel.textColor = .secondaryLabel
    detailLabel.numberOfLines = 3

    let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, progressView])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 5
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(entry: CRWebDownloadEntry) {
    titleLabel.text = entry.displayName
    let destination = entry.destinationCollection ?? "Library Root"
    let status: String
    let symbolName: String
    switch entry.state {
    case .downloading:
      status = "Downloading \(Int((entry.progress * 100).rounded()))%"
      symbolName = "arrow.down.circle"
    case .validating:
      status = "Checking comic"
      symbolName = "checkmark.shield"
    case .importing:
      status = "Adding to library"
      symbolName = "square.and.arrow.down"
    case .completed:
      status = entry.pageCount.map { "Imported • \($0) \($0 == 1 ? "page" : "pages")" } ?? "Imported"
      symbolName = "checkmark.circle.fill"
    case .duplicate:
      status = "Already in library"
      symbolName = "doc.on.doc"
    case .failed:
      status = entry.errorDescription ?? "Import failed"
      symbolName = "exclamationmark.circle"
    case .cancelled:
      status = "Cancelled"
      symbolName = "xmark.circle"
    }
    detailLabel.text = "\(status) • \(destination)"
    progressView.isHidden = entry.state != .downloading
    progressView.progress = Float(max(0, min(1, entry.progress)))
    accessoryView = UIImageView(image: UIImage(systemName: symbolName))
    accessoryView?.tintColor = entry.state == .failed ? .systemRed : .secondaryLabel
    accessibilityLabel = entry.displayName
    accessibilityValue = "\(status), \(destination)"
    accessibilityHint = entry.importedURL != nil
      ? "Double tap to open this comic."
      : (entry.canRetry ? "Double tap to retry." : nil)
  }
}

@MainActor
private final class CRWebDownloadsViewController: UITableViewController,
                                                          CRWebBrowserSessionObserver {
  private let session: CRWebBrowserSession
  private weak var webView: WKWebView?
  private let openHandler: (URL) -> Void
  private let plusHandler: () -> Void
  private var entries: [CRWebDownloadEntry] = []

  init(session: CRWebBrowserSession,
       webView: WKWebView,
       openHandler: @escaping (URL) -> Void,
       plusHandler: @escaping () -> Void) {
    self.session = session
    self.webView = webView
    self.openHandler = openHandler
    self.plusHandler = plusHandler
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Downloads"
    view.accessibilityIdentifier = "library.browser.downloads"
    let browserButton = UIBarButtonItem(title: "Browser",
                                        style: .plain,
                                        target: self,
                                        action: #selector(returnToBrowser))
    browserButton.image = UIImage(systemName: "chevron.backward")
    browserButton.accessibilityIdentifier = "library.browser.downloads.back"
    navigationItem.leftBarButtonItem = browserButton
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 84
    tableView.register(CRWebDownloadCell.self, forCellReuseIdentifier: "WebDownload")
    updateEmptyState()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setToolbarHidden(true, animated: animated)
    session.addObserver(self)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if isMovingFromParent || navigationController?.isBeingDismissed == true {
      session.removeObserver(self)
    }
  }

  override func numberOfSections(in tableView: UITableView) -> Int {
    1
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    entries.count
  }

  override func tableView(_ tableView: UITableView,
                          titleForFooterInSection section: Int) -> String? {
    "You can close the standard browser while downloading, but keep ComicReader open until imports finish. Private downloads are cancelled when their private session closes. Imported comics remain available if Plus is no longer active."
  }

  override func tableView(_ tableView: UITableView,
                          cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "WebDownload", for: indexPath)
    guard let downloadCell = cell as? CRWebDownloadCell else { return cell }
    downloadCell.configure(entry: entries[indexPath.row])
    downloadCell.accessibilityIdentifier = "library.browser.download"
    return downloadCell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let entry = entries[indexPath.row]
    presentActions(for: entry, sourceView: tableView.cellForRow(at: indexPath))
  }

  override func tableView(_ tableView: UITableView,
                          trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    let entry = entries[indexPath.row]
    var actions: [UIContextualAction] = []

    if !entry.isTerminal {
      let cancel = UIContextualAction(style: .destructive, title: "Cancel") { [weak self] _, _, completion in
        self?.session.manager.cancel(id: entry.id)
        completion(true)
      }
      cancel.image = UIImage(systemName: "xmark")
      actions.append(cancel)
    }
    if entry.canRetry {
      let retry = UIContextualAction(style: .normal, title: "Retry") { [weak self] _, _, completion in
        self?.retry(entry)
        completion(true)
      }
      retry.image = UIImage(systemName: "arrow.clockwise")
      actions.append(retry)
    }
    if entry.isTerminal {
      let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
        self?.session.manager.remove(id: entry.id)
        completion(true)
      }
      remove.image = UIImage(systemName: "trash")
      actions.append(remove)
    }

    guard !actions.isEmpty else { return nil }
    let configuration = UISwipeActionsConfiguration(actions: actions)
    configuration.performsFirstActionWithFullSwipe = false
    return configuration
  }

  fileprivate func webBrowserSession(_ session: CRWebBrowserSession,
                                      didUpdate entries: [CRWebDownloadEntry]) {
    guard session === self.session else { return }
    self.entries = entries
    tableView.reloadData()
    updateEmptyState()
  }

  fileprivate func webBrowserSession(_ session: CRWebBrowserSession, didImport url: URL) {
    guard session === self.session else { return }
    UIAccessibility.post(notification: .announcement,
                         argument: "Import complete. Double tap to open the comic.")
  }

  private func retry(_ entry: CRWebDownloadEntry) {
    guard let webView else {
      presentError(CRWebImportError.retryUnavailable)
      return
    }
    do {
      try session.manager.retry(id: entry.id, in: webView)
    } catch let error as CRWebImportError {
      if case .plusRequired = error {
        presentPlusRequired()
      } else {
        presentError(error)
      }
    } catch {
      presentError(error)
    }
  }

  @objc private func returnToBrowser() {
    navigationController?.popViewController(animated: true)
  }

  private func presentActions(for entry: CRWebDownloadEntry, sourceView: UIView?) {
    let alert = UIAlertController(title: entry.displayName,
                                  message: downloadStatus(for: entry),
                                  preferredStyle: .actionSheet)
    if let url = session.manager.openableURL(for: entry.id) {
      alert.addAction(UIAlertAction(title: "Open Comic", style: .default) { [openHandler] _ in
        openHandler(url)
      })
    }
    if entry.canRetry {
      alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
        self?.retry(entry)
      })
    }
    if !entry.isTerminal {
      alert.addAction(UIAlertAction(title: "Cancel Download", style: .destructive) { [weak self] _ in
        self?.session.manager.cancel(id: entry.id)
      })
    }
    if entry.isTerminal {
      alert.addAction(UIAlertAction(title: "Remove from List", style: .destructive) { [weak self] _ in
        self?.session.manager.remove(id: entry.id)
      })
    }
    alert.addAction(UIAlertAction(title: "Close", style: .cancel))
    if let popover = alert.popoverPresentationController {
      popover.sourceView = sourceView ?? view
      popover.sourceRect = sourceView?.bounds ?? CGRect(x: view.bounds.midX,
                                                        y: view.bounds.midY,
                                                        width: 1,
                                                        height: 1)
    }
    present(alert, animated: true)
  }

  private func downloadStatus(for entry: CRWebDownloadEntry) -> String {
    switch entry.state {
    case .downloading: return "Downloading \(Int((entry.progress * 100).rounded()))%"
    case .validating: return "Checking comic"
    case .importing: return "Adding to library"
    case .completed: return "Imported"
    case .duplicate: return "Already in library"
    case .failed: return entry.errorDescription ?? "Import failed"
    case .cancelled: return "Cancelled"
    }
  }

  private func updateEmptyState() {
    if entries.isEmpty {
      let label = UILabel()
      label.text = "No Downloads\n\nDownload a CBZ, CBR, or PDF from a publisher’s website to add it to your library."
      label.font = .preferredFont(forTextStyle: .body)
      label.adjustsFontForContentSizeCategory = true
      label.textColor = .secondaryLabel
      label.textAlignment = .center
      label.numberOfLines = 0
      label.accessibilityIdentifier = "library.browser.downloads.empty"
      tableView.backgroundView = label
    } else {
      tableView.backgroundView = nil
    }
  }

  private func presentPlusRequired() {
    let alert = UIAlertController(title: "ComicReader Plus",
                                  message: "Retrying a web download requires ComicReader Plus. Imported comics remain available to open.",
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
    alert.addAction(UIAlertAction(title: "View Plus", style: .default) { [weak self] _ in
      self?.plusHandler()
    })
    present(alert, animated: true)
  }

  private func presentError(_ error: Error) {
    let alert = UIAlertController(title: "Download Error",
                                  message: error.localizedDescription,
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
