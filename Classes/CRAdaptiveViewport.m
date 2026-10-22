#import "CRAdaptiveViewport.h"

#import <math.h>
#import <TargetConditionals.h>

#if !TARGET_OS_MACCATALYST && __has_include(<UIKit/UIViewReservedRegion.h>)
#import <UIKit/UIViewReservedRegion.h>
#define CR_HAS_UIVIEW_RESERVED_REGIONS 1
#else
#define CR_HAS_UIVIEW_RESERVED_REGIONS 0
#endif

CGRect CRAdaptiveSafeBounds(CGRect bounds, UIEdgeInsets safeAreaInsets) {
  bounds = CGRectStandardize(bounds);
  if (CGRectIsNull(bounds) || CGRectIsInfinite(bounds) ||
      !isfinite(CGRectGetMinX(bounds)) || !isfinite(CGRectGetMinY(bounds)) ||
      !isfinite(CGRectGetWidth(bounds)) || !isfinite(CGRectGetHeight(bounds))) {
    return CGRectZero;
  }

  CGFloat left = MIN(MAX(safeAreaInsets.left, 0.0), CGRectGetWidth(bounds));
  CGFloat right = MIN(MAX(safeAreaInsets.right, 0.0), CGRectGetWidth(bounds) - left);
  CGFloat top = MIN(MAX(safeAreaInsets.top, 0.0), CGRectGetHeight(bounds));
  CGFloat bottom = MIN(MAX(safeAreaInsets.bottom, 0.0), CGRectGetHeight(bounds) - top);
  return CGRectMake(CGRectGetMinX(bounds) + left,
                    CGRectGetMinY(bounds) + top,
                    CGRectGetWidth(bounds) - left - right,
                    CGRectGetHeight(bounds) - top - bottom);
}

static BOOL CRViewportRectIsUsable(CGRect rect) {
  rect = CGRectStandardize(rect);
  return !CGRectIsNull(rect) && !CGRectIsInfinite(rect) &&
         isfinite(CGRectGetMinX(rect)) && isfinite(CGRectGetMinY(rect)) &&
         isfinite(CGRectGetWidth(rect)) && isfinite(CGRectGetHeight(rect)) &&
         CGRectGetWidth(rect) > 0.0 && CGRectGetHeight(rect) > 0.0;
}

static CGRect CRViewportByAvoidingDivision(CGRect viewport,
                                           CGRect division,
                                           UIUserInterfaceLayoutDirection layoutDirection) {
  division = CGRectStandardize(division);
  if (!CRViewportRectIsUsable(viewport) || !CRViewportRectIsUsable(division) ||
      !CGRectIntersectsRect(viewport, division)) {
    return viewport;
  }

  if (CGRectGetWidth(division) < CGRectGetHeight(division)) {
    CGRect divider = CGRectMake(CGRectGetMinX(division), CGRectGetMinY(viewport),
                                CGRectGetWidth(division), CGRectGetHeight(viewport));
    divider = CGRectIntersection(viewport, divider);
    CGRect left = CGRectMake(CGRectGetMinX(viewport), CGRectGetMinY(viewport),
                             MAX(0.0, CGRectGetMinX(divider) - CGRectGetMinX(viewport)),
                             CGRectGetHeight(viewport));
    CGRect right = CGRectMake(CGRectGetMaxX(divider), CGRectGetMinY(viewport),
                              MAX(0.0, CGRectGetMaxX(viewport) - CGRectGetMaxX(divider)),
                              CGRectGetHeight(viewport));
    CGRect preferred = layoutDirection == UIUserInterfaceLayoutDirectionRightToLeft ? right : left;
    CGRect alternate = layoutDirection == UIUserInterfaceLayoutDirectionRightToLeft ? left : right;
    return CRViewportRectIsUsable(preferred) ? preferred : alternate;
  }

  CGRect divider = CGRectMake(CGRectGetMinX(viewport), CGRectGetMinY(division),
                              CGRectGetWidth(viewport), CGRectGetHeight(division));
  divider = CGRectIntersection(viewport, divider);
  CGRect top = CGRectMake(CGRectGetMinX(viewport), CGRectGetMinY(viewport),
                          CGRectGetWidth(viewport),
                          MAX(0.0, CGRectGetMinY(divider) - CGRectGetMinY(viewport)));
  CGRect bottom = CGRectMake(CGRectGetMinX(viewport), CGRectGetMaxY(divider),
                             CGRectGetWidth(viewport),
                             MAX(0.0, CGRectGetMaxY(viewport) - CGRectGetMaxY(divider)));
  return CRViewportRectIsUsable(top) ? top : bottom;
}

