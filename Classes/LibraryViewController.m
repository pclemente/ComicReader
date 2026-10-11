//  Copyright (C) 2010-2016 Pierre-Olivier Latour <info@pol-online.net>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import <unistd.h>
#import <QuartzCore/QuartzCore.h>

#import "LibraryViewController.h"
#import "ComicViewController.h"
#import "AppDelegate.h"
#import "CRLibrarySyncCoordinator.h"
#import "CRReadingLists.h"
#import "ComicFlow-Swift.h"
#import "Defaults.h"
#import "Extensions_Foundation.h"
#import "Extensions_UIKit.h"
#import "NetReachability.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@class ThumbnailView;

@interface LibraryViewController () <CRWhatsNewBannerDelegate>
- (void)_activateThumbnail:(ThumbnailView*)thumbnail;
- (void)_configureNavigationForCompactWidth:(BOOL)compact;
- (void)_updateCompactSortMenu;
- (void)_openComicFilesCommand:(UIKeyCommand*)command;
- (void)_refreshLibraryCommand:(UIKeyCommand*)command;
@end

@interface CRSettingsScrollView : UIScrollView {
@private
  UIView* _settingsContentView;
  CGSize _settingsContentSize;
}
- (id)initWithSettingsContentView:(UIView*)contentView;
@end

@implementation CRSettingsScrollView

- (id)initWithSettingsContentView:(UIView*)contentView {
  if ((self = [super initWithFrame:contentView.bounds])) {
    _settingsContentView = [contentView retain];
    _settingsContentSize = contentView.bounds.size;
    self.alwaysBounceVertical = YES;
    self.backgroundColor = contentView.backgroundColor;
    if (@available(iOS 11.0, *)) {
      self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self addSubview:_settingsContentView];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  UIEdgeInsets safeInsets = self.safeAreaInsets;
  CGFloat availableWidth = MAX(0.0, CGRectGetWidth(self.bounds) - safeInsets.left - safeInsets.right);
  CGFloat x = safeInsets.left + MAX(0.0, floor((availableWidth - _settingsContentSize.width) / 2.0));
  _settingsContentView.frame = CGRectMake(x, safeInsets.top,
                                          _settingsContentSize.width, _settingsContentSize.height);
  self.contentSize = CGSizeMake(CGRectGetWidth(self.bounds),
                                MAX(CGRectGetHeight(self.bounds) + 1.0,
                                    CGRectGetMaxY(_settingsContentView.frame) + safeInsets.bottom));
}

- (void)dealloc {
  [_settingsContentView release];
  [super dealloc];
}

@end

#define kAppStoreAppID @"1597314495"
#define kiOSAppStoreURLFormat @"itms-apps://itunes.apple.com/WebObjects/MZStore.woa/wa/viewContentsUserReviews?type=Purple+Software&id=%@"
#define kiOS7AppStoreURLFormat @"itms-apps://itunes.apple.com/app/id%@"

#define kBackgroundOffset 6.0

#define kGridMargin 10.0
#define kGridMarginExtra_Portrait 2.0
#define kGridMarginExtra_Landscape 2.0

#define kItemVerticalSpacing 8.0
#define kItemHorizontalSpacing_Portrait 17.0
#define kItemHorizontalSpacing_Landscape 9.0

#define kNewImageX 67.0
#define kNewImageY 6.0
#define kNewImageWidth 60.0
#define kNewImageHeight 60.0

#define kRibbonImageX 67.0
#define kRibbonImageY 6.0
#define kRibbonImageWidth 60.0
#define kRibbonImageHeight 60.0

#define kLaunchCountBeforeRating 10
#define kShowRatingDelay 1.0

#define kUpdateTimerInterval 1.0

#if __DISPLAY_THUMBNAILS_IN_BACKGROUND__
@interface ThumbnailView : UIView
#else
@interface ThumbnailView : UIImageView
#endif
{
@private
  UIView* _noteView;
  UIView* _ribbonView;
  DatabaseObject* _item;
}
@property(nonatomic, assign) UIView* noteView;
@property(nonatomic, assign) UIView* ribbonView;
@property(nonatomic, retain) DatabaseObject* item;
@property(nonatomic, assign) id activationTarget;
@end

@implementation ThumbnailView

@synthesize noteView=_noteView, ribbonView=_ribbonView, item=_item;

- (BOOL) accessibilityActivate {
  return [[UIApplication sharedApplication] sendAction:@selector(_activateThumbnail:) to:self.activationTarget from:self forEvent:nil];
}

- (void) dealloc {
  [_item release];
  [super dealloc];
}

@end

@implementation LibraryViewController

@synthesize gridView=_gridView, navigationBar=_navigationBar, segmentedControl=_segmentedControl, menuView=_menuView,
            markReadButton=_markReadButton, markNewButton=_markNewButton, updateButton=_updateButton,
            forceUpdateButton=_forceUpdateButton, serverControl=_serverControl, addressLabel=_addressLabel,
            infoLabel=_infoLabel, versionLabel=_versionLabel, dimmingSwitch=_dimmingSwitch, purchaseButton=_purchaseButton,
            restoreButton=_restoreButton;

- (void) updatePurchase {
  BOOL enabled = YES;
  _purchaseButton.enabled = enabled;
  _restoreButton.enabled = enabled;
  _plusButtonItem.title = [CRPlusStore sharedStore].isUnlocked ? @"Plus" : @"Get Plus";
}

- (void) _plusEntitlementChanged:(NSNotification*)notification {
  [self updatePurchase];
}

- (void) _updateCompactSortMenu {
  if (!_compactSortButtonItem) return;

  NSArray<NSString*>* fallbackTitles = @[@"By Series", @"By Name", @"By Date", @"By State"];
  NSMutableArray<UIMenuElement*>* actions = [NSMutableArray arrayWithCapacity:4];
  __block LibraryViewController* controller = self;
  for (NSInteger index = 0; index < 4; index++) {
    NSString* title = [_segmentedControl titleForSegmentAtIndex:index] ?: fallbackTitles[index];
    UIAction* action = [UIAction actionWithTitle:title
                                           image:nil
                                      identifier:[NSString stringWithFormat:@"library.sort.%ld", (long)index]
                                         handler:^(UIAction* selectedAction) {
      controller->_segmentedControl.selectedSegmentIndex = index;
      [controller resort:controller->_segmentedControl];
      [controller _updateCompactSortMenu];
    }];
    action.state = (_segmentedControl.selectedSegmentIndex == index ? UIMenuElementStateOn : UIMenuElementStateOff);
    [actions addObject:action];
  }
  _compactSortButtonItem.menu = [UIMenu menuWithTitle:@"Sort Library" children:actions];
}

- (void) _configureNavigationForCompactWidth:(BOOL)compact {
  _usingCompactLayout = compact;
  _adaptiveLayoutConfigured = YES;

  UINavigationItem* rootItem = _navigationBar.items.firstObject;
  if (compact) {
    rootItem.leftBarButtonItem = nil;
    for (UINavigationItem* item in _navigationBar.items) {
      item.rightBarButtonItems = @[_compactSortButtonItem];
    }
    UIBarButtonItem* flexible1 = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                 target:nil action:nil] autorelease];
    UIBarButtonItem* flexible2 = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                 target:nil action:nil] autorelease];
    UIBarButtonItem* flexible3 = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                 target:nil action:nil] autorelease];
    _compactToolbar.items = @[_readingListsButtonItem, flexible1, _cloudButtonItem, flexible2,
                              _plusButtonItem, flexible3, _settingsButtonItem];
    _compactToolbar.hidden = NO;
    [self _updateCompactSortMenu];
  } else {
    _compactToolbar.items = nil;
    _compactToolbar.hidden = YES;
    rootItem.leftBarButtonItem = _sortBarButtonItem;
    NSArray* rightItems = @[_settingsButtonItem, _plusButtonItem, _cloudButtonItem, _readingListsButtonItem];
    for (UINavigationItem* item in _navigationBar.items) {
      item.rightBarButtonItems = rightItems;
    }
  }
}

- (void) _updateStatistics {
  NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[LibraryConnection libraryDatabasePath]
                                                                              error:nil];
  _infoLabel.text = [NSString stringWithFormat:NSLocalizedString(@"INFO_FORMAT", nil),
                                               [[LibraryConnection mainConnection] countObjectsOfClass:[Comic class]],
                                               [[LibraryConnection mainConnection] countObjectsOfClass:[ComicCollection class]],
                                               ceil((double)[attributes fileSize] / (1024.0 * 1024.0))];
}

- (void) _updateTimer:(NSTimer*)timer {
  if (timer == nil) {
    _serverControl.selectedSegmentIndex = [[WebServer sharedWebServer] type];
  }
  _addressLabel.text = [[WebServer sharedWebServer] addressLabel];
  _addressLabel.textColor = [[WebServer sharedWebServer] type] != kWebServerType_Off ? [UIColor darkGrayColor] : [UIColor grayColor];
}

#if __DISPLAY_THUMBNAILS_IN_BACKGROUND__

// Called from main thread or display thread
static void __DisplayQueueApplierFunction(const void* key, const void* value, void* context) {
  ThumbnailView* view = (ThumbnailView*)key;
  DatabaseObject* item = (DatabaseObject*)value;
  void** params = (void**)context;
  UIImage* image = nil;
#if __STORE_THUMBNAILS_IN_DATABASE__
  DatabaseSQLRowID rowID = [(id)item thumbnail];
  if (rowID > 0) {
    Thumbnail* thumbnail = [(LibraryConnection*)params[1] fetchObjectOfClass:[Thumbnail class] withSQLRowID:rowID];
    image = [[UIImage alloc] initWithData:thumbnail.data];
  }
#else
  NSString* name = [(id)item thumbnail];
  if (name) {
    NSString* path = [(NSString*)params[1] stringByAppendingPathComponent:name];
    image = [[UIImage alloc] initWithContentsOfFile:path];
  }
#endif
  if (image) {
    if (params[0]) {
      [CATransaction begin];
    }
    view.layer.contents = (id)[image CGImage];
    if (params[0]) {
      [CATransaction commit];
    }
    [image release];
  }
}

