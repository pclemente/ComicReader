#import <XCTest/XCTest.h>
@import StoreKitTest;
@import UIKit;

@interface ComicReaderUITests : XCTestCase
@end

@implementation ComicReaderUITests
- (void)saveScreenshot:(NSString*)name ofApp:(XCUIApplication*)app {
  (void)app;
  XCTAttachment* attachment = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
  attachment.name = name;
  attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
  [self addAttachment:attachment];
}

- (NSArray<NSString*>*)standardLaunchArguments {
  return @[@"-serverType", @"0", @"-launchCount", @"-1", @"-currentComic", @"0",
           @"-plusIntroductionShown", @"YES", @"-releaseNews1_4Shown", @"YES"];
}

- (NSURL*)createPDFUIFixtureNamed:(NSString*)name {
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  UIGraphicsBeginPDFContextToFile(path, CGRectMake(0, 0, 600, 800), nil);
  for (NSUInteger page = 1; page <= 3; page++) {
    UIGraphicsBeginPDFPage();
    NSString* text = [NSString stringWithFormat:@"ComicReader Plus UI fixture, page %lu", (unsigned long)page];
    [text drawAtPoint:CGPointMake(40, 40)
       withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:24]}];
  }
  UIGraphicsEndPDFContext();
  NSURL* url = [NSURL fileURLWithPath:path];
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path]);
  return url;
}

- (BOOL)waitForElementToBecomeEnabled:(XCUIElement*)element timeout:(NSTimeInterval)timeout {
  NSPredicate* predicate = [NSPredicate predicateWithFormat:@"exists == YES AND enabled == YES"];
  XCTestExpectation* expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:element];
  return [XCTWaiter waitForExpectations:@[expectation] timeout:timeout] == XCTWaiterResultCompleted;
}

- (BOOL)waitForElementToBecomeHittable:(XCUIElement*)element timeout:(NSTimeInterval)timeout {
  NSPredicate* predicate = [NSPredicate predicateWithFormat:@"exists == YES AND hittable == YES"];
  XCTestExpectation* expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:element];
  return [XCTWaiter waitForExpectations:@[expectation] timeout:timeout] == XCTWaiterResultCompleted;
}

- (BOOL)waitForPlusToUnlockInApp:(XCUIApplication*)app {
  NSPredicate* predicate = [NSPredicate predicateWithFormat:@"exists == YES AND value == %@", @"Unlocked"];
  XCTestExpectation* expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate
                                                                               object:app.cells[@"plus.purchase"]];
  return [XCTWaiter waitForExpectations:@[expectation] timeout:15] == XCTWaiterResultCompleted;
}

- (void)replaceTextInElement:(XCUIElement*)element withText:(NSString*)text {
  XCTAssertTrue([self waitForElementToBecomeHittable:element timeout:5]);
  [element tap];
  if (element.elementType == XCUIElementTypeTextView) {
    BOOL (^waitForEmpty)(void) = ^BOOL {
      NSPredicate* empty = [NSPredicate predicateWithFormat:@"exists == YES AND (value == nil OR value == '')"];
      XCTestExpectation* expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:empty object:element];
      return [XCTWaiter waitForExpectations:@[expectation] timeout:3] == XCTWaiterResultCompleted;
    };
    BOOL cleared = NO;
    // A shortcut can be ignored while the editor takes keyboard focus. Verify
    // deletion before typing, and retry only when the previous text remains.
    for (NSUInteger attempt = 0; attempt < 2 && !cleared; attempt++) {
      if (attempt > 0) [element tap];
      [element typeKey:@"a" modifierFlags:XCUIKeyModifierCommand];
      [element typeText:XCUIKeyboardKeyDelete];
      cleared = waitForEmpty();
    }
    if (!cleared) {
      [element pressForDuration:1.0];
      XCUIApplication* app = [[XCUIApplication alloc] init];
      NSPredicate* selectAllAction = [NSPredicate predicateWithFormat:@"elementType IN %@ AND label == %@",
        @[@(XCUIElementTypeButton), @(XCUIElementTypeMenuItem)], @"Select All"];
      XCUIElement* selectAll = [[app descendantsMatchingType:XCUIElementTypeAny]
        matchingPredicate:selectAllAction].firstMatch;
      if ([self waitForElementToBecomeHittable:selectAll timeout:3]) {
        [selectAll tap];
        [element typeText:XCUIKeyboardKeyDelete];
        cleared = waitForEmpty();
      }
    }
    XCTAssertTrue(cleared, @"The quote editor must be empty before entering replacement text");
    if (!cleared) return;
    [element typeText:text];
    XCTAssertEqualObjects(element.value, text, @"The quote editor must replace all of its original text");
    return;
  }
  NSString* current = [element.value isKindOfClass:NSString.class] ? element.value : @"";
  NSMutableString* deletes = [NSMutableString string];
  for (NSUInteger index = 0; index < current.length; index++) [deletes appendString:XCUIKeyboardKeyDelete];
  if (deletes.length) [element typeText:deletes];
  [element typeText:text];
}

- (XCUIElement*)cellInApp:(XCUIApplication*)app containingText:(NSString*)text {
  return [app.cells containingType:XCUIElementTypeStaticText identifier:text].firstMatch;
}

- (BOOL)revealReaderToolbarInApp:(XCUIApplication*)app atCoordinate:(XCUICoordinate*)coordinate {
  XCUIElement* bookmarksButton = app.buttons[@"reader.bookmarks.open"];
  for (NSUInteger attempt = 0; attempt < 4; attempt++) {
    if ([bookmarksButton waitForExistenceWithTimeout:1]) {
      return [self waitForElementToBecomeHittable:bookmarksButton timeout:10];
    }
    XCUIElement* loadingLabel = app.staticTexts[@"Please Wait…"];
    if (loadingLabel.exists && ![loadingLabel waitForNonExistenceWithTimeout:15]) return NO;
    [coordinate tap];
  }
  return [bookmarksButton waitForExistenceWithTimeout:5] &&
    [self waitForElementToBecomeHittable:bookmarksButton timeout:10];
}

