#import "GCSCardboardView.h"

@class StarsRenderLoop;

/** Cardboard Stars renderer. */
@interface StarsRenderer : NSObject<GCSCardboardViewDelegate>

@property(nonatomic, weak) StarsRenderLoop *renderLoop;

@end
