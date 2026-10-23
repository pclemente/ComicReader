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
#import "CRAdaptiveViewport.h"
#import "CRLibrarySyncCoordinator.h"
#import "CRReadingLists.h"
#import "ComicFlow-Swift.h"
#import "Defaults.h"
#import "Extensions_Foundation.h"
#import "Extensions_UIKit.h"
#import "NetReachability.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@class ThumbnailView;

static NSString* CRResolvedComicPath(NSURL* url) {
  return [[url.path stringByResolvingSymlinksInPath] stringByStandardizingPath];
}

static BOOL CRIsIndexedLibraryComicPath(NSString* path) {
  NSString* root = [[[LibraryConnection libraryRootPath] stringByResolvingSymlinksInPath] stringByStandardizingPath];
  NSString* prefix = [root stringByAppendingString:@"/"];
  if (![path hasPrefix:prefix]) return NO;
  NSArray<NSString*>* components = [[path substringFromIndex:prefix.length] pathComponents];
  if (components.count < 1 || components.count > 2 ||
      [components.firstObject isEqualToString:@"Inbox"]) return NO;
  for (NSString* component in components) {
    if ([component hasPrefix:@"."]) return NO;
  }
  return YES;
}

static BOOL CRPathIsInsideDirectory(NSString* path, NSString* directory) {
  NSString* standardizedPath = [path.stringByStandardizingPath stringByResolvingSymlinksInPath];
  NSString* standardizedDirectory = [directory.stringByStandardizingPath stringByResolvingSymlinksInPath];
  if (!standardizedPath || !standardizedDirectory) return NO;
  return [standardizedPath isEqualToString:standardizedDirectory] ||
    [standardizedPath hasPrefix:[standardizedDirectory stringByAppendingString:@"/"]];
}

static BOOL CRIsPickerOwnedCopyURL(NSURL* url) {
  if (!url.isFileURL) return NO;
  NSString* inbox = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:@"Inbox"];
  return CRPathIsInsideDirectory(url.path, NSTemporaryDirectory()) ||
    CRPathIsInsideDirectory(url.path, inbox);
}

static NSURL* CRStageDirectOpenPickerCopy(NSURL* sourceURL, NSError** error) {
  if (![ComicViewController isSupportedComicFileURL:sourceURL]) return nil;
  NSString* root = CRDirectOpenTemporaryRootPath();
  NSString* directory = [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSString* destinationPath = [directory stringByAppendingPathComponent:sourceURL.lastPathComponent];
  if (CRPathIsInsideDirectory(destinationPath, [LibraryConnection libraryRootPath])) return nil;

  NSFileManager* manager = [NSFileManager defaultManager];
  if (![manager createDirectoryAtPath:directory
          withIntermediateDirectories:YES
                           attributes:nil
                                error:error]) return nil;

  NSURL* destinationURL = [NSURL fileURLWithPath:destinationPath];
  BOOL scoped = [sourceURL startAccessingSecurityScopedResource];
  NSNumber* regularFile = nil;
  BOOL readable = [sourceURL getResourceValue:&regularFile
                                       forKey:NSURLIsRegularFileKey
                                        error:error] && regularFile.boolValue;
  BOOL success = NO;
  if (readable && CRIsPickerOwnedCopyURL(sourceURL)) {
    success = [manager moveItemAtURL:sourceURL toURL:destinationURL error:error];
    if (!success) {
      // A provider can put its copy on a different volume. Copy it across and
      // remove only paths known to be picker-owned container locations.
      success = [manager copyItemAtURL:sourceURL toURL:destinationURL error:error];
      if (success) [manager removeItemAtURL:sourceURL error:NULL];
    }
  } else if (readable) {
    // Be conservative for unexpected provider URLs: preserve the possible
    // original and create our own short-lived reader copy.
    success = [manager copyItemAtURL:sourceURL toURL:destinationURL error:error];
  }
  if (scoped) [sourceURL stopAccessingSecurityScopedResource];
  if (!success) {
    [manager removeItemAtPath:directory error:NULL];
    return nil;
  }
  return destinationURL;
}

@interface CRComicDocumentPickerViewController : UIDocumentPickerViewController
@property(nonatomic) BOOL opensComicsDirectly;
@end

@implementation CRComicDocumentPickerViewController
@end

@interface LibraryViewController () <CRWhatsNewBannerDelegate, CRAdaptiveViewportViewDelegate>
@property(nonatomic, retain) id adaptiveGridScrollAnchor;
@property(nonatomic, retain) CRAdaptiveViewportView* adaptiveViewportView;
@property(nonatomic) CGFloat adaptiveGridScrollAnchorY;
@property(nonatomic) CGSize gridSizeBeforeLayout;
@property(nonatomic) UIEdgeInsets gridContentMarginsBeforeLayout;
@property(nonatomic) UIEdgeInsets gridItemSpacingBeforeLayout;
@property(nonatomic) BOOL hasGridLayoutSnapshot;
@property(nonatomic) BOOL suppressGridScrollingPersistence;
- (void)_activateThumbnail:(ThumbnailView*)thumbnail;
- (void)_captureGridLayoutSnapshot;
- (void)_configureNavigationForCompactWidth:(BOOL)compact;
- (void)_centerEmptyStateContent;
- (CGRect)_libraryViewportBounds;
- (void)_updateCompactSortMenu;
- (void)_openComicFilesCommand:(UIKeyCommand*)command;
#if TARGET_OS_MACCATALYST
- (void)open:(id)sender;
#endif
- (void)_refreshLibraryCommand:(UIKeyCommand*)command;
- (Comic*)_indexedComicForURL:(NSURL*)url;
- (void)_drainExternalComicURLQueue;
- (void)_enqueueComicURLsForOpening:(NSArray<NSURL*>*)urls
             deletesFilesOnClose:(BOOL)deletesFilesOnClose;
- (void)_showDirectOpenFailureAlertForFilenames:(NSArray<NSString*>*)filenames;
- (void)_externalComicOpenAlertDidDismiss:(id)argument;
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

#define kBackgroundOffset 6.0

#define kGridMargin 10.0
#define kGridMarginExtra_Portrait 2.0
#define kGridMarginExtra_Landscape 2.0

#define kItemVerticalSpacing 8.0
#define kItemHorizontalSpacing_Portrait 17.0
#define kItemHorizontalSpacing_Landscape 9.0

// The regular navigation bar combines the 332-point sort control with five
// primary actions. Below this width UIKit moves Plus and Settings into its More
// menu, so use the dedicated toolbar while leaving grid spacing independent.
#define kLibraryCompactGridWidth 600.0
#define kLibraryRegularNavigationMinimumWidth 820.0

#define kNewImageX 67.0
#define kNewImageY 6.0
#define kNewImageWidth 60.0
#define kNewImageHeight 60.0

#define kRibbonImageX 67.0
#define kRibbonImageY 6.0
#define kRibbonImageWidth 60.0
#define kRibbonImageHeight 60.0

#define kShowRatingDelay 2.0

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
@synthesize adaptiveViewportView=_adaptiveViewportView;

- (void) dealloc {
  _adaptiveViewportView.adaptiveViewportDelegate = nil;
  [_adaptiveViewportView release];
  [_adaptiveGridScrollAnchor release];
  _adaptiveGridScrollAnchor = nil;
  [_browserButtonItem release];
  [_pendingWebComicURL release];
  for (NSURL* url in _directOpenTemporaryURLs) {
    CRRemoveDirectOpenTemporaryFileAtURL(url);
  }
  [_directOpenTemporaryURLs release];
  [_externalComicURLQueue release];
  [super dealloc];
}

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
      item.rightBarButtonItems = @[_compactSortButtonItem, _browserButtonItem];
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
    NSArray* rightItems = @[_settingsButtonItem, _plusButtonItem, _cloudButtonItem, _readingListsButtonItem, _browserButtonItem];
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

typedef struct {
  ThumbnailView* view;
  DatabaseObject* item;
  CGImageRef image;
} CRThumbnailDisplayResult;

// Called from the main thread only.
static void __ApplyThumbnailContents(ThumbnailView* view, DatabaseObject* item, CGImageRef image) {
  NSCAssert([NSThread isMainThread], @"Thumbnail layers must be updated on the main thread");
  if ((view.item != item) || (view.superview == nil) || view.hidden) return;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  view.layer.contents = (id)image;
  [CATransaction commit];
}

// Called from the main thread by dispatch_async_f.
static void __ApplyThumbnailDisplayResult(void* context) {
  CRThumbnailDisplayResult* result = (CRThumbnailDisplayResult*)context;
  __ApplyThumbnailContents(result->view, result->item, result->image);
  [result->view release];
  [result->item release];
  CGImageRelease(result->image);
  free(result);
}

// Keeps the batch's UIKit keys alive until every preceding main-queue apply.
static void __ReleaseThumbnailDisplayBatch(void* context) {
  NSCAssert([NSThread isMainThread], @"Thumbnail view batches must be released on the main thread");
  CFRelease((CFDictionaryRef)context);
}

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
    CGImageRef contents = [image CGImage];
    if (contents) {
      if (params[0]) {
        CRThumbnailDisplayResult* result = malloc(sizeof(CRThumbnailDisplayResult));
        if (result) {
          result->view = [view retain];
          result->item = [item retain];
          result->image = CGImageRetain(contents);
          dispatch_async_f(dispatch_get_main_queue(), result, __ApplyThumbnailDisplayResult);
        }
      } else {
        __ApplyThumbnailContents(view, item, contents);
      }
    }
    [image release];
  }
}