- (void)testPurchasedReadingListAndNamedBookmarkRemainReadableAfterRefund {
  self.continueAfterFailure = NO;
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;

  NSURL* configurationURL = [[NSBundle bundleForClass:self.class] URLForResource:@"ComicReader"
                                                                    withExtension:@"storekit"];
  XCTAssertNotNil(configurationURL);
  NSError* sessionError = nil;
  SKTestSession* session = [[SKTestSession alloc] initWithContentsOfURL:configurationURL error:&sessionError];
  XCTAssertNotNil(session, @"%@", sessionError);
  [session resetToDefaultState];
  [session clearTransactions];
  session.disableDialogs = YES;

  NSString* token = [NSUUID.UUID.UUIDString substringToIndex:8];
  NSString* comicName = [NSString stringWithFormat:@"Plus-%@.pdf", token];
  NSString* listName = [NSString stringWithFormat:@"Trip %@", token];
  NSString* bookmarkName = [NSString stringWithFormat:@"Opening %@", token];
  NSString* renamedBookmarkName = [NSString stringWithFormat:@"Favorite %@", token];
  NSURL* fixtureURL = [self createPDFUIFixtureNamed:comicName];
  XCUIApplication* app = [[XCUIApplication alloc] init];
  app.launchArguments = self.standardLaunchArguments;

  @try {
    [app launch];
    XCUIElement* plusButton = app.buttons[@"library.plus"];
    XCTAssertTrue([plusButton waitForExistenceWithTimeout:15]);
    [plusButton tap];
    XCUIElement* purchase = app.cells[@"plus.purchase"];
    XCTAssertTrue([self waitForElementToBecomeEnabled:purchase timeout:15]);
    [self saveScreenshot:@"Plus before purchase" ofApp:app];
    [purchase tap];
    XCTAssertTrue([self waitForPlusToUnlockInApp:app]);
    [app.buttons[@"Done"] tap];

    // Deliver a private three-page PDF through the same document URL path used by real imports.
    if (@available(iOS 16.4, *)) {
      [app openURL:fixtureURL];
    } else {
      XCTFail(@"The document-import UI fixture requires iOS 16.4 or later");
      return;
    }
    XCUIElement* listsButton = app.buttons[@"library.readingLists"];
    XCTAssertTrue([listsButton waitForExistenceWithTimeout:15]);
    [listsButton tap];
    XCTAssertTrue([app.navigationBars[@"Reading Lists"] waitForExistenceWithTimeout:5]);
    [app.buttons[@"readingLists.add"] tap];
    XCUIElement* listNameField = app.alerts[@"New Reading List"].textFields[@"readingLists.name"];
    [self replaceTextInElement:listNameField withText:listName];
    [app.alerts[@"New Reading List"].buttons[@"Create"] tap];
    XCTAssertTrue([app.navigationBars[listName] waitForExistenceWithTimeout:5]);

    // Import indexing is asynchronous. Reopen the picker if its initial library snapshot was early.
    XCUIElement* comicCell = nil;
    for (NSUInteger attempt = 0; attempt < 4; attempt++) {
      [app.buttons[@"readingLists.addComic"] tap];
      XCTAssertTrue([app.navigationBars[@"Add Comic"] waitForExistenceWithTimeout:5]);
      comicCell = [self cellInApp:app containingText:comicName];
      if ([comicCell waitForExistenceWithTimeout:4]) break;
      [app.buttons[@"Cancel"] tap];
      XCTAssertTrue([app.navigationBars[listName] waitForExistenceWithTimeout:5]);
    }
    XCTAssertTrue(comicCell.exists, @"The imported PDF never appeared in the Reading List picker");
    [comicCell tap];
    comicCell = [self cellInApp:app containingText:comicName];
    XCTAssertTrue([comicCell waitForExistenceWithTimeout:5]);
    [self saveScreenshot:@"Purchased reading list before refund" ofApp:app];
    XCUIElement* initialListNavigationBar = app.navigationBars[listName];
    [comicCell tap];
    XCTAssertTrue([initialListNavigationBar waitForNonExistenceWithTimeout:10]);

    // The library callback closes the list sheet and opens the existing full-screen reader.
    XCUICoordinate* readerCenter = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
      coordinateWithOffset:CGVectorMake(CGRectGetMidX(app.frame), CGRectGetMidY(app.frame))];
    XCUIElement* bookmarksButton = app.buttons[@"reader.bookmarks.open"];
    XCTAssertTrue([self revealReaderToolbarInApp:app atCoordinate:readerCenter]);
    [bookmarksButton tap];
    XCUIElement* addBookmark = app.buttons[@"reader.bookmarks.add"];
    XCTAssertTrue([self waitForElementToBecomeEnabled:addBookmark timeout:15]);
    [addBookmark tap];
    XCUIElement* bookmarkNameField = app.alerts[@"Add Bookmark"].textFields.firstMatch;
    [self replaceTextInElement:bookmarkNameField withText:bookmarkName];
    [app.alerts[@"Add Bookmark"].buttons[@"Save"] tap];
    XCUIElement* bookmarkRow = app.cells[@"reader.bookmarks.row"];
    NSPredicate* namedBookmark = [NSPredicate predicateWithFormat:@"exists == YES AND label CONTAINS %@", bookmarkName];
    XCTestExpectation* bookmarkSaved = [[XCTNSPredicateExpectation alloc] initWithPredicate:namedBookmark
                                                                                     object:bookmarkRow];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[bookmarkSaved] timeout:15], XCTWaiterResultCompleted);

    XCUIElement* bookmarkActions = app.buttons[@"reader.bookmarks.actions"];
    XCTAssertTrue([self waitForElementToBecomeHittable:bookmarkActions timeout:5]);
    [bookmarkActions tap];
    XCUIElement* renameAction = app.buttons[@"Rename"].firstMatch;
    XCTAssertTrue([self waitForElementToBecomeHittable:renameAction timeout:5]);
    [renameAction tap];
    XCUIElement* renameAlert = app.alerts[@"Rename Bookmark"];
    XCTAssertTrue([renameAlert waitForExistenceWithTimeout:5]);
    [self replaceTextInElement:renameAlert.textFields.firstMatch withText:renamedBookmarkName];
    [renameAlert.buttons[@"Save"] tap];
    bookmarkName = renamedBookmarkName;
    namedBookmark = [NSPredicate predicateWithFormat:@"exists == YES AND label CONTAINS %@", bookmarkName];
    XCTestExpectation* bookmarkRenamed = [[XCTNSPredicateExpectation alloc] initWithPredicate:namedBookmark
                                                                                       object:bookmarkRow];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[bookmarkRenamed] timeout:15], XCTWaiterResultCompleted);
    [self saveScreenshot:@"Named bookmark before refund" ofApp:app];

    [app.buttons[@"reader.bookmarks.done"] tap];
    XCUIElement* filtersButton = app.buttons[@"reader.filters.open"];
    XCTAssertTrue([filtersButton waitForExistenceWithTimeout:5]);
    [filtersButton tap];
    XCUIElement* filtersNavigationBar = app.navigationBars[@"Image Filters"];
    XCTAssertTrue([filtersNavigationBar waitForExistenceWithTimeout:5]);
    XCUIElement* grayscaleFilter = app.cells[@"reader.filter.2"];
    XCTAssertTrue([grayscaleFilter waitForExistenceWithTimeout:5]);
    [grayscaleFilter tap];
    [self saveScreenshot:@"Grayscale filter before refund" ofApp:app];
    [filtersNavigationBar.buttons[@"Done"] tap];
    XCTAssertTrue([filtersButton waitForExistenceWithTimeout:5]);
    XCTAssertTrue([app.buttons[@"Library"] waitForExistenceWithTimeout:5]);
    [app.buttons[@"Library"] tap];
    XCTAssertTrue([listsButton waitForExistenceWithTimeout:10]);

    SKTestTransaction* plusTransaction = nil;
    for (SKTestTransaction* transaction in session.allTransactions) {
      if ([transaction.productIdentifier isEqualToString:@"com.pabloclementeperez.ComicFlow.plus"]) {
        plusTransaction = transaction;
        break;
      }
    }
    XCTAssertNotNil(plusTransaction);
    NSError* refundError = nil;
    XCTAssertTrue([session refundTransactionWithIdentifier:plusTransaction.identifier error:&refundError], @"%@", refundError);

    // Opening Plus gives the app an observable point to finish entitlement refresh.
    [plusButton tap];
    XCTAssertTrue([self waitForElementToBecomeEnabled:app.cells[@"plus.purchase"] timeout:15]);
    [app.buttons[@"Done"] tap];

    // Revocation blocks mutation but does not hide or detach either saved object.
    [listsButton tap];
    XCUIElement* savedList = [self cellInApp:app containingText:listName];
    XCTAssertTrue([savedList waitForExistenceWithTimeout:5]);
    [savedList tap];
    XCUIElement* savedListNavigationBar = app.navigationBars[listName];
    XCTAssertTrue([savedListNavigationBar waitForExistenceWithTimeout:5]);
    XCUIElement* savedComic = [self cellInApp:app containingText:comicName];
    XCTAssertTrue([savedComic waitForExistenceWithTimeout:5]);
    [self saveScreenshot:@"Saved reading list after refund" ofApp:app];
    [app.buttons[@"readingLists.addComic"] tap];
    XCTAssertTrue([app.cells[@"plus.purchase"] waitForExistenceWithTimeout:10]);
    [app.buttons[@"Done"] tap];
    XCTAssertTrue([self waitForElementToBecomeHittable:savedComic timeout:5]);
    [savedComic tap];
    XCTAssertTrue([savedListNavigationBar waitForNonExistenceWithTimeout:10]);
    XCTAssertTrue([self revealReaderToolbarInApp:app atCoordinate:readerCenter]);
    [bookmarksButton tap];
    bookmarkRow = app.cells[@"reader.bookmarks.row"];
    XCTAssertTrue([bookmarkRow waitForExistenceWithTimeout:15]);
    XCTAssertTrue([bookmarkRow.label containsString:bookmarkName]);
    [self saveScreenshot:@"Saved bookmark after refund" ofApp:app];
    [addBookmark tap];
    XCTAssertTrue([app.alerts[@"ComicReader Plus"] waitForExistenceWithTimeout:5]);
    [self saveScreenshot:@"Bookmark mutation gated after refund" ofApp:app];
    [app.alerts[@"ComicReader Plus"].buttons[@"Not Now"] tap];
    [bookmarkRow tap];
    XCTAssertTrue([bookmarksButton waitForExistenceWithTimeout:5]);
  } @finally {
    [app terminate];
    [session clearTransactions];
    [[NSFileManager defaultManager] removeItemAtURL:fixtureURL error:NULL];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
  }
}

