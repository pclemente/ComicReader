#import <XCTest/XCTest.h>
#import <QuartzCore/QuartzCore.h>

#import "CRAdaptiveViewport.h"
#import "ComicViewController.h"
#import "DocumentView.h"
#import "ImageDecompression.h"
#import "MiniZip.h"
#import "UnRAR.h"
#import "ZoomView.h"

@interface ReaderRegressionTests : XCTestCase
@end

@interface ZoomView (ReaderRegressionTesting)
- (void) displayImage:(UIImage*)image;
@end

@interface ComicViewController (ReaderRegressionTesting)
- (void) _tapAction:(UITapGestureRecognizer*)recognizer;
@end

@interface ReaderTapGestureRecognizer : UITapGestureRecognizer
@property(nonatomic, strong) UIView* readerView;
@property(nonatomic) CGPoint readerLocation;
@end

@implementation ReaderTapGestureRecognizer

- (UIGestureRecognizerState) state {
  return UIGestureRecognizerStateEnded;
}

- (UIView*) view {
  return self.readerView;
}

- (CGPoint) locationInView:(UIView*)view {
  return self.readerLocation;
}

@end

@implementation ReaderRegressionTests

- (NSData*) dataFromBase64:(NSString*)base64 {
  return [[NSData alloc] initWithBase64EncodedString:base64 options:0];
}

- (NSString*) temporaryPath:(NSString*)name {
  NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:NULL]);
  return [directory stringByAppendingPathComponent:name];
}

- (void) testNativeImageIODecodesWebP {
  NSData* data = [self dataFromBase64:@"UklGRh4AAABXRUJQVlA4TBEAAAAvAYAAAAdQkUZ0pv+BiOh/AAA="];
  CGImageRef image = CreateCGImageFromFileData(data, @"WEBP", CGSizeMake(100.0, 100.0), NO);
  XCTAssertNotEqual(image, NULL);
  if (image) {
    XCTAssertEqual(CGImageGetWidth(image), (size_t)2);
    XCTAssertEqual(CGImageGetHeight(image), (size_t)3);
    CGImageRelease(image);
  }
}

- (void) testSupportedComicImageExtensionsAreCaseInsensitive {
  XCTAssertTrue(IsImageFileExtensionSupported(@"JPG"));
  XCTAssertTrue(IsImageFileExtensionSupported(@"jpeg"));
  XCTAssertTrue(IsImageFileExtensionSupported(@"Png"));
  XCTAssertTrue(IsImageFileExtensionSupported(@"GIF"));
  XCTAssertTrue(IsImageFileExtensionSupported(@"WebP"));
  XCTAssertFalse(IsImageFileExtensionSupported(@"txt"));
}

- (void) testComicReaderKeepsTheStatusBarHidden {
  ComicViewController* viewController = [[ComicViewController alloc] initWithNibName:nil bundle:nil];
  XCTAssertTrue([viewController prefersStatusBarHidden]);
}

- (void) testReaderContentBoundsPreserveAsymmetricSafeAreas {
  CGRect bounds = CGRectMake(0.0, 0.0, 800.0, 500.0);
  CGRect contentBounds = CRReaderContentBounds(bounds, UIEdgeInsetsMake(10.0, 120.0, 20.0, 40.0));
  XCTAssertTrue(CGRectEqualToRect(contentBounds, CGRectMake(120.0, 10.0, 640.0, 470.0)));

  CGRect constrainedBounds = CRReaderContentBounds(CGRectMake(0.0, 0.0, 100.0, 100.0),
                                                    UIEdgeInsetsMake(0.0, 80.0, 0.0, 50.0));
  XCTAssertEqual(CGRectGetMinX(constrainedBounds), 80.0);
  XCTAssertEqual(CGRectGetWidth(constrainedBounds), 0.0);
}

- (void) testAdaptiveViewportUsesAllSafeAreaWithoutActiveRegions {
  CGRect viewport = CRAdaptiveViewportBounds(CGRectMake(20.0, 30.0, 800.0, 600.0),
                                             UIEdgeInsetsMake(10.0, 30.0, 20.0, 40.0),
                                             @[], @[], UIUserInterfaceLayoutDirectionLeftToRight);
  XCTAssertTrue(CGRectEqualToRect(viewport, CGRectMake(50.0, 40.0, 730.0, 570.0)));
}

- (void) testAdaptiveViewportSelectsTopPaneAndAvoidsAnOcclusion {
  CGRect bounds = CGRectMake(0.0, 0.0, 800.0, 1000.0);
  UIEdgeInsets safeArea = UIEdgeInsetsMake(20.0, 10.0, 30.0, 10.0);
  NSArray<NSValue*>* divisions = @[[NSValue valueWithCGRect:CGRectMake(0.0, 480.0, 800.0, 40.0)]];

  CGRect topPane = CRAdaptiveViewportBounds(bounds, safeArea, divisions, @[],
                                            UIUserInterfaceLayoutDirectionLeftToRight);
  XCTAssertTrue(CGRectEqualToRect(topPane, CGRectMake(10.0, 20.0, 780.0, 460.0)));

  // The region frame already contains UIKit's interaction margin. Keeping the
  // page below it yields more usable area than placing it to either side.
  NSArray<NSValue*>* occlusions = @[[NSValue valueWithCGRect:CGRectMake(300.0, 20.0, 200.0, 80.0)]];
  CGRect clearTopPane = CRAdaptiveViewportBounds(bounds, safeArea, divisions, occlusions,
                                                 UIUserInterfaceLayoutDirectionLeftToRight);
  XCTAssertTrue(CGRectEqualToRect(clearTopPane, CGRectMake(10.0, 100.0, 780.0, 380.0)));
}

