#import <XCTest/XCTest.h>

#import "ComicViewController.h"
#import "ImageDecompression.h"
#import "MiniZip.h"
#import "UnRAR.h"

@interface ReaderRegressionTests : XCTestCase
@end

@implementation ReaderRegressionTests

- (NSData*) dataFromBase64:(NSString*)base64 {
  return [[NSData alloc] initWithBase64EncodedString:base64 options:0];
}

- (NSString*) temporaryPath:(NSString*)name {
  NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:NULL]);
  return [directory stringByAppendingPathComponent:name];
}

- (void) testNativeImageIODecodesWebP {
  NSData* data = [self dataFromBase64:@"UklGRh4AAABXRUJQVlA4TBEAAAAvAYAAAAdQkUZ0pv+BiOh/AAA="];
  CGImageRef image = CreateCGImageFromFileData(data, @"WEBP", CGSizeMake(100.0, 100.0), NO);
  XCTAssertNotEqual(image, NULL);
  if (image) {
    XCTAssertEqual(CGImageGetWidth(image), (size_t)2);
    XCTAssertEqual(CGImageGetHeight(image), (size_t)3);
    CGImageRelease(image);
  }
}

- (void) testSupportedComicImageExtensionsAreCaseInsensitive {
  XCTAssertTrue(IsImageFileExtensionSupported(@"JPG"));
  XCTAssertTrue(IsImageFileExtensionSupported(@"jpeg"));
  XCTAssertTrue(IsImageFileExtensionSupported(@"Png"));
  XCTAssertTrue(IsImageFileExtensionSupported(@"GIF"));
  XCTAssertTrue(IsImageFileExtensionSupported(@"WebP"));
  XCTAssertFalse(IsImageFileExtensionSupported(@"txt"));
}

- (void) testComicReaderKeepsTheStatusBarHidden {
  ComicViewController* viewController = [[ComicViewController alloc] initWithNibName:nil bundle:nil];
  XCTAssertTrue([viewController prefersStatusBarHidden]);
}

