#import "CRReadingLists.h"

#import <CommonCrypto/CommonDigest.h>

#import "ComicFlow-Swift.h"
#import "Library.h"

NSErrorDomain const CRReadingListsErrorDomain = @"com.pabloclementeperez.ComicReader.ReadingLists";
NSNotificationName const CRReadingListsDidChangeNotification = @"CRReadingListsDidChangeNotification";

static NSUInteger const CRReadingListsSchemaVersion = 1;
static NSUInteger const CRReadingListMaximumNameLength = 100;
static NSUInteger const CRReadingListFingerprintChunkLength = 64 * 1024;

static NSError* CRReadingListsError(CRReadingListsErrorCode code, NSString* description, NSError* underlyingError) {
  NSMutableDictionary* userInfo = [NSMutableDictionary dictionaryWithObject:description
                                                                      forKey:NSLocalizedDescriptionKey];
  if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
  return [NSError errorWithDomain:CRReadingListsErrorDomain code:code userInfo:userInfo];
}

static NSString* CRReadingListNormalizedName(NSString* value) {
  if (![value isKindOfClass:[NSString class]]) return nil;
  NSString* trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!trimmed.length || trimmed.length > CRReadingListMaximumNameLength) return nil;
  return [trimmed precomposedStringWithCanonicalMapping];
}

static BOOL CRReadingListNamesEqual(NSString* left, NSString* right) {
  NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
  return [left compare:right options:options range:NSMakeRange(0, left.length) locale:[NSLocale currentLocale]] == NSOrderedSame;
}

static NSString* CRReadingListFileSystemIdentity(NSDictionary<NSFileAttributeKey, id>* attributes) {
  NSNumber* systemNumber = attributes[NSFileSystemNumber];
  NSNumber* fileNumber = attributes[NSFileSystemFileNumber];
  if (![systemNumber isKindOfClass:[NSNumber class]] || ![fileNumber isKindOfClass:[NSNumber class]]) return nil;
  return [NSString stringWithFormat:@"%@:%@", systemNumber.stringValue, fileNumber.stringValue];
}

static NSNumber* CRReadingListTimestamp(NSDictionary<NSFileAttributeKey, id>* attributes, NSFileAttributeKey key) {
  NSDate* date = attributes[key];
  return [date isKindOfClass:[NSDate class]] ? @(date.timeIntervalSince1970) : nil;
}

static BOOL CRReadingListTimestampsEqual(NSNumber* expected, NSNumber* actual) {
  if (!expected) return YES;
  return actual && fabs(expected.doubleValue - actual.doubleValue) <= 0.001;
}

static void CRReadingListUpdateDigest(CC_SHA256_CTX* context, uint64_t value) {
  uint64_t bigEndian = CFSwapInt64HostToBig(value);
  CC_SHA256_Update(context, &bigEndian, (CC_LONG)sizeof(bigEndian));
}

/** A bounded fallback for file systems that do not expose a stable device/inode pair. */
static NSString* CRReadingListSampleDigest(NSString* path, unsigned long long fileSize, NSError** error) {
  NSError* openError = nil;
  NSFileHandle* handle = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path] error:&openError];
  if (!handle) {
    if (error) *error = openError;
    return nil;
  }

  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  CRReadingListUpdateDigest(&context, fileSize);

  unsigned long long chunkLength = MIN((unsigned long long)CRReadingListFingerprintChunkLength, fileSize);
  NSMutableOrderedSet<NSNumber*>* offsets = [NSMutableOrderedSet orderedSetWithObject:@0];
  if (fileSize > chunkLength) {
    [offsets addObject:@((fileSize - chunkLength) / 2)];
    [offsets addObject:@(fileSize - chunkLength)];
  }

  for (NSNumber* offsetNumber in offsets) {
    unsigned long long offset = offsetNumber.unsignedLongLongValue;
    NSError* seekError = nil;
    if (![handle seekToOffset:offset error:&seekError]) {
      [handle closeFile];
      if (error) *error = seekError;
      return nil;
    }
    NSError* readError = nil;
    NSData* data = [handle readDataUpToLength:(NSUInteger)chunkLength error:&readError];
    if (!data || readError) {
      [handle closeFile];
      if (error) *error = readError;
      return nil;
    }
    CRReadingListUpdateDigest(&context, offset);
    CRReadingListUpdateDigest(&context, data.length);
    CC_SHA256_Update(&context, data.bytes, (CC_LONG)data.length);
  }
  [handle closeFile];

  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  NSMutableString* result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
    [result appendFormat:@"%02x", digest[index]];
  }
  return result;
}

