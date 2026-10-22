#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Insets bounds by the safe area, preserving independent values on every edge.
FOUNDATION_EXPORT CGRect CRAdaptiveSafeBounds(CGRect bounds, UIEdgeInsets safeAreaInsets);

/// Returns one unobstructed rectangle for content that must remain continuous.
///
/// Region frames must use the same coordinate space as `bounds`. UIKit reserved
/// region frames already include their interaction margins, so callers must not
/// apply those margins again. Horizontal divisions prefer the top pane. Vertical
/// divisions prefer the leading pane for the supplied layout direction. Active
/// occlusions are then removed from that pane and the largest remaining rectangle
/// is returned.
FOUNDATION_EXPORT CGRect CRAdaptiveViewportBounds(CGRect bounds,
                                                  UIEdgeInsets safeAreaInsets,
                                                  NSArray<NSValue*>* divisionRegionFrames,
                                                  NSArray<NSValue*>* occlusionRegionFrames,
                                                  UIUserInterfaceLayoutDirection layoutDirection);

/// Returns the extra safe-area insets needed to keep container content inside
/// `viewportBounds`. `baselineSafeAreaInsets` must exclude previously returned
/// adaptive insets so repeated updates do not accumulate them.
FOUNDATION_EXPORT UIEdgeInsets CRAdaptiveAdditionalSafeAreaInsets(CGRect bounds,
                                                                  UIEdgeInsets baselineSafeAreaInsets,
                                                                  CGRect viewportBounds);

@class CRAdaptiveViewportView;

@protocol CRAdaptiveViewportViewDelegate <NSObject>
@optional
- (void) adaptiveViewportView:(CRAdaptiveViewportView*)view
      didChangeViewportBounds:(CGRect)viewportBounds;
@end

/// A transparent, root-sized view that observes UIKit reserved-region changes.
///
/// Keep this view aligned with the view whose children you position. The
/// returned bounds use this view's coordinate space. Reserved regions are read
/// from `updateConstraints`, where UIKit tracks the query and schedules another
/// constraints pass when a region becomes active, inactive, or moves.
@interface CRAdaptiveViewportView : UIView {
@private
  id<CRAdaptiveViewportViewDelegate> _adaptiveViewportDelegate;
  CGRect _viewportBounds;
}
@property(nonatomic, assign, nullable) id<CRAdaptiveViewportViewDelegate> adaptiveViewportDelegate;
@property(nonatomic, readonly) CGRect viewportBounds;

/// Refreshes the cached viewport after this view's bounds change. Region reads
/// still occur in the tracked `updateConstraints` path.
- (void) refreshViewport;
@end

/// A system navigation controller whose app-owned content stays inside one
/// continuous reserved-region pane. Its modal presentation remains managed by
/// UIKit; only the container safe area is adapted.
@interface CRAdaptiveToolNavigationController : UINavigationController {
@private
  UIView* _adaptiveReservedRegionObserverView;
  UIEdgeInsets _adaptiveSafeAreaInsets;
}
@end

NS_ASSUME_NONNULL_END
