#import "CRReadingLists.h"

#import "ComicFlow-Swift.h"
#import "ComicViewController.h"
#import "Library.h"

static void CRReadingListsPresentWhenReady(UIViewController* controller,
                                           UIViewController* presentedController,
                                           NSUInteger retriesRemaining) {
  __weak UIViewController* weakController = controller;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIViewController* controller = weakController;
    if (!controller || !controller.viewIfLoaded.window) return;
    if (controller.presentedViewController || controller.isBeingDismissed || controller.isBeingPresented) {
      if (retriesRemaining) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          CRReadingListsPresentWhenReady(controller, presentedController, retriesRemaining - 1);
        });
      }
      return;
    }
    [controller presentViewController:presentedController animated:YES completion:nil];
  });
}

static void CRReadingListsShowError(UIViewController* controller, NSError* error) {
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Reading Lists"
                                                                 message:error.localizedDescription ?: @"The operation could not be completed."
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
  CRReadingListsPresentWhenReady(controller, alert, 10);
}

static void CRReadingListsPresentPlus(UIViewController* controller) {
  CRPlusViewController* plus = [[CRPlusViewController alloc] init];
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:plus];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  CRReadingListsPresentWhenReady(controller, navigation, 10);
}

static UIView* CRReadingListsEmptyView(NSString* title, NSString* message, NSString* symbolName,
                                      UIButton* actionButton) {
  UIImageView* imageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName]];
  imageView.translatesAutoresizingMaskIntoConstraints = NO;
  imageView.tintColor = UIColor.tertiaryLabelColor;
  imageView.contentMode = UIViewContentModeScaleAspectFit;
  imageView.accessibilityElementsHidden = YES;

  UILabel* titleLabel = [[UILabel alloc] init];
  titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
  titleLabel.adjustsFontForContentSizeCategory = YES;
  titleLabel.textColor = UIColor.labelColor;
  titleLabel.textAlignment = NSTextAlignmentCenter;
  titleLabel.text = title;

  UILabel* messageLabel = [[UILabel alloc] init];
  messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  messageLabel.adjustsFontForContentSizeCategory = YES;
  messageLabel.textColor = UIColor.secondaryLabelColor;
  messageLabel.textAlignment = NSTextAlignmentCenter;
  messageLabel.numberOfLines = 0;
  messageLabel.text = message;

  NSMutableArray<UIView*>* arrangedViews = [@[imageView, titleLabel, messageLabel] mutableCopy];
  if (actionButton) [arrangedViews addObject:actionButton];
  UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:arrangedViews];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  stack.axis = UILayoutConstraintAxisVertical;
  stack.alignment = UIStackViewAlignmentFill;
  stack.spacing = 8;
  [stack setCustomSpacing:16 afterView:imageView];

  UIView* container = [[UIView alloc] init];
  [container addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [imageView.heightAnchor constraintEqualToConstant:48],
    [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-20],
    [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:32],
    [stack.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-32],
    [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
    [stack.widthAnchor constraintLessThanOrEqualToConstant:460],
  ]];
  container.isAccessibilityElement = actionButton == nil;
  if (!actionButton) container.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", title, message];
  return container;
}

