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

#import "ZoomView.h"
#import "Logging.h"

#define kAutomaticTolerance 0.1
#define kZoomTolerance 0.01

@interface ZoomView (UIScrollViewDelegate) <UIScrollViewDelegate>
- (void) _saveCurrentFocusPoint;
- (void) _saveRelativeZoomScale:(CGFloat)zoomScale;
@end

@implementation ZoomView

@synthesize displayView=_displayView, displayMode=_displayMode, doubleTapZoom=_doubleTapZoom, doubleTapRecognizer=_doubleTapRecognizer;

+ (NSTimeInterval) defaultAnimationDuration {
  return (1.0 / 3.0);
}

- (void) _resetFocusPoint {
  _sourceFocusPoint.x = _displaySize.width / 2.0;
  _sourceFocusPoint.y = _displaySize.height / 2.0;
  _relativeZoomScale = 1.0;
}

- (void) _saveFocusPointForContentOffset:(CGPoint)offset boundsSize:(CGSize)boundsSize zoomScale:(CGFloat)zoomScale {
  if (zoomScale > 0.0) {
    _sourceFocusPoint.x = MIN(MAX((offset.x + boundsSize.width / 2.0) / zoomScale, 0.0), _displaySize.width);
    _sourceFocusPoint.y = MIN(MAX((offset.y + boundsSize.height / 2.0) / zoomScale, 0.0), _displaySize.height);
  }
}

- (void) _saveCurrentFocusPoint {
  if (_displayView && !_isApplyingGeometryChange) {
    [self _saveFocusPointForContentOffset:self.contentOffset boundsSize:self.bounds.size zoomScale:self.zoomScale];
  }
}

- (void) _saveRelativeZoomScale:(CGFloat)zoomScale {
  if (_displayView && !_isApplyingGeometryChange && self.minimumZoomScale > 0.0) {
    CGFloat relativeZoomScale = zoomScale / self.minimumZoomScale;
    _relativeZoomScale = relativeZoomScale <= 1.0 + kZoomTolerance ? 1.0 : relativeZoomScale;
  }
}

- (void) _preserveFocusBeforeSizeChange {
  if (!_hasPendingSizeChangeFocus && _displayView && !CGSizeEqualToSize(_oldSize, CGSizeZero)) {
    // _sourceFocusPoint already records the last user-selected position.
    // Geometry may clamp the visible midpoint, but must not replace that intent.
    _hasPendingSizeChangeFocus = YES;
  }
}

- (void) setFrame:(CGRect)frame {
  CGSize oldBoundsSize = self.bounds.size;
  BOOL alreadyPending = _hasPendingSizeChangeFocus;
  BOOL sizeChanged = !CGSizeEqualToSize(frame.size, self.frame.size);
  if (sizeChanged) {
    _geometryGeneration += 1;
    [self _preserveFocusBeforeSizeChange];
  }
  BOOL wasApplyingGeometryChange = _isApplyingGeometryChange;
  if (sizeChanged) {
    _isApplyingGeometryChange = YES;
  }
  [super setFrame:frame];
  _isApplyingGeometryChange = wasApplyingGeometryChange;
  // A transform can change frame.size without changing the viewport. Do not
  // leave a false pending capture that would mask the next real bounds change.
  if (!alreadyPending && _hasPendingSizeChangeFocus && CGSizeEqualToSize(oldBoundsSize, self.bounds.size)) {
    _hasPendingSizeChangeFocus = NO;
  }
}

- (void) setBounds:(CGRect)bounds {
  BOOL sizeChanged = !CGSizeEqualToSize(bounds.size, self.bounds.size);
  if (sizeChanged) {
    _geometryGeneration += 1;
    [self _preserveFocusBeforeSizeChange];
  }
  BOOL wasApplyingGeometryChange = _isApplyingGeometryChange;
  if (sizeChanged) {
    _isApplyingGeometryChange = YES;
  }
  [super setBounds:bounds];
  _isApplyingGeometryChange = wasApplyingGeometryChange;
}

- (void) _restoreFocusPoint {
  CGSize contentSize = self.contentSize;
  CGSize boundsSize = self.bounds.size;
  CGFloat zoomScale = self.zoomScale;
  CGFloat minimumX = -self.contentInset.left;
  CGFloat minimumY = -self.contentInset.top;
  CGFloat maximumX = MAX(minimumX, contentSize.width - boundsSize.width + self.contentInset.right);
  CGFloat maximumY = MAX(minimumY, contentSize.height - boundsSize.height + self.contentInset.bottom);
  CGPoint point = CGPointMake(MIN(MAX(zoomScale * _sourceFocusPoint.x - boundsSize.width / 2.0, minimumX), maximumX),
                              MIN(MAX(zoomScale * _sourceFocusPoint.y - boundsSize.height / 2.0, minimumY), maximumY));
  self.contentOffset = point;
}

