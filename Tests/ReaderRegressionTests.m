#import <XCTest/XCTest.h>
#import <QuartzCore/QuartzCore.h>

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
