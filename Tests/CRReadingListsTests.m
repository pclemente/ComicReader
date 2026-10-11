#import <XCTest/XCTest.h>

#import "CRReadingLists.h"
#import "Library.h"

@interface CRReadingListsFakeLibraryConnection : LibraryConnection
@property(nonatomic, copy) NSArray<Comic*>* comics;
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* pathsByComicName;
@end

@implementation CRReadingListsFakeLibraryConnection
- (NSArray*)fetchAllComicsByName {
  return self.comics ?: @[];
}
- (NSString*)pathForComic:(Comic*)comic {
  return self.pathsByComicName[comic.name];
}
@end

@interface CRReadingListsTests : XCTestCase
@property(nonatomic, strong) NSURL* temporaryRootURL;
@property(nonatomic, strong) NSURL* storageURL;
@property(nonatomic, strong) CRReadingListsFakeLibraryConnection* library;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* entitlement;
@end

@implementation CRReadingListsTests

- (void)setUp {
  [super setUp];
  NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [@"CRReadingListsTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  self.temporaryRootURL = [NSURL fileURLWithPath:directory isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtURL:self.temporaryRootURL
                                          withIntermediateDirectories:YES attributes:nil error:NULL]);
  self.storageURL = [self.temporaryRootURL URLByAppendingPathComponent:@"metadata/reading-lists.json"];
  self.library = [[CRReadingListsFakeLibraryConnection alloc] initWithDatabaseAtPath:nil];
  XCTAssertNotNil(self.library);
  self.entitlement = [@{ @"allowed": @YES } mutableCopy];
}

- (void)tearDown {
  [[NSFileManager defaultManager] removeItemAtURL:self.temporaryRootURL error:NULL];
  self.library = nil;
  self.entitlement = nil;
  self.storageURL = nil;
  self.temporaryRootURL = nil;
  [super tearDown];
}

- (CRReadingListsStore*)newStore {
  NSMutableDictionary* entitlement = self.entitlement;
  return [[CRReadingListsStore alloc] initWithStorageURL:self.storageURL
                                         libraryRootURL:self.temporaryRootURL
                                      libraryConnection:self.library
                                 editingAllowedProvider:^BOOL{
    return [entitlement[@"allowed"] boolValue];
  }];
}

- (Comic*)comicNamed:(NSString*)name relativePath:(NSString*)relativePath bytes:(NSData*)bytes {
  NSURL* url = [self.temporaryRootURL URLByAppendingPathComponent:relativePath];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent
                                          withIntermediateDirectories:YES attributes:nil error:NULL]);
  XCTAssertTrue([bytes writeToURL:url atomically:YES]);
  Comic* comic = [[Comic alloc] init];
  comic.name = name;
  NSMutableArray* comics = [self.library.comics mutableCopy] ?: [NSMutableArray array];
  [comics addObject:comic];
  self.library.comics = comics;
  NSMutableDictionary* paths = [self.library.pathsByComicName mutableCopy] ?: [NSMutableDictionary dictionary];
  paths[name] = url.path;
  self.library.pathsByComicName = paths;
  return comic;
}

- (Comic*)comicNamed:(NSString*)name bytes:(NSData*)bytes {
  return [self comicNamed:name relativePath:name bytes:bytes];
}

- (CRReadingList*)createListNamed:(NSString*)name store:(CRReadingListsStore*)store {
  NSError* error = nil;
  CRReadingList* list = nil;
  XCTAssertTrue([store createListNamed:name createdList:&list error:&error], @"%@", error);
  XCTAssertNotNil(list);
  return list;
}

