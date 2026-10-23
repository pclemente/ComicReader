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

#import "ApplicationDelegate.h"
#import "WebServer.h"

#if DEBUG
#define kTrialMaxUploads 5
#else
#define kTrialMaxUploads 50
#endif

@interface AppDelegate : ApplicationDelegate {
  NSTimer* _updateTimer;
  BOOL _needsUpdate;
  WebServer* _webServer;
  UIWindow* _dimmingWindow;
  dispatch_queue_t _importQueue;
}
@property(nonatomic, getter=isScreenDimmed) BOOL screenDimmed;
+ (AppDelegate*) sharedDelegate;
- (void) updateLibrary;
- (BOOL) importComicAtURL:(NSURL*)url;  // Returns whether the import was queued.
- (BOOL) importComicAtURL:(NSURL*)url completion:(void (^)(BOOL imported))completion;
- (BOOL)importComicAtURL:(NSURL*)url
       resultCompletion:(void (^)(BOOL imported, NSURL* libraryURL, BOOL createdCopy))completion;
- (void)openComicURLs:(NSArray<NSURL*>*)urls;
- (void) connectWindowScene:(UIWindowScene*)scene;
@end

@interface AppDelegate (WebServer) <WebServerDelegate>
@end

@interface AppDelegate (Events)
- (void) logEvent:(NSString*)event;
- (void) logEvent:(NSString*)event withParameterName:(NSString*)name value:(NSString*)value;
- (void) logPageView;
@end
