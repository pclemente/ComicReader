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
#import "Extensions_Foundation.h"
#import "XLFunctions.h"
#import "XLDatabaseLogger.h"
#if DEBUG
#import "XLTelnetServerLogger.h"
#endif

#define kOverlayWindowLevel 100.0

#define kSpinnerBorderWidth 15.0
#define kSpinnerSpacing 10.0
#define kSpinnerFullscreenSpacing 18.0
#define kSpinnerViewAnimationDuration 0.5
#define kSpinnerFontSize 14.0
#define kSpinnerFullscreenFontSize 17.0

#define kLoggingHistoryMaxAge (7.0 * 24.0 * 60.0 * 60.0) // 7 days
#define kLoggingFontName @"Courier"
#define kLoggingFontSize 13.0

static ApplicationDelegate* _sharedInstance = nil;

@interface LogViewController : UIViewController
@end

@interface ApplicationDelegate (Internal)
- (void) _dismissAlertWithButtonIndex:(NSInteger)index;
@end

@implementation LogViewController

@end

@implementation ApplicationDelegate

@synthesize window=_window, viewController=_viewController;

+ (id) alloc {
  XLOG_DEBUG_CHECK(_sharedInstance == nil);
  _sharedInstance = [[super alloc] init];
  return _sharedInstance;
}

+ (id) sharedInstance {
  return _sharedInstance;
}

- (BOOL) application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  // Configure logging
  [XLSharedFacility setLogsUncaughtExceptions:YES];
  [XLSharedFacility setLogsInitializedExceptions:YES];
  _databaseLogger = [[XLDatabaseLogger alloc] init];
  [XLSharedFacility addLogger:_databaseLogger];
#if DEBUG
  [XLSharedFacility addLogger:[[[XLTelnetServerLogger alloc] init] autorelease]];
#endif
  
  return YES;
}

- (void) configureOverlayForWindowScene:(UIWindowScene*)scene {
  [_overlayWindow release];
  _overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
  _overlayWindow.windowLevel = kOverlayWindowLevel;
  _overlayWindow.userInteractionEnabled = NO;
  _overlayWindow.backgroundColor = [UIColor clearColor];
  _overlayWindow.rootViewController = [[[UIViewController alloc] init] autorelease];
  _overlayWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
}

- (void) enterBackground {
  // Dismiss alert views
  [self dismissAlert:NO];
  
  // Save state
  [self saveState];
  
  // Make sure user defaults are synchronized
  [[NSUserDefaults standardUserDefaults] synchronize];
  
  // Purge log history
  [_databaseLogger purgeRecordsBeforeAbsoluteTime:(CFAbsoluteTimeGetCurrent() - kLoggingHistoryMaxAge)];
  
  XLOG_VERBOSE(@"Application did enter background");
}

- (void) enterForeground {
  XLOG_VERBOSE(@"Application will enter foreground");
  
  // Make sure user defaults are synchronized
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void) applicationWillTerminate:(UIApplication*)application {
  // Dismiss alert views
  [self dismissAlert:NO];
  
  // Save state
  [self saveState];
  
  // Make sure user defaults are synchronized
  [[NSUserDefaults standardUserDefaults] synchronize];
  
  // Purge log history
  [_databaseLogger purgeRecordsBeforeAbsoluteTime:(CFAbsoluteTimeGetCurrent() - kLoggingHistoryMaxAge)];
}

- (void) saveState {
  ;
}

@end

@implementation ApplicationDelegate (Logging)

- (void) purgeLogHistory {
  [_databaseLogger purgeAllRecords];
}

- (void) _logViewControllerDone:(id)sender {
  [_viewController dismissViewControllerAnimated:YES completion:nil];
}