static UIButton* CRReadingListsActionButton(NSString* title, id target, SEL action) {
  UIButtonConfiguration* configuration = [UIButtonConfiguration tintedButtonConfiguration];
  configuration.title = title;
  configuration.buttonSize = UIButtonConfigurationSizeMedium;
  UIButton* button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
  [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
  return button;
}

@class CRReadingListDetailViewController;
@class CRReadingSmartQueueViewController;

typedef NS_ENUM(NSInteger, CRReadingListsSection) {
  CRReadingListsSectionSmartQueues = 0,
  CRReadingListsSectionSavedLists,
  CRReadingListsSectionCount,
};

static NSString* CRReadingSmartQueueSymbolName(CRReadingSmartQueueKind kind) {
  switch (kind) {
    case CRReadingSmartQueueKindContinueReading: return @"book.closed";
    case CRReadingSmartQueueKindUnread: return @"sparkles";
    case CRReadingSmartQueueKindFinished: return @"checkmark.circle";
  }
  return @"books.vertical";
}

static NSString* CRReadingSmartQueueEmptyMessage(CRReadingSmartQueueKind kind) {
  switch (kind) {
    case CRReadingSmartQueueKindContinueReading:
      return @"Comics with reading progress appear here automatically.";
    case CRReadingSmartQueueKindUnread:
      return @"Comics marked unread appear here automatically.";
    case CRReadingSmartQueueKindFinished:
      return @"Comics marked as read appear here automatically.";
  }
  return @"This Smart Queue updates from your library.";
}

@interface CRReadingListComicPickerController : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithStore:(CRReadingListsStore*)store listIdentifier:(NSString*)listIdentifier;
@end

@interface CRReadingSmartQueueViewController : UITableViewController
- (instancetype)initWithStore:(CRReadingListsStore*)store
                          kind:(CRReadingSmartQueueKind)kind
              openComicHandler:(CRReadingListsOpenComicHandler)openComicHandler;
@property(nonatomic, strong) CRReadingListsStore* store;
@property(nonatomic) CRReadingSmartQueueKind kind;
@property(nonatomic, copy) NSArray<Comic*>* comics;
@property(nonatomic, copy) CRReadingListsOpenComicHandler openComicHandler;
@end

@interface CRReadingListsViewController ()
@property(nonatomic, strong) CRReadingListsStore* store;
@property(nonatomic, copy) CRReadingListsOpenComicHandler openComicHandler;
@property(nonatomic) BOOL didShowLoadError;
@end

@interface CRReadingListDetailViewController : UITableViewController
- (instancetype)initWithStore:(CRReadingListsStore*)store
                listIdentifier:(NSString*)listIdentifier
              openComicHandler:(CRReadingListsOpenComicHandler)openComicHandler;
@property(nonatomic, strong) CRReadingListsStore* store;
@property(nonatomic, copy) NSString* listIdentifier;
@property(nonatomic, copy) CRReadingListsOpenComicHandler openComicHandler;
@end

@implementation CRReadingListsViewController

- (instancetype)initWithLibraryConnection:(LibraryConnection*)libraryConnection {
  return [self initWithLibraryConnection:libraryConnection openComicHandler:nil];
}

- (instancetype)initWithLibraryConnection:(LibraryConnection*)libraryConnection
                          openComicHandler:(CRReadingListsOpenComicHandler)openComicHandler {
  CRReadingListsStore* store = [[CRReadingListsStore alloc] initWithLibraryConnection:libraryConnection];
  return [self initWithStore:store openComicHandler:openComicHandler];
}

- (instancetype)initWithStore:(CRReadingListsStore*)store
             openComicHandler:(CRReadingListsOpenComicHandler)openComicHandler {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
    _store = store;
    _openComicHandler = [openComicHandler copy];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Reading Lists";
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 64;
  self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
  [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"List"];

  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
    initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done:)];
  UIBarButtonItem* add = [[UIBarButtonItem alloc]
    initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addList:)];
  add.accessibilityIdentifier = @"readingLists.add";
  self.editButtonItem.accessibilityIdentifier = @"readingLists.edit";
  self.navigationItem.rightBarButtonItems = @[add, self.editButtonItem];

  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  [center addObserver:self selector:@selector(storeDidChange:) name:CRReadingListsDidChangeNotification object:self.store];
  [center addObserver:self selector:@selector(entitlementDidChange:) name:CRPlusStore.entitlementDidChangeNotification object:nil];
  [center addObserver:self selector:@selector(libraryStateDidChange:) name:@"CRLibraryReadingStateDidChangeNotification" object:nil];
  [center addObserver:self selector:@selector(libraryStateDidChange:) name:UIApplicationDidBecomeActiveNotification object:nil];
  [self.store refreshLibraryState];
  [self updateEmptyState];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.store refreshLibraryState];
  [self.tableView reloadData];
  [self updateEmptyState];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (self.store.loadError && !self.didShowLoadError) {
    self.didShowLoadError = YES;
    CRReadingListsShowError(self, self.store.loadError);
  }
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
  if (editing && !self.store.isEditingAllowed) {
    CRReadingListsPresentPlus(self);
    return;
  }
  [super setEditing:editing animated:animated];
}

