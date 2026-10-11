#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class Comic;
@class LibraryConnection;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const CRReadingListsErrorDomain;
FOUNDATION_EXPORT NSNotificationName const CRReadingListsDidChangeNotification;

typedef NS_ERROR_ENUM(CRReadingListsErrorDomain, CRReadingListsErrorCode) {
  CRReadingListsErrorEditingRequiresPlus = 1,
  CRReadingListsErrorInvalidName,
  CRReadingListsErrorDuplicateName,
  CRReadingListsErrorListNotFound,
  CRReadingListsErrorComicUnavailable,
  CRReadingListsErrorComicAlreadyPresent,
  CRReadingListsErrorInvalidMove,
  CRReadingListsErrorPersistence,
  CRReadingListsErrorInvalidData,
  CRReadingListsErrorSmartQueuesRequirePlus,
};

typedef NS_ENUM(NSInteger, CRReadingListItemAvailability) {
  CRReadingListItemAvailabilityAvailable = 0,
  CRReadingListItemAvailabilityMissingOrChanged,
};

typedef NS_ENUM(NSInteger, CRReadingSmartQueueKind) {
  CRReadingSmartQueueKindContinueReading = 0,
  CRReadingSmartQueueKindUnread,
  CRReadingSmartQueueKindFinished,
};

/** A live, non-persisted preview of comics grouped by their library reading status. */
@interface CRReadingSmartQueue : NSObject
@property(nonatomic, readonly) CRReadingSmartQueueKind kind;
@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly) NSUInteger comicCount;
- (instancetype)init NS_UNAVAILABLE;
@end

/** An immutable view of a comic reference saved in a reading list. */
@interface CRReadingListItem : NSObject
@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSString* displayName;
@property(nonatomic, readonly, copy) NSString* relativePath;
- (instancetype)init NS_UNAVAILABLE;
@end

/** A named, ordered collection of comic references. */
@interface CRReadingList : NSObject
@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSArray<CRReadingListItem*>* items;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef BOOL (^CRReadingListsEditingAllowedProvider)(void);

/**
 Stores reading-list metadata only. Comic files remain in their existing library locations.

 All public methods are intended for the main thread because LibraryConnection.mainConnection
 is main-thread-only. Mutations are entitlement-gated; loading, resolving, and opening saved
 entries remain available if the entitlement is later revoked.
 */
@interface CRReadingListsStore : NSObject

@property(nonatomic, readonly, copy) NSArray<CRReadingList*>* lists;
/** Continue Reading, Unread, and Read Again snapshots, in display order. */
@property(nonatomic, readonly, copy) NSArray<CRReadingSmartQueue*>* smartQueues;
@property(nonatomic, readonly, strong) NSURL* storageURL;
@property(nonatomic, readonly, strong) NSURL* libraryRootURL;
@property(nonatomic, readonly, strong) LibraryConnection* libraryConnection;
@property(nonatomic, readonly, nullable, strong) NSError* loadError;
@property(nonatomic, readonly, getter=isEditingAllowed) BOOL editingAllowed;
@property(nonatomic, readonly, getter=isSmartQueueAccessAllowed) BOOL smartQueueAccessAllowed;

- (instancetype)initWithLibraryConnection:(LibraryConnection*)libraryConnection;
- (instancetype)initWithStorageURL:(NSURL*)storageURL
                     libraryRootURL:(NSURL*)libraryRootURL
                  libraryConnection:(LibraryConnection*)libraryConnection
             editingAllowedProvider:(CRReadingListsEditingAllowedProvider)editingAllowedProvider NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Reloads the JSON document without replacing the current model if the document is invalid. */
- (BOOL)reloadWithError:(NSError* _Nullable* _Nullable)error;

/** Refreshes Smart Queues and rebuilds the file-identity index for saved-list entries. */
- (void)refreshLibraryState;

- (nullable CRReadingList*)listWithIdentifier:(NSString*)identifier;
- (nullable CRReadingSmartQueue*)smartQueueWithKind:(CRReadingSmartQueueKind)kind;
/** Counts remain visible to everyone; resolving a queue's comics requires Plus. */
- (nullable NSArray<Comic*>*)comicsForSmartQueue:(CRReadingSmartQueue*)queue
                                           error:(NSError* _Nullable* _Nullable)error;
- (CRReadingListItemAvailability)availabilityForItem:(CRReadingListItem*)item;
- (nullable Comic*)comicForItem:(CRReadingListItem*)item;
- (BOOL)containsComic:(Comic*)comic inList:(CRReadingList*)list;

- (BOOL)createListNamed:(NSString*)name
            createdList:(CRReadingList* _Nullable* _Nullable)createdList
                  error:(NSError* _Nullable* _Nullable)error;
- (BOOL)renameList:(CRReadingList*)list
            toName:(NSString*)name
             error:(NSError* _Nullable* _Nullable)error;
- (BOOL)removeList:(CRReadingList*)list error:(NSError* _Nullable* _Nullable)error;
- (BOOL)moveListFromIndex:(NSUInteger)sourceIndex
                  toIndex:(NSUInteger)destinationIndex
                    error:(NSError* _Nullable* _Nullable)error;

- (BOOL)addComic:(Comic*)comic
          toList:(CRReadingList*)list
           error:(NSError* _Nullable* _Nullable)error;
- (BOOL)removeItemAtIndex:(NSUInteger)index
                 fromList:(CRReadingList*)list
                    error:(NSError* _Nullable* _Nullable)error;
- (BOOL)moveItemInList:(CRReadingList*)list
             fromIndex:(NSUInteger)sourceIndex
               toIndex:(NSUInteger)destinationIndex
                 error:(NSError* _Nullable* _Nullable)error;

@end

typedef void (^CRReadingListsOpenComicHandler)(Comic* comic, UIViewController* sourceViewController);

/** Native list browser, editor, searchable comic picker, and reader launcher. */
@interface CRReadingListsViewController : UITableViewController
- (instancetype)initWithLibraryConnection:(LibraryConnection*)libraryConnection;
- (instancetype)initWithLibraryConnection:(LibraryConnection*)libraryConnection
                          openComicHandler:(nullable CRReadingListsOpenComicHandler)openComicHandler;
- (instancetype)initWithStore:(CRReadingListsStore*)store
             openComicHandler:(nullable CRReadingListsOpenComicHandler)openComicHandler;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