- (void) testAdaptiveViewportSelectsLeadingPaneForVerticalDivision {
  NSArray<NSValue*>* divisions = @[[NSValue valueWithCGRect:CGRectMake(490.0, 0.0, 20.0, 600.0)]];
  CGRect leftToRight = CRAdaptiveViewportBounds(CGRectMake(0.0, 0.0, 1000.0, 600.0),
                                                UIEdgeInsetsZero, divisions, @[],
                                                UIUserInterfaceLayoutDirectionLeftToRight);
  CGRect rightToLeft = CRAdaptiveViewportBounds(CGRectMake(0.0, 0.0, 1000.0, 600.0),
                                                UIEdgeInsetsZero, divisions, @[],
                                                UIUserInterfaceLayoutDirectionRightToLeft);
  XCTAssertTrue(CGRectEqualToRect(leftToRight, CGRectMake(0.0, 0.0, 490.0, 600.0)));
  XCTAssertTrue(CGRectEqualToRect(rightToLeft, CGRectMake(510.0, 0.0, 490.0, 600.0)));
}

- (void) testAdaptiveViewportUsesLargestRectangleBesideAnOcclusion {
  CGRect viewport = CRAdaptiveViewportBounds(CGRectMake(0.0, 0.0, 800.0, 600.0),
                                             UIEdgeInsetsZero,
                                             @[],
                                             @[[NSValue valueWithCGRect:CGRectMake(0.0, 0.0, 120.0, 120.0)]],
                                             UIUserInterfaceLayoutDirectionLeftToRight);
  XCTAssertTrue(CGRectEqualToRect(viewport, CGRectMake(120.0, 0.0, 680.0, 600.0)));
}

- (void) testReaderCanvasClipsAdjacentPagesOutsideTheActivePane {
  ComicViewController* controller = [[ComicViewController alloc] initWithNibName:@"ComicViewController" bundle:nil];
  UIWindow* window = [[UIWindow alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 240.0)];
  window.rootViewController = controller;
  [controller loadViewIfNeeded];
  // The test window stays hidden; UIKit attaches its root automatically only
  // when presented. Attach explicitly without replacing the app's key window.
  [window addSubview:controller.view];
  [controller.view layoutIfNeeded];
  XCTAssertEqual(controller.view.window, window);

  // Model the reader's leading pane after a vertical Duo division. DocumentView
  // keeps adjacent pages in one wide internal strip, so the second page really
  // does extend into the reserved half of the hosted root view.
  UIView* canvas = controller.contentView;
  canvas.frame = CGRectMake(0.0, 0.0, 140.0, 240.0);
  DocumentView* documentView = [controller valueForKey:@"documentView"];
  documentView.delegate = nil;
  documentView.frame = canvas.bounds;
  UIView* currentPage = [[UIView alloc] init];
  UIView* adjacentPage = [[UIView alloc] init];
  [documentView setPageViews:@[currentPage, adjacentPage] initialPageIndex:0];
  [documentView layoutIfNeeded];

  CGRect adjacentPageInRoot = [adjacentPage convertRect:adjacentPage.bounds toView:controller.view];
  XCTAssertEqualWithAccuracy(CGRectGetMinX(adjacentPageInRoot), CGRectGetMaxX(canvas.frame), 0.001);
  XCTAssertGreaterThan(CGRectGetMaxX(adjacentPageInRoot), CGRectGetMaxX(canvas.frame));
  XCTAssertTrue(CGRectContainsRect(controller.view.bounds, adjacentPageInRoot));
  XCTAssertTrue(canvas.clipsToBounds,
                @"The active reader pane must mask DocumentView's adjacent pages");
}

- (void) testComicReaderTapZonesUseTheVisibleScrolledViewport {
  ComicViewController* controller = [[ComicViewController alloc] initWithNibName:@"ComicViewController" bundle:nil];
  [controller loadViewIfNeeded];
  DocumentView* documentView = [controller valueForKey:@"documentView"];
  XCTAssertNotNil(documentView);
  documentView.delegate = nil;
  NSArray* pages = @[[[UIView alloc] init], [[UIView alloc] init], [[UIView alloc] init]];
  [documentView setPageViews:pages initialPageIndex:1];

  UIView* readerView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 300.0, 400.0)];
  ReaderTapGestureRecognizer* recognizer = [[ReaderTapGestureRecognizer alloc] initWithTarget:nil action:NULL];
  recognizer.readerView = readerView;

  // A visual center tap remains center with a negative scroll origin.
  readerView.bounds = CGRectMake(-100.0, 0.0, 300.0, 400.0);
  recognizer.readerLocation = CGPointMake(50.0, 200.0);
  controller.navigationBar.hidden = YES;
  [controller _tapAction:recognizer];
  XCTAssertFalse(controller.navigationBar.hidden);
  XCTAssertEqual(documentView.selectedPageIndex, (NSUInteger)1);

  // The same visual center remains center with a positive scroll origin.
  readerView.bounds = CGRectMake(100.0, 0.0, 300.0, 400.0);
  recognizer.readerLocation = CGPointMake(250.0, 200.0);
  controller.navigationBar.hidden = YES;
  [controller _tapAction:recognizer];
  XCTAssertFalse(controller.navigationBar.hidden);
  XCTAssertEqual(documentView.selectedPageIndex, (NSUInteger)1);

  // Visible left and right zones still navigate relative to each viewport.
  readerView.bounds = CGRectMake(-100.0, 0.0, 300.0, 400.0);
  recognizer.readerLocation = CGPointMake(-70.0, 200.0);
  [controller _tapAction:recognizer];
  XCTAssertEqual(documentView.selectedPageIndex, (NSUInteger)0);

  documentView.selectedPageIndex = 1;
  readerView.bounds = CGRectMake(100.0, 0.0, 300.0, 400.0);
  recognizer.readerLocation = CGPointMake(370.0, 200.0);
  [controller _tapAction:recognizer];
  XCTAssertEqual(documentView.selectedPageIndex, (NSUInteger)2);
}