@interface CRReadingListItem ()
@property(nonatomic, readwrite, copy) NSString* identifier;
@property(nonatomic, readwrite, copy) NSString* displayName;
@property(nonatomic, readwrite, copy) NSString* relativePath;
@property(nonatomic, copy) NSString* fileSystemIdentity;
@property(nonatomic, strong) NSNumber* fileSize;
@property(nonatomic, strong) NSNumber* modifiedAt;
@property(nonatomic, strong) NSNumber* createdAt;
@property(nonatomic, copy) NSString* sampleDigest;
- (instancetype)initWithDictionary:(NSDictionary*)dictionary error:(NSError**)error;
- (NSDictionary*)dictionaryRepresentation;
@end

@interface CRReadingList ()
@property(nonatomic, readwrite, copy) NSString* identifier;
@property(nonatomic, readwrite, copy) NSString* name;
@property(nonatomic, strong) NSMutableArray<CRReadingListItem*>* mutableItems;
- (instancetype)initWithDictionary:(NSDictionary*)dictionary error:(NSError**)error;
- (NSDictionary*)dictionaryRepresentation;
@end

@interface CRReadingListCandidate : NSObject
@property(nonatomic, strong) Comic* comic;
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSString* relativePath;
@property(nonatomic, copy) NSString* fileSystemIdentity;
@property(nonatomic, strong) NSDictionary<NSFileAttributeKey, id>* attributes;
@end

@implementation CRReadingListCandidate
@end

@implementation CRReadingListItem

- (instancetype)initWithDictionary:(NSDictionary*)dictionary error:(NSError**)error {
  if ((self = [super init])) {
    NSString* identifier = dictionary[@"id"];
    NSString* displayName = dictionary[@"displayName"];
    NSString* relativePath = dictionary[@"relativePath"];
    NSNumber* fileSize = dictionary[@"fileSize"];
    NSNumber* modifiedAt = dictionary[@"modifiedAt"];
    NSNumber* createdAt = dictionary[@"createdAt"];
    NSString* fileSystemIdentity = dictionary[@"fileSystemIdentity"];
    NSString* sampleDigest = dictionary[@"sampleDigest"];
    BOOL validIdentifier = [identifier isKindOfClass:[NSString class]] &&
      [[NSUUID alloc] initWithUUIDString:identifier] != nil;
    BOOL valid = validIdentifier &&
      [displayName isKindOfClass:[NSString class]] && displayName.length > 0 &&
      [relativePath isKindOfClass:[NSString class]] && relativePath.length > 0 &&
      [fileSize isKindOfClass:[NSNumber class]] && fileSize.longLongValue >= 0 &&
      [modifiedAt isKindOfClass:[NSNumber class]] &&
      (!createdAt || [createdAt isKindOfClass:[NSNumber class]]) &&
      (!fileSystemIdentity || [fileSystemIdentity isKindOfClass:[NSString class]]) &&
      (!sampleDigest || ([sampleDigest isKindOfClass:[NSString class]] && sampleDigest.length == CC_SHA256_DIGEST_LENGTH * 2)) &&
      (fileSystemIdentity.length > 0 || sampleDigest.length > 0);
    if (!valid) {
      if (error) *error = CRReadingListsError(CRReadingListsErrorInvalidData,
                                              @"The reading lists file contains an invalid comic reference.", nil);
      return nil;
    }
    _identifier = [identifier copy];
    _displayName = [displayName copy];
    _relativePath = [relativePath copy];
    _fileSystemIdentity = [fileSystemIdentity copy];
    _fileSize = fileSize;
    _modifiedAt = modifiedAt;
    _createdAt = createdAt;
    _sampleDigest = [sampleDigest copy];
  }
  return self;
}

- (NSDictionary*)dictionaryRepresentation {
  NSMutableDictionary* dictionary = [@{
    @"id": self.identifier,
    @"displayName": self.displayName,
    @"relativePath": self.relativePath,
    @"fileSize": self.fileSize,
    @"modifiedAt": self.modifiedAt,
  } mutableCopy];
  if (self.createdAt) dictionary[@"createdAt"] = self.createdAt;
  if (self.fileSystemIdentity) dictionary[@"fileSystemIdentity"] = self.fileSystemIdentity;
  if (self.sampleDigest) dictionary[@"sampleDigest"] = self.sampleDigest;
  return dictionary;
}

@end

@implementation CRReadingList

