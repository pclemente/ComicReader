#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AppDelegate.h"
#import "CRAdaptiveViewport.h"
#import "CRLibrarySyncCoordinator.h"
#import "Library.h"
#import "LibraryViewController.h"
#import "Defaults.h"
#import "Extensions_Foundation.h"

@interface ApplicationDelegate (RegressionTesting)
- (void)_dismissAlertWithButtonIndex:(NSInteger)index;
@end

// The Swift class is supplied by the test host. Its generated interface header
// is private to the app target, so declare the public surface exercised here.
@interface CRComicTextViewController : UIViewController
- (instancetype)initWithComicPath:(NSString*)comicPath currentPageIndex:(NSInteger)currentPageIndex;
@end

@interface CRWebBrowserViewController : UIViewController
- (instancetype)initWithLibraryRootURL:(NSURL*)libraryRootURL;
@end

@interface LibraryViewController (AdaptiveViewportTesting)
@property(nonatomic, retain) CRAdaptiveViewportView* adaptiveViewportView;
@end

@interface LibraryViewController (DirectOpenTesting)
- (Comic*)_indexedComicForURL:(NSURL*)url;
- (void)_enqueueComicURLsForOpening:(NSArray<NSURL*>*)urls
                deletesFilesOnClose:(BOOL)deletesFilesOnClose;
- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls;
- (void)presentationControllerDidDismiss:(UIPresentationController*)presentationController;
@end

@interface LibraryViewController (ReviewPromptTesting)
- (void)_showRatingScreen;
@end

@interface CRReviewRequestRecorder : NSObject
@property(nonatomic) NSUInteger requestCount;
@property(nonatomic, weak) UIWindowScene* requestedScene;
- (BOOL)requestReviewIfEligibleInScene:(UIWindowScene*)scene;
@end

@implementation CRReviewRequestRecorder
- (BOOL)requestReviewIfEligibleInScene:(UIWindowScene*)scene {
  self.requestCount++;
  self.requestedScene = scene;
  return YES;
}
@end

@interface CRDirectOpenRecordingLibraryViewController : LibraryViewController
@property(nonatomic, copy) NSArray<NSURL*>* enqueuedURLs;
@property(nonatomic) BOOL enqueuedURLsDeleteOnClose;
@end

@implementation CRDirectOpenRecordingLibraryViewController
- (void)_enqueueComicURLsForOpening:(NSArray<NSURL*>*)urls
                deletesFilesOnClose:(BOOL)deletesFilesOnClose {
  self.enqueuedURLs = urls;
  self.enqueuedURLsDeleteOnClose = deletesFilesOnClose;
}
@end

@interface CRPresentationRecordingViewController : UIViewController
@property(nonatomic, strong) UIViewController* recordedPresentedViewController;
@end

@implementation CRPresentationRecordingViewController
- (void)presentViewController:(UIViewController*)viewControllerToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
  self.recordedPresentedViewController = viewControllerToPresent;
  if (completion) completion();
}
@end

#if TARGET_OS_MACCATALYST
@interface CRQueueDrainTestComicViewController : ComicViewController
@property(nonatomic) BOOL saveStateCalled;
@end

@implementation CRQueueDrainTestComicViewController
- (void)loadView { self.view = [[UIView alloc] init]; }
- (void)viewDidLoad {}
- (void)saveState { self.saveStateCalled = YES; }
@end

@interface CRQueueDrainRecordingLibraryViewController : LibraryViewController
@property(nonatomic, strong) ComicViewController* presentedReader;
@property(nonatomic) BOOL queueDismissalRequested;
@end

@implementation CRQueueDrainRecordingLibraryViewController
- (UIViewController*)presentedViewController { return self.presentedReader; }
- (void)viewDidLoad {}
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
  // This unit verifies the replacement request. Native validation covers the
  // actual dismissal and next-reader presentation without a synthetic library.
  self.queueDismissalRequested = YES;
}
@end
#endif

@interface CRFixedAdaptiveViewportView : CRAdaptiveViewportView
@property(nonatomic) CGRect fixedViewportBounds;
@end

@implementation CRFixedAdaptiveViewportView
- (CGRect)viewportBounds {
  return self.fixedViewportBounds;
}
- (void)refreshViewport {
}
@end

@interface CRAdaptiveToolNavigationController (AdaptiveViewportTesting)
- (void)_adaptiveObserver:(UIView*)observer
    didReadDivisionFrames:(NSArray<NSValue*>*)divisionFrames
          occlusionFrames:(NSArray<NSValue*>*)occlusionFrames;
@end

@interface CRAdaptiveToolSafeAreaTestView : UIView
@property(nonatomic) UIEdgeInsets baselineSafeAreaInsets;
@property(nonatomic, assign) CRAdaptiveToolNavigationController* adaptiveNavigationController;
@end

@implementation CRAdaptiveToolSafeAreaTestView
- (UIEdgeInsets)safeAreaInsets {
  UIEdgeInsets additional = UIEdgeInsetsZero;
  if (self.adaptiveNavigationController) {
    additional = self.adaptiveNavigationController.additionalSafeAreaInsets;
  }
  return UIEdgeInsetsMake(self.baselineSafeAreaInsets.top + additional.top,
                          self.baselineSafeAreaInsets.left + additional.left,
                          self.baselineSafeAreaInsets.bottom + additional.bottom,
                          self.baselineSafeAreaInsets.right + additional.right);
}
@end

@interface AlertRecorder : NSObject
@property(nonatomic) NSUInteger cancellations;
@property(nonatomic) NSUInteger confirmations;
@property(nonatomic) BOOL showAnotherAlert;
@property(nonatomic) BOOL showAnotherAlertOnCancel;
@end
@implementation AlertRecorder
- (void)cancel:(id)argument {
  self.cancellations++;
  if (self.showAnotherAlertOnCancel) {
    self.showAnotherAlertOnCancel = NO;
    [[AppDelegate sharedDelegate] showAlertWithTitle:@"Cancellation follow-up" message:nil button:@"OK"];
  }
}
- (void)confirm:(id)argument {
  self.confirmations++;
  if (self.showAnotherAlert) {
    [[AppDelegate sharedDelegate] showAlertWithTitle:@"Follow-up" message:nil button:@"OK"];
  }
}
@end

@interface ComicReaderTests : XCTestCase
@property(nonatomic) NSMutableArray<NSString*>* createdPaths;
@end

@implementation ComicReaderTests
- (void)testUndismissedNewsDoesNotSuppressEligibleReviewRequest {
  AppDelegate* app = [AppDelegate sharedDelegate];
  LibraryViewController* library = (LibraryViewController*)app.viewController;
  XCTAssertTrue([library isKindOfClass:LibraryViewController.class]);
  XCTAssertNotNil(library.view.window);
  XCTAssertEqual(app.window.windowScene.activationState, UISceneActivationStateForegroundActive);
  XCTAssertNil(library.presentedViewController);
  XCTAssertFalse(app.isAlertVisible);
  XCTAssertFalse(app.isSpinnerVisible);
  XCTAssertFalse([LibraryUpdater sharedUpdater].isUpdating);

  Class promptClass = NSClassFromString(@"CRReviewPrompt");
  Method getter = class_getClassMethod(promptClass, NSSelectorFromString(@"sharedPrompt"));
  XCTAssertNotEqual(getter, NULL);
  if (!getter) return;
  CRReviewRequestRecorder* recorder = [CRReviewRequestRecorder new];
  IMP replacement = imp_implementationWithBlock(^id(id receiver) { return recorder; });
  IMP original = method_setImplementation(getter, replacement);
  id previousNews = [library valueForKey:@"releaseNewsDismissed"];
  id previousStartup = [library valueForKey:@"startupPresentationsPending"];
  @try {
    [library setValue:@NO forKey:@"releaseNewsDismissed"];
    [library setValue:@NO forKey:@"startupPresentationsPending"];
    [library _showRatingScreen];
    XCTAssertEqual(recorder.requestCount, 1u,
                   @"A persistent nonmodal news banner must not prevent an eligible StoreKit request");
    XCTAssertEqual(recorder.requestedScene, app.window.windowScene);

    [library setValue:@YES forKey:@"startupPresentationsPending"];
    [library _showRatingScreen];
    XCTAssertEqual(recorder.requestCount, 1u, @"Active startup work must still defer the request");
  } @finally {
    method_setImplementation(getter, original);
    imp_removeBlock(replacement);
    [library setValue:previousNews forKey:@"releaseNewsDismissed"];
    [library setValue:previousStartup forKey:@"startupPresentationsPending"];
  }
}

