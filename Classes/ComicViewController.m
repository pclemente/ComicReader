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

#import <QuartzCore/QuartzCore.h>
#import "AppDelegate.h"
#import "ComicViewController.h"
#import "ZoomView.h"
#import "MiniZip.h"
#import "UnRAR.h"
#import "ImageDecompression.h"

#import "Defaults.h"
#import "CRAdaptiveViewport.h"
#import "CRComicPageSource.h"
#import "CRLibrarySyncCoordinator.h"
#import "ComicFlow-Swift.h"

#define kMaxPageSize 1500.0
#define kLeftZoneRatio 0.2
#define kRightZoneRatio 0.8
#define kDoubleTapZoomRatio 1.5
#define kReaderChromeHeight 44.0
#define kReaderCompactWidth 600.0

CGRect CRReaderContentBounds(CGRect bounds, UIEdgeInsets safeAreaInsets) {
  return CRAdaptiveSafeBounds(bounds, safeAreaInsets);
}

NSString* CRDirectOpenTemporaryRootPath(void) {
  return [NSTemporaryDirectory() stringByAppendingPathComponent:@"ComicReaderDirectOpen"];
}

void CRRemoveDirectOpenTemporaryFileAtURL(NSURL* url) {
  if (!url.isFileURL) return;
  NSString* root = [CRDirectOpenTemporaryRootPath() stringByStandardizingPath];
  NSString* directory = [[url.path stringByDeletingLastPathComponent] stringByStandardizingPath];
  // Every direct-open selection gets its own UUID directory. Restrict cleanup
  // to one of those immediate children so an ownership bug cannot remove a
  // user-selected source or the temporary directory itself.
  if (![[directory stringByDeletingLastPathComponent] isEqualToString:root]) return;
  NSError* error = nil;
  if (![[NSFileManager defaultManager] removeItemAtPath:directory error:&error] &&
      error.code != NSFileNoSuchFileError) {
    XLOG_ERROR(@"Unable to remove direct-open temporary directory at \"%@\": %@", directory, error);
  }
}

@interface ComicDocumentView : DocumentView
@end

@interface ComicPageView : ZoomView {
@private
  NSString* _file;
  CGFloat _renderedDisplayScale;
}
@property(nonatomic, copy) NSString* file;
@property(nonatomic) CGFloat renderedDisplayScale;
- (id) initWithTapTarget:(id)target action:(SEL)action;
- (void) displayImage:(UIImage*)anImage;
@end

@implementation ComicDocumentView

// If we are zoomed out on a page, make sure the DocumentView built-in pan gesture recognizer is allowed to work simultaneously with the UIScrollView native one
// This is required since iOS 8
- (BOOL) gestureRecognizer:(UIGestureRecognizer*)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)otherGestureRecognizer {
  ComicPageView* pageView = (ComicPageView*)self.selectedPageView;
  if (pageView && otherGestureRecognizer == pageView.panGestureRecognizer &&
      pageView.zoomScale <= pageView.minimumZoomScale) {
    return YES;
  }
  return NO;
}

@end

@implementation ComicPageView

@synthesize file=_file, renderedDisplayScale=_renderedDisplayScale;

- (id) initWithTapTarget:(id)target action:(SEL)action {
  if ((self = [super init])) {
    self.displayMode = kZoomViewDisplayMode_Fit;
    self.doubleTapZoom = kDoubleTapZoomRatio;
    self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    
    self.alwaysBounceHorizontal = NO;
    self.alwaysBounceVertical = NO;
    
    UITapGestureRecognizer* recognizer = [[UITapGestureRecognizer alloc] initWithTarget:target action:action];
    [recognizer requireGestureRecognizerToFail:self.doubleTapRecognizer];
    [self addGestureRecognizer:recognizer];
    [recognizer release];
  }
  return self;
}

- (void) displayImage:(UIImage*)anImage {
  if (anImage) {
    // A display-scale refresh must not replace the zoomed view: doing so resets
    // ZoomView's viewport state. The decoded page has the same source aspect,
    // so updating the existing image preserves its coordinate space and focus.
    if ([self.displayView isKindOfClass:[UIImageView class]]) {
      [(UIImageView*)self.displayView setImage:anImage];
    } else {
      UIImageView* imageView = [[UIImageView alloc] initWithImage:anImage];
      [self setDisplayView:imageView];
      [imageView release];
    }
  } else {
    _renderedDisplayScale = 0.0;
    [self setDisplayView:nil];
  }
}

- (void) dealloc {
  [_file release];
  
  [super dealloc];
}

@end