// Public positioning calls are intentional viewport changes. Internal layout
// uses _isApplyingGeometryChange so its temporary clamps cannot replace them.
- (void) setContentOffset:(CGPoint)contentOffset {
  [super setContentOffset:contentOffset];
  [self _saveCurrentFocusPoint];
}

- (void) setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
  BOOL wasApplyingGeometryChange = _isApplyingGeometryChange;
  if (animated && _displayView && !wasApplyingGeometryChange) {
    [self _saveFocusPointForContentOffset:contentOffset boundsSize:self.bounds.size zoomScale:self.zoomScale];
    _isApplyingGeometryChange = YES;
  }
  [super setContentOffset:contentOffset animated:animated];
  _isApplyingGeometryChange = wasApplyingGeometryChange;
  if (!animated) {
    [self _saveCurrentFocusPoint];
  }
}

- (void) setZoomScale:(CGFloat)scale {
  [super setZoomScale:scale];
  [self _saveRelativeZoomScale:self.zoomScale];
  [self _saveCurrentFocusPoint];
}

- (void) setZoomScale:(CGFloat)scale animated:(BOOL)animated {
  BOOL wasApplyingGeometryChange = _isApplyingGeometryChange;
  if (!wasApplyingGeometryChange) {
    CGFloat targetScale = MIN(MAX(scale, self.minimumZoomScale), self.maximumZoomScale);
    [self _saveRelativeZoomScale:targetScale];
  }
  if (animated) {
    _isApplyingGeometryChange = YES;
  }
  [super setZoomScale:scale animated:animated];
  _isApplyingGeometryChange = wasApplyingGeometryChange;
  if (!animated) {
    [self _saveRelativeZoomScale:self.zoomScale];
    [self _saveCurrentFocusPoint];
  }
}

- (void) zoomToRect:(CGRect)rect animated:(BOOL)animated {
  BOOL wasApplyingGeometryChange = _isApplyingGeometryChange;
  if (_displayView && !wasApplyingGeometryChange && !CGRectIsEmpty(rect)) {
    _sourceFocusPoint.x = MIN(MAX(CGRectGetMidX(rect), 0.0), _displaySize.width);
    _sourceFocusPoint.y = MIN(MAX(CGRectGetMidY(rect), 0.0), _displaySize.height);
    CGFloat targetScale = MIN(CGRectGetWidth(self.bounds) / CGRectGetWidth(rect),
                              CGRectGetHeight(self.bounds) / CGRectGetHeight(rect));
    targetScale = MIN(MAX(targetScale, self.minimumZoomScale), self.maximumZoomScale);
    [self _saveRelativeZoomScale:targetScale];
  }
  _isApplyingGeometryChange = YES;
  [super zoomToRect:rect animated:animated];
  _isApplyingGeometryChange = wasApplyingGeometryChange;
  if (!animated) {
    [self _saveRelativeZoomScale:self.zoomScale];
    [self _saveCurrentFocusPoint];
  }
}

- (void) _handleDoubleTap:(UIGestureRecognizer*)gestureRecognizer {
  if (self.maximumZoomScale > self.minimumZoomScale) {
    if (self.zoomScale <= self.minimumZoomScale + FLT_EPSILON) {
      CGPoint point = [gestureRecognizer locationInView:_displayView];
      CGRect zoomRect = CGRectMake(point.x - 1.0, point.y - 1.0, 2.0, 2.0);
      [self zoomToRect:zoomRect animated:YES];
    } else {
      BOOL wasApplyingGeometryChange = _isApplyingGeometryChange;
      _isApplyingGeometryChange = YES;
      BOOL atOrigin = CGPointEqualToPoint(self.contentOffset, CGPointZero);  // Work around a strange behavior where if zooming out while changing contentInset from zero to non-zero at the same time
      if (atOrigin) {
        self.contentOffset = CGPointMake(1.0, 1.0);
      }
      [self setZoomScale:self.minimumZoomScale animated:YES];
      if (atOrigin) {
        self.contentOffset = CGPointMake(0.0, 0.0);
      }
      _isApplyingGeometryChange = wasApplyingGeometryChange;
      [self _resetFocusPoint];
    }
  }
}

- (id) initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.showsVerticalScrollIndicator = NO;
    self.showsHorizontalScrollIndicator = NO;
    self.decelerationRate = UIScrollViewDecelerationRateFast;
    self.bouncesZoom = YES;
    self.clipsToBounds = YES;
    self.scrollsToTop = NO;
    self.autoresizesSubviews = NO;
    self.delegate = self;
    
    _displayMode = kZoomViewDisplayMode_Centered;
    _doubleTapZoom = 1.5;
    
    _doubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleDoubleTap:)];
    [_doubleTapRecognizer setNumberOfTapsRequired:2];
    [self addGestureRecognizer:_doubleTapRecognizer];
  }
  return self;
}

