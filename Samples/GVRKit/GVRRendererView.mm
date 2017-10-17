/*
 * Copyright 2017 Google Inc. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "GVRRendererView.h"

#import "GVRSceneRenderer.h"

/** Defines a class to set the supplied EAGLContext and restore old context when destroyed. **/
class GVRSetContext {
public:
  GVRSetContext(EAGLContext *context) {
    _oldContext = [EAGLContext currentContext];
    [EAGLContext setCurrentContext:context];
  }
  ~GVRSetContext() {
    [EAGLContext setCurrentContext:_oldContext];
  }
private:
  EAGLContext *_oldContext;
};

@implementation GVRRendererView {
  CADisplayLink *_displayLink;
  BOOL _initialized;
}

- (instancetype)init {
  return [self initWithRenderer:nil];
}

- (instancetype)initWithRenderer:(GVRRenderer *)renderer {
  if (self = [super init]) {
    // Default to |GVRSceneRenderer| if no renderer is provided.
    if (renderer == nil) {
      renderer = [[GVRSceneRenderer alloc] init];
    }
    _renderer = renderer;

    // Create an overlay view on top of the GLKView.
    _overlayView = [[GVROverlayView alloc] initWithFrame:self.bounds];
    _overlayView.hidesBackButton = YES;
    _overlayView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_overlayView];

    // Add a tap gesture to handle viewer trigger action.
    UITapGestureRecognizer *tapGesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didTapGLView:)];
    [self addGestureRecognizer:tapGesture];

    // Add pan gesture to allow manual tracking.
    UIPanGestureRecognizer *panGesture =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(didPanGLView:)];
    [self addGestureRecognizer:panGesture];

    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    self.drawableDepthFormat = GLKViewDrawableDepthFormat16;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc {
  // Shutdown GVRRenderer.
  GVRSetContext context(self.context);
  [_renderer clearGl];
  [self deleteDrawable];

  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setVRModeEnabled:(BOOL)VRModeEnabled {
  if (_VRModeEnabled == VRModeEnabled) {
    return;
  }

  _renderer.VRModeEnabled = VRModeEnabled;

  [self willChangeValueForKey:@"VRModeEnabled"];
  _VRModeEnabled = VRModeEnabled;
  [self didChangeValueForKey:@"VRModeEnabled"];

  [self updateOverlayView];
}

- (void)setPaused:(BOOL)paused {
  [self willChangeValueForKey:@"VRModeEnabled"];
  _paused = paused;
  [self didChangeValueForKey:@"VRModeEnabled"];

  [_renderer pause:paused];

  _displayLink.paused = (self.superview == nil || _paused);
}

- (void)didMoveToSuperview {
  [super didMoveToSuperview];

  // Start rendering only when added to a superview and vice versa.
  if (self.superview) {
    [self startRenderer];
  } else {
    [self stopRenderer];
  }
}

- (void)layoutSubviews {
  [super layoutSubviews];

  if (!_initialized) {
    _initialized = YES;
    // Initialize GVRRenderer.
    GVRSetContext context(self.context);
    [self bindDrawable];
    [_renderer initializeGl];
  }

  UIInterfaceOrientation orientation = [UIApplication sharedApplication].statusBarOrientation;
  [_renderer setSize:self.bounds.size andOrientation:orientation];
}

- (void)drawRect:(CGRect)rect {
  [super drawRect:rect];

  if (!_initialized) {
    return;
  }

  GVRSetContext context(self.context);

  if ([_displayLink respondsToSelector:@selector(targetTimestamp)]) {
    [_renderer drawFrame:_displayLink.targetTimestamp];
  } else {
    NSTimeInterval nextFrameTime =
        _displayLink.timestamp + (_displayLink.duration * _displayLink.frameInterval);
    [_renderer drawFrame:nextFrameTime];
  }
}

#pragma mark - Actions

- (void)didTapGLView:(UIPanGestureRecognizer *)panGesture {
  GVRSetContext context(self.context);
  // If renderer does not handle the trigger, call the delegate.
  if ([_renderer handleTrigger]) {
    return;
  }
  if ([self.overlayView.delegate respondsToSelector:@selector(didTapTriggerButton)]) {
    [self.overlayView.delegate didTapTriggerButton];
  }
}

- (void)didPanGLView:(UIPanGestureRecognizer *)panGesture {
  CGPoint translation = [panGesture translationInView:self];
  [panGesture setTranslation:CGPointZero inView:self];

  // Compute rotation from translation delta.
  CGFloat yaw = GLKMathDegreesToRadians(-translation.x);
  CGFloat pitch = GLKMathDegreesToRadians(-translation.y);

  [_renderer addToHeadRotationYaw:yaw andPitch:pitch];
}

#pragma mark - NSNotificationCenter

- (void)applicationWillResignActive:(NSNotification *)notification {
  self.paused = YES;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
  self.paused = NO;
}

#pragma mark - Private

- (void)updateOverlayView {
  // Transition view is always shown when VR mode is toggled ON.
  _overlayView.hidesTransitionView = _overlayView.hidesTransitionView || !_VRModeEnabled;
  _overlayView.hidesSettingsButton = !_VRModeEnabled;
  _overlayView.hidesAlignmentMarker = !_VRModeEnabled;
  _overlayView.hidesFullscreenButton = !_VRModeEnabled;
  _overlayView.hidesCardboardButton = _VRModeEnabled;

  [_overlayView setNeedsLayout];
}

- (void)startRenderer {
  if (!_displayLink) {
    // Create a CADisplayLink instance to drive our render loop.
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(display)];
    if ([_displayLink respondsToSelector:@selector(preferredFramesPerSecond)]) {
      _displayLink.preferredFramesPerSecond = 60;
    }

    [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    _displayLink.paused = _paused;
  }

  [self updateOverlayView];
}

- (void)stopRenderer {
  // Invalidate CADisplayLink instance, which should release us.
  [_displayLink invalidate];
  _displayLink = nil;
}

@end