@interface ComicViewController () <CRPageBookmarksViewControllerDelegate, CRReaderImageFiltersDelegate, CRComicTextViewControllerDelegate, CRAdaptiveViewportViewDelegate>
- (void)_configureReaderChromeForNarrowWidth:(BOOL)narrow usesSeparateToolsToolbar:(BOOL)usesToolbar;
- (void)_setReaderChromeHidden:(BOOL)hidden;
- (CGRect)_readerViewportBounds;
- (CGFloat)_displayScaleForPageView:(UIView*)pageView documentView:(DocumentView*)documentView;
- (void)_scheduleSelectedPageScaleRefresh;
- (void)_refreshSelectedPageScaleIfNeeded;
- (void)_previousPageCommand:(UIKeyCommand*)command;
- (void)_nextPageCommand:(UIKeyCommand*)command;
- (void)_openComicFilesCommand:(UIKeyCommand*)command;
#if TARGET_OS_MACCATALYST
- (void)open:(id)sender;
#endif
- (BOOL)_loadComicContentsAtPath:(NSString*)path;
- (void)_logComicReadEvent;
- (void)_addExternalComicToLibrary:(id)sender;
- (BOOL)_reviewPromptNotificationMatchesCurrentScene:(NSNotification*)notification;
- (void)_reviewPromptSceneWillDeactivate:(NSNotification*)notification;
- (void)_reviewPromptSceneDidActivate:(NSNotification*)notification;
@end

@implementation ComicViewController

@synthesize navigationBar=_navigationBar, navigationControl=_navigationControl, contentView=_contentView;

+ (BOOL)isSupportedComicFileURL:(NSURL*)url {
  if (!url.isFileURL || [url.lastPathComponent hasPrefix:@"."]) return NO;
  return [@[@"pdf", @"cbz", @"zip", @"cbr", @"rar"] containsObject:url.pathExtension.lowercaseString];
}

- (BOOL) prefersStatusBarHidden {
  return YES;
}

- (BOOL) canBecomeFirstResponder {
  return YES;
}

- (NSArray<UIKeyCommand*>*) keyCommands {
  UIKeyCommand* previous = [UIKeyCommand keyCommandWithInput:UIKeyInputLeftArrow
                                               modifierFlags:0
                                                      action:@selector(_previousPageCommand:)];
  previous.discoverabilityTitle = @"Previous Page";
  previous.wantsPriorityOverSystemBehavior = YES;
  UIKeyCommand* next = [UIKeyCommand keyCommandWithInput:UIKeyInputRightArrow
                                           modifierFlags:0
                                                  action:@selector(_nextPageCommand:)];
  next.discoverabilityTitle = @"Next Page";
  next.wantsPriorityOverSystemBehavior = YES;
  return @[previous, next];
}

