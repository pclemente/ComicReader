#import "CRLibrarySyncCoordinator.h"
#import "ComicFlow-Swift.h"
#import "Library.h"
#import "AppDelegate.h"

static NSString* const CRSyncPreference = @"CRCloudSyncOptedIn";
static NSString* const CRLocalFileSystemNumberKey = @"localFileSystemNumber";
static NSString* const CRLocalFileNumberKey = @"localFileNumber";

static NSTimeInterval CRReadingTimestamp(id value) {
  if ([value isKindOfClass:[NSDate class]]) return [value timeIntervalSince1970];
  if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
  return 0;
}

@interface CRLibrarySyncCoordinator () {
  NSMutableDictionary* _readingStates;
  NSMutableDictionary* _pendingRemoteStates;
  NSString* _activePath;
  dispatch_queue_t _persistenceQueue;
  BOOL _started;
  BOOL _cloudWasEnabled;
}
@end

@implementation CRLibrarySyncCoordinator

+ (instancetype)sharedCoordinator {
  static CRLibrarySyncCoordinator* coordinator;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ coordinator = [[self alloc] init]; });
  return coordinator;
}

- (NSString*)statePath {
  return [[LibraryConnection libraryApplicationDataPath] stringByAppendingPathComponent:@"reading-state-v1.plist"];
}

- (instancetype)init {
  if ((self = [super init])) {
    _readingStates = [[NSMutableDictionary alloc] initWithContentsOfFile:[self statePath]];
    if (!_readingStates) _readingStates = [[NSMutableDictionary alloc] init];
    _pendingRemoteStates = [[NSMutableDictionary alloc] init];
    _persistenceQueue = dispatch_queue_create("com.comicreader.reading-state", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)persist {
  NSDictionary* snapshot = [_readingStates copy];
  NSString* path = [[self statePath] copy];
  dispatch_async(_persistenceQueue, ^{
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![snapshot writeToFile:path atomically:YES]) NSLog(@"Could not save ComicReader reading state");
    [snapshot release];
    [path release];
  });
}

- (NSString*)relativePath:(NSString*)path {
  NSString* prefix = [[LibraryConnection libraryRootPath] stringByAppendingString:@"/"];
  return [path hasPrefix:prefix] ? [path substringFromIndex:prefix.length] : nil;
}

- (NSDictionary*)stateForComic:(Comic*)comic {
  NSString* path = [[LibraryConnection mainConnection] pathForComic:comic];
  NSString* relative = [self relativePath:path];
  id state = relative ? [_readingStates objectForKey:relative] : nil;
  if (![state isKindOfClass:[NSDictionary class]]) return nil;
  NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
  if (state[@"localFileSize"] &&
      (![state[@"localFileSize"] isEqual:attributes[NSFileSize]] ||
       ![state[@"localFileModifiedAt"] isEqual:attributes[NSFileModificationDate]])) return nil;
  id storedSystemNumber = state[CRLocalFileSystemNumberKey];
  id storedFileNumber = state[CRLocalFileNumberKey];
  if ((storedSystemNumber || storedFileNumber) &&
      (![storedSystemNumber isEqual:attributes[NSFileSystemNumber]] ||
       ![storedFileNumber isEqual:attributes[NSFileSystemFileNumber]])) return nil;
  return state;
}

- (void)addFileFingerprint:(NSMutableDictionary*)state path:(NSString*)path {
  NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
  if (attributes[NSFileSize]) state[@"localFileSize"] = attributes[NSFileSize];
  if (attributes[NSFileModificationDate]) state[@"localFileModifiedAt"] = attributes[NSFileModificationDate];
  if (attributes[NSFileSystemNumber] && attributes[NSFileSystemFileNumber]) {
    state[CRLocalFileSystemNumberKey] = attributes[NSFileSystemNumber];
    state[CRLocalFileNumberKey] = attributes[NSFileSystemFileNumber];
  } else {
    [state removeObjectForKey:CRLocalFileSystemNumberKey];
    [state removeObjectForKey:CRLocalFileNumberKey];
  }
}

- (NSDictionary*)snapshotForComic:(Comic*)comic {
  NSString* path = [[LibraryConnection mainConnection] pathForComic:comic];
  NSString* relative = [self relativePath:path];
  if (!relative) return nil;
  NSMutableDictionary* record = [NSMutableDictionary dictionaryWithDictionary:[self stateForComic:comic] ?: @{}];
  record[@"localPath"] = path;
  record[@"relativePath"] = relative;
  record[@"legacyStatus"] = @(comic.status);
  if (!record[@"currentPage"]) record[@"currentPage"] = @(MAX(0, comic.status));
  if (!record[@"pageCount"]) record[@"pageCount"] = @0;
  // Missing timestamps deliberately stay absent: enabling sync must not turn an
  // old local copy into a new reading event and replace progress from iCloud.
  return record;
}

- (void)start {
  if (_started) return;
  _started = YES;
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(syncRequested:) name:@"CRPlusSyncRequestedNotification" object:nil];
  [center addObserver:self selector:@selector(imported:) name:[CRCloudSyncManager importedComicsNotification] object:nil];
  [center addObserver:self selector:@selector(receivedReadingStates:) name:[CRCloudSyncManager readingStateDidChangeNotification] object:nil];
  [center addObserver:self selector:@selector(cloudStatusChanged:) name:[CRCloudSyncManager statusDidChangeNotification] object:nil];
  [[CRCloudSyncManager sharedManager] configureWithLibraryRootPath:[LibraryConnection libraryRootPath]
                                                         optedIn:[[NSUserDefaults standardUserDefaults] boolForKey:CRSyncPreference]];
}