- (void) dealloc {
  [_displayView release];
  [_doubleTapRecognizer release];
  
  [super dealloc];
}

- (void) setDisplayMode:(ZoomViewDisplayMode)mode {
  if (mode != _displayMode) {
    _displayMode = mode;
    
    // Force a layout
    _oldSize = CGSizeZero;
    [self setNeedsLayout];
  }
}

- (void) setDoubleTapZoom:(float)zoom {
  if (zoom != _doubleTapZoom) {
    _doubleTapZoom = zoom;
    
    // Force a layout
    _oldSize = CGSizeZero;
    [self setNeedsLayout];
  }
}

- (void) setDisplayView:(UIView*)view {
  [self setDisplayView:view animated:NO];
}

- (void) setDisplayView:(UIView*)view animated:(BOOL)animated {
  if (view != _displayView) {
    // Replace display view
    UIView* oldDisplayView = [_displayView autorelease];
    _displayView = [view retain];
    _displaySize = view.frame.size;
    [self _resetFocusPoint];
    _hasPendingSizeChangeFocus = NO;
    if (animated) {
      [UIView transitionWithView:self duration:[[self class] defaultAnimationDuration] options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        [oldDisplayView removeFromSuperview];
        if (_displayView) {
          [self addSubview:_displayView];
        }
      } completion:NULL];
    } else {
      [oldDisplayView removeFromSuperview];
      if (_displayView) {
        [self addSubview:_displayView];
      }
    }
    
    // Force a layout
    _oldSize = CGSizeZero;
    [self setNeedsLayout];
  }
}

- (void) layoutSubviews {
  BOOL wasApplyingGeometryChange = _isApplyingGeometryChange;
  _isApplyingGeometryChange = YES;
  [super layoutSubviews];
  
  // Update layout if we have a display view
  if (_displayView) {
    CGSize boundsSize = self.bounds.size;
    if (boundsSize.width <= 0.0 || boundsSize.height <= 0.0 || _displaySize.width <= 0.0 || _displaySize.height <= 0.0) {
      _isApplyingGeometryChange = wasApplyingGeometryChange;
      return;
    }
    
    // Check if zoom values need to be recomputed
    if (!CGSizeEqualToSize(boundsSize, _oldSize)) {
      // Preserve the reader's magnification relative to a fitted page. This
      // keeps the same reading zoom as the window grows or shrinks.
      CGFloat oldRelativeZoom = _relativeZoomScale > 0.0 ? _relativeZoomScale : 1.0;
      
      // Compute new min and max zoom
      CGFloat fitZoomScale = MIN(boundsSize.width / _displaySize.width, boundsSize.height / _displaySize.height);
      CGFloat fillZoomScale = MAX(boundsSize.width / _displaySize.width, boundsSize.height / _displaySize.height);
      DCHECK(fillZoomScale >= fitZoomScale);
      CGFloat newMinimumZoomScale = 1.0;
      switch (_displayMode) {
        
        case kZoomViewDisplayMode_Centered:
          newMinimumZoomScale = 1.0;
          break;
        
        case kZoomViewDisplayMode_Fit:
          newMinimumZoomScale = fitZoomScale;
          break;
        
        case kZoomViewDisplayMode_FitVertically:
          newMinimumZoomScale = boundsSize.height / _displaySize.height;
          break;

        case kZoomViewDisplayMode_FitHorizontally:
          newMinimumZoomScale = boundsSize.width / _displaySize.width;
          break;

        case kZoomViewDisplayMode_Fill:
          newMinimumZoomScale = fillZoomScale;
          break;
        
        case kZoomViewDisplayMode_Automatic: {
          CGFloat ratio = (_displaySize.width / _displaySize.height) / (boundsSize.width / boundsSize.height);
          if ((ratio >= 1.0 - kAutomaticTolerance) && (ratio <= 1.0 + kAutomaticTolerance)) {
            newMinimumZoomScale = fillZoomScale;
          } else {
            newMinimumZoomScale = fitZoomScale;
          }
          break;
        }
        
      }
      CGFloat maxZoomScale = MAX(boundsSize.width, boundsSize.height) / MIN(_displaySize.width, _displaySize.height);
      CGFloat newMaximumZoomScale = MAX(newMinimumZoomScale, _doubleTapZoom * maxZoomScale);
      if (newMinimumZoomScale > self.maximumZoomScale) {
        self.maximumZoomScale = newMinimumZoomScale;
      }
      self.minimumZoomScale = newMinimumZoomScale;
      self.maximumZoomScale = newMaximumZoomScale;
      
      // Update current zoom
      if (CGSizeEqualToSize(_oldSize, CGSizeZero)) {
        self.zoomScale = 1.0;  // Be extra safe by resetting zoom scale before setting content size
        self.contentSize = _displaySize;
        self.zoomScale = self.minimumZoomScale;
        [self _resetFocusPoint];
      } else {
        CGFloat relativeZoom = oldRelativeZoom <= 1.0 + kZoomTolerance ? 1.0 : oldRelativeZoom;
        self.zoomScale = MIN(MAX(self.minimumZoomScale * relativeZoom, self.minimumZoomScale), self.maximumZoomScale);
      }

      // Recompute padding before restoring the offset so fitted content can use
      // the negative offsets represented by its insets.
      CGSize contentSize = self.contentSize;  // Content size depends on current zoom scale
      CGFloat paddingX = MAX((boundsSize.width - contentSize.width) / 2.0, 0.0);
      CGFloat paddingY = MAX((boundsSize.height - contentSize.height) / 2.0, 0.0);
      self.contentInset = UIEdgeInsetsMake(paddingY, paddingX, paddingY, paddingX);
      [self _restoreFocusPoint];

      _oldSize = boundsSize;
      _hasPendingSizeChangeFocus = NO;
    } else {
      // Zooming changes contentSize without changing bounds.
      CGSize contentSize = self.contentSize;
      CGFloat paddingX = MAX((boundsSize.width - contentSize.width) / 2.0, 0.0);
      CGFloat paddingY = MAX((boundsSize.height - contentSize.height) / 2.0, 0.0);
      UIEdgeInsets edgeInsets = UIEdgeInsetsMake(paddingY, paddingX, paddingY, paddingX);
      if (!UIEdgeInsetsEqualToEdgeInsets(edgeInsets, self.contentInset)) {
        self.contentInset = edgeInsets;
      }
      if (_hasPendingSizeChangeFocus) {
        // Multiple geometry updates may return to _oldSize before a layout.
        // UIKit may still have clamped the intermediate offset, so restore the
        // retained user focus even though the final size matches _oldSize.
        [self _restoreFocusPoint];
        _hasPendingSizeChangeFocus = NO;
      }
    }

  }
  // Otherwise reset everything
  else {
    self.contentInset = UIEdgeInsetsZero;
    self.contentOffset = CGPointZero;
    self.minimumZoomScale = 1.0;
    self.maximumZoomScale = 1.0;
    self.zoomScale = 1.0;
  }
  _isApplyingGeometryChange = wasApplyingGeometryChange;
}