- (CGPoint) sourceFocusForZoomView:(ZoomView*)zoomView {
  return CGPointMake((zoomView.contentOffset.x + CGRectGetWidth(zoomView.bounds) / 2.0) / zoomView.zoomScale,
                     (zoomView.contentOffset.y + CGRectGetHeight(zoomView.bounds) / 2.0) / zoomView.zoomScale);
}

- (UIImage*) imageWithSize:(CGSize)size color:(UIColor*)color {
  UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat defaultFormat];
  format.scale = 1.0;
  UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
    [color setFill];
    [context fillRect:(CGRect){CGPointZero, size}];
  }];
}

- (void) testComicPageImageRefreshPreservesZoomAndFocus {
  Class pageViewClass = NSClassFromString(@"ComicPageView");
  XCTAssertNotNil(pageViewClass);
  ZoomView* pageView = [[pageViewClass alloc] initWithFrame:CGRectMake(0.0, 0.0, 300.0, 400.0)];
  pageView.displayMode = kZoomViewDisplayMode_Fit;
  [(id)pageView displayImage:[self imageWithSize:CGSizeMake(100.0, 120.0) color:[UIColor redColor]]];
  [pageView layoutIfNeeded];
  pageView.zoomScale = pageView.minimumZoomScale * 1.5;
  pageView.contentOffset = CGPointMake(75.0, 70.0);

  UIView* displayView = pageView.displayView;
  CGFloat relativeZoom = pageView.zoomScale / pageView.minimumZoomScale;
  CGPoint focus = [self sourceFocusForZoomView:pageView];
  [(id)pageView displayImage:[self imageWithSize:CGSizeMake(200.0, 240.0) color:[UIColor blueColor]]];
  [pageView layoutIfNeeded];

  XCTAssertEqual(pageView.displayView, displayView);
  XCTAssertEqualWithAccuracy(pageView.zoomScale / pageView.minimumZoomScale, relativeZoom, 0.001);
  XCTAssertEqualWithAccuracy([self sourceFocusForZoomView:pageView].x, focus.x, 0.001);
  XCTAssertEqualWithAccuracy([self sourceFocusForZoomView:pageView].y, focus.y, 0.001);
}

- (void) testZoomViewPreservesZoomAndFocalPositionAcrossResize {
  ZoomView* zoomView = [[ZoomView alloc] initWithFrame:CGRectMake(0.0, 0.0, 300.0, 400.0)];
  zoomView.displayMode = kZoomViewDisplayMode_Fit;
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1000.0, 1200.0)];
  [zoomView layoutIfNeeded];

  zoomView.zoomScale = zoomView.minimumZoomScale * 1.9;
  // This reachable off-center point simulates a pan immediately before the
  // resize. Deliberately do not lay out between setting the offset and frame.
  zoomView.contentOffset = CGPointMake(169.0, 199.0);
  CGPoint focusBeforeResize = [self sourceFocusForZoomView:zoomView];
  CGFloat relativeZoomBeforeResize = zoomView.zoomScale / zoomView.minimumZoomScale;
  XCTAssertGreaterThan(fabs(focusBeforeResize.x - 500.0), 40.0);
  XCTAssertGreaterThan(fabs(focusBeforeResize.y - 600.0), 40.0);

  NSArray<NSValue*>* viewportSizes = @[[NSValue valueWithCGSize:CGSizeMake(700.0, 600.0)],
                                       [NSValue valueWithCGSize:CGSizeMake(400.0, 300.0)],
                                       [NSValue valueWithCGSize:CGSizeMake(300.0, 400.0)]];
  NSUInteger viewportIndex = 0;
  for (NSValue* viewportSize in viewportSizes) {
    if (viewportIndex == 1) {
      // Exercise a direct bounds resize as well as the frame-driven path used
      // by DocumentView, while retaining UIScrollView's current bounds origin.
      zoomView.bounds = (CGRect){zoomView.bounds.origin, viewportSize.CGSizeValue};
    } else {
      zoomView.frame = (CGRect){CGPointZero, viewportSize.CGSizeValue};
    }
    [zoomView layoutIfNeeded];
    CGPoint focusAfterResize = [self sourceFocusForZoomView:zoomView];

    XCTAssertEqualWithAccuracy(zoomView.zoomScale / zoomView.minimumZoomScale, relativeZoomBeforeResize, 0.001);
    // UIScrollView quantizes its offset to display pixels, so compare the
    // projected physical error instead of imposing a subpixel source bound.
    CGFloat displayScale = MAX(zoomView.traitCollection.displayScale, 1.0);
    CGFloat horizontalErrorInPixels = fabs(focusAfterResize.x - focusBeforeResize.x) * zoomView.zoomScale * displayScale;
    CGFloat verticalErrorInPixels = fabs(focusAfterResize.y - focusBeforeResize.y) * zoomView.zoomScale * displayScale;
    XCTAssertLessThanOrEqual(horizontalErrorInPixels, 1.001);
    XCTAssertLessThanOrEqual(verticalErrorInPixels, 1.001);
    viewportIndex += 1;
  }
}