#if TARGET_OS_MACCATALYST
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
  if (action == @selector(open:)) {
    return _externalComicDelegate != nil && self.presentedViewController == nil &&
      !self.isBeingPresented && !self.isBeingDismissed;
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

- (void) _previousPageCommand:(UIKeyCommand*)command {
  if (_readerReady && !self.presentedViewController) {
    [_documentView goToPreviousPage:NO];
  }
}

- (void) _nextPageCommand:(UIKeyCommand*)command {
  if (_readerReady && !self.presentedViewController) {
    [_documentView goToNextPage:NO];
  }
}

- (void)_openComicFilesCommand:(UIKeyCommand*)command {
  if (!self.presentedViewController && _externalComicDelegate) {
    [_externalComicDelegate comicViewControllerDidRequestOpenComicFiles:self];
  }
}

- (id) initWithComic:(Comic*)comic {
  return [self initWithComic:comic delegate:nil];
}

- (id)initWithComic:(Comic*)comic delegate:(id<CRExternalComicReaderDelegate>)delegate {
  [CATransaction begin];
  [[AppDelegate sharedInstance] showSpinnerWithMessage:NSLocalizedString(@"SPINNER_MESSAGE", nil) fullScreen:NO animated:YES];
  [CATransaction flush];
  [CATransaction commit];
  
  XLOG_DEBUG_CHECK(comic.sqlRowID);
  if ((self = [super init])) {
    _externalComicDelegate = delegate;
    _comic = [comic retain];
    _path = [[[LibraryConnection mainConnection] pathForComic:_comic] copy];
    if (![self _loadComicContentsAtPath:_path]) {
      XLOG_ERROR(@"Failed loading comic at \"%@\"", _path);
      [self release];
      return nil;
    }
    [self _logComicReadEvent];
  }
  return self;
}

- (id)initWithExternalFileURL:(NSURL*)url delegate:(id<CRExternalComicReaderDelegate>)delegate {
  return [self initWithExternalFileURL:url delegate:delegate deletesFileOnDealloc:NO];
}

- (id)initWithExternalFileURL:(NSURL*)url
                     delegate:(id<CRExternalComicReaderDelegate>)delegate
         deletesFileOnDealloc:(BOOL)deletesFileOnDealloc {
  if (![[self class] isSupportedComicFileURL:url]) {
    if (deletesFileOnDealloc) CRRemoveDirectOpenTemporaryFileAtURL(url);
    [self release];
    return nil;
  }

  [CATransaction begin];
  [[AppDelegate sharedInstance] showSpinnerWithMessage:NSLocalizedString(@"SPINNER_MESSAGE", nil) fullScreen:NO animated:YES];
  [CATransaction flush];
  [CATransaction commit];

  if ((self = [super init])) {
    _externalFileURL = [url copy];
    _externalComicDelegate = delegate;
    _deletesExternalFileOnDealloc = deletesFileOnDealloc;
    _securityScopedAccessStarted = [_externalFileURL startAccessingSecurityScopedResource];

    __block BOOL valid = NO;
    __block NSError* validationError = nil;
    NSError* coordinationError = nil;
    NSFileCoordinator* coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
    [coordinator coordinateReadingItemAtURL:_externalFileURL
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&coordinationError
                                 byAccessor:^(NSURL* readableURL) {
      NSNumber* regularFile = nil;
      CRComicPageSource* source = nil;
      if ([readableURL getResourceValue:&regularFile
                                 forKey:NSURLIsRegularFileKey
                                  error:&validationError] && regularFile.boolValue) {
        source = [[CRComicPageSource alloc] initWithPath:readableURL.path error:&validationError];
      }
      self->_path = [readableURL.path copy];
      valid = source.pageCount > 0 && [self _loadComicContentsAtPath:self->_path];
      [source release];
    }];
    if (!valid) {
      XLOG_ERROR(@"Failed loading external comic at \"%@\": %@", _externalFileURL.path,
                 coordinationError ?: validationError);
      [self release];
      return nil;
    }
    [self _logComicReadEvent];
  } else if (deletesFileOnDealloc) {
    CRRemoveDirectOpenTemporaryFileAtURL(url);
  }
  return self;
}

- (BOOL)_loadComicContentsAtPath:(NSString*)path {
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
  NSString* extension = path.pathExtension;
  if (![extension caseInsensitiveCompare:@"pdf"]) {
    _type = kComicType_PDF;
    CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((CFURLRef)[NSURL fileURLWithPath:path]);
    if (document) {
      _contents = [[NSNumber alloc] initWithInteger:CGPDFDocumentGetNumberOfPages(document)];
      CGPDFDocumentRelease(document);
    }
  } else if (![extension caseInsensitiveCompare:@"zip"] || ![extension caseInsensitiveCompare:@"cbz"] ||
             ![extension caseInsensitiveCompare:@"rar"] || ![extension caseInsensitiveCompare:@"cbr"]) {
    _type = kComicType_ZIP;
    _contents = [[MiniZip alloc] initWithArchiveAtPath:path];
    if (_contents == nil) {
      _type = kComicType_RAR;
      _contents = [[UnRAR alloc] initWithArchiveAtPath:path];
    }
  }
  return _contents != nil;
}

- (void)_logComicReadEvent {
  NSString* type = @"";
  switch (_type) {
    case kComicType_PDF: type = @"PDF"; break;
    case kComicType_ZIP: type = @"ZIP"; break;
    case kComicType_RAR: type = @"RAR"; break;
  }
  [[AppDelegate sharedDelegate] logEvent:@"comic.read" withParameterName:@"type" value:type];
}

- (NSURL*)externalFileURL {
  return _externalFileURL;
}

- (BOOL)isExternalComic {
  return _externalFileURL != nil;
}

- (void) dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  _documentView.delegate = nil;
  _navigationControl.delegate = nil;
  
  [_navigationBar release];
  [_navigationControl release];
  [_contentView release];
  
  [_pageLabel release];
  [_documentView release];
  [_bookmarksButtonItem release];
  [_filtersButtonItem release];
  [_textButtonItem release];
  [_addToLibraryButtonItem release];
  [_toolsToolbar release];
  _adaptiveViewportView.adaptiveViewportDelegate = nil;
  [_adaptiveViewportView release];
  [_contents release];
  [_path release];
  [_comic release];
  if (_securityScopedAccessStarted) {
    [_externalFileURL stopAccessingSecurityScopedResource];
  }
  if (_deletesExternalFileOnDealloc) {
    CRRemoveDirectOpenTemporaryFileAtURL(_externalFileURL);
  }
  [_externalFileURL release];
  
  [[AppDelegate sharedInstance] hideSpinner:NO];  // Just in case
  
  [super dealloc];
}

- (void) saveState {
  if (!_comic || !_readerReady || _documentView.pageViews.count == 0) {
    return;
  }
  NSInteger status = (_documentView.selectedPageIndex < _documentView.pageViews.count - 1 ? _documentView.selectedPageIndex : 0);
  if (status != _comic.status) {
    _comic.status = (int)status;
    [[LibraryConnection mainConnection] updateObject:_comic];
  }
  [[CRLibrarySyncCoordinator sharedCoordinator] recordComic:_comic currentPage:_documentView.selectedPageIndex pageCount:_documentView.pageViews.count];
}