// Called from main thread or display thread
- (void) _processDisplayQueue:(BOOL)inBackground {
#if __STORE_THUMBNAILS_IN_DATABASE__
  void* params[] = {inBackground ? (void*)self : NULL,
                    inBackground ? (void*)_displayConnection : (void*)[LibraryConnection mainConnection]};
#else
  void* params[] = {inBackground ? (void*)self : NULL, [LibraryConnection libraryApplicationDataPath]};
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
      if (inBackground) {
        dispatch_async_f(dispatch_get_main_queue(), (void*)dictionary, __ReleaseThumbnailDisplayBatch);
      } else {
        CFRelease(dictionary);
      }
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
    _externalComicURLQueue = [[NSMutableArray alloc] init];
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
#if !TARGET_OS_MACCATALYST
  UIKeyCommand* open = [UIKeyCommand keyCommandWithInput:@"o"
                                           modifierFlags:UIKeyModifierCommand
                                                  action:@selector(_openComicFilesCommand:)];
  open.discoverabilityTitle = @"Open Comic Files";
#endif
  UIKeyCommand* refresh = [UIKeyCommand keyCommandWithInput:@"r"
                                              modifierFlags:UIKeyModifierCommand
                                                     action:@selector(_refreshLibraryCommand:)];
  refresh.discoverabilityTitle = @"Refresh Library";
  UIKeyCommand* browse = [UIKeyCommand keyCommandWithInput:@"b"
                                             modifierFlags:UIKeyModifierCommand | UIKeyModifierShift
                                                    action:@selector(_showWebBrowser:)];
  browse.discoverabilityTitle = @"Browse for Comics";
#if TARGET_OS_MACCATALYST
  return @[refresh, browse];
#else
  return @[open, refresh, browse];
#endif
}

#if TARGET_OS_MACCATALYST
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
  if (action == @selector(open:)) {
    return self.presentedViewController == nil && !self.isBeingPresented && !self.isBeingDismissed;
  }
  return [super canPerformAction:action withSender:sender];
}