- (void)testSmartQueuesRefreshMembershipAcrossFoldersInNameOrder {
  Comic* zebra = [self comicNamed:@"Zebra.cbz" relativePath:@"Series Z/Zebra.cbz"
                            bytes:[@"zebra" dataUsingEncoding:NSUTF8StringEncoding]];
  Comic* alpha = [self comicNamed:@"Alpha.pdf" relativePath:@"Series A/Alpha.pdf"
                            bytes:[@"alpha" dataUsingEncoding:NSUTF8StringEncoding]];
  Comic* done = [self comicNamed:@"Done.pdf" relativePath:@"Archives/Done.pdf"
                           bytes:[@"done" dataUsingEncoding:NSUTF8StringEncoding]];
  Comic* beta = [self comicNamed:@"Beta.cbz" relativePath:@"Incoming/Beta.cbz"
                           bytes:[@"beta" dataUsingEncoding:NSUTF8StringEncoding]];
  zebra.status = 8;
  alpha.status = 2;
  done.status = 0;
  beta.status = -1;

  CRReadingListsStore* store = [self newStore];
  [store refreshLibraryState];
  XCTAssertEqual(store.smartQueues.count, 3u);
  XCTAssertEqualObjects([store.smartQueues valueForKey:@"name"],
                        (@[@"Continue Reading", @"Unread", @"Read Again"]));

  NSError* error = nil;
  NSArray<Comic*>* reading = [store comicsForSmartQueue:
    [store smartQueueWithKind:CRReadingSmartQueueKindContinueReading] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects([reading valueForKey:@"name"], (@[@"Alpha.pdf", @"Zebra.cbz"]));
  NSArray<Comic*>* unread = [store comicsForSmartQueue:
    [store smartQueueWithKind:CRReadingSmartQueueKindUnread] error:&error];
  XCTAssertEqualObjects([unread valueForKey:@"name"], (@[@"Beta.cbz"]));
  NSArray<Comic*>* finished = [store comicsForSmartQueue:
    [store smartQueueWithKind:CRReadingSmartQueueKindFinished] error:&error];
  XCTAssertEqualObjects([finished valueForKey:@"name"], (@[@"Done.pdf"]));

  alpha.status = 0;
  beta.status = 3;
  [store refreshLibraryState];
  reading = [store comicsForSmartQueue:
    [store smartQueueWithKind:CRReadingSmartQueueKindContinueReading] error:&error];
  XCTAssertEqualObjects([reading valueForKey:@"name"], (@[@"Beta.cbz", @"Zebra.cbz"]));
  XCTAssertEqual([store smartQueueWithKind:CRReadingSmartQueueKindUnread].comicCount, 0u);
  finished = [store comicsForSmartQueue:
    [store smartQueueWithKind:CRReadingSmartQueueKindFinished] error:&error];
  XCTAssertEqualObjects([finished valueForKey:@"name"], (@[@"Alpha.pdf", @"Done.pdf"]));
}

- (void)testSmartQueueCountsRemainVisibleButOpeningIsPlusGatedAndQueuesAreNotPersisted {
  Comic* comic = [self comicNamed:@"Preview.pdf" relativePath:@"Folder/Preview.pdf"
                            bytes:[@"preview" dataUsingEncoding:NSUTF8StringEncoding]];
  comic.status = 4;
  CRReadingListsStore* store = [self newStore];
  [self createListNamed:@"Saved" store:store];
  [store refreshLibraryState];
  XCTAssertEqual([store smartQueueWithKind:CRReadingSmartQueueKindContinueReading].comicCount, 1u);

  NSDictionary* document = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:self.storageURL]
                                                            options:0 error:NULL];
  XCTAssertEqual([document[@"lists"] count], 1u);
  XCTAssertNil(document[@"smartQueues"]);

  self.entitlement[@"allowed"] = @NO;
  [store refreshLibraryState];
  CRReadingSmartQueue* preview = [store smartQueueWithKind:CRReadingSmartQueueKindContinueReading];
  XCTAssertEqual(preview.comicCount, 1u);
  NSError* error = nil;
  XCTAssertNil([store comicsForSmartQueue:preview error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorSmartQueuesRequirePlus);
  XCTAssertEqualObjects(store.lists.firstObject.name, @"Saved");
}

