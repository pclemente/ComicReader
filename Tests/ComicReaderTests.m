#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "CRLibrarySyncCoordinator.h"
#import "Library.h"
#import "LibraryViewController.h"
#import "Defaults.h"
#import "Extensions_Foundation.h"

@interface ApplicationDelegate (RegressionTesting)
- (void)_dismissAlertWithButtonIndex:(NSInteger)index;
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
    [@"Import regression fixture" drawAtPoint:CGPointMake(20, 20) withAttributes:nil];
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
- (void)testImportPreservesOriginalAndBothSameNamedComics {
  NSString* name = [NSString stringWithFormat:@"Regression-%@.pdf", NSUUID.UUID.UUIDString];
  NSURL* source = [self createPDFNamed:name inDirectory:NSTemporaryDirectory()];
  NSString* first = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:name];
  NSString* second = [[first stringByDeletingPathExtension] stringByAppendingString:@" (2).pdf"];
  [self.createdPaths addObjectsFromArray:@[first, second]];
  XCTAssertTrue([self importAndWait:source]);
  XCTAssertTrue([self importAndWait:source]);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:first], [NSData dataWithContentsOfURL:source]);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:second], [NSData dataWithContentsOfURL:source]);
  NSPredicate* indexed = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary* bindings) {
    NSSet* names = [NSSet setWithArray:[[LibraryConnection mainConnection].fetchAllComicsByName valueForKey:@"name"]];
    return [names containsObject:name] && [names containsObject:second.lastPathComponent];
  }];
  XCTestExpectation* expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:indexed object:nil];
  [self waitForExpectations:@[expectation] timeout:15];
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
- (void)testExistingCollectionComicIsNotCopiedToRoot {
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