- (void)validateCommand:(UICommand*)command {
  [super validateCommand:command];
  if (command.action == @selector(open:)) {
    command.title = @"Open Comic…";
    if ([self canPerformAction:command.action withSender:command]) {
      command.attributes &= ~UIMenuElementAttributesDisabled;
    } else {
      command.attributes |= UIMenuElementAttributesDisabled;
    }
  }
}

- (void)open:(id)sender {
  [self _openComicFilesCommand:nil];
}
#endif

- (void) _openComicFilesCommand:(UIKeyCommand*)command {
  if (!self.presentedViewController) {
#if TARGET_OS_MACCATALYST
    [self _presentComicDocumentPickerOpeningDirectly:YES fromController:self];
#else
    [self purchase:nil];
#endif
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

- (Comic*)_indexedComicForURL:(NSURL*)url {
  NSString* path = CRResolvedComicPath(url);
  if (!path) return nil;
  for (Comic* comic in [[LibraryConnection mainConnection] fetchAllComicsByName]) {
    NSString* comicPath = [[[LibraryConnection mainConnection] pathForComic:comic]
      stringByResolvingSymlinksInPath].stringByStandardizingPath;
    if ([comicPath isEqualToString:path]) return comic;
  }
  return nil;
}

+ (NSArray<NSURL*>*)supportedComicURLsFromURLs:(NSArray<NSURL*>*)urls {
  NSMutableArray<NSURL*>* supported = [NSMutableArray arrayWithCapacity:urls.count];
  for (NSURL* url in urls) {
    if ([ComicViewController isSupportedComicFileURL:url]) [supported addObject:url];
  }
  return supported;
}

- (void)enqueueComicURLsForOpening:(NSArray<NSURL*>*)urls {
  [self _enqueueComicURLsForOpening:urls deletesFilesOnClose:NO];
}

- (void)_enqueueComicURLsForOpening:(NSArray<NSURL*>*)urls
             deletesFilesOnClose:(BOOL)deletesFilesOnClose {
  if (![NSThread isMainThread]) {
    NSArray* copiedURLs = [urls copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self _enqueueComicURLsForOpening:copiedURLs deletesFilesOnClose:deletesFilesOnClose];
    });
    [copiedURLs release];
    return;
  }

  if (!_externalComicURLQueue) _externalComicURLQueue = [[NSMutableArray alloc] init];
  NSArray<NSURL*>* supportedURLs = [[self class] supportedComicURLsFromURLs:urls];
  NSUInteger previousCount = _externalComicURLQueue.count;
  BOOL readerAlreadyPresented = [self.presentedViewController isKindOfClass:[ComicViewController class]];
  [_externalComicURLQueue addObjectsFromArray:supportedURLs];
  if (deletesFilesOnClose && supportedURLs.count > 0) {
    if (!_directOpenTemporaryURLs) _directOpenTemporaryURLs = [[NSMutableSet alloc] init];
    [_directOpenTemporaryURLs addObjectsFromArray:supportedURLs];
  }
  if (_externalComicURLQueue.count == previousCount) return;
  if (readerAlreadyPresented) _dismissPresentedComicForIncomingURL = YES;

  // A URL delivered at launch takes precedence over restoring the last reader.
  // An already presented library reader keeps its model until dismissal so its
  // current position can be saved normally.
  if (!_comicPresentationActive && ![self.presentedViewController isKindOfClass:[ComicViewController class]]) {
    [_currentComic release];
    _currentComic = nil;
  }
  [self _drainExternalComicURLQueue];
}

- (void)_drainExternalComicURLQueue {
  if (_externalComicURLQueue.count == 0) return;
  if (!_launched || _startupPresentationsPending) return;
  if (_pendingWebComicURL) {
    [self _tryOpenPendingWebComic];
    return;
  }
  UIViewController* presented = self.presentedViewController;
  UIWindow* effectiveWindow = self.viewIfLoaded.window;
  if (!effectiveWindow && [presented isKindOfClass:[ComicViewController class]]) {
    effectiveWindow = presented.viewIfLoaded.window;
  }
  AppDelegate* delegate = [AppDelegate sharedDelegate];
  UIWindowScene* windowScene = _window.windowScene;
  if (!_window || effectiveWindow != _window || !windowScene ||
      windowScene.activationState != UISceneActivationStateForegroundActive ||
      self.isBeingPresented || self.isBeingDismissed) return;
  if ([delegate isAlertVisible]) {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_drainExternalComicURLQueue) object:nil];
    [self performSelector:@selector(_drainExternalComicURLQueue) withObject:nil afterDelay:0.35];
    return;
  }

  if (presented) {
    if (![presented isKindOfClass:[ComicViewController class]]) {
      // Programmatic dismissal of a Catalyst form sheet does not always make
      // the presenting controller appear again. Keep the queued Finder URL
      // moving without dismissing the user's current sheet automatically.
      [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_drainExternalComicURLQueue) object:nil];
      [self performSelector:@selector(_drainExternalComicURLQueue) withObject:nil afterDelay:0.35];
      return;
    }
    if (presented.presentedViewController) {
      // The reader can own a document picker or tools sheet. Let that child
      // finish dismissing before replacing the reader with the queued comic.
      [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_drainExternalComicURLQueue) object:nil];
      [self performSelector:@selector(_drainExternalComicURLQueue) withObject:nil afterDelay:0.35];
      return;
    }
    if (!_dismissPresentedComicForIncomingURL || _incomingComicDismissalPending ||
        presented.isBeingDismissed) return;
    if (presented.isBeingPresented) {
      [self performSelector:@selector(_drainExternalComicURLQueue) withObject:nil afterDelay:0.1];
      return;
    }
    _incomingComicDismissalPending = YES;
    [(ComicViewController*)presented saveState];
    [self dismissViewControllerAnimated:YES completion:^{
      self->_incomingComicDismissalPending = NO;
      self->_dismissPresentedComicForIncomingURL = NO;
      [self _refreshComicAfterDismissal];
      [self _drainExternalComicURLQueue];
    }];
    return;
  }
  _dismissPresentedComicForIncomingURL = NO;
  if ([delegate isSpinnerVisible] || [[LibraryUpdater sharedUpdater] isUpdating]) return;

  NSURL* url = [_externalComicURLQueue firstObject];
  BOOL deletesFileOnClose = [_directOpenTemporaryURLs containsObject:url];
  Comic* indexedComic = [self _indexedComicForURL:url];
  if (indexedComic) {
    [_externalComicURLQueue removeObjectAtIndex:0];
    if (deletesFileOnClose) {
      [_directOpenTemporaryURLs removeObject:url];
      CRRemoveDirectOpenTemporaryFileAtURL(url);
    }
    _externalComicLibraryScanAttempts = 0;
    [self _presentComic:indexedComic];
    return;
  }

  if (CRIsIndexedLibraryComicPath(CRResolvedComicPath(url)) && _externalComicLibraryScanAttempts == 0) {
    _externalComicLibraryScanAttempts = 1;
    [delegate updateLibrary];
    return;
  }

  ComicViewController* reader = [[ComicViewController alloc] initWithExternalFileURL:url
                                                                             delegate:self
                                                                 deletesFileOnDealloc:deletesFileOnClose];
  NSString* filename = [url.lastPathComponent copy];
  [_externalComicURLQueue removeObjectAtIndex:0];
  if (deletesFileOnClose) [_directOpenTemporaryURLs removeObject:url];
  _externalComicLibraryScanAttempts = 0;
  if (reader) {
    reader.modalPresentationStyle = UIModalPresentationFullScreen;
    reader.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:reader animated:YES completion:nil];
    _externalComicPresentationActive = YES;
    [reader release];
  } else {
    [delegate showAlertWithTitle:NSLocalizedString(@"COMIC_OPEN_FAILED_TITLE", nil)
                         message:[NSString stringWithFormat:@"%@ could not be opened as a comic.", filename]
                          button:NSLocalizedString(@"INBOX_ALERT_BUTTON", nil)
                        delegate:self
                        selector:@selector(_externalComicOpenAlertDidDismiss:)
                        argument:nil];
  }
  [filename release];
}

