// Copyright 2011 Cooliris, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "UnRAR.h"
#import "raros.hpp"
#import "dll.hpp"

#include <stdint.h>

// http://www.rarlab.com/rar_add.htm
// http://goahomepage.free.fr/article/2000_09_17_unrar_dll/UnRARDLL.html

static const unsigned int kRARMainHeaderFlagPassword = 0x0080U;
static const unsigned int kRARFileHeaderFlagPassword = 0x0004U;

static NSString* _PathFromFileName(const char* filename) {
  NSString* path = [NSString stringWithCString:filename encoding:NSUTF8StringEncoding];
  if (path == nil) {
    path = [NSString stringWithCString:filename encoding:NSISOLatin1StringEncoding];
  }
  XLOG_DEBUG_CHECK(path);
  return path;
}

static HANDLE _OpenArchive(NSString* path, unsigned int mode) {
  struct RAROpenArchiveDataEx archiveData;
  bzero(&archiveData, sizeof(archiveData));
  archiveData.ArcName = (char*)[path fileSystemRepresentation];
  archiveData.OpenMode = mode;
  HANDLE handle = RAROpenArchiveEx(&archiveData);
  if (handle == NULL) {
    XLOG_ERROR(@"UnRAR failed opening archive");
    return NULL;
  }
  if (archiveData.Flags & kRARMainHeaderFlagPassword) {
    XLOG_ERROR(@"Encrypted RAR headers are unsupported");
    RARCloseArchive(handle);
    return NULL;
  }
  return handle;
}

static BOOL _RARFileIsEncrypted(const struct RARHeaderData* headerData) {
  if (headerData->Flags & kRARFileHeaderFlagPassword) {
    XLOG_ERROR(@"Encrypted RAR files are unsupported");
    return YES;
  }
  return NO;
}

typedef struct {
  unsigned long long maximumBytes;
  unsigned long long processedBytes;
  BOOL exceededLimit;
} CRRARExtractionLimit;

static int CALLBACK _RARExtractionLimitCallback(UINT message, LPARAM userData, LPARAM data, LPARAM dataSize) {
  if (message != UCM_PROCESSDATA) return 0;
  (void)data;
  CRRARExtractionLimit* limit = (CRRARExtractionLimit*)(uintptr_t)userData;
  if (!limit || dataSize < 0) return -1;
  unsigned long long byteCount = (unsigned long long)dataSize;
  if (limit->processedBytes > limit->maximumBytes ||
      byteCount > limit->maximumBytes - limit->processedBytes) {
    limit->exceededLimit = YES;
    return -1;
  }
  limit->processedBytes += byteCount;
  return 0;
}

@implementation UnRAR

@synthesize skipInvisibleFiles=_skipInvisible;

+ (BOOL) extractRARArchiveAtPath:(NSString*)inPath toPath:(NSString*)outPath {
  BOOL success = NO;
  UnRAR* archive = [[UnRAR alloc] initWithArchiveAtPath:inPath];
  if (archive) {
    success = [archive extractToPath:outPath];
    [archive release];
  }
  return success;
}

- (id) initWithArchiveAtPath:(NSString*)path {
  if ((self = [super init])) {
    _archivePath = [path copy];

    HANDLE handle = _OpenArchive(_archivePath, RAR_OM_LIST);
    if (handle) {
      RARCloseArchive(handle);
    } else {
      [self release];
      return nil;
    }
  }
  return self;
}

- (void) dealloc {
  [_archivePath release];
  
  [super dealloc];
}

- (NSArray*) retrieveFileList {
  NSMutableArray* array = nil;
  
  // Open archive
  HANDLE handle = _OpenArchive(_archivePath, RAR_OM_LIST);
  if (handle) {
    array = [NSMutableArray array];
    
    // Scan archive
    while (1) {
      // Retrieve current file information
      struct RARHeaderData headerData;
      bzero(&headerData, sizeof(headerData));
      int result = RARReadHeader(handle, &headerData);
      if (result != 0) {
        if (result != ERAR_END_ARCHIVE) {
          XLOG_ERROR(@"UnRAR returned error %i", result);
          array = nil;
        }
        break;
      }
      if (_RARFileIsEncrypted(&headerData)) {
        array = nil;
        break;
      }
      NSString* path = _PathFromFileName(headerData.FileName);
      
      // Add current file to list if necessary
      if (_skipInvisible) {
        for (NSString* string in [path pathComponents]) {
          if ([string hasPrefix:@"."]) {
            path = nil;
            break;
          }
        }
      }
      if (path && headerData.FileCRC) {
        [array addObject:path];
      }
      
      // Find next file
      result = RARProcessFile(handle, RAR_SKIP, NULL, NULL);
      if (result != 0) {
        XLOG_ERROR(@"UnRAR returned error %i", result);
        array = nil;
        break;
      }
    }
    
    // Close archive
    RARCloseArchive(handle);
  }
  
  return array;
}

