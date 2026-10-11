#import "CRComicPageSource.h"

#import <ImageIO/ImageIO.h>
#import <PDFKit/PDFKit.h>
#import <math.h>

#import "ImageDecompression.h"
#import "MiniZip.h"
#import "UnRAR.h"

NSErrorDomain const CRComicPageSourceErrorDomain = @"com.pabloclementeperez.ComicReader.ComicPageSource";

typedef NS_ENUM(NSUInteger, CRComicPageSourceKind) {
  CRComicPageSourceKindPDF,
  CRComicPageSourceKindArchive,
};

static NSError* CRComicPageSourceError(CRComicPageSourceErrorCode code, NSString* description,
                                       NSError* underlyingError) {
  NSMutableDictionary* userInfo = [@{NSLocalizedDescriptionKey: description} mutableCopy];
  if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
  return [NSError errorWithDomain:CRComicPageSourceErrorDomain code:code userInfo:userInfo];
}

static NSDictionary<NSFileAttributeKey, id>* CRComicPageSourceSnapshot(NSString* path, NSError** error) {
  NSError* attributesError = nil;
  NSDictionary<NSFileAttributeKey, id>* attributes =
    [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&attributesError];
  if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || !attributes[NSFileSize] ||
      !attributes[NSFileModificationDate]) {
    if (error) {
      *error = CRComicPageSourceError(CRComicPageSourceErrorInvalidPath,
                                      @"The comic file is unavailable.", attributesError);
    }
    return nil;
  }
  return @{
    NSFileSize: attributes[NSFileSize],
    NSFileModificationDate: attributes[NSFileModificationDate],
    NSFileCreationDate: attributes[NSFileCreationDate] ?: NSNull.null,
    NSFileSystemNumber: attributes[NSFileSystemNumber] ?: NSNull.null,
    NSFileSystemFileNumber: attributes[NSFileSystemFileNumber] ?: NSNull.null,
  };
}

@interface CRComicPageSource ()
@property(nonatomic, readwrite, copy) NSString* path;
@property(nonatomic, readwrite) NSInteger pageCount;
@property(nonatomic) CRComicPageSourceKind kind;
@property(nonatomic, strong) NSDictionary<NSFileAttributeKey, id>* fileSnapshot;
@property(nonatomic, strong) PDFDocument* PDFDocument;
@property(nonatomic, strong) id archive;
@property(nonatomic, copy) NSArray<NSString*>* archiveEntries;
@property(nonatomic, strong) NSLock* lock;
@end

@implementation CRComicPageSource

- (instancetype)initWithPath:(NSString*)path error:(NSError**)error {
  NSString* standardizedPath = [[NSURL fileURLWithPath:path].URLByStandardizingPath.URLByResolvingSymlinksInPath path];
  NSError* snapshotError = nil;
  NSDictionary* snapshot = CRComicPageSourceSnapshot(standardizedPath, &snapshotError);
  if (!snapshot) {
    if (error) *error = snapshotError;
    return nil;
  }

  if ((self = [super init])) {
    _path = [standardizedPath copy];
    _fileSnapshot = snapshot;
    _lock = [[NSLock alloc] init];

    NSString* extension = _path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"pdf"]) {
      _kind = CRComicPageSourceKindPDF;
      _PDFDocument = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:_path]];
      _pageCount = _PDFDocument.pageCount;
    } else if ([extension isEqualToString:@"zip"] || [extension isEqualToString:@"cbz"] ||
               [extension isEqualToString:@"rar"] || [extension isEqualToString:@"cbr"]) {
      _kind = CRComicPageSourceKindArchive;
      id archive = [[MiniZip alloc] initWithArchiveAtPath:_path];
      if (!archive) archive = [[UnRAR alloc] initWithArchiveAtPath:_path];
      if (archive) {
        [archive setSkipInvisibleFiles:YES];
        NSArray<NSString*>* entries = [archive retrieveFileList];
        if (entries) {
          NSMutableArray<NSString*>* imageEntries = [NSMutableArray array];
          for (NSString* entry in entries) {
            if (IsImageFileExtensionSupported(entry.pathExtension)) [imageEntries addObject:entry];
          }
          _archive = archive;
          _archiveEntries = [imageEntries sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
          _pageCount = _archiveEntries.count;
        }
      }
    } else {
      if (error) {
        *error = CRComicPageSourceError(CRComicPageSourceErrorUnsupportedFormat,
                                        @"This comic format does not support text recognition.", nil);
      }
      return nil;
    }

    if (_pageCount <= 0 || (_kind == CRComicPageSourceKindPDF && !_PDFDocument) ||
        (_kind == CRComicPageSourceKindArchive && !_archive)) {
      if (error) {
        *error = CRComicPageSourceError(CRComicPageSourceErrorUnreadableComic,
                                        @"The comic has no readable pages.", nil);
      }
      return nil;
    }
  }
  return self;
}

