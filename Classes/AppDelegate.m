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

#import "AppDelegate.h"
#import "Library.h"
#import "LibraryViewController.h"
#import "Defaults.h"
#import "Extensions_Foundation.h"
#import "Extensions_UIKit.h"
#import "NetReachability.h"
#import "CRLibrarySyncCoordinator.h"
#import "ComicFlow-Swift.h"

#define kUpdateDelay 1.0
#define kScreenDimmingOpacity 0.5

@implementation AppDelegate

+ (void) initialize {
  // Setup initial user defaults
  NSMutableDictionary* defaults = [[NSMutableDictionary alloc] init];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_LibraryVersion];
  [defaults setObject:[NSNumber numberWithInteger:kServerMode_Full] forKey:kDefaultKey_ServerMode];
  [defaults setObject:[NSNumber numberWithInteger:kTrialMaxUploads] forKey:kDefaultKey_UploadsRemaining];
  [defaults setObject:[NSNumber numberWithBool:NO] forKey:kDefaultKey_ScreenDimmed];
  [defaults setObject:[NSNumber numberWithDouble:0.0] forKey:kDefaultKey_RootTimestamp];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_RootScrolling];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_CurrentCollection];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_CurrentComic];
  [defaults setObject:[NSNumber numberWithInteger:kSortingMode_ByStatus] forKey:kDefaultKey_SortingMode];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_LaunchCount];
  [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
  [defaults release];
  
  // Seed random generator
  srandomdev();
}

+ (AppDelegate*) sharedDelegate {
  return (AppDelegate*)[[UIApplication sharedApplication] delegate];
}

- (void) _updateTimer:(NSTimer*)timer {
  if ([[LibraryUpdater sharedUpdater] isUpdating]) {
    [_updateTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:kUpdateDelay]];
  } else {
    [[LibraryUpdater sharedUpdater] update:NO];
  }
}

- (void) updateLibrary {
  [self _updateTimer:nil];
}

- (BOOL) application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  [super application:application didFinishLaunchingWithOptions:launchOptions];
  XLOG_CHECK([LibraryConnection mainConnection]);

  [[CRLibrarySyncCoordinator sharedCoordinator] start];
  [[CRPlusStore sharedStore] start];

  // Keep unlimited transfers free, including installations with old trial settings.
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  [defaults setInteger:kServerMode_Full forKey:kDefaultKey_ServerMode];
  [defaults removeObjectForKey:kDefaultKey_UploadsRemaining];
  
#if TARGET_IPHONE_SIMULATOR
  // Log Documents folder path
  XLOG_VERBOSE(@"Documents folder location: %@", [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]);
#endif
  
  // Prevent mobile device backups from duplicating the offline comic library.
  // On macOS, the sandbox Documents directory is the user's primary local
  // library and should remain eligible for Time Machine backups.
#if !TARGET_OS_MACCATALYST
  NSString* documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
  NSURL* documentsURL = [NSURL fileURLWithPath:documentsPath];
  NSError* backupError = nil;
  if (![documentsURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&backupError]) {
    XLOG_ERROR(@"Failed setting do-not-backup attribute on \"%@\": %@", documentsPath, backupError);
  }
#endif
  
  // Initialize update timer
  _updateTimer = [[NSTimer alloc] initWithFireDate:[NSDate distantFuture]
                                          interval:HUGE_VAL
                                            target:self
                                          selector:@selector(_updateTimer:)
                                          userInfo:nil
                                           repeats:YES];
  [[NSRunLoop currentRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];

  // Initialize web server
  [[WebServer sharedWebServer] setDelegate:self];

  return YES;
}

