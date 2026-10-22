import UIKit

@objc(CRPageBookmarksViewControllerDelegate)
public protocol CRPageBookmarksViewControllerDelegate: AnyObject {
  @objc(pageBookmarksViewControllerDidRequestClose:)
  func pageBookmarksViewControllerDidRequestClose(_ viewController: CRPageBookmarksViewController)

  @objc(pageBookmarksViewController:didSelectPageIndex:)
  func pageBookmarksViewController(_ viewController: CRPageBookmarksViewController,
                                   didSelectPageIndex pageIndex: Int)
}

@objc(CRPageBookmarksViewController)
@MainActor
public final class CRPageBookmarksViewController: UITableViewController {
  @objc public weak var delegate: CRPageBookmarksViewControllerDelegate?

  private enum ContentState {
    case loading
    case loaded
    case failed(Error)
  }

  private let comicPath: String
  private let currentPageIndex: Int
  private let pageCount: Int
  private let bookmarkStore: CRPageBookmarkStore
  private let plusStore = CRPlusStore.sharedStore
  private let workQueue = DispatchQueue(label: "com.pabloclementeperez.ComicReader.PageBookmarks",
                                        qos: .userInitiated)

  private var comic: CRPageBookmarkComic?
  private var bookmarks: [CRPageBookmark] = []
  private var contentState: ContentState = .loading
  private var isMutating = false

  private let stateLabel: UILabel = {
    let label = UILabel()
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.numberOfLines = 0
    return label
  }()

  private let stateSpinner: UIActivityIndicatorView = {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.hidesWhenStopped = true
    return spinner
  }()