- (UIView*)viewWithAccessibilityIdentifier:(NSString*)identifier underView:(UIView*)view {
  if ([view.accessibilityIdentifier isEqualToString:identifier]) {
    return view;
  }
  for (UIView* subview in view.subviews) {
    UIView* match = [self viewWithAccessibilityIdentifier:identifier underView:subview];
    if (match) return match;
  }
  return nil;
}
- (void)assertSubviewsFitHorizontallyInView:(UIView*)view {
  for (UIView* subview in view.subviews) {
    XCTAssertGreaterThanOrEqual(CGRectGetMinX(subview.frame), -0.5);
    XCTAssertGreaterThanOrEqual(CGRectGetWidth(subview.frame), 0.0);
    XCTAssertLessThanOrEqual(CGRectGetMaxX(subview.frame), CGRectGetWidth(view.bounds) + 0.5);
    [self assertSubviewsFitHorizontallyInView:subview];
  }
}
- (CGRect)assertComicTextControllerBodyFitsSafeArea:(CRComicTextViewController*)controller {
  [controller.view setNeedsLayout];
  [controller.view layoutIfNeeded];
  UIView* mode = [self viewWithAccessibilityIdentifier:@"reader.text.mode" underView:controller.view];
  UIView* body = mode.superview;
  XCTAssertNotNil(mode);
  XCTAssertTrue([body isKindOfClass:[UIStackView class]]);
  CGRect safeFrame = controller.view.safeAreaLayoutGuide.layoutFrame;
  if (body) {
    XCTAssertEqualWithAccuracy(CGRectGetMinX(body.frame), CGRectGetMinX(safeFrame) + 16.0, 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetMaxX(body.frame), CGRectGetMaxX(safeFrame) - 16.0, 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetMinY(body.frame), CGRectGetMinY(safeFrame) + 12.0, 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetMaxY(body.frame), CGRectGetMaxY(safeFrame) - 12.0, 0.5);
    XCTAssertTrue(CGRectContainsRect(CGRectInset(safeFrame, -0.5, -0.5), body.frame));
  }
  return safeFrame;
}
- (void)assertLibraryController:(LibraryViewController*)controller fitsViewport:(CGRect)viewport {
  UIView* rootView = controller.view;
  UIToolbar* toolbar = (UIToolbar*)[self viewWithAccessibilityIdentifier:@"library.compactToolbar"
                                                               underView:rootView];
  XCTAssertEqualWithAccuracy(CGRectGetMinX(controller.navigationBar.frame), CGRectGetMinX(viewport), 0.5);
  XCTAssertEqualWithAccuracy(CGRectGetMinY(controller.navigationBar.frame), CGRectGetMinY(viewport), 0.5);
  XCTAssertEqualWithAccuracy(CGRectGetWidth(controller.navigationBar.frame), CGRectGetWidth(viewport), 0.5);
  XCTAssertEqualWithAccuracy(CGRectGetMinX(controller.gridView.frame), CGRectGetMinX(viewport), 0.5);
  XCTAssertEqualWithAccuracy(CGRectGetWidth(controller.gridView.frame), CGRectGetWidth(viewport), 0.5);
  XCTAssertGreaterThanOrEqual(CGRectGetMinY(controller.gridView.frame),
                              CGRectGetMaxY(controller.navigationBar.frame) - 0.5);
  if (toolbar && !toolbar.hidden) {
    XCTAssertEqualWithAccuracy(CGRectGetMinX(toolbar.frame), CGRectGetMinX(viewport), 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetWidth(toolbar.frame), CGRectGetWidth(viewport), 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetMaxY(toolbar.frame), CGRectGetMaxY(viewport), 0.5);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(controller.gridView.frame), CGRectGetMinY(toolbar.frame) + 0.5);
  } else {
    XCTAssertLessThanOrEqual(CGRectGetMaxY(controller.gridView.frame), CGRectGetMaxY(viewport) + 0.5);
  }

  UIView* emptyState = [controller valueForKey:@"emptyStateView"];
  XCTAssertTrue(CGRectEqualToRect(emptyState.frame, controller.gridView.frame));
  UIScrollView* emptyScroll = (UIScrollView*)[emptyState viewWithTag:9901];
  UIView* emptyContent = [emptyState viewWithTag:9902];
  XCTAssertEqualWithAccuracy(CGRectGetWidth(emptyContent.frame), CGRectGetWidth(emptyScroll.bounds), 0.5);
  [self assertSubviewsFitHorizontallyInView:emptyContent];

  UIView* banner = [self viewWithAccessibilityIdentifier:@"library.whatsNew" underView:rootView];
  if (banner && !banner.hidden) {
    XCTAssertGreaterThanOrEqual(CGRectGetMinX(banner.frame), CGRectGetMinX(viewport) - 0.5);
    XCTAssertLessThanOrEqual(CGRectGetMaxX(banner.frame), CGRectGetMaxX(viewport) + 0.5);
    XCTAssertGreaterThanOrEqual(CGRectGetMinY(banner.frame), CGRectGetMaxY(controller.navigationBar.frame) - 0.5);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(banner.frame), CGRectGetMinY(controller.gridView.frame) + 0.5);
  }
}
- (UIContextMenuInteraction*)contextMenuInteractionForView:(UIView*)view {
  for (id<UIInteraction> interaction in view.interactions) {
    if ([interaction isKindOfClass:[UIContextMenuInteraction class]]) {
      return (UIContextMenuInteraction*)interaction;
    }
  }
  return nil;
}
- (void)assertPreview:(UITargetedPreview*)preview
          targetsView:(UIView*)view
          inContainer:(UIView*)container {
  XCTAssertNotNil(preview);
  XCTAssertEqual(preview.view, view);
  XCTAssertEqual(preview.target.container, container);
  XCTAssertEqualWithAccuracy(preview.target.center.x, view.center.x, 0.001);
  XCTAssertEqualWithAccuracy(preview.target.center.y, view.center.y, 0.001);
  XCTAssertEqualWithAccuracy(preview.size.width, CGRectGetWidth(view.bounds), 0.001);
  XCTAssertEqualWithAccuracy(preview.size.height, CGRectGetHeight(view.bounds), 0.001);
}
- (void)waitForLibrary {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:15];
  do {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  } while ([LibraryUpdater sharedUpdater].isUpdating && deadline.timeIntervalSinceNow > 0);
  XCTAssertFalse([LibraryUpdater sharedUpdater].isUpdating);
}
- (void)setUp {
  [super setUp];
  self.createdPaths = [NSMutableArray array];
  [[AppDelegate sharedDelegate] dismissAlert:NO];
  [self waitForLibrary];
}
- (void)tearDown {
  [[AppDelegate sharedDelegate] dismissAlert:NO];
  [self waitForLibrary];
  for (NSString* path in self.createdPaths) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
  }
  [[AppDelegate sharedDelegate] updateLibrary];
  [self waitForLibrary];
  [super tearDown];
}
- (NSURL*)createPDFNamed:(NSString*)name inDirectory:(NSString*)directory {
  [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
  UIGraphicsPDFRenderer* renderer = [[UIGraphicsPDFRenderer alloc] initWithBounds:CGRectMake(0, 0, 300, 450)];
  NSData* data = [renderer PDFDataWithActions:^(UIGraphicsPDFRendererContext* context) {
    [context beginPage];
    [name drawAtPoint:CGPointMake(20, 20) withAttributes:nil];
  }];
  NSString* path = [directory stringByAppendingPathComponent:name];
  XCTAssertTrue([data writeToFile:path atomically:YES]);
  [self.createdPaths addObject:path];
  return [NSURL fileURLWithPath:path];
}
- (BOOL)importAndWait:(NSURL*)url {
  XCTestExpectation* finished = [self expectationWithDescription:@"File copy completed"];
  __block BOOL result = NO;
  [[AppDelegate sharedDelegate] importComicAtURL:url completion:^(BOOL imported) {
    result = imported;
    [finished fulfill];
  }];
  [self waitForExpectations:@[finished] timeout:15];
  return result;
}
- (NSArray*)importResultAndWait:(NSURL*)url {
  XCTestExpectation* finished = [self expectationWithDescription:@"File import completed"];
  __block NSArray* result = nil;
  [[AppDelegate sharedDelegate] importComicAtURL:url
                               resultCompletion:^(BOOL imported, NSURL* libraryURL, BOOL createdCopy) {
    result = @[@(imported), libraryURL ?: NSNull.null, @(createdCopy)];
    [finished fulfill];
  }];
  [self waitForExpectations:@[finished] timeout:15];
  return result;
}
- (void)testSceneWindowAndFreeTransferMigration {
  AppDelegate* app = [AppDelegate sharedDelegate];
  XCTAssertNotNil(app.window.windowScene);
  XCTAssertEqual(app.window.rootViewController, app.viewController);
  XCTAssertEqual([[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_ServerMode], kServerMode_Full);
}
- (void)testCompactLibraryChromeHonorsAsymmetricSafeArea {
  LibraryViewController* controller = (LibraryViewController*)[AppDelegate sharedDelegate].viewController;
  XCTAssertTrue([controller isKindOfClass:[LibraryViewController class]]);
  UIView* view = controller.view;
  CGRect originalFrame = view.frame;
  UIEdgeInsets originalAdditionalInsets = controller.additionalSafeAreaInsets;

  @try {
    view.frame = CGRectMake(originalFrame.origin.x, originalFrame.origin.y, 430, 700);
    controller.additionalSafeAreaInsets = UIEdgeInsetsMake(7, 31, 19, 67);
    [view setNeedsLayout];
    [view layoutIfNeeded];

    CGRect safeBounds = UIEdgeInsetsInsetRect(view.bounds, view.safeAreaInsets);
    UIToolbar* toolbar = (UIToolbar*)[self viewWithAccessibilityIdentifier:@"library.compactToolbar"
                                                                 underView:view];
    XCTAssertNotNil(toolbar);
    XCTAssertFalse(toolbar.hidden);
    XCTAssertEqualWithAccuracy(CGRectGetMinX(controller.navigationBar.frame), CGRectGetMinX(safeBounds), 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetWidth(controller.navigationBar.frame), CGRectGetWidth(safeBounds), 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetMinX(toolbar.frame), CGRectGetMinX(safeBounds), 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetWidth(toolbar.frame), CGRectGetWidth(safeBounds), 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetMaxY(toolbar.frame), CGRectGetMaxY(safeBounds), 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetMinX(controller.gridView.frame), CGRectGetMinX(safeBounds), 0.5);
    XCTAssertEqualWithAccuracy(CGRectGetWidth(controller.gridView.frame), CGRectGetWidth(safeBounds), 0.5);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(controller.gridView.frame), CGRectGetMinY(toolbar.frame) + 0.5);
    XCTAssertGreaterThanOrEqual(CGRectGetMinY(controller.gridView.frame), CGRectGetMaxY(controller.navigationBar.frame) - 0.5);
    UIView* banner = [self viewWithAccessibilityIdentifier:@"library.whatsNew" underView:view];
    if (banner && !banner.hidden) {
      XCTAssertGreaterThanOrEqual(CGRectGetMinX(banner.frame), CGRectGetMinX(safeBounds) - 0.5);
      XCTAssertLessThanOrEqual(CGRectGetMaxX(banner.frame), CGRectGetMaxX(safeBounds) + 0.5);
      XCTAssertLessThanOrEqual(CGRectGetMaxY(banner.frame), CGRectGetMinY(controller.gridView.frame) + 0.5);
    }
  } @finally {
    controller.additionalSafeAreaInsets = originalAdditionalInsets;
    view.frame = originalFrame;
    [view setNeedsLayout];
    [view layoutIfNeeded];
  }
}
- (void)testLibraryNavigationKeepsEveryPrimaryActionVisibleAtDuoAndNarrowWidths {
  LibraryViewController* controller = (LibraryViewController*)[AppDelegate sharedDelegate].viewController;
  XCTAssertTrue([controller isKindOfClass:[LibraryViewController class]]);
  UIView* view = controller.view;
  CGRect originalFrame = view.frame;
  UIEdgeInsets originalAdditionalInsets = controller.additionalSafeAreaInsets;
  CRAdaptiveViewportView* originalTracker = controller.adaptiveViewportView;
  CRFixedAdaptiveViewportView* fixedTracker = [[CRFixedAdaptiveViewportView alloc] initWithFrame:view.bounds];
  NSArray<NSString*>* expectedActions = @[@"library.readingLists", @"library.icloud",
                                          @"library.plus", @"library.settings"];

  @try {
    [originalTracker removeFromSuperview];
    fixedTracker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    fixedTracker.adaptiveViewportDelegate = (id<CRAdaptiveViewportViewDelegate>)controller;
    [view insertSubview:fixedTracker atIndex:0];
    controller.adaptiveViewportView = fixedTracker;
    controller.additionalSafeAreaInsets = UIEdgeInsetsZero;

    NSArray<NSValue*>* viewportSizes = @[[NSValue valueWithCGSize:CGSizeMake(669.0, 951.0)],
                                         [NSValue valueWithCGSize:CGSizeMake(430.0, 700.0)]];
    for (NSValue* viewportSizeValue in viewportSizes) {
      CGSize viewportSize = viewportSizeValue.CGSizeValue;
      view.frame = (CGRect){originalFrame.origin, viewportSize};
      fixedTracker.fixedViewportBounds = (CGRect){CGPointZero, viewportSize};
      [view setNeedsLayout];
      [view layoutIfNeeded];

      UIToolbar* toolbar = (UIToolbar*)[self viewWithAccessibilityIdentifier:@"library.compactToolbar"
                                                                   underView:view];
      XCTAssertNotNil(toolbar);
      XCTAssertFalse(toolbar.hidden, @"The %.0f-point viewport must not overflow primary actions",
                     viewportSize.width);
      NSMutableArray<NSString*>* visibleActions = [NSMutableArray array];
      for (UIBarButtonItem* item in toolbar.items) {
        if (item.accessibilityIdentifier.length) [visibleActions addObject:item.accessibilityIdentifier];
      }
      XCTAssertEqualObjects(visibleActions, expectedActions);
      XCTAssertEqualObjects(controller.navigationBar.topItem.rightBarButtonItems.firstObject.accessibilityIdentifier,
                            @"library.sort");
      XCTAssertEqual(controller.navigationBar.topItem.rightBarButtonItems.count, (NSUInteger)2);
      XCTAssertEqualObjects(controller.navigationBar.topItem.rightBarButtonItems.lastObject.accessibilityIdentifier,
                            @"library.browser");
      [self assertLibraryController:controller
                       fitsViewport:(CGRect){CGPointZero, viewportSize}];
    }
  } @finally {
    fixedTracker.adaptiveViewportDelegate = nil;
    [fixedTracker removeFromSuperview];
    controller.adaptiveViewportView = originalTracker;
    originalTracker.adaptiveViewportDelegate = (id<CRAdaptiveViewportViewDelegate>)controller;
    controller.additionalSafeAreaInsets = originalAdditionalInsets;
    view.frame = originalFrame;
    originalTracker.frame = view.bounds;
    [view insertSubview:originalTracker atIndex:0];
    [view setNeedsLayout];
    [view layoutIfNeeded];
  }
}
- (void)testBrowserHomeAddressRemainsInteractiveInsideHeaderAcrossDuoWidths {
  NSURL* libraryRootURL = [NSURL fileURLWithPath:[LibraryConnection libraryRootPath]
                                    isDirectory:YES];
  CRWebBrowserViewController* browser =
    [[CRWebBrowserViewController alloc] initWithLibraryRootURL:libraryRootURL];
  UINavigationController* navigation =
    [[UINavigationController alloc] initWithRootViewController:browser];
  UITraitCollection* accessibilityTraits =
    [UITraitCollection traitCollectionWithPreferredContentSizeCategory:
      UIContentSizeCategoryAccessibilityExtraExtraLarge];
  [navigation setOverrideTraitCollection:accessibilityTraits forChildViewController:browser];

  NSArray<NSNumber*>* widths = @[@320.0, @390.0, @318.333, @653.0, @669.0];
  for (NSNumber* widthValue in widths) {
    CGFloat width = widthValue.doubleValue;
    navigation.view.frame = CGRectMake(0, 0, width, 1000);
    [navigation.view setNeedsLayout];
    [navigation.view layoutIfNeeded];
    [browser.view setNeedsLayout];
    [browser.view layoutIfNeeded];

    UITableView* table = (UITableView*)[self viewWithAccessibilityIdentifier:@"library.browser.home"
                                                                   underView:browser.view];
    UITextField* address = (UITextField*)[self viewWithAccessibilityIdentifier:@"library.browser.homeAddress"
                                                                    underView:browser.view];
    XCTAssertTrue([table isKindOfClass:UITableView.class], @"Missing browser home table at %.3f points", width);
    XCTAssertTrue([address isKindOfClass:UITextField.class], @"Missing home address field at %.3f points", width);
    UIView* header = table.tableHeaderView;
    XCTAssertNotNil(header, @"Missing browser home header at %.3f points", width);
    if (!header || !address) continue;

    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGRect addressFrame = [address convertRect:address.bounds toView:header];
    XCTAssertGreaterThan(CGRectGetWidth(addressFrame), 0.0, @"Address width at %.3f points", width);
    XCTAssertGreaterThan(CGRectGetHeight(addressFrame), 0.0, @"Address height at %.3f points", width);
    XCTAssertTrue(address.userInteractionEnabled, @"Address disabled at %.3f points", width);
    XCTAssertTrue(CGRectContainsRect(CGRectInset(header.bounds, -0.5, -0.5), addressFrame),
                  @"Address %@ escapes header %@ at %.3f points",
                  NSStringFromCGRect(addressFrame), NSStringFromCGRect(header.bounds), width);
  }
}
- (void)testAdaptiveToolNavigationKeepsSafeAreaInOnePaneWithoutAccumulatingInsets {
  CGRect bounds = CGRectMake(0, 0, 820, 720);
  UIEdgeInsets baselineInsets = UIEdgeInsetsMake(17, 23, 29, 41);
  UIViewController* root = [[UIViewController alloc] init];
  CRAdaptiveToolNavigationController* navigation =
    [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:root];
  UIView* originalView = navigation.view;
  UIView* observer = [navigation valueForKey:@"adaptiveReservedRegionObserverView"];
  XCTAssertNotNil(originalView);
  XCTAssertNotNil(observer);

  CRAdaptiveToolSafeAreaTestView* testView =
    [[CRAdaptiveToolSafeAreaTestView alloc] initWithFrame:bounds];
  CRAdaptiveToolSafeAreaTestView* presentationContainer =
    [[CRAdaptiveToolSafeAreaTestView alloc] initWithFrame:bounds];
  presentationContainer.baselineSafeAreaInsets = baselineInsets;
  testView.baselineSafeAreaInsets = baselineInsets;
  testView.adaptiveNavigationController = navigation;
  [observer removeFromSuperview];
  navigation.view = testView;
  [presentationContainer addSubview:testView];
  observer.frame = testView.bounds;
  [testView addSubview:observer];

  CGRect horizontalDivision = CGRectMake(0, 340, CGRectGetWidth(bounds), 18);
  NSArray<NSValue*>* horizontalFrames = @[[NSValue valueWithCGRect:horizontalDivision]];
  CGRect topViewport = CRAdaptiveViewportBounds(bounds, baselineInsets, horizontalFrames, @[],
                                                UIUserInterfaceLayoutDirectionLeftToRight);
  [navigation _adaptiveObserver:observer
         didReadDivisionFrames:horizontalFrames
               occlusionFrames:@[]];
  UIEdgeInsets firstInsets = navigation.additionalSafeAreaInsets;
  XCTAssertEqualWithAccuracy(firstInsets.top, 0.0, 0.001);
  XCTAssertEqualWithAccuracy(firstInsets.left, 0.0, 0.001);
  XCTAssertEqualWithAccuracy(firstInsets.bottom, 351.0, 0.001);
  XCTAssertEqualWithAccuracy(firstInsets.right, 0.0, 0.001);
  XCTAssertTrue(CGRectEqualToRect(CRAdaptiveSafeBounds(bounds, testView.safeAreaInsets), topViewport));

  [navigation _adaptiveObserver:observer
         didReadDivisionFrames:horizontalFrames
               occlusionFrames:@[]];
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(navigation.additionalSafeAreaInsets, firstInsets));
  XCTAssertTrue(CGRectEqualToRect(CRAdaptiveSafeBounds(bounds, testView.safeAreaInsets), topViewport));

  [navigation _adaptiveObserver:observer didReadDivisionFrames:@[] occlusionFrames:@[]];
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(navigation.additionalSafeAreaInsets, UIEdgeInsetsZero));
  XCTAssertTrue(CGRectEqualToRect(CRAdaptiveSafeBounds(bounds, testView.safeAreaInsets),
                                  CRAdaptiveSafeBounds(bounds, baselineInsets)));

  CGRect verticalDivision = CGRectMake(400, 0, 20, CGRectGetHeight(bounds));
  NSArray<NSValue*>* verticalFrames = @[[NSValue valueWithCGRect:verticalDivision]];
  CGRect leadingViewport = CRAdaptiveViewportBounds(bounds, baselineInsets, verticalFrames, @[],
                                                    UIUserInterfaceLayoutDirectionLeftToRight);
  [navigation _adaptiveObserver:observer
         didReadDivisionFrames:verticalFrames
               occlusionFrames:@[]];
  XCTAssertEqualWithAccuracy(navigation.additionalSafeAreaInsets.right, 379.0, 0.001);
  XCTAssertTrue(CGRectEqualToRect(CRAdaptiveSafeBounds(bounds, testView.safeAreaInsets),
                                  leadingViewport));
}
- (void)testAdaptiveToolNavigationIgnoresFractionalChildSafeAreaDriftAcrossUpdates {
  CGRect bounds = CGRectMake(0, 0, 653, 943);
  UIEdgeInsets stableContainerInsets = UIEdgeInsetsMake(17, 0, 34, 0);
  UIViewController* root = [[UIViewController alloc] init];
  CRAdaptiveToolNavigationController* navigation =
    [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:root];
  UIView* originalView = navigation.view;
  UIView* originalObserver = [navigation valueForKey:@"adaptiveReservedRegionObserverView"];
  XCTAssertNotNil(originalView);
  XCTAssertNotNil(originalObserver);

  CRAdaptiveToolSafeAreaTestView* presentationContainer =
    [[CRAdaptiveToolSafeAreaTestView alloc] initWithFrame:bounds];
  presentationContainer.baselineSafeAreaInsets = stableContainerInsets;
  CRAdaptiveToolSafeAreaTestView* navigationView =
    [[CRAdaptiveToolSafeAreaTestView alloc] initWithFrame:bounds];
  navigationView.adaptiveNavigationController = navigation;
  CRAdaptiveToolSafeAreaTestView* observer =
    [[CRAdaptiveToolSafeAreaTestView alloc] initWithFrame:bounds];
  observer.adaptiveNavigationController = navigation;

  [originalObserver removeFromSuperview];
  navigation.view = navigationView;
  [presentationContainer addSubview:navigationView];
  [navigationView addSubview:observer];

  CGRect division = CGRectMake(0, 447.5, CGRectGetWidth(bounds), 16.667);
  NSArray<NSValue*>* divisionFrames = @[[NSValue valueWithCGRect:division]];
  UIEdgeInsets expectedInsets = UIEdgeInsetsZero;
  for (NSUInteger pass = 0; pass < 8; pass++) {
    CGFloat drift = pass % 2 == 0 ? 1.0 / 6.0 : -1.0 / 6.0;
    navigationView.baselineSafeAreaInsets = UIEdgeInsetsMake(17, 0, 34 + drift, 0);
    observer.baselineSafeAreaInsets = UIEdgeInsetsMake(17, 0, 34 - drift, 0);
    XCTAssertNotEqualWithAccuracy(navigationView.safeAreaInsets.bottom,
                                  observer.safeAreaInsets.bottom, 0.001);
    [navigation _adaptiveObserver:observer
           didReadDivisionFrames:divisionFrames
                 occlusionFrames:@[]];
    if (pass == 0) {
      expectedInsets = navigation.additionalSafeAreaInsets;
      XCTAssertEqualWithAccuracy(expectedInsets.bottom, 461.5, 0.001);
      XCTAssertEqualWithAccuracy(navigationView.safeAreaInsets.bottom, 495.667, 0.001);
      XCTAssertEqualWithAccuracy(observer.safeAreaInsets.bottom, 495.333, 0.001);
    } else {
      XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(navigation.additionalSafeAreaInsets,
                                                  expectedInsets));
    }
  }
}
- (void)testComicTextBodyTracksAdaptiveToolSafeAreaInBothFoldOrientations {
  CGRect bounds = CGRectMake(0, 0, 653, 943);
  NSURL* comicURL = [self createPDFNamed:[NSString stringWithFormat:@"Text-Geometry-%@.pdf",
                                                                    NSUUID.UUID.UUIDString]
                             inDirectory:NSTemporaryDirectory()];
  CRComicTextViewController* controller =
    [[CRComicTextViewController alloc] initWithComicPath:comicURL.path currentPageIndex:0];
  CRAdaptiveToolNavigationController* navigation =
    [[CRAdaptiveToolNavigationController alloc] initWithRootViewController:controller];
  UIViewController* host = [[UIViewController alloc] init];
  CRAdaptiveToolSafeAreaTestView* presentationContainer =
    [[CRAdaptiveToolSafeAreaTestView alloc] initWithFrame:bounds];
  presentationContainer.baselineSafeAreaInsets = UIEdgeInsetsZero;
  host.view = presentationContainer;
  UIWindow* window = [[UIWindow alloc] initWithFrame:bounds];
  window.rootViewController = host;
  [window addSubview:host.view];
  [host addChildViewController:navigation];
  navigation.view.frame = presentationContainer.bounds;
  [presentationContainer addSubview:navigation.view];
  [navigation didMoveToParentViewController:host];

  UIView* systemObserver = [navigation valueForKey:@"adaptiveReservedRegionObserverView"];
  XCTAssertNotNil(systemObserver);
  [systemObserver removeFromSuperview];
  UIView* observer = [[UIView alloc] initWithFrame:navigation.view.bounds];
  observer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  observer.userInteractionEnabled = NO;
  [navigation.view insertSubview:observer atIndex:0];
  [host.view setNeedsLayout];
  [host.view layoutIfNeeded];
  [navigation.view setNeedsLayout];
  [navigation.view layoutIfNeeded];
  CGRect fullSafeFrame = [self assertComicTextControllerBodyFitsSafeArea:controller];

  CGRect horizontalDivision = CGRectMake(0, 447.5, CGRectGetWidth(bounds), 16.667);
  [navigation _adaptiveObserver:observer
         didReadDivisionFrames:@[[NSValue valueWithCGRect:horizontalDivision]]
               occlusionFrames:@[]];
  [navigation.view setNeedsLayout];
  [navigation.view layoutIfNeeded];
  CGRect horizontalSafeFrame = [self assertComicTextControllerBodyFitsSafeArea:controller];
  XCTAssertGreaterThan(navigation.additionalSafeAreaInsets.bottom, 0.0);
  XCTAssertEqualWithAccuracy(navigation.additionalSafeAreaInsets.right, 0.0, 0.001);
  XCTAssertLessThan(CGRectGetMaxY(horizontalSafeFrame), CGRectGetMaxY(fullSafeFrame) - 100.0);

  CGRect verticalDivision = CGRectMake(318.333, 0, 16.667, CGRectGetHeight(bounds));
  [navigation _adaptiveObserver:observer
         didReadDivisionFrames:@[[NSValue valueWithCGRect:verticalDivision]]
               occlusionFrames:@[]];
  [navigation.view setNeedsLayout];
  [navigation.view layoutIfNeeded];
  CGRect verticalSafeFrame = [self assertComicTextControllerBodyFitsSafeArea:controller];
  XCTAssertEqualWithAccuracy(navigation.additionalSafeAreaInsets.bottom, 0.0, 0.001);
  XCTAssertGreaterThan(navigation.additionalSafeAreaInsets.right, 0.0);
  XCTAssertLessThan(CGRectGetMaxX(verticalSafeFrame), CGRectGetMaxX(fullSafeFrame) - 100.0);
}
- (void)testLibraryChromeUsesContinuousViewportAcrossBookAndLaptopPostures {
  LibraryViewController* controller = (LibraryViewController*)[AppDelegate sharedDelegate].viewController;
  XCTAssertTrue([controller isKindOfClass:[LibraryViewController class]]);
  UIView* view = controller.view;
  GridView* grid = controller.gridView;
  CGRect originalFrame = view.frame;
  UIEdgeInsets originalAdditionalInsets = controller.additionalSafeAreaInsets;
  CRAdaptiveViewportView* originalTracker = controller.adaptiveViewportView;
  NSArray* originalItems = grid.items;
  UINavigationItem* originalNavigationItem = controller.navigationBar.topItem;
  ComicCollection* originalCollection = [controller valueForKey:@"currentCollection"];
  UIView* originalEmptyState = [controller valueForKey:@"emptyStateView"];
  CGPoint originalEmptyOffset = [(UIScrollView*)[originalEmptyState viewWithTag:9901] contentOffset];
  CRFixedAdaptiveViewportView* fixedTracker = [[CRFixedAdaptiveViewportView alloc] initWithFrame:view.bounds];

  @try {
    [originalTracker removeFromSuperview];
    fixedTracker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    fixedTracker.adaptiveViewportDelegate = (id<CRAdaptiveViewportViewDelegate>)controller;
    [view insertSubview:fixedTracker atIndex:0];
    controller.adaptiveViewportView = fixedTracker;
    view.frame = CGRectMake(originalFrame.origin.x, originalFrame.origin.y, 820, 720);
    controller.additionalSafeAreaInsets = UIEdgeInsetsZero;

    UIEdgeInsets asymmetricInsets = UIEdgeInsetsMake(17, 23, 29, 41);
    CGRect openViewport = CRAdaptiveViewportBounds(view.bounds, asymmetricInsets, @[], @[],
                                                   UIUserInterfaceLayoutDirectionLeftToRight);
    fixedTracker.fixedViewportBounds = openViewport;
    [view setNeedsLayout];
    [view layoutIfNeeded];
    [self assertLibraryController:controller fitsViewport:openViewport];

    UIScrollView* emptyScroll = (UIScrollView*)[[controller valueForKey:@"emptyStateView"] viewWithTag:9901];
    emptyScroll.contentOffset = CGPointMake(0, 40);

    CGRect verticalDivision = CGRectMake(400, 0, 20, CGRectGetHeight(view.bounds));
    CGRect bookViewport = CRAdaptiveViewportBounds(view.bounds, asymmetricInsets,
                                                   @[[NSValue valueWithCGRect:verticalDivision]], @[],
                                                   UIUserInterfaceLayoutDirectionLeftToRight);
    fixedTracker.fixedViewportBounds = bookViewport;
    [view setNeedsLayout];
    [view layoutIfNeeded];
    [self assertLibraryController:controller fitsViewport:bookViewport];
    emptyScroll = (UIScrollView*)[[controller valueForKey:@"emptyStateView"] viewWithTag:9901];
    XCTAssertEqualWithAccuracy(emptyScroll.contentOffset.y, 40, 0.5);

    CGRect horizontalDivision = CGRectMake(0, 340, CGRectGetWidth(view.bounds), 18);
    CGRect laptopViewport = CRAdaptiveViewportBounds(view.bounds, asymmetricInsets,
                                                     @[[NSValue valueWithCGRect:horizontalDivision]], @[],
                                                     UIUserInterfaceLayoutDirectionLeftToRight);
    fixedTracker.fixedViewportBounds = laptopViewport;
    [view setNeedsLayout];
    [view layoutIfNeeded];
    [self assertLibraryController:controller fitsViewport:laptopViewport];
    emptyScroll = (UIScrollView*)[[controller valueForKey:@"emptyStateView"] viewWithTag:9901];
    XCTAssertEqualWithAccuracy(emptyScroll.contentOffset.y, 40, 0.5);

    fixedTracker.fixedViewportBounds = openViewport;
    [view setNeedsLayout];
    [view layoutIfNeeded];
    [self assertLibraryController:controller fitsViewport:openViewport];
    XCTAssertEqualObjects(grid.items, originalItems);
    XCTAssertEqual(controller.navigationBar.topItem, originalNavigationItem);
    XCTAssertEqual([controller valueForKey:@"currentCollection"], originalCollection);
  } @finally {
    fixedTracker.adaptiveViewportDelegate = nil;
    [fixedTracker removeFromSuperview];
    controller.adaptiveViewportView = originalTracker;
    originalTracker.adaptiveViewportDelegate = (id<CRAdaptiveViewportViewDelegate>)controller;
    controller.additionalSafeAreaInsets = originalAdditionalInsets;
    view.frame = originalFrame;
    originalTracker.frame = view.bounds;
    [view insertSubview:originalTracker atIndex:0];
    [view setNeedsLayout];
    [view layoutIfNeeded];
    UIScrollView* restoredEmptyScroll = (UIScrollView*)[[controller valueForKey:@"emptyStateView"] viewWithTag:9901];
    restoredEmptyScroll.contentOffset = originalEmptyOffset;
  }
}
- (void)testLibraryResizePreservesGridStateAndShortLayoutGeometry {
  LibraryViewController* controller = (LibraryViewController*)[AppDelegate sharedDelegate].viewController;
  XCTAssertTrue([controller isKindOfClass:[LibraryViewController class]]);
  UIView* view = controller.view;
  GridView* grid = controller.gridView;
  CGRect originalFrame = view.frame;
  UIEdgeInsets originalAdditionalInsets = controller.additionalSafeAreaInsets;
  NSArray* originalItems = grid.items;
  CGFloat originalScrollingAmount = grid.scrollingAmount;
  ComicCollection* collectionBeforeResize = [controller valueForKey:@"currentCollection"];
  NSInteger originalPersistedScrolling = collectionBeforeResize ? collectionBeforeResize.scrolling :
    [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_RootScrolling];
  UIView* originalEmptyState = [controller valueForKey:@"emptyStateView"];
  CGPoint originalEmptyOffset = [(UIScrollView*)[originalEmptyState viewWithTag:9901] contentOffset];

  NSMutableArray* fixtures = [NSMutableArray array];
  for (NSUInteger index = 0; index < 30; index++) {
    Comic* comic = [Comic new];
    [comic setValue:@(100000 + index) forKey:@"sqlRowID"];
    comic.name = [NSString stringWithFormat:@"Adaptive fixture %lu", (unsigned long)index];
    [fixtures addObject:comic];
  }

  @try {
    view.frame = CGRectMake(originalFrame.origin.x, originalFrame.origin.y, 230, 320);
    controller.additionalSafeAreaInsets = UIEdgeInsetsMake(9, 23, 17, 47);
    grid.items = fixtures;
    [view setNeedsLayout];
    [view layoutIfNeeded];
    [grid layoutIfNeeded];
    grid.scrollingAmount = 4500.0;

    NSArray* itemsBeforeResize = grid.items;
    UINavigationItem* navigationItemBeforeResize = controller.navigationBar.topItem;
    id scrollAnchor = grid.visibleItems.firstObject;
    UIView* anchorView = [grid viewForItem:scrollAnchor];
    XCTAssertNotNil(scrollAnchor);
    XCTAssertNotNil(anchorView);
    CGFloat scrollAnchorY = CGRectGetMinY([grid convertRect:anchorView.bounds fromView:anchorView]);
    XCTAssertGreaterThan(grid.scrollingAmount, 4000.0);

    UIView* emptyState = [controller valueForKey:@"emptyStateView"];
    UIScrollView* emptyScroll = (UIScrollView*)[emptyState viewWithTag:9901];
    emptyScroll.contentOffset = CGPointMake(0, 120);
    XCTAssertGreaterThanOrEqual(CGRectGetWidth(grid.frame), 0.0);
    XCTAssertGreaterThanOrEqual(CGRectGetHeight(grid.frame), 0.0);
    XCTAssertLessThanOrEqual(grid.contentMargins.left + kLibraryThumbnailWidth + grid.contentMargins.right,
                             CGRectGetWidth(grid.bounds) + 0.5);

    emptyState = [controller valueForKey:@"emptyStateView"];
    emptyScroll = (UIScrollView*)[emptyState viewWithTag:9901];
    UIView* emptyContent = [emptyState viewWithTag:9902];
    XCTAssertTrue(CGRectEqualToRect(emptyState.frame, grid.frame));
    XCTAssertEqualWithAccuracy(CGRectGetWidth(emptyContent.frame), CGRectGetWidth(emptyScroll.bounds), 0.5);
    XCTAssertEqualWithAccuracy(emptyScroll.contentOffset.y, 120.0, 0.5);
    [self assertSubviewsFitHorizontallyInView:emptyContent];
    UIView* banner = [self viewWithAccessibilityIdentifier:@"library.whatsNew" underView:view];
    if (banner) XCTAssertTrue(banner.hidden);

    view.frame = CGRectMake(originalFrame.origin.x, originalFrame.origin.y, 430, 600);
    controller.additionalSafeAreaInsets = UIEdgeInsetsMake(5, 17, 11, 43);
    [view setNeedsLayout];
    [view layoutIfNeeded];
    [grid layoutIfNeeded];
    NSArray* itemsAfterExpansion = grid.items;
    XCTAssertEqual(itemsAfterExpansion.count, itemsBeforeResize.count);
    for (NSUInteger index = 0; index < itemsBeforeResize.count; index++) {
      XCTAssertEqual(itemsAfterExpansion[index], itemsBeforeResize[index]);
    }
    anchorView = [grid viewForItem:scrollAnchor];
    XCTAssertTrue([grid.visibleItems indexOfObjectIdenticalTo:scrollAnchor] != NSNotFound);
    XCTAssertEqualWithAccuracy(CGRectGetMinY([grid convertRect:anchorView.bounds fromView:anchorView]),
                               scrollAnchorY, 0.5);
    XCTAssertLessThan(grid.scrollingAmount, 3000.0);
    XCTAssertEqual(controller.navigationBar.topItem, navigationItemBeforeResize);
    XCTAssertEqual([controller valueForKey:@"currentCollection"], collectionBeforeResize);

    NSInteger expandedPersistedScrolling = collectionBeforeResize ? collectionBeforeResize.scrolling :
      [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_RootScrolling];
    XCTAssertEqual(expandedPersistedScrolling, (NSInteger)lround(grid.scrollingAmount));

    view.frame = CGRectMake(originalFrame.origin.x, originalFrame.origin.y, 230, 320);
    controller.additionalSafeAreaInsets = UIEdgeInsetsMake(9, 23, 17, 47);
    [view setNeedsLayout];
    [view layoutIfNeeded];
    [grid layoutIfNeeded];
    anchorView = [grid viewForItem:scrollAnchor];
    XCTAssertTrue([grid.visibleItems indexOfObjectIdenticalTo:scrollAnchor] != NSNotFound);
    XCTAssertEqualWithAccuracy(CGRectGetMinY([grid convertRect:anchorView.bounds fromView:anchorView]),
                               scrollAnchorY, 0.5);
    XCTAssertEqualWithAccuracy(grid.scrollingAmount, 4500.0, 0.5);
    XCTAssertEqual(controller.navigationBar.topItem, navigationItemBeforeResize);
    XCTAssertEqual([controller valueForKey:@"currentCollection"], collectionBeforeResize);

    NSInteger collapsedPersistedScrolling = collectionBeforeResize ? collectionBeforeResize.scrolling :
      [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_RootScrolling];
    XCTAssertEqual(collapsedPersistedScrolling, (NSInteger)lround(grid.scrollingAmount));
  } @finally {
    controller.additionalSafeAreaInsets = originalAdditionalInsets;
    view.frame = originalFrame;
    grid.items = originalItems;
    [view setNeedsLayout];
    [view layoutIfNeeded];
    [grid layoutIfNeeded];
    grid.scrollingAmount = originalScrollingAmount;
    if (collectionBeforeResize) {
      collectionBeforeResize.scrolling = (int)originalPersistedScrolling;
      [[LibraryConnection mainConnection] updateObject:collectionBeforeResize];
    } else {
      [[NSUserDefaults standardUserDefaults] setInteger:originalPersistedScrolling forKey:kDefaultKey_RootScrolling];
    }
    UIView* restoredEmptyState = [controller valueForKey:@"emptyStateView"];
    [(UIScrollView*)[restoredEmptyState viewWithTag:9901] setContentOffset:originalEmptyOffset];
  }
}
- (void)testEachLibraryThumbnailOwnsItsContextMenuPreview {
  AppDelegate* app = [AppDelegate sharedDelegate];
  LibraryViewController* controller = (LibraryViewController*)app.viewController;
  XCTAssertTrue([controller isKindOfClass:[LibraryViewController class]]);
  XCTAssertNotNil(app.window);

  Comic* comic = [Comic new];
  comic.name = @"Preview comic";
  ComicCollection* collection = [ComicCollection new];
  collection.name = @"Preview collection";
  UIView* comicCover = [controller gridView:controller.gridView viewForItem:comic];
  UIView* collectionCover = [controller gridView:controller.gridView viewForItem:collection];
  XCTAssertNotNil(comicCover);
  XCTAssertNotNil(collectionCover);

  UIView* container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 400, 240)];
  [app.window addSubview:container];
  comicCover.frame = CGRectMake(20, 25, CGRectGetWidth(comicCover.bounds), CGRectGetHeight(comicCover.bounds));
  collectionCover.frame = CGRectMake(210, 35, CGRectGetWidth(collectionCover.bounds), CGRectGetHeight(collectionCover.bounds));
  [container addSubview:comicCover];
  [container addSubview:collectionCover];

  UIContextMenuInteraction* comicInteraction = [self contextMenuInteractionForView:comicCover];
  UIContextMenuInteraction* collectionInteraction = [self contextMenuInteractionForView:collectionCover];
  XCTAssertNotNil(comicInteraction);
  XCTAssertNotNil(collectionInteraction);
  XCTAssertNotEqual(comicInteraction, collectionInteraction);
  XCTAssertEqual(comicInteraction.view, comicCover);
  XCTAssertEqual(collectionInteraction.view, collectionCover);
  XCTAssertEqual(comicInteraction.delegate, controller);
  XCTAssertEqual(collectionInteraction.delegate, controller);

  UIContextMenuConfiguration* comicConfiguration =
    [controller contextMenuInteraction:comicInteraction configurationForMenuAtLocation:CGPointZero];
  UIContextMenuConfiguration* collectionConfiguration =
    [controller contextMenuInteraction:collectionInteraction configurationForMenuAtLocation:CGPointZero];
  XCTAssertNotNil(comicConfiguration);
  XCTAssertNotNil(collectionConfiguration);
  XCTAssertEqualObjects(comicConfiguration.identifier, @"Comic:0");
  XCTAssertEqualObjects(collectionConfiguration.identifier, @"Collection:0");

  if (comicInteraction && collectionInteraction && comicConfiguration && collectionConfiguration) {
    UITargetedPreview* comicHighlight;
    UITargetedPreview* comicDismissal;
    UITargetedPreview* collectionHighlight;
    UITargetedPreview* collectionDismissal;
    if (@available(iOS 16.0, *)) {
      comicHighlight = [controller contextMenuInteraction:comicInteraction
                                            configuration:comicConfiguration
                      highlightPreviewForItemWithIdentifier:comicConfiguration.identifier];
      comicDismissal = [controller contextMenuInteraction:comicInteraction
                                            configuration:comicConfiguration
                      dismissalPreviewForItemWithIdentifier:comicConfiguration.identifier];
      collectionHighlight = [controller contextMenuInteraction:collectionInteraction
                                                 configuration:collectionConfiguration
                           highlightPreviewForItemWithIdentifier:collectionConfiguration.identifier];
      collectionDismissal = [controller contextMenuInteraction:collectionInteraction
                                                 configuration:collectionConfiguration
                           dismissalPreviewForItemWithIdentifier:collectionConfiguration.identifier];
    } else {
      comicHighlight = [controller contextMenuInteraction:comicInteraction
                    previewForHighlightingMenuWithConfiguration:comicConfiguration];
      comicDismissal = [controller contextMenuInteraction:comicInteraction
                       previewForDismissingMenuWithConfiguration:comicConfiguration];
      collectionHighlight = [controller contextMenuInteraction:collectionInteraction
                         previewForHighlightingMenuWithConfiguration:collectionConfiguration];
      collectionDismissal = [controller contextMenuInteraction:collectionInteraction
                            previewForDismissingMenuWithConfiguration:collectionConfiguration];
    }
    [self assertPreview:comicHighlight targetsView:comicCover inContainer:container];
    [self assertPreview:comicDismissal targetsView:comicCover inContainer:container];
    [self assertPreview:collectionHighlight targetsView:collectionCover inContainer:container];
    [self assertPreview:collectionDismissal targetsView:collectionCover inContainer:container];
  }
  [container removeFromSuperview];
}
- (void)testImportPreservesOriginalAndReusesExactDuplicateWithoutChangingProgress {
  NSString* name = [NSString stringWithFormat:@"Regression-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* source = [self createPDFNamed:name inDirectory:NSTemporaryDirectory()];
  NSString* first = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:name];
  NSString* second = [[first stringByDeletingPathExtension] stringByAppendingString:@" (2).pdf"];
  [self.createdPaths addObjectsFromArray:@[first, second]];
  NSArray* firstResult = [self importResultAndWait:source];
  XCTAssertEqualObjects(firstResult[0], @YES);
  XCTAssertEqualObjects(firstResult[1], [NSURL fileURLWithPath:first]);
  XCTAssertEqualObjects(firstResult[2], @YES);
  [self waitForLibrary];

  Comic* comic = [(LibraryViewController*)[AppDelegate sharedDelegate].viewController
    _indexedComicForURL:[NSURL fileURLWithPath:first]];
  XCTAssertNotNil(comic);
  comic.status = 4;
  XCTAssertTrue([[LibraryConnection mainConnection] updateObject:comic]);
  [[CRLibrarySyncCoordinator sharedCoordinator] recordComic:comic currentPage:4 pageCount:10];

  NSArray* duplicateResult = [self importResultAndWait:source];
  XCTAssertEqualObjects(duplicateResult[0], @YES);
  XCTAssertEqualObjects(duplicateResult[1], [NSURL fileURLWithPath:first]);
  XCTAssertEqualObjects(duplicateResult[2], @NO);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:first], [NSData dataWithContentsOfURL:source]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:second]);
  [self waitForLibrary];
  XCTAssertTrue([[LibraryConnection mainConnection] refetchObject:comic]);
  XCTAssertEqual([CRLibrarySyncCoordinator.sharedCoordinator initialPageForComic:comic pageCount:10], 4);
}