static void CRAddViewportCandidate(NSMutableArray<NSValue*>* candidates, CGRect candidate) {
  if (!CRViewportRectIsUsable(candidate)) return;
  for (NSValue* existingValue in candidates) {
    if (CGRectEqualToRect(existingValue.CGRectValue, candidate)) return;
  }
  [candidates addObject:[NSValue valueWithCGRect:candidate]];
}

static NSArray<NSValue*>* CRViewportCandidatesByRemovingOcclusion(NSArray<NSValue*>* candidates,
                                                                  CGRect occlusion) {
  if (!CRViewportRectIsUsable(occlusion)) return candidates;

  NSMutableArray<NSValue*>* result = [NSMutableArray array];
  for (NSValue* candidateValue in candidates) {
    CGRect candidate = candidateValue.CGRectValue;
    CGRect intersection = CGRectIntersection(candidate, occlusion);
    if (!CRViewportRectIsUsable(intersection)) {
      CRAddViewportCandidate(result, candidate);
      continue;
    }

    CRAddViewportCandidate(result,
                           CGRectMake(CGRectGetMinX(candidate), CGRectGetMinY(candidate),
                                      CGRectGetWidth(candidate),
                                      CGRectGetMinY(intersection) - CGRectGetMinY(candidate)));
    CRAddViewportCandidate(result,
                           CGRectMake(CGRectGetMinX(candidate), CGRectGetMaxY(intersection),
                                      CGRectGetWidth(candidate),
                                      CGRectGetMaxY(candidate) - CGRectGetMaxY(intersection)));
    CRAddViewportCandidate(result,
                           CGRectMake(CGRectGetMinX(candidate), CGRectGetMinY(candidate),
                                      CGRectGetMinX(intersection) - CGRectGetMinX(candidate),
                                      CGRectGetHeight(candidate)));
    CRAddViewportCandidate(result,
                           CGRectMake(CGRectGetMaxX(intersection), CGRectGetMinY(candidate),
                                      CGRectGetMaxX(candidate) - CGRectGetMaxX(intersection),
                                      CGRectGetHeight(candidate)));
  }
  return result;
}

static BOOL CRViewportCandidateIsBetter(CGRect candidate,
                                        CGRect current,
                                        UIUserInterfaceLayoutDirection layoutDirection) {
  CGFloat candidateArea = CGRectGetWidth(candidate) * CGRectGetHeight(candidate);
  CGFloat currentArea = CGRectGetWidth(current) * CGRectGetHeight(current);
  if (candidateArea > currentArea + 0.001) return YES;
  if (candidateArea + 0.001 < currentArea) return NO;

  if (CGRectGetMinY(candidate) < CGRectGetMinY(current) - 0.001) return YES;
  if (CGRectGetMinY(candidate) > CGRectGetMinY(current) + 0.001) return NO;
  if (layoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) {
    return CGRectGetMaxX(candidate) > CGRectGetMaxX(current) + 0.001;
  }
  return CGRectGetMinX(candidate) < CGRectGetMinX(current) - 0.001;
}