- (void)storeDidChange:(NSNotification*)notification {
  [self.tableView reloadData];
  [self updateEmptyState];
}

- (void)entitlementDidChange:(NSNotification*)notification {
  if (!self.store.isEditingAllowed && self.isEditing) [super setEditing:NO animated:YES];
  [self.tableView reloadData];
  [self updateEmptyState];
}

- (void)libraryStateDidChange:(NSNotification*)notification {
  [self.store refreshLibraryState];
  [self.tableView reloadData];
  [self updateEmptyState];
}

- (void)done:(id)sender {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)addList:(id)sender {
  if (!self.store.isEditingAllowed) {
    CRReadingListsPresentPlus(self);
    return;
  }
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"New Reading List"
                                                                 message:@"Give this list a unique name."
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
    textField.placeholder = @"List name";
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    textField.accessibilityIdentifier = @"readingLists.name";
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  __weak __typeof__(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
    __typeof__(self) self = weakSelf;
    if (!self) return;
    NSError* error = nil;
    CRReadingList* list = nil;
    if ([self.store createListNamed:alert.textFields.firstObject.text createdList:&list error:&error]) {
      CRReadingListDetailViewController* detail = [[CRReadingListDetailViewController alloc]
        initWithStore:self.store listIdentifier:list.identifier openComicHandler:self.openComicHandler];
      [self.navigationController pushViewController:detail animated:YES];
    } else if (error.code == CRReadingListsErrorEditingRequiresPlus) {
      CRReadingListsPresentPlus(self);
    } else {
      CRReadingListsShowError(self, error);
    }
  }]];
  CRReadingListsPresentWhenReady(self, alert, 10);
}

- (void)updateEmptyState {
  self.tableView.backgroundView = nil;
  self.editButtonItem.enabled = self.store.lists.count > 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return CRReadingListsSectionCount;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return section == CRReadingListsSectionSmartQueues ? self.store.smartQueues.count : self.store.lists.count;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  return section == CRReadingListsSectionSmartQueues ? @"Smart Queues" : @"My Lists";
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (section == CRReadingListsSectionSmartQueues) {
    return self.store.isSmartQueueAccessAllowed
      ? @"Smart Queues update automatically from reading progress across every folder in your library."
      : @"Preview counts update automatically across your library. ComicReader Plus is required to open Smart Queues.";
  }
  if (!self.store.lists.count) {
    return self.store.isEditingAllowed
      ? @"Create your own ordered list with the + button."
      : @"Saved lists stay readable if Plus is no longer active. Creating and editing lists requires Plus.";
  }
  return self.store.isEditingAllowed ? @"Your saved, manually ordered lists."
                                     : @"Saved lists remain readable. Creating and editing lists requires Plus.";
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"List" forIndexPath:indexPath];
  cell.accessoryView = nil;
  if (indexPath.section == CRReadingListsSectionSmartQueues) {
    CRReadingSmartQueue* queue = self.store.smartQueues[indexPath.row];
    BOOL locked = !self.store.isSmartQueueAccessAllowed;
    UIListContentConfiguration* content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = queue.name;
    NSString* count = [NSString localizedStringWithFormat:@"%lu comic%@",
      (unsigned long)queue.comicCount, queue.comicCount == 1 ? @"" : @"s"];
    content.secondaryText = locked ? [count stringByAppendingString:@" · Plus"] : count;
    content.image = [UIImage systemImageNamed:CRReadingSmartQueueSymbolName(queue.kind)];
    content.imageProperties.tintColor = self.view.tintColor;
    content.textProperties.numberOfLines = 0;
    content.secondaryTextProperties.numberOfLines = 0;
    cell.contentConfiguration = content;
    if (locked) {
      UIImageView* lock = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"]];
      lock.tintColor = UIColor.tertiaryLabelColor;
      lock.accessibilityElementsHidden = YES;
      cell.accessoryView = lock;
      cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.accessibilityIdentifier = [@"readingLists.smartQueue." stringByAppendingString:queue.identifier];
    cell.accessibilityHint = locked ? @"Shows ComicReader Plus before opening this Smart Queue."
                                    : @"Opens this automatically updated Smart Queue.";
    return cell;
  }
  CRReadingList* list = self.store.lists[indexPath.row];
  UIListContentConfiguration* content = [UIListContentConfiguration valueCellConfiguration];
  content.text = list.name;
  content.secondaryText = [NSString localizedStringWithFormat:@"%lu comic%@",
                           (unsigned long)list.items.count, list.items.count == 1 ? @"" : @"s"];
  content.image = [UIImage systemImageNamed:@"text.book.closed"];
  content.imageProperties.tintColor = self.view.tintColor;
  cell.contentConfiguration = content;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  cell.accessibilityIdentifier = [@"readingLists.list." stringByAppendingString:list.identifier];
  return cell;
}