- (void)testCRUDOrderingAndPersistenceDoNotModifyComicFiles {
  NSData* firstData = [@"first comic bytes" dataUsingEncoding:NSUTF8StringEncoding];
  NSData* secondData = [@"second comic bytes" dataUsingEncoding:NSUTF8StringEncoding];
  Comic* firstComic = [self comicNamed:@"First.pdf" bytes:firstData];
  Comic* secondComic = [self comicNamed:@"Second.cbz" bytes:secondData];
  NSString* firstPath = self.library.pathsByComicName[firstComic.name];
  NSString* secondPath = self.library.pathsByComicName[secondComic.name];

  CRReadingListsStore* store = [self newStore];
  CRReadingList* firstList = [self createListNamed:@"Weekend" store:store];
  CRReadingList* secondList = [self createListNamed:@"Archive" store:store];
  NSError* error = nil;
  XCTAssertFalse([store createListNamed:@"  wEeKeNd  " createdList:NULL error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorDuplicateName);

  error = nil;
  XCTAssertTrue([store addComic:firstComic toList:firstList error:&error], @"%@", error);
  XCTAssertTrue([store addComic:secondComic toList:firstList error:&error], @"%@", error);
  XCTAssertFalse([store addComic:firstComic toList:firstList error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorComicAlreadyPresent);
  XCTAssertTrue([store moveItemInList:firstList fromIndex:1 toIndex:0 error:&error], @"%@", error);
  XCTAssertTrue([store renameList:secondList toName:@"Later" error:&error], @"%@", error);
  XCTAssertTrue([store moveListFromIndex:1 toIndex:0 error:&error], @"%@", error);

  CRReadingListsStore* reloaded = [self newStore];
  XCTAssertNil(reloaded.loadError);
  XCTAssertEqual(reloaded.lists.count, 2u);
  XCTAssertEqualObjects(reloaded.lists[0].name, @"Later");
  XCTAssertEqualObjects(reloaded.lists[1].name, @"Weekend");
  XCTAssertEqualObjects(reloaded.lists[1].items[0].displayName, secondComic.name);
  XCTAssertEqualObjects(reloaded.lists[1].items[1].displayName, firstComic.name);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:firstPath], firstData);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:secondPath], secondData);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:firstPath]);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:secondPath]);
}