// Called from main thread or display thread
- (void) _processDisplayQueue:(BOOL)inBackground {
#if __STORE_THUMBNAILS_IN_DATABASE__
  void** params[] = {inBackground ? (void*)self : NULL,
                     inBackground ? (void*)_displayConnection : (void*)[LibraryConnection mainConnection]};
#else
  void** params[] = {inBackground ? (void*)self : NULL, [LibraryConnection libraryApplicationDataPath]};
#endif
  while (1) {
    CFDictionaryRef dictionary = NULL;
    
    pthread_mutex_lock(&_displayMutex);
    if (CFArrayGetCount(_displayQueue)) {
      dictionary = CFRetain(CFArrayGetValueAtIndex(_displayQueue, 0));
      CFArrayRemoveValueAtIndex(_displayQueue, 0);
    }
    pthread_mutex_unlock(&_displayMutex);
    
    if (dictionary) {
      NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
      CFDictionaryApplyFunction(dictionary, __DisplayQueueApplierFunction, params);
      [pool release];
      CFRelease(dictionary);
    } else {
      break;
    }
  }
}

// Called from display thread
static void __DisplayQueueCallBack(void* info) {
  [(LibraryViewController*)info _processDisplayQueue:YES];
}

- (void) _displayQueueThread:(id)argument {
  _displayRunLoop = CFRunLoopGetCurrent();
  CFRunLoopAddSource(_displayRunLoop, _displaySource, kCFRunLoopCommonModes);
  CFRunLoopRun();
}

#endif

- (id) initWithWindow:(UIWindow*)window {
  if ((self = [super init])) {
    _window = window;
    _releaseNewsDismissed = [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultKey_ReleaseNewsDismissed];
    
    _comicImage = [[UIImage imageNamed: @"Comic-Background"] retain];
    XLOG_CHECK(_comicImage);
    _collectionImage = [[UIImage imageNamed: @"Collection-Background"] retain];
    XLOG_CHECK(_collectionImage);
    _newImage = [[UIImage imageNamed: @"New"] retain];
    XLOG_CHECK(_newImage);
    _ribbonImage = [[UIImage imageNamed: @"Ribbon"] retain];
    XLOG_CHECK(_ribbonImage);
    
    DatabaseSQLRowID collectionID = (int)[[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_CurrentCollection];
    if (collectionID) {
      _currentCollection = [[[LibraryConnection mainConnection] fetchObjectOfClass:[ComicCollection class] withSQLRowID:collectionID] retain];
    }
    DatabaseSQLRowID comicID = (int)[[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_CurrentComic];
    if (comicID) {
      _currentComic = [[[LibraryConnection mainConnection] fetchObjectOfClass:[Comic class] withSQLRowID:comicID] retain];
    }
    
#if __DISPLAY_THUMBNAILS_IN_BACKGROUND__
#if __STORE_THUMBNAILS_IN_DATABASE__
    _displayConnection = [[LibraryConnection alloc] initWithDatabaseAtPath:[LibraryConnection libraryDatabasePath]];
    XLOG_CHECK(_displayConnection);
#endif
    pthread_mutexattr_t attributes;
    pthread_mutexattr_init(&attributes);
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&_displayMutex, &attributes);
    pthread_mutexattr_destroy(&attributes);
    _displayQueue = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    CFRunLoopSourceContext context = {0, self, NULL, NULL, NULL, NULL, NULL, NULL, NULL, __DisplayQueueCallBack};
    _displaySource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
    [NSThread detachNewThreadSelector:@selector(_displayQueueThread:) toTarget:self withObject:nil];
    do {
      usleep(100000);  // Make sure background thread has started
    } while (_displayRunLoop == NULL);
#endif
  }
  return self;
}

- (BOOL) canBecomeFirstResponder {
  return YES;
}

- (NSArray<UIKeyCommand*>*) keyCommands {
  UIKeyCommand* open = [UIKeyCommand keyCommandWithInput:@"o"
                                           modifierFlags:UIKeyModifierCommand
                                                  action:@selector(_openComicFilesCommand:)];
  open.discoverabilityTitle = @"Open Comic Files";
  UIKeyCommand* refresh = [UIKeyCommand keyCommandWithInput:@"r"
                                              modifierFlags:UIKeyModifierCommand
                                                     action:@selector(_refreshLibraryCommand:)];
  refresh.discoverabilityTitle = @"Refresh Library";
  return @[open, refresh];
}

- (void) _openComicFilesCommand:(UIKeyCommand*)command {
  if (!self.presentedViewController) {
    [self purchase:nil];
  }
}

- (void) _refreshLibraryCommand:(UIKeyCommand*)command {
  if (!self.presentedViewController && ![[LibraryUpdater sharedUpdater] isUpdating]) {
    [self update:nil];
  }
}

- (void) _toggleMenu:(id)sender {
  if (self.presentedViewController == _menuViewController) {
    [self dismissViewControllerAnimated:YES completion:^{
      [self->_updateTimer setFireDate:[NSDate distantFuture]];
    }];
  } else if (self.presentedViewController == nil) {
    [self _updateTimer:nil];
    [self _updateStatistics];
    [self updatePurchase];
    _menuViewController.modalPresentationStyle = UIModalPresentationPopover;
    _menuViewController.preferredContentSize = _menuView.frame.size;
    UIPopoverPresentationController* pc = _menuViewController.popoverPresentationController;
    pc.barButtonItem = (UIBarButtonItem*)sender;
    pc.permittedArrowDirections = _usingCompactLayout ? UIPopoverArrowDirectionDown : UIPopoverArrowDirectionUp;
    pc.delegate = self;
    [self presentViewController:_menuViewController animated:YES completion:nil];
    [_updateTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:kUpdateTimerInterval]];
  }
}

- (void) _tap:(UITapGestureRecognizer*)recognizer {
  if (recognizer.state == UIGestureRecognizerStateEnded) {
    DatabaseObject* item = [_gridView itemAtLocation:[recognizer locationInView:_gridView] view:NULL];
    if ([item isKindOfClass:[Comic class]]) {
      [self _presentComic:(Comic*)item];
    } else if ([item isKindOfClass:[ComicCollection class]]) {
      [self gridViewDidUpdateScrollingAmount:nil];
      [self _setCurrentCollection:(ComicCollection*)item];
    }
  }
}

- (void) _activateThumbnail:(ThumbnailView*)view {
  if (self.presentedViewController) return;
  if ([view.item isKindOfClass:[Comic class]]) {
    [self _presentComic:(Comic*)view.item];
  } else if ([view.item isKindOfClass:[ComicCollection class]]) {
    [self gridViewDidUpdateScrollingAmount:nil];
    [self _setCurrentCollection:(ComicCollection*)view.item];
  }
}

- (void) _updateThumbnailViewForItem:(DatabaseObject*)item {
  ThumbnailView* view = (ThumbnailView*)[_gridView viewForItem:item];
  if (view && !view.hidden) {
    NSInteger status = ([item isKindOfClass:[Comic class]] ? [(Comic*)item status] : [(ComicCollection*)item status]);
    [view.noteView removeFromSuperview];
    [view.ribbonView removeFromSuperview];
    if (status > 0) {
      UIImageView* subview = [[UIImageView alloc] initWithImage:_ribbonImage];
      subview.frame = CGRectMake(kRibbonImageX, kRibbonImageY, kRibbonImageWidth, kRibbonImageHeight);
      [view addSubview:subview];
      [subview release];
      view.noteView = nil;
      view.ribbonView = subview;
    } else if (status < 0) {
      UIImageView* subview = [[UIImageView alloc] initWithImage:_newImage];
      subview.frame = CGRectMake(kNewImageX, kNewImageY, kNewImageWidth, kNewImageHeight);
      [view addSubview:subview];
      [subview release];
      view.noteView = subview;
      view.ribbonView = nil;
    } else {
      view.noteView = nil;
      view.ribbonView = nil;
    }
  }
}

- (void) _setStatus:(int)status forItem:(DatabaseObject*)item {
  if ([item isKindOfClass:[Comic class]]) {
    [[CRLibrarySyncCoordinator sharedCoordinator] markComics:@[item] status:status];
    [self _updateThumbnailViewForItem:item];
    if ([[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_SortingMode] == kSortingMode_ByStatus) {
      [self _reloadCurrentCollection];
    }
  } else if ([item isKindOfClass:[ComicCollection class]]) {
    [[CRLibrarySyncCoordinator sharedCoordinator] markComics:[[LibraryConnection mainConnection] fetchComicsInCollection:(ComicCollection*)item] status:status];
    [[LibraryConnection mainConnection] refetchObject:item];
    [self _updateThumbnailViewForItem:item];
  }
}

- (void) _cloudReadingChanged:(NSNotification*)notification {
  [self _reloadCurrentCollection];
}

- (void) _showPlus:(id)sender {
  if (self.presentedViewController || self.isBeingPresented || self.isBeingDismissed) {
    return;
  }
  CRPlusViewController* controller = [[CRPlusViewController alloc] init];
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:controller];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:navigation animated:YES completion:nil];
  [controller release];
  [navigation release];
}

