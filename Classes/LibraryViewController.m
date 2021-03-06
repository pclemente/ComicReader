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
#import "Defaults.h"
#import "Extensions_Foundation.h"
#import "Extensions_UIKit.h"
#import "NetReachability.h"

#import <SafariServices/SafariServices.h>
#import <StoreKit/StoreKit.h>

#define kAppStoreAppID @"409290355"
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
}
@property(nonatomic, assign) UIView* noteView;
@property(nonatomic, assign) UIView* ribbonView;
@end

@implementation ThumbnailView

@synthesize noteView=_noteView, ribbonView=_ribbonView;

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
}

- (void) _updateStatistics {
  NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[LibraryConnection libraryDatabasePath]
                                                                              error:nil];
  _infoLabel.text = [NSString stringWithFormat:NSLocalizedString(@"INFO_FORMAT", nil),
                                               [[LibraryConnection mainConnection] countObjectsOfClass:[Comic class]],
                                               [[LibraryConnection mainConnection] countObjectsOfClass:[Collection class]],
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
      _currentCollection = [[[LibraryConnection mainConnection] fetchObjectOfClass:[Collection class] withSQLRowID:collectionID] retain];
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

- (void) _toggleMenu:(id)sender {
  if (_menuController.popoverVisible) {
    [_menuController dismissPopoverAnimated:YES];
    [_updateTimer setFireDate:[NSDate distantFuture]];
  } else {
    [self _updateTimer:nil];
    [self _updateStatistics];
    [self updatePurchase];
    [_menuController presentPopoverFromBarButtonItem:sender permittedArrowDirections:UIPopoverArrowDirectionUp animated:YES];
    [_updateTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:kUpdateTimerInterval]];
  }
}

- (void) _tap:(UITapGestureRecognizer*)recognizer {
  if (recognizer.state == UIGestureRecognizerStateEnded) {
    DatabaseObject* item = [_gridView itemAtLocation:[recognizer locationInView:_gridView] view:NULL];
    if ([item isKindOfClass:[Comic class]]) {
      [self _presentComic:(Comic*)item];
    } else if ([item isKindOfClass:[Collection class]]) {
      [self gridViewDidUpdateScrollingAmount:nil];
      [self _setCurrentCollection:(Collection*)item];
    }
  }
}