- (void)_externalComicOpenAlertDidDismiss:(id)argument {
  [self performSelector:@selector(_drainExternalComicURLQueue) withObject:nil afterDelay:0.35];
}

- (void)_showDirectOpenFailureAlertForFilenames:(NSArray<NSString*>*)filenames {
  UIViewController* top = self.presentedViewController;
  while (top.presentedViewController) top = top.presentedViewController;
  if ([top isKindOfClass:[UIDocumentPickerViewController class]] ||
      top.isBeingDismissed || top.isBeingPresented) {
    [self performSelector:@selector(_showDirectOpenFailureAlertForFilenames:)
               withObject:filenames
               afterDelay:0.1];
    return;
  }
  NSString* message = [NSString stringWithFormat:@"%@\n\n%@",
    [filenames componentsJoinedByString:@"\n"],
    NSLocalizedString(@"COMIC_OPEN_FAILED_MESSAGE", nil)];
  [[AppDelegate sharedDelegate] showAlertWithTitle:NSLocalizedString(@"COMIC_OPEN_FAILED_TITLE", nil)
                                           message:message
                                            button:NSLocalizedString(@"INBOX_ALERT_BUTTON", nil)];
}

- (void) _tryOpenPendingWebComic {
  if (!_pendingWebComicURL || !self.view.window ||
      _window.windowScene.activationState != UISceneActivationStateForegroundActive ||
      self.presentedViewController || self.isBeingPresented || self.isBeingDismissed ||
      [[AppDelegate sharedDelegate] isAlertVisible] || [[AppDelegate sharedDelegate] isSpinnerVisible] ||
      [[LibraryUpdater sharedUpdater] isUpdating]) return;
  Comic* comic = [self _indexedComicForURL:_pendingWebComicURL];
  if (comic) {
    if (_pendingWebComicCreatedCopy && _pendingWebComicPageCount > 0) {
      NSInteger page = MIN(MAX(0, _pendingWebComicPageIndex), _pendingWebComicPageCount - 1);
      comic.status = (int)(page < _pendingWebComicPageCount - 1 ? page : 0);
      [[LibraryConnection mainConnection] updateObject:comic];
      [[CRLibrarySyncCoordinator sharedCoordinator] recordComic:comic
                                                    currentPage:page
                                                      pageCount:_pendingWebComicPageCount];
    }
    [_pendingWebComicURL release];
    _pendingWebComicURL = nil;
    _pendingWebComicPageIndex = 0;
    _pendingWebComicPageCount = 0;
    _pendingWebComicCreatedCopy = NO;
    [self _presentComic:comic];
    return;
  }
  // An import can finish while an older scan is already running. Give the
  // indexer one fresh pass before reporting that the file is unavailable.
  if (_webComicScanAttempts++ < 1) {
    [[AppDelegate sharedDelegate] updateLibrary];
  } else {
    [_pendingWebComicURL release];
    _pendingWebComicURL = nil;
    _pendingWebComicPageIndex = 0;
    _pendingWebComicPageCount = 0;
    _pendingWebComicCreatedCopy = NO;
    [[AppDelegate sharedDelegate] showAlertWithTitle:@"Comic Unavailable"
                                           message:@"The comic could not be found in the library. It may have been moved or removed."
                                            button:@"OK"
                                          delegate:self
                                          selector:@selector(_externalComicOpenAlertDidDismiss:)
                                          argument:nil];
  }
}

