#import <Foundation/Foundation.h>

@class Comic;

// All entry points are main-thread only, like LibraryConnection.mainConnection.
@interface CRLibrarySyncCoordinator : NSObject
+ (instancetype)sharedCoordinator;
- (void)start;
- (void)synchronize;
- (void)libraryDidUpdate;
- (NSInteger)initialPageForComic:(Comic*)comic pageCount:(NSInteger)pageCount;
- (void)beginReadingComic:(Comic*)comic;
- (void)endReadingComic:(Comic*)comic;
- (void)recordComic:(Comic*)comic currentPage:(NSInteger)page pageCount:(NSInteger)pageCount;
- (void)markComics:(NSArray*)comics status:(int)status;
- (void)didDeleteComics:(NSArray*)comics paths:(NSArray*)paths;
@end