- (BOOL)isStillCurrent {
  NSDictionary* current = CRComicPageSourceSnapshot(self.path, NULL);
  return current && [current isEqualToDictionary:self.fileSnapshot];
}

- (BOOL)validatePageIndex:(NSInteger)pageIndex error:(NSError**)error {
  if (pageIndex >= 0 && pageIndex < self.pageCount) return YES;
  if (error) {
    *error = CRComicPageSourceError(CRComicPageSourceErrorInvalidPage,
                                    @"That comic page is unavailable.", nil);
  }
  return NO;
}

- (BOOL)validateCurrentWithError:(NSError**)error {
  if (self.isStillCurrent) return YES;
  if (error) {
    *error = CRComicPageSourceError(CRComicPageSourceErrorComicChanged,
                                    @"The comic changed while its text was being read.", nil);
  }
  return NO;
}

- (UIImage*)imageAtPageIndex:(NSInteger)pageIndex
                maxDimension:(CGFloat)maxDimension
                       error:(NSError**)error {
  if (![self validatePageIndex:pageIndex error:error]) return nil;
  if (![self validateCurrentWithError:error]) return nil;
  if (!isfinite(maxDimension) || maxDimension <= 0.0) {
    if (error) {
      *error = CRComicPageSourceError(CRComicPageSourceErrorImageDecodeFailed,
                                      @"The requested recognition image size is invalid.", nil);
    }
    return nil;
  }

  UIImage* image = nil;
  [self.lock lock];
  @try {
    if (self.kind == CRComicPageSourceKindPDF) {
      CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:self.path]);
      if (document) {
        CGPDFPageRef page = CGPDFDocumentGetPage(document, (size_t)pageIndex + 1);
        if (page) {
          CGImageRef imageRef = CreateCGImageFromPDFPage(page,
                                                        CGSizeMake(maxDimension, maxDimension), NO);
          if (imageRef) {
            image = [UIImage imageWithCGImage:imageRef];
            CGImageRelease(imageRef);
          }
        }
        CGPDFDocumentRelease(document);
      }
    } else {
      NSString* entry = self.archiveEntries[(NSUInteger)pageIndex];
      NSString* temporaryName = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:entry.pathExtension];
      NSString* temporaryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:temporaryName];
      @try {
        if (![self.archive extractFile:entry toPath:temporaryPath]) {
          if (error) {
            *error = CRComicPageSourceError(CRComicPageSourceErrorExtractionFailed,
                                            @"A comic page could not be extracted.", nil);
          }
          return nil;
        }
        NSURL* temporaryURL = [NSURL fileURLWithPath:temporaryPath];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)temporaryURL, NULL);
        if (source) {
          NSDictionary* options = @{
            (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize: @((NSUInteger)ceil(maxDimension)),
            (__bridge NSString*)kCGImageSourceShouldCacheImmediately: @YES,
          };
          CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                    (__bridge CFDictionaryRef)options);
          if (imageRef) {
            image = [UIImage imageWithCGImage:imageRef];
            CGImageRelease(imageRef);
          }
          CFRelease(source);
        }
      } @finally {
        [[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:NULL];
      }
    }
  } @finally {
    [self.lock unlock];
  }

  if (!image) {
    if (error && !*error) {
      *error = CRComicPageSourceError(CRComicPageSourceErrorImageDecodeFailed,
                                      @"A comic page could not be decoded for text recognition.", nil);
    }
    return nil;
  }
  if (![self validateCurrentWithError:error]) return nil;
  return image;
}

- (NSString*)embeddedTextAtPageIndex:(NSInteger)pageIndex error:(NSError**)error {
  if (![self validatePageIndex:pageIndex error:error]) return nil;
  if (![self validateCurrentWithError:error]) return nil;
  if (self.kind != CRComicPageSourceKindPDF) return nil;

  NSString* text = nil;
  [self.lock lock];
  @try {
    text = [self.PDFDocument pageAtIndex:(NSUInteger)pageIndex].string;
  } @finally {
    [self.lock unlock];
  }
  if (![self validateCurrentWithError:error]) return nil;
  NSString* trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return trimmed.length ? trimmed : nil;
}

@end