- (BOOL)tableView:(UITableView*)tableView canEditRowAtIndexPath:(NSIndexPath*)indexPath {
  return indexPath.section == CRReadingListsSectionSavedLists && self.store.isEditingAllowed;
}

- (BOOL)tableView:(UITableView*)tableView canMoveRowAtIndexPath:(NSIndexPath*)indexPath {
  return indexPath.section == CRReadingListsSectionSavedLists && self.store.isEditingAllowed;
}

- (void)tableView:(UITableView*)tableView moveRowAtIndexPath:(NSIndexPath*)sourceIndexPath
                                      toIndexPath:(NSIndexPath*)destinationIndexPath {
  NSError* error = nil;
  if (![self.store moveListFromIndex:sourceIndexPath.row toIndex:destinationIndexPath.row error:&error]) {
    [tableView reloadData];
    CRReadingListsShowError(self, error);
  }
}

- (NSIndexPath*)tableView:(UITableView*)tableView
 targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath*)sourceIndexPath
       toProposedIndexPath:(NSIndexPath*)proposedDestinationIndexPath {
  if (proposedDestinationIndexPath.section == CRReadingListsSectionSavedLists) return proposedDestinationIndexPath;
  return [NSIndexPath indexPathForRow:0 inSection:CRReadingListsSectionSavedLists];
}

- (void)tableView:(UITableView*)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section != CRReadingListsSectionSavedLists || editingStyle != UITableViewCellEditingStyleDelete) return;
  CRReadingList* list = self.store.lists[indexPath.row];
  NSError* error = nil;
  if (![self.store removeList:list error:&error]) CRReadingListsShowError(self, error);
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView
 trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section != CRReadingListsSectionSavedLists || !self.store.isEditingAllowed) return nil;
  CRReadingList* list = self.store.lists[indexPath.row];
  __weak __typeof__(self) weakSelf = self;
  UIContextualAction* deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
    title:@"Delete" handler:^(UIContextualAction* action, UIView* sourceView, void (^completionHandler)(BOOL)) {
      __typeof__(self) self = weakSelf;
      NSError* error = nil;
      BOOL removed = self && [self.store removeList:list error:&error];
      if (!removed && self) CRReadingListsShowError(self, error);
      completionHandler(removed);
    }];
  UIContextualAction* renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
    title:@"Rename" handler:^(UIContextualAction* action, UIView* sourceView, void (^completionHandler)(BOOL)) {
      __typeof__(self) self = weakSelf;
      if (self) [self promptToRenameList:list];
      completionHandler(NO);
    }];
  renameAction.backgroundColor = UIColor.systemBlueColor;
  return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, renameAction]];
}