- (void) _updateThumbnailViewForItem:(DatabaseObject*)item {
  ThumbnailView* view = (ThumbnailView*)[_gridView viewForItem:item];
  if (view && !view.hidden) {
    NSInteger status = [(id)item status];
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

- (void) _setStatus:(int)status {
  if (_selectedItem) {
    if ([_selectedItem isKindOfClass:[Comic class]]) {
      [(Comic*)_selectedItem setStatus:status];
      [[LibraryConnection mainConnection] updateObject:_selectedItem];
      [self _updateThumbnailViewForItem:_selectedItem];
      if ([[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_SortingMode] == kSortingMode_ByStatus) {
        [self _reloadCurrentCollection];
      }
    } else {
      [[LibraryConnection mainConnection] updateStatus:status forComicsInCollection:(Collection*)_selectedItem];
      [[LibraryConnection mainConnection] refetchObject:_selectedItem];
      [self _updateThumbnailViewForItem:_selectedItem];
    }
    [_selectedItem release];
    _selectedItem = nil;
  } else {
    XLOG_DEBUG_UNREACHABLE();
  }
}

- (void) _setRead:(id)sender {
  [self _setStatus:0];
  [[AppDelegate sharedDelegate] logEvent:@"menu.read"];
}

- (void) _setNew:(id)sender {
  [self _setStatus:-1];
  [[AppDelegate sharedDelegate] logEvent:@"menu.new"];
}

- (void) _delete:(id)sender {
  if (_selectedItem) {
    if ([_selectedItem isKindOfClass:[Comic class]]) {
      NSError* error = nil;
      if ([[NSFileManager defaultManager] removeItemAtPath:[[LibraryConnection mainConnection] pathForComic:(Comic*)_selectedItem] error:&error]) {
        [(AppDelegate*)[AppDelegate sharedInstance] updateLibrary];
      } else {
        XLOG_ERROR(@"Failed deleting comic \"%@\": %@", [(Comic*)_selectedItem name], error);
      }
    } else {
      NSError* error = nil;
      if ([[NSFileManager defaultManager] removeItemAtPath:[[LibraryConnection mainConnection] pathForCollection:(Collection*)_selectedItem] error:&error]) {
        [(AppDelegate*)[AppDelegate sharedInstance] updateLibrary];
      } else {
        XLOG_ERROR(@"Failed deleting comic \"%@\": %@", [(Collection*)_selectedItem name], error);
      }
    }
    [_selectedItem release];
    _selectedItem = nil;
  } else {
    XLOG_DEBUG_UNREACHABLE();
  }
  [[AppDelegate sharedDelegate] logEvent:@"menu.delete"];
}

- (void) _press:(UILongPressGestureRecognizer*)recognizer {
  if (recognizer.state == UIGestureRecognizerStateBegan) {
    [_selectedItem release];
    _selectedItem = [[_gridView itemAtLocation:[recognizer locationInView:_gridView] view:NULL] retain];
    if (_selectedItem) {
      NSInteger status = [(id)_selectedItem status];
      NSMutableArray* items = [[NSMutableArray alloc] init];
      if ([_selectedItem isKindOfClass:[Comic class]]) {
        if (status != 0) {
          UIMenuItem* item = [[UIMenuItem alloc] initWithTitle:NSLocalizedString(@"MARK_READ", nil) action:@selector(_setRead:)];
          [items addObject:item];
          [item release];
        }
        if (status >= 0) {
          UIMenuItem* item = [[UIMenuItem alloc] initWithTitle:NSLocalizedString(@"MARK_NEW", nil) action:@selector(_setNew:)];
          [items addObject:item];
          [item release];
        }
        if (1) {
          UIMenuItem* item = [[UIMenuItem alloc] initWithTitle:NSLocalizedString(@"DELETE", nil) action:@selector(_delete:)];
          [items addObject:item];
          [item release];
        }
      } else {
        if (status != 0) {
          UIMenuItem* item = [[UIMenuItem alloc] initWithTitle:NSLocalizedString(@"MARK_ALL_READ", nil) action:@selector(_setRead:)];
          [items addObject:item];
          [item release];
        }
        if (status >= 0) {
          UIMenuItem* item = [[UIMenuItem alloc] initWithTitle:NSLocalizedString(@"MARK_ALL_NEW", nil) action:@selector(_setNew:)];
          [items addObject:item];
          [item release];
        }
        if (1) {
          UIMenuItem* item = [[UIMenuItem alloc] initWithTitle:NSLocalizedString(@"DELETE_ALL", nil) action:@selector(_delete:)];
          [items addObject:item];
          [item release];
        }
      }
      CGPoint location = [recognizer locationInView:_gridView];
      [[UIMenuController sharedMenuController] setMenuItems:items];
      [[UIMenuController sharedMenuController] setTargetRect:CGRectMake(location.x, location.y, 1.0, 1.0) inView:_gridView];
      [[UIMenuController sharedMenuController] setMenuVisible:YES animated:YES];
      [items release];
    }
  }
}

- (void) viewDidLoad {
  [super viewDidLoad];
  
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = UIColor.systemBackgroundColor;
    } else {
        // Fallback on earlier versions
        self.view.backgroundColor = UIColor.whiteColor;
    }  // Can't do this in Interface Builder
  
  _gridView.contentBackgroundOffset = CGPointMake(0.0, kBackgroundOffset);
  _gridView.contentBackgroundColor = [UIColor colorWithPatternImage:[UIImage imageWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Background" ofType:@"png"]]];
  _gridView.delegate = self;
  UITapGestureRecognizer* tapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap:)];
  [_gridView addGestureRecognizer:tapRecognizer];
  [tapRecognizer release];
  UILongPressGestureRecognizer* pressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_press:)];
  pressRecognizer.minimumPressDuration = 0.3;  // Default is 0.5
  [_gridView addGestureRecognizer:pressRecognizer];
  [pressRecognizer release];
  
  UINavigationItem* item = [_navigationBar.items objectAtIndex:0];
  UIBarButtonItem* rightButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"SETTINGS_BUTTON", nil)
                                                                  style:UIBarButtonItemStyleBordered
                                                                 target:self
                                                                 action:@selector(_toggleMenu:)];
  item.rightBarButtonItem = rightButton;
  [rightButton release];
  
  UIViewController* viewController = [[UIViewController alloc] init];
  viewController.view = _menuView;
  _menuController = [[UIPopoverController alloc] initWithContentViewController:viewController];
  _menuController.delegate = self;
  _menuController.popoverContentSize = _menuView.frame.size;
  [viewController release];
  
  _infoLabel.text = nil;
  _versionLabel.text = [NSString stringWithFormat:NSLocalizedString(@"VERSION_FORMAT", nil),
                                                  [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
  BOOL updating = [[LibraryUpdater sharedUpdater] isUpdating];
  _markReadButton.enabled = !updating;
  _markNewButton.enabled = !updating;
  _updateButton.enabled = !updating;
  _forceUpdateButton.enabled = !updating;
  _dimmingSwitch.on = [(AppDelegate*)[AppDelegate sharedInstance] isScreenDimmed];
  
  if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iOS_7_0) {
    //[_purchaseButton setTitleColor:[UIColor lightGrayColor] forState:UIControlStateDisabled];
    //[_restoreButton setTitleColor:[UIColor lightGrayColor] forState:UIControlStateDisabled];
  }
  
  XLOG_DEBUG_CHECK(_updateTimer == nil);
  _updateTimer = [[NSTimer alloc] initWithFireDate:[NSDate distantFuture] interval:kUpdateTimerInterval target:self selector:@selector(_updateTimer:) userInfo:nil repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
    
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
}

- (void) _setCurrentCollection:(Collection*)collection {
  NSMutableArray* barItems = [[NSMutableArray alloc] initWithArray:_navigationBar.items];
  if (barItems.count == 2) {
    [barItems removeObjectAtIndex:1];
  }
  if (collection) {
    UINavigationItem* item = [[UINavigationItem alloc] initWithTitle:collection.name];
    UIBarButtonItem* button = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"SETTINGS_BUTTON", nil)
                                                               style:UIBarButtonItemStyleBordered
                                                              target:self
                                                              action:@selector(_toggleMenu:)];
    item.rightBarButtonItem = button;
    [button release];
    [barItems addObject:item];
    [item release];
  }
  _navigationBar.items = barItems;
  [barItems release];
  
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
    [self presentModalViewController:viewController animated:YES];
    [viewController release];
    
    if (comic != _currentComic) {
      [_currentComic release];
      _currentComic = [comic retain];
    }
  }
}