- (BOOL) navigationBar:(UINavigationBar*)navigationBar shouldPopItem:(UINavigationItem*)item {
  [self dismissViewControllerAnimated:YES completion:nil];
  return YES;
}

- (CGFloat) _displayScaleForPageView:(UIView*)pageView documentView:(DocumentView*)documentView {
  // A page is normally attached before this delegate callback. Prefer its
  // traits when attached, then fall back through attached reader containers so
  // alternate DocumentView visibility policies cannot silently use scale 1.
  CGFloat displayScale = pageView.superview ? pageView.traitCollection.displayScale : 0.0;
  if (displayScale <= 0.0) displayScale = documentView.traitCollection.displayScale;
  if (displayScale <= 0.0) displayScale = self.traitCollection.displayScale;
  return displayScale > 0.0 ? displayScale : 1.0;
}

- (void) documentView:(DocumentView*)documentView willShowPageView:(UIView*)view {
  CGFloat displayScale = [self _displayScaleForPageView:view documentView:documentView];
  CGFloat maxPageSize = kMaxPageSize * displayScale;
  CGImageRef imageRef = NULL;
  if (_type == kComicType_PDF) {
    CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((CFURLRef)[NSURL fileURLWithPath:_path]);  // Don't keep CGPDFDocument around as it caches pages content heavily
    if (document) {
      CGPDFPageRef page = CGPDFDocumentGetPage(document, view.tag);
      if (page) {
        imageRef = CreateCGImageFromPDFPage(page, CGSizeMake(maxPageSize, maxPageSize), NO);
      }
      CGPDFDocumentRelease(document);
    }
  } else {
    NSString* temp = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    if ([_contents extractFile:[(ComicPageView*)view file] toPath:temp]) {
      NSData* data = [[NSData alloc] initWithContentsOfFile:temp];
      if (data) {
        NSString* extension = [[(ComicPageView*)view file] pathExtension];
        imageRef = CreateCGImageFromFileData(data, extension, CGSizeMake(maxPageSize, maxPageSize), NO);
        [data release];
      }
      [[NSFileManager defaultManager] removeItemAtPath:temp error:NULL];
    }
  }
  if (imageRef) {
    UIImage* image = [[UIImage alloc] initWithCGImage:imageRef];
    ComicPageView* pageView = (ComicPageView*)view;
    UIImage* displayImage = [CRReaderImageFilters displayImage:image];
    [pageView displayImage:displayImage];
    pageView.renderedDisplayScale = displayImage ? displayScale : 0.0;
    [image release];
    view.backgroundColor = [UIColor blackColor];
    CGImageRelease(imageRef);
  } else {
    view.backgroundColor = [UIColor redColor];
  }
}

- (void) documentView:(DocumentView*)documentView didHidePageView:(UIView*)view {
  [(ComicPageView*)view displayImage:nil];
  view.backgroundColor = nil;
}