- (void) _showReadingLists:(id)sender {
  if (self.presentedViewController || self.isBeingPresented || self.isBeingDismissed) return;
  CRReadingListsViewController* controller = [[CRReadingListsViewController alloc]
    initWithLibraryConnection:[LibraryConnection mainConnection]
    openComicHandler:^(Comic* comic, UIViewController* source) {
      self->_startupPresentationsPending = NO;
      NSString* path = [[LibraryConnection mainConnection] pathForComic:comic];
      NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
      [self dismissViewControllerAnimated:YES completion:^{
        BOOL valid = [[LibraryConnection mainConnection] refetchObject:comic] &&
          [path isEqualToString:[[LibraryConnection mainConnection] pathForComic:comic]];
        NSDictionary* current = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        for (NSString* key in @[NSFileSystemNumber, NSFileSystemFileNumber, NSFileSize, NSFileModificationDate]) {
          valid = valid && attributes[key] && [attributes[key] isEqual:current[key]];
        }
        if (valid) {
          [self _presentComic:comic];
        } else {
          [[AppDelegate sharedDelegate] showAlertWithTitle:@"Comic Unavailable" message:@"The comic changed or was removed. Please select it again from your library." button:@"OK"];
        }
      }];
    }];
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:controller];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:navigation animated:YES completion:nil];
  [controller release];
  [navigation release];
}

- (void) _showCloud:(id)sender {
  if (self.presentedViewController || self.isBeingPresented || self.isBeingDismissed) return;
  CRPlusViewController* controller = [[CRPlusViewController alloc] init];
  controller.showsOnlyCloud = YES;
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:controller];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:navigation animated:YES completion:nil];
  [controller release];
  [navigation release];
}

- (void) whatsNewDidDismiss {
  _releaseNewsDismissed = YES;
  [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kDefaultKey_ReleaseNewsDismissed];
  _whatsNewBanner.hidden = YES;
  [self.view setNeedsLayout];
}

- (void) whatsNewDidRequestCloud {
  [self whatsNewDidDismiss];
  [self _showCloud:nil];
}

- (void) whatsNewDidRequestPlus {
  [self whatsNewDidDismiss];
  [self _showPlus:nil];
}

- (void) _setReadForItem:(DatabaseObject*)item {
  [self _setStatus:0 forItem:item];
  [[AppDelegate sharedDelegate] logEvent:@"menu.read"];
}

- (void) _setNewForItem:(DatabaseObject*)item {
  [self _setStatus:-1 forItem:item];
  [[AppDelegate sharedDelegate] logEvent:@"menu.new"];
}