- (void)promptToRenameList:(CRReadingList*)list {
  if (!self.store.isEditingAllowed) {
    CRReadingListsPresentPlus(self);
    return;
  }
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Rename Reading List"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
    textField.text = list.name;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    textField.accessibilityIdentifier = @"readingLists.name";
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  __weak __typeof__(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
    __typeof__(self) self = weakSelf;
    NSError* error = nil;
    if (self && ![self.store renameList:list toName:alert.textFields.firstObject.text error:&error]) {
      CRReadingListsShowError(self, error);
    }
  }]];
  CRReadingListsPresentWhenReady(self, alert, 10);
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == CRReadingListsSectionSmartQueues) {
    CRReadingSmartQueue* queue = self.store.smartQueues[indexPath.row];
    if (!self.store.isSmartQueueAccessAllowed) {
      CRReadingListsPresentPlus(self);
      return;
    }
    CRReadingSmartQueueViewController* detail = [[CRReadingSmartQueueViewController alloc]
      initWithStore:self.store kind:queue.kind openComicHandler:self.openComicHandler];
    [self.navigationController pushViewController:detail animated:YES];
    return;
  }
  CRReadingList* list = self.store.lists[indexPath.row];
  CRReadingListDetailViewController* detail = [[CRReadingListDetailViewController alloc]
    initWithStore:self.store listIdentifier:list.identifier openComicHandler:self.openComicHandler];
  [self.navigationController pushViewController:detail animated:YES];
}

@end

@implementation CRReadingSmartQueueViewController

- (instancetype)initWithStore:(CRReadingListsStore*)store
                          kind:(CRReadingSmartQueueKind)kind
              openComicHandler:(CRReadingListsOpenComicHandler)openComicHandler {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
    _store = store;
    _kind = kind;
    _openComicHandler = [openComicHandler copy];
    _comics = @[];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 64;
  self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
  [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"SmartQueueComic"];

  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  [center addObserver:self selector:@selector(libraryStateDidChange:) name:@"CRLibraryReadingStateDidChangeNotification" object:nil];
  [center addObserver:self selector:@selector(libraryStateDidChange:) name:UIApplicationDidBecomeActiveNotification object:nil];
  [center addObserver:self selector:@selector(entitlementDidChange:) name:CRPlusStore.entitlementDidChangeNotification object:nil];
  [self refreshQueue];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if (!self.store.isSmartQueueAccessAllowed) {
    [self.navigationController popViewControllerAnimated:animated];
    return;
  }
  [self refreshQueue];
}

- (void)libraryStateDidChange:(NSNotification*)notification {
  if (self.store.isSmartQueueAccessAllowed) [self refreshQueue];
}

- (void)entitlementDidChange:(NSNotification*)notification {
  if (!self.store.isSmartQueueAccessAllowed) {
    [self.navigationController popViewControllerAnimated:YES];
  } else {
    [self refreshQueue];
  }
}

- (void)refreshQueue {
  [self.store refreshLibraryState];
  CRReadingSmartQueue* queue = [self.store smartQueueWithKind:self.kind];
  self.comics = queue ? [self.store comicsForSmartQueue:queue error:NULL] : @[];
  if (!self.comics) self.comics = @[];
  self.title = queue.name ?: @"Smart Queue";
  [self.tableView reloadData];
  self.tableView.backgroundView = self.comics.count ? nil :
    CRReadingListsEmptyView(@"No Comics", CRReadingSmartQueueEmptyMessage(self.kind),
                            CRReadingSmartQueueSymbolName(self.kind), nil);
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return self.comics.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"SmartQueueComic" forIndexPath:indexPath];
  Comic* comic = self.comics[indexPath.row];
  NSString* path = [self.store.libraryConnection pathForComic:comic];
  NSString* folderPath = path.stringByDeletingLastPathComponent;
  NSString* folder = [folderPath isEqualToString:self.store.libraryRootURL.path] ? @"Library" : folderPath.lastPathComponent;
  NSString* state = nil;
  switch (self.kind) {
    case CRReadingSmartQueueKindContinueReading:
      state = [NSString localizedStringWithFormat:@"Page %d", comic.status + 1];
      break;
    case CRReadingSmartQueueKindUnread:
      state = @"Unread";
      break;
    case CRReadingSmartQueueKindFinished:
      state = @"Read";
      break;
  }
  UIListContentConfiguration* content = [UIListContentConfiguration subtitleCellConfiguration];
  content.text = comic.name;
  content.secondaryText = folder.length ? [NSString stringWithFormat:@"%@ · %@", folder, state] : state;
  content.image = [UIImage systemImageNamed:@"book.closed"];
  content.imageProperties.tintColor = self.view.tintColor;
  content.textProperties.numberOfLines = 0;
  content.secondaryTextProperties.numberOfLines = 0;
  cell.contentConfiguration = content;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  CRReadingSmartQueue* queue = [self.store smartQueueWithKind:self.kind];
  cell.accessibilityIdentifier = [NSString stringWithFormat:@"readingLists.smartQueueComic.%@.%ld",
    queue.identifier ?: @"unknown", (long)indexPath.row];
  cell.accessibilityHint = @"Opens this comic.";
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (!self.store.isSmartQueueAccessAllowed || indexPath.row >= self.comics.count) return;
  Comic* comic = self.comics[indexPath.row];
  if (self.openComicHandler) {
    self.openComicHandler(comic, self);
    return;
  }
  ComicViewController* reader = [[ComicViewController alloc] initWithComic:comic];
  if (!reader) {
    CRReadingListsShowError(self, [NSError errorWithDomain:CRReadingListsErrorDomain
      code:CRReadingListsErrorComicUnavailable
      userInfo:@{NSLocalizedDescriptionKey: @"The comic could not be opened."}]);
    return;
  }
  reader.modalPresentationStyle = UIModalPresentationFullScreen;
  reader.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
  [self presentViewController:reader animated:YES completion:nil];
}

