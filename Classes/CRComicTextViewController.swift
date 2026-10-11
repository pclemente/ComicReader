import UIKit

@objc(CRComicTextViewControllerDelegate)
public protocol CRComicTextViewControllerDelegate: AnyObject {
    func comicTextViewControllerDidRequestClose(_ controller: CRComicTextViewController)
    func comicTextViewController(_ controller: CRComicTextViewController, didSelectPageIndex pageIndex: Int)
}

@MainActor
@objc(CRComicTextViewController)
public final class CRComicTextViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    @objc public weak var delegate: CRComicTextViewControllerDelegate?
    private let engine: CRComicTextEngine
    private let comicName: String
    private let currentPage: Int
    private let quoteStore = CRSavedQuoteStore.sharedStore
    private let quoteQueue = DispatchQueue(label: "com.pabloclementeperez.ComicReader.Quotes", qos: .userInitiated)
    private var document: CRComicTextDocument?
    private var results: [CRComicTextSearchResult] = []
    private var quotes: [CRSavedQuote] = []
    private var pageText = ""
    private var isIndexing = false
    private var isLoadingPage = false
    private var isClosing = false
    private var searchGeneration = 0
    private var indexGeneration = 0
    private var pageGeneration = 0
    private var preparationGeneration = 0
    private let modes = UISegmentedControl(items: ["This Page", "Search", "Quotes"])
    private let status = UILabel()
    private let pageContent = UITextView()
    private let searchBar = UISearchBar()
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let actions = UIStackView()
    private let body = UIStackView()
    private let indexButton = UIButton(type: .system)
    private let cancelIndexButton = UIButton(type: .system)
    private let saveQuoteButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)

    @objc(initWithComicPath:currentPageIndex:)
    public init(comicPath: String, currentPageIndex: Int) {
        engine = CRComicTextEngine(comicPath: comicPath)
        comicName = URL(fileURLWithPath: comicPath).lastPathComponent
        currentPage = currentPageIndex
        super.init(nibName: nil, bundle: nil)
    }
    public required init?(coder: NSCoder) { fatalError("Use init(comicPath:currentPageIndex:)") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Comic Text"
        view.backgroundColor = .systemGroupedBackground
        preferredContentSize = CGSize(width: 660, height: 760)
        let done = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        done.accessibilityIdentifier = "reader.text.done"
        navigationItem.leftBarButtonItem = done
        modes.selectedSegmentIndex = 0
        modes.accessibilityIdentifier = "reader.text.mode"
        modes.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        status.accessibilityIdentifier = "reader.text.progress"
        pageContent.isEditable = false
        pageContent.isSelectable = true
        pageContent.font = .preferredFont(forTextStyle: .body)
        pageContent.adjustsFontForContentSizeCategory = true
        pageContent.backgroundColor = .secondarySystemGroupedBackground
        pageContent.layer.cornerRadius = 12
        pageContent.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        pageContent.accessibilityIdentifier = "reader.text.content"
        searchBar.placeholder = "Search words in this comic"
        searchBar.searchTextField.accessibilityIdentifier = "reader.text.query"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 90
        table.keyboardDismissMode = .onDrag
        configureButton(indexButton, title: "Index Comic", id: "reader.text.index", action: #selector(startIndex))
        configureButton(cancelIndexButton, title: "Stop", id: "reader.text.cancelIndex", action: #selector(stopIndex))
        configureButton(saveQuoteButton, title: "Save Quote", id: "reader.text.saveQuote", action: #selector(saveQuote))
        configureButton(shareButton, title: "Share Text", id: "reader.text.share", action: #selector(sharePage))
        configureButton(retryButton, title: "Try Again", id: "reader.text.retry", action: #selector(prepareText))
        actions.axis = .horizontal
        actions.spacing = 10
        actions.distribution = .fillEqually
        for button in [shareButton, saveQuoteButton, indexButton, cancelIndexButton, retryButton] { actions.addArrangedSubview(button) }
        body.axis = .vertical
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        for child in [modes, status, actions, searchBar, pageContent, table] { body.addArrangedSubview(child) }
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            body.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
        ])
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        modes.setContentCompressionResistancePriority(.required, for: .vertical)
        NotificationCenter.default.addObserver(self, selector: #selector(entitlementChanged), name: CRPlusStore.entitlementDidChangeNotification, object: CRPlusStore.sharedStore)
        NotificationCenter.default.addObserver(self, selector: #selector(pauseWork), name: UIApplication.didEnterBackgroundNotification, object: nil)
        CRPlusStore.sharedStore.start()
        prepareText()
    }
    deinit { engine.cancel(); NotificationCenter.default.removeObserver(self) }
    public override func didReceiveMemoryWarning() { super.didReceiveMemoryWarning(); pauseWork() }

    private func configureButton(_ button: UIButton, title: String, id: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }
    @objc private func prepareText() {
        preparationGeneration += 1
        let generation = preparationGeneration
        retryButton.isHidden = true
        status.text = "Preparing this comic…"
        updateLayout()
        engine.prepare { [weak self] document, error in
            guard let self, !self.isClosing, generation == self.preparationGeneration else { return }
            if let error { self.showFailure(error); return }
            self.document = document
            self.updateLayout()
            self.loadPage()
            self.reloadQuotes()
            self.search()
        }
    }
    private func loadPage() {
        guard document != nil, !isLoadingPage, pageText.isEmpty else { return }
        isLoadingPage = true
        pageGeneration += 1
        let generation = pageGeneration
        updateLayout()
        engine.recognizePage(atPageIndex: currentPage) { [weak self] text, error in
            guard let self, !self.isClosing, generation == self.pageGeneration else { return }
            self.isLoadingPage = false
            if let error { self.showFailure(error); return }
            self.pageText = text ?? ""
            self.pageContent.text = self.pageText
            self.updateLayout()
        }
    }
    @objc private func modeChanged() {
        view.endEditing(true)
        updateLayout()
        if modes.selectedSegmentIndex == 0 { loadPage() }
        if modes.selectedSegmentIndex == 1 { search() }
        if modes.selectedSegmentIndex == 2 { reloadQuotes() }
    }
    private func updateLayout() {
        let mode = modes.selectedSegmentIndex
        pageContent.isHidden = mode != 0
        table.isHidden = mode == 0
        searchBar.isHidden = mode != 1
        shareButton.isHidden = mode != 0
        saveQuoteButton.isHidden = mode != 0
        indexButton.isHidden = mode != 1 || isIndexing
        cancelIndexButton.isHidden = mode != 1 || !isIndexing
        shareButton.isEnabled = !pageText.isEmpty
        saveQuoteButton.isEnabled = !pageText.isEmpty && document != nil
        indexButton.isEnabled = document != nil && !isLoadingPage && (document?.complete != true || !CRPlusStore.sharedStore.isUnlocked)
        searchBar.searchTextField.isEnabled = document != nil && CRPlusStore.sharedStore.isUnlocked
        if document != nil {
            switch mode {
            case 0:
                status.text = isLoadingPage ? "Reading text on page \(currentPage + 1)…" :
                    (pageText.isEmpty ? "No text was recognized on page \(currentPage + 1). Small or stylized lettering may not be readable." : "Page \(currentPage + 1) · Free for everyone. Select text to copy or share a phrase. Recognition can make mistakes; check quotations before saving.")
            case 1:
                let count = document!.indexedPageCount
                status.text = "Indexed \(count) of \(document!.pageCount) pages. " + (isIndexing ? "Search available pages while indexing continues." : "Plus builds a searchable index on this device. Scans and stylized lettering may produce incomplete results.")
                indexButton.setTitle(document!.complete ? "Comic Indexed" : (count > 0 ? "Resume Indexing" : "Index Comic"), for: .normal)
                if !CRPlusStore.sharedStore.isUnlocked { indexButton.setTitle("Explore Plus", for: .normal) }
            default:
                status.text = "Saved quotations stay on this device. Open a quote to share it or return to its page. Plus adds and edits quotes."
            }
        }
        table.reloadData()
    }
    @objc private func startIndex() {
        guard requirePlus(from: self) else { return }
        guard document != nil, !isIndexing else { return }
        isIndexing = true
        indexGeneration += 1
        let generation = indexGeneration
        retryButton.isHidden = true
        updateLayout()
        engine.buildIndex(startingAtPageIndex: currentPage, progress: { [weak self] document in
            guard let self, !self.isClosing, generation == self.indexGeneration else { return }
            self.document = document
            self.updateLayout()
            self.search()
        }, completion: { [weak self] document, error in
            guard let self, !self.isClosing, generation == self.indexGeneration else { return }
            self.isIndexing = false
            if let document { self.document = document }
            self.updateLayout()
            if let error { self.showFailure(error) }
            self.search()
        })
    }
    @objc private func stopIndex() {
        indexGeneration += 1
        pageGeneration += 1
        preparationGeneration += 1
        searchGeneration += 1
        engine.cancel()
        isIndexing = false
        isLoadingPage = false
        updateLayout()
    }
    @objc private func pauseWork() {
        stopIndex()
        status.text = "Text processing paused. Open Search to resume indexing, or tap Try Again for this page."
        retryButton.isHidden = false
    }
    @objc private func entitlementChanged() {
        if !CRPlusStore.sharedStore.isUnlocked && isIndexing { stopIndex() }
        searchGeneration += 1
        if !CRPlusStore.sharedStore.isUnlocked { results = [] }
        updateLayout()
        if CRPlusStore.sharedStore.isUnlocked { search() }
    }
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { search() }
    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder(); search() }
    private func search() {
        guard modes.selectedSegmentIndex == 1, document != nil else { return }
        searchGeneration += 1
        guard CRPlusStore.sharedStore.isUnlocked else { results = []; table.reloadData(); return }
        let generation = searchGeneration
        engine.search(forQuery: searchBar.text ?? "") { [weak self] results, error in
            guard let self, !self.isClosing, CRPlusStore.sharedStore.isUnlocked, generation == self.searchGeneration else { return }
            if let error { self.showFailure(error); return }
            self.results = results ?? []
            self.table.reloadData()
        }
    }
    private func reloadQuotes() {
        guard let fingerprint = document?.fingerprint else { return }
        quoteQueue.async { [weak self, quoteStore] in
            let result = Result { try quoteStore.records(for: fingerprint) }
            DispatchQueue.main.async {
                guard let self, !self.isClosing else { return }
                switch result {
                case .success(let quotes): self.quotes = quotes; self.table.reloadData()
                case .failure(let error): self.showFailure(error)
                }
            }
        }
    }
    private var selectedPageText: String {
        let value = pageContent.text ?? ""
        let range = pageContent.selectedRange
        if range.length > 0, NSMaxRange(range) <= (value as NSString).length { return (value as NSString).substring(with: range) }
        return value
    }
    @objc private func sharePage() { share(selectedPageText, page: currentPage, from: self, anchor: shareButton) }
    @objc private func saveQuote() {
        guard requirePlus(from: self), let fingerprint = document?.fingerprint else { return }
        let editor = CRQuoteEditorViewController(text: String(selectedPageText.prefix(10_000)), title: "Save Quote")
        editor.save = { [weak self, weak editor] text in
            guard let self, let editor, self.requirePlus(from: editor) else { return }
            editor.setSaving(true)
            self.engine.validateCurrent { [weak self, weak editor] error in
                guard let self, let editor else { return }
                if let error { editor.setSaving(false); self.presentError(error, from: editor); return }
                self.quoteQueue.async { [weak self, weak editor, quoteStore = self.quoteStore, comicName = self.comicName, page = self.currentPage] in
                    let result = Result { try quoteStore.add(fingerprint: fingerprint, comicName: comicName, pageIndex: page, text: text) }
                    DispatchQueue.main.async {
                        guard let self, let editor else { return }
                        editor.setSaving(false)
                        switch result {
                        case .success: self.navigationController?.popViewController(animated: true); self.reloadQuotes()
                        case .failure(let error): self.presentError(error, from: editor)
                        }
                    }
                }
            }
        }
        navigationController?.pushViewController(editor, animated: true)
    }
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { modes.selectedSegmentIndex == 1 ? results.count : quotes.count }
    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if modes.selectedSegmentIndex == 1 && results.isEmpty {
            return (searchBar.text ?? "").isEmpty ? "Enter words to find them in indexed pages." : "No matches in the pages indexed so far."
        }
        return quotes.isEmpty && modes.selectedSegmentIndex == 2 ? "Select text on This Page, then tap Save Quote." : nil
    }
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 4
        content.secondaryTextProperties.numberOfLines = 0
        if modes.selectedSegmentIndex == 1 {
            let result = results[indexPath.row]
            content.text = result.snippet
            content.secondaryText = "Page \(result.pageIndex + 1)"
            cell.accessibilityIdentifier = "reader.text.result.\(result.pageIndex)"
            cell.accessibilityLabel = "\(result.snippet), Page \(result.pageIndex + 1)"
        } else {
            let quote = quotes[indexPath.row]
            content.text = quote.text
            content.secondaryText = "\(quote.comicName) · Page \(quote.pageIndex + 1)"
            cell.accessibilityIdentifier = "reader.quotes.row"
            cell.accessibilityLabel = "\(quote.text), \(quote.comicName), Page \(quote.pageIndex + 1)"
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
            button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            button.accessibilityIdentifier = "reader.quotes.actions"
            button.accessibilityLabel = "Actions for quotation on page \(quote.pageIndex + 1)"
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: [
                UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.editQuote(quote) },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteQuote(quote) }
            ])
            cell.accessoryView = button
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if modes.selectedSegmentIndex == 1 { jump(to: results[indexPath.row].pageIndex) }
        else { showQuote(quotes[indexPath.row]) }
    }
    private func showQuote(_ quote: CRSavedQuote) {
        let detail = CRQuoteDetailViewController(quote: quote)
        detail.share = { [weak self, weak detail] button in
            guard let self, let detail else { return }
            self.share(detail.quote.text, page: detail.quote.pageIndex, from: detail, anchor: button)
        }
        detail.edit = { [weak self, weak detail] in
            guard let self, let detail else { return }
            self.editQuote(detail.quote, detail: detail)
        }
        detail.goToPage = { [weak self] in self?.jump(to: quote.pageIndex) }
        navigationController?.pushViewController(detail, animated: true)
    }
    private func editQuote(_ quote: CRSavedQuote, detail: CRQuoteDetailViewController? = nil) {
        let presenter: UIViewController = detail ?? self
        guard requirePlus(from: presenter), let fingerprint = document?.fingerprint else { return }
        let editor = CRQuoteEditorViewController(text: quote.text, title: "Edit Quote")
        editor.save = { [weak self, weak editor, weak detail] text in
            guard let self, let editor, self.requirePlus(from: editor) else { return }
            editor.setSaving(true)
            self.quoteQueue.async { [weak self, weak editor, weak detail, quoteStore = self.quoteStore] in
                let result = Result { () -> CRSavedQuote? in
                    try quoteStore.update(fingerprint: fingerprint, id: quote.id, text: text)
                    return try quoteStore.records(for: fingerprint).first { $0.id == quote.id }
                }
                DispatchQueue.main.async {
                    guard let self, let editor else { return }
                    editor.setSaving(false)
                    switch result {
                    case .success(let updated):
                        if let updated { detail?.update(updated) }
                        self.navigationController?.popViewController(animated: true)
                        self.reloadQuotes()
                    case .failure(let error): self.presentError(error, from: editor)
                    }
                }
            }
        }
        navigationController?.pushViewController(editor, animated: true)
    }
    private func deleteQuote(_ quote: CRSavedQuote) {
        guard requirePlus(from: self), let fingerprint = document?.fingerprint else { return }
        let alert = UIAlertController(title: "Delete Quote?", message: "This removes the saved quotation from this device. The comic is unchanged.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self, self.requirePlus(from: self) else { return }
            self.quoteQueue.async { [weak self, quoteStore = self.quoteStore] in
                let result = Result { try quoteStore.remove(fingerprint: fingerprint, id: quote.id) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success: self.reloadQuotes()
                    case .failure(let error): self.presentError(error, from: self)
                    }
                }
            }
        })
        present(alert, animated: true)
    }
    private func jump(to page: Int) {
        guard let document, page >= 0, page < document.pageCount else { return }
        engine.validateCurrent { [weak self] error in
            guard let self, !self.isClosing else { return }
            if let error { self.presentError(error, from: self.navigationController?.topViewController ?? self); return }
            self.isClosing = true
            self.engine.cancel()
            self.delegate?.comicTextViewController(self, didSelectPageIndex: page)
        }
    }
    private func share(_ text: String, page: Int, from presenter: UIViewController, anchor: UIView) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let activity = UIActivityViewController(activityItems: ["\(text)\n\n— \(comicName), page \(page + 1)"], applicationActivities: nil)
        activity.view.accessibilityIdentifier = "reader.text.shareSheet"
        activity.popoverPresentationController?.sourceView = anchor
        activity.popoverPresentationController?.sourceRect = anchor.bounds
        presenter.present(activity, animated: true)
    }
    private func requirePlus(from presenter: UIViewController) -> Bool {
        guard !CRPlusStore.sharedStore.isUnlocked else { return true }
        let alert = UIAlertController(title: "ComicReader Plus", message: "Plus builds a searchable comic index and saves editable quotations. Current-page text, copying and sharing are free.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "View Plus", style: .default) { [weak self] _ in self?.navigationController?.pushViewController(CRPlusViewController(), animated: true) })
        presenter.present(alert, animated: true)
        return false
    }
    private func showFailure(_ error: Error) {
        status.text = error.localizedDescription
        retryButton.isHidden = false
    }
    private func presentError(_ error: Error, from presenter: UIViewController) {
        let alert = UIAlertController(title: "Comic Text", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }
    @objc private func close() {
        isClosing = true
        engine.cancel()
        delegate?.comicTextViewControllerDidRequestClose(self)
    }
}

@MainActor
private final class CRQuoteEditorViewController: UIViewController, UITextViewDelegate {
    var save: ((String) -> Void)?
    private let textView = UITextView()
    private var isSaving = false
    private var saveItem: UIBarButtonItem!
    init(text: String, title: String) { super.init(nibName: nil, bundle: nil); self.title = title; textView.text = text }
    required init?(coder: NSCoder) { fatalError("Use init(text:title:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = self
        textView.accessibilityIdentifier = "reader.quote.editor"
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        let cancel = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        cancel.accessibilityIdentifier = "reader.quote.cancel"
        navigationItem.leftBarButtonItem = cancel
        saveItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(savePressed))
        saveItem.accessibilityIdentifier = "reader.quote.save"
        navigationItem.rightBarButtonItem = saveItem
        textViewDidChange(textView)
    }
    func textViewDidChange(_ textView: UITextView) { saveItem?.isEnabled = !isSaving && !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && textView.text.count <= 10_000 }
    func setSaving(_ value: Bool) { isSaving = value; textView.isEditable = !value; navigationItem.leftBarButtonItem?.isEnabled = !value; textViewDidChange(textView) }
    @objc private func savePressed() { guard !isSaving else { return }; save?(textView.text) }
    @objc private func cancel() { guard !isSaving else { return }; navigationController?.popViewController(animated: true) }
}

@MainActor
private final class CRQuoteDetailViewController: UIViewController {
    private(set) var quote: CRSavedQuote
    var share: ((UIView) -> Void)?
    var edit: (() -> Void)?
    var goToPage: (() -> Void)?
    private let textView = UITextView()
    init(quote: CRSavedQuote) { self.quote = quote; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(quote:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Saved Quote"
        view.backgroundColor = .systemGroupedBackground
        let done = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        done.accessibilityIdentifier = "reader.quote.done"
        navigationItem.leftBarButtonItem = done
        let editItem = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(editPressed))
        editItem.accessibilityIdentifier = "reader.quote.edit"
        navigationItem.rightBarButtonItem = editItem
        textView.isEditable = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityIdentifier = "reader.quote.content"
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        let source = UILabel()
        source.text = "\(quote.comicName) · Page \(quote.pageIndex + 1)"
        source.font = .preferredFont(forTextStyle: .footnote)
        source.adjustsFontForContentSizeCategory = true
        source.numberOfLines = 0
        source.textColor = .secondaryLabel
        let share = UIButton(type: .system)
        share.setTitle("Share Quote", for: .normal)
        share.accessibilityIdentifier = "reader.quote.share"
        share.addTarget(self, action: #selector(sharePressed(_:)), for: .touchUpInside)
        let jump = UIButton(type: .system)
        jump.setTitle("Go to Page \(quote.pageIndex + 1)", for: .normal)
        jump.accessibilityIdentifier = "reader.quote.goToPage"
        jump.addTarget(self, action: #selector(jumpPressed), for: .touchUpInside)
        for button in [share, jump] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        let buttons = UIStackView(arrangedSubviews: [share, jump])
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [source, textView, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        update(quote)
    }
    func update(_ quote: CRSavedQuote) { self.quote = quote; textView.text = quote.text }
    @objc private func done() { navigationController?.popViewController(animated: true) }
    @objc private func editPressed() { edit?() }
    @objc private func sharePressed(_ button: UIButton) { share?(button) }
    @objc private func jumpPressed() { goToPage?() }
}