- (void) _deleteItem:(DatabaseObject*)item {
  if ([item isKindOfClass:[Comic class]]) {
    NSString* path = [[LibraryConnection mainConnection] pathForComic:(Comic*)item];
    NSError* error = nil;
    if ([[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
      [[CRLibrarySyncCoordinator sharedCoordinator] didDeleteComics:@[item] paths:@[path]];
      [(AppDelegate*)[AppDelegate sharedInstance] updateLibrary];
    } else {
      XLOG_ERROR(@"Failed deleting comic \"%@\": %@", [(Comic*)item name], error);
    }
  } else if ([item isKindOfClass:[ComicCollection class]]) {
    NSArray* comics = [[LibraryConnection mainConnection] fetchComicsInCollection:(ComicCollection*)item];
    NSMutableArray* paths = [NSMutableArray array];
    for (Comic* comic in comics) [paths addObject:[[LibraryConnection mainConnection] pathForComic:comic]];
    NSError* error = nil;
    if ([[NSFileManager defaultManager] removeItemAtPath:[[LibraryConnection mainConnection] pathForCollection:(ComicCollection*)item] error:&error]) {
      [[CRLibrarySyncCoordinator sharedCoordinator] didDeleteComics:comics paths:paths];
      [(AppDelegate*)[AppDelegate sharedInstance] updateLibrary];
    } else {
      XLOG_ERROR(@"Failed deleting collection \"%@\": %@", [(ComicCollection*)item name], error);
    }
  }
  [[AppDelegate sharedDelegate] logEvent:@"menu.delete"];
}

- (UIContextMenuConfiguration*) contextMenuInteraction:(UIContextMenuInteraction*)interaction
                            configurationForMenuAtLocation:(CGPoint)location {
  if (![interaction.view isKindOfClass:[ThumbnailView class]]) {
    return nil;
  }

  DatabaseObject* selectedItem = [((ThumbnailView*)interaction.view).item retain];
  BOOL isComic = [selectedItem isKindOfClass:[Comic class]];
  if (!isComic && ![selectedItem isKindOfClass:[ComicCollection class]]) {
    [selectedItem release];
    return nil;
  }

  NSInteger status = (isComic ? [(Comic*)selectedItem status] : [(ComicCollection*)selectedItem status]);
  NSString* identifier = [NSString stringWithFormat:@"%@:%i", isComic ? @"Comic" : @"Collection", selectedItem.sqlRowID];
  UIContextMenuConfiguration* configuration = [UIContextMenuConfiguration configurationWithIdentifier:identifier
                                                                                       previewProvider:nil
                                                                                        actionProvider:^UIMenu* (NSArray<UIMenuElement*>* suggestedActions) {
    NSMutableArray<UIMenuElement*>* actions = [NSMutableArray array];
    if (status != 0) {
      UIAction* read = [UIAction actionWithTitle:NSLocalizedString(isComic ? @"MARK_READ" : @"MARK_ALL_READ", nil)
                                           image:[UIImage systemImageNamed:@"checkmark.circle"]
                                      identifier:nil
                                         handler:^(UIAction* action) { [self _setReadForItem:selectedItem]; }];
      [actions addObject:read];
    }
    if (status >= 0) {
      UIAction* markNew = [UIAction actionWithTitle:NSLocalizedString(isComic ? @"MARK_NEW" : @"MARK_ALL_NEW", nil)
                                              image:[UIImage systemImageNamed:@"sparkles"]
                                         identifier:nil
                                            handler:^(UIAction* action) { [self _setNewForItem:selectedItem]; }];
      [actions addObject:markNew];
    }
    UIAction* delete = [UIAction actionWithTitle:([[CRCloudSyncManager sharedManager] optedIn] ? @"Remove from This Device" : NSLocalizedString(isComic ? @"DELETE" : @"DELETE_ALL", nil))
                                           image:[UIImage systemImageNamed:@"trash"]
                                      identifier:nil
                                         handler:^(UIAction* action) { [self _deleteItem:selectedItem]; }];
    delete.attributes = UIMenuElementAttributesDestructive;
    [actions addObject:delete];
    return [UIMenu menuWithTitle:@"" children:actions];
  }];
  [selectedItem release];
  return configuration;
}

- (UITargetedPreview*) _contextMenuPreviewForInteraction:(UIContextMenuInteraction*)interaction {
  if (![interaction.view isKindOfClass:[ThumbnailView class]] || interaction.view.window == nil) {
    return nil;
  }
  return [[[UITargetedPreview alloc] initWithView:interaction.view] autorelease];
}

- (UITargetedPreview*) contextMenuInteraction:(UIContextMenuInteraction*)interaction
                                configuration:(UIContextMenuConfiguration*)configuration
        highlightPreviewForItemWithIdentifier:(id<NSCopying>)identifier API_AVAILABLE(ios(16.0)) {
  return [self _contextMenuPreviewForInteraction:interaction];
}

- (UITargetedPreview*) contextMenuInteraction:(UIContextMenuInteraction*)interaction
                                configuration:(UIContextMenuConfiguration*)configuration
        dismissalPreviewForItemWithIdentifier:(id<NSCopying>)identifier API_AVAILABLE(ios(16.0)) {
  return [self _contextMenuPreviewForInteraction:interaction];
}

- (UITargetedPreview*) contextMenuInteraction:(UIContextMenuInteraction*)interaction
  previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration*)configuration {
  return [self _contextMenuPreviewForInteraction:interaction];
}

- (UITargetedPreview*) contextMenuInteraction:(UIContextMenuInteraction*)interaction
     previewForDismissingMenuWithConfiguration:(UIContextMenuConfiguration*)configuration {
  return [self _contextMenuPreviewForInteraction:interaction];
}

- (void) viewDidLoad {
  [super viewDidLoad];
  
  if (@available(iOS 13.0, *)) {
    self.view.backgroundColor = [UIColor systemBackgroundColor];
  } else {
    self.view.backgroundColor = [UIColor whiteColor];
  }

  // Grid background (XIB has it red by mistake — fix here)
  _gridView.backgroundColor = [UIColor clearColor];
  
  _gridView.contentBackgroundOffset = CGPointMake(0.0, kBackgroundOffset);
  _gridView.contentBackgroundColor = [UIColor colorWithPatternImage:[UIImage imageWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Background" ofType:@"png"]]];
  _gridView.delegate = self;
  UITapGestureRecognizer* tapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap:)];
  [_gridView addGestureRecognizer:tapRecognizer];
  [tapRecognizer release];
  
  UINavigationItem* item = [_navigationBar.items objectAtIndex:0];
  _sortBarButtonItem = [item.leftBarButtonItem retain];
  _segmentedControl.accessibilityIdentifier = @"library.sort.segmented";
  if (@available(iOS 13.0, *)) {
    UIImage* gearIcon = [UIImage systemImageNamed:@"slider.horizontal.3"];
    _settingsButtonItem = [[UIBarButtonItem alloc] initWithImage:gearIcon
                                                           style:UIBarButtonItemStylePlain
                                                          target:self
                                                          action:@selector(_toggleMenu:)];
  } else {
    _settingsButtonItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"SETTINGS_BUTTON", nil)
                                                           style:UIBarButtonItemStylePlain
                                                          target:self
                                                          action:@selector(_toggleMenu:)];
  }
  _settingsButtonItem.accessibilityIdentifier = @"library.settings";
  _settingsButtonItem.accessibilityLabel = NSLocalizedString(@"SETTINGS_BUTTON", nil);
  _plusButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Get Plus"
                                                     style:UIBarButtonItemStylePlain
                                                    target:self
                                                    action:@selector(_showPlus:)];
  _plusButtonItem.accessibilityIdentifier = @"library.plus";
  _plusButtonItem.accessibilityLabel = @"ComicReader Plus";
  _cloudButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"icloud"]
                                                      style:UIBarButtonItemStylePlain
                                                     target:self
                                                     action:@selector(_showCloud:)];
  _cloudButtonItem.accessibilityIdentifier = @"library.icloud";
  _cloudButtonItem.accessibilityLabel = @"Free iCloud Sync";
  _readingListsButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"list.bullet.rectangle"]
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(_showReadingLists:)];
  _readingListsButtonItem.accessibilityIdentifier = @"library.readingLists";
  _readingListsButtonItem.accessibilityLabel = @"Reading Lists";
  _compactSortButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                            style:UIBarButtonItemStylePlain
                                                           target:nil
                                                           action:nil];
  _compactSortButtonItem.accessibilityIdentifier = @"library.sort";
  _compactSortButtonItem.accessibilityLabel = @"Sort Library";
  _compactToolbar = [[UIToolbar alloc] initWithFrame:CGRectZero];
  _compactToolbar.hidden = YES;
  _compactToolbar.accessibilityIdentifier = @"library.compactToolbar";
  [self.view addSubview:_compactToolbar];
  [self updatePurchase];
  BOOL startsCompact = self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact ||
                       CGRectGetWidth(self.view.bounds) < 600.0;
  [self _configureNavigationForCompactWidth:startsCompact];
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_cloudReadingChanged:) name:@"CRLibraryReadingStateDidChangeNotification" object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_sceneDidActivate:) name:UISceneDidActivateNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_plusEntitlementChanged:)
                                               name:[CRPlusStore entitlementDidChangeNotification]
                                             object:[CRPlusStore sharedStore]];

  _menuViewController = [[UIViewController alloc] init];
  [self _applyMenuTheme];
  CRSettingsScrollView* menuScrollView = [[CRSettingsScrollView alloc] initWithSettingsContentView:_menuView];
  _menuViewController.view = menuScrollView;
  [menuScrollView release];
  [self _buildEmptyStateView];
  if (!_releaseNewsDismissed) {
    CRWhatsNewBannerView* banner = [[CRWhatsNewBannerView alloc] init];
    banner.delegate = self;
    _whatsNewBanner = banner;
    [self.view addSubview:banner];
    [banner release];
  }
  
  _infoLabel.text = nil;
  _versionLabel.text = [NSString stringWithFormat:NSLocalizedString(@"VERSION_FORMAT", nil),
                                                  [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
  BOOL updating = [[LibraryUpdater sharedUpdater] isUpdating];
  _markReadButton.enabled = !updating;
  _markNewButton.enabled = !updating;
  _updateButton.enabled = !updating;
  _forceUpdateButton.enabled = !updating;
  _dimmingSwitch.on = [(AppDelegate*)[AppDelegate sharedInstance] isScreenDimmed];
  _purchaseButton.accessibilityIdentifier = @"library.addFiles";
  
  XLOG_DEBUG_CHECK(_updateTimer == nil);
  _updateTimer = [[NSTimer alloc] initWithFireDate:[NSDate distantFuture] interval:kUpdateTimerInterval target:self selector:@selector(_updateTimer:) userInfo:nil repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
    
}

- (void) _applyMenuTheme {
  // ── Adaptive colours ─────────────────────────────────────────────────────
  UIColor* menuBg;
  UIColor* sectionBg;
  UIColor* secondaryText;
  UIColor* separatorColor;
  UIColor* accentColor;
  UIColor* destructiveColor;

  if (@available(iOS 13.0, *)) {
    menuBg        = [UIColor systemGroupedBackgroundColor];
    sectionBg     = [UIColor secondarySystemGroupedBackgroundColor];
    secondaryText = [UIColor secondaryLabelColor];
    separatorColor = [UIColor separatorColor];
    accentColor   = [UIColor systemBlueColor];
    destructiveColor = [UIColor systemRedColor];
  } else {
    menuBg        = [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0];
    sectionBg     = [UIColor whiteColor];
    secondaryText = [UIColor grayColor];
    separatorColor = [UIColor colorWithWhite:0.80 alpha:1.0];
    accentColor   = [UIColor colorWithRed:0.20 green:0.55 blue:1.00 alpha:1.0];
    destructiveColor = [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1.0];
  }

  _menuView.backgroundColor = menuBg;

  // ── Helper: add separator line beneath a view ─────────────────────────────
  void (^addSeparator)(UIView*, UIColor*) = ^(UIView* below, UIColor* color) {
    CGRect r = below.frame;
    UIView* sep = [[UIView alloc] initWithFrame:CGRectMake(r.origin.x + 12,
                                                            CGRectGetMaxY(r),
                                                            r.size.width - 24, 0.5)];
    sep.backgroundColor = color;
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_menuView addSubview:sep];
    [sep release];
  };

  // ── Section header labels ─────────────────────────────────────────────────
  void (^styleHeader)(UILabel*) = ^(UILabel* lbl) {
    lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    lbl.textColor = secondaryText;
    lbl.text = [lbl.text uppercaseString];
  };

  // ── Style each button ─────────────────────────────────────────────────────
  void (^styleButton)(UIButton*, UIColor*, BOOL) = ^(UIButton* btn, UIColor* tintColor, BOOL isSection) {
    btn.backgroundColor = isSection ? menuBg : sectionBg;
    btn.layer.cornerRadius = isSection ? 0 : 10;
    btn.clipsToBounds = YES;
    [btn setTitleColor:tintColor forState:UIControlStateNormal];
    [btn setTitleColor:secondaryText forState:UIControlStateDisabled];
    btn.titleLabel.font = [UIFont systemFontOfSize:17];
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
  };

  // ── Walk the XIB subviews and apply styles ────────────────────────────────
  for (UIView* v in _menuView.subviews) {
    if ([v isKindOfClass:[UIButton class]]) {
      UIButton* btn = (UIButton*)v;
      if (btn == _forceUpdateButton) {
        styleButton(btn, destructiveColor, NO);
      } else {
        styleButton(btn, accentColor, NO);
      }
      // Add subtle hairline separator beneath each button row
      addSeparator(btn, separatorColor);

    } else if ([v isKindOfClass:[UILabel class]]) {
      UILabel* lbl = (UILabel*)v;
      if (lbl.font.pointSize >= 16) {
        // Section header
        styleHeader(lbl);
      } else {
        // Info / address / version secondary text
        lbl.textColor = secondaryText;
      }

    } else if ([v isKindOfClass:[UISegmentedControl class]]) {
      UISegmentedControl* sc = (UISegmentedControl*)v;
      if (@available(iOS 13.0, *)) {
        sc.selectedSegmentTintColor = accentColor;
        NSDictionary* normal   = @{NSForegroundColorAttributeName: secondaryText};
        NSDictionary* selected = @{NSForegroundColorAttributeName: [UIColor whiteColor],
                                   NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]};
        [sc setTitleTextAttributes:normal   forState:UIControlStateNormal];
        [sc setTitleTextAttributes:selected forState:UIControlStateSelected];
        if (@available(iOS 13.0, *)) {
          sc.backgroundColor = sectionBg;
        }
      } else {
        sc.tintColor = accentColor;
      }
      // Give the web-server control a taller hit target
      if (sc == _serverControl) {
        CGRect f = sc.frame;
        f.size.height = 36;
        sc.frame = f;
      }

    } else if ([v isKindOfClass:[UISwitch class]]) {
      UISwitch* sw = (UISwitch*)v;
      sw.onTintColor = accentColor;
    }
  }

  // ── Group visually – add a card background behind the server section ───────
  UIView* serverCard = [[UIView alloc] initWithFrame:CGRectMake(10,
                                                                 CGRectGetMinY(_serverControl.frame) - 44,
                                                                 300, 44 + _serverControl.frame.size.height + 8)];
  serverCard.backgroundColor = sectionBg;
  serverCard.layer.cornerRadius = 12;
  if (@available(iOS 13.0, *)) {
    serverCard.layer.shadowColor = [UIColor labelColor].CGColor;
  } else {
    serverCard.layer.shadowColor = [UIColor blackColor].CGColor;
  }
  serverCard.layer.shadowOpacity = 0.06;
  serverCard.layer.shadowRadius  = 6;
  serverCard.layer.shadowOffset  = CGSizeMake(0, 2);
  [_menuView insertSubview:serverCard belowSubview:_serverControl];
  [serverCard release];

  // ── Navigation bar: modern translucent style ──────────────────────────────
  if (@available(iOS 15.0, *)) {
    UINavigationBarAppearance* appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithDefaultBackground];
    _navigationBar.standardAppearance = appearance;
    _navigationBar.scrollEdgeAppearance = appearance;
    [appearance release];
  }
}