- (void)testImportDoesNotDeduplicateSameSizedDifferentComics {
  NSString* token = NSUUID.UUID.UUIDString;
  NSString* firstName = [NSString stringWithFormat:@"Same-A-%@.pdf", token];
  NSString* secondName = [NSString stringWithFormat:@"Same-B-%@.pdf", token];
  NSURL* firstSource = [self createPDFNamed:firstName inDirectory:NSTemporaryDirectory()];
  NSURL* secondSource = [self createPDFNamed:secondName inDirectory:NSTemporaryDirectory()];
  NSMutableData* firstData = [NSMutableData dataWithContentsOfURL:firstSource];
  NSMutableData* secondData = [NSMutableData dataWithContentsOfURL:secondSource];
  NSUInteger commonSize = MAX(firstData.length, secondData.length);
  [firstData increaseLengthBy:commonSize - firstData.length];
  [secondData increaseLengthBy:commonSize - secondData.length];
  XCTAssertTrue([firstData writeToURL:firstSource atomically:YES]);
  XCTAssertTrue([secondData writeToURL:secondSource atomically:YES]);
  XCTAssertEqual(firstData.length, secondData.length);
  XCTAssertNotEqualObjects(firstData, secondData);

  NSURL* firstDestination = [NSURL fileURLWithPath:
    [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:firstName]];
  NSURL* secondDestination = [NSURL fileURLWithPath:
    [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:secondName]];
  [self.createdPaths addObjectsFromArray:@[firstDestination.path, secondDestination.path]];

  NSArray* firstResult = [self importResultAndWait:firstSource];
  NSArray* secondResult = [self importResultAndWait:secondSource];

  XCTAssertEqualObjects(firstResult, (@[@YES, firstDestination, @YES]));
  XCTAssertEqualObjects(secondResult, (@[@YES, secondDestination, @YES]));
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:firstDestination.path]);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:secondDestination.path]);
}