- (NSURL*)createComicTextUIFixtureNamed:(NSString*)name {
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  CGRect pageBounds = CGRectMake(0, 0, 600, 800);
  NSArray<NSString*>* phrases = @[@"The lantern glows beside the harbor.",
                                 @"The silver comet crossed the quiet sky.",
                                 @"Every quiet journey begins with courage."];
  UIGraphicsBeginPDFContextToFile(path, pageBounds, nil);
  for (NSUInteger page = 0; page < phrases.count; page++) {
    UIGraphicsBeginPDFPage();
    NSDictionary* attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:26],
                                  NSForegroundColorAttributeName: UIColor.blackColor};
    CGRect textRect = CGRectMake(40, 100, 520, 250);
    if (page == 0) {
      // This page has no PDF text layer: the free page-text feature must run real OCR.
      UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat defaultFormat];
      format.scale = 1;
      format.opaque = YES;
      UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:pageBounds.size
                                                                               format:format];
      UIImage* scannedPage = [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        [UIColor.whiteColor setFill];
        [context fillRect:pageBounds];
        [phrases[page] drawInRect:textRect withAttributes:attributes];
      }];
      [scannedPage drawInRect:pageBounds];
    } else {
      // The index also needs to handle PDFs that already contain selectable text.
      [phrases[page] drawInRect:textRect withAttributes:attributes];
    }
  }
  UIGraphicsEndPDFContext();
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path]);
  return [NSURL fileURLWithPath:path];
}