- (void) _buildEmptyStateView {
  if (_emptyStateView) {
    [_emptyStateView removeFromSuperview];
    [_emptyStateView release];
    _emptyStateView = nil;
  }
  // Positioned over the grid view (below the nav bar) so centering needs no
  // nav-bar offset — frame is kept in sync in viewDidLayoutSubviews.
  _emptyStateView = [[UIView alloc] initWithFrame:_gridView.frame];
  _emptyStateView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _emptyStateView.hidden = !(_gridView.empty && (_currentCollection == nil));

  // ── Scroll view (safety net when content is taller than the screen) ───────
  UIScrollView* scroll = [[UIScrollView alloc] initWithFrame:_emptyStateView.bounds];
  scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  scroll.alwaysBounceVertical = YES;
  if (@available(iOS 11.0, *)) {
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  }
  scroll.tag = 9901;
  [_emptyStateView addSubview:scroll];
  [scroll release];

  // ── Single content view – everything goes in here ─────────────────────────
  CGFloat w = _emptyStateView.bounds.size.width;
  _emptyStateLayoutWidth = w;
  CGFloat cardW = MIN(w - 40, 600);   // cap card width for large iPad Pro
  CGFloat cardX = (w - cardW) / 2.0;

  UIView* contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 0)];
  contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  contentView.tag = 9902;
  [scroll addSubview:contentView];

  CGFloat y = 0;

  // ── Icon ──────────────────────────────────────────────────────────────────
  UIImageView* iconView;
  if (@available(iOS 13.0, *)) {
    UIImageSymbolConfiguration* cfg = [UIImageSymbolConfiguration configurationWithPointSize:96
                                                                                      weight:UIImageSymbolWeightThin
                                                                                       scale:UIImageSymbolScaleLarge];
    UIImage* icon = [UIImage systemImageNamed:@"books.vertical" withConfiguration:cfg];
    iconView = [[UIImageView alloc] initWithImage:icon];
    iconView.tintColor = [UIColor tertiaryLabelColor];
  } else {
    iconView = [[UIImageView alloc] init];
    iconView.frame = CGRectMake(0, 0, 96, 96);
  }
  iconView.contentMode = UIViewContentModeScaleAspectFit;
  iconView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
  CGFloat iconSize = 110;
  iconView.frame = CGRectMake((w - iconSize) / 2.0, y, iconSize, iconSize);
  [contentView addSubview:iconView];
  [iconView release];
  y = CGRectGetMaxY(iconView.frame) + 20;

  // ── Title ─────────────────────────────────────────────────────────────────
  UILabel* titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(cardX, y, cardW, 0)];
  titleLabel.text = @"Your Library is Empty";
  titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
  titleLabel.textAlignment = NSTextAlignmentCenter;
  titleLabel.numberOfLines = 0;
  titleLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
  if (@available(iOS 13.0, *)) {
    titleLabel.textColor = [UIColor labelColor];
  } else {
    titleLabel.textColor = [UIColor darkTextColor];
  }
  [titleLabel sizeToFit];
  titleLabel.frame = CGRectMake((w - titleLabel.frame.size.width) / 2.0, y,
                                 titleLabel.frame.size.width, titleLabel.frame.size.height);
  [contentView addSubview:titleLabel];
  y = CGRectGetMaxY(titleLabel.frame) + 8;
  [titleLabel release];

  // ── Subtitle ──────────────────────────────────────────────────────────────
  UILabel* subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(cardX, y, cardW, 0)];
  subtitleLabel.text = @"Add .cbz, .cbr or .pdf comics using any of the methods below.";
  subtitleLabel.font = [UIFont systemFontOfSize:17];
  subtitleLabel.textAlignment = NSTextAlignmentCenter;
  subtitleLabel.numberOfLines = 0;
  subtitleLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
  if (@available(iOS 13.0, *)) {
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
  } else {
    subtitleLabel.textColor = [UIColor grayColor];
  }
  [subtitleLabel sizeToFit];
  subtitleLabel.frame = CGRectMake((w - cardW) / 2.0, y, cardW, subtitleLabel.frame.size.height);
  [contentView addSubview:subtitleLabel];
  y = CGRectGetMaxY(subtitleLabel.frame) + 32;
  [subtitleLabel release];

  // ── Step cards ────────────────────────────────────────────────────────────
  UIColor* cardBg;
  UIColor* stepTitleColor;
  UIColor* stepBodyColor;
  UIColor* accentColor;
  if (@available(iOS 13.0, *)) {
    cardBg         = [UIColor secondarySystemGroupedBackgroundColor];
    stepTitleColor = [UIColor labelColor];
    stepBodyColor  = [UIColor secondaryLabelColor];
    accentColor    = [UIColor systemBlueColor];
  } else {
    cardBg         = [UIColor whiteColor];
    stepTitleColor = [UIColor darkTextColor];
    stepBodyColor  = [UIColor grayColor];
    accentColor    = [UIColor colorWithRed:0.20 green:0.55 blue:1.00 alpha:1.0];
  }

  struct { NSString* symbol; NSString* title; NSString* body; } steps[] = {
#if TARGET_OS_MACCATALYST
    { @"folder",
      @"Import from Finder",
      @"Choose Add Files in Settings or press ⌘O. Select any .cbz, .cbr or .pdf comic." },
    { @"icloud",
      @"Free iCloud Sync",
      @"Turn on iCloud Sync to keep comic files and reading progress available across your iPhone, iPad and Mac. No Plus purchase is needed." },
    { @"wifi",
      @"Wi-Fi Upload",
      @"Open Settings, enable the Web Server, then visit the displayed address in a browser to drag and drop files." },
#else
    { @"square.and.arrow.down",
      @"Files App",
      @"Choose Add Files in Settings, then browse the Files app and pick any comic file." },
    { @"wifi",
      @"Wi-Fi Upload",
      @"Open Settings, enable the Web Server, then visit the URL in a browser on your Mac or PC to drag and drop files." },
    { @"arrow.down.to.line",
      @"iTunes / Finder",
      @"Connect your iPhone or iPad via USB. In Finder (or iTunes on Windows) select ComicReader under File Sharing and drag comics in." },
#endif
  };

  NSUInteger stepCount = sizeof(steps) / sizeof(steps[0]);
  for (NSUInteger i = 0; i < stepCount; i++) {
    UIView* card = [[UIView alloc] initWithFrame:CGRectMake(cardX, y, cardW, 0)];
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    card.backgroundColor = cardBg;
    card.layer.cornerRadius = 14;
    card.layer.masksToBounds = YES;

    // Numbered badge
    UIView* badge = [[UIView alloc] initWithFrame:CGRectMake(16, 16, 36, 36)];
    badge.backgroundColor = accentColor;
    badge.layer.cornerRadius = 18;
    UILabel* numLabel = [[UILabel alloc] initWithFrame:badge.bounds];
    numLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
    numLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    numLabel.textColor = [UIColor whiteColor];
    numLabel.textAlignment = NSTextAlignmentCenter;
    [badge addSubview:numLabel];
    [numLabel release];
    [card addSubview:badge];
    [badge release];

    // SF Symbol icon (right side)
    if (@available(iOS 13.0, *)) {
      UIImageSymbolConfiguration* cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
      UIImage* img = [UIImage systemImageNamed:steps[i].symbol withConfiguration:cfg];
      UIImageView* symView = [[UIImageView alloc] initWithImage:img];
      symView.tintColor = accentColor;
      symView.frame = CGRectMake(cardW - 48, 22, 26, 26);
      [card addSubview:symView];
      [symView release];
    }

    // Text
    CGFloat textX = 68;
    CGFloat textW = cardW - textX - 56;
    UILabel* stepTitle = [[UILabel alloc] initWithFrame:CGRectMake(textX, 14, textW, 0)];
    stepTitle.text = steps[i].title;
    stepTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    stepTitle.textColor = stepTitleColor;
    stepTitle.numberOfLines = 1;
    [stepTitle sizeToFit];
    stepTitle.frame = CGRectMake(textX, 14, textW, stepTitle.frame.size.height);
    [card addSubview:stepTitle];

    UILabel* stepBody = [[UILabel alloc] initWithFrame:CGRectMake(textX, CGRectGetMaxY(stepTitle.frame) + 4, textW, 0)];
    stepBody.text = steps[i].body;
    stepBody.font = [UIFont systemFontOfSize:14];
    stepBody.textColor = stepBodyColor;
    stepBody.numberOfLines = 0;
    [stepBody sizeToFit];
    stepBody.frame = CGRectMake(textX, CGRectGetMaxY(stepTitle.frame) + 4, textW, stepBody.frame.size.height);
    [card addSubview:stepBody];

    [stepTitle release];
    [stepBody release];

    CGFloat cardH = CGRectGetMaxY(stepBody.frame) + 16;
    card.frame = CGRectMake(cardX, y, cardW, cardH);
    [contentView addSubview:card];
    [card release];
    y += cardH + 10;
  }

  // ── Footer hint ───────────────────────────────────────────────────────────
  y += 4;
  UILabel* hint = [[UILabel alloc] initWithFrame:CGRectMake(cardX, y, cardW, 0)];
  hint.text = @"Need free comics? Visit digitalcomicmuseum.com";
  hint.font = [UIFont systemFontOfSize:13];
  hint.textAlignment = NSTextAlignmentCenter;
  hint.numberOfLines = 0;
  hint.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
  if (@available(iOS 13.0, *)) {
    hint.textColor = [UIColor tertiaryLabelColor];
  } else {
    hint.textColor = [UIColor lightGrayColor];
  }
  [hint sizeToFit];
  hint.frame = CGRectMake((w - cardW) / 2.0, y, cardW, hint.frame.size.height);
  [contentView addSubview:hint];
  y = CGRectGetMaxY(hint.frame);
  [hint release];

  // Seal contentView height and scroll contentSize
  contentView.frame = CGRectMake(0, 0, w, y);
  scroll.contentSize = CGSizeMake(w, y);
  [contentView release];

  [_gridView.superview insertSubview:_emptyStateView aboveSubview:_gridView];
}

- (void) _centerEmptyStateContent {
  if (!_emptyStateView) return;
  UIScrollView* scroll = (UIScrollView*)[_emptyStateView viewWithTag:9901];
  UIView* contentView  = [_emptyStateView viewWithTag:9902];
  if (!scroll || !contentView) return;

  // _emptyStateView.frame == _gridView.frame (set in viewDidLayoutSubviews),
  // so scroll.bounds.size.height is exactly the visible area below the nav bar.
  CGFloat availH   = scroll.bounds.size.height;
  CGFloat contentH = contentView.frame.size.height;
  contentView.frame = CGRectMake(0.0, 0.0, scroll.bounds.size.width, contentH);
  scroll.contentSize = CGSizeMake(scroll.bounds.size.width, contentH);
  CGFloat topInset = MAX(0.0, floor((availH - contentH) / 2.0));
  scroll.contentInset = UIEdgeInsetsMake(topInset, 0, 0, 0);
}