- (void)testExternalPDFReaderOpensInPlaceWithoutCopyingOrModifyingSource {
  NSString* name = [NSString stringWithFormat:@"External-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* source = [self createPDFNamed:name inDirectory:NSTemporaryDirectory()];
  NSString* destination = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:name];
  [self.createdPaths addObject:destination];
  NSData* originalData = [NSData dataWithContentsOfURL:source];
  NSDate* originalModificationDate = [[[NSFileManager defaultManager]
    attributesOfItemAtPath:source.path error:NULL] objectForKey:NSFileModificationDate];

  ComicViewController* reader = [[ComicViewController alloc] initWithExternalFileURL:source delegate:nil];
  XCTAssertNotNil(reader);
  XCTAssertTrue(reader.isExternalComic);
  XCTAssertEqualObjects(reader.externalFileURL, source);
  [reader loadViewIfNeeded];
  UIBarButtonItem* addButton = [reader valueForKey:@"addToLibraryButtonItem"];
  XCTAssertEqualObjects(addButton.accessibilityIdentifier, @"reader.external.addToLibrary");
  [reader saveState];
  reader = nil;

  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:destination]);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:source], originalData);
  XCTAssertEqualObjects([[[NSFileManager defaultManager] attributesOfItemAtPath:source.path error:NULL]
                         objectForKey:NSFileModificationDate], originalModificationDate);
}

