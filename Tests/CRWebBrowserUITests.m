#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <StoreKitTest/StoreKitTest.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <errno.h>

// A loopback-only publisher fixture. No credentials or third-party sites are
// involved: WebKit must retain its own HttpOnly cookie across a redirect.
@interface CRBrowserFixtureServer : NSObject
@property(atomic) BOOL running;
@property(nonatomic) int listener;
@property(nonatomic) NSUInteger port;
@property(nonatomic, strong) NSData* comic;
- (void)start;
- (void)stop;
@end

@implementation CRBrowserFixtureServer
- (void)start {
  NSMutableData* pdf = [NSMutableData data];
  UIGraphicsBeginPDFContextToData(pdf, CGRectMake(0, 0, 600, 800), nil);
  for (NSUInteger page = 1; page <= 3; page++) {
    UIGraphicsBeginPDFPage();
    [[NSString stringWithFormat:@"WEB JOURNEY — page %lu", (unsigned long)page]
      drawAtPoint:CGPointMake(40, 60) withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:24]}];
  }
  UIGraphicsEndPDFContext();
  self.comic = pdf;
  self.listener = socket(AF_INET, SOCK_STREAM, 0);
  NSAssert(self.listener >= 0, @"Could not create fixture socket");
  struct sockaddr_in address = {0};
  address.sin_len = sizeof(address);
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  NSAssert(bind(self.listener, (struct sockaddr*)&address, sizeof(address)) == 0, @"Could not bind fixture");
  socklen_t addressSize = sizeof(address);
  getsockname(self.listener, (struct sockaddr*)&address, &addressSize);
  self.port = ntohs(address.sin_port);
  NSAssert(listen(self.listener, 8) == 0, @"Could not listen for fixture");
  self.running = YES;
  int listener = self.listener;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    while (self.running) {
      int client = accept(listener, NULL, NULL);
      if (client < 0 && errno == EINTR) continue;
      if (client < 0) break;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
          int noSignal = 1;
          setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
          struct timeval timeout = {30, 0};
          setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
          setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
          // TCP does not preserve header boundaries. In particular, cookies
          // may arrive in a different packet from the request line.
          char buffer[16384];
          NSUInteger received = 0;
          while (received < sizeof(buffer)) {
            ssize_t count = recv(client, buffer + received, sizeof(buffer) - received, 0);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            received += (NSUInteger)count;
            NSString* request = [[NSString alloc] initWithBytes:buffer length:received encoding:NSUTF8StringEncoding];
            if ([request containsString:@"\r\n\r\n"]) {
              [self respondTo:request socket:client];
              break;
            }
          }
          shutdown(client, SHUT_WR);
          close(client);
        }
      });
    }
  });
}
- (void)respondTo:(NSString*)request socket:(int)client {
  NSString* route = [request componentsSeparatedByString:@" "].count > 1 ? [request componentsSeparatedByString:@" "][1] : @"/";
  BOOL signedIn = [request containsString:@"CRFixtureSession=yes"];
  BOOL login = [route isEqualToString:@"/login"];
  NSLog(@"Browser fixture: %@ (test session: %@)", route, signedIn ? @"yes" : @"no");
  NSString* status = @"200 OK";
  NSString* headers = login ? @"Set-Cookie: CRFixtureSession=yes; HttpOnly; SameSite=Lax; Path=/\r\n" : @"";
  NSString* mime = @"text/html; charset=utf-8";
  NSData* body;
  if ([route isEqualToString:@"/download"] && signedIn) {
    status = @"302 Found";
    headers = @"Location: /protected/comic.pdf\r\n";
    body = NSData.data;
  } else if ([route isEqualToString:@"/protected/comic.pdf"] && signedIn) {
    mime = @"application/pdf";
    headers = @"Content-Disposition: attachment; filename=\"Web Journey.pdf\"\r\n";
    body = self.comic;
  } else {
    NSString* state = signedIn || login ? @"Signed in to test publisher" : @"No publisher session";
    NSString* html = [NSString stringWithFormat:@"<!doctype html><meta name='viewport' content='width=device-width'><title>Test publisher</title><h1>%@</h1><p><a href='/login'>Sign in to test publisher</a></p><p><a href='/download'>Download test comic</a></p>", state];
    body = [html dataUsingEncoding:NSUTF8StringEncoding];
  }
  NSString* response = [NSString stringWithFormat:@"HTTP/1.0 %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n%@\r\n", status, mime, (unsigned long)body.length, headers];
  NSMutableData* bytes = [[response dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [bytes appendData:body];
  NSUInteger offset = 0;
  while (offset < bytes.length) {
    ssize_t written = send(client, (const char*)bytes.bytes + offset, bytes.length - offset, 0);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) break;
    offset += (NSUInteger)written;
  }
}
- (void)stop {
  if (!self.running) return;
  self.running = NO;
  shutdown(self.listener, SHUT_RDWR);
  close(self.listener);
}
@end

@interface ComicReaderUITests : XCTestCase
- (NSArray<NSString*>*)standardLaunchArguments;
- (BOOL)waitForElementToBecomeHittable:(XCUIElement*)element timeout:(NSTimeInterval)timeout;
- (BOOL)waitForElementToBecomeEnabled:(XCUIElement*)element timeout:(NSTimeInterval)timeout;
- (BOOL)waitForPlusToUnlockInApp:(XCUIApplication*)app;
- (void)saveScreenshot:(NSString*)name ofApp:(XCUIApplication*)app;
@end

@implementation ComicReaderUITests (WebBrowserTests)
- (void)openFixture:(CRBrowserFixtureServer*)server route:(NSString*)route inBrowser:(XCUIApplication*)app {
  XCUIElement* address = app.textFields[@"library.browser.homeAddress"];
  if (![address waitForExistenceWithTimeout:3]) address = app.textFields[@"library.browser.address"];
  XCTAssertTrue([self waitForElementToBecomeHittable:address timeout:10]);
  [address tap];
  [address typeKey:@"a" modifierFlags:XCUIKeyModifierCommand];
  [address typeText:[NSString stringWithFormat:@"http://localhost:%lu%@\n", (unsigned long)server.port, route]];
}

- (void)testWebBrowserSessionsAndPrivateModeWithoutPlus {
  self.continueAfterFailure = NO;
  CRBrowserFixtureServer* server = [CRBrowserFixtureServer new];
  [server start];
  XCUIApplication* app = [XCUIApplication new];
  app.launchArguments = self.standardLaunchArguments;
  @try {
    [app launch];
    XCTAssertTrue([self waitForElementToBecomeHittable:app.buttons[@"library.browser"] timeout:15]);
    [app.buttons[@"library.browser"] tap];
    [self openFixture:server route:@"/login" inBrowser:app];
    XCTAssertTrue([app.webViews.staticTexts[@"Signed in to test publisher"] waitForExistenceWithTimeout:30]);
    [self saveScreenshot:@"Browser authenticated website" ofApp:app];
    [app.buttons[@"library.browser.done"] tap];
    [app.buttons[@"library.browser"] tap];
    [self openFixture:server route:@"/" inBrowser:app];
    XCTAssertTrue([app.webViews.staticTexts[@"Signed in to test publisher"] waitForExistenceWithTimeout:10]);
    [app.buttons[@"library.browser.more"] tap];
    [app.buttons[@"New Private Session"] tap];
    [app.alerts[@"Start Private Session?"].buttons[@"Start Private"] tap];
    [self openFixture:server route:@"/" inBrowser:app];
    XCTAssertTrue([app.webViews.staticTexts[@"No publisher session"] waitForExistenceWithTimeout:10]);
    [self saveScreenshot:@"Private browser has separate website session" ofApp:app];
    [app.buttons[@"library.browser.done"] tap];
    [app.buttons[@"library.browser"] tap];
    [self openFixture:server route:@"/" inBrowser:app];
    XCTAssertTrue([app.webViews.staticTexts[@"Signed in to test publisher"] waitForExistenceWithTimeout:10]);
  } @finally {
    [app terminate];
    [server stop];
  }
}

- (void)testWebDownloadRequiresPlusAndImportsAuthenticatedComic {
  self.continueAfterFailure = NO;
  NSURL* configuration = [[NSBundle bundleForClass:self.class] URLForResource:@"ComicReader" withExtension:@"storekit"];
  NSError* error;
  SKTestSession* purchaseSession = [[SKTestSession alloc] initWithContentsOfURL:configuration error:&error];
  XCTAssertNotNil(purchaseSession, @"%@", error);
  [purchaseSession resetToDefaultState];
  [purchaseSession clearTransactions];
  purchaseSession.disableDialogs = YES;
  CRBrowserFixtureServer* server = [CRBrowserFixtureServer new];
  [server start];
  XCUIApplication* app = [XCUIApplication new];
  app.launchArguments = self.standardLaunchArguments;
  @try {
    [app launch];
    XCTAssertTrue([self waitForElementToBecomeHittable:app.buttons[@"library.browser"] timeout:15]);
    [app.buttons[@"library.browser"] tap];
    [self openFixture:server route:@"/login" inBrowser:app];
    XCUIElement* download = app.webViews.links[@"Download test comic"];
    XCTAssertTrue([download waitForExistenceWithTimeout:30]);
    [download tap];
    XCUIElement* upsell = app.alerts[@"ComicReader Plus"];
    XCTAssertTrue([upsell waitForExistenceWithTimeout:10]);
    [upsell.buttons[@"View Plus"] tap];
    XCTAssertTrue([self waitForElementToBecomeEnabled:app.cells[@"plus.purchase"] timeout:15]);
    [app.cells[@"plus.purchase"] tap];
    XCTAssertTrue([self waitForPlusToUnlockInApp:app]);
    [app.buttons[@"Done"] tap];
    XCTAssertTrue([download waitForExistenceWithTimeout:10]);
    [download tap];
    XCUIElement* root = app.buttons[@"Library Root  ✓"];
    XCTAssertTrue([self waitForElementToBecomeHittable:root timeout:10]);
    [root tap];
    XCTAssertTrue([root waitForNonExistenceWithTimeout:10]);
    XCUIElement* downloadedComic = app.cells[@"library.browser.download"];
    NSPredicate* imported = [NSPredicate predicateWithFormat:@"exists == YES AND value BEGINSWITH %@", @"Imported"];
    XCTestExpectation* completion = [[XCTNSPredicateExpectation alloc] initWithPredicate:imported object:downloadedComic];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[completion] timeout:30], XCTWaiterResultCompleted);
    [self saveScreenshot:@"Authenticated comic download queue" ofApp:app];
    [app.buttons[@"library.browser.downloads.back"] tap];
    [download tap];
    XCTAssertTrue([self waitForElementToBecomeHittable:root timeout:10]);
    [root tap];
    XCTAssertTrue([root waitForNonExistenceWithTimeout:10]);
    XCUIElement* duplicate = [app.cells matchingPredicate:[NSPredicate predicateWithFormat:
      @"identifier == %@ AND value BEGINSWITH %@", @"library.browser.download", @"Already in library"]].firstMatch;
    XCTAssertTrue([duplicate waitForExistenceWithTimeout:30]);
    [duplicate tap];
    [app.buttons[@"Open Comic"] tap];
    XCTAssertTrue([app.otherElements[@"reader.canvas"] waitForExistenceWithTimeout:15]);
    XCTAssertTrue([app.staticTexts[@"Please Wait…"] waitForNonExistenceWithTimeout:15]);
    XCTAssertTrue([self waitForElementToBecomeHittable:app.otherElements[@"reader.canvas"] timeout:10]);
    [self saveScreenshot:@"Downloaded comic opened in reader" ofApp:app];
  } @finally {
    [app terminate];
    [server stop];
    [purchaseSession clearTransactions];
    [purchaseSession resetToDefaultState];
  }
}
@end