- (BOOL)waitForTextElement:(XCUIElement*)element toContain:(NSString*)text timeout:(NSTimeInterval)timeout {
  NSPredicate* predicate = [NSPredicate predicateWithFormat:@"exists == YES AND value CONTAINS[c] %@", text];
  XCTestExpectation* expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:element];
  return [XCTWaiter waitForExpectations:@[expectation] timeout:timeout] == XCTWaiterResultCompleted;
}

- (void)dismissComicTextPlusGateInApp:(XCUIApplication*)app {
  XCUIElement* gate = app.alerts[@"ComicReader Plus"];
  XCTAssertTrue([gate waitForExistenceWithTimeout:5]);
  XCTAssertTrue(gate.buttons[@"Not Now"].hittable);
  [gate.buttons[@"Not Now"] tap];
  XCTAssertTrue([gate waitForNonExistenceWithTimeout:5]);
}

- (void)dismissLegacyRatingPromptIfPresentInApp:(XCUIApplication*)app {
  XCUIElement* rating = app.alerts[@"Are you enjoying ComicReader?"];
  if ([rating waitForExistenceWithTimeout:3]) {
    [rating.buttons[@"Remind Me Later"] tap];
    XCTAssertTrue([rating waitForNonExistenceWithTimeout:5]);
  }
}