- (void)testInvalidExternalComicIsRejected {
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"Invalid-%@.pdf", NSUUID.UUID.UUIDString]];
  XCTAssertTrue([[@"not a PDF" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]);
  [self.createdPaths addObject:path];
  ComicViewController* reader = [[ComicViewController alloc]
    initWithExternalFileURL:[NSURL fileURLWithPath:path] delegate:nil];
  XCTAssertNil(reader);
}

- (void)testExternalOpenQueueFiltersUnsupportedURLsWithoutReordering {
  NSArray<NSURL*>* urls = @[
    [NSURL fileURLWithPath:@"/tmp/Third.cbz"],
    [NSURL fileURLWithPath:@"/tmp/Ignore.txt"],
    [NSURL fileURLWithPath:@"/tmp/First.pdf"],
    [NSURL URLWithString:@"https://example.invalid/Remote.cbr"],
    [NSURL fileURLWithPath:@"/tmp/.Hidden.zip"],
    [NSURL fileURLWithPath:@"/tmp/Second.cbr"]
  ];
  NSArray<NSURL*>* expected = @[urls[0], urls[2], urls[5]];
  XCTAssertEqualObjects([LibraryViewController supportedComicURLsFromURLs:urls], expected);
}

- (void)testDirectOpenPickerIntentIsControllerScopedAndTemporaryCopyLivesForReaderOnly {
  CRDirectOpenRecordingLibraryViewController* controller =
    [[CRDirectOpenRecordingLibraryViewController alloc] init];
  CRPresentationRecordingViewController* directPresenter =
    [[CRPresentationRecordingViewController alloc] init];
  CRPresentationRecordingViewController* importPresenter =
    [[CRPresentationRecordingViewController alloc] init];
  [controller _presentComicDocumentPickerOpeningDirectly:YES fromController:directPresenter];
  [controller _presentComicDocumentPickerOpeningDirectly:NO fromController:importPresenter];

  UIDocumentPickerViewController* directPicker =
    (UIDocumentPickerViewController*)directPresenter.recordedPresentedViewController;
  UIDocumentPickerViewController* importPicker =
    (UIDocumentPickerViewController*)importPresenter.recordedPresentedViewController;
  XCTAssertEqualObjects(NSStringFromClass(directPicker.class), @"CRComicDocumentPickerViewController");
  XCTAssertEqualObjects(NSStringFromClass(importPicker.class), @"CRComicDocumentPickerViewController");
  XCTAssertEqualObjects([directPicker valueForKey:@"opensComicsDirectly"], @YES);
  XCTAssertEqualObjects([importPicker valueForKey:@"opensComicsDirectly"], @NO);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  XCTAssertEqual(directPicker.documentPickerMode, UIDocumentPickerModeImport);
  XCTAssertEqual(importPicker.documentPickerMode, UIDocumentPickerModeImport);
#pragma clang diagnostic pop

  // Dismissing another picker must not erase the intent carried by this picker.
  UIPresentationController* unrelatedDismissal = [[UIPresentationController alloc]
    initWithPresentedViewController:importPicker presentingViewController:controller];
  [controller presentationControllerDidDismiss:unrelatedDismissal];
  XCTAssertEqualObjects([directPicker valueForKey:@"opensComicsDirectly"], @YES);

  NSString* name = [NSString stringWithFormat:@"Direct-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* pickerCopy = [self createPDFNamed:name inDirectory:NSTemporaryDirectory()];
  NSString* libraryPath = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:name];
  [self.createdPaths addObject:libraryPath];
  NSData* expectedData = [NSData dataWithContentsOfURL:pickerCopy];

  [controller documentPicker:directPicker didPickDocumentsAtURLs:@[pickerCopy]];

  XCTAssertTrue(controller.enqueuedURLsDeleteOnClose);
  XCTAssertEqual(controller.enqueuedURLs.count, 1u);
  NSURL* stagedURL = controller.enqueuedURLs.firstObject;
  NSString* stagedDirectory = stagedURL.path.stringByDeletingLastPathComponent;
  [self.createdPaths addObject:stagedDirectory];
  XCTAssertEqualObjects(stagedURL.lastPathComponent, name);
  XCTAssertEqualObjects(stagedDirectory.stringByDeletingLastPathComponent.stringByStandardizingPath,
                        CRDirectOpenTemporaryRootPath().stringByStandardizingPath);
  XCTAssertFalse([stagedURL.path.stringByStandardizingPath
    hasPrefix:[[LibraryConnection libraryRootPath].stringByStandardizingPath
      stringByAppendingString:@"/"]]);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:stagedURL.path]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:pickerCopy.path],
                 @"A picker-owned container copy should be moved into transient storage");
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:stagedURL], expectedData);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:libraryPath]);
  XCTAssertNil([controller _indexedComicForURL:stagedURL]);
  XCTAssertFalse([[[LibraryConnection mainConnection].fetchAllComicsByName valueForKey:@"name"]
    containsObject:name]);

  @autoreleasepool {
    ComicViewController* reader = [[ComicViewController alloc]
      initWithExternalFileURL:stagedURL delegate:nil deletesFileOnDealloc:YES];
    XCTAssertNotNil(reader);
    XCTAssertEqualObjects(reader.externalFileURL, stagedURL);
    XCTAssertTrue(reader.isExternalComic);
  }

  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:stagedURL.path]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:stagedDirectory]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:libraryPath]);
}

