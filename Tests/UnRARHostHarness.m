#import <Foundation/Foundation.h>

#import "UnRAR.h"

static NSData* _Fixture(NSString* base64) {
  return [[[NSData alloc] initWithBase64EncodedString:base64 options:0] autorelease];
}

static BOOL _WriteFixture(NSString* base64, NSString* path) {
  return [_Fixture(base64) writeToFile:path atomically:YES];
}

static int _Fail(NSString* message) {
  fprintf(stderr, "FAIL: %s\n", [message UTF8String]);
  return 1;
}

int main(void) {
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
  NSFileManager* files = [NSFileManager defaultManager];
  NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  if (![files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]) {
    return _Fail(@"Could not create the fixture directory");
  }

  NSString* plainPath = [root stringByAppendingPathComponent:@"plain.rar"];
  if (!_WriteFixture(@"UmFyIRoHAM+QcwAADQAAAAAAAABbn3QgkCsAEQAAABEAAAAD4oZFw/AVFEkdMAkA7YEAAGNvbnRhaW5lcgDAIyEvYmluL3NoCmV4aXQgMArEPXsAQAcA", plainPath)) {
    return _Fail(@"Could not write the ordinary RAR fixture");
  }
  UnRAR* plain = [[UnRAR alloc] initWithArchiveAtPath:plainPath];
  if (plain == nil || ![[plain retrieveFileList] isEqualToArray:[NSArray arrayWithObject:@"container"]]) {
    return _Fail(@"Ordinary RAR listing failed");
  }
  NSData* expected = [@"#!/bin/sh\nexit 0\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSString* plainOutput = [root stringByAppendingPathComponent:@"plain-output"];
  if (![plain extractFile:@"container" toPath:plainOutput] ||
      ![[NSData dataWithContentsOfFile:plainOutput] isEqualToData:expected]) {
    return _Fail(@"Ordinary RAR single-file extraction failed");
  }
  NSString* plainBulkOutput = [root stringByAppendingPathComponent:@"plain-bulk"];
  if (![files createDirectoryAtPath:plainBulkOutput withIntermediateDirectories:NO attributes:nil error:NULL] ||
      ![plain extractToPath:plainBulkOutput] ||
      ![[NSData dataWithContentsOfFile:[plainBulkOutput stringByAppendingPathComponent:@"container"]] isEqualToData:expected]) {
    return _Fail(@"Ordinary RAR bulk extraction failed");
  }
  [plain release];

  NSString* encryptedHeadersPath = [root stringByAppendingPathComponent:@"encrypted-headers.rar"];
  if (!_WriteFixture(@"UmFyIRoHAM6Zc4AADQAAAAAAAABIrNhAIRyvnL7DAOAFLZzG+A7NO/d1yo9WccI/zkN1NGY52Lav1vpY7KdkEtpD+GGWYVOoC5jeS4+dr6hnUl875yOMTOFXHP/vHmAzrvzw1iEPfLrfBloS9wqgMP9XwRBT+iry0JOkk0is2EAhHK+cFprTUdL57Kx5HTKWQnadcA==", encryptedHeadersPath)) {
    return _Fail(@"Could not write the encrypted-header fixture");
  }
  UnRAR* encryptedHeaders = [[UnRAR alloc] initWithArchiveAtPath:encryptedHeadersPath];
  if (encryptedHeaders != nil) {
    return _Fail(@"RAR with encrypted headers was accepted");
  }

  NSString* encryptedFilePath = [root stringByAppendingPathComponent:@"encrypted-file.rar"];
  if (!_WriteFixture(@"UmFyIRoHAM+QcwAADQAAAAAAAABgM3QklDYAIAAAABEAAAAD4oZFw4RdMl0dMwkApIEAAGNvbnRhaW5lcshnGkZU8CA1APBQHkkgL+LJ9hYn5daRoEoddsfl1tgSR5DafJgr1UQhm16H28Q9ewBABwA=", encryptedFilePath)) {
    return _Fail(@"Could not write the encrypted-file fixture");
  }
  UnRAR* encryptedFile = [[UnRAR alloc] initWithArchiveAtPath:encryptedFilePath];
  if (encryptedFile == nil) {
    return _Fail(@"RAR with a visible encrypted entry did not open for inspection");
  }
  if ([encryptedFile retrieveFileList] != nil) {
    return _Fail(@"Encrypted RAR entry appeared in the file list");
  }
  NSString* encryptedOutput = [root stringByAppendingPathComponent:@"encrypted-output"];
  if ([encryptedFile extractFile:@"container" toPath:encryptedOutput] ||
      [files fileExistsAtPath:encryptedOutput]) {
    return _Fail(@"Encrypted RAR single-file extraction created output");
  }
  NSString* encryptedBulkOutput = [root stringByAppendingPathComponent:@"encrypted-bulk"];
  if (![files createDirectoryAtPath:encryptedBulkOutput withIntermediateDirectories:NO attributes:nil error:NULL]) {
    return _Fail(@"Could not create the encrypted bulk output directory");
  }
  if ([encryptedFile extractToPath:encryptedBulkOutput] ||
      [files fileExistsAtPath:[encryptedBulkOutput stringByAppendingPathComponent:@"container"]]) {
    return _Fail(@"Encrypted RAR bulk extraction created output");
  }
  [encryptedFile release];

  [files removeItemAtPath:root error:NULL];
  printf("Ordinary RAR list and extraction: PASS\n");
  printf("Encrypted RAR header rejection: PASS\n");
  printf("Encrypted RAR entry rejection without output: PASS\n");
  [pool drain];
  return 0;
}