- (void)verifyAndDismissComicTextShareSheetInApp:(XCUIApplication*)app containingText:(NSString*)text {
  // UIKit may rebuild the activity controller's root view and remove an app-set
  // identifier. These system containers identify the actual presented share UI.
  NSPredicate* shareContainer = [NSPredicate predicateWithFormat:@"identifier IN %@",
    @[@"ActivityListView", @"ShareSheet.RemoteContainerView"]];
  XCUIElement* shareSheet = [[app descendantsMatchingType:XCUIElementTypeAny]
    matchingPredicate:shareContainer].firstMatch;
  XCTAssertTrue([shareSheet waitForExistenceWithTimeout:10]);
  NSPredicate* sharedText = [NSPredicate predicateWithFormat:@"identifier == %@ AND label CONTAINS[c] %@",
    @"LP.CaptionBar.BottomCaption", text];
  XCUIElement* caption = [[app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:sharedText].firstMatch;
  XCTAssertTrue([caption waitForExistenceWithTimeout:10], @"The share sheet must contain the requested phrase");
  [self saveScreenshot:@"Comic phrase system share sheet" ofApp:app];
  NSPredicate* dismissalLabel = [NSPredicate predicateWithFormat:@"label == %@ OR label == %@", @"Close", @"Cancel"];
  XCUIElement* dismiss = [app.buttons matchingPredicate:dismissalLabel].firstMatch;
  if (dismiss.exists && dismiss.hittable) {
    [dismiss tap];
  } else {
    // On iPad UIActivityViewController may be a popover with outside-tap dismissal.
    [[app coordinateWithNormalizedOffset:CGVectorMake(0.98, 0.05)] tap];
  }
  XCTAssertTrue([shareSheet waitForNonExistenceWithTimeout:10]);
}

- (void)testComicTextSearchAndQuotesKeepFreeOCRAndSavedQuotesAfterRefund {
  self.continueAfterFailure = NO;
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;

  NSURL* configurationURL = [[NSBundle bundleForClass:self.class] URLForResource:@"ComicReader"
                                                                    withExtension:@"storekit"];
  XCTAssertNotNil(configurationURL);
  NSError* sessionError = nil;
  SKTestSession* session = [[SKTestSession alloc] initWithContentsOfURL:configurationURL error:&sessionError];
  XCTAssertNotNil(session, @"%@", sessionError);
  [session resetToDefaultState];
  [session clearTransactions];
  session.disableDialogs = YES;

  NSString* token = [NSUUID.UUID.UUIDString substringToIndex:8];
  NSString* comicName = [NSString stringWithFormat:@"Text-%@.pdf", token];
  NSString* quote = [NSString stringWithFormat:@"The silver comet is my favorite phrase %@.", token];
  NSString* editedQuote = [NSString stringWithFormat:@"A silver comet crosses the sky %@.", token];
  NSURL* fixtureURL = [self createComicTextUIFixtureNamed:comicName];
  XCUIApplication* app = [[XCUIApplication alloc] init];
  app.launchArguments = self.standardLaunchArguments;

  @try {
    [app launch];
    [self dismissLegacyRatingPromptIfPresentInApp:app];
    XCTAssertTrue([app.buttons[@"library.plus"] waitForExistenceWithTimeout:15]);
    if (@available(iOS 16.4, *)) {
      [app openURL:fixtureURL];
    } else {
      XCTFail(@"The document-import UI fixture requires iOS 16.4 or later");
      return;
    }
    NSString* coverIdentifier = [@"library.comic." stringByAppendingString:comicName];
    XCUIElement* cover = [app descendantsMatchingType:XCUIElementTypeAny][coverIdentifier];
    XCTAssertTrue([self waitForElementToBecomeHittable:cover timeout:20]);
    [cover tap];
    XCUICoordinate* readerCenter = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
      coordinateWithOffset:CGVectorMake(CGRectGetMidX(app.frame), CGRectGetMidY(app.frame))];
    XCTAssertTrue([self revealReaderToolbarInApp:app atCoordinate:readerCenter]);
    XCUIElement* textButton = app.buttons[@"reader.text.open"];
    XCTAssertTrue([self waitForElementToBecomeHittable:textButton timeout:5]);
    [textButton tap];
    XCUIElement* pageText = app.textViews[@"reader.text.content"];
    XCTAssertTrue([self waitForTextElement:pageText toContain:@"lantern glows" timeout:25]);
    XCTAssertTrue(pageText.enabled);
    [self saveScreenshot:@"Free on-device OCR from a scanned page" ofApp:app];
    [app.buttons[@"reader.text.share"] tap];
    [self verifyAndDismissComicTextShareSheetInApp:app containingText:@"lantern glows"];
    [app.buttons[@"reader.text.saveQuote"] tap];
    [self dismissComicTextPlusGateInApp:app];
    XCUIElement* modes = app.segmentedControls[@"reader.text.mode"];
    [modes.buttons[@"Search"] tap];
    XCUIElement* query = app.searchFields[@"reader.text.query"];
    XCTAssertFalse(query.enabled);
    [app.buttons[@"reader.text.index"] tap];

    // Buy from the reader's actual upgrade route, then return to the same Search screen.
    XCUIElement* searchGate = app.alerts[@"ComicReader Plus"];
    XCTAssertTrue([searchGate waitForExistenceWithTimeout:5]);
    [searchGate.buttons[@"View Plus"] tap];
    XCUIElement* embeddedPlusNavigation = app.navigationBars[@"ComicReader Plus"];
    XCTAssertTrue([embeddedPlusNavigation waitForExistenceWithTimeout:5]);
    XCUIElement* plusButton = app.buttons[@"library.plus"];
    XCUIElement* purchase = app.cells[@"plus.purchase"];
    XCTAssertTrue([self waitForElementToBecomeEnabled:purchase timeout:15]);
    [purchase tap];
    XCTAssertTrue([self waitForPlusToUnlockInApp:app]);
    [embeddedPlusNavigation.buttons[@"Done"] tap];
    XCTAssertTrue([app.navigationBars[@"Comic Text"] waitForExistenceWithTimeout:5]);
    XCTAssertTrue(modes.buttons[@"Search"].selected);
    XCTAssertTrue([self waitForElementToBecomeEnabled:app.buttons[@"reader.text.index"] timeout:15]);
    [app.buttons[@"reader.text.index"] tap];
    XCTAssertTrue([self waitForElementToBecomeEnabled:query timeout:30]);
    [self replaceTextInElement:query withText:@"silver comet"];
    XCUIElement* secondPage = app.cells[@"reader.text.result.1"];
    XCTAssertTrue([self waitForElementToBecomeHittable:secondPage timeout:30]);
    [self saveScreenshot:@"Plus searches dialogue across the comic" ofApp:app];
    [secondPage tap];
    XCTAssertTrue([app.navigationBars[@"Comic Text"] waitForNonExistenceWithTimeout:10]);
    XCTAssertTrue([self revealReaderToolbarInApp:app atCoordinate:readerCenter]);
    [textButton tap];
    XCTAssertTrue([self waitForTextElement:pageText toContain:@"silver comet" timeout:15]);

    // The quote is editable before saving, keeps its source page, and uses the system share sheet.
    [app.buttons[@"reader.text.saveQuote"] tap];
    XCUIElement* quoteEditor = app.textViews[@"reader.quote.editor"];
    [self replaceTextInElement:quoteEditor withText:quote];
    [app.buttons[@"reader.quote.save"] tap];
    [modes.buttons[@"Quotes"] tap];
    XCUIElement* quoteRow = [app.cells matchingPredicate:
      [NSPredicate predicateWithFormat:@"identifier == %@ AND label CONTAINS %@", @"reader.quotes.row", quote]].firstMatch;
    XCTAssertTrue([self waitForElementToBecomeHittable:quoteRow timeout:10]);
    [quoteRow tap];
    XCUIElement* quoteContent = app.textViews[@"reader.quote.content"];
    XCTAssertTrue([self waitForTextElement:quoteContent toContain:quote timeout:5]);
    XCTAssertEqualObjects(quoteContent.value, quote);
    [app.buttons[@"reader.quote.share"] tap];
    [self verifyAndDismissComicTextShareSheetInApp:app containingText:quote];
    [app.buttons[@"reader.quote.edit"] tap];
    [self replaceTextInElement:quoteEditor withText:editedQuote];
    [app.buttons[@"reader.quote.save"] tap];
    XCTAssertTrue([self waitForTextElement:quoteContent toContain:editedQuote timeout:5]);
    XCTAssertEqualObjects(quoteContent.value, editedQuote);
    [self saveScreenshot:@"Edited quotation with its comic and page" ofApp:app];
    [app.buttons[@"reader.quote.done"] tap];
    [app.buttons[@"reader.text.done"] tap];
    XCTAssertTrue([self waitForElementToBecomeHittable:app.buttons[@"Library"] timeout:5]);
    [app.buttons[@"Library"] tap];

    SKTestTransaction* plusTransaction = nil;
    for (SKTestTransaction* transaction in session.allTransactions) {
      if ([transaction.productIdentifier isEqualToString:@"com.pabloclementeperez.ComicFlow.plus"]) {
        plusTransaction = transaction;
        break;
      }
    }
    XCTAssertNotNil(plusTransaction);
    NSError* refundError = nil;
    XCTAssertTrue([session refundTransactionWithIdentifier:plusTransaction.identifier error:&refundError], @"%@", refundError);
    XCTAssertTrue([self waitForElementToBecomeHittable:plusButton timeout:10]);
    [plusButton tap];
    XCTAssertTrue([self waitForElementToBecomeEnabled:app.cells[@"plus.purchase"] timeout:15]);
    [app.buttons[@"Done"] tap];
    [app terminate];
    [app launch];
    [self dismissLegacyRatingPromptIfPresentInApp:app];

    // Relaunch proves local persistence; a refund must not strand the reader's saved quotations.
    XCTAssertTrue([self waitForElementToBecomeHittable:cover timeout:15]);
    [cover tap];
    XCTAssertTrue([self revealReaderToolbarInApp:app atCoordinate:readerCenter]);
    [textButton tap];
    [modes.buttons[@"Quotes"] tap];
    quoteRow = [app.cells matchingPredicate:
      [NSPredicate predicateWithFormat:@"identifier == %@ AND label CONTAINS %@", @"reader.quotes.row", editedQuote]].firstMatch;
    XCTAssertTrue([self waitForElementToBecomeHittable:quoteRow timeout:10]);
    [quoteRow tap];
    XCTAssertTrue([self waitForTextElement:quoteContent toContain:editedQuote timeout:5]);
    XCTAssertEqualObjects(quoteContent.value, editedQuote);
    [app.buttons[@"reader.quote.edit"] tap];
    [self dismissComicTextPlusGateInApp:app];
    [app.buttons[@"reader.quote.share"] tap];
    [self verifyAndDismissComicTextShareSheetInApp:app containingText:editedQuote];
    [self saveScreenshot:@"Saved quotation remains readable after refund" ofApp:app];
    [app.buttons[@"reader.quote.goToPage"] tap];
    XCTAssertTrue([app.navigationBars[@"Comic Text"] waitForNonExistenceWithTimeout:10]);
    XCTAssertTrue([self revealReaderToolbarInApp:app atCoordinate:readerCenter]);
    [textButton tap];
    XCTAssertTrue([self waitForTextElement:pageText toContain:@"silver comet" timeout:15]);
  } @finally {
    [app terminate];
    [session clearTransactions];
    [[NSFileManager defaultManager] removeItemAtURL:fixtureURL error:NULL];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
  }
}