@end

@implementation CRReadingListDetailViewController

- (instancetype)initWithStore:(CRReadingListsStore*)store
                listIdentifier:(NSString*)listIdentifier
              openComicHandler:(CRReadingListsOpenComicHandler)openComicHandler {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
    _store = store;
    _listIdentifier = [listIdentifier copy];
    _openComicHandler = [openComicHandler copy];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (CRReadingList*)currentList {
  return [self.store listWithIdentifier:self.listIdentifier];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
  [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Comic"];

  UIBarButtonItem* add = [[UIBarButtonItem alloc]
    initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addComic:)];
  add.accessibilityIdentifier = @"readingLists.addComic";
  UIBarButtonItem* more = [[UIBarButtonItem alloc]
    initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain
    target:self action:@selector(showListActions:)];
  more.accessibilityLabel = @"List actions";
  self.editButtonItem.accessibilityIdentifier = @"readingLists.editComics";
  self.navigationItem.rightBarButtonItems = @[add, self.editButtonItem, more];

  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  [center addObserver:self selector:@selector(storeDidChange:) name:CRReadingListsDidChangeNotification object:self.store];
  [center addObserver:self selector:@selector(entitlementDidChange:) name:CRPlusStore.entitlementDidChangeNotification object:nil];
  [self updateUI];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.store refreshLibraryState];
  [self updateUI];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
  if (editing && !self.store.isEditingAllowed) {
    CRReadingListsPresentPlus(self);
    return;
  }
  [super setEditing:editing animated:animated];
}

- (void)storeDidChange:(NSNotification*)notification {
  if (!self.currentList) {
    [self.navigationController popViewControllerAnimated:YES];
    return;
  }
  [self updateUI];
}

- (void)entitlementDidChange:(NSNotification*)notification {
  if (!self.store.isEditingAllowed && self.isEditing) [super setEditing:NO animated:YES];
  [self updateUI];
}

- (void)updateUI {
  CRReadingList* list = self.currentList;
  self.title = list.name;
  [self.tableView reloadData];
  UIButton* button = CRReadingListsActionButton(self.store.isEditingAllowed ? @"Add Comic" : @"View ComicReader Plus",
                                                self, @selector(addComic:));
  button.accessibilityIdentifier = @"readingLists.emptyAddComic";
  self.tableView.backgroundView = list.items.count ? nil :
    CRReadingListsEmptyView(@"No Comics", @"Add comics from your library. Their files will not be moved or copied.",
                            @"books.vertical", button);
}

- (void)addComic:(id)sender {
  if (!self.store.isEditingAllowed) {
    CRReadingListsPresentPlus(self);
    return;
  }
  CRReadingListComicPickerController* picker = [[CRReadingListComicPickerController alloc]
    initWithStore:self.store listIdentifier:self.listIdentifier];
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:picker];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:navigation animated:YES completion:nil];
}