- (instancetype)initWithDictionary:(NSDictionary*)dictionary error:(NSError**)error {
  if ((self = [super init])) {
    NSString* identifier = dictionary[@"id"];
    NSString* name = CRReadingListNormalizedName(dictionary[@"name"]);
    NSArray* itemDictionaries = dictionary[@"items"];
    BOOL validIdentifier = [identifier isKindOfClass:[NSString class]] &&
      [[NSUUID alloc] initWithUUIDString:identifier] != nil;
    if (!validIdentifier || !name || ![itemDictionaries isKindOfClass:[NSArray class]]) {
      if (error) *error = CRReadingListsError(CRReadingListsErrorInvalidData,
                                              @"The reading lists file contains an invalid list.", nil);
      return nil;
    }
    NSMutableArray* items = [NSMutableArray arrayWithCapacity:itemDictionaries.count];
    NSMutableSet<NSString*>* identifiers = [NSMutableSet set];
    for (id itemDictionary in itemDictionaries) {
      if (![itemDictionary isKindOfClass:[NSDictionary class]]) {
        if (error) *error = CRReadingListsError(CRReadingListsErrorInvalidData,
                                                @"The reading lists file contains an invalid comic reference.", nil);
        return nil;
      }
      CRReadingListItem* item = [[CRReadingListItem alloc] initWithDictionary:itemDictionary error:error];
      if (!item || [identifiers containsObject:item.identifier]) {
        if (item && error) *error = CRReadingListsError(CRReadingListsErrorInvalidData,
                                                        @"The reading lists file contains duplicate comic references.", nil);
        return nil;
      }
      [identifiers addObject:item.identifier];
      [items addObject:item];
    }
    _identifier = [identifier copy];
    _name = [name copy];
    _mutableItems = items;
  }
  return self;
}

- (NSArray<CRReadingListItem*>*)items {
  return [self.mutableItems copy];
}

- (NSDictionary*)dictionaryRepresentation {
  NSMutableArray* items = [NSMutableArray arrayWithCapacity:self.mutableItems.count];
  for (CRReadingListItem* item in self.mutableItems) [items addObject:item.dictionaryRepresentation];
  return @{ @"id": self.identifier, @"name": self.name, @"items": items };
}

@end

@interface CRReadingSmartQueue ()
@property(nonatomic, readwrite) CRReadingSmartQueueKind kind;
@property(nonatomic, readwrite, copy) NSString* identifier;
@property(nonatomic, readwrite, copy) NSString* name;
@property(nonatomic, readwrite) NSUInteger comicCount;
@property(nonatomic, copy) NSArray<Comic*>* comics;
- (instancetype)initWithKind:(CRReadingSmartQueueKind)kind
                   identifier:(NSString*)identifier
                         name:(NSString*)name
                       comics:(NSArray<Comic*>*)comics;
@end

@implementation CRReadingSmartQueue

- (instancetype)initWithKind:(CRReadingSmartQueueKind)kind
                   identifier:(NSString*)identifier
                         name:(NSString*)name
                       comics:(NSArray<Comic*>*)comics {
  if ((self = [super init])) {
    _kind = kind;
    _identifier = [identifier copy];
    _name = [name copy];
    _comics = [comics copy] ?: @[];
    _comicCount = _comics.count;
  }
  return self;
}

@end

@interface CRReadingListsStore ()
@property(nonatomic, readwrite, strong) NSURL* storageURL;
@property(nonatomic, readwrite, strong) NSURL* libraryRootURL;
@property(nonatomic, readwrite, strong) LibraryConnection* libraryConnection;
@property(nonatomic, readwrite, strong) NSError* loadError;
@property(nonatomic, copy) CRReadingListsEditingAllowedProvider editingAllowedProvider;
@property(nonatomic, strong) NSMutableArray<CRReadingList*>* mutableLists;
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* resolvedComics;
@property(nonatomic, copy) NSArray<CRReadingSmartQueue*>* currentSmartQueues;
@end

@implementation CRReadingListsStore

- (instancetype)initWithLibraryConnection:(LibraryConnection*)libraryConnection {
  NSURL* storageURL = [NSURL fileURLWithPath:[[LibraryConnection libraryApplicationDataPath]
    stringByAppendingPathComponent:@"reading-lists-v1.json"]];
  NSURL* rootURL = [NSURL fileURLWithPath:[LibraryConnection libraryRootPath] isDirectory:YES];
  return [self initWithStorageURL:storageURL
                  libraryRootURL:rootURL
               libraryConnection:libraryConnection
          editingAllowedProvider:^BOOL{
    return [CRPlusStore sharedStore].isUnlocked;
  }];
}

