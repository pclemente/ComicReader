#import <Foundation/Foundation.h>
#import <GCDWebServers/GCDWebDAVServer.h>
#import <GCDWebServers/GCDWebUploader.h>
#import <GCDWebServers/GCDWebServerHTTPStatusCodes.h>
#import <GCDWebServers/GCDWebServerRequest.h>
#import <GCDWebServers/GCDWebServerResponse.h>

@interface GCDWebUploader (PathHarness)
- (NSString*)_absolutePathForRelativePath:(NSString*)relativePath allowRoot:(BOOL)allowRoot;
@end

@interface GCDWebDAVServer (PathHarness)
- (NSString*)_absolutePathForRelativePath:(NSString*)relativePath allowRoot:(BOOL)allowRoot;
- (GCDWebServerResponse*)performCOPY:(GCDWebServerRequest*)request isMove:(BOOL)isMove;
@end

static void Check(BOOL condition, NSString* message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static void CheckServer(id server, NSString* root) {
  NSString* child = [root stringByAppendingPathComponent:@"comic.cbz"];
  Check([[server _absolutePathForRelativePath:@"/" allowRoot:YES] isEqualToString:root], @"root must remain readable");
  Check([server _absolutePathForRelativePath:@"/" allowRoot:NO] == nil, @"slash root mutation must be rejected");
  Check([server _absolutePathForRelativePath:@"" allowRoot:NO] == nil, @"empty root mutation must be rejected");
  Check([server _absolutePathForRelativePath:@"." allowRoot:NO] == nil, @"dot root mutation must be rejected");
  Check([server _absolutePathForRelativePath:@".." allowRoot:NO] == nil, @"dot-dot root mutation must be rejected");
  Check([[server _absolutePathForRelativePath:@"nested/../comic.cbz" allowRoot:NO] isEqualToString:child], @"dot components must normalize inside root");
  Check([[server _absolutePathForRelativePath:@"../comic.cbz" allowRoot:NO] isEqualToString:child], @"leading traversal must not escape root");
  Check([server _absolutePathForRelativePath:nil allowRoot:YES] == nil, @"nil path must be rejected");
  unichar nullCharacter = 0;
  NSString* malformed = [NSString stringWithCharacters:&nullCharacter length:1];
  Check([server _absolutePathForRelativePath:malformed allowRoot:YES] == nil, @"control-character path must be rejected");
}

static GCDWebServerRequest* CopyRequest(NSString* source, NSString* destination) {
  NSDictionary* headers = @{
    @"Host": @"localhost",
    @"Destination": [@"http://localhost" stringByAppendingString:destination],
    @"Overwrite": @"T"
  };
  return [[GCDWebServerRequest alloc] initWithMethod:@"MOVE"
                                                url:[NSURL URLWithString:[@"http://localhost" stringByAppendingString:source]]
                                            headers:headers
                                               path:source
                                              query:@{}];
}

static void CheckUnsafeCopyDestinations(GCDWebDAVServer* server, NSString* root) {
  NSData* comicData = [@"comic" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* comic = [root stringByAppendingPathComponent:@"comic.cbz"];
  Check([comicData writeToFile:comic atomically:YES], @"create comic fixture");
  for (NSNumber* move in @[@NO, @YES]) {
    GCDWebServerResponse* response = [server performCOPY:CopyRequest(@"/comic.cbz", @"/comic.cbz") isMove:move.boolValue];
    Check(response.statusCode == kGCDWebServerHTTPStatusCode_Forbidden, @"same-path COPY and MOVE must be rejected");
    Check([[NSData dataWithContentsOfFile:comic] isEqualToData:comicData], @"same-path COPY and MOVE must preserve source bytes");
  }

  NSString* child = [root stringByAppendingPathComponent:@"series/child"];
  Check([[NSFileManager defaultManager] createDirectoryAtPath:child withIntermediateDirectories:YES attributes:nil error:NULL], @"create nested directory fixture");
  NSData* pageData = [@"page" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* page = [child stringByAppendingPathComponent:@"page.jpg"];
  Check([pageData writeToFile:page atomically:YES], @"create nested file fixture");
  for (NSNumber* move in @[@NO, @YES]) {
    GCDWebServerResponse* response = [server performCOPY:CopyRequest(@"/series", @"/series/child") isMove:move.boolValue];
    Check(response.statusCode == kGCDWebServerHTTPStatusCode_Forbidden, @"descendant COPY and MOVE must be rejected");
    Check([[NSData dataWithContentsOfFile:page] isEqualToData:pageData], @"descendant COPY and MOVE must preserve child bytes");
  }

  for (NSNumber* move in @[@NO, @YES]) {
    GCDWebServerResponse* response = [server performCOPY:CopyRequest(@"/series/child", @"/series") isMove:move.boolValue];
    Check(response.statusCode == kGCDWebServerHTTPStatusCode_Forbidden, @"directory-to-ancestor COPY and MOVE must be rejected");
    Check([[NSData dataWithContentsOfFile:page] isEqualToData:pageData], @"directory-to-ancestor COPY and MOVE must preserve child bytes");
  }

  for (NSNumber* move in @[@NO, @YES]) {
    GCDWebServerResponse* response = [server performCOPY:CopyRequest(@"/series/child/page.jpg", @"/series") isMove:move.boolValue];
    Check(response.statusCode == kGCDWebServerHTTPStatusCode_Forbidden, @"file-to-ancestor COPY and MOVE must be rejected");
    Check([[NSData dataWithContentsOfFile:page] isEqualToData:pageData], @"file-to-ancestor COPY and MOVE must preserve source bytes");
  }
}

int main(void) {
  @autoreleasepool {
    NSString* container = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    NSString* root = [container stringByAppendingPathComponent:@"root"];
    NSError* error = nil;
    Check([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&error], error.description);

    GCDWebUploader* uploader = [[GCDWebUploader alloc] initWithUploadDirectory:root];
    GCDWebDAVServer* dav = [[GCDWebDAVServer alloc] initWithUploadDirectory:root];
    Check(uploader != nil, @"uploader initialization");
    Check(dav != nil, @"DAV initialization");
    CheckServer(uploader, root);
    CheckServer(dav, root);
    CheckUnsafeCopyDestinations(dav, root);

    Check([[NSFileManager defaultManager] fileExistsAtPath:root], @"root must survive all checks");
    Check([[NSFileManager defaultManager] removeItemAtPath:container error:&error], error.description);
    puts("PASS: uploader and DAV path boundaries");
  }
  return 0;
}