- (void)testDirectOpenPickerPreservesUnexpectedSourceWhileStagingPrivateCopy {
  CRDirectOpenRecordingLibraryViewController* controller =
    [[CRDirectOpenRecordingLibraryViewController alloc] init];
  CRPresentationRecordingViewController* presenter =
    [[CRPresentationRecordingViewController alloc] init];
  [controller _presentComicDocumentPickerOpeningDirectly:YES fromController:presenter];
  UIDocumentPickerViewController* picker =
    (UIDocumentPickerViewController*)presenter.recordedPresentedViewController;

  NSString* sourceDirectory = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                                     NSUserDomainMask,
                                                                     YES) firstObject]
    stringByAppendingPathComponent:[NSString stringWithFormat:@"DirectOpenSource-%@",
                                                               NSUUID.UUID.UUIDString]];
  [self.createdPaths addObject:sourceDirectory];
  NSString* name = [NSString stringWithFormat:@"Preserved-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* possibleOriginal = [self createPDFNamed:name inDirectory:sourceDirectory];
  NSData* expectedData = [NSData dataWithContentsOfURL:possibleOriginal];

  [controller documentPicker:picker didPickDocumentsAtURLs:@[possibleOriginal]];

  XCTAssertTrue(controller.enqueuedURLsDeleteOnClose);
  XCTAssertEqual(controller.enqueuedURLs.count, 1u);
  NSURL* stagedURL = controller.enqueuedURLs.firstObject;
  [self.createdPaths addObject:stagedURL.path.stringByDeletingLastPathComponent];
  XCTAssertNotEqualObjects(stagedURL, possibleOriginal);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:possibleOriginal.path],
                @"An unexpected source URL might be the original and must be preserved");
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:possibleOriginal], expectedData);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:stagedURL], expectedData);

  CRRemoveDirectOpenTemporaryFileAtURL(stagedURL);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:stagedURL.path]);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:possibleOriginal.path]);
}