- (void)testPlusScreenKeepsICloudFreeAndSeparate {
  self.continueAfterFailure = NO;
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
  XCUIApplication* app = [[XCUIApplication alloc] init];
  app.launchArguments = @[@"-serverType", @"0", @"-launchCount", @"-1", @"-currentComic", @"0", @"-releaseNews1_4Shown", @"YES"];
  [app launch];
  XCUIElement* plus = app.buttons[@"library.plus"];
  XCTAssertTrue([plus waitForExistenceWithTimeout:15]);
  [plus tap];
  XCTAssertTrue([app.cells[@"plus.purchase"] waitForExistenceWithTimeout:10]);
  XCTAssertTrue(app.cells[@"plus.restore"].exists);
  XCTAssertTrue(app.cells[@"plus.readingListsFeature"].exists);
  XCTAssertTrue(app.cells[@"plus.bookmarksFeature"].exists);
  XCTAssertFalse(app.switches[@"Sync all comics with iCloud"].exists);
  [self saveScreenshot:@"Plus reading tools before purchase" ofApp:app];
  [app.buttons[@"Done"] tap];
  [app.buttons[@"library.icloud"] tap];
  XCUIElement* toggle = app.switches[@"Sync all comics with iCloud"];
  XCTAssertTrue([toggle waitForExistenceWithTimeout:5]);
  XCTAssertTrue(toggle.enabled);
  XCTAssertEqualObjects(toggle.value, @"0");
  XCTAssertFalse(app.cells[@"plus.purchase"].exists);
  [toggle tap];
  XCTAssertTrue([app.alerts[@"Turn On iCloud Sync?"] waitForExistenceWithTimeout:5]);
  [app.alerts[@"Turn On iCloud Sync?"].buttons[@"Cancel"] tap];
  XCTAssertEqualObjects(toggle.value, @"0");
  [self saveScreenshot:@"Free iCloud settings without Plus" ofApp:app];
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
  XCTAssertTrue(toggle.hittable);
  [app.buttons[@"Done"] tap];
  XCTAssertTrue([plus waitForExistenceWithTimeout:5]);
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
}

- (void)testContextMenuOnPreparedSampleLibrary {
  // This destructive case is opt-in. Its runner must seed only disposable comic
  // fixtures and verify the deleted file against the pre-test file inventory.
  XCTSkipUnless([NSProcessInfo.processInfo.environment[@"CR_UI_DISPOSABLE_LIBRARY"] boolValue],
                @"Requires an isolated library of disposable sample comics");
  self.continueAfterFailure = NO;
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
  XCUIApplication* app = [[XCUIApplication alloc] init];
  app.launchArguments = @[@"-serverType", @"0", @"-launchCount", @"-1", @"-currentComic", @"0", @"-releaseNews1_4Shown", @"YES"];
  [app launch];
  XCTAssertTrue([app.buttons[@"library.settings"] waitForExistenceWithTimeout:15]);
  [app.buttons[@"By Name"] tap];
  XCTAssertGreaterThan(CGRectGetWidth(app.frame), 900.0);
  // First cover centre in the full-screen 13-inch iPad fixture layout.
  XCUICoordinate* cover = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                           coordinateWithOffset:CGVectorMake(80, 175)];
  [cover pressForDuration:1.2];
  XCUIElement* delete = app.buttons[@"Delete"];
  XCTAssertTrue([delete waitForExistenceWithTimeout:5]);
  XCTAssertLessThan(CGRectGetMinX(delete.frame), CGRectGetWidth(app.frame) / 2.0);
  XCTAssertLessThan(CGRectGetMaxY(delete.frame), CGRectGetHeight(app.frame) / 2.0);
  [self saveScreenshot:@"Cover context menu portrait" ofApp:app];
  [[app coordinateWithNormalizedOffset:CGVectorMake(0.75, 0.70)] tap];
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
  cover = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
             coordinateWithOffset:CGVectorMake(80, 175)];
  [cover pressForDuration:1.2];
  XCTAssertTrue([delete waitForExistenceWithTimeout:5]);
  XCTAssertLessThan(CGRectGetMinX(delete.frame), CGRectGetWidth(app.frame) / 2.0);
  [self saveScreenshot:@"Cover context menu landscape" ofApp:app];
  [delete tap];
  XCTAssertTrue([app.buttons[@"library.settings"] waitForExistenceWithTimeout:5]);
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
}