- (instancetype)initWithStorageURL:(NSURL*)storageURL
                     libraryRootURL:(NSURL*)libraryRootURL
                  libraryConnection:(LibraryConnection*)libraryConnection
             editingAllowedProvider:(CRReadingListsEditingAllowedProvider)editingAllowedProvider {
  NSParameterAssert(storageURL.isFileURL);
  NSParameterAssert(libraryRootURL.isFileURL);
  NSParameterAssert(libraryConnection);
  NSParameterAssert(editingAllowedProvider);
  if ((self = [super init])) {
    _storageURL = storageURL;
    _libraryRootURL = libraryRootURL.URLByStandardizingPath;
    _libraryConnection = libraryConnection;
    _editingAllowedProvider = [editingAllowedProvider copy];
    _mutableLists = [NSMutableArray array];
    _resolvedComics = [NSMutableDictionary dictionary];
    [self reloadWithError:NULL];
  }
  return self;
}

- (NSArray<CRReadingList*>*)lists {
  return [self.mutableLists copy];
}

- (NSArray<CRReadingSmartQueue*>*)smartQueues {
  if (!self.currentSmartQueues) [self refreshLibraryState];
  return self.currentSmartQueues ?: @[];
}

- (BOOL)isEditingAllowed {
  return self.editingAllowedProvider ? self.editingAllowedProvider() : NO;
}

- (BOOL)isSmartQueueAccessAllowed {
  return self.isEditingAllowed;
}

- (BOOL)reloadWithError:(NSError**)error {
  NSFileManager* manager = [NSFileManager defaultManager];
  if (![manager fileExistsAtPath:self.storageURL.path]) {
    self.mutableLists = [NSMutableArray array];
    self.resolvedComics = [NSMutableDictionary dictionary];
    self.loadError = nil;
    if (error) *error = nil;
    return YES;
  }

  NSError* readError = nil;
  NSData* data = [NSData dataWithContentsOfURL:self.storageURL options:0 error:&readError];
  id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&readError] : nil;
  if (![root isKindOfClass:[NSDictionary class]] ||
      ![root[@"schemaVersion"] isKindOfClass:[NSNumber class]] ||
      [root[@"schemaVersion"] unsignedIntegerValue] != CRReadingListsSchemaVersion ||
      ![root[@"lists"] isKindOfClass:[NSArray class]]) {
    NSError* invalid = CRReadingListsError(CRReadingListsErrorInvalidData,
                                           @"The saved reading lists could not be read.", readError);
    self.loadError = invalid;
    if (error) *error = invalid;
    return NO;
  }

  NSMutableArray<CRReadingList*>* lists = [NSMutableArray array];
  NSMutableSet<NSString*>* identifiers = [NSMutableSet set];
  for (id listDictionary in root[@"lists"]) {
    if (![listDictionary isKindOfClass:[NSDictionary class]]) {
      NSError* invalid = CRReadingListsError(CRReadingListsErrorInvalidData,
                                             @"The saved reading lists contain an invalid list.", nil);
      self.loadError = invalid;
      if (error) *error = invalid;
      return NO;
    }
    NSError* modelError = nil;
    CRReadingList* list = [[CRReadingList alloc] initWithDictionary:listDictionary error:&modelError];
    BOOL duplicateIdentifier = list && [identifiers containsObject:list.identifier];
    BOOL duplicateName = NO;
    if (list) {
      for (CRReadingList* existing in lists) {
        if (CRReadingListNamesEqual(existing.name, list.name)) {
          duplicateName = YES;
          break;
        }
      }
    }
    if (!list || duplicateIdentifier || duplicateName) {
      NSError* invalid = modelError ?: CRReadingListsError(CRReadingListsErrorInvalidData,
                                                            @"The saved reading lists contain duplicate data.", nil);
      self.loadError = invalid;
      if (error) *error = invalid;
      return NO;
    }
    [identifiers addObject:list.identifier];
    [lists addObject:list];
  }

  self.mutableLists = lists;
  self.resolvedComics = [NSMutableDictionary dictionary];
  self.loadError = nil;
  if (error) *error = nil;
  return YES;
}

- (NSString*)relativePathForPath:(NSString*)path {
  NSArray<NSString*>* rootComponents = self.libraryRootURL.path.pathComponents;
  NSArray<NSString*>* pathComponents = [NSURL fileURLWithPath:path].URLByStandardizingPath.path.pathComponents;
  if (pathComponents.count <= rootComponents.count) return nil;
  for (NSUInteger index = 0; index < rootComponents.count; index++) {
    if (![rootComponents[index] isEqualToString:pathComponents[index]]) return nil;
  }
  return [NSString pathWithComponents:[pathComponents subarrayWithRange:NSMakeRange(rootComponents.count,
                                                                                     pathComponents.count - rootComponents.count)]];
}