CGRect CRAdaptiveViewportBounds(CGRect bounds,
                                UIEdgeInsets safeAreaInsets,
                                NSArray<NSValue*>* divisionRegionFrames,
                                NSArray<NSValue*>* occlusionRegionFrames,
                                UIUserInterfaceLayoutDirection layoutDirection) {
  CGRect viewport = CRAdaptiveSafeBounds(bounds, safeAreaInsets);
  if (!CRViewportRectIsUsable(viewport)) return viewport;

  // A division has pane semantics rather than ordinary occlusion semantics: a
  // continuous page must live wholly on one side, even if the reported frame
  // intersects only part of the current safe rectangle.
  for (NSValue* frameValue in divisionRegionFrames) {
    viewport = CRViewportByAvoidingDivision(viewport, frameValue.CGRectValue, layoutDirection);
    if (!CRViewportRectIsUsable(viewport)) return CGRectZero;
  }

  NSArray<NSValue*>* candidates = @[[NSValue valueWithCGRect:viewport]];
  for (NSValue* frameValue in occlusionRegionFrames) {
    candidates = CRViewportCandidatesByRemovingOcclusion(candidates, frameValue.CGRectValue);
    if (candidates.count == 0) return CGRectZero;
  }

  CGRect best = CGRectZero;
  BOOL hasBest = NO;
  for (NSValue* candidateValue in candidates) {
    CGRect candidate = candidateValue.CGRectValue;
    if (!hasBest || CRViewportCandidateIsBetter(candidate, best, layoutDirection)) {
      best = candidate;
      hasBest = YES;
    }
  }
  return hasBest ? best : CGRectZero;
}

UIEdgeInsets CRAdaptiveAdditionalSafeAreaInsets(CGRect bounds,
                                                UIEdgeInsets baselineSafeAreaInsets,
                                                CGRect viewportBounds) {
  CGRect baselineBounds = CRAdaptiveSafeBounds(bounds, baselineSafeAreaInsets);
  if (!CRViewportRectIsUsable(baselineBounds) || !CRViewportRectIsUsable(viewportBounds)) {
    return UIEdgeInsetsZero;
  }

  CGRect containedViewport = CGRectIntersection(baselineBounds, CGRectStandardize(viewportBounds));
  if (!CRViewportRectIsUsable(containedViewport)) return UIEdgeInsetsZero;
  return UIEdgeInsetsMake(MAX(0.0, CGRectGetMinY(containedViewport) - CGRectGetMinY(baselineBounds)),
                          MAX(0.0, CGRectGetMinX(containedViewport) - CGRectGetMinX(baselineBounds)),
                          MAX(0.0, CGRectGetMaxY(baselineBounds) - CGRectGetMaxY(containedViewport)),
                          MAX(0.0, CGRectGetMaxX(baselineBounds) - CGRectGetMaxX(containedViewport)));
}

@implementation CRAdaptiveViewportView

@synthesize adaptiveViewportDelegate=_adaptiveViewportDelegate;

+ (BOOL) requiresConstraintBasedLayout {
  return YES;
}

- (void) _commonAdaptiveViewportInit {
  _viewportBounds = CGRectNull;
  self.backgroundColor = [UIColor clearColor];
  self.opaque = NO;
  self.userInteractionEnabled = NO;
  self.accessibilityElementsHidden = YES;
}

- (id) initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    [self _commonAdaptiveViewportInit];
  }
  return self;
}

- (id) initWithCoder:(NSCoder*)coder {
  if ((self = [super initWithCoder:coder])) {
    [self _commonAdaptiveViewportInit];
  }
  return self;
}

- (CGRect) viewportBounds {
  if (CGRectIsNull(_viewportBounds)) {
    return CRAdaptiveSafeBounds(self.bounds, self.safeAreaInsets);
  }
  return _viewportBounds;
}

- (void) refreshViewport {
  [self setNeedsUpdateConstraints];
  [self updateConstraintsIfNeeded];
}

- (void) safeAreaInsetsDidChange {
  [super safeAreaInsetsDidChange];
  [self setNeedsUpdateConstraints];
}

- (void) didMoveToWindow {
  [super didMoveToWindow];
  [self setNeedsUpdateConstraints];
}