- (void) connectWindowScene:(UIWindowScene*)scene {
#if TARGET_OS_MACCATALYST
  // Keep the legacy fixed-size controls usable while still allowing a normal,
  // resizable Mac window and full-screen reading.
  scene.sizeRestrictions.minimumSize = CGSizeMake(700.0, 500.0);
#endif
  if (self.window.windowScene == scene) {
    return;
  }
  if (self.window) {
    // Reconnect the existing library after UIKit discards a scene connection.
    self.window.windowScene = scene;
    _dimmingWindow.windowScene = scene;
    [self hideSpinner:NO];
    [self configureOverlayForWindowScene:scene];
    [self.window makeKeyAndVisible];
    [self updateLibrary];
    return;
  }
  [self saveState];
  self.window = [[[UIWindow alloc] initWithWindowScene:scene] autorelease];
  [self configureOverlayForWindowScene:scene];

  // Create root view controller
  self.viewController = [[[LibraryViewController alloc] initWithWindow:self.window] autorelease];
  
  // Initialize updater
  [[LibraryUpdater sharedUpdater] setDelegate:(LibraryViewController*)self.viewController];
  
  // Update library immediately
  if ([[LibraryConnection mainConnection] countObjectsOfClass:[Comic class]] == 0) {
    [[LibraryUpdater sharedUpdater] update:YES];
    [[NSUserDefaults standardUserDefaults] setInteger:kLibraryVersion forKey:kDefaultKey_LibraryVersion];
  } else {
    [[LibraryUpdater sharedUpdater] update:NO];
  }
  
  self.window.rootViewController = self.viewController;
  [self.window makeKeyAndVisible];

  [_dimmingWindow release];
  _dimmingWindow = [[UIWindow alloc] initWithWindowScene:scene];
  _dimmingWindow.userInteractionEnabled = NO;
  _dimmingWindow.windowLevel = UIWindowLevelStatusBar;
  _dimmingWindow.backgroundColor = [UIColor clearColor];
  _dimmingWindow.rootViewController = [[[UIViewController alloc] init] autorelease];
  _dimmingWindow.rootViewController.view.backgroundColor = [UIColor blackColor];
  _dimmingWindow.alpha = self.isScreenDimmed ? kScreenDimmingOpacity : 0.0;
  _dimmingWindow.hidden = !self.isScreenDimmed;
}

- (BOOL) importComicAtURL:(NSURL*)url {
  return [self importComicAtURL:url completion:nil];
}

- (BOOL) importComicAtURL:(NSURL*)url completion:(void (^)(BOOL))completion {
  if (!url.isFileURL || [url.lastPathComponent hasPrefix:@"."] ||
      ![@[@"pdf", @"cbz", @"zip", @"cbr", @"rar"] containsObject:url.pathExtension.lowercaseString]) {
    if (completion) {
      completion(NO);
    }
    return NO;
  }
  if (!_importQueue) {
    _importQueue = dispatch_queue_create("com.comicreader.import", DISPATCH_QUEUE_SERIAL);
  }
  dispatch_async(_importQueue, ^{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    BOOL scoped = [url startAccessingSecurityScopedResource];
    __block NSError* copyError = nil;
    NSError* coordinationError = nil;
    __block BOOL imported = NO;
    NSFileCoordinator* coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
    [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL* readableURL) {
      NSNumber* regularFile = nil;
      if (![readableURL getResourceValue:&regularFile forKey:NSURLIsRegularFileKey error:&copyError] || !regularFile.boolValue) {
        [copyError retain];
        return;
      }
      NSString* root = [[LibraryConnection libraryRootPath] stringByResolvingSymlinksInPath];
      NSString* source = [readableURL.path stringByResolvingSymlinksInPath];
      // The indexer supports root comics and one visible collection folder.
      if ([source hasPrefix:[root stringByAppendingString:@"/"]]) {
        NSArray* components = [[source substringFromIndex:root.length + 1] pathComponents];
        BOOL indexedLocation = components.count <= 2 && ![components.firstObject isEqualToString:@"Inbox"];
        for (NSString* component in components) {
          indexedLocation &= ![component hasPrefix:@"."];
        }
        if (indexedLocation) {
          imported = YES;
          return;
        }
      }
      NSFileManager* manager = [NSFileManager defaultManager];
      NSString* filename = url.lastPathComponent;
      NSString* destination = [root stringByAppendingPathComponent:filename];
      NSUInteger suffix = 2;
      while ([manager fileExistsAtPath:destination]) {
        filename = [NSString stringWithFormat:@"%@ (%lu).%@", url.lastPathComponent.stringByDeletingPathExtension, (unsigned long)suffix++, url.pathExtension];
        destination = [root stringByAppendingPathComponent:filename];
      }
      // Copy via a hidden staging file so the updater cannot index a partially copied archive.
      NSString* staging = [NSTemporaryDirectory() stringByAppendingPathComponent:[@".comicreader-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
      imported = [manager copyItemAtPath:source toPath:staging error:&copyError] &&
                 [manager moveItemAtPath:staging toPath:destination error:&copyError];
      if (!imported) {
        [copyError retain];
        [manager removeItemAtPath:staging error:NULL];
      }
    }];
    if (scoped) {
      [url stopAccessingSecurityScopedResource];
    }
    NSError* error = coordinationError ?: copyError;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (imported) {
        [self updateLibrary];
        [self logEvent:@"app.open"];
      } else {
        XLOG_ERROR(@"Unable to import %@: %@", url.lastPathComponent, error);
        [self showAlertWithTitle:NSLocalizedString(@"IMPORT_FAILED_TITLE", nil)
                        message:error.localizedDescription ?: NSLocalizedString(@"IMPORT_FAILED_MESSAGE", nil)
                         button:NSLocalizedString(@"INBOX_ALERT_BUTTON", nil)];
      }
      if (completion) {
        completion(imported);
      }
    });
    [copyError release];
    [pool drain];
  });
  return YES;
}