- (void) documentViewDidReachFirstPage:(DocumentView*)documentView {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void) documentViewDidReachLastPage:(DocumentView*)documentView {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void) viewDidLoad {
  [super viewDidLoad];

  NSNotificationCenter* notificationCenter = [NSNotificationCenter defaultCenter];
  [notificationCenter addObserver:self
                         selector:@selector(_reviewPromptSceneWillDeactivate:)
                             name:UISceneWillDeactivateNotification
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(_reviewPromptSceneWillDeactivate:)
                             name:UISceneDidDisconnectNotification
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(_reviewPromptSceneDidActivate:)
                             name:UISceneDidActivateNotification
                           object:nil];
  
  self.view.clipsToBounds = YES;  // Required on iOS 7

  _adaptiveViewportView = [[CRAdaptiveViewportView alloc] initWithFrame:self.view.bounds];
  _adaptiveViewportView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _adaptiveViewportView.adaptiveViewportDelegate = self;
  [self.view insertSubview:_adaptiveViewportView atIndex:0];
  [_adaptiveViewportView refreshViewport];
  
  UINavigationItem* item = [[UINavigationItem alloc] initWithTitle:[_path lastPathComponent]];
  _bookmarksButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"bookmark"]
                                                          style:UIBarButtonItemStylePlain
                                                         target:self
                                                         action:@selector(_showPageBookmarks:)];
  _bookmarksButtonItem.accessibilityLabel = @"Page bookmarks";
  _bookmarksButtonItem.accessibilityIdentifier = @"reader.bookmarks.open";
  _filtersButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"camera.filters"]
                                                        style:UIBarButtonItemStylePlain
                                                       target:self
                                                       action:@selector(_showImageFilters:)];
  _filtersButtonItem.accessibilityLabel = @"Image Filters";
  _filtersButtonItem.accessibilityIdentifier = @"reader.filters.open";
  _textButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"text.magnifyingglass"]
                                                     style:UIBarButtonItemStylePlain
                                                    target:self
                                                    action:@selector(_showComicText:)];
  _textButtonItem.accessibilityLabel = @"Comic text and search";
  _textButtonItem.accessibilityIdentifier = @"reader.text.open";
  if (_externalFileURL) {
    _addToLibraryButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Add to Library"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(_addExternalComicToLibrary:)];
    _addToLibraryButtonItem.accessibilityIdentifier = @"reader.external.addToLibrary";
    _addToLibraryButtonItem.accessibilityLabel = @"Add to Library";
  }
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(readerImageFiltersDidChange) name:[CRPlusStore entitlementDidChangeNotification] object:[CRPlusStore sharedStore]];
  [_navigationBar pushNavigationItem:item animated:NO];
  [item release];
  _navigationBar.hidden = YES;
  _navigationControl.delegate = self;
  _navigationControl.continuous = NO;
  _navigationControl.margins = UIEdgeInsetsMake(0, 80, 20, 80);
  _navigationControl.constrainOverlayToSuperview = YES;
  _navigationControl.hidden = YES;
  _toolsToolbar = [[UIToolbar alloc] initWithFrame:CGRectZero];
  _toolsToolbar.hidden = YES;
  _toolsToolbar.tintColor = [UIColor whiteColor];
  _toolsToolbar.accessibilityIdentifier = @"reader.compactTools";
  [self.view addSubview:_toolsToolbar];
  _contentView.backgroundColor = nil;
  _contentView.accessibilityIdentifier = @"reader.canvas";
  // DocumentView keeps neighboring pages in a strip wider than its bounds.
  // Mask that strip at the active pane, including while the pane is resizing.
  _contentView.clipsToBounds = YES;
  
  _documentView = [[ComicDocumentView alloc] initWithFrame:_contentView.bounds];
  _documentView.delegate = self;
  _documentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [_contentView addSubview:_documentView];
  // Keep the scrubber and its overlay inside the same safe rectangle as the page.
  [_navigationControl removeFromSuperview];
  [_contentView addSubview:_navigationControl];
  
  _pageLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 160, 24)];
  _pageLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
  _pageLabel.textColor = [UIColor whiteColor];
  _pageLabel.textAlignment = NSTextAlignmentCenter;
  _pageLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
  _pageLabel.layer.cornerRadius = 12;
  _pageLabel.layer.masksToBounds = YES;
  _pageLabel.opaque = NO;
  
  // Style comic reader nav bar
  if (@available(iOS 15.0, *)) {
    UINavigationBarAppearance* appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
    NSDictionary* titleAttr = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
    appearance.titleTextAttributes = titleAttr;
    _navigationBar.standardAppearance = appearance;
    _navigationBar.scrollEdgeAppearance = appearance;
    [appearance release];
  }
  _navigationBar.tintColor = [UIColor whiteColor];
  if (@available(iOS 15.0, *)) {
    UIToolbarAppearance* toolbarAppearance = [[UIToolbarAppearance alloc] init];
    [toolbarAppearance configureWithOpaqueBackground];
    toolbarAppearance.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
    _toolsToolbar.standardAppearance = toolbarAppearance;
    _toolsToolbar.scrollEdgeAppearance = toolbarAppearance;
    [toolbarAppearance release];
  }
  CGRect initialBounds = [self _readerViewportBounds];
  BOOL startsNarrow = self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact ||
                      CGRectGetWidth(initialBounds) < kReaderCompactWidth;
  BOOL startsWithToolbar = startsNarrow && CGRectGetHeight(initialBounds) >= 3.0 * kReaderChromeHeight;
  [self _configureReaderChromeForNarrowWidth:startsNarrow usesSeparateToolsToolbar:startsWithToolbar];
}

- (void) _configureReaderChromeForNarrowWidth:(BOOL)narrow usesSeparateToolsToolbar:(BOOL)usesToolbar {
  _usingNarrowLayout = narrow;
  _usingCompactLayout = usesToolbar;
  _adaptiveLayoutConfigured = YES;

  UINavigationItem* previousItem = _navigationBar.items.firstObject;
  UINavigationItem* readerItem = _navigationBar.topItem;
  previousItem.backButtonDisplayMode = narrow ? UINavigationItemBackButtonDisplayModeMinimal : UINavigationItemBackButtonDisplayModeDefault;
  if (usesToolbar) {
    readerItem.rightBarButtonItems = _addToLibraryButtonItem ? @[_addToLibraryButtonItem] : nil;
    UIBarButtonItem* flexible1 = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                 target:nil action:nil] autorelease];
    UIBarButtonItem* flexible2 = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                 target:nil action:nil] autorelease];
    UIBarButtonItem* flexible3 = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                 target:nil action:nil] autorelease];
    UIBarButtonItem* flexible4 = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                 target:nil action:nil] autorelease];
    _toolsToolbar.items = @[flexible1, _bookmarksButtonItem, flexible2, _filtersButtonItem,
                            flexible3, _textButtonItem, flexible4];
  } else {
    _toolsToolbar.items = nil;
    readerItem.rightBarButtonItems = _addToLibraryButtonItem
      ? @[_addToLibraryButtonItem, _bookmarksButtonItem, _filtersButtonItem, _textButtonItem]
      : @[_bookmarksButtonItem, _filtersButtonItem, _textButtonItem];
  }
  _toolsToolbar.hidden = !usesToolbar || _navigationBar.hidden;
}