- (void) _showWebBrowser:(id)sender {
  if (self.presentedViewController || self.isBeingPresented || self.isBeingDismissed) return;
  CRWebBrowserViewController* controller = [[CRWebBrowserViewController alloc]
    initWithLibraryRootURL:[NSURL fileURLWithPath:[LibraryConnection libraryRootPath] isDirectory:YES]];
  controller.libraryDidChangeHandler = ^{
    [[AppDelegate sharedDelegate] updateLibrary];
  };
  controller.openComicHandler = ^(NSURL* url) {
    self->_startupPresentationsPending = NO;
    [self->_pendingWebComicURL release];
    self->_pendingWebComicURL = [url copy];
    self->_webComicScanAttempts = 0;
    self->_pendingWebComicPageIndex = 0;
    self->_pendingWebComicPageCount = 0;
    self->_pendingWebComicCreatedCopy = NO;
    [self dismissViewControllerAnimated:YES completion:^{ [self _tryOpenPendingWebComic]; }];
  };
  CRAdaptiveToolNavigationController* navigation = [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:controller];
  navigation.modalPresentationStyle = UIModalPresentationFullScreen;
  [self presentViewController:navigation animated:YES completion:nil];
  [controller release];
  [navigation release];
}

- (void) _showPlus:(id)sender {
  if (self.presentedViewController || self.isBeingPresented || self.isBeingDismissed) {
    return;
  }
  CRPlusViewController* controller = [[CRPlusViewController alloc] init];
  CRAdaptiveToolNavigationController* navigation = [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:controller];
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
  CRAdaptiveToolNavigationController* navigation = [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:controller];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:navigation animated:YES completion:nil];
  [controller release];
  [navigation release];
}

- (void) _showCloud:(id)sender {
  if (self.presentedViewController || self.isBeingPresented || self.isBeingDismissed) return;
  CRPlusViewController* controller = [[CRPlusViewController alloc] init];
  controller.showsOnlyCloud = YES;
  CRAdaptiveToolNavigationController* navigation = [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:controller];
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

  _adaptiveViewportView = [[CRAdaptiveViewportView alloc] initWithFrame:self.view.bounds];
  _adaptiveViewportView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _adaptiveViewportView.adaptiveViewportDelegate = self;
  [self.view insertSubview:_adaptiveViewportView atIndex:0];
  [_adaptiveViewportView refreshViewport];

  // Grid background (XIB has it red by mistake — fix here)
  _gridView.backgroundColor = [UIColor clearColor];
  // This controller sets the grid frame after capturing its pre-layout geometry.
  _gridView.autoresizingMask = UIViewAutoresizingNone;
  
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
  _browserButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"globe"]
                                                       style:UIBarButtonItemStylePlain
                                                      target:self
                                                      action:@selector(_showWebBrowser:)];
  _browserButtonItem.accessibilityIdentifier = @"library.browser";
  _browserButtonItem.accessibilityLabel = @"Browse for Comics";
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
  CGRect initialViewport = [self _libraryViewportBounds];
  BOOL startsWithCompactNavigation =
    self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact ||
    CGRectGetWidth(initialViewport) < kLibraryRegularNavigationMinimumWidth;
  [self _configureNavigationForCompactWidth:startsWithCompactNavigation];
  
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
  UIScrollView* previousScroll = (UIScrollView*)[_emptyStateView viewWithTag:9901];
  CGPoint previousContentOffset = previousScroll ? previousScroll.contentOffset : CGPointZero;
  BOOL restoreScrollPosition = (previousScroll != nil);
  BOOL wasHidden = _emptyStateView ? _emptyStateView.hidden : !(_gridView.empty && (_currentCollection == nil));
  CGFloat previousAlpha = _emptyStateView ? _emptyStateView.alpha : 1.0;
  if (_emptyStateView) {
    [_emptyStateView removeFromSuperview];
    [_emptyStateView release];
    _emptyStateView = nil;
  }
  // Positioned over the grid view (below the nav bar) so centering needs no
  // nav-bar offset — frame is kept in sync in viewDidLayoutSubviews.
  _emptyStateView = [[UIView alloc] initWithFrame:_gridView.frame];
  _emptyStateView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _emptyStateView.hidden = wasHidden;
  _emptyStateView.alpha = previousAlpha;

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
  CGFloat horizontalInset = MIN(20.0, floor(w / 2.0));
  CGFloat cardW = MAX(0.0, MIN(w - 2.0 * horizontalInset, 600.0));
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
  CGFloat iconSize = MIN(110.0, w);
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
  CGSize titleSize = [titleLabel sizeThatFits:CGSizeMake(MAX(1.0, cardW), CGFLOAT_MAX)];
  titleLabel.frame = CGRectMake(cardX, y, cardW, ceil(titleSize.height));
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
  CGSize subtitleSize = [subtitleLabel sizeThatFits:CGSizeMake(MAX(1.0, cardW), CGFLOAT_MAX)];
  subtitleLabel.frame = CGRectMake(cardX, y, cardW, ceil(subtitleSize.height));
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
      @"Open from Finder",
      @"Double-click a comic, use Open With, or press ⌘O to read it without importing. Choose Add to Library in the reader when you want a copy." },
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
    BOOL stacksCardContents = cardW < 260.0;
    CGFloat cardInset = MIN(16.0, floor(cardW / 2.0));
    CGFloat badgeSize = MIN(36.0, cardW);
    CGFloat badgeX = stacksCardContents ? floor((cardW - badgeSize) / 2.0) : 16.0;
    UIView* badge = [[UIView alloc] initWithFrame:CGRectMake(badgeX, 16, badgeSize, badgeSize)];
    badge.backgroundColor = accentColor;
    badge.layer.cornerRadius = badgeSize / 2.0;
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
    if (!stacksCardContents) {
      UIImageSymbolConfiguration* cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
      UIImage* img = [UIImage systemImageNamed:steps[i].symbol withConfiguration:cfg];
      UIImageView* symView = [[UIImageView alloc] initWithImage:img];
      symView.tintColor = accentColor;
      symView.frame = CGRectMake(cardW - 48, 22, 26, 26);
      [card addSubview:symView];
      [symView release];
    }

    // Text
    CGFloat textX = stacksCardContents ? cardInset : 68.0;
    CGFloat textRightInset = stacksCardContents ? cardInset : 56.0;
    CGFloat textW = MAX(0.0, cardW - textX - textRightInset);
    CGFloat titleY = stacksCardContents ? CGRectGetMaxY(badge.frame) + 12.0 : 14.0;
    UILabel* stepTitle = [[UILabel alloc] initWithFrame:CGRectMake(textX, titleY, textW, 0)];
    stepTitle.text = steps[i].title;
    stepTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    stepTitle.textColor = stepTitleColor;
    stepTitle.numberOfLines = stacksCardContents ? 0 : 1;
    CGSize stepTitleSize = [stepTitle sizeThatFits:CGSizeMake(MAX(1.0, textW), CGFLOAT_MAX)];
    stepTitle.frame = CGRectMake(textX, titleY, textW, ceil(stepTitleSize.height));
    [card addSubview:stepTitle];

    UILabel* stepBody = [[UILabel alloc] initWithFrame:CGRectMake(textX, CGRectGetMaxY(stepTitle.frame) + 4, textW, 0)];
    stepBody.text = steps[i].body;
    stepBody.font = [UIFont systemFontOfSize:14];
    stepBody.textColor = stepBodyColor;
    stepBody.numberOfLines = 0;
    CGSize stepBodySize = [stepBody sizeThatFits:CGSizeMake(MAX(1.0, textW), CGFLOAT_MAX)];
    stepBody.frame = CGRectMake(textX, CGRectGetMaxY(stepTitle.frame) + 4, textW, ceil(stepBodySize.height));
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
  CGSize hintSize = [hint sizeThatFits:CGSizeMake(MAX(1.0, cardW), CGFLOAT_MAX)];
  hint.frame = CGRectMake(cardX, y, cardW, ceil(hintSize.height));
  [contentView addSubview:hint];
  y = CGRectGetMaxY(hint.frame);
  [hint release];

  // Seal contentView height and scroll contentSize
  contentView.frame = CGRectMake(0, 0, w, y);
  scroll.contentSize = CGSizeMake(w, y);
  [contentView release];

  [_gridView.superview insertSubview:_emptyStateView aboveSubview:_gridView];
  [self _centerEmptyStateContent];
  if (restoreScrollPosition) {
    CGFloat minimumOffset = -scroll.contentInset.top;
    CGFloat maximumOffset = MAX(minimumOffset, scroll.contentSize.height + scroll.contentInset.bottom - CGRectGetHeight(scroll.bounds));
    previousContentOffset.y = MIN(maximumOffset, MAX(minimumOffset, previousContentOffset.y));
    scroll.contentOffset = previousContentOffset;
  }
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