- (void)cloudStatusChanged:(NSNotification*)notification {
  CRCloudSyncManager* manager = [CRCloudSyncManager sharedManager];
  // The engine owns account consent; the preference alone never authorizes upload.
  [[NSUserDefaults standardUserDefaults] setBool:manager.optedIn forKey:CRSyncPreference];
  if (!manager.enabled) [_pendingRemoteStates removeAllObjects];
  if (manager.enabled && !_cloudWasEnabled) [self scheduleSync];
  _cloudWasEnabled = manager.enabled;
}

- (void)syncRequested:(NSNotification*)notification { [self synchronize]; }

- (void)scheduleSync {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronize) object:nil];
  [self performSelector:@selector(synchronize) withObject:nil afterDelay:2.0];
}

- (void)synchronize {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronize) object:nil];
  if (![[CRCloudSyncManager sharedManager] enabled] || [[LibraryUpdater sharedUpdater] isUpdating]) return;
  NSMutableArray* snapshot = [NSMutableArray array];
  for (Comic* comic in [[LibraryConnection mainConnection] fetchAllComicsByName]) {
    NSDictionary* entry = [self snapshotForComic:comic];
    if (entry) [snapshot addObject:entry];
  }
  [[CRCloudSyncManager sharedManager] synchronizeLibrarySnapshot:snapshot completion:nil];
}

- (NSInteger)initialPageForComic:(Comic*)comic pageCount:(NSInteger)pageCount {
  NSDictionary* state = [self stateForComic:comic];
  NSInteger page = state[@"currentPage"] ? [state[@"currentPage"] integerValue] : MAX(0, comic.status);
  return MIN(MAX(0, page), MAX(0, pageCount - 1));
}

- (void)beginReadingComic:(Comic*)comic {
  [_activePath release];
  _activePath = [[[LibraryConnection mainConnection] pathForComic:comic] copy];
}

- (void)endReadingComic:(Comic*)comic {
  [_activePath release];
  _activePath = nil;
  [self applyPendingRemoteStates];
  [self synchronize];
}

- (void)recordComic:(Comic*)comic currentPage:(NSInteger)page pageCount:(NSInteger)pageCount {
  [self recordComic:comic currentPage:page pageCount:pageCount force:NO];
}