- (void) testZoomViewClampsAnEdgeFocusToValidOffsetsAfterResize {
  ZoomView* zoomView = [[ZoomView alloc] initWithFrame:CGRectMake(0.0, 0.0, 300.0, 400.0)];
  zoomView.displayMode = kZoomViewDisplayMode_Fit;
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1000.0, 1200.0)];
  [zoomView layoutIfNeeded];
  zoomView.zoomScale = 0.55;
  zoomView.contentOffset = CGPointMake(250.0, 260.0);

  zoomView.frame = CGRectMake(0.0, 0.0, 400.0, 300.0);
  [zoomView layoutIfNeeded];

  CGFloat minimumX = -zoomView.contentInset.left;
  CGFloat minimumY = -zoomView.contentInset.top;
  CGFloat maximumX = MAX(minimumX, zoomView.contentSize.width - CGRectGetWidth(zoomView.bounds) + zoomView.contentInset.right);
  CGFloat maximumY = MAX(minimumY, zoomView.contentSize.height - CGRectGetHeight(zoomView.bounds) + zoomView.contentInset.bottom);
  XCTAssertGreaterThanOrEqual(zoomView.contentOffset.x, minimumX - 0.001);
  XCTAssertLessThanOrEqual(zoomView.contentOffset.x, maximumX + 0.001);
  XCTAssertGreaterThanOrEqual(zoomView.contentOffset.y, minimumY - 0.001);
  XCTAssertLessThanOrEqual(zoomView.contentOffset.y, maximumY + 0.001);
}

- (void) testZoomViewRestoresUserFocusAfterSettledClampAndReopen {
  CGSize openSize = CGSizeMake(710.0, 995.0);
  CGSize closedSize = CGSizeMake(630.0, 445.0);
  ZoomView* zoomView = [[ZoomView alloc] initWithFrame:(CGRect){CGPointZero, openSize}];
  zoomView.displayMode = kZoomViewDisplayMode_Fit;
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1000.0, 1600.0)];
  [zoomView layoutIfNeeded];

  zoomView.zoomScale = zoomView.minimumZoomScale * 2.0;
  CGPoint requestedFocus = CGPointMake(680.0, 1120.0);
  zoomView.contentOffset = CGPointMake(requestedFocus.x * zoomView.zoomScale - openSize.width / 2.0,
                                       requestedFocus.y * zoomView.zoomScale - openSize.height / 2.0);
  CGPoint selectedFocus = [self sourceFocusForZoomView:zoomView];
  CGFloat relativeZoom = zoomView.zoomScale / zoomView.minimumZoomScale;

  zoomView.frame = (CGRect){CGPointZero, closedSize};
  [zoomView layoutIfNeeded];
  CGPoint clampedFocus = [self sourceFocusForZoomView:zoomView];
  XCTAssertGreaterThan(fabs(clampedFocus.x - selectedFocus.x), 100.0,
                       @"The closed viewport must actually clamp the horizontal focus");

  // Let the clamped geometry settle through another ordinary layout before
  // reopening. That layout must not replace the user's source-space intent.
  [zoomView setNeedsLayout];
  [zoomView layoutIfNeeded];
  zoomView.frame = (CGRect){CGPointZero, openSize};
  [zoomView layoutIfNeeded];

  CGPoint reopenedFocus = [self sourceFocusForZoomView:zoomView];
  CGFloat displayScale = MAX(zoomView.traitCollection.displayScale, 1.0);
  XCTAssertEqualWithAccuracy(zoomView.zoomScale / zoomView.minimumZoomScale, relativeZoom, 0.001);
  XCTAssertLessThanOrEqual(fabs(reopenedFocus.x - selectedFocus.x) * zoomView.zoomScale * displayScale, 1.001);
  XCTAssertLessThanOrEqual(fabs(reopenedFocus.y - selectedFocus.y) * zoomView.zoomScale * displayScale, 1.001);
}

- (void) testZoomViewRestoresIdealZoomAfterTransientMaximumClamp {
  CGSize openSize = CGSizeMake(710.0, 974.0);
  CGSize foldedSize = CGSizeMake(445.0, 445.0);
  ZoomView* zoomView = [[ZoomView alloc] initWithFrame:(CGRect){CGPointZero, openSize}];
  zoomView.displayMode = kZoomViewDisplayMode_Fit;
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 700.0, 930.0)];
  [zoomView layoutIfNeeded];

  // Double-tap zoom requests the current maximum. The folded viewport has a
  // lower maximum relative to its fitted scale, so it must clamp temporarily
  // without replacing the user's requested magnification.
  [zoomView zoomToRect:CGRectMake(349.0, 464.0, 2.0, 2.0) animated:NO];
  CGFloat idealRelativeZoom = zoomView.zoomScale / zoomView.minimumZoomScale;
  CGFloat openZoomScale = zoomView.zoomScale;

  zoomView.frame = (CGRect){CGPointZero, foldedSize};
  [zoomView layoutIfNeeded];
  XCTAssertEqualWithAccuracy(zoomView.zoomScale, zoomView.maximumZoomScale, 0.001);
  XCTAssertLessThan(zoomView.zoomScale / zoomView.minimumZoomScale, idealRelativeZoom - 0.01);

  // Exercise the settled-clamp path seen between the close and reopen events.
  [zoomView setNeedsLayout];
  [zoomView layoutIfNeeded];
  zoomView.frame = (CGRect){CGPointZero, openSize};
  [zoomView layoutIfNeeded];

  XCTAssertEqualWithAccuracy(zoomView.zoomScale / zoomView.minimumZoomScale, idealRelativeZoom, 0.001);
  XCTAssertEqualWithAccuracy(zoomView.zoomScale, openZoomScale, 0.001);
}

