//  Copyright (C) 2010-2016 Pierre-Olivier Latour <info@pol-online.net>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import <ImageIO/ImageIO.h>

#import "ImageDecompression.h"
#import "ImageUtilities.h"

BOOL IsImageFileExtensionSupported(NSString* extension) {
  return ![extension caseInsensitiveCompare:@"jpg"] || ![extension caseInsensitiveCompare:@"jpeg"] ||
         ![extension caseInsensitiveCompare:@"png"] || ![extension caseInsensitiveCompare:@"gif"] ||
         ![extension caseInsensitiveCompare:@"webp"];
}

static CGImageRef _CreateCGImageFromData(NSData* data) {
  CGImageRef imageRef = NULL;
  CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
  if (source) {
    imageRef = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
  }
  return imageRef;
}

CGImageRef CreateCGImageFromFileData(NSData* data, NSString* extension, CGSize targetSize, BOOL thumbnailMode) {
  CFTimeInterval time = CFAbsoluteTimeGetCurrent();
  CGImageRef imageRef = NULL;
  imageRef = _CreateCGImageFromData(data);
  if (imageRef) {
    if (thumbnailMode || (CGImageGetWidth(imageRef) > (size_t)targetSize.width) || (CGImageGetHeight(imageRef) > (size_t)targetSize.height)) {
      CGImageRef scaledImageRef = CreateScaledImage(imageRef, targetSize, thumbnailMode ? kImageScalingMode_AspectFill : kImageScalingMode_AspectFit, [[UIColor blackColor] CGColor]);
      if (scaledImageRef) {
        XLOG_VERBOSE(@"Decompressed '%@' image of %ix%i pixels and rescaled to %ix%i pixels in %.3f seconds", [extension lowercaseString],
                     (int)CGImageGetWidth(imageRef), (int)CGImageGetHeight(imageRef), (int)CGImageGetWidth(scaledImageRef), (int)CGImageGetHeight(scaledImageRef), CFAbsoluteTimeGetCurrent() - time);
      }
      CGImageRelease(imageRef);
      imageRef = scaledImageRef;
    } else {
      XLOG_VERBOSE(@"Decompressed '%@' image of %ix%i pixels in %.3f seconds", [extension lowercaseString],
                   (int)CGImageGetWidth(imageRef), (int)CGImageGetHeight(imageRef), CFAbsoluteTimeGetCurrent() - time);
    }
  }
  return imageRef;
}

CGImageRef CreateCGImageFromPDFPage(CGPDFPageRef page, CGSize targetSize, BOOL thumbnailMode) {
  // Render at 2x resolution to ensure good antialiasing
  if (thumbnailMode) {
    targetSize.width *= 2.0;
    targetSize.height *= 2.0;
  }
  return CreateRenderedPDFPage(page, targetSize, thumbnailMode ? kImageScalingMode_AspectFill : kImageScalingMode_AspectFit, [[UIColor whiteColor] CGColor]);
}