- (NSDictionary<NSFileAttributeKey, id>*)attributesForPath:(NSString*)path {
  NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
  return [attributes[NSFileType] isEqual:NSFileTypeRegular] && attributes[NSFileSize] &&
    attributes[NSFileModificationDate] ? attributes : nil;
}

- (CRReadingListCandidate*)candidateForComic:(Comic*)comic {
  NSString* path = [self.libraryConnection pathForComic:comic];
  NSString* relativePath = path ? [self relativePathForPath:path] : nil;
  NSDictionary* attributes = path ? [self attributesForPath:path] : nil;
  if (!relativePath || !attributes) return nil;
  CRReadingListCandidate* candidate = [[CRReadingListCandidate alloc] init];
  candidate.comic = comic;
  candidate.path = path;
  candidate.relativePath = relativePath;
  candidate.attributes = attributes;
  candidate.fileSystemIdentity = CRReadingListFileSystemIdentity(attributes);
  return candidate;
}

- (BOOL)item:(CRReadingListItem*)item matchesCandidate:(CRReadingListCandidate*)candidate {
  NSNumber* currentSize = candidate.attributes[NSFileSize];
  NSNumber* modifiedAt = CRReadingListTimestamp(candidate.attributes, NSFileModificationDate);
  NSNumber* createdAt = CRReadingListTimestamp(candidate.attributes, NSFileCreationDate);
  if (![item.fileSize isEqual:currentSize] ||
      !CRReadingListTimestampsEqual(item.modifiedAt, modifiedAt) ||
      !CRReadingListTimestampsEqual(item.createdAt, createdAt)) return NO;

  if (item.fileSystemIdentity.length) {
    return [item.fileSystemIdentity isEqualToString:candidate.fileSystemIdentity];
  }
  if (![item.relativePath isEqualToString:candidate.relativePath] || !item.sampleDigest.length) return NO;
  NSString* digest = CRReadingListSampleDigest(candidate.path, currentSize.unsignedLongLongValue, NULL);
  return digest && [digest isEqualToString:item.sampleDigest];
}

static void CRReadingListAddUniqueCandidate(NSMutableDictionary<NSString*, id>* index,
                                            NSString* key,
                                            CRReadingListCandidate* candidate) {
  if (!key.length) return;
  index[key] = index[key] ? NSNull.null : candidate;
}

- (void)refreshLibraryState {
  NSArray<Comic*>* allComics = [self.libraryConnection fetchAllComicsByName] ?: @[];
  allComics = [allComics sortedArrayUsingComparator:^NSComparisonResult(Comic* left, Comic* right) {
    NSComparisonResult nameResult = [(left.name ?: @"") localizedStandardCompare:(right.name ?: @"")];
    if (nameResult != NSOrderedSame) return nameResult;
    NSString* leftPath = [self.libraryConnection pathForComic:left] ?: @"";
    NSString* rightPath = [self.libraryConnection pathForComic:right] ?: @"";
    return [leftPath localizedStandardCompare:rightPath];
  }];
  NSMutableArray<Comic*>* continueReading = [NSMutableArray array];
  NSMutableArray<Comic*>* unread = [NSMutableArray array];
  NSMutableArray<Comic*>* finished = [NSMutableArray array];
  for (Comic* comic in allComics) {
    if (comic.status > 0) {
      [continueReading addObject:comic];
    } else if (comic.status < 0) {
      [unread addObject:comic];
    } else {
      [finished addObject:comic];
    }
  }
  self.currentSmartQueues = @[
    [[CRReadingSmartQueue alloc] initWithKind:CRReadingSmartQueueKindContinueReading
                                   identifier:@"continue-reading" name:@"Continue Reading" comics:continueReading],
    [[CRReadingSmartQueue alloc] initWithKind:CRReadingSmartQueueKindUnread
                                   identifier:@"unread" name:@"Unread" comics:unread],
    [[CRReadingSmartQueue alloc] initWithKind:CRReadingSmartQueueKindFinished
                                   identifier:@"finished" name:@"Read Again" comics:finished],
  ];

  NSMutableDictionary<NSString*, id>* candidatesByIdentity = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString*, id>* candidatesByPath = [NSMutableDictionary dictionary];
  for (Comic* comic in allComics) {
    CRReadingListCandidate* candidate = [self candidateForComic:comic];
    if (!candidate) continue;
    CRReadingListAddUniqueCandidate(candidatesByIdentity, candidate.fileSystemIdentity, candidate);
    CRReadingListAddUniqueCandidate(candidatesByPath, candidate.relativePath, candidate);
  }

  NSMutableDictionary<NSString*, id>* resolved = [NSMutableDictionary dictionary];
  for (CRReadingList* list in self.mutableLists) {
    for (CRReadingListItem* item in list.mutableItems) {
      id value = item.fileSystemIdentity.length ? candidatesByIdentity[item.fileSystemIdentity]
                                                : candidatesByPath[item.relativePath];
      CRReadingListCandidate* candidate = [value isKindOfClass:[CRReadingListCandidate class]] ? value : nil;
      resolved[item.identifier] = candidate && [self item:item matchesCandidate:candidate]
        ? candidate.comic : NSNull.null;
    }
  }
  self.resolvedComics = resolved;
}