- (void) viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];

  CGRect safeBounds = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
  BOOL isLandscape = CGRectGetWidth(safeBounds) > CGRectGetHeight(safeBounds);
  BOOL isCompact = self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact ||
                   CGRectGetWidth(safeBounds) < 600.0;
  if (!_adaptiveLayoutConfigured || isCompact != _usingCompactLayout) {
    [self _configureNavigationForCompactWidth:isCompact];
  }

  CGFloat navigationHeight = 44.0;
  _navigationBar.frame = CGRectMake(CGRectGetMinX(safeBounds), CGRectGetMinY(safeBounds),
                                    CGRectGetWidth(safeBounds), navigationHeight);
  CGFloat contentBottom = CGRectGetMaxY(safeBounds);
  if (isCompact) {
    CGFloat toolbarHeight = 44.0;
    _compactToolbar.frame = CGRectMake(CGRectGetMinX(self.view.bounds), contentBottom - toolbarHeight,
                                       CGRectGetWidth(self.view.bounds),
                                       toolbarHeight + self.view.safeAreaInsets.bottom);
    contentBottom = CGRectGetMinY(_compactToolbar.frame);
  }

  CGFloat contentTop = CGRectGetMaxY(_navigationBar.frame);
  BOOL showBanner = _whatsNewBanner && !_releaseNewsDismissed && !(isCompact && isLandscape);
  if (_whatsNewBanner) _whatsNewBanner.hidden = !showBanner;
  if (showBanner) {
    CGFloat width = MAX(1, CGRectGetWidth(safeBounds) - 20);
    CGFloat height = [(CRWhatsNewBannerView*)_whatsNewBanner preferredHeightForWidth:width];
    height = MIN(height, MAX(130, CGRectGetHeight(safeBounds) * 0.45));
    _whatsNewBanner.frame = CGRectMake(CGRectGetMinX(safeBounds) + 10, contentTop + 6, width, height);
    contentTop = CGRectGetMaxY(_whatsNewBanner.frame) + 6;
  }
  _gridView.frame = CGRectMake(CGRectGetMinX(safeBounds), contentTop,
                               CGRectGetWidth(safeBounds),
                               MAX(0.0, contentBottom - contentTop));

  if (isCompact) {
    CGFloat width = CGRectGetWidth(_gridView.bounds);
    CGFloat minimumGap = isLandscape ? 12.0 : 16.0;
    CGFloat availableWidth = MAX(0.0, width - 2.0 * kGridMargin);
    NSUInteger columns = MAX(1, (NSUInteger)floor((availableWidth + minimumGap) /
                                                  (kLibraryThumbnailWidth + minimumGap)));
    CGFloat gap = 0.0;
    if (columns > 1) {
      CGFloat maximumGap = (availableWidth - columns * kLibraryThumbnailWidth) / (columns - 1);
      gap = MAX(0.0, MIN(isLandscape ? 16.0 : 20.0, maximumGap));
    }
    CGFloat groupWidth = columns * kLibraryThumbnailWidth + (columns - 1) * gap;
    CGFloat leftMargin = MAX(kGridMargin, floor((width - groupWidth) / 2.0));
    CGFloat rightMargin = MAX(kGridMargin, width - groupWidth - leftMargin);
    _gridView.contentMargins = UIEdgeInsetsMake(kGridMargin, leftMargin, kGridMargin, rightMargin);
    _gridView.itemSpacing = UIEdgeInsetsMake(0.0, 0.0, kItemVerticalSpacing, gap);
  } else {
    _gridView.contentMargins = UIEdgeInsetsMake(kGridMargin,
                                                kGridMargin + (isLandscape ? kGridMarginExtra_Landscape : kGridMarginExtra_Portrait),
                                                kGridMargin,
                                                kGridMargin);
    _gridView.itemSpacing = UIEdgeInsetsMake(0.0, 0.0, kItemVerticalSpacing,
                                             isLandscape ? kItemHorizontalSpacing_Landscape : kItemHorizontalSpacing_Portrait);
  }
  [_gridView setNeedsLayout];

  // Keep the empty-state overlay exactly over the grid (below the nav bar).
  if (fabs(_emptyStateLayoutWidth - CGRectGetWidth(_gridView.bounds)) > 0.5) {
    [self _buildEmptyStateView];
  }
  if (_emptyStateView) {
    _emptyStateView.frame = _gridView.frame;
    UIScrollView* scroll = (UIScrollView*)[_emptyStateView viewWithTag:9901];
    if (scroll) scroll.frame = _emptyStateView.bounds;
  }
  [self _centerEmptyStateContent];
}

- (void) _updateEmptyStateVisibility {
  BOOL showEmpty = _gridView.empty && (_currentCollection == nil);
  if (_emptyStateView) {
    if (showEmpty != !_emptyStateView.hidden) {
      if (showEmpty) {
        _emptyStateView.hidden = NO;
        _emptyStateView.alpha  = 0.0;
        [self _centerEmptyStateContent];
      }
      [UIView animateWithDuration:0.3 animations:^{
        self->_emptyStateView.alpha = showEmpty ? 1.0 : 0.0;
      } completion:^(BOOL finished) {
        self->_emptyStateView.hidden = !showEmpty;
        self->_emptyStateView.alpha  = 1.0;
      }];
    }
  }
}

- (void) _reloadCurrentCollection {
  XLOG_VERBOSE(@"Reloading current collection");
  NSInteger scrolling = _currentCollection ? _currentCollection.scrolling
                                           : [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_RootScrolling];
  if ((scrolling < 0) || (scrolling == NSNotFound)) {
    scrolling = 0;
  }
  
  NSArray* items = nil;
  switch ([[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_SortingMode]) {  // Setting "selectedSegmentIndex" will call the action
    
    case kSortingMode_ByName: {
      _segmentedControl.selectedSegmentIndex = 1;
      items = [[LibraryConnection mainConnection] fetchAllComicsByName];
      break;
    }
    
    case kSortingMode_ByDate: {
      _segmentedControl.selectedSegmentIndex = 2;
      items = [[LibraryConnection mainConnection] fetchAllComicsByDate];
      break;
    }
    
    case kSortingMode_ByStatus: {
      _segmentedControl.selectedSegmentIndex = 3;
      items = [[LibraryConnection mainConnection] fetchAllComicsByStatus];
      break;
    }
    
    default: {  // kSortingMode_ByCollection
      _segmentedControl.selectedSegmentIndex = 0;
      if (_currentCollection) {
        items = [[LibraryConnection mainConnection] fetchComicsInCollection:_currentCollection];
      } else {
        items = [[LibraryConnection mainConnection] fetchAllCollectionsByName];
      }
      break;
    }
    
  }
#if __DISPLAY_THUMBNAILS_IN_BACKGROUND__
  pthread_mutex_lock(&_displayMutex);
  CFArrayRemoveAllValues(_displayQueue);
  _gridView.items = nil;
  _gridView.extraVisibleRows = 0;
#endif
  _gridView.scrollingAmount = scrolling;
  _gridView.items = items;
#if __DISPLAY_THUMBNAILS_IN_BACKGROUND__
  [self _processDisplayQueue:NO];  // Display immediately
  pthread_mutex_unlock(&_displayMutex);
  _gridView.extraVisibleRows = 6;
#endif
  [self _updateEmptyStateVisibility];
  [self _updateCompactSortMenu];
}

- (void) _setCurrentCollection:(ComicCollection*)collection {
  NSMutableArray* barItems = [[NSMutableArray alloc] initWithArray:_navigationBar.items];
  if (barItems.count == 2) {
    [barItems removeObjectAtIndex:1];
  }
  if (collection) {
    UINavigationItem* item = [[UINavigationItem alloc] initWithTitle:collection.name];
    item.rightBarButtonItems = [(UINavigationItem*)barItems.firstObject rightBarButtonItems];
    [barItems addObject:item];
    [item release];
  }
  _navigationBar.items = barItems;
  [barItems release];
  [self _configureNavigationForCompactWidth:_usingCompactLayout];
  
  if (collection != _currentCollection) {
    [_currentCollection release];
    _currentCollection = [collection retain];
  }
  [self _reloadCurrentCollection];
}

- (void) _presentComic:(Comic*)comic {
  ComicViewController* viewController = [[ComicViewController alloc] initWithComic:comic];
  if (viewController) {
    viewController.modalPresentationStyle = UIModalPresentationFullScreen;
    viewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:viewController animated:YES completion:nil];
    _comicPresentationActive = YES;
    [viewController release];
    
    if (comic != _currentComic) {
      [_currentComic release];
      _currentComic = [comic retain];
    }
  } else {
    [[AppDelegate sharedDelegate] showAlertWithTitle:NSLocalizedString(@"COMIC_OPEN_FAILED_TITLE", nil)
                                            message:NSLocalizedString(@"COMIC_OPEN_FAILED_MESSAGE", nil)
                                             button:NSLocalizedString(@"INBOX_ALERT_BUTTON", nil)];
  }
}

- (void) _refreshComicAfterDismissal {
  if (!_comicPresentationActive || self.presentedViewController) {
    return;
  }
  _comicPresentationActive = NO;

  Comic* comic = [[_currentComic retain] autorelease];
  [_currentComic release];
  _currentComic = nil;
  if (comic == nil) {
    return;
  }

  if ([[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_SortingMode] == kSortingMode_ByStatus) {
    [self _reloadCurrentCollection];
  } else {
    Comic* visibleComic = [_gridView itemForItem:comic];
    if (visibleComic && [[LibraryConnection mainConnection] refetchObject:visibleComic]) {
      [self _updateThumbnailViewForItem:visibleComic];
    } else {
      [self _reloadCurrentCollection];
    }
  }
}



- (void) viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  
  BOOL isLandscape = self.view.bounds.size.width > self.view.bounds.size.height;
  if (isLandscape) {
    _gridView.contentMargins = UIEdgeInsetsMake(kGridMargin, kGridMargin + kGridMarginExtra_Landscape, kGridMargin, kGridMargin);
    _gridView.itemSpacing = UIEdgeInsetsMake(0.0, 0.0, kItemVerticalSpacing, kItemHorizontalSpacing_Landscape);
  } else {
    _gridView.contentMargins = UIEdgeInsetsMake(kGridMargin, kGridMargin + kGridMarginExtra_Portrait, kGridMargin, kGridMargin);
    _gridView.itemSpacing = UIEdgeInsetsMake(0.0, 0.0, kItemVerticalSpacing, kItemHorizontalSpacing_Portrait);
  }
  
  if (_gridView.empty) {
    [_gridView layoutSubviews];
    [self _setCurrentCollection:_currentCollection];
  }
}