- (void) viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  
  if (UIInterfaceOrientationIsLandscape(self.interfaceOrientation)) {
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

  // Launch screens are used on iOS 8 and later
  if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iOS_8_0) {
    if (_launched == NO) {
      _launchView = [[UIImageView alloc] initWithFrame:self.view.bounds];
      _launchView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      NSString* path = [[NSBundle mainBundle] pathForResource:(UIInterfaceOrientationIsLandscape(self.interfaceOrientation) ? @"Default-Landscape" : @"Default-Portrait") ofType:@"png"];
      UIImage* image = [[UIImage alloc] initWithContentsOfFile:path];
      _launchView.image = image;
      [image release];
      [self.view addSubview:_launchView];
      _launched = YES;
    }
  }
}

- (void) _rateNow:(id)argument {
  [[AppDelegate sharedDelegate] logEvent:@"rating.now"];
  [[NSUserDefaults standardUserDefaults] setInteger:-1 forKey:kDefaultKey_LaunchCount];
  
  NSString* appURL;
  float version = [[UIDevice currentDevice].systemVersion floatValue];
  if (version >= 7.0 && version < 7.1) {
    appURL = [NSString stringWithFormat:kiOS7AppStoreURLFormat, kAppStoreAppID];
  } else {
    appURL = [NSString stringWithFormat:kiOSAppStoreURLFormat, kAppStoreAppID];
  }
  [[UIApplication sharedApplication] openURL:[NSURL URLWithString:appURL]];
}

- (void) _rateLater:(id)argument {
  [[AppDelegate sharedDelegate] logEvent:@"rating.later"];
  [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:kDefaultKey_LaunchCount];
}

- (void) _showRatingScreen {
  [[AppDelegate sharedDelegate] logEvent:@"rating.prompt"];
  [[AppDelegate sharedDelegate] showAlertWithTitle:NSLocalizedString(@"RATE_ALERT_TITLE", nil)
                                           message:NSLocalizedString(@"RATE_ALERT_MESSAGE", nil)
                                     confirmButton:NSLocalizedString(@"RATE_ALERT_CONFIRM", nil)
                                      cancelButton:NSLocalizedString(@"RATE_ALERT_CANCEL", nil)
                                          delegate:self
                                   confirmSelector:@selector(_rateNow:)
                                    cancelSelector:@selector(_rateLater:)
                                          argument:nil];
  [[UIApplication sharedApplication] endIgnoringInteractionEvents];
}

- (void) _requireUpdate {
  [self _forceUpdate];
  [[NSUserDefaults standardUserDefaults] setInteger:kLibraryVersion forKey:kDefaultKey_LibraryVersion];
}