- (void)testInvalidDirectOpenPickerCopyIsRemovedWhenReaderRejectsIt {
  CRDirectOpenRecordingLibraryViewController* controller =
    [[CRDirectOpenRecordingLibraryViewController alloc] init];
  CRPresentationRecordingViewController* presenter =
    [[CRPresentationRecordingViewController alloc] init];
  [controller _presentComicDocumentPickerOpeningDirectly:YES fromController:presenter];
  UIDocumentPickerViewController* picker =
    (UIDocumentPickerViewController*)presenter.recordedPresentedViewController;

  NSString* name = [NSString stringWithFormat:@"Invalid-Direct-%@.pdf", NSUUID.UUID.UUIDString];
  NSString* sourcePath = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  XCTAssertTrue([[@"not a PDF" dataUsingEncoding:NSUTF8StringEncoding]
    writeToFile:sourcePath atomically:YES]);
  [self.createdPaths addObject:sourcePath];

  [controller documentPicker:picker
       didPickDocumentsAtURLs:@[[NSURL fileURLWithPath:sourcePath]]];

  XCTAssertTrue(controller.enqueuedURLsDeleteOnClose);
  XCTAssertEqual(controller.enqueuedURLs.count, 1u);
  NSURL* stagedURL = controller.enqueuedURLs.firstObject;
  NSString* stagedDirectory = stagedURL.path.stringByDeletingLastPathComponent;
  [self.createdPaths addObject:stagedDirectory];
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:stagedURL.path]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:sourcePath]);

  @autoreleasepool {
    ComicViewController* reader = [[ComicViewController alloc]
      initWithExternalFileURL:stagedURL delegate:nil deletesFileOnDealloc:YES];
    XCTAssertNil(reader);
  }

  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:stagedURL.path]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:stagedDirectory]);
}

#if TARGET_OS_MACCATALYST
- (void)testExternalOpenQueueReplacesFullScreenReaderWhileLibraryViewIsDetached {
  AppDelegate* app = [AppDelegate sharedDelegate];
  UIWindow* window = app.window;
  XCTAssertNotNil(window.windowScene);
  XCTAssertEqual(window.windowScene.activationState, UISceneActivationStateForegroundActive);
  XCTAssertFalse(app.isAlertVisible);
  if (!window.windowScene ||
      window.windowScene.activationState != UISceneActivationStateForegroundActive) return;

  CRQueueDrainRecordingLibraryViewController* library =
    [[CRQueueDrainRecordingLibraryViewController alloc] init];
  library.view = [[UIView alloc] init];
  [library setValue:window forKey:@"window"];
  [library setValue:@YES forKey:@"launched"];
  [library setValue:@NO forKey:@"startupPresentationsPending"];
  CRQueueDrainTestComicViewController* reader = [[CRQueueDrainTestComicViewController alloc] init];
  library.presentedReader = reader;
  // Reproduce the UIKit state: the full-screen reader belongs to the active
  // window while its presenting library view has no window.
  [window addSubview:reader.view];
  @try {
    XCTAssertNil(library.view.window);
    XCTAssertEqual(reader.view.window, window);
    [library enqueueComicURLsForOpening:@[
      [NSURL fileURLWithPath:@"/tmp/Queued-While-Reader-Full-Screen.pdf"]
    ]];
    XCTAssertTrue(library.queueDismissalRequested,
                  @"An active owning scene must request replacement even when the library view is detached");
    XCTAssertTrue(reader.saveStateCalled);
  } @finally {
    [NSObject cancelPreviousPerformRequestsWithTarget:library];
    [reader.view removeFromSuperview];
    library.presentedReader = nil;
    [library setValue:nil forKey:@"window"];
  }
}

