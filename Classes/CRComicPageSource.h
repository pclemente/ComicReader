#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const CRComicPageSourceErrorDomain;

typedef NS_ERROR_ENUM(CRComicPageSourceErrorDomain, CRComicPageSourceErrorCode) {
  CRComicPageSourceErrorInvalidPath = 1,
  CRComicPageSourceErrorUnsupportedFormat,
  CRComicPageSourceErrorUnreadableComic,
  CRComicPageSourceErrorInvalidPage,
  CRComicPageSourceErrorComicChanged,
  CRComicPageSourceErrorExtractionFailed,
  CRComicPageSourceErrorImageDecodeFailed,
};

/**
 A serial-use page reader for one immutable comic snapshot.

 The source follows the same PDF and naturally-sorted CBZ/CBR page ordering as
 ComicViewController. It never applies reader display filters and never keeps
 decoded page images alive between calls.
 */
@interface CRComicPageSource : NSObject

- (nullable instancetype)initWithPath:(NSString*)path
                                error:(NSError* _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER
  NS_SWIFT_NAME(init(path:));
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly, copy) NSString* path;
@property(nonatomic, readonly) NSInteger pageCount;

- (nullable UIImage*)imageAtPageIndex:(NSInteger)pageIndex
                         maxDimension:(CGFloat)maxDimension
                                error:(NSError* _Nullable * _Nullable)error
  NS_SWIFT_NAME(image(atPageIndex:maxDimension:));

/** Returns nil without an error when the page has no embedded text. */
- (nullable NSString*)embeddedTextAtPageIndex:(NSInteger)pageIndex
                                        error:(NSError* _Nullable * _Nullable)error
  NS_SWIFT_NAME(embeddedText(atPageIndex:))
  __attribute__((swift_error(nonnull_error)));

/** Checks the original device/inode, size, creation time and modification time. */
- (BOOL)isStillCurrent NS_SWIFT_NAME(isStillCurrent());

@end

NS_ASSUME_NONNULL_END