- (void)testSettingsAndFilesPickerWithServerOff {
  self.continueAfterFailure = NO;
  XCUIApplication* app = [[XCUIApplication alloc] init];
  app.launchArguments = @[@"-serverType", @"0", @"-launchCount", @"-1", @"-currentComic", @"0", @"-releaseNews1_4Shown", @"YES"];
  [app launch];
  XCUIElement* settings = app.buttons[@"library.settings"];
  XCTAssertTrue([settings waitForExistenceWithTimeout:15]);
  [settings tap];
  XCUIElement* addFiles = app.buttons[@"library.addFiles"];
  XCTAssertTrue([addFiles waitForExistenceWithTimeout:5]);
  [addFiles tap];
  XCUIElement* cancel = app.buttons[@"Cancel"].firstMatch;
  // The system Files extension can initially show an empty remote view on a
  // cold simulator. Require its real Cancel control to become interactive.
  XCTAssertTrue([self waitForElementToBecomeHittable:cancel timeout:35],
                @"The system Files picker did not finish loading its controls");
  [self saveScreenshot:@"Files picker after provider loading" ofApp:app];
  [cancel tap];
  XCTAssertTrue([cancel waitForNonExistenceWithTimeout:10]);
  XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
  [settings tap];
  XCTAssertTrue([addFiles waitForExistenceWithTimeout:5]);
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
  XCTAssertTrue(addFiles.isHittable);
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
  XCTAttachment* screenshot = [XCTAttachment attachmentWithScreenshot:app.screenshot];
  screenshot.name = @"Settings after Files import cancellation";
  screenshot.lifetime = XCTAttachmentLifetimeKeepAlways;
  [self addAttachment:screenshot];
}

- (void)testNewsBannerAppearsForUpgradeAndStaysDismissed {
  self.continueAfterFailure = NO;
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
  XCUIApplication* app = [[XCUIApplication alloc] init];
  NSArray* normalArguments = @[@"-serverType", @"0", @"-launchCount", @"-1", @"-currentComic", @"0", @"-plusIntroductionShown", @"YES"];
  app.launchArguments = [normalArguments arrayByAddingObjectsFromArray:@[@"-releaseNews1_4Shown", @"NO"]];
  [app launch];
  XCUIElement* close = app.buttons[@"news.dismiss"];
  XCTAssertTrue([close waitForExistenceWithTimeout:15]);
  XCTAssertTrue(app.buttons[@"news.icloud"].hittable);
  XCTAssertTrue(app.buttons[@"news.plus"].hittable);
  XCTAssertFalse(app.alerts[@"Introducing ComicReader Plus"].exists);
  [self saveScreenshot:@"What is new banner portrait" ofApp:app];
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
  XCTAssertTrue(close.hittable);
  [self saveScreenshot:@"What is new banner landscape" ofApp:app];
  [close tap];
  XCTAssertFalse(close.exists);
  [app terminate];
  app.launchArguments = normalArguments;
  [app launch];
  XCTAssertTrue([app.buttons[@"library.icloud"] waitForExistenceWithTimeout:15]);
  XCTAssertFalse(close.exists);
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
}

- (void)testNewsBannerOpensFreeSyncWithoutPurchase {
  self.continueAfterFailure = NO;
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
  XCUIApplication* app = [[XCUIApplication alloc] init];
  app.launchArguments = @[@"-serverType", @"0", @"-launchCount", @"-1", @"-currentComic", @"0", @"-releaseNews1_4Shown", @"NO"];
  [app launch];
  XCTAssertTrue([app.buttons[@"news.icloud"] waitForExistenceWithTimeout:15]);
  [app.buttons[@"news.icloud"] tap];
  XCUIElement* toggle = app.switches[@"Sync all comics with iCloud"];
  XCTAssertTrue([toggle waitForExistenceWithTimeout:5]);
  XCTAssertTrue(toggle.enabled);
  XCTAssertEqualObjects(toggle.value, @"0");
  XCTAssertFalse(app.cells[@"plus.purchase"].exists);
  [app.buttons[@"Done"] tap];
  XCTAssertFalse(app.buttons[@"news.dismiss"].exists);
}