- (void) testLateZoomDelegateAfterFoldDoesNotReplaceDoubleTapIntent {
  CGSize openSize = CGSizeMake(710.0, 974.0);
  CGSize foldedSize = CGSizeMake(445.0, 445.0);
  ZoomView* zoomView = [[ZoomView alloc] initWithFrame:(CGRect){CGPointZero, openSize}];
  zoomView.displayMode = kZoomViewDisplayMode_Fit;
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 700.0, 930.0)];
  [zoomView layoutIfNeeded];

  [zoomView zoomToRect:CGRectMake(349.0, 464.0, 2.0, 2.0) animated:NO];
  CGFloat idealRelativeZoom = zoomView.zoomScale / zoomView.minimumZoomScale;
  CGFloat openZoomScale = zoomView.zoomScale;

  // Model UIKit's zoom delegate epoch without depending on animation timing.
  // A posture resize then clamps the actual scale before the old epoch ends.
  id<UIScrollViewDelegate> delegate = (id<UIScrollViewDelegate>)zoomView;
  [delegate scrollViewWillBeginZooming:zoomView withView:zoomView.displayView];
  zoomView.frame = (CGRect){CGPointZero, foldedSize};
  [zoomView layoutIfNeeded];
  CGFloat foldedScale = zoomView.zoomScale;
  XCTAssertLessThan(foldedScale / zoomView.minimumZoomScale, idealRelativeZoom - 0.01);

  // This delayed callback belongs to the invalidated pre-fold epoch and must
  // not promote the folded clamp to the user's new zoom intent.
  [delegate scrollViewDidEndZooming:zoomView withView:zoomView.displayView atScale:foldedScale];
  zoomView.frame = (CGRect){CGPointZero, openSize};
  [zoomView layoutIfNeeded];

  XCTAssertEqualWithAccuracy(zoomView.zoomScale / zoomView.minimumZoomScale, idealRelativeZoom, 0.001);
  XCTAssertEqualWithAccuracy(zoomView.zoomScale, openZoomScale, 0.001);
}

- (void) testZoomViewUsesUserPanAfterSettledClampAsNewFocus {
  CGSize openSize = CGSizeMake(710.0, 995.0);
  CGSize closedSize = CGSizeMake(630.0, 445.0);
  ZoomView* zoomView = [[ZoomView alloc] initWithFrame:(CGRect){CGPointZero, openSize}];
  zoomView.displayMode = kZoomViewDisplayMode_Fit;
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1000.0, 1600.0)];
  [zoomView layoutIfNeeded];

  zoomView.zoomScale = zoomView.minimumZoomScale * 2.0;
  CGPoint originalFocus = CGPointMake(680.0, 1120.0);
  zoomView.contentOffset = CGPointMake(originalFocus.x * zoomView.zoomScale - openSize.width / 2.0,
                                       originalFocus.y * zoomView.zoomScale - openSize.height / 2.0);
  zoomView.frame = (CGRect){CGPointZero, closedSize};
  [zoomView layoutIfNeeded];

  // UIScrollView performs a drag by moving its bounds and then notifying its
  // delegate. Simulate that path directly so this exercises user-pan capture,
  // rather than the public programmatic contentOffset setter used above.
  CGFloat pannedSourceY = 650.0;
  CGRect pannedBounds = zoomView.bounds;
  pannedBounds.origin.y = pannedSourceY * zoomView.zoomScale - closedSize.height / 2.0;
  zoomView.bounds = pannedBounds;
  [(id<UIScrollViewDelegate>)zoomView scrollViewDidEndDragging:zoomView willDecelerate:NO];
  CGPoint pannedFocus = [self sourceFocusForZoomView:zoomView];
  CGFloat closedDisplayScale = MAX(zoomView.traitCollection.displayScale, 1.0);
  XCTAssertLessThanOrEqual(fabs(pannedFocus.y - pannedSourceY) * zoomView.zoomScale * closedDisplayScale, 1.001);
  XCTAssertGreaterThan(fabs(pannedFocus.x - originalFocus.x), 100.0,
                       @"Panning after the clamp must supersede the earlier focus on both axes");

  [zoomView setNeedsLayout];
  [zoomView layoutIfNeeded];
  zoomView.frame = (CGRect){CGPointZero, openSize};
  [zoomView layoutIfNeeded];

  CGPoint reopenedFocus = [self sourceFocusForZoomView:zoomView];
  CGFloat displayScale = MAX(zoomView.traitCollection.displayScale, 1.0);
  XCTAssertLessThanOrEqual(fabs(reopenedFocus.x - pannedFocus.x) * zoomView.zoomScale * displayScale, 1.001);
  XCTAssertLessThanOrEqual(fabs(reopenedFocus.y - pannedFocus.y) * zoomView.zoomScale * displayScale, 1.001);
}