- (void) updateConstraints {
  NSMutableArray<NSValue*>* divisionFrames = [NSMutableArray array];
  NSMutableArray<NSValue*>* occlusionFrames = [NSMutableArray array];
#if CR_HAS_UIVIEW_RESERVED_REGIONS
  if (@available(iOS 27.1, *)) {
    // Query in this method deliberately. UIKit tracks reserved-region reads in
    // updateConstraints and schedules a new pass when their state changes.
    NSArray<UIViewReservedRegion*>* divisions =
      [self reservedRegionsOfKind:[UIViewReservedRegionKind divisionRegionKind]];
    for (UIViewReservedRegion* region in divisions) {
      if (region.isActive) [divisionFrames addObject:[NSValue valueWithCGRect:region.frame]];
    }
    NSArray<UIViewReservedRegion*>* occlusions =
      [self reservedRegionsOfKind:[UIViewReservedRegionKind occlusionRegionKind]];
    for (UIViewReservedRegion* region in occlusions) {
      if (region.isActive) [occlusionFrames addObject:[NSValue valueWithCGRect:region.frame]];
    }
  }
#endif

  CGRect viewportBounds = CRAdaptiveViewportBounds(self.bounds,
                                                   self.safeAreaInsets,
                                                   divisionFrames,
                                                   occlusionFrames,
                                                   self.effectiveUserInterfaceLayoutDirection);
  BOOL changed = CGRectIsNull(_viewportBounds) || !CGRectEqualToRect(_viewportBounds, viewportBounds);
  _viewportBounds = viewportBounds;

  if (changed && [_adaptiveViewportDelegate respondsToSelector:@selector(adaptiveViewportView:didChangeViewportBounds:)]) {
    [_adaptiveViewportDelegate adaptiveViewportView:self didChangeViewportBounds:_viewportBounds];
  }
  [super updateConstraints];
}

@end

@class CRAdaptiveToolReservedRegionObserverView;

@interface CRAdaptiveToolNavigationController ()
- (void) _adaptiveObserver:(CRAdaptiveToolReservedRegionObserverView*)observer
    didReadDivisionFrames:(NSArray<NSValue*>*)divisionFrames
          occlusionFrames:(NSArray<NSValue*>*)occlusionFrames;
@end

/// Reserved-region reads must happen in UIView.updateConstraints so UIKit can
/// invalidate the query when a region activates, deactivates or moves. Keep a
/// view observer rather than relying on UIViewController.updateViewConstraints
/// having the same dependency-tracking contract.
@interface CRAdaptiveToolReservedRegionObserverView : UIView {
@private
  CRAdaptiveToolNavigationController* _navigationController;
}
@property(nonatomic, assign) CRAdaptiveToolNavigationController* navigationController;
@end

@implementation CRAdaptiveToolReservedRegionObserverView

@synthesize navigationController=_navigationController;

+ (BOOL) requiresConstraintBasedLayout {
  return YES;
}

- (id) initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
  }
  return self;
}

- (void) safeAreaInsetsDidChange {
  [super safeAreaInsetsDidChange];
  [self setNeedsUpdateConstraints];
}

- (void) didMoveToWindow {
  [super didMoveToWindow];
  [self setNeedsUpdateConstraints];
}

- (void) updateConstraints {
  NSMutableArray<NSValue*>* divisionFrames = [NSMutableArray array];
  NSMutableArray<NSValue*>* occlusionFrames = [NSMutableArray array];
#if CR_HAS_UIVIEW_RESERVED_REGIONS
  if (@available(iOS 27.1, *)) {
    NSArray<UIViewReservedRegion*>* divisions =
      [self reservedRegionsOfKind:[UIViewReservedRegionKind divisionRegionKind]];
    for (UIViewReservedRegion* region in divisions) {
      if (region.isActive) [divisionFrames addObject:[NSValue valueWithCGRect:region.frame]];
    }
    NSArray<UIViewReservedRegion*>* occlusions =
      [self reservedRegionsOfKind:[UIViewReservedRegionKind occlusionRegionKind]];
    for (UIViewReservedRegion* region in occlusions) {
      if (region.isActive) [occlusionFrames addObject:[NSValue valueWithCGRect:region.frame]];
    }
  }
#endif
  [_navigationController _adaptiveObserver:self
                     didReadDivisionFrames:divisionFrames
                           occlusionFrames:occlusionFrames];
  [super updateConstraints];
}

@end