- (void) _rateNow:(id)argument {
  [[AppDelegate sharedDelegate] logEvent:@"rating.now"];
  [[NSUserDefaults standardUserDefaults] setInteger:-1 forKey:kDefaultKey_LaunchCount];
  
  NSString* appURL = [NSString stringWithFormat:kiOS7AppStoreURLFormat, kAppStoreAppID];
  [[UIApplication sharedApplication] openURL:[NSURL URLWithString:appURL] options:@{} completionHandler:nil];
}

- (void) _rateLater:(id)argument {
  [[AppDelegate sharedDelegate] logEvent:@"rating.later"];
  [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:kDefaultKey_LaunchCount];
}

- (void) _showRatingScreen {
  if (_startupPresentationsPending || self.presentedViewController ||
      [[AppDelegate sharedDelegate] isAlertVisible] ||
      _window.windowScene.activationState != UISceneActivationStateForegroundActive) {
    return;
  }
  [[AppDelegate sharedDelegate] logEvent:@"rating.prompt"];
  [[AppDelegate sharedDelegate] showAlertWithTitle:NSLocalizedString(@"RATE_ALERT_TITLE", nil)
                                           message:NSLocalizedString(@"RATE_ALERT_MESSAGE", nil)
                                     confirmButton:NSLocalizedString(@"RATE_ALERT_CONFIRM", nil)
                                      cancelButton:NSLocalizedString(@"RATE_ALERT_CANCEL", nil)
                                          delegate:self
                                   confirmSelector:@selector(_rateNow:)
                                    cancelSelector:@selector(_rateLater:)
                                          argument:nil];
}

- (void) _requireUpdate {
  [self _forceUpdate];
  [[NSUserDefaults standardUserDefaults] setInteger:kLibraryVersion forKey:kDefaultKey_LibraryVersion];
}

- (void) _sceneDidActivate:(NSNotification*)notification {
  if (notification.object == _window.windowScene && _startupPresentationsPending) {
    // Let scene setup enqueue any import errors before considering the announcement.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_continueStartupPresentations) object:nil];
    [self performSelector:@selector(_continueStartupPresentations) withObject:nil afterDelay:0.0];
  }
}

- (void) _continueStartupPresentations {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_continueStartupPresentations) object:nil];
  if (!_startupPresentationsPending || !self.view.window ||
      _window.windowScene.activationState != UISceneActivationStateForegroundActive) {
    return;
  }

  // Startup alerts, import scans, and modal dismissals take priority. Some alert and
  // form-sheet dismissals do not call the library's viewDidAppear, so retry while
  // startup work remains; scene activation restarts this after backgrounding.
  AppDelegate* delegate = [AppDelegate sharedDelegate];
  if (self.presentedViewController || self.isBeingPresented || self.isBeingDismissed ||
      [delegate isAlertVisible] || [delegate isSpinnerVisible] ||
      [[LibraryUpdater sharedUpdater] isUpdating]) {
    [self performSelector:@selector(_continueStartupPresentations) withObject:nil afterDelay:0.25];
    return;
  }

  if (_libraryUpdatePromptPending) {
    _libraryUpdatePromptPending = NO;
    [delegate showAlertWithTitle:NSLocalizedString(@"REQUIRE_UPDATE_TITLE", nil)
                        message:NSLocalizedString(@"REQUIRE_UPDATE_MESSAGE", nil)
                  confirmButton:NSLocalizedString(@"REQUIRE_UPDATE_CONTINUE", nil)
                   cancelButton:NSLocalizedString(@"REQUIRE_UPDATE_CANCEL", nil)
                       delegate:self
                confirmSelector:@selector(_requireUpdate)
                 cancelSelector:NULL
                       argument:nil];
    [self performSelector:@selector(_continueStartupPresentations) withObject:nil afterDelay:0.25];
    return;
  }

  _startupPresentationsPending = NO;
  if (_currentComic && !_comicPresentationActive) {
    // Keep the saved comic until all startup UI is finished, including settings. An
    // import scan may have removed it or updated its saved reading state meanwhile.
    Comic* comic = [[_currentComic retain] autorelease];
    [_currentComic release];
    _currentComic = nil;
    if ([[LibraryConnection mainConnection] refetchObject:comic]) {
      [self _presentComic:comic];
    }
  }
}

- (void) _viewDidReallyAppear {
  BOOL needLibraryUpdate = [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_LibraryVersion] != kLibraryVersion;
  if (needLibraryUpdate) {
    XLOG_VERBOSE(@"Library is outdated at version %i", (int)[[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_LibraryVersion]);
    [_currentComic release];
    _currentComic = nil;
  }
  
  [CATransaction flush];

  if (_launchView) {
    UIView* launchView = _launchView;
    [UIView animateWithDuration:0.5 animations:^{
      launchView.alpha = 0.0;
    } completion:^(BOOL finished) {
      [launchView removeFromSuperview];
      [launchView release];
    }];
    _launchView = nil;
  }
  
  NSInteger count = [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_LaunchCount];
  if (count >= 0) {
    [[NSUserDefaults standardUserDefaults] setInteger:(count + 1) forKey:kDefaultKey_LaunchCount];
    if (_releaseNewsDismissed && !needLibraryUpdate && !_currentComic && (count + 1 >= kLaunchCountBeforeRating) && !self.presentedViewController && [[NetReachability sharedNetReachability] state]) {
      [self performSelector:@selector(_showRatingScreen) withObject:nil afterDelay:kShowRatingDelay];
    } else {
      XLOG_VERBOSE(@"Launch count is now %i", (int)[[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_LaunchCount]);
    }
  }
  
  _libraryUpdatePromptPending = needLibraryUpdate;
  _startupPresentationsPending = YES;
  [self _continueStartupPresentations];
}

- (void) viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];

  [self _refreshComicAfterDismissal];
  if (!_launched) {
    _launched = YES;
    [self performSelector:@selector(_viewDidReallyAppear) withObject:nil afterDelay:0.0];
  } else if (_startupPresentationsPending) {
    [self _continueStartupPresentations];
  }
  
  [self becomeFirstResponder];
}

- (void) _popCollection {
  [self gridViewDidUpdateScrollingAmount:nil];
  [self _setCurrentCollection:nil];
}

- (BOOL) navigationBar:(UINavigationBar*)navigationBar shouldPopItem:(UINavigationItem*)item {
  [self performSelector:@selector(_popCollection) withObject:nil afterDelay:0.0];
  return NO;
}

- (void) saveState {
  if ([self.presentedViewController isKindOfClass:[ComicViewController class]]) {
    [(ComicViewController*)self.presentedViewController saveState];
  }
  
  [self gridViewDidUpdateScrollingAmount:nil];
  [[NSUserDefaults standardUserDefaults] setInteger:_currentCollection.sqlRowID forKey:kDefaultKey_CurrentCollection];
  [[NSUserDefaults standardUserDefaults] setInteger:_currentComic.sqlRowID forKey:kDefaultKey_CurrentComic];
}

- (void) _forceUpdate {
  [[AppDelegate sharedDelegate] purgeLogHistory];
  [[LibraryUpdater sharedUpdater] update:YES];
  [self _updateStatistics];
  [self _setCurrentCollection:nil];
}

@end

@implementation LibraryViewController (LibraryUpdaterDelegate)

- (void) libraryUpdaterWillStart:(LibraryUpdater*)library {
  _markReadButton.enabled = NO;
  _markNewButton.enabled = NO;
  _updateButton.enabled = NO;
  _forceUpdateButton.enabled = NO;
}

- (void) libraryUpdaterDidContinue:(LibraryUpdater*)library progress:(float)progress {
  if (self.presentedViewController == _menuViewController) {
    [self _updateStatistics];
  }
}

- (void) libraryUpdaterDidFinish:(LibraryUpdater*)library {
  // The updater clears isUpdating immediately after this delegate returns.
  dispatch_async(dispatch_get_main_queue(), ^{
    [[CRLibrarySyncCoordinator sharedCoordinator] libraryDidUpdate];
  });
  if (_currentCollection && ![[LibraryConnection mainConnection] refetchObject:_currentCollection]) {
    [self _setCurrentCollection:nil];
  } else {
    [self _reloadCurrentCollection];
  }
  
  _markReadButton.enabled = YES;
  _markNewButton.enabled = YES;
  _updateButton.enabled = YES;
  _forceUpdateButton.enabled = YES;
}

@end

@implementation LibraryViewController (GridViewDelegate)

- (UIView*) gridView:(GridView*)gridView viewForItem:(id)item {
  ThumbnailView* view = [[ThumbnailView alloc] initWithFrame:CGRectMake(0, 0, kLibraryThumbnailWidth, kLibraryThumbnailHeight)];
  view.item = item;
  view.activationTarget = self;
  view.isAccessibilityElement = YES;
  view.accessibilityTraits = UIAccessibilityTraitButton;
  view.accessibilityLabel = [item name];
  view.accessibilityIdentifier = [NSString stringWithFormat:@"library.%@.%@", [item isKindOfClass:[Comic class]] ? @"comic" : @"collection", [item name]];
  view.userInteractionEnabled = YES;
  UIContextMenuInteraction* contextMenu = [[UIContextMenuInteraction alloc] initWithDelegate:self];
  [view addInteraction:contextMenu];
  [contextMenu release];
  return [view autorelease];
}