- (void) testZoomViewDoesNotRestoreFocusFromReplacedPage {
  CGSize openSize = CGSizeMake(710.0, 995.0);
  ZoomView* zoomView = [[ZoomView alloc] initWithFrame:(CGRect){CGPointZero, openSize}];
  zoomView.displayMode = kZoomViewDisplayMode_Fit;
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1000.0, 1600.0)];
  [zoomView layoutIfNeeded];
  zoomView.zoomScale = zoomView.minimumZoomScale * 2.0;
  zoomView.contentOffset = CGPointMake(490.0, 895.0);

  // Begin a geometry change, then replace the page before its pending layout.
  // The replacement has a different source coordinate space and must start at
  // its own center rather than consuming the old page's retained focus.
  zoomView.frame = CGRectMake(0.0, 0.0, 630.0, 445.0);
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 800.0, 1200.0)];
  [zoomView layoutIfNeeded];
  zoomView.frame = (CGRect){CGPointZero, openSize};
  [zoomView layoutIfNeeded];

  CGPoint focus = [self sourceFocusForZoomView:zoomView];
  XCTAssertEqualWithAccuracy(zoomView.zoomScale, zoomView.minimumZoomScale, 0.001);
  XCTAssertEqualWithAccuracy(focus.x, 400.0, 1.0);
  XCTAssertEqualWithAccuracy(focus.y, 600.0, 1.0);
}

- (void) testZoomViewRestoresFocusAfterCoalescedExpandAndCollapse {
  ZoomView* zoomView = [[ZoomView alloc] initWithFrame:CGRectMake(0.0, 0.0, 300.0, 400.0)];
  zoomView.displayMode = kZoomViewDisplayMode_Fit;
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1000.0, 1200.0)];
  [zoomView layoutIfNeeded];
  zoomView.zoomScale = zoomView.minimumZoomScale * 1.9;
  zoomView.contentOffset = CGPointMake(169.0, 199.0);
  CGPoint focusBeforeResize = [self sourceFocusForZoomView:zoomView];
  CGFloat relativeZoom = zoomView.zoomScale / zoomView.minimumZoomScale;

  // Both mutations are coalesced into one layout and finish at _oldSize.
  zoomView.frame = CGRectMake(0.0, 0.0, 700.0, 600.0);
  zoomView.frame = CGRectMake(0.0, 0.0, 300.0, 400.0);
  [zoomView layoutIfNeeded];

  CGPoint focusAfterResize = [self sourceFocusForZoomView:zoomView];
  XCTAssertEqualWithAccuracy(zoomView.zoomScale / zoomView.minimumZoomScale, relativeZoom, 0.001);
  XCTAssertEqualWithAccuracy(focusAfterResize.x, focusBeforeResize.x, 0.05);
  XCTAssertEqualWithAccuracy(focusAfterResize.y, focusBeforeResize.y, 0.05);
}

- (void) testZoomViewKeepsFittedPageCenteredAcrossResize {
  ZoomView* zoomView = [[ZoomView alloc] initWithFrame:CGRectMake(0.0, 0.0, 300.0, 400.0)];
  zoomView.displayMode = kZoomViewDisplayMode_Fit;
  zoomView.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1000.0, 1200.0)];
  [zoomView layoutIfNeeded];

  zoomView.frame = CGRectMake(0.0, 0.0, 500.0, 300.0);
  [zoomView layoutIfNeeded];
  CGPoint focus = [self sourceFocusForZoomView:zoomView];

  XCTAssertEqualWithAccuracy(zoomView.zoomScale, zoomView.minimumZoomScale, 0.001);
  XCTAssertLessThanOrEqual(zoomView.contentSize.width, CGRectGetWidth(zoomView.bounds) + 0.001);
  XCTAssertLessThanOrEqual(zoomView.contentSize.height, CGRectGetHeight(zoomView.bounds) + 0.001);
  XCTAssertEqualWithAccuracy(focus.x, 500.0, 1.0);
  XCTAssertEqualWithAccuracy(focus.y, 600.0, 1.0);
}

- (void) testDocumentViewPreservesSelectedPageAcrossResize {
  DocumentView* documentView = [[DocumentView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 480.0)];
  NSArray* pages = @[[[UIView alloc] init], [[UIView alloc] init], [[UIView alloc] init]];
  [documentView setPageViews:pages initialPageIndex:1];

  documentView.frame = CGRectMake(0.0, 0.0, 700.0, 300.0);
  [documentView layoutIfNeeded];

  XCTAssertEqual(documentView.selectedPageIndex, (NSUInteger)1);
  XCTAssertEqual(documentView.selectedPageView, pages[1]);
  XCTAssertTrue(CGSizeEqualToSize(documentView.selectedPageView.bounds.size, CGSizeMake(700.0, 300.0)));
}