- (void) _captureGridLayoutSnapshot {
  self.gridSizeBeforeLayout = _gridView.bounds.size;
  self.gridContentMarginsBeforeLayout = _gridView.contentMargins;
  self.gridItemSpacingBeforeLayout = _gridView.itemSpacing;
  self.hasGridLayoutSnapshot = YES;

  NSArray* visibleItems = [_gridView visibleItems];
  id anchor = nil;
  if (self.adaptiveGridScrollAnchor) {
    for (id item in visibleItems) {
      if (item == self.adaptiveGridScrollAnchor || [item isEqual:self.adaptiveGridScrollAnchor]) {
        anchor = item;
        break;
      }
    }
  }
  if (!anchor) anchor = visibleItems.firstObject;
  if (anchor) {
    UIView* itemView = [_gridView viewForItem:anchor];
    if (itemView) {
      self.adaptiveGridScrollAnchor = anchor;
      self.adaptiveGridScrollAnchorY = CGRectGetMinY([_gridView convertRect:itemView.bounds fromView:itemView]);
    }
  } else if (_gridView.empty) {
    self.adaptiveGridScrollAnchor = nil;
  }
}

- (CGRect) _libraryViewportBounds {
  if (!_adaptiveViewportView) {
    return CRAdaptiveSafeBounds(self.view.bounds, self.view.safeAreaInsets);
  }
  _adaptiveViewportView.frame = self.view.bounds;
  [_adaptiveViewportView refreshViewport];
  return [_adaptiveViewportView convertRect:_adaptiveViewportView.viewportBounds toView:self.view];
}

- (void) adaptiveViewportView:(CRAdaptiveViewportView*)view
      didChangeViewportBounds:(CGRect)viewportBounds {
  [self.view setNeedsLayout];
}

- (void) viewWillLayoutSubviews {
  [self _captureGridLayoutSnapshot];
  [super viewWillLayoutSubviews];
}