  private lazy var retryButton: UIButton = {
    let button = UIButton(type: .system)
    button.setTitle("Try Again", for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.accessibilityIdentifier = "reader.bookmarks.retry"
    button.addTarget(self, action: #selector(retryLoading), for: .touchUpInside)
    return button
  }()

  @objc(initWithComicPath:currentPageIndex:pageCount:)
  public init(comicPath: String, currentPageIndex: Int, pageCount: Int) {
    self.comicPath = comicPath
    self.currentPageIndex = currentPageIndex
    self.pageCount = pageCount
    bookmarkStore = .sharedStore
    super.init(style: .insetGrouped)
  }

  init(comicPath: String,
       currentPageIndex: Int,
       pageCount: Int,
       bookmarkStore: CRPageBookmarkStore) {
    self.comicPath = comicPath
    self.currentPageIndex = currentPageIndex
    self.pageCount = pageCount
    self.bookmarkStore = bookmarkStore
    super.init(style: .insetGrouped)
  }

  public required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  public override func viewDidLoad() {
    super.viewDidLoad()

    title = "Page Bookmarks"
    view.accessibilityIdentifier = "reader.bookmarks.list"
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 58
    tableView.cellLayoutMarginsFollowReadableWidth = true

    let doneButton = UIBarButtonItem(barButtonSystemItem: .done,
                                     target: self,
                                     action: #selector(done))
    doneButton.accessibilityIdentifier = "reader.bookmarks.done"
    navigationItem.leftBarButtonItem = doneButton

    let addButton = UIBarButtonItem(barButtonSystemItem: .add,
                                    target: self,
                                    action: #selector(addBookmark))
    addButton.accessibilityLabel = "Add bookmark for this page"
    addButton.accessibilityIdentifier = "reader.bookmarks.add"
    navigationItem.rightBarButtonItem = addButton

    configureStateBackground()
    updateContent()
    plusStore.start()
    loadBookmarks()
  }

  public override func numberOfSections(in tableView: UITableView) -> Int {
    1
  }

  public override func tableView(_ tableView: UITableView,
                                 numberOfRowsInSection section: Int) -> Int {
    bookmarks.count
  }

  public override func tableView(_ tableView: UITableView,
                                 titleForFooterInSection section: Int) -> String? {
    guard case .loaded = contentState else {
      return nil
    }
    return "Bookmarks are stored on this device. Saved bookmarks stay available to view and open if Plus is no longer active."
  }

  public override func tableView(_ tableView: UITableView,
                                 cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let reuseIdentifier = "PageBookmark"
    let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier) ??
      UITableViewCell(style: .default, reuseIdentifier: reuseIdentifier)
    let bookmark = bookmarks[indexPath.row]

    var configuration = cell.defaultContentConfiguration()
    configuration.text = bookmark.name
    configuration.secondaryText = "Page \(bookmark.pageIndex + 1)"
    configuration.image = UIImage(systemName: "bookmark.fill")
    configuration.imageProperties.tintColor = view.tintColor
    configuration.textProperties.numberOfLines = 2
    cell.contentConfiguration = configuration
    cell.accessoryView = actionsButton(for: bookmark)
    cell.accessibilityIdentifier = "reader.bookmarks.row"
    cell.accessibilityLabel = "\(bookmark.name), page \(bookmark.pageIndex + 1)"
    cell.accessibilityHint = "Jumps to this page."
    cell.selectionStyle = bookmark.pageIndex < pageCount ? .default : .none
    return cell
  }

  public override func tableView(_ tableView: UITableView,
                                 didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let bookmark = bookmarks[indexPath.row]
    guard bookmark.pageIndex >= 0, bookmark.pageIndex < pageCount else {
      presentError(NSError(domain: CRPageBookmarkStore.errorDomain,
                           code: CRPageBookmarkErrorCode.invalidPage.rawValue,
                           userInfo: [NSLocalizedDescriptionKey:
                             "That bookmarked page is no longer available in this comic."]))
      return
    }
    delegate?.pageBookmarksViewController(self, didSelectPageIndex: bookmark.pageIndex)
  }

  public override func tableView(_ tableView: UITableView,
                                 trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
    let bookmark = bookmarks[indexPath.row]
    let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, completion in
      completion(false)
      self?.requestRename(bookmark)
    }
    rename.backgroundColor = .systemBlue
    rename.image = UIImage(systemName: "pencil")

    let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
      completion(false)
      self?.requestDelete(bookmark)
    }
    delete.image = UIImage(systemName: "trash")
    return UISwipeActionsConfiguration(actions: [delete, rename])
  }

  private func configureStateBackground() {
    let container = UIView()
    let stack = UIStackView(arrangedSubviews: [stateSpinner, stateLabel, retryButton])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 12
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32)
    ])
    tableView.backgroundView = container
  }

  private func updateContent() {
    switch contentState {
    case .loading:
      stateSpinner.startAnimating()
      stateLabel.text = "Loading bookmarks…"
      retryButton.isHidden = true
      tableView.backgroundView?.isHidden = false

    case .loaded where bookmarks.isEmpty:
      stateSpinner.stopAnimating()
      stateLabel.text = "No bookmarks yet.\nSave a named bookmark for any page you want to revisit."
      retryButton.isHidden = true
      tableView.backgroundView?.isHidden = false

    case .loaded:
      stateSpinner.stopAnimating()
      stateLabel.text = nil
      retryButton.isHidden = true
      tableView.backgroundView?.isHidden = true

    case .failed(let error):
      stateSpinner.stopAnimating()
      stateLabel.text = error.localizedDescription
      retryButton.isHidden = false
      tableView.backgroundView?.isHidden = false
    }

    navigationItem.rightBarButtonItem?.isEnabled = comic != nil && pageCount > 0 && !isMutating
    tableView.reloadData()
  }

  @objc private func retryLoading() {
    loadBookmarks()
  }

  private func loadBookmarks() {
    guard !isMutating else {
      return
    }
    contentState = .loading
    bookmarks = []
    comic = nil
    updateContent()

    let path = comicPath
    let store = bookmarkStore
    workQueue.async { [weak self] in
      let result = Result { () -> (CRPageBookmarkComic, [CRPageBookmark]) in
        let comic = try store.resolveComic(atPath: path)
        return (comic, try store.bookmarks(for: comic))
      }
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let value):
          self.comic = value.0
          self.bookmarks = value.1
          self.contentState = .loaded
        case .failure(let error):
          self.contentState = .failed(error)
        }
        self.updateContent()
      }
    }
  }

  @objc private func addBookmark() {
    authorizeMutation { [weak self] in
      guard let self else { return }
      self.presentNamePrompt(title: "Add Bookmark",
                             message: "Save page \(self.currentPageIndex + 1) with a name.",
                             initialName: "Page \(self.currentPageIndex + 1)") { [weak self] name in
        guard let self else { return }
        self.authorizeMutation {
          self.performMutation { comic in
            _ = try self.bookmarkStore.addBookmark(for: comic,
                                                   name: name,
                                                   pageIndex: self.currentPageIndex,
                                                   pageCount: self.pageCount)
          }
        }
      }
    }
  }

  private func requestRename(_ bookmark: CRPageBookmark) {
    authorizeMutation { [weak self] in
      self?.presentNamePrompt(title: "Rename Bookmark",
                              message: "Page \(bookmark.pageIndex + 1)",
                              initialName: bookmark.name) { [weak self] name in
        guard let self else { return }
        self.authorizeMutation {
          self.performMutation { comic in
            _ = try self.bookmarkStore.renameBookmark(for: comic,
                                                      identifier: bookmark.identifier,
                                                      name: name)
          }
        }
      }
    }
  }

  private func requestDelete(_ bookmark: CRPageBookmark) {
    authorizeMutation { [weak self] in
      guard let self else { return }
      let alert = UIAlertController(title: "Delete Bookmark?",
                                    message: "“\(bookmark.name)” will be removed.",
                                    preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
        guard let self else { return }
        self.authorizeMutation {
          self.performMutation { comic in
            try self.bookmarkStore.deleteBookmark(for: comic,
                                                  identifier: bookmark.identifier)
          }
        }
      })
      self.present(alert, animated: true)
    }
  }

  private func presentNamePrompt(title: String,
                                 message: String,
                                 initialName: String,
                                 completion: @escaping (String) -> Void) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addTextField { textField in
      textField.text = initialName
      textField.placeholder = "Bookmark name"
      textField.clearButtonMode = .whileEditing
      textField.autocapitalizationType = .sentences
      textField.returnKeyType = .done
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
      completion(alert.textFields?.first?.text ?? "")
    })
    present(alert, animated: true) {
      alert.textFields?.first?.selectAll(nil)
    }
  }

  private func authorizeMutation(_ action: @escaping () -> Void) {
    guard plusStore.isUnlocked else {
      presentPlusRequired()
      return
    }
    action()
  }

  private func presentPlusRequired() {
    guard presentedViewController == nil else {
      return
    }
    let alert = UIAlertController(
      title: "ComicReader Plus",
      message: "Creating and editing page bookmarks is a ComicReader Plus feature. Saved bookmarks remain available to view and open.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
    alert.addAction(UIAlertAction(title: "View Plus", style: .default) { [weak self] _ in
      self?.presentPlus()
    })
    present(alert, animated: true)
  }

  private func presentPlus() {
    let plusViewController = CRPlusViewController()
    let navigationController = CRAdaptiveToolNavigationController(rootViewController: plusViewController)
    navigationController.modalPresentationStyle = .formSheet
    present(navigationController, animated: true)
  }

  private func performMutation(_ mutation: @escaping (CRPageBookmarkComic) throws -> Void) {
    guard !isMutating, let comic else {
      return
    }
    isMutating = true
    updateContent()

    let store = bookmarkStore
    workQueue.async { [weak self] in
      let result = Result { () -> [CRPageBookmark] in
        try mutation(comic)
        return try store.bookmarks(for: comic)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.isMutating = false
        switch result {
        case .success(let bookmarks):
          self.bookmarks = bookmarks
          self.contentState = .loaded
          self.updateContent()
        case .failure(let error):
          self.updateContent()
          self.presentError(error)
        }
      }
    }
  }

  private func actionsButton(for bookmark: CRPageBookmark) -> UIButton {
    let rename = UIAction(title: "Rename",
                          image: UIImage(systemName: "pencil")) { [weak self] _ in
      self?.requestRename(bookmark)
    }
    let delete = UIAction(title: "Delete",
                          image: UIImage(systemName: "trash"),
                          attributes: .destructive) { [weak self] _ in
      self?.requestDelete(bookmark)
    }
    let button = UIButton(type: .system)
    button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
    button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
    button.menu = UIMenu(children: [rename, delete])
    button.showsMenuAsPrimaryAction = true
    button.accessibilityLabel = "Actions for \(bookmark.name)"
    button.accessibilityIdentifier = "reader.bookmarks.actions"
    return button
  }

  private func presentError(_ error: Error) {
    if let presentedViewController {
      presentedViewController.dismiss(animated: false) { [weak self] in
        self?.presentError(error)
      }
      return
    }
    let alert = UIAlertController(title: "Bookmarks Could Not Be Updated",
                                  message: error.localizedDescription,
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  @objc private func done() {
    delegate?.pageBookmarksViewControllerDidRequestClose(self)
  }
}