- (void) showLogViewController {
  NSMutableString* log = [NSMutableString string];
  [_databaseLogger enumerateAllRecordsBackward:YES usingBlock:^(int appVersion, XLLogRecord* record, BOOL* stop) {
    NSString* date = [[NSDate dateWithTimeIntervalSinceReferenceDate:record.absoluteTime] stringWithCachedFormat:@"yyyy-MM-dd HH:mm:ss.SSS" localIdentifier:@"en_US"];
    [log appendFormat:@"[r%i | %@ | %@] %@\n", appVersion, date, XLStringFromLogLevelName(record.level), record.message];
  }];
  
  UITextView* view = [[UITextView alloc] init];
  view.text = log;
  view.textColor = [UIColor darkGrayColor];
  view.font = [UIFont fontWithName:kLoggingFontName size:kLoggingFontSize];
  view.editable = NO;
  view.dataDetectorTypes = UIDataDetectorTypeNone;
  
  LogViewController* viewController = [[LogViewController alloc] init];
  viewController.view = view;
  viewController.navigationItem.title = NSLocalizedString(@"LOG_TITLE", nil);
  viewController.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                                    target:self
                                                                                                    action:@selector(_logViewControllerDone:)] autorelease];
  UINavigationController* navigationController = [[UINavigationController alloc] initWithRootViewController:viewController];
  [_viewController presentViewController:navigationController animated:YES completion:nil];
  [navigationController release];
  [viewController release];
  
  [view release];
}

@end

@implementation ApplicationDelegate (Alerts)

- (BOOL) isAlertVisible {
  return _alertView ? YES : NO;
}

- (void) _dismissAlertWithButtonIndex:(NSInteger)index {
  // Clear ownership before invoking client code: callbacks may show another alert.
  id delegate = _alertDelegate;
  id argument = _alertArgument;
  SEL selector = index == 0 ? _alertCancelSelector : _alertConfirmSelector;
  UIAlertController* alert = _alertView;
  _alertView = nil;
  _alertDelegate = nil;
  _alertArgument = nil;
  _alertCancelSelector = NULL;
  _alertConfirmSelector = NULL;
  if (delegate && selector) {
    [delegate performSelector:selector withObject:argument];
  }
  [argument release];
  [delegate release];
  [alert release];
}

- (void) presentPendingAlert {
  if (!_alertView || _alertView.presentingViewController || !_viewController.view.window ||
      _window.windowScene.activationState != UISceneActivationStateForegroundActive) {
    return;
  }
  UIViewController* top = _viewController;
  while (top.presentedViewController) {
    top = top.presentedViewController;
  }
  // UIKit must finish dismissing the previous controller before presenting its replacement.
  if (top.isBeingDismissed || top.isBeingPresented) {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(presentPendingAlert) object:nil];
    [self performSelector:@selector(presentPendingAlert) withObject:nil afterDelay:0.05];
    return;
  }
  [top presentViewController:_alertView animated:YES completion:nil];
}

- (void) showAlertWithTitle:(NSString*)title message:(NSString*)message button:(NSString*)button {
  [self showAlertWithTitle:title message:message button:button delegate:nil selector:NULL argument:nil];
}

- (void) showAlertWithTitle:(NSString*)title
                    message:(NSString*)message
                     button:(NSString*)button
                   delegate:(id)delegate
                   selector:(SEL)selector
                   argument:(id)argument {
  [self showAlertWithTitle:title
                   message:message
             confirmButton:button
              cancelButton:nil
                  delegate:delegate
           confirmSelector:selector
            cancelSelector:nil
                  argument:argument];
}

- (void) showAlertWithTitle:(NSString*)title
                    message:(NSString*)message
              confirmButton:(NSString*)confirmButton
               cancelButton:(NSString*)cancelButton
                   delegate:(id)delegate
            confirmSelector:(SEL)confirmSelector
             cancelSelector:(SEL)cancelSelector
                   argument:(id)argument {
  XLOG_CHECK(title);
  XLOG_CHECK(confirmButton);
  NSUInteger previousGeneration = _alertGeneration;
  [self dismissAlert:NO];
  if (_alertGeneration != previousGeneration) {
    // A cancellation callback requested a newer alert; preserve its ownership and state.
    return;
  }

  UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  _alertView = [alert retain];
  NSUInteger generation = ++_alertGeneration;
  _alertDelegate = [delegate retain];
  _alertConfirmSelector = confirmSelector;
  _alertCancelSelector = cancelSelector;
  _alertArgument = [argument retain];

  if (cancelButton) {
    UIAlertAction* cancel = [UIAlertAction actionWithTitle:cancelButton
                                                     style:UIAlertActionStyleCancel
                                                   handler:^(UIAlertAction* action) {
      if (_alertView && _alertGeneration == generation) {
        [self _dismissAlertWithButtonIndex:0];
      }
    }];
    [alert addAction:cancel];
  }

  UIAlertAction* confirm = [UIAlertAction actionWithTitle:confirmButton
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction* action) {
    if (_alertView && _alertGeneration == generation) {
      [self _dismissAlertWithButtonIndex:1];
    }
  }];
  [alert addAction:confirm];

  // Deferring also permits alerts requested during scene setup to be presented after launch.
  [self performSelector:@selector(presentPendingAlert) withObject:nil afterDelay:0.0];
}