- (void) viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];

  if (!self.hasGridLayoutSnapshot) [self _captureGridLayoutSnapshot];

  CGRect safeBounds = [self _libraryViewportBounds];
  BOOL isLandscape = CGRectGetWidth(safeBounds) > CGRectGetHeight(safeBounds);
  BOOL hasCompactSizeClass = self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
  BOOL usesCompactNavigation = hasCompactSizeClass ||
                               CGRectGetWidth(safeBounds) < kLibraryRegularNavigationMinimumWidth;
  BOOL usesCompactGrid = hasCompactSizeClass ||
                         CGRectGetWidth(safeBounds) < kLibraryCompactGridWidth;
  if (!_adaptiveLayoutConfigured || usesCompactNavigation != _usingCompactLayout) {
    [self _configureNavigationForCompactWidth:usesCompactNavigation];
  }

  CGFloat navigationHeight = MIN(44.0, CGRectGetHeight(safeBounds));
  _navigationBar.frame = CGRectMake(CGRectGetMinX(safeBounds), CGRectGetMinY(safeBounds),
                                    CGRectGetWidth(safeBounds), navigationHeight);
  CGFloat contentTop = CGRectGetMaxY(_navigationBar.frame);
  CGFloat contentBottom = CGRectGetMaxY(safeBounds);
  if (usesCompactNavigation) {
    CGFloat toolbarHeight = MIN(44.0, MAX(0.0, contentBottom - contentTop));
    _compactToolbar.frame = CGRectMake(CGRectGetMinX(safeBounds), contentBottom - toolbarHeight,
                                       CGRectGetWidth(safeBounds), toolbarHeight);
    contentBottom = CGRectGetMinY(_compactToolbar.frame);
  }

  CGFloat bannerInset = MIN(10.0, floor(CGRectGetWidth(safeBounds) / 2.0));
  CGFloat bannerWidth = MAX(0.0, CGRectGetWidth(safeBounds) - 2.0 * bannerInset);
  CGFloat availableContentHeight = MAX(0.0, contentBottom - contentTop);
  CGFloat bannerHeight = 0.0;
  if (_whatsNewBanner && !_releaseNewsDismissed && bannerWidth > 0.0) {
    CGFloat preferredHeight = [(CRWhatsNewBannerView*)_whatsNewBanner preferredHeightForWidth:bannerWidth];
    CGFloat maximumHeight = MAX(130.0, availableContentHeight * 0.45);
    bannerHeight = MIN(preferredHeight, maximumHeight);
  }
  CGFloat minimumGridHeight = MIN(kLibraryThumbnailHeight + 2.0 * kGridMargin, availableContentHeight);
  BOOL showBanner = bannerHeight > 0.0 &&
                    availableContentHeight - bannerHeight - 12.0 >= minimumGridHeight;
  if (_whatsNewBanner) _whatsNewBanner.hidden = !showBanner;
  if (showBanner) {
    _whatsNewBanner.frame = CGRectMake(CGRectGetMinX(safeBounds) + bannerInset, contentTop + 6,
                                       bannerWidth, bannerHeight);
    contentTop = CGRectGetMaxY(_whatsNewBanner.frame) + 6;
  }
  _gridView.frame = CGRectMake(CGRectGetMinX(safeBounds), contentTop,
                               CGRectGetWidth(safeBounds),
                               MAX(0.0, contentBottom - contentTop));

  if (usesCompactGrid) {
    CGFloat width = CGRectGetWidth(_gridView.bounds);
    CGFloat minimumGap = isLandscape ? 12.0 : 16.0;
    CGFloat outerMargin = MIN(kGridMargin, MAX(0.0, floor((width - kLibraryThumbnailWidth) / 2.0)));
    CGFloat availableWidth = MAX(0.0, width - 2.0 * outerMargin);
    NSUInteger columns = MAX(1, (NSUInteger)floor((availableWidth + minimumGap) /
                                                  (kLibraryThumbnailWidth + minimumGap)));
    CGFloat gap = 0.0;
    if (columns > 1) {
      CGFloat maximumGap = (availableWidth - columns * kLibraryThumbnailWidth) / (columns - 1);
      gap = MAX(0.0, MIN(isLandscape ? 16.0 : 20.0, maximumGap));
    }
    CGFloat groupWidth = columns * kLibraryThumbnailWidth + (columns - 1) * gap;
    CGFloat leftMargin = MAX(outerMargin, floor((width - groupWidth) / 2.0));
    CGFloat rightMargin = MAX(outerMargin, width - groupWidth - leftMargin);
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
  BOOL gridGeometryChanged = !CGSizeEqualToSize(self.gridSizeBeforeLayout, _gridView.bounds.size) ||
                             !UIEdgeInsetsEqualToEdgeInsets(self.gridContentMarginsBeforeLayout, _gridView.contentMargins) ||
                             !UIEdgeInsetsEqualToEdgeInsets(self.gridItemSpacingBeforeLayout, _gridView.itemSpacing);
  [_gridView setNeedsLayout];
  if (gridGeometryChanged) {
    self.suppressGridScrollingPersistence = YES;
    [_gridView layoutIfNeeded];
    if (self.adaptiveGridScrollAnchor) {
      // GridView creates one view per item, including offscreen items, so the
      // retained logical anchor remains addressable after a column reflow.
      UIView* itemView = [_gridView viewForItem:self.adaptiveGridScrollAnchor];
      if (itemView) {
        CGFloat updatedAnchorY = CGRectGetMinY([_gridView convertRect:itemView.bounds fromView:itemView]);
        _gridView.scrollingAmount += updatedAnchorY - self.adaptiveGridScrollAnchorY;
      }
    }
    self.suppressGridScrollingPersistence = NO;
    [self gridViewDidUpdateScrollingAmount:_gridView];
  }
  self.hasGridLayoutSnapshot = NO;

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
  self.adaptiveGridScrollAnchor = nil;
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
  ComicViewController* viewController = [[ComicViewController alloc] initWithComic:comic delegate:self];
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
  if (self.presentedViewController) {
    return;
  }
  if (!_comicPresentationActive) {
    if (_externalComicPresentationActive) {
      _externalComicPresentationActive = NO;
      [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_showRatingScreen) object:nil];
      [self performSelector:@selector(_showRatingScreen) withObject:nil afterDelay:kShowRatingDelay];
    }
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
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_showRatingScreen) object:nil];
  [self performSelector:@selector(_showRatingScreen) withObject:nil afterDelay:kShowRatingDelay];
}



- (void) viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  // A resized window can keep the same orientation and size class. Reuse the
  // bounds-based layout instead of replacing its grid metrics here.
  [self.view setNeedsLayout];
  [self.view layoutIfNeeded];
  if (_gridView.empty) {
    [self _setCurrentCollection:_currentCollection];
  }
}

- (void) _showRatingScreen {
  if (_startupPresentationsPending || !self.view.window ||
      self.presentedViewController || self.isBeingPresented || self.isBeingDismissed ||
      [[AppDelegate sharedDelegate] isAlertVisible] || [[AppDelegate sharedDelegate] isSpinnerVisible] ||
      [[LibraryUpdater sharedUpdater] isUpdating] || _pendingWebComicURL || _externalComicURLQueue.count > 0 ||
      _window.windowScene.activationState != UISceneActivationStateForegroundActive) {
    return;
  }
  [[CRReviewPrompt sharedPrompt] requestReviewIfEligibleInScene:_window.windowScene];
}