- (void) testMiniZipListsAndExtractsAnEntryFromData {
  NSData* data = [self dataFromBase64:@"UEsDBBQAAAAAAIMYIlBR2j+NCgAAAAoAAAAIAAAAcGFnZS5qcGdjb21pYy1wYWdlUEsDBBQAAAAAAIMYIlAUNBRPCAAAAAgAAAATAAAAX19NQUNPU1gvLl9wYWdlLmpwZ21ldGFkYXRhUEsBAhQDFAAAAAAAgxgiUFHaP40KAAAACgAAAAgAAAAAAAAAAAAAAIABAAAAAHBhZ2UuanBnUEsBAhQDFAAAAAAAgxgiUBQ0FE8IAAAACAAAABMAAAAAAAAAAAAAAIABMAAAAF9fTUFDT1NYLy5fcGFnZS5qcGdQSwUGAAAAAAIAAgB3AAAAaQAAAAAA"];
  MiniZip* archive = [[MiniZip alloc] initWithArchiveData:data];
  XCTAssertNotNil(archive);
  archive.skipInvisibleFiles = YES;
  XCTAssertEqualObjects([archive retrieveFileList], (@[@"page.jpg"]));

  NSString* outputPath = [self temporaryPath:@"page.jpg"];
  XCTAssertTrue([archive extractFile:@"page.jpg" toPath:outputPath]);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:outputPath], [@"comic-page" dataUsingEncoding:NSUTF8StringEncoding]);
  [[NSFileManager defaultManager] removeItemAtPath:[outputPath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testMiniZipRejectsAnEntryWithACRCMismatch {
  NSData* data = [self dataFromBase64:@"UEsDBBQAAAAAAIMYIlBR2j+NCgAAAAoAAAAIAAAAcGFnZS5qcGdib21pYy1wYWdlUEsDBBQAAAAAAIMYIlAUNBRPCAAAAAgAAAATAAAAX19NQUNPU1gvLl9wYWdlLmpwZ21ldGFkYXRhUEsBAhQDFAAAAAAAgxgiUFHaP40KAAAACgAAAAgAAAAAAAAAAAAAAIABAAAAAHBhZ2UuanBnUEsBAhQDFAAAAAAAgxgiUBQ0FE8IAAAACAAAABMAAAAAAAAAAAAAAIABMAAAAF9fTUFDT1NYLy5fcGFnZS5qcGdQSwUGAAAAAAIAAgB3AAAAaQAAAAAA"];
  MiniZip* archive = [[MiniZip alloc] initWithArchiveData:data];
  XCTAssertNotNil(archive);

  NSString* outputPath = [self temporaryPath:@"page.jpg"];
  XCTAssertFalse([archive extractFile:@"page.jpg" toPath:outputPath]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outputPath]);
  [[NSFileManager defaultManager] removeItemAtPath:[outputPath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testMiniZipDoesNotRemoveDestinationItCouldNotOpen {
  NSData* data = [self dataFromBase64:@"UEsDBBQAAAAAAIMYIlBR2j+NCgAAAAoAAAAIAAAAcGFnZS5qcGdjb21pYy1wYWdlUEsDBBQAAAAAAIMYIlAUNBRPCAAAAAgAAAATAAAAX19NQUNPU1gvLl9wYWdlLmpwZ21ldGFkYXRhUEsBAhQDFAAAAAAAgxgiUFHaP40KAAAACgAAAAgAAAAAAAAAAAAAAIABAAAAAHBhZ2UuanBnUEsBAhQDFAAAAAAAgxgiUBQ0FE8IAAAACAAAABMAAAAAAAAAAAAAAIABMAAAAF9fTUFDT1NYLy5fcGFnZS5qcGdQSwUGAAAAAAIAAgB3AAAAaQAAAAAA"];
  MiniZip* archive = [[MiniZip alloc] initWithArchiveData:data];
  XCTAssertNotNil(archive);

  NSString* outputPath = [self temporaryPath:@"existing-directory"];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:outputPath
                                          withIntermediateDirectories:NO
                                                           attributes:nil
                                                                error:NULL]);
  XCTAssertFalse([archive extractFile:@"page.jpg" toPath:outputPath]);
  BOOL isDirectory = NO;
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outputPath isDirectory:&isDirectory]);
  XCTAssertTrue(isDirectory);
  [[NSFileManager defaultManager] removeItemAtPath:[outputPath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testUnRARListsAndExtractsAnEntry {
  NSData* data = [self dataFromBase64:@"UmFyIRoHAM+QcwAADQAAAAAAAABbn3QgkCsAEQAAABEAAAAD4oZFw/AVFEkdMAkA7YEAAGNvbnRhaW5lcgDAIyEvYmluL3NoCmV4aXQgMArEPXsAQAcA"];
  NSString* archivePath = [self temporaryPath:@"comic.rar"];
  XCTAssertTrue([data writeToFile:archivePath atomically:YES]);

  UnRAR* archive = [[UnRAR alloc] initWithArchiveAtPath:archivePath];
  XCTAssertNotNil(archive);
  XCTAssertEqualObjects([archive retrieveFileList], (@[@"container"]));

  NSString* outputPath = [[archivePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"page"];
  XCTAssertTrue([archive extractFile:@"container" toPath:outputPath]);
  XCTAssertEqualObjects([NSData dataWithContentsOfFile:outputPath], [@"#!/bin/sh\nexit 0\n" dataUsingEncoding:NSUTF8StringEncoding]);
  [[NSFileManager defaultManager] removeItemAtPath:[archivePath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testUnRARRejectsEncryptedHeaders {
  NSData* data = [self dataFromBase64:@"UmFyIRoHAM6Zc4AADQAAAAAAAABIrNhAIRyvnL7DAOAFLZzG+A7NO/d1yo9WccI/zkN1NGY52Lav1vpY7KdkEtpD+GGWYVOoC5jeS4+dr6hnUl875yOMTOFXHP/vHmAzrvzw1iEPfLrfBloS9wqgMP9XwRBT+iry0JOkk0is2EAhHK+cFprTUdL57Kx5HTKWQnadcA=="];
  NSString* archivePath = [self temporaryPath:@"encrypted-headers.rar"];
  XCTAssertTrue([data writeToFile:archivePath atomically:YES]);

  UnRAR* archive = [[UnRAR alloc] initWithArchiveAtPath:archivePath];
  XCTAssertNil(archive);
  [[NSFileManager defaultManager] removeItemAtPath:[archivePath stringByDeletingLastPathComponent] error:NULL];
}

- (void) testUnRARRejectsEncryptedFilesWithoutCreatingOutput {
  NSData* data = [self dataFromBase64:@"UmFyIRoHAM+QcwAADQAAAAAAAABgM3QklDYAIAAAABEAAAAD4oZFw4RdMl0dMwkApIEAAGNvbnRhaW5lcshnGkZU8CA1APBQHkkgL+LJ9hYn5daRoEoddsfl1tgSR5DafJgr1UQhm16H28Q9ewBABwA="];
  NSString* archivePath = [self temporaryPath:@"encrypted-file.rar"];
  XCTAssertTrue([data writeToFile:archivePath atomically:YES]);

  UnRAR* archive = [[UnRAR alloc] initWithArchiveAtPath:archivePath];
  XCTAssertNotNil(archive);
  XCTAssertNil([archive retrieveFileList]);

  NSString* directory = [archivePath stringByDeletingLastPathComponent];
  NSString* outputPath = [directory stringByAppendingPathComponent:@"page"];
  XCTAssertFalse([archive extractFile:@"container" toPath:outputPath]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outputPath]);

  NSString* bulkOutputPath = [directory stringByAppendingPathComponent:@"bulk"];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:bulkOutputPath
                                          withIntermediateDirectories:NO
                                                           attributes:nil
                                                                error:NULL]);
  XCTAssertFalse([archive extractToPath:bulkOutputPath]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[bulkOutputPath stringByAppendingPathComponent:@"container"]]);
  [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

@end