- (void)testRevokedEntitlementKeepsSavedListsReadableButBlocksEveryEdit {
  Comic* comic = [self comicNamed:@"Readable.pdf" bytes:[@"comic" dataUsingEncoding:NSUTF8StringEncoding]];
  CRReadingListsStore* unlockedStore = [self newStore];
  CRReadingList* list = [self createListNamed:@"Saved" store:unlockedStore];
  NSError* error = nil;
  XCTAssertTrue([unlockedStore addComic:comic toList:list error:&error], @"%@", error);

  self.entitlement[@"allowed"] = @NO;
  CRReadingListsStore* lockedStore = [self newStore];
  [lockedStore refreshLibraryState];
  CRReadingList* saved = lockedStore.lists.firstObject;
  XCTAssertEqualObjects(saved.name, @"Saved");
  XCTAssertEqual([lockedStore availabilityForItem:saved.items.firstObject], CRReadingListItemAvailabilityAvailable);
  XCTAssertNotNil([lockedStore comicForItem:saved.items.firstObject]);

  CRReadingList* created = nil;
  XCTAssertFalse([lockedStore createListNamed:@"Blocked" createdList:&created error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorEditingRequiresPlus);
  XCTAssertFalse([lockedStore renameList:saved toName:@"Blocked" error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorEditingRequiresPlus);
  XCTAssertFalse([lockedStore addComic:comic toList:saved error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorEditingRequiresPlus);
  XCTAssertFalse([lockedStore removeItemAtIndex:0 fromList:saved error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorEditingRequiresPlus);
  XCTAssertFalse([lockedStore moveItemInList:saved fromIndex:0 toIndex:0 error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorEditingRequiresPlus);
  XCTAssertFalse([lockedStore moveListFromIndex:0 toIndex:0 error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorEditingRequiresPlus);
  XCTAssertFalse([lockedStore removeList:saved error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorEditingRequiresPlus);
  XCTAssertEqual(lockedStore.lists.count, 1u);
}

- (void)testMoveKeepsIdentityButSamePathReplacementIsNeverRelinked {
  NSMutableData* originalData = [NSMutableData dataWithLength:4096];
  ((uint8_t*)originalData.mutableBytes)[2048] = 0x42;
  Comic* comic = [self comicNamed:@"Identity.pdf" bytes:originalData];
  NSString* originalPath = self.library.pathsByComicName[comic.name];
  NSDate* fixedModificationDate = [NSDate dateWithTimeIntervalSince1970:1700000000.0];
  NSError* error = nil;
  XCTAssertTrue([[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: fixedModificationDate}
                                                       ofItemAtPath:originalPath error:&error], @"%@", error);
  CRReadingListsStore* store = [self newStore];
  CRReadingList* list = [self createListNamed:@"Identity" store:store];
  XCTAssertTrue([store addComic:comic toList:list error:&error], @"%@", error);
  CRReadingListItem* item = list.items.firstObject;

  NSString* oldPath = originalPath;
  NSString* movedPath = [self.temporaryRootURL URLByAppendingPathComponent:@"Moved.pdf"].path;
  XCTAssertTrue([[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:movedPath error:&error], @"%@", error);
  self.library.pathsByComicName = @{ comic.name: movedPath };
  [store refreshLibraryState];
  XCTAssertEqual([store availabilityForItem:item], CRReadingListItemAvailabilityAvailable);
  XCTAssertNotNil([store comicForItem:item]);

  NSDictionary* oldAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:movedPath error:NULL];
  NSMutableData* replacementData = [originalData mutableCopy];
  ((uint8_t*)replacementData.mutableBytes)[2048] ^= 0xff;
  NSString* replacementPath = [self.temporaryRootURL URLByAppendingPathComponent:@"Replacement.pdf"].path;
  XCTAssertTrue([replacementData writeToFile:replacementPath atomically:NO]);
  XCTAssertTrue([[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: oldAttributes[NSFileModificationDate]}
                                                       ofItemAtPath:replacementPath error:&error], @"%@", error);
  XCTAssertTrue([[NSFileManager defaultManager] replaceItemAtURL:[NSURL fileURLWithPath:movedPath]
                                                    withItemAtURL:[NSURL fileURLWithPath:replacementPath]
                                                   backupItemName:nil
                                                          options:NSFileManagerItemReplacementUsingNewMetadataOnly
                                                 resultingItemURL:NULL
                                                            error:&error], @"%@", error);
  XCTAssertTrue([[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: oldAttributes[NSFileModificationDate]}
                                                       ofItemAtPath:movedPath error:&error], @"%@", error);
  NSDictionary* newAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:movedPath error:NULL];
  XCTAssertEqualObjects(oldAttributes[NSFileSize], newAttributes[NSFileSize]);
  XCTAssertEqualObjects(oldAttributes[NSFileModificationDate], newAttributes[NSFileModificationDate]);
  XCTAssertNotEqualObjects(oldAttributes[NSFileSystemFileNumber], newAttributes[NSFileSystemFileNumber]);

  [store refreshLibraryState];
  XCTAssertEqual([store availabilityForItem:item], CRReadingListItemAvailabilityMissingOrChanged);
  XCTAssertNil([store comicForItem:item]);
  XCTAssertEqualObjects(item.relativePath, @"Identity.pdf");
}

- (void)testMissingFileStaysVisibleAndCanBeRemovedWhenUnlocked {
  Comic* comic = [self comicNamed:@"Missing.pdf" bytes:[@"gone" dataUsingEncoding:NSUTF8StringEncoding]];
  CRReadingListsStore* store = [self newStore];
  CRReadingList* list = [self createListNamed:@"Missing" store:store];
  NSError* error = nil;
  XCTAssertTrue([store addComic:comic toList:list error:&error], @"%@", error);
  XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:self.library.pathsByComicName[comic.name] error:&error]);
  [store refreshLibraryState];
  XCTAssertEqual(list.items.count, 1u);
  XCTAssertEqual([store availabilityForItem:list.items.firstObject], CRReadingListItemAvailabilityMissingOrChanged);
  XCTAssertNil([store comicForItem:list.items.firstObject]);
  XCTAssertTrue([store removeItemAtIndex:0 fromList:list error:&error], @"%@", error);
  XCTAssertEqual(list.items.count, 0u);
}

- (void)testInvalidDocumentIsNotSilentlyOverwritten {
  NSData* invalidData = [@"not json" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtURL:self.storageURL.URLByDeletingLastPathComponent
                                          withIntermediateDirectories:YES attributes:nil error:NULL]);
  XCTAssertTrue([invalidData writeToURL:self.storageURL atomically:YES]);
  CRReadingListsStore* store = [self newStore];
  XCTAssertNotNil(store.loadError);
  NSError* error = nil;
  XCTAssertFalse([store createListNamed:@"Would overwrite" createdList:NULL error:&error]);
  XCTAssertEqual(error.code, CRReadingListsErrorInvalidData);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:self.storageURL], invalidData);
}

@end