- (void) _requireUpdate {
  [self _forceUpdate];
  [[NSUserDefaults standardUserDefaults] setInteger:kLibraryVersion forKey:kDefaultKey_LibraryVersion];
}

- (void) _sceneDidActivate:(NSNotification*)notification {
  if (notification.object == _window.windowScene && _pendingWebComicURL) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self _tryOpenPendingWebComic]; });
  }
  if (notification.object == _window.windowScene && _externalComicURLQueue.count > 0) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self _drainExternalComicURLQueue]; });
  }
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
  if (_externalComicURLQueue.count > 0) {
    [self _drainExternalComicURLQueue];
    return;
  }
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
  
  _libraryUpdatePromptPending = needLibraryUpdate;
  _startupPresentationsPending = YES;
  [self _continueStartupPresentations];
}

- (void) viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];

  [self _refreshComicAfterDismissal];
  [self _tryOpenPendingWebComic];
  if (!_launched) {
    _launched = YES;
    _startupPresentationsPending = YES;
    [self performSelector:@selector(_viewDidReallyAppear) withObject:nil afterDelay:0.0];
  } else if (_startupPresentationsPending) {
    [self _continueStartupPresentations];
  } else {
    [self _drainExternalComicURLQueue];
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
    [self _tryOpenPendingWebComic];
    [self _drainExternalComicURLQueue];
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
  if (self.suppressGridScrollingPersistence) return;
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

- (void) gridViewDidBeginScrolling:(GridView*)gridView {
  self.adaptiveGridScrollAnchor = nil;
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

- (void)_presentComicDocumentPickerOpeningDirectly:(BOOL)opensComicsDirectly
                                    fromController:(UIViewController*)controller {
  if (!controller || controller.presentedViewController || controller.isBeingDismissed) return;
  NSMutableArray<UTType*>* types = [NSMutableArray arrayWithObject:UTTypePDF];
  for (NSString* extension in @[@"cbz", @"zip", @"cbr", @"rar"]) {
    UTType* type = [UTType typeWithFilenameExtension:extension];
    if (type && ![types containsObject:type]) [types addObject:type];
  }
  CRComicDocumentPickerViewController* picker = [[CRComicDocumentPickerViewController alloc]
    initForOpeningContentTypes:types asCopy:YES];
  picker.opensComicsDirectly = opensComicsDirectly;
  picker.delegate = self;
  picker.allowsMultipleSelection = YES;
  picker.presentationController.delegate = self;
  [controller presentViewController:picker animated:YES completion:nil];
  [picker release];
}

- (IBAction) purchase:(id)sender {
  void (^presentPicker)(void) = ^{
    // Add Files always imports a local copy, including on Catalyst.
    [self _presentComicDocumentPickerOpeningDirectly:NO fromController:self];
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
  BOOL opensComicsDirectly = [controller isKindOfClass:[CRComicDocumentPickerViewController class]] &&
    [(CRComicDocumentPickerViewController*)controller opensComicsDirectly];
  if (opensComicsDirectly) {
    NSMutableArray<NSURL*>* stagedURLs = [NSMutableArray arrayWithCapacity:urls.count];
    NSMutableArray<NSString*>* failedFilenames = [NSMutableArray array];
    for (NSURL* url in urls) {
      NSError* error = nil;
      NSURL* stagedURL = CRStageDirectOpenPickerCopy(url, &error);
      if (stagedURL) {
        [stagedURLs addObject:stagedURL];
      } else {
        XLOG_ERROR(@"Unable to stage direct-open picker copy at \"%@\": %@", url.path, error);
        [failedFilenames addObject:url.lastPathComponent ?: @"Selected file"];
        if (CRIsPickerOwnedCopyURL(url)) {
          [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
        }
      }
    }
    // The picker owns its dismissal. Queue immediately; draining waits until
    // the picker disappears, while the copied files remain in our container.
    [self _enqueueComicURLsForOpening:stagedURLs deletesFilesOnClose:YES];
    if (failedFilenames.count > 0) {
      [self performSelector:@selector(_showDirectOpenFailureAlertForFilenames:)
                 withObject:failedFilenames
                 afterDelay:0.1];
    }
    return;
  }
  for (NSURL* url in urls) {
    [[AppDelegate sharedDelegate] importComicAtURL:url];
  }
}


- (void)comicViewControllerDidRequestOpenComicFiles:(ComicViewController*)controller {
#if TARGET_OS_MACCATALYST
  if (self.presentedViewController == controller) {
    [self _presentComicDocumentPickerOpeningDirectly:YES fromController:controller];
  }
#endif
}

- (void)comicViewController:(ComicViewController*)controller
    didRequestAddExternalComicAtURL:(NSURL*)url
                   currentPageIndex:(NSInteger)currentPageIndex
                          pageCount:(NSInteger)pageCount {
  [[AppDelegate sharedDelegate] importComicAtURL:url
                               resultCompletion:^(BOOL imported, NSURL* libraryURL, BOOL createdCopy) {
    if (!imported || !libraryURL) {
      [controller externalComicImportDidFail];
      return;
    }
    [self->_pendingWebComicURL release];
    self->_pendingWebComicURL = [libraryURL copy];
    self->_webComicScanAttempts = 0;
    self->_pendingWebComicPageIndex = currentPageIndex;
    self->_pendingWebComicPageCount = pageCount;
    self->_pendingWebComicCreatedCopy = createdCopy;

    void (^openLibraryCopy)(void) = ^{
      [self _tryOpenPendingWebComic];
    };
    if (self.presentedViewController == controller) {
      [self dismissViewControllerAnimated:YES completion:openLibraryCopy];
    } else {
      openLibraryCopy();
    }
  }];
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
  [self _tryOpenPendingWebComic];
  [self _drainExternalComicURLQueue];
}

@end