- (void) dismissAlert:(BOOL)animated {
  if (_alertView) {
    UIAlertController* alert = [_alertView retain];
    [alert dismissViewControllerAnimated:animated completion:nil];
    [self _dismissAlertWithButtonIndex:0];
    [alert release];
  }
}

@end

@implementation ApplicationDelegate (Spinner)

- (BOOL) isSpinnerVisible {
  return _spinnerView ? YES : NO;
}

- (void) showSpinnerWithMessage:(NSString*)message fullScreen:(BOOL)fullScreen animated:(BOOL)animated {
  CGRect frame;
  
  [self hideSpinner:NO];
  
  UIActivityIndicatorView* indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
  indicator.frame = CGRectOffset(indicator.frame, kSpinnerBorderWidth, kSpinnerBorderWidth);
  indicator.hidesWhenStopped = NO;
  indicator.color = [UIColor whiteColor];
  [indicator autorelease];
  CGSize size = indicator.frame.size;
  frame.size.width = size.width + 2.0 * kSpinnerBorderWidth;
  frame.size.height = size.height + 2.0 * kSpinnerBorderWidth;
  
  UILabel* label = nil;
  if (message) {
    label = [[UILabel alloc] init];
    label.backgroundColor = nil;
    label.opaque = NO;
    label.font = [UIFont boldSystemFontOfSize:(fullScreen ? kSpinnerFullscreenFontSize : kSpinnerFontSize)];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.text = message;
    [label sizeToFit];
    [label autorelease];
    CGRect rect = label.frame;
    rect.origin.x = kSpinnerBorderWidth;
    rect.origin.y = frame.size.height - kSpinnerBorderWidth + (fullScreen ? kSpinnerFullscreenSpacing : kSpinnerSpacing);
    label.frame = rect;
    frame.size.width += rect.size.width - size.width;
    frame.size.height += rect.size.height + (fullScreen ? kSpinnerFullscreenSpacing : kSpinnerSpacing);
    CGRect temp = indicator.frame;
    temp.origin.x = roundf(temp.origin.x - temp.size.width / 2.0 + rect.size.width / 2.0);
    indicator.frame = temp;
  }

  CGRect bounds = _overlayWindow.bounds;
  frame.origin.x = roundf(bounds.size.width / 2.0 - frame.size.width / 2.0);
  frame.origin.y = roundf(bounds.size.height / 2.0 - frame.size.height / 2.0);
  UIView* spinnerView = [[UIView alloc] initWithFrame:frame];
  spinnerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                 UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
  [spinnerView addSubview:indicator];
  if (label) {
    [spinnerView addSubview:label];
  }
  if (fullScreen) {
    _spinnerView = [[UIView alloc] initWithFrame:bounds];
    _spinnerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_spinnerView addSubview:spinnerView];
    [spinnerView release];
  } else {
    _spinnerView = spinnerView;
    _spinnerView.layer.cornerRadius = 10.0;
  }
  _spinnerView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
  [_overlayWindow.rootViewController.view addSubview:_spinnerView];
  _overlayWindow.hidden = NO;
  if (animated) {
    _spinnerView.alpha = 0.0;
    [UIView animateWithDuration:kSpinnerViewAnimationDuration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ _spinnerView.alpha = 1.0; }
                     completion:nil];
  }
  
  [indicator startAnimating];
}

- (void) hideSpinner:(BOOL)animated {
  UIView* spinner = _spinnerView;
  _spinnerView = nil;
  if (spinner) {
    if (animated) {
      [UIView animateWithDuration:kSpinnerViewAnimationDuration
                            delay:0
                          options:UIViewAnimationOptionCurveEaseIn
                       animations:^{ spinner.alpha = 0.0; }
                       completion:^(BOOL finished) {
        [spinner removeFromSuperview];
        if (!_spinnerView) {
          _overlayWindow.hidden = YES;
        }
      }];
    } else {
      [spinner removeFromSuperview];
      _overlayWindow.hidden = YES;
    }
    [spinner release];
  }
}

@end