- (void) testFoldedViewportPreservesSelectedPageZoomAndFocus {
  CGRect openViewport = CRAdaptiveViewportBounds(CGRectMake(0.0, 0.0, 800.0, 1000.0),
                                                 UIEdgeInsetsMake(20.0, 10.0, 30.0, 10.0),
                                                 @[], @[], UIUserInterfaceLayoutDirectionLeftToRight);
  NSArray<NSValue*>* divisions = @[[NSValue valueWithCGRect:CGRectMake(0.0, 480.0, 800.0, 40.0)]];
  CGRect foldedViewport = CRAdaptiveViewportBounds(CGRectMake(0.0, 0.0, 800.0, 1000.0),
                                                   UIEdgeInsetsMake(20.0, 10.0, 30.0, 10.0),
                                                   divisions, @[], UIUserInterfaceLayoutDirectionLeftToRight);

  DocumentView* documentView = [[DocumentView alloc] initWithFrame:(CGRect){CGPointZero, openViewport.size}];
  NSMutableArray<ZoomView*>* pages = [NSMutableArray array];
  for (NSUInteger index = 0; index < 3; index += 1) {
    ZoomView* page = [[ZoomView alloc] initWithFrame:documentView.bounds];
    page.displayMode = kZoomViewDisplayMode_Fit;
    page.displayView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1000.0, 1600.0)];
    [pages addObject:page];
  }
  [documentView setPageViews:pages initialPageIndex:1];
  [documentView layoutIfNeeded];

  ZoomView* selectedPage = (ZoomView*)documentView.selectedPageView;
  [selectedPage layoutIfNeeded];
  selectedPage.zoomScale = selectedPage.minimumZoomScale * 2.0;
  CGPoint requestedFocus = CGPointMake(500.0, 700.0);
  selectedPage.contentOffset = CGPointMake(requestedFocus.x * selectedPage.zoomScale - CGRectGetWidth(selectedPage.bounds) / 2.0,
                                           requestedFocus.y * selectedPage.zoomScale - CGRectGetHeight(selectedPage.bounds) / 2.0);
  // UIScrollView can quantize the requested offset to the display's pixel grid
  // immediately. Resize continuity starts from the focus the reader actually
  // displays, rather than the fractional offset requested above.
  CGPoint expectedFocus = [self sourceFocusForZoomView:selectedPage];
  CGFloat relativeZoom = selectedPage.zoomScale / selectedPage.minimumZoomScale;

  NSArray<NSValue*>* viewportValues = @[[NSValue valueWithCGRect:foldedViewport],
                                        [NSValue valueWithCGRect:openViewport]];
  for (NSValue* viewportValue in viewportValues) {
    documentView.frame = (CGRect){CGPointZero, viewportValue.CGRectValue.size};
    [documentView layoutIfNeeded];
    [selectedPage layoutIfNeeded];

    XCTAssertEqual(documentView.selectedPageIndex, (NSUInteger)1);
    XCTAssertEqual(documentView.selectedPageView, selectedPage);
    XCTAssertEqualWithAccuracy(selectedPage.zoomScale / selectedPage.minimumZoomScale, relativeZoom, 0.001);
    CGPoint focus = [self sourceFocusForZoomView:selectedPage];
    CGFloat displayScale = MAX(selectedPage.traitCollection.displayScale, 1.0);
    XCTAssertLessThanOrEqual(fabs(focus.x - expectedFocus.x) * selectedPage.zoomScale * displayScale, 1.001);
    XCTAssertLessThanOrEqual(fabs(focus.y - expectedFocus.y) * selectedPage.zoomScale * displayScale, 1.001);
  }
}

- (void) testDocumentViewCancelsAStalePageAnimationWhenResized {
  DocumentView* documentView = [[DocumentView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 480.0)];
  NSArray* pages = @[[[UIView alloc] init], [[UIView alloc] init], [[UIView alloc] init]];
  [documentView setPageViews:pages initialPageIndex:1];
  documentView.animationDuration = 10.0;
  UIView* pagingContentView = documentView.subviews.firstObject;

  [documentView goToNextPage:YES];
  XCTAssertNotNil([pagingContentView.layer animationForKey:@"position"]);

  documentView.frame = CGRectMake(0.0, 0.0, 700.0, 300.0);
  [documentView layoutIfNeeded];

  XCTAssertNil([pagingContentView.layer animationForKey:@"position"]);
  XCTAssertEqual(documentView.selectedPageIndex, (NSUInteger)2);
  XCTAssertEqualWithAccuracy(CGRectGetMinX(pagingContentView.frame), -1400.0, 0.001);
}