@end

@implementation ZoomView (UIScrollViewDelegate)

- (UIView*) viewForZoomingInScrollView:(UIScrollView*)scrollView {
  return _displayView;
}

- (void) scrollViewWillBeginZooming:(UIScrollView*)scrollView withView:(UIView*)view {
  _zoomCaptureGeometryGeneration = _geometryGeneration;
  _hasActiveZoomCapture = YES;
}

- (void) scrollViewDidScroll:(UIScrollView*)scrollView {
  if (scrollView.dragging || scrollView.decelerating) {
    [self _saveCurrentFocusPoint];
  }
}

- (void) scrollViewDidEndDragging:(UIScrollView*)scrollView willDecelerate:(BOOL)decelerate {
  if (!decelerate) {
    [self _saveCurrentFocusPoint];
  }
}

- (void) scrollViewDidEndDecelerating:(UIScrollView*)scrollView {
  [self _saveCurrentFocusPoint];
}

- (void) scrollViewDidZoom:(UIScrollView*)scrollView {
  UIGestureRecognizerState pinchState = scrollView.pinchGestureRecognizer.state;
  BOOL userIsPinching = pinchState == UIGestureRecognizerStateBegan ||
                        pinchState == UIGestureRecognizerStateChanged;
  if (userIsPinching && _hasActiveZoomCapture &&
      _zoomCaptureGeometryGeneration == _geometryGeneration) {
    [self _saveRelativeZoomScale:scrollView.zoomScale];
    [self _saveCurrentFocusPoint];
  }
}

- (void) scrollViewDidEndZooming:(UIScrollView*)scrollView withView:(UIView*)view atScale:(CGFloat)scale {
  if (_hasActiveZoomCapture && _zoomCaptureGeometryGeneration == _geometryGeneration) {
    [self _saveRelativeZoomScale:scale];
    [self _saveCurrentFocusPoint];
  }
  _hasActiveZoomCapture = NO;
}

- (void) scrollViewDidEndScrollingAnimation:(UIScrollView*)scrollView {
  [self _saveCurrentFocusPoint];
}

@end