- (CRReadingSmartQueue*)smartQueueWithKind:(CRReadingSmartQueueKind)kind {
  for (CRReadingSmartQueue* queue in self.smartQueues) {
    if (queue.kind == kind) return queue;
  }
  return nil;
}

- (NSArray<Comic*>*)comicsForSmartQueue:(CRReadingSmartQueue*)queue error:(NSError**)error {
  if (!self.isSmartQueueAccessAllowed) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorSmartQueuesRequirePlus,
      @"Opening Smart Queues requires ComicReader Plus. The preview counts remain available.", nil);
    return nil;
  }
  CRReadingSmartQueue* currentQueue = [self smartQueueWithKind:queue.kind];
  if (!currentQueue || ![currentQueue.identifier isEqualToString:queue.identifier]) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorInvalidData,
                                            @"This Smart Queue is no longer available.", nil);
    return nil;
  }
  if (error) *error = nil;
  return [currentQueue.comics copy];
}

- (CRReadingList*)listWithIdentifier:(NSString*)identifier {
  for (CRReadingList* list in self.mutableLists) {
    if ([list.identifier isEqualToString:identifier]) return list;
  }
  return nil;
}

- (CRReadingListItemAvailability)availabilityForItem:(CRReadingListItem*)item {
  if (!self.resolvedComics[item.identifier]) [self refreshLibraryState];
  return [self.resolvedComics[item.identifier] isKindOfClass:[Comic class]]
    ? CRReadingListItemAvailabilityAvailable : CRReadingListItemAvailabilityMissingOrChanged;
}

- (Comic*)comicForItem:(CRReadingListItem*)item {
  if (!self.resolvedComics[item.identifier]) [self refreshLibraryState];
  Comic* comic = [self.resolvedComics[item.identifier] isKindOfClass:[Comic class]]
    ? self.resolvedComics[item.identifier] : nil;
  if (comic) {
    CRReadingListCandidate* candidate = [self candidateForComic:comic];
    if (!candidate || ![self item:item matchesCandidate:candidate]) {
      [self refreshLibraryState];
      comic = [self.resolvedComics[item.identifier] isKindOfClass:[Comic class]]
        ? self.resolvedComics[item.identifier] : nil;
    }
  }
  return comic;
}

- (BOOL)containsComic:(Comic*)comic inList:(CRReadingList*)list {
  CRReadingList* currentList = [self listWithIdentifier:list.identifier];
  CRReadingListCandidate* candidate = [self candidateForComic:comic];
  if (!currentList || !candidate) return NO;
  for (CRReadingListItem* item in currentList.mutableItems) {
    if (item.fileSystemIdentity.length &&
        [item.fileSystemIdentity isEqualToString:candidate.fileSystemIdentity]) return YES;
    if (!item.fileSystemIdentity.length &&
        [item.relativePath isEqualToString:candidate.relativePath] &&
        [self item:item matchesCandidate:candidate]) return YES;
  }
  return NO;
}

- (BOOL)validateMutationForList:(CRReadingList*)list error:(NSError**)error {
  if (self.loadError) {
    if (error) *error = self.loadError;
    return NO;
  }
  if (!self.isEditingAllowed) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorEditingRequiresPlus,
                                            @"Editing Reading Lists requires ComicReader Plus.", nil);
    return NO;
  }
  if (list && ![self listWithIdentifier:list.identifier]) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorListNotFound,
                                            @"This reading list no longer exists.", nil);
    return NO;
  }
  return YES;
}