static UIEdgeInsets CRInsetsBySubtractingInsets(UIEdgeInsets insets, UIEdgeInsets subtrahend) {
  return UIEdgeInsetsMake(MAX(0.0, insets.top - subtrahend.top),
                          MAX(0.0, insets.left - subtrahend.left),
                          MAX(0.0, insets.bottom - subtrahend.bottom),
                          MAX(0.0, insets.right - subtrahend.right));
}

static UIEdgeInsets CRInsetsByAddingInsets(UIEdgeInsets first, UIEdgeInsets second) {
  return UIEdgeInsetsMake(first.top + second.top,
                          first.left + second.left,
                          first.bottom + second.bottom,
                          first.right + second.right);
}

@implementation CRAdaptiveToolNavigationController

- (void) dealloc {
  [(CRAdaptiveToolReservedRegionObserverView*)_adaptiveReservedRegionObserverView setNavigationController:nil];
  [_adaptiveReservedRegionObserverView release];
  [super dealloc];
}

- (void) viewDidLoad {
  [super viewDidLoad];
  CRAdaptiveToolReservedRegionObserverView* observer =
    [[CRAdaptiveToolReservedRegionObserverView alloc] initWithFrame:self.view.bounds];
  observer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  observer.navigationController = self;
  _adaptiveReservedRegionObserverView = observer;
  [self.view insertSubview:observer atIndex:0];
  [observer setNeedsUpdateConstraints];
}

- (void) viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  _adaptiveReservedRegionObserverView.frame = self.view.bounds;
  [_adaptiveReservedRegionObserverView setNeedsUpdateConstraints];
  [_adaptiveReservedRegionObserverView updateConstraintsIfNeeded];
}

- (void) viewSafeAreaInsetsDidChange {
  [super viewSafeAreaInsetsDidChange];
  [_adaptiveReservedRegionObserverView setNeedsUpdateConstraints];
}

- (void) _adaptiveObserver:(CRAdaptiveToolReservedRegionObserverView*)observer
    didReadDivisionFrames:(NSArray<NSValue*>*)divisionFrames
          occlusionFrames:(NSArray<NSValue*>*)occlusionFrames {
  if (!self.isViewLoaded || observer.superview != self.view) return;

  // The navigation view's safe area includes our previous adjustment and can
  // round it differently from its descendants during a display transition.
  // Subtracting that adjustment feeds the rounding error back into each layout
  // pass. Project the unaffected presentation container's safe area instead.
  UIEdgeInsets inheritedInsets = UIEdgeInsetsZero;
  UIView* container = self.view.superview;
  if (container) {
    CGRect containerSafeBounds = CRAdaptiveSafeBounds(container.bounds, container.safeAreaInsets);
    CGRect inheritedViewport = [container convertRect:containerSafeBounds toView:self.view];
    inheritedInsets = CRAdaptiveAdditionalSafeAreaInsets(self.view.bounds,
                                                         UIEdgeInsetsZero,
                                                         inheritedViewport);
  }
  UIEdgeInsets configuredInsets =
    CRInsetsBySubtractingInsets(self.additionalSafeAreaInsets, _adaptiveSafeAreaInsets);
  UIEdgeInsets baselineSafeAreaInsets = CRInsetsByAddingInsets(inheritedInsets, configuredInsets);
  CGRect viewportBounds = CRAdaptiveViewportBounds(observer.bounds,
                                                   baselineSafeAreaInsets,
                                                   divisionFrames,
                                                   occlusionFrames,
                                                   observer.effectiveUserInterfaceLayoutDirection);
  UIEdgeInsets desiredAdaptiveInsets = CRAdaptiveAdditionalSafeAreaInsets(observer.bounds,
                                                                          baselineSafeAreaInsets,
                                                                          viewportBounds);
  if (UIEdgeInsetsEqualToEdgeInsets(desiredAdaptiveInsets, _adaptiveSafeAreaInsets)) return;

  _adaptiveSafeAreaInsets = desiredAdaptiveInsets;
  self.additionalSafeAreaInsets = CRInsetsByAddingInsets(configuredInsets, desiredAdaptiveInsets);
}

@end