- (void)recordComic:(Comic*)comic currentPage:(NSInteger)page pageCount:(NSInteger)pageCount force:(BOOL)force {
  NSDictionary* old = [self stateForComic:comic];
  if (!force && old && [old[@"currentPage"] integerValue] == page &&
      [old[@"pageCount"] integerValue] == pageCount && [old[@"legacyStatus"] intValue] == comic.status) return;
  NSMutableDictionary* state = [NSMutableDictionary dictionaryWithDictionary:[self snapshotForComic:comic]];
  state[@"currentPage"] = @(MAX(0, page));
  state[@"pageCount"] = @(MAX(0, pageCount));
  state[@"readingUpdatedAt"] = @([[NSDate date] timeIntervalSince1970]);
  state[@"readingMutationIdentifier"] = [[NSUUID UUID] UUIDString];
  [self addFileFingerprint:state path:state[@"localPath"]];
  _readingStates[state[@"relativePath"]] = state;
  [self persist];
  if ([[CRCloudSyncManager sharedManager] enabled]) {
    [[CRCloudSyncManager sharedManager] recordReadingStateForComic:state completion:nil];
    [self scheduleSync];
  }
}

- (void)markComics:(NSArray*)comics status:(int)status {
  for (Comic* comic in comics) {
    comic.status = status;
    [[LibraryConnection mainConnection] updateObject:comic];
    NSDictionary* state = [self stateForComic:comic];
    NSInteger count = [state[@"pageCount"] integerValue];
    NSInteger page = status < 0 ? 0 : MAX(0, count - 1);
    [self recordComic:comic currentPage:page pageCount:count force:YES];
  }
}

- (void)didDeleteComics:(NSArray*)comics paths:(NSArray*)paths {
  for (NSString* path in paths) {
    NSString* relative = [self relativePath:path];
    if (relative) [_readingStates removeObjectForKey:relative];
    [[CRCloudSyncManager sharedManager] removeLocalComicFromSyncWithLocalPath:path];
  }
  [self persist];
}

- (void)imported:(NSNotification*)notification {
  [[AppDelegate sharedDelegate] updateLibrary];
}

- (void)receivedReadingStates:(NSNotification*)notification {
  if (![[CRCloudSyncManager sharedManager] enabled]) return;
  for (NSDictionary* state in notification.userInfo[@"readingStates"]) {
    NSString* relative = state[@"relativePath"];
    if (!relative && state[@"localPath"]) relative = [self relativePath:state[@"localPath"]];
    if ([relative isKindOfClass:[NSString class]]) _pendingRemoteStates[relative] = state;
  }
  [self applyPendingRemoteStates];
}

- (void)applyPendingRemoteStates {
  if (![[CRCloudSyncManager sharedManager] enabled] || [[LibraryUpdater sharedUpdater] isUpdating] || !_pendingRemoteStates.count) return;
  BOOL changed = NO;
  for (Comic* comic in [[LibraryConnection mainConnection] fetchAllComicsByName]) {
    NSString* path = [[LibraryConnection mainConnection] pathForComic:comic];
    NSString* relative = [self relativePath:path];
    NSDictionary* remote = _pendingRemoteStates[relative];
    if (!remote || [path isEqualToString:_activePath]) continue;
    NSDictionary* local = [self stateForComic:comic];
    NSTimeInterval remoteTime = CRReadingTimestamp(remote[@"readingUpdatedAt"]);
    NSTimeInterval localTime = CRReadingTimestamp(local[@"readingUpdatedAt"]);
    BOOL newer = remoteTime > localTime || (remoteTime == localTime &&
      [remote[@"readingMutationIdentifier"] compare:local[@"readingMutationIdentifier"] ?: @""] == NSOrderedDescending);
    if (!local || newer) {
      NSMutableDictionary* state = [NSMutableDictionary dictionaryWithDictionary:remote];
      state[@"readingUpdatedAt"] = @(remoteTime);
      state[@"localPath"] = path;
      state[@"relativePath"] = relative;
      [self addFileFingerprint:state path:path];
      _readingStates[relative] = state;
      comic.status = [state[@"legacyStatus"] intValue];
      [[LibraryConnection mainConnection] updateObject:comic];
      changed = YES;
    }
    [_pendingRemoteStates removeObjectForKey:relative];
  }
  if (changed) {
    [self persist];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CRLibraryReadingStateDidChangeNotification" object:self];
  }
}

- (void)libraryDidUpdate {
  [self applyPendingRemoteStates];
  [self scheduleSync];
}

@end