- (BOOL) extractToPath:(NSString*)outPath {
  BOOL success = NO;
  
  // Open archive
  HANDLE handle = _OpenArchive(_archivePath, RAR_OM_EXTRACT);
  if (handle) {
    const char* destination = [outPath fileSystemRepresentation];
    success = YES;
    
    // Scan archive
    while (1) {
      // Retrieve current file information
      struct RARHeaderData headerData;
      bzero(&headerData, sizeof(headerData));
      int result = RARReadHeader(handle, &headerData);
      if (result != 0) {
        if (result != ERAR_END_ARCHIVE) {
          XLOG_ERROR(@"UnRAR returned error %i", result);
          success = NO;
        }
        break;
      }
      if (_RARFileIsEncrypted(&headerData)) {
        success = NO;
        break;
      }
      NSString* path = _PathFromFileName(headerData.FileName);
      
      // Add current file to list if necessary
      if (_skipInvisible) {
        for (NSString* string in [path pathComponents]) {
          if ([string hasPrefix:@"."]) {
            path = nil;
            break;
          }
        }
      }
      
      // Extract and find next file
      result = RARProcessFile(handle, path && headerData.FileCRC ? RAR_EXTRACT : RAR_SKIP, (char*)destination, NULL);
      if (result != 0) {
        XLOG_ERROR(@"UnRAR returned error %i", result);
        success = NO;
        break;
      }
    }
    
    // Close archive
    RARCloseArchive(handle);
  }
  
  return success;
}

- (BOOL) extractFile:(NSString*)inPath toPath:(NSString*)outPath {
  BOOL success = NO;
  
  // Open archive
  HANDLE handle = _OpenArchive(_archivePath, RAR_OM_EXTRACT);
  if (handle) {
    
    // Scan archive
    while (1) {
      // Retrieve current file information
      struct RARHeaderData headerData;
      bzero(&headerData, sizeof(headerData));
      int result = RARReadHeader(handle, &headerData);
      if (result != 0) {
        if (result != ERAR_END_ARCHIVE) {
          XLOG_ERROR(@"UnRAR returned error %i", result);
        }
        break;
      }
      if (_RARFileIsEncrypted(&headerData)) {
        break;
      }
      NSString* path = _PathFromFileName(headerData.FileName);
      
      // Extract if necessary and find next file
      if (headerData.FileCRC && [path isEqualToString:inPath]) {
        result = RARProcessFile(handle, RAR_EXTRACT, NULL, (char*)[outPath fileSystemRepresentation]);
        if (result != 0) {
          XLOG_ERROR(@"UnRAR returned error %i", result);
        } else {
          success = YES;
        }
        break;
      } else {
        result = RARProcessFile(handle, RAR_SKIP, NULL, NULL);
        if (result != 0) {
          XLOG_ERROR(@"UnRAR returned error %i", result);
          break;
        }
      }
    }
    
    // Close archive
    RARCloseArchive(handle);
  }
  
  return success;
}

- (BOOL) extractFile:(NSString*)inPath
              toPath:(NSString*)outPath
maximumUncompressedBytes:(unsigned long long)maximumUncompressedBytes {
  if (maximumUncompressedBytes == 0) return [self extractFile:inPath toPath:outPath];

  BOOL success = NO;
  BOOL outputExisted = [[NSFileManager defaultManager] fileExistsAtPath:outPath];

  // Open archive
  HANDLE handle = _OpenArchive(_archivePath, RAR_OM_EXTRACT);
  if (handle) {
    // Scan archive
    while (1) {
      // Use the extended header so the preflight includes entries larger than 4 GiB.
      struct RARHeaderDataEx headerData;
      bzero(&headerData, sizeof(headerData));
      int result = RARReadHeaderEx(handle, &headerData);
      if (result != 0) {
        if (result != ERAR_END_ARCHIVE) {
          XLOG_ERROR(@"UnRAR returned error %i", result);
        }
        break;
      }
      if (headerData.Flags & kRARFileHeaderFlagPassword) {
        XLOG_ERROR(@"Encrypted RAR files are unsupported");
        break;
      }
      NSString* path = _PathFromFileName(headerData.FileName);

      if (headerData.FileCRC && [path isEqualToString:inPath]) {
        unsigned long long uncompressedSize =
          ((unsigned long long)headerData.UnpSizeHigh << 32) | headerData.UnpSize;
        if (uncompressedSize > maximumUncompressedBytes) {
          XLOG_ERROR(@"Refusing to extract oversized RAR entry \"%@\" (%llu bytes; limit %llu)",
                     path, uncompressedSize, maximumUncompressedBytes);
          break;
        }

        // The callback runs before UnRAR writes each decompressed block, making
        // the limit authoritative even when archive metadata is malformed.
        CRRARExtractionLimit limit = {maximumUncompressedBytes, 0, NO};
        RARSetCallback(handle, _RARExtractionLimitCallback, (LPARAM)(uintptr_t)&limit);
        result = RARProcessFile(handle, RAR_EXTRACT, NULL, (char*)[outPath fileSystemRepresentation]);
        if (result == 0 && !limit.exceededLimit) {
          success = YES;
        } else if (limit.exceededLimit) {
          XLOG_ERROR(@"RAR entry \"%@\" exceeded its %llu-byte extraction limit",
                     path, maximumUncompressedBytes);
        } else {
          XLOG_ERROR(@"UnRAR returned error %i", result);
        }
        break;
      } else {
        result = RARProcessFile(handle, RAR_SKIP, NULL, NULL);
        if (result != 0) {
          XLOG_ERROR(@"UnRAR returned error %i", result);
          break;
        }
      }
    }

    RARCloseArchive(handle);
  }

  if (!success && !outputExisted) {
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:NULL];
  }
  return success;
}

@end