- (void) testMiniZipListsAndExtractsAnEntryFromData {
  NSData* data = [self dataFromBase64:@"UEsDBBQAAAAAAIMYIlBR2j+NCgAAAAoAAAAIAAAAcGFnZS5qcGdjb21pYy1wYWdlUEsDBBQAAAAAAIMYIlAUNBRPCAAAAAgAAAATAAAAX19NQUNPU1gvLl9wYWdlLmpwZ21ldGFkYXRhUEsBAhQDFAAAAAAAgxgiUFHaP40KAAAACgAAAAgAAAAAAAAAAAAAAIABAAAAAHBhZ2UuanBnUEsBAhQDFAAAAAAAgxgiUBQ0FE8IAAAACAAAABMAAAAAAAAAAAAAAIABMAAAAF9fTUFDT1NYLy5fcGFnZS5qcGdQSwUGAAAAAAIAAgB3AAAAaQAAAAAA"];
  MiniZip* archive = [[MiniZip alloc] initWithArchiveData:data];
  XCTAssertNotNil(archive);
  archive.skipInvisibleFiles = YES;
  XCTAssertEqualObjects([archive retrieveFileList], (@[@"page.jpg"]));

  NSString* outputPath = [self temporaryPath:@"page.jpg"];
  XCTAssertTrue([archive extractFile:@"page.jpg" toPath:outputPath]);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:outputPath], [@"comic-page" dataUsingEncoding:NSUTF8StringEncoding]);
  [[NSFileManager defaultManager] removeItemAtPath:[outputPath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testMiniZipRejectsAnEntryWithACRCMismatch {
  NSData* data = [self dataFromBase64:@"UEsDBBQAAAAAAIMYIlBR2j+NCgAAAAoAAAAIAAAAcGFnZS5qcGdib21pYy1wYWdlUEsDBBQAAAAAAIMYIlAUNBRPCAAAAAgAAAATAAAAX19NQUNPU1gvLl9wYWdlLmpwZ21ldGFkYXRhUEsBAhQDFAAAAAAAgxgiUFHaP40KAAAACgAAAAgAAAAAAAAAAAAAAIABAAAAAHBhZ2UuanBnUEsBAhQDFAAAAAAAgxgiUBQ0FE8IAAAACAAAABMAAAAAAAAAAAAAAIABMAAAAF9fTUFDT1NYLy5fcGFnZS5qcGdQSwUGAAAAAAIAAgB3AAAAaQAAAAAA"];
  MiniZip* archive = [[MiniZip alloc] initWithArchiveData:data];
  XCTAssertNotNil(archive);

  NSString* outputPath = [self temporaryPath:@"page.jpg"];
  XCTAssertFalse([archive extractFile:@"page.jpg" toPath:outputPath]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outputPath]);
  [[NSFileManager defaultManager] removeItemAtPath:[outputPath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testMiniZipDoesNotRemoveDestinationItCouldNotOpen {
  NSData* data = [self dataFromBase64:@"UEsDBBQAAAAAAIMYIlBR2j+NCgAAAAoAAAAIAAAAcGFnZS5qcGdjb21pYy1wYWdlUEsDBBQAAAAAAIMYIlAUNBRPCAAAAAgAAAATAAAAX19NQUNPU1gvLl9wYWdlLmpwZ21ldGFkYXRhUEsBAhQDFAAAAAAAgxgiUFHaP40KAAAACgAAAAgAAAAAAAAAAAAAAIABAAAAAHBhZ2UuanBnUEsBAhQDFAAAAAAAgxgiUBQ0FE8IAAAACAAAABMAAAAAAAAAAAAAAIABMAAAAF9fTUFDT1NYLy5fcGFnZS5qcGdQSwUGAAAAAAIAAgB3AAAAaQAAAAAA"];
  MiniZip* archive = [[MiniZip alloc] initWithArchiveData:data];
  XCTAssertNotNil(archive);

  NSString* outputPath = [self temporaryPath:@"existing-directory"];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:outputPath
                                          withIntermediateDirectories:NO
                                                           attributes:nil
                                                                error:NULL]);
  XCTAssertFalse([archive extractFile:@"page.jpg" toPath:outputPath]);
  BOOL isDirectory = NO;
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outputPath isDirectory:&isDirectory]);
  XCTAssertTrue(isDirectory);
  [[NSFileManager defaultManager] removeItemAtPath:[outputPath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testUnRARListsAndExtractsAnEntry {
  NSData* data = [self dataFromBase64:@"UmFyIRoHAM+QcwAADQAAAAAAAABbn3QgkCsAEQAAABEAAAAD4oZFw/AVFEkdMAkA7YEAAGNvbnRhaW5lcgDAIyEvYmluL3NoCmV4aXQgMArEPXsAQAcA"];
  NSString* archivePath = [self temporaryPath:@"comic.rar"];
  XCTAssertTrue([data writeToFile:archivePath atomically:YES]);

  UnRAR* archive = [[UnRAR alloc] initWithArchiveAtPath:archivePath];
  XCTAssertNotNil(archive);
  XCTAssertEqualObjects([archive retrieveFileList], (@[@"container"]));

  NSString* outputPath = [[archivePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"page"];
  XCTAssertTrue([archive extractFile:@"container" toPath:outputPath]);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:outputPath], [@"#!/bin/sh\nexit 0\n" dataUsingEncoding:NSUTF8StringEncoding]);
  [[NSFileManager defaultManager] removeItemAtPath:[archivePath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testUnRARRejectsEncryptedHeaders {
  NSData* data = [self dataFromBase64:@"UmFyIRoHAM6Zc4AADQAAAAAAAABIrNhAIRyvnL7DAOAFLZzG+A7NO/d1yo9WccI/zkN1NGY52Lav1vpY7KdkEtpD+GGWYVOoC5jeS4+dr6hnUl875yOMTOFXHP/vHmAzrvzw1iEPfLrfBloS9wqgMP9XwRBT+iry0JOkk0is2EAhHK+cFprTUdL57Kx5HTKWQnadcA=="];
  NSString* archivePath = [self temporaryPath:@"encrypted-headers.rar"];
  XCTAssertTrue([data writeToFile:archivePath atomically:YES]);

  UnRAR* archive = [[UnRAR alloc] initWithArchiveAtPath:archivePath];
  XCTAssertNil(archive);
  [[NSFileManager defaultManager] removeItemAtPath:[archivePath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testUnRARRejectsEncryptedFilesWithoutCreatingOutput {
  NSData* data = [self dataFromBase64:@"UmFyIRoHAM+QcwAADQAAAAAAAABgM3QklDYAIAAAABEAAAAD4oZFw4RdMl0dMwkApIEAAGNvbnRhaW5lcshnGkZU8CA1APBQHkkgL+LJ9hYn5daRoEoddsfl1tgSR5DafJgr1UQhm16H28Q9ewBABwA="];
  NSString* archivePath = [self temporaryPath:@"encrypted-file.rar"];
  XCTAssertTrue([data writeToFile:archivePath atomically:YES]);

  UnRAR* archive = [[UnRAR alloc] initWithArchiveAtPath:archivePath];
  XCTAssertNotNil(archive);
  XCTAssertNil([archive retrieveFileList]);

  NSString* directory = [archivePath stringByDeletingLastPathComponent];
  NSString* outputPath = [directory stringByAppendingPathComponent:@"page"];
  XCTAssertFalse([archive extractFile:@"container" toPath:outputPath]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outputPath]);

  NSString* bulkOutputPath = [directory stringByAppendingPathComponent:@"bulk"];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:bulkOutputPath
                                          withIntermediateDirectories:NO
                                                           attributes:nil
                                                                error:NULL]);
  XCTAssertFalse([archive extractToPath:bulkOutputPath]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[bulkOutputPath stringByAppendingPathComponent:@"container"]]);
  [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

@end