- (void)testCatalystStandardOpenCommandIsAvailableAndTitledForLibraryAndReader {
  SEL openAction = NSSelectorFromString(@"open:");
  CRDirectOpenRecordingLibraryViewController* library =
    [[CRDirectOpenRecordingLibraryViewController alloc] init];
  UICommand* libraryCommand = [UICommand commandWithTitle:@"Open…"
                                                    image:nil
                                                   action:openAction
                                             propertyList:nil];

  XCTAssertTrue([library canPerformAction:openAction withSender:libraryCommand]);
  [library validateCommand:libraryCommand];
  XCTAssertEqualObjects(libraryCommand.title, @"Open Comic…");
  XCTAssertFalse((libraryCommand.attributes & UIMenuElementAttributesDisabled) != 0);
  XCTAssertEqual([library.keyCommands indexOfObjectPassingTest:^BOOL(UIKeyCommand* command,
                                                                      NSUInteger index,
                                                                      BOOL* stop) {
    return [command.input isEqualToString:@"o"] &&
      command.modifierFlags == UIKeyModifierCommand;
  }], NSNotFound);

  NSString* name = [NSString stringWithFormat:@"Menu-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* source = [self createPDFNamed:name inDirectory:NSTemporaryDirectory()];
  ComicViewController* reader = [[ComicViewController alloc]
    initWithExternalFileURL:source delegate:(id<CRExternalComicReaderDelegate>)library];
  UICommand* readerCommand = [UICommand commandWithTitle:@"Open…"
                                                   image:nil
                                                  action:openAction
                                            propertyList:nil];

  XCTAssertNotNil(reader);
  XCTAssertTrue([reader canPerformAction:openAction withSender:readerCommand]);
  [reader validateCommand:readerCommand];
  XCTAssertEqualObjects(readerCommand.title, @"Open Comic…");
  XCTAssertFalse((readerCommand.attributes & UIMenuElementAttributesDisabled) != 0);
  XCTAssertEqual([reader.keyCommands indexOfObjectPassingTest:^BOOL(UIKeyCommand* command,
                                                                     NSUInteger index,
                                                                     BOOL* stop) {
    return [command.input isEqualToString:@"o"] &&
      command.modifierFlags == UIKeyModifierCommand;
  }], NSNotFound);
}
#endif

- (void)testDocumentTypesAdvertiseGenericZipAndRARArchives {
  NSArray* documentTypes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDocumentTypes"];
  NSArray* identifiers = [documentTypes valueForKeyPath:@"@unionOfArrays.LSItemContentTypes"];
  XCTAssertTrue([identifiers containsObject:@"public.zip-archive"]);
  XCTAssertTrue([identifiers containsObject:@"com.rarlab.rar-archive"]);
}
- (void)testFileReferenceURLImportPreservesOriginalNameAndContents {
  NSString* name = [NSString stringWithFormat:@"File-Reference-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* source = [self createPDFNamed:name inDirectory:NSTemporaryDirectory()];
  NSURL* reference = source.fileReferenceURL;
  NSString* destination = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:name];
  [self.createdPaths addObject:destination];
  XCTAssertNotNil(reference);
  XCTAssertTrue(reference.isFileReferenceURL);
  XCTAssertTrue([self importAndWait:reference]);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:destination], [NSData dataWithContentsOfURL:source]);
}
- (void)testInboxIsCopiedIntoLibraryAndExistingLibraryFileIsNotDuplicated {
  NSString* name = [NSString stringWithFormat:@"Inbox-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* source = [self createPDFNamed:name inDirectory:[[LibraryConnection libraryRootPath] stringByAppendingPathComponent:@"Inbox"]];
  NSString* destination = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:name];
  [self.createdPaths addObject:destination];
  XCTAssertTrue([self importAndWait:source]);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:source.path]);
  XCTAssertTrue([self importAndWait:[NSURL fileURLWithPath:destination]]);
  NSString* duplicate = [[destination stringByDeletingPathExtension] stringByAppendingString:@" (2).pdf"];
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:duplicate]);
}
- (void)testCopyWithExistingLibraryIdentifierKeepsBothComics {
  NSString* name = [NSString stringWithFormat:@"Copy-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* source = [self createPDFNamed:name inDirectory:NSTemporaryDirectory()];
  NSString* first = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:name];
  NSString* second = [[first stringByDeletingPathExtension] stringByAppendingString:@" (2).pdf"];
  [self.createdPaths addObjectsFromArray:@[first, second]];
  XCTAssertTrue([self importAndWait:source]);
  [self waitForLibrary];
  NSData* identifier = [[NSFileManager defaultManager] extendedAttributeDataWithName:kLibraryExtendedAttribute forFileAtPath:first];
  XCTAssertNotNil(identifier);
  XCTAssertTrue([[NSFileManager defaultManager] copyItemAtPath:first toPath:second error:NULL]);
  XCTAssertTrue([[NSFileManager defaultManager] setExtendedAttributeData:identifier withName:kLibraryExtendedAttribute forFileAtPath:second]);
  [[AppDelegate sharedDelegate] updateLibrary];
  [self waitForLibrary];
  NSArray* comics = [[LibraryConnection mainConnection] fetchAllComicsByName];
  NSPredicate* matching = [NSPredicate predicateWithFormat:@"name IN %@", @[name, second.lastPathComponent]];
  NSArray* copies = [comics filteredArrayUsingPredicate:matching];
  XCTAssertEqual(copies.count, 2u);
  if (copies.count == 2) {
    XCTAssertNotEqual(((Comic*)copies[0]).sqlRowID, ((Comic*)copies[1]).sqlRowID);
  }
}
- (void)testSameSizeReplacementDoesNotReuseReadingPage {
  NSString* name = [NSString stringWithFormat:@"Reading-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* source = [self createPDFNamed:name inDirectory:NSTemporaryDirectory()];
  NSString* path = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:name];
  [self.createdPaths addObject:path];
  XCTAssertTrue([self importAndWait:source]);
  [self waitForLibrary];

  NSPredicate* matching = [NSPredicate predicateWithFormat:@"name == %@", name];
  Comic* comic = [[[LibraryConnection mainConnection].fetchAllComicsByName
                    filteredArrayUsingPredicate:matching] firstObject];
  XCTAssertNotNil(comic);
  if (!comic) return;

  NSFileManager* manager = [NSFileManager defaultManager];
  NSDate* fixedModificationDate = [NSDate dateWithTimeIntervalSince1970:1700000000.0];
  XCTAssertTrue([manager setAttributes:@{NSFileModificationDate: fixedModificationDate}
                                ofItemAtPath:path error:NULL]);
  comic.status = 3;
  XCTAssertTrue([[LibraryConnection mainConnection] updateObject:comic]);
  CRLibrarySyncCoordinator* coordinator = [CRLibrarySyncCoordinator sharedCoordinator];
  [coordinator recordComic:comic currentPage:7 pageCount:12];
  XCTAssertEqual([coordinator initialPageForComic:comic pageCount:12], 7);

  NSDictionary* oldAttributes = [manager attributesOfItemAtPath:path error:NULL];
  NSDate* capturedModificationDate = oldAttributes[NSFileModificationDate];
  NSData* oldData = [NSData dataWithContentsOfFile:path];
  XCTAssertGreaterThan(oldData.length, 0u);
  XCTAssertNotNil(capturedModificationDate);
  if (!oldData.length || !capturedModificationDate) {
    [coordinator didDeleteComics:@[comic] paths:@[path]];
    return;
  }
  NSMutableData* replacementData = [oldData mutableCopy];
  NSUInteger changedOffset = replacementData.length / 2;
  uint8_t changedByte = ((const uint8_t*)replacementData.bytes)[changedOffset] ^ 0x01;
  [replacementData replaceBytesInRange:NSMakeRange(changedOffset, 1) withBytes:&changedByte];
  NSString* replacementPath = [[LibraryConnection libraryRootPath]
    stringByAppendingPathComponent:[NSString stringWithFormat:@".replacement-%@", NSUUID.UUID.UUIDString]];
  [self.createdPaths addObject:replacementPath];
  XCTAssertTrue([replacementData writeToFile:replacementPath atomically:NO]);
  XCTAssertTrue([manager setAttributes:@{NSFileModificationDate: capturedModificationDate}
                                ofItemAtPath:replacementPath error:NULL]);
  NSError* replacementError = nil;
  XCTAssertTrue([manager replaceItemAtURL:[NSURL fileURLWithPath:path]
                            withItemAtURL:[NSURL fileURLWithPath:replacementPath]
                           backupItemName:nil
                                  options:NSFileManagerItemReplacementUsingNewMetadataOnly
                         resultingItemURL:NULL
                                    error:&replacementError], @"%@", replacementError);
  XCTAssertTrue([manager setAttributes:@{NSFileModificationDate: capturedModificationDate}
                                ofItemAtPath:path error:NULL]);

  NSDictionary* newAttributes = [manager attributesOfItemAtPath:path error:NULL];
  XCTAssertEqualObjects(oldAttributes[NSFileSize], newAttributes[NSFileSize]);
  XCTAssertEqualObjects(oldAttributes[NSFileModificationDate], newAttributes[NSFileModificationDate]);
  XCTAssertNotEqualObjects(oldData, [NSData dataWithContentsOfFile:path]);
  XCTAssertNotEqualObjects(oldAttributes[NSFileSystemFileNumber], newAttributes[NSFileSystemFileNumber]);

  // Model the new database row created when the replacement has no old xattr.
  Comic* replacementComic = [[Comic alloc] init];
  replacementComic.collection = comic.collection;
  replacementComic.name = comic.name;
  replacementComic.status = -1;
  XCTAssertEqual([coordinator initialPageForComic:replacementComic pageCount:12], 0);
  [coordinator didDeleteComics:@[comic] paths:@[path]];
}
- (void)testUnindexedLibraryLocationsAreCopiedToRoot {
  NSString* root = [LibraryConnection libraryRootPath];
  for (NSString* folder in @[[NSString stringWithFormat:@"Nested-%@/Child", NSUUID.UUID.UUIDString],
                              [NSString stringWithFormat:@".Hidden-%@", NSUUID.UUID.UUIDString]]) {
    NSString* directory = [root stringByAppendingPathComponent:folder];
    [self.createdPaths addObject:[root stringByAppendingPathComponent:folder.pathComponents.firstObject]];
    NSString* name = [NSString stringWithFormat:@"Visible-%@.pdf", NSUUID.UUID.UUIDString];
    NSURL* source = [self createPDFNamed:name inDirectory:directory];
    NSString* destination = [root stringByAppendingPathComponent:name];
    [self.createdPaths addObject:destination];
    XCTAssertTrue([self importAndWait:source]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:destination], [NSData dataWithContentsOfURL:source]);
    [self waitForLibrary];
    NSArray* comics = [[LibraryConnection mainConnection] fetchAllComicsByName];
    NSPredicate* matching = [NSPredicate predicateWithFormat:@"name == %@", name];
    XCTAssertEqual([[comics filteredArrayUsingPredicate:matching] count], 1u);
  }
}
- (void)testExistingCollectionComicAndProgressSurviveRepeatedLibraryScans {
  NSString* root = [LibraryConnection libraryRootPath];
  NSString* directory = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"Collection-%@", NSUUID.UUID.UUIDString]];
  [self.createdPaths addObject:directory];
  NSString* name = [NSString stringWithFormat:@"Comic-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* source = [self createPDFNamed:name inDirectory:directory];
  NSString* destination = [root stringByAppendingPathComponent:name];
  [self.createdPaths addObject:destination];
  XCTAssertTrue([self importAndWait:source]);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:source.path]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:destination]);

  [self waitForLibrary];
  Comic* comic = [(LibraryViewController*)[AppDelegate sharedDelegate].viewController
    _indexedComicForURL:source];
  XCTAssertNotNil(comic);
  if (!comic) return;
  [[CRLibrarySyncCoordinator sharedCoordinator] recordComic:comic currentPage:2 pageCount:3];

  // App launch performs this same non-forced library scan. Repeating it with
  // an unchanged collection folder must not treat the collection or comic as
  // stale, move the file to the root, or discard exact-page state.
  [[AppDelegate sharedDelegate] updateLibrary];
  [self waitForLibrary];
  Comic* rescanned = [(LibraryViewController*)[AppDelegate sharedDelegate].viewController
    _indexedComicForURL:source];
  XCTAssertNotNil(rescanned);
  XCTAssertEqualObjects(rescanned.name, name);
  XCTAssertNotEqual(rescanned.collection, 0);
  XCTAssertEqual([[CRLibrarySyncCoordinator sharedCoordinator] initialPageForComic:rescanned pageCount:3], 2);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:source.path]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:destination]);
}
- (void)testUnsupportedImportsAreRejected {
  XCTAssertFalse([[AppDelegate sharedDelegate] importComicAtURL:[NSURL URLWithString:@"https://example.invalid/comic.pdf"]]);
  XCTAssertFalse([[AppDelegate sharedDelegate] importComicAtURL:[NSURL fileURLWithPath:@"/tmp/not-a-comic.txt"]]);
}
- (void)testReplacingAlertCancelsOnlyThePreviousAlert {
  AppDelegate* app = [AppDelegate sharedDelegate];
  AlertRecorder* first = [AlertRecorder new];
  AlertRecorder* second = [AlertRecorder new];
  [app showAlertWithTitle:@"First" message:nil confirmButton:@"OK" cancelButton:@"Cancel" delegate:first confirmSelector:@selector(confirm:) cancelSelector:@selector(cancel:) argument:nil];
  [app showAlertWithTitle:@"Second" message:nil confirmButton:@"OK" cancelButton:@"Cancel" delegate:second confirmSelector:@selector(confirm:) cancelSelector:@selector(cancel:) argument:nil];
  XCTAssertEqual(first.cancellations, 1u);
  XCTAssertEqual(second.cancellations, 0u);
  XCTAssertTrue(app.isAlertVisible);
  [app dismissAlert:NO];
  XCTAssertEqual(first.cancellations, 1u);
  XCTAssertEqual(second.cancellations, 1u);
  XCTAssertFalse(app.isAlertVisible);
}
- (void)testAlertCallbackCanPresentAnotherAlert {
  AppDelegate* app = [AppDelegate sharedDelegate];
  AlertRecorder* recorder = [AlertRecorder new];
  recorder.showAnotherAlert = YES;
  [app showAlertWithTitle:@"First" message:nil button:@"OK" delegate:recorder selector:@selector(confirm:) argument:nil];
  [app _dismissAlertWithButtonIndex:1];
  XCTAssertEqual(recorder.confirmations, 1u);
  XCTAssertTrue(app.isAlertVisible);
  [app dismissAlert:NO];
  XCTAssertFalse(app.isAlertVisible);
}
- (void)testAlertReplacementPreservesNewerAlertFromCancellation {
  AppDelegate* app = [AppDelegate sharedDelegate];
  AlertRecorder* recorder = [AlertRecorder new];
  recorder.showAnotherAlertOnCancel = YES;
  [app showAlertWithTitle:@"First" message:nil confirmButton:@"OK" cancelButton:@"Cancel" delegate:recorder confirmSelector:@selector(confirm:) cancelSelector:@selector(cancel:) argument:nil];
  [app showAlertWithTitle:@"Replacement" message:nil button:@"OK"];
  XCTAssertEqual(recorder.cancellations, 1u);
  UIAlertController* alert = [app valueForKey:@"alertView"];
  XCTAssertEqualObjects(alert.title, @"Cancellation follow-up");
  [app dismissAlert:NO];
  XCTAssertFalse(app.isAlertVisible);
}
- (void)testAnimatedDismissalDoesNotCancelReplacementAlert {
  AppDelegate* app = [AppDelegate sharedDelegate];
  AlertRecorder* recorder = [AlertRecorder new];
  [app showAlertWithTitle:@"Old alert" message:nil button:@"OK"];
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
  [app dismissAlert:YES];
  [app showAlertWithTitle:@"Replacement" message:nil confirmButton:@"OK" cancelButton:@"Cancel" delegate:recorder confirmSelector:@selector(confirm:) cancelSelector:@selector(cancel:) argument:nil];
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
  XCTAssertTrue(app.isAlertVisible);
  XCTAssertEqual(recorder.cancellations, 0u);
}
- (void)testOldSpinnerAnimationDoesNotHideNewSpinner {
  AppDelegate* app = [AppDelegate sharedDelegate];
  [app showSpinnerWithMessage:@"First" fullScreen:NO animated:NO];
  [app hideSpinner:YES];
  [app showSpinnerWithMessage:@"Second" fullScreen:NO animated:NO];
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.7]];
  XCTAssertTrue(app.isSpinnerVisible);
  UIWindow* overlay = [app valueForKey:@"overlayWindow"];
  XCTAssertFalse(overlay.hidden);
  [app hideSpinner:NO];
}
@end