- (void) saveState {
  [(LibraryViewController*)self.viewController saveState];
}

- (BOOL) isScreenDimmed {
  return [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultKey_ScreenDimmed];
}

- (void) setScreenDimmed:(BOOL)flag {
  if (flag) {
    _dimmingWindow.hidden = NO;
  }
  [UIView animateWithDuration:(1.0 / 3.0) animations:^{
    _dimmingWindow.alpha = flag ? kScreenDimmingOpacity : 0.0;
  } completion:^(BOOL finished) {
    if (!self.isScreenDimmed) {
      _dimmingWindow.hidden = YES;
    }
  }];
  [[NSUserDefaults standardUserDefaults] setBool:flag forKey:kDefaultKey_ScreenDimmed];
}

@end

@implementation AppDelegate (WebServer)

- (NSString*) _serverMode {
  switch ([[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_ServerMode]) {
    case kServerMode_Limited: return @"Limited";
    case kServerMode_Trial: return @"Trial";
    case kServerMode_Full: return @"Full";
  }
  return nil;
}

- (void) webServerDidConnect:(WebServer*)server {
  [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
}

- (void) webServerDidDownloadComic:(WebServer*)server {
  [self logEvent:@"server.download" withParameterName:@"mode" value:[self _serverMode]];
}

- (void) webServerDidUploadComic:(WebServer*)server {
  [self logEvent:@"server.upload" withParameterName:@"mode" value:[self _serverMode]];
  _needsUpdate = YES;
}

- (void) webServerDidUpdate:(WebServer*)server {
  _needsUpdate = YES;
}

- (void) webServerDidDisconnect:(WebServer*)server {
  [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
  
  if (_needsUpdate) {
    [self _updateTimer:nil];
    _needsUpdate = NO;
  }
}

@end

@implementation AppDelegate (Events)

- (void) logEvent:(NSString*)event {
  [self logEvent:event withParameterName:nil value:nil];
}

- (void) logEvent:(NSString*)event withParameterName:(NSString*)name value:(NSString*)value {
  if (name && value) {
    XLOG_VERBOSE(@"<EVENT> %@ ('%@' = '%@')", event, name, value);
    // TODO
  } else {
    XLOG_VERBOSE(@"<EVENT> %@", event);
    // TODO
  }
}

- (void) logPageView {
  XLOG_VERBOSE(@"<PAGE VIEW>");
  // TODO
}

@end

// Keep a single library window, while using the scene lifecycle required by modern iPadOS.
@interface ComicSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, retain) UIWindow* window;
@property(nonatomic) BOOL skipInitialForegroundScan;
@end

@implementation ComicSceneDelegate
@synthesize window = _window;

- (void) scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)connectionOptions {
  AppDelegate* delegate = [AppDelegate sharedDelegate];
  [delegate connectWindowScene:(UIWindowScene*)scene];
  self.window = delegate.window;
  self.skipInitialForegroundScan = YES;
  for (UIOpenURLContext* context in connectionOptions.URLContexts) {
    [delegate importComicAtURL:context.URL];
  }
}

- (void) scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
  for (UIOpenURLContext* context in URLContexts) {
    [[AppDelegate sharedDelegate] importComicAtURL:context.URL];
  }
}

- (void) sceneWillEnterForeground:(UIScene*)scene {
  [[AppDelegate sharedDelegate] enterForeground];
  if (!self.skipInitialForegroundScan) {
    [[AppDelegate sharedDelegate] updateLibrary];
  }
  self.skipInitialForegroundScan = NO;
}

- (void) sceneDidBecomeActive:(UIScene*)scene {
  [[AppDelegate sharedDelegate] presentPendingAlert];
  [[CRPlusStore sharedStore] refreshEntitlementStatus];
  [[CRLibrarySyncCoordinator sharedCoordinator] synchronize];
}

- (void) sceneWillResignActive:(UIScene*)scene {
  [[AppDelegate sharedDelegate] saveState];
}

- (void) sceneDidEnterBackground:(UIScene*)scene {
  [[AppDelegate sharedDelegate] enterBackground];
}

- (void) sceneDidDisconnect:(UIScene*)scene {
  [[AppDelegate sharedDelegate] saveState];
  self.window = nil;
}

- (void) dealloc {
  [_window release];
  [super dealloc];
}
@end