- (BOOL)writeToDiskWithError:(NSError**)error {
  NSMutableArray* lists = [NSMutableArray arrayWithCapacity:self.mutableLists.count];
  for (CRReadingList* list in self.mutableLists) [lists addObject:list.dictionaryRepresentation];
  NSDictionary* root = @{ @"schemaVersion": @(CRReadingListsSchemaVersion), @"lists": lists };
  NSError* serializationError = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:root options:0 error:&serializationError];
  NSFileManager* manager = [NSFileManager defaultManager];
  BOOL madeDirectory = data && [manager createDirectoryAtURL:[self.storageURL URLByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:&serializationError];
  BOOL wrote = madeDirectory && [data writeToURL:self.storageURL options:NSDataWritingAtomic error:&serializationError];
  if (!wrote) {
    NSError* persistenceError = CRReadingListsError(CRReadingListsErrorPersistence,
                                                    @"The reading lists could not be saved.", serializationError);
    if (error) *error = persistenceError;
    return NO;
  }
  [manager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
            ofItemAtPath:self.storageURL.path error:NULL];
  if (error) *error = nil;
  return YES;
}

- (void)didMutate {
  self.resolvedComics = [NSMutableDictionary dictionary];
  [[NSNotificationCenter defaultCenter] postNotificationName:CRReadingListsDidChangeNotification object:self];
}

- (BOOL)nameExists:(NSString*)name exceptList:(CRReadingList*)exceptList {
  for (CRReadingList* list in self.mutableLists) {
    if (list != exceptList && CRReadingListNamesEqual(name, list.name)) return YES;
  }
  return NO;
}

- (BOOL)createListNamed:(NSString*)name createdList:(CRReadingList**)createdList error:(NSError**)error {
  if (createdList) *createdList = nil;
  if (![self validateMutationForList:nil error:error]) return NO;
  NSString* normalized = CRReadingListNormalizedName(name);
  if (!normalized) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorInvalidName,
                                            @"Enter a name between 1 and 100 characters.", nil);
    return NO;
  }
  if ([self nameExists:normalized exceptList:nil]) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorDuplicateName,
                                            @"A reading list with that name already exists.", nil);
    return NO;
  }
  NSDictionary* dictionary = @{ @"id": NSUUID.UUID.UUIDString, @"name": normalized, @"items": @[] };
  CRReadingList* list = [[CRReadingList alloc] initWithDictionary:dictionary error:error];
  [self.mutableLists addObject:list];
  if (![self writeToDiskWithError:error]) {
    [self.mutableLists removeLastObject];
    return NO;
  }
  [self didMutate];
  if (createdList) *createdList = list;
  return YES;
}

- (BOOL)renameList:(CRReadingList*)list toName:(NSString*)name error:(NSError**)error {
  if (![self validateMutationForList:list error:error]) return NO;
  CRReadingList* currentList = [self listWithIdentifier:list.identifier];
  NSString* normalized = CRReadingListNormalizedName(name);
  if (!normalized) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorInvalidName,
                                            @"Enter a name between 1 and 100 characters.", nil);
    return NO;
  }
  if ([self nameExists:normalized exceptList:currentList]) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorDuplicateName,
                                            @"A reading list with that name already exists.", nil);
    return NO;
  }
  NSString* oldName = currentList.name;
  currentList.name = normalized;
  if (![self writeToDiskWithError:error]) {
    currentList.name = oldName;
    return NO;
  }
  [self didMutate];
  return YES;
}

- (BOOL)removeList:(CRReadingList*)list error:(NSError**)error {
  if (![self validateMutationForList:list error:error]) return NO;
  CRReadingList* currentList = [self listWithIdentifier:list.identifier];
  NSUInteger index = [self.mutableLists indexOfObjectIdenticalTo:currentList];
  [self.mutableLists removeObjectAtIndex:index];
  if (![self writeToDiskWithError:error]) {
    [self.mutableLists insertObject:currentList atIndex:index];
    return NO;
  }
  [self didMutate];
  return YES;
}

- (BOOL)moveListFromIndex:(NSUInteger)sourceIndex toIndex:(NSUInteger)destinationIndex error:(NSError**)error {
  if (![self validateMutationForList:nil error:error]) return NO;
  if (sourceIndex >= self.mutableLists.count || destinationIndex >= self.mutableLists.count) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorInvalidMove,
                                            @"The reading list could not be moved.", nil);
    return NO;
  }
  if (sourceIndex == destinationIndex) return YES;
  NSArray* oldOrder = [self.mutableLists copy];
  CRReadingList* list = self.mutableLists[sourceIndex];
  [self.mutableLists removeObjectAtIndex:sourceIndex];
  [self.mutableLists insertObject:list atIndex:destinationIndex];
  if (![self writeToDiskWithError:error]) {
    self.mutableLists = [oldOrder mutableCopy];
    return NO;
  }
  [self didMutate];
  return YES;
}