- (void)showListActions:(UIBarButtonItem*)sender {
  if (!self.store.isEditingAllowed) {
    CRReadingListsPresentPlus(self);
    return;
  }
  UIAlertController* sheet = [UIAlertController alertControllerWithTitle:self.currentList.name
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
  __weak __typeof__(self) weakSelf = self;
  [sheet addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
    [weakSelf promptToRename];
  }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Delete List" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
    [weakSelf confirmDelete];
  }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  sheet.popoverPresentationController.barButtonItem = sender;
  [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptToRename {
  CRReadingList* list = self.currentList;
  if (!list) return;
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Rename Reading List"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
    textField.text = list.name;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  __weak __typeof__(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
    __typeof__(self) self = weakSelf;
    NSError* error = nil;
    if (self && ![self.store renameList:list toName:alert.textFields.firstObject.text error:&error]) {
      CRReadingListsShowError(self, error);
    }
  }]];
  CRReadingListsPresentWhenReady(self, alert, 10);
}

- (void)confirmDelete {
  CRReadingList* list = self.currentList;
  if (!list) return;
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Delete Reading List?"
                                                                 message:@"The comic files in this list will remain in your library."
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  __weak __typeof__(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
    __typeof__(self) self = weakSelf;
    NSError* error = nil;
    if (self && ![self.store removeList:list error:&error]) CRReadingListsShowError(self, error);
  }]];
  CRReadingListsPresentWhenReady(self, alert, 10);
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return self.currentList.items.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"Comic" forIndexPath:indexPath];
  CRReadingListItem* item = self.currentList.items[indexPath.row];
  BOOL available = [self.store availabilityForItem:item] == CRReadingListItemAvailabilityAvailable;
  UIListContentConfiguration* content = [UIListContentConfiguration subtitleCellConfiguration];
  content.text = item.displayName;
  content.secondaryText = available ? item.relativePath : @"File missing or changed";
  content.image = [UIImage systemImageNamed:available ? @"book.closed" : @"exclamationmark.triangle"];
  content.imageProperties.tintColor = available ? self.view.tintColor : UIColor.systemOrangeColor;
  if (!available) {
    content.textProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.color = UIColor.systemOrangeColor;
  }
  cell.contentConfiguration = content;
  cell.accessoryType = available ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
  cell.accessibilityIdentifier = [@"readingLists.comic." stringByAppendingString:item.identifier];
  cell.accessibilityHint = available ? @"Opens this comic." : @"The saved file identity no longer matches the library.";
  return cell;
}

- (BOOL)tableView:(UITableView*)tableView canEditRowAtIndexPath:(NSIndexPath*)indexPath {
  return self.store.isEditingAllowed;
}

- (BOOL)tableView:(UITableView*)tableView canMoveRowAtIndexPath:(NSIndexPath*)indexPath {
  return self.store.isEditingAllowed;
}

- (void)tableView:(UITableView*)tableView moveRowAtIndexPath:(NSIndexPath*)sourceIndexPath
                                      toIndexPath:(NSIndexPath*)destinationIndexPath {
  NSError* error = nil;
  if (![self.store moveItemInList:self.currentList fromIndex:sourceIndexPath.row
                         toIndex:destinationIndexPath.row error:&error]) {
    [tableView reloadData];
    CRReadingListsShowError(self, error);
  }
}

- (void)tableView:(UITableView*)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath*)indexPath {
  if (editingStyle != UITableViewCellEditingStyleDelete) return;
  NSError* error = nil;
  if (![self.store removeItemAtIndex:indexPath.row fromList:self.currentList error:&error]) {
    CRReadingListsShowError(self, error);
  }
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  CRReadingListItem* item = self.currentList.items[indexPath.row];
  Comic* comic = [self.store comicForItem:item];
  if (!comic) {
    CRReadingListsShowError(self, [NSError errorWithDomain:CRReadingListsErrorDomain
      code:CRReadingListsErrorComicUnavailable
      userInfo:@{NSLocalizedDescriptionKey: @"This comic is missing or its file has changed. It was not relinked automatically."}]);
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    return;
  }
  if (self.openComicHandler) {
    self.openComicHandler(comic, self);
    return;
  }
  ComicViewController* reader = [[ComicViewController alloc] initWithComic:comic];
  if (!reader) {
    CRReadingListsShowError(self, [NSError errorWithDomain:CRReadingListsErrorDomain
      code:CRReadingListsErrorComicUnavailable
      userInfo:@{NSLocalizedDescriptionKey: @"The comic could not be opened."}]);
    return;
  }
  reader.modalPresentationStyle = UIModalPresentationFullScreen;
  reader.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
  [self presentViewController:reader animated:YES completion:nil];
}