- (void) _viewDidReallyAppear {
  BOOL needLibraryUpdate = [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_LibraryVersion] != kLibraryVersion;
  if (needLibraryUpdate) {
    XLOG_VERBOSE(@"Library is outdated at version %i", (int)[[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_LibraryVersion]);
    [_currentComic release];
    _currentComic = nil;
  }
  
  if (_currentComic) {
    Comic* comic = [[_currentComic retain] autorelease];
    [_currentComic release];
    _currentComic = nil;
    
    [self _presentComic:comic];
  }
  
  [CATransaction flush];

  if (_launchView) {
    UIView* launchView = _launchView;
    [UIView animateWithDuration:0.5 animations:^{
      launchView.alpha = 0.0;
      self.view.frame = [[UIScreen mainScreen] applicationFrame];
    } completion:^(BOOL finished) {
      [launchView removeFromSuperview];
      [launchView release];
    }];
    _launchView = nil;
  }
  
  NSInteger count = [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_LaunchCount];
  if (count >= 0) {
    [[NSUserDefaults standardUserDefaults] setInteger:(count + 1) forKey:kDefaultKey_LaunchCount];
    if (!needLibraryUpdate && (count + 1 >= kLaunchCountBeforeRating) && !self.modalViewController && [[NetReachability sharedNetReachability] state]) {
      [[UIApplication sharedApplication] beginIgnoringInteractionEvents];
      [self performSelector:@selector(_showRatingScreen) withObject:nil afterDelay:kShowRatingDelay];
    } else {
      XLOG_VERBOSE(@"Launch count is now %i", (int)[[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_LaunchCount]);
    }
  }
  
  if (needLibraryUpdate) {
    [[AppDelegate sharedInstance] showAlertWithTitle:NSLocalizedString(@"REQUIRE_UPDATE_TITLE", nil)
                                             message:NSLocalizedString(@"REQUIRE_UPDATE_MESSAGE", nil)
                                       confirmButton:NSLocalizedString(@"REQUIRE_UPDATE_CONTINUE", nil)
                                        cancelButton:NSLocalizedString(@"REQUIRE_UPDATE_CANCEL", nil)
                                            delegate:self
                                     confirmSelector:@selector(_requireUpdate)
                                      cancelSelector:NULL
                                            argument:nil];
  }
}

- (void) viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  
  if (_launchView) {
    [self performSelector:@selector(_viewDidReallyAppear) withObject:nil afterDelay:0.0];  // Work around interface orientation not already set in -viewDidAppear before iOS 6.0 but instead set after -didRotateFromInterfaceOrientation gets called
  }
    
    if ([[NSUserDefaults standardUserDefaults] integerForKey:@"LaunchCount"] % 10 == 0) {
        if (@available(iOS 10.3, *)) {
            [SKStoreReviewController requestReview];
        }
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
  if ([self.modalViewController isKindOfClass:[ComicViewController class]]) {
    [(ComicViewController*)self.modalViewController saveState];
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
  if (_menuController.popoverVisible) {
    [self _updateStatistics];
  }
}

- (void) libraryUpdaterDidFinish:(LibraryUpdater*)library {
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
  
  int status = [item status];
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
  [[LibraryConnection mainConnection] updateStatusForAllComics:0];
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
  [[LibraryConnection mainConnection] updateStatusForAllComics:-1];
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
  [_menuController dismissPopoverAnimated:YES];
  [_updateTimer setFireDate:[NSDate distantFuture]];
  [[AppDelegate sharedInstance] showLogViewController];
}

- (IBAction) toggleDimming:(id)sender {
  [(AppDelegate*)[AppDelegate sharedInstance] setScreenDimmed:_dimmingSwitch.on];
}

- (IBAction) purchase:(id)sender {
    NSString *urlString = _addressLabel.text;
    //NSLog(@"URL STRING");
    //NSLog(urlString);
    NSDataDetector *detect = [[NSDataDetector alloc] initWithTypes:NSTextCheckingTypeLink error:nil];
    NSArray *matches = [detect matchesInString:urlString options:0 range:NSMakeRange(0, [urlString length])];
    //NSLog(@"%@", [matches objectAtIndex:1]);
    NSRange addressMatchRange = [[matches objectAtIndex:0] range];
    NSString *matchString = [urlString substringWithRange:addressMatchRange];
    //NSLog(@"%@", matchString);
    NSURL *myUrl = [NSURL URLWithString: matchString];
    SFSafariViewController *svc = [[SFSafariViewController alloc] initWithURL: myUrl];
    //svc.delegate = self;
    [self dismissViewControllerAnimated:true completion:nil];
    [self presentViewController:svc animated:YES completion:nil];
  //[(AppDelegate*)[AppDelegate sharedInstance] purchase];
}

- (IBAction) restore:(id)sender {
  [(AppDelegate*)[AppDelegate sharedInstance] restore];
}

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    [self dismissViewControllerAnimated:true completion:nil];
}

@end