- (void) _setReaderChromeHidden:(BOOL)hidden {
  _navigationBar.hidden = hidden;
  _navigationControl.hidden = hidden;
  _toolsToolbar.hidden = hidden || !_usingCompactLayout;
}

- (CGRect) _readerViewportBounds {
  if (!_adaptiveViewportView) {
    return CRReaderContentBounds(self.view.bounds, self.view.safeAreaInsets);
  }
  _adaptiveViewportView.frame = self.view.bounds;
  [_adaptiveViewportView refreshViewport];
  return [_adaptiveViewportView convertRect:_adaptiveViewportView.viewportBounds toView:self.view];
}

- (void) adaptiveViewportView:(CRAdaptiveViewportView*)view
      didChangeViewportBounds:(CGRect)viewportBounds {
  [self.view setNeedsLayout];
}


- (void) _tapAction:(UITapGestureRecognizer*)recognizer {
  if (recognizer.state == UIGestureRecognizerStateEnded) {
    CGRect bounds = recognizer.view.bounds;
    CGPoint location = [recognizer locationInView:recognizer.view];
    CGFloat viewportX = location.x - CGRectGetMinX(bounds);
    // Left margin
    if (viewportX <= bounds.size.width * kLeftZoneRatio) {
      [_documentView goToPreviousPage:NO];
    }
    // Right margin
    else if (viewportX >= bounds.size.width * kRightZoneRatio) {
      [_documentView goToNextPage:NO];
    }
    // Center
    else {
      [self _setReaderChromeHidden:!_navigationBar.hidden];
    }
  }
}

- (void) viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGRect safeBounds = [self _readerViewportBounds];
  _contentView.frame = safeBounds;
  _documentView.frame = _contentView.bounds;

  BOOL narrow = self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact ||
                CGRectGetWidth(safeBounds) < kReaderCompactWidth;
  // On short displays, keep all tools in the navigation bar so the reader only
  // needs two 44-point chrome rows and the controls cannot overlap each other.
  BOOL usesToolbar = narrow && CGRectGetHeight(safeBounds) >= 3.0 * kReaderChromeHeight;
  if (!_adaptiveLayoutConfigured || narrow != _usingNarrowLayout || usesToolbar != _usingCompactLayout) {
    [self _configureReaderChromeForNarrowWidth:narrow usesSeparateToolsToolbar:usesToolbar];
  }
  _navigationBar.frame = CGRectMake(CGRectGetMinX(safeBounds), CGRectGetMinY(safeBounds),
                                    CGRectGetWidth(safeBounds), kReaderChromeHeight);
  _navigationControl.frame = CGRectMake(0.0, MAX(0.0, CGRectGetHeight(safeBounds) - kReaderChromeHeight),
                                        CGRectGetWidth(safeBounds), kReaderChromeHeight);
  if (usesToolbar) {
    _toolsToolbar.frame = CGRectMake(CGRectGetMinX(safeBounds),
                                     CGRectGetMaxY(safeBounds) - 2.0 * kReaderChromeHeight,
                                     CGRectGetWidth(safeBounds), kReaderChromeHeight);
    _navigationControl.margins = UIEdgeInsetsMake(0.0, 24.0, 0.0, 24.0);
  } else {
    _toolsToolbar.frame = CGRectZero;
    _navigationControl.margins = UIEdgeInsetsMake(0.0, 80.0, 20.0, 80.0);
  }
  CGRect pageLabelBounds = _pageLabel.bounds;
  pageLabelBounds.size.width = MIN(160.0, MAX(0.0, CGRectGetWidth(safeBounds) - 16.0));
  _pageLabel.bounds = pageLabelBounds;
}

- (void) viewSafeAreaInsetsDidChange {
  [super viewSafeAreaInsetsDidChange];
  [self.view setNeedsLayout];
}

- (void) traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
  [super traitCollectionDidChange:previousTraitCollection];
  [self.view setNeedsLayout];
  if (self.traitCollection.displayScale > previousTraitCollection.displayScale + 0.01) {
    [self _scheduleSelectedPageScaleRefresh];
  }
}