@end

@interface CRReadingListComicPickerController ()
@property(nonatomic, strong) CRReadingListsStore* store;
@property(nonatomic, copy) NSString* listIdentifier;
@property(nonatomic, copy) NSArray<Comic*>* allComics;
@property(nonatomic, copy) NSArray<Comic*>* displayedComics;
@property(nonatomic, strong) UISearchController* searchController;
@end

@implementation CRReadingListComicPickerController

- (instancetype)initWithStore:(CRReadingListsStore*)store listIdentifier:(NSString*)listIdentifier {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
    _store = store;
    _listIdentifier = [listIdentifier copy];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Add Comic";
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
  [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"PickerComic"];
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
    initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel:)];

  self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
  self.searchController.obscuresBackgroundDuringPresentation = NO;
  self.searchController.searchResultsUpdater = self;
  self.searchController.searchBar.placeholder = @"Search your library";
  self.searchController.searchBar.accessibilityIdentifier = @"readingLists.comicSearch";
  self.navigationItem.searchController = self.searchController;
  self.navigationItem.hidesSearchBarWhenScrolling = NO;
  self.definesPresentationContext = YES;

  self.allComics = [self.store.libraryConnection fetchAllComicsByName];
  self.displayedComics = self.allComics;
  [self.store refreshLibraryState];
  if (!self.allComics.count) {
    self.tableView.backgroundView = CRReadingListsEmptyView(@"No Comics",
      @"Import a comic into the library before adding it to a Reading List.", @"book.closed", nil);
  }
}

- (void)cancel:(id)sender {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController*)searchController {
  NSString* query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!query.length) {
    self.displayedComics = self.allComics;
  } else {
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    self.displayedComics = [self.allComics filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(Comic* comic,
                                                                                                                NSDictionary* bindings) {
      return [comic.name rangeOfString:query options:options].location != NSNotFound;
    }]];
  }
  [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return self.displayedComics.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"PickerComic" forIndexPath:indexPath];
  Comic* comic = self.displayedComics[indexPath.row];
  CRReadingList* list = [self.store listWithIdentifier:self.listIdentifier];
  BOOL alreadyAdded = list && [self.store containsComic:comic inList:list];
  NSString* path = [self.store.libraryConnection pathForComic:comic];
  UIListContentConfiguration* content = [UIListContentConfiguration subtitleCellConfiguration];
  content.text = comic.name;
  content.secondaryText = path.stringByDeletingLastPathComponent.lastPathComponent;
  content.image = [UIImage systemImageNamed:@"book.closed"];
  content.imageProperties.tintColor = self.view.tintColor;
  cell.contentConfiguration = content;
  cell.accessoryType = alreadyAdded ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  cell.selectionStyle = alreadyAdded ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
  cell.accessibilityHint = alreadyAdded ? @"Already in this Reading List." : @"Adds this comic to the Reading List.";
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  CRReadingList* list = [self.store listWithIdentifier:self.listIdentifier];
  Comic* comic = self.displayedComics[indexPath.row];
  if (!list || [self.store containsComic:comic inList:list]) return;
  NSError* error = nil;
  if ([self.store addComic:comic toList:list error:&error]) {
    [self dismissViewControllerAnimated:YES completion:nil];
  } else if (error.code == CRReadingListsErrorEditingRequiresPlus) {
    CRReadingListsPresentPlus(self);
  } else {
    CRReadingListsShowError(self, error);
  }
}

@end