- (void)testPlusPurchaseRestoreAndRefund {
  self.continueAfterFailure = NO;
  NSURL* configurationURL = [[NSBundle bundleForClass:self.class] URLForResource:@"ComicReader" withExtension:@"storekit"];
  XCTAssertNotNil(configurationURL);
  NSError* error = nil;
  SKTestSession* session = [[SKTestSession alloc] initWithContentsOfURL:configurationURL error:&error];
  XCTAssertNotNil(session, @"%@", error);
  [session resetToDefaultState];
  [session clearTransactions];
  session.disableDialogs = YES;
  XCUIApplication* app = [[XCUIApplication alloc] init];
  app.launchArguments = self.standardLaunchArguments;
  @try {
    [app launch];
    XCTAssertTrue([self waitForElementToBecomeHittable:app.buttons[@"library.plus"] timeout:15]);
    [app.buttons[@"library.plus"] tap];
    XCUIElement* purchase = app.cells[@"plus.purchase"];
    XCTAssertTrue([self waitForElementToBecomeEnabled:purchase timeout:15]);
    [purchase tap];
    XCTAssertTrue([self waitForPlusToUnlockInApp:app]);
    // A new process must recover the purchase from StoreKit, without relying
    // on the in-memory grant from the purchase result.
    [app terminate];
    [app launch];
    XCTAssertTrue([self waitForElementToBecomeHittable:app.buttons[@"library.plus"] timeout:15]);
    [app.buttons[@"library.plus"] tap];
    XCTAssertTrue([self waitForPlusToUnlockInApp:app]);
    XCTAssertTrue([self waitForElementToBecomeEnabled:app.cells[@"plus.restore"] timeout:15]);
    [app.cells[@"plus.restore"] tap];
    XCUIElement* restored = app.alerts[@"Purchase Restored"];
    XCTAssertTrue([restored waitForExistenceWithTimeout:15]);
    [restored.buttons[@"OK"] tap];
    XCTAssertEqualObjects(purchase.value, @"Unlocked");
    [self saveScreenshot:@"Plus purchase and restore verified" ofApp:app];

    SKTestTransaction* bought = nil;
    for (SKTestTransaction* transaction in session.allTransactions) {
      if ([transaction.productIdentifier isEqualToString:@"com.pabloclementeperez.ComicFlow.plus"]) {
        bought = transaction;
        break;
      }
    }
    XCTAssertNotNil(bought);
    XCTAssertTrue([session refundTransactionWithIdentifier:bought.identifier error:&error], @"%@", error);
    XCTAssertTrue([self waitForElementToBecomeEnabled:purchase timeout:15]);
    XCTAssertEqualObjects(purchase.value, @"Not purchased");
    [self saveScreenshot:@"Plus refund verified" ofApp:app];

    [app.buttons[@"Done"] tap];
    XCTAssertTrue([self waitForElementToBecomeHittable:app.buttons[@"library.icloud"] timeout:5]);
    [app.buttons[@"library.icloud"] tap];
    XCTAssertTrue([app.switches[@"Sync all comics with iCloud"] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(app.cells[@"plus.purchase"].exists);
  } @finally {
    [app terminate];
    [session clearTransactions];
  }
}

- (void)testAdaptiveNavigationAndFreeFilterPreview {
  self.continueAfterFailure = NO;
  XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
  NSURL* configurationURL = [[NSBundle bundleForClass:self.class] URLForResource:@"ComicReader" withExtension:@"storekit"];
  NSError* error = nil;
  SKTestSession* session = [[SKTestSession alloc] initWithContentsOfURL:configurationURL error:&error];
  XCTAssertNotNil(session, @"%@", error);
  [session resetToDefaultState];
  [session clearTransactions];
  session.disableDialogs = YES;
  XCUIApplication* app = [[XCUIApplication alloc] init];
  app.launchArguments = self.standardLaunchArguments;
  @try {
    [app launch];
    for (NSString* identifier in @[@"library.plus", @"library.icloud", @"library.settings"]) {
      XCUIElement* button = app.buttons[identifier];
      XCTAssertTrue([self waitForElementToBecomeHittable:button timeout:15], @"%@", identifier);
      XCTAssertTrue(CGRectContainsRect(app.frame, button.frame), @"%@ must fit on screen", identifier);
    }
    [self saveScreenshot:@"Adaptive library portrait" ofApp:app];
    [app.buttons[@"library.plus"] tap];
    XCUIElement* purchase = app.cells[@"plus.purchase"];
    XCTAssertTrue([self waitForElementToBecomeEnabled:purchase timeout:15]);
    XCTAssertTrue(purchase.hittable);
    [self saveScreenshot:@"Plus one-time offer portrait" ofApp:app];
    XCUIElement* filters = app.cells[@"plus.imageFiltersFeature"];
    for (NSUInteger scroll = 0; scroll < 6 && !filters.hittable; scroll++) [app.tables.firstMatch swipeUp];
    XCTAssertTrue(filters.hittable);
    [filters tap];
    XCUIElement* gray = app.cells[@"plus.filterPreview.2"];
    XCTAssertTrue([gray waitForExistenceWithTimeout:5]);
    for (NSUInteger scroll = 0; scroll < 4 && !gray.hittable; scroll++) [app.tables.firstMatch swipeUp];
    [gray tap];
    XCUIElement* preview = app.images[@"plus.filterPreview.image"];
    XCTAssertEqualObjects(preview.label, @"Grayscale sample comic artwork");
    [self saveScreenshot:@"Free real filter preview" ofApp:app];
    XCUIElement* previewBack = app.navigationBars[@"Preview Image Filters"].buttons[@"BackButton"];
    XCTAssertTrue([self waitForElementToBecomeHittable:previewBack timeout:5]);
    [previewBack tap];
    XCUIElement* plusDone = app.navigationBars[@"ComicReader Plus"].buttons[@"Done"];
    XCTAssertTrue([self waitForElementToBecomeHittable:plusDone timeout:5]);
    [plusDone tap];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    for (NSString* identifier in @[@"library.plus", @"library.icloud", @"library.settings"]) {
      XCTAssertTrue([self waitForElementToBecomeHittable:app.buttons[identifier] timeout:5]);
    }
    [app.buttons[@"library.settings"] tap];
    XCUIElement* add = app.buttons[@"library.addFiles"];
    XCTAssertTrue([self waitForElementToBecomeHittable:add timeout:10]);
    [self saveScreenshot:@"Scrollable settings landscape" ofApp:app];
  } @finally {
    [app terminate];
    [session clearTransactions];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
  }
}

@end