- (void) viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  _readerAcceptsScaleRefreshes = YES;

  // A compact-width sheet can cover the reader and trigger appearance callbacks.
  // Keep the existing views and selected page instead of rebuilding the document.
  if (_readerReady && _documentView.pageViews.count > 0) {
    _navigationControl.currentPage = _documentView.selectedPageIndex;
    [self _scheduleSelectedPageScaleRefresh];
    return;
  }
  
  NSMutableArray* array = [[NSMutableArray alloc] init];
  if (_type == kComicType_PDF) {
    NSUInteger count = [(NSNumber*)_contents integerValue];
    for (NSUInteger i = 0; i < count; ++i) {
      ComicPageView* view = [[ComicPageView alloc] initWithTapTarget:self action:@selector(_tapAction:)];
      view.tag = i + 1;
      [array addObject:view];
      [view release];
    }
  } else {
    [_contents setSkipInvisibleFiles:YES];
    NSUInteger index = 0;
    for (NSString* file in [[_contents retrieveFileList] sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
      if (IsImageFileExtensionSupported([file pathExtension])) {
        ComicPageView* view = [[ComicPageView alloc] initWithTapTarget:self action:@selector(_tapAction:)];
        view.tag = ++index;
        view.file = file;
        [array addObject:view];
        [view release];
      }
    }
  }
  NSInteger initialPage = 0;
  if (_comic) {
    [[CRLibrarySyncCoordinator sharedCoordinator] beginReadingComic:_comic];
    initialPage = [[CRLibrarySyncCoordinator sharedCoordinator] initialPageForComic:_comic pageCount:array.count];
  }
  [_documentView setPageViews:array initialPageIndex:initialPage];
  _readerReady = YES;
  _navigationControl.numberOfPages = array.count;
  _navigationControl.numberOfMarkers = MIN(array.count, 50);
  _navigationControl.currentPage = _documentView.selectedPageIndex;
  if (array.count == 0) {
    [self _setReaderChromeHidden:NO];
  }
  [array release];
}

- (void) viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  
  [[AppDelegate sharedInstance] hideSpinner:YES];
  if (_readerReady && _documentView.pageViews.count > 0) {
    [[CRReviewPrompt sharedPrompt] beginReading];
    if (self.view.window.windowScene.activationState != UISceneActivationStateForegroundActive) {
      [[CRReviewPrompt sharedPrompt] pauseReading];
    }
  }
  [self becomeFirstResponder];
}

- (void) viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  _readerAcceptsScaleRefreshes = NO;

  [self saveState];
}

- (void) viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];

  if (_preservingReaderForToolsSheet && self.presentedViewController && !self.isBeingDismissed) {
    return;
  }
  
  _preservingReaderForToolsSheet = NO;
  [[CRReviewPrompt sharedPrompt] endReading];
  _readerReady = NO;
  if (_comic) {
    [[CRLibrarySyncCoordinator sharedCoordinator] endReadingComic:_comic];
  }
  _documentView.pageViews = nil;
}

- (void)_addExternalComicToLibrary:(id)sender {
  if (!_externalFileURL || !_externalComicDelegate || !_readerReady || !_addToLibraryButtonItem.enabled) return;
  _addToLibraryButtonItem.enabled = NO;
  _addToLibraryButtonItem.title = @"Adding…";
  [_externalComicDelegate comicViewController:self
                didRequestAddExternalComicAtURL:_externalFileURL
                               currentPageIndex:_documentView.selectedPageIndex
                                      pageCount:_documentView.pageViews.count];
}

- (void)externalComicImportDidFail {
  _addToLibraryButtonItem.enabled = YES;
  _addToLibraryButtonItem.title = @"Add to Library";
}

- (BOOL) _reviewPromptNotificationMatchesCurrentScene:(NSNotification*)notification {
  UIWindowScene* scene = self.view.window.windowScene;
  return scene && notification.object == scene;
}

- (void) _reviewPromptSceneWillDeactivate:(NSNotification*)notification {
  if (![self _reviewPromptNotificationMatchesCurrentScene:notification]) return;
  [[CRReviewPrompt sharedPrompt] pauseReading];
}

- (void) _reviewPromptSceneDidActivate:(NSNotification*)notification {
  if (![self _reviewPromptNotificationMatchesCurrentScene:notification] ||
      !_readerReady || self.isBeingDismissed || !self.view.window) return;
  [[CRReviewPrompt sharedPrompt] resumeReading];
}

- (void) documentViewDidChangePage:(DocumentView*)documentView {
  if (_readerReady) [self saveState];
  _navigationControl.currentPage = _documentView.selectedPageIndex;
  [self _scheduleSelectedPageScaleRefresh];
  
  if (_documentView.pageViews) {
    [[AppDelegate sharedDelegate] logPageView];
  }
}