- (CRReadingListItem*)itemForComic:(Comic*)comic error:(NSError**)error {
  CRReadingListCandidate* candidate = [self candidateForComic:comic];
  if (!candidate) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorComicUnavailable,
                                            @"This comic is missing from the local library.", nil);
    return nil;
  }
  NSString* sampleDigest = nil;
  if (!candidate.fileSystemIdentity.length) {
    NSError* fingerprintError = nil;
    sampleDigest = CRReadingListSampleDigest(candidate.path,
                                             [candidate.attributes[NSFileSize] unsignedLongLongValue],
                                             &fingerprintError);
    if (!sampleDigest) {
      if (error) *error = CRReadingListsError(CRReadingListsErrorComicUnavailable,
                                              @"This comic could not be identified safely.", fingerprintError);
      return nil;
    }
  }
  NSMutableDictionary* dictionary = [@{
    @"id": NSUUID.UUID.UUIDString,
    @"displayName": comic.name.length ? comic.name : candidate.path.lastPathComponent,
    @"relativePath": candidate.relativePath,
    @"fileSize": candidate.attributes[NSFileSize],
    @"modifiedAt": CRReadingListTimestamp(candidate.attributes, NSFileModificationDate),
  } mutableCopy];
  NSNumber* createdAt = CRReadingListTimestamp(candidate.attributes, NSFileCreationDate);
  if (createdAt) dictionary[@"createdAt"] = createdAt;
  if (candidate.fileSystemIdentity) dictionary[@"fileSystemIdentity"] = candidate.fileSystemIdentity;
  if (sampleDigest) dictionary[@"sampleDigest"] = sampleDigest;
  return [[CRReadingListItem alloc] initWithDictionary:dictionary error:error];
}

- (BOOL)addComic:(Comic*)comic toList:(CRReadingList*)list error:(NSError**)error {
  if (![self validateMutationForList:list error:error]) return NO;
  CRReadingList* currentList = [self listWithIdentifier:list.identifier];
  if ([self containsComic:comic inList:currentList]) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorComicAlreadyPresent,
                                            @"This comic is already in the reading list.", nil);
    return NO;
  }
  CRReadingListItem* item = [self itemForComic:comic error:error];
  if (!item) return NO;
  [currentList.mutableItems addObject:item];
  if (![self writeToDiskWithError:error]) {
    [currentList.mutableItems removeLastObject];
    return NO;
  }
  [self didMutate];
  return YES;
}

- (BOOL)removeItemAtIndex:(NSUInteger)index fromList:(CRReadingList*)list error:(NSError**)error {
  if (![self validateMutationForList:list error:error]) return NO;
  CRReadingList* currentList = [self listWithIdentifier:list.identifier];
  if (index >= currentList.mutableItems.count) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorInvalidMove,
                                            @"The comic is no longer in this reading list.", nil);
    return NO;
  }
  CRReadingListItem* item = currentList.mutableItems[index];
  [currentList.mutableItems removeObjectAtIndex:index];
  if (![self writeToDiskWithError:error]) {
    [currentList.mutableItems insertObject:item atIndex:index];
    return NO;
  }
  [self didMutate];
  return YES;
}

- (BOOL)moveItemInList:(CRReadingList*)list
             fromIndex:(NSUInteger)sourceIndex
               toIndex:(NSUInteger)destinationIndex
                 error:(NSError**)error {
  if (![self validateMutationForList:list error:error]) return NO;
  CRReadingList* currentList = [self listWithIdentifier:list.identifier];
  if (sourceIndex >= currentList.mutableItems.count || destinationIndex >= currentList.mutableItems.count) {
    if (error) *error = CRReadingListsError(CRReadingListsErrorInvalidMove,
                                            @"The comic could not be moved.", nil);
    return NO;
  }
  if (sourceIndex == destinationIndex) return YES;
  NSArray* oldOrder = [currentList.mutableItems copy];
  CRReadingListItem* item = currentList.mutableItems[sourceIndex];
  [currentList.mutableItems removeObjectAtIndex:sourceIndex];
  [currentList.mutableItems insertObject:item atIndex:destinationIndex];
  if (![self writeToDiskWithError:error]) {
    currentList.mutableItems = [oldOrder mutableCopy];
    return NO;
  }
  [self didMutate];
  return YES;
}

@end