- (void) gridViewDidUpdateScrollingAmount:(GridView*)gridView {
  if (!_gridView.empty) {
    int scrolling = (int)lroundf(_gridView.scrollingAmount);
    if (_currentCollection) {
      if (scrolling != _currentCollection.scrolling) {
        _currentCollection.scrolling = scrolling;
        [[LibraryConnection mainConnection] updateObject:_currentCollection];
      }
    } else {
      [[NSUserDefaults standardUserDefaults] setInteger:scrolling forKey:kDefaultKey_RootScrolling];
    }
  }
}

#if __DISPLAY_THUMBNAILS_IN_BACKGROUND__

- (void) gridViewWillStartUpdatingViewsVisibility:(GridView*)gridView {
  pthread_mutex_lock(&_displayMutex);
  _showBatch = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  _hideBatch = CFSetCreateMutable(kCFAllocatorDefault, 0, &kCFTypeSetCallBacks);
}

#endif

- (void) gridView:(GridView*)gridView willShowView:(UIView*)view forItem:(id)item {
  UIImage* placeholderImage = [item isKindOfClass:[Comic class]] ? _comicImage : _collectionImage;
#if __DISPLAY_THUMBNAILS_IN_BACKGROUND__
  view.layer.contents = (id)[placeholderImage CGImage];
  CFDictionarySetValue(_showBatch, view, item);
#else
  UIImage* image = nil;
#if __STORE_THUMBNAILS_IN_DATABASE__
  DatabaseSQLRowID rowID = [item thumbnail];
  if (rowID > 0) {
    Thumbnail* thumbnail = [[LibraryConnection mainConnection] fetchObjectOfClass:[Thumbnail class] withSQLRowID:rowID];
    image = [[UIImage alloc] initWithData:thumbnail.data];
  }
#else
  NSString* name = [item thumbnail];
  if (name) {
    NSString* path = [[LibraryConnection libraryApplicationDataPath] stringByAppendingPathComponent:name];
    image = [[UIImage alloc] initWithContentsOfFile:path];
  }
#endif
  if (image) {
    [(ThumbnailView*)view setImage:image];
    [image release];
  } else {
    [(ThumbnailView*)view setImage:placeholderImage];
  }
#endif
  
  int status = [item isKindOfClass:[Comic class]] ? [(Comic*)item status] : [(ComicCollection*)item status];
  if (status > 0) {
    UIImageView* subview = [[UIImageView alloc] initWithImage:_ribbonImage];
    subview.frame = CGRectMake(kRibbonImageX, kRibbonImageY, kRibbonImageWidth, kRibbonImageHeight);
    [view addSubview:subview];
    [subview release];
    [(ThumbnailView*)view setRibbonView:subview];
  } else if (status < 0) {
    UIImageView* subview = [[UIImageView alloc] initWithImage:_newImage];
    subview.frame = CGRectMake(kNewImageX, kNewImageY, kNewImageWidth, kNewImageHeight);
    [view addSubview:subview];
    [subview release];
    [(ThumbnailView*)view setNoteView:subview];
  }
}

- (void) gridView:(GridView*)gridView didHideView:(UIView*)view forItem:(id)item {
#if __DISPLAY_THUMBNAILS_IN_BACKGROUND__
  CFSetAddValue(_hideBatch, view);
  view.layer.contents = NULL;
#else
  [(ThumbnailView*)view setImage:nil];
#endif
  
  [[(ThumbnailView*)view noteView] removeFromSuperview];
  [(ThumbnailView*)view setNoteView:nil];
  [[(ThumbnailView*)view ribbonView] removeFromSuperview];
  [(ThumbnailView*)view setRibbonView:nil];
}

#if __DISPLAY_THUMBNAILS_IN_BACKGROUND__

static void __SetApplierFunction(const void* value, void* context) {
  CFDictionaryRemoveValue((CFMutableDictionaryRef)context, value);
}

static void __ArrayApplierFunction(const void* value, void* context) {
  CFSetApplyFunction((CFSetRef)context, __SetApplierFunction, (void*)value);
}

- (void) gridViewDidEndUpdatingViewsVisibility:(GridView*)gridView {
  BOOL signal = NO;
  
  if (CFSetGetCount(_hideBatch)) {
    CFArrayApplyFunction(_displayQueue, CFRangeMake(0, CFArrayGetCount(_displayQueue)), __ArrayApplierFunction, _hideBatch);
  }
  CFRelease(_hideBatch);
  if (CFDictionaryGetCount(_showBatch)) {
    CFArrayAppendValue(_displayQueue, _showBatch);
    signal = YES;
  }
  CFRelease(_showBatch);
  pthread_mutex_unlock(&_displayMutex);
  
  if (signal) {
    CFRunLoopSourceSignal(_displaySource);
    CFRunLoopWakeUp(_displayRunLoop);
  }
}

#endif

@end

@implementation LibraryViewController (IBActions)

- (IBAction) resort:(id)sender {
  if (_segmentedControl.selectedSegmentIndex != [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_SortingMode]) {
    [[NSUserDefaults standardUserDefaults] setInteger:_segmentedControl.selectedSegmentIndex forKey:kDefaultKey_SortingMode];
    [self gridViewDidUpdateScrollingAmount:nil];
    [self _reloadCurrentCollection];
  }
}

- (IBAction) update:(id)sender {
  [[LibraryUpdater sharedUpdater] update:NO];
}

- (IBAction) forceUpdate:(id)sender {
  [[AppDelegate sharedInstance] showAlertWithTitle:NSLocalizedString(@"FORCE_UPDATE_TITLE", nil)
                                           message:NSLocalizedString(@"FORCE_UPDATE_MESSAGE", nil)
                                     confirmButton:NSLocalizedString(@"FORCE_UPDATE_CONTINUE", nil)
                                      cancelButton:NSLocalizedString(@"FORCE_UPDATE_CANCEL", nil)
                                          delegate:self
                                   confirmSelector:@selector(_forceUpdate)
                                    cancelSelector:NULL
                                          argument:nil];
}

- (IBAction) updateServer:(id)sender {
  [[WebServer sharedWebServer] setType:(WebServerType)_serverControl.selectedSegmentIndex];
  [self _updateTimer:nil];
}

- (void) _markAllRead {
  [[CRLibrarySyncCoordinator sharedCoordinator] markComics:[[LibraryConnection mainConnection] fetchAllComicsByName] status:0];
  [self _reloadCurrentCollection];
}

- (IBAction) markAllRead:(id)sender {
  [[AppDelegate sharedInstance] showAlertWithTitle:NSLocalizedString(@"MARK_ALL_READ_TITLE", nil)
                                           message:nil
                                     confirmButton:NSLocalizedString(@"MARK_ALL_READ_CONTINUE", nil)
                                      cancelButton:NSLocalizedString(@"MARK_ALL_READ_CANCEL", nil)
                                          delegate:self
                                   confirmSelector:@selector(_markAllRead)
                                    cancelSelector:NULL
                                          argument:nil];
}

- (void) _markAllNew {
  [[CRLibrarySyncCoordinator sharedCoordinator] markComics:[[LibraryConnection mainConnection] fetchAllComicsByName] status:-1];
  [self _reloadCurrentCollection];
}

- (IBAction) markAllNew:(id)sender {
  [[AppDelegate sharedInstance] showAlertWithTitle:NSLocalizedString(@"MARK_ALL_NEW_TITLE", nil)
                                           message:nil
                                     confirmButton:NSLocalizedString(@"MARK_ALL_NEW_CONTINUE", nil)
                                      cancelButton:NSLocalizedString(@"MARK_ALL_NEW_CANCEL", nil)
                                          delegate:self
                                   confirmSelector:@selector(_markAllNew)
                                    cancelSelector:NULL
                                          argument:nil];
}

- (IBAction) showLog:(id)sender {
  if (self.presentedViewController == _menuViewController) {
    [self dismissViewControllerAnimated:YES completion:^{
      [self->_updateTimer setFireDate:[NSDate distantFuture]];
      [[AppDelegate sharedInstance] showLogViewController];
    }];
  } else {
    [[AppDelegate sharedInstance] showLogViewController];
  }
}

- (IBAction) toggleDimming:(id)sender {
  [(AppDelegate*)[AppDelegate sharedInstance] setScreenDimmed:_dimmingSwitch.on];
}

- (IBAction) purchase:(id)sender {
  NSMutableArray<UTType*>* types = [NSMutableArray arrayWithObject:UTTypePDF];
  for (NSString* extension in @[@"cbz", @"zip", @"cbr", @"rar"]) {
    UTType* type = [UTType typeWithFilenameExtension:extension];
    if (type) {
      [types addObject:type];
    }
  }
  // Import a local copy; Catalyst open-in-place requests write access to the original.
  UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
  picker.delegate = self;
  picker.allowsMultipleSelection = YES;

  void (^presentPicker)(void) = ^{
    [self presentViewController:picker animated:YES completion:nil];
    [picker release];
  };
  [_updateTimer setFireDate:[NSDate distantFuture]];
  if (self.presentedViewController == _menuViewController) {
    [self dismissViewControllerAnimated:YES completion:presentPicker];
  } else {
    presentPicker();
  }
}

- (IBAction) restore:(id)sender {
  [[CRPlusStore sharedStore] restoreWithCompletion:^(BOOL unlocked, NSError* error) {
    if (error) [[AppDelegate sharedDelegate] showAlertWithTitle:@"Restore Purchases" message:error.localizedDescription button:@"OK"];
  }];
}

- (void) documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  for (NSURL* url in urls) {
    [[AppDelegate sharedDelegate] importComicAtURL:url];
  }
}

// UIPopoverPresentationControllerDelegate — fires when tapped outside popover
- (UIModalPresentationStyle) adaptivePresentationStyleForPresentationController:(UIPresentationController*)controller {
  if (controller.presentedViewController == _menuViewController) {
    return UIModalPresentationPageSheet;
  }
  return UIModalPresentationNone;
}

- (void) presentationControllerDidDismiss:(UIPresentationController*)presentationController {
  [_updateTimer setFireDate:[NSDate distantFuture]];
}

@end
