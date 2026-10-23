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

#import "DocumentView.h"
#import "NavigationControl.h"
#import "Library.h"

@class CRAdaptiveViewportView;
@class ComicViewController;

@protocol CRExternalComicReaderDelegate <NSObject>
- (void)comicViewController:(ComicViewController*)controller
    didRequestAddExternalComicAtURL:(NSURL*)url
                   currentPageIndex:(NSInteger)currentPageIndex
                          pageCount:(NSInteger)pageCount;
- (void)comicViewControllerDidRequestOpenComicFiles:(ComicViewController*)controller;
@end

typedef enum {
  kComicType_PDF,
  kComicType_ZIP,
  kComicType_RAR
} ComicType;

// Returns the usable reader rectangle while preserving asymmetric safe-area insets.
FOUNDATION_EXPORT CGRect CRReaderContentBounds(CGRect bounds, UIEdgeInsets safeAreaInsets);
FOUNDATION_EXPORT NSString* CRDirectOpenTemporaryRootPath(void);
FOUNDATION_EXPORT void CRRemoveDirectOpenTemporaryFileAtURL(NSURL* url);

@interface ComicViewController : UIViewController <UINavigationBarDelegate, DocumentViewDelegate, NavigationControlDelegate> {
@private
  UINavigationBar* _navigationBar;
  UIView* _contentView;
  NavigationControl* _navigationControl;
  
  Comic* _comic;
  NSString* _path;
  NSURL* _externalFileURL;
  BOOL _securityScopedAccessStarted;
  BOOL _deletesExternalFileOnDealloc;
  id<CRExternalComicReaderDelegate> _externalComicDelegate;
  ComicType _type;
  id _contents;
  DocumentView* _documentView;
  UILabel* _pageLabel;
  BOOL _readerReady;
  BOOL _preservingReaderForToolsSheet;
  UIBarButtonItem* _bookmarksButtonItem;
  UIBarButtonItem* _filtersButtonItem;
  UIBarButtonItem* _textButtonItem;
  UIBarButtonItem* _addToLibraryButtonItem;
  UIToolbar* _toolsToolbar;
  CRAdaptiveViewportView* _adaptiveViewportView;
  BOOL _usingNarrowLayout;
  BOOL _usingCompactLayout;
  BOOL _adaptiveLayoutConfigured;
  BOOL _readerAcceptsScaleRefreshes;
  BOOL _selectedPageScaleRefreshScheduled;
}
@property(nonatomic, retain) IBOutlet UINavigationBar* navigationBar;
@property(nonatomic, retain) IBOutlet NavigationControl* navigationControl;
@property(nonatomic, retain) IBOutlet UIView* contentView;
- (id) initWithComic:(Comic*)comic;
- (id)initWithComic:(Comic*)comic delegate:(id<CRExternalComicReaderDelegate>)delegate;
+ (BOOL)isSupportedComicFileURL:(NSURL*)url;
- (id)initWithExternalFileURL:(NSURL*)url delegate:(id<CRExternalComicReaderDelegate>)delegate;
- (id)initWithExternalFileURL:(NSURL*)url
                     delegate:(id<CRExternalComicReaderDelegate>)delegate
         deletesFileOnDealloc:(BOOL)deletesFileOnDealloc;
@property(nonatomic, readonly, copy) NSURL* externalFileURL;
@property(nonatomic, readonly, getter=isExternalComic) BOOL externalComic;
- (void)externalComicImportDidFail;
- (IBAction) selectPage:(id)sender;
- (void) saveState;
@end