- (void) _scheduleSelectedPageScaleRefresh {
  if (!_readerAcceptsScaleRefreshes || !_readerReady || _selectedPageScaleRefreshScheduled) return;
  _selectedPageScaleRefreshScheduled = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_selectedPageScaleRefreshScheduled = NO;
    if (!self->_readerAcceptsScaleRefreshes || !self->_readerReady || self.isBeingDismissed) return;
    [self _refreshSelectedPageScaleIfNeeded];
  });
}

- (void) _refreshSelectedPageScaleIfNeeded {
  if (!_readerAcceptsScaleRefreshes || !_readerReady || _documentView.pageViews.count == 0) return;
  ComicPageView* pageView = (ComicPageView*)_documentView.selectedPageView;
  if (!pageView.displayView) return;
  CGFloat displayScale = [self _displayScaleForPageView:pageView documentView:_documentView];
  if (displayScale > pageView.renderedDisplayScale + 0.01) {
    [self documentView:_documentView willShowPageView:pageView];
  }
}

- (UIView*) navigationControlOverlayViewForCurrentPage:(NavigationControl*)control {
  _pageLabel.text = [NSString stringWithFormat:NSLocalizedString(@"LABEL_FORMAT", nil), _navigationControl.currentPage + 1,
                                               _navigationControl.numberOfPages];
  return _pageLabel;
}

- (IBAction) selectPage:(id)sender {
  _documentView.selectedPageIndex = _navigationControl.currentPage;
}

- (void) _showImageFilters:(id)sender {
  if (!_readerReady || self.presentedViewController) return;
  CRReaderImageFiltersViewController* controller = [[CRReaderImageFiltersViewController alloc] init];
  controller.delegate = self;
  CRAdaptiveToolNavigationController* navigation = [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:controller];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  navigation.modalInPresentation = YES;
  _preservingReaderForToolsSheet = YES;
  [self presentViewController:navigation animated:YES completion:nil];
  [controller release];
  [navigation release];
}

- (void) _showComicText:(id)sender {
  if (!_readerReady || !_documentView.pageViews.count || self.presentedViewController) return;
  CRComicTextViewController* controller = [[CRComicTextViewController alloc] initWithComicPath:_path currentPageIndex:_documentView.selectedPageIndex];
  controller.delegate = self;
  CRAdaptiveToolNavigationController* navigation = [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:controller];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  navigation.modalInPresentation = YES;
  _preservingReaderForToolsSheet = YES;
  [self presentViewController:navigation animated:YES completion:nil];
  [controller release];
  [navigation release];
}

- (void) comicTextViewControllerDidRequestClose:(CRComicTextViewController*)controller {
  [self dismissViewControllerAnimated:YES completion:^{ self->_preservingReaderForToolsSheet = NO; }];
}

- (void) comicTextViewController:(CRComicTextViewController*)controller didSelectPageIndex:(NSInteger)pageIndex {
  if (pageIndex >= 0 && pageIndex < _documentView.pageViews.count) {
    _documentView.selectedPageIndex = pageIndex;
    _navigationControl.currentPage = pageIndex;
    [self saveState];
  }
  [self dismissViewControllerAnimated:YES completion:^{ self->_preservingReaderForToolsSheet = NO; }];
}

- (void) readerImageFiltersDidChange {
  for (ComicPageView* page in _documentView.pageViews) {
    if (page.displayView) [self documentView:_documentView willShowPageView:page];
  }
}

- (void) readerImageFiltersDidRequestClose {
  [self dismissViewControllerAnimated:YES completion:^{ self->_preservingReaderForToolsSheet = NO; }];
}

- (void) _showPageBookmarks:(id)sender {
  if (!_readerReady || _documentView.pageViews.count == 0 || self.presentedViewController) {
    return;
  }

  CRPageBookmarksViewController* controller =
    [[CRPageBookmarksViewController alloc] initWithComicPath:_path
                                           currentPageIndex:_documentView.selectedPageIndex
                                                    pageCount:_documentView.pageViews.count];
  controller.delegate = self;
  CRAdaptiveToolNavigationController* navigation = [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:controller];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  navigation.modalInPresentation = YES;
  _preservingReaderForToolsSheet = YES;
  [self presentViewController:navigation animated:YES completion:nil];
  [controller release];
  [navigation release];
}

- (void) pageBookmarksViewControllerDidRequestClose:(CRPageBookmarksViewController*)viewController {
  [self dismissViewControllerAnimated:YES completion:^{
    self->_preservingReaderForToolsSheet = NO;
  }];
}

- (void) pageBookmarksViewController:(CRPageBookmarksViewController*)viewController
                   didSelectPageIndex:(NSInteger)pageIndex {
  if (pageIndex >= 0 && pageIndex < _documentView.pageViews.count) {
    _documentView.selectedPageIndex = pageIndex;
    _navigationControl.currentPage = pageIndex;
    [self saveState];
  }
  [self dismissViewControllerAnimated:YES completion:^{
    self->_preservingReaderForToolsSheet = NO;
  }];
}

@end
