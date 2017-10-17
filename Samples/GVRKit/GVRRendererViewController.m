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

#import "GVRRendererViewController.h"

#import "GVRRendererView.h"

@interface GVRRendererViewController ()<GVROverlayViewDelegate> {
  GVRRenderer *_renderer;
}

@end

@implementation GVRRendererViewController

- (instancetype)initWithRenderer:(GVRRenderer *)renderer {
  if (self = [super init]) {
    _renderer = renderer;
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (GVRRendererView *)rendererView {
  return (GVRRendererView *)self.view;
}

- (void)loadView {
  if (!_renderer && [self.delegate respondsToSelector:@selector(rendererForDisplayMode:)]) {
    _renderer = [self.delegate rendererForDisplayMode:kGVRDisplayModeEmbedded];
  }
  self.view = [[GVRRendererView alloc] initWithRenderer:_renderer];
}

- (void)viewDidLoad {
  [super viewDidLoad];

  // We need device orientation change notifications to work.
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
  });

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(didChangeOrientation:)
                                               name:UIDeviceOrientationDidChangeNotification
                                             object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  self.rendererView.paused = NO;
  self.rendererView.overlayView.delegate = self;

  if (self.isModal) {
    // Back button is always visible when presented.
    self.rendererView.overlayView.hidesBackButton = NO;
  }
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];

  self.rendererView.paused = YES;

  // Since our orientation is fixed to landscape right in modal state, upon returning from the modal
  // state, reset the UI orientation to the device's orientation.
  if (self.isModal) {
    [UIViewController attemptRotationToDeviceOrientation];
  }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  // GVR only supports landscape right orientation when the phone is inserted in the viewer.
  if (self.isModal) {
    return UIInterfaceOrientationMaskLandscapeRight;
  } else {
    return [super supportedInterfaceOrientations];
  }
}

#pragma mark - GVROverlayViewDelegate - Works only when we are presented.

- (void)didTapTriggerButton {
  // In embedded mode, pass the trigger tap to our delegate.
  if (self.isModal && [self.delegate respondsToSelector:@selector(didTapTriggerButton)]) {
    [self.delegate didTapTriggerButton];
  }
}

- (void)didTapBackButton {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (UIViewController *)presentingViewControllerForSettingsDialog {
  return self;
}

- (void)didPresentSettingsDialog:(BOOL)presented {
  // The overlay view is presenting the settings dialog. Pause our rendering while presented.
  self.rendererView.paused = presented;
}

- (void)didChangeViewerProfile {
  // Renderer's OnResume also refreshes viewer profile.
  [_renderer refresh];
}

- (void)shouldDisableIdleTimer:(BOOL)shouldDisable {
  [UIApplication sharedApplication].idleTimerDisabled = shouldDisable;
}

- (void)didTapCardboardButton {
  // Toggle VR mode if we are being presented.
  if ([self isModal]) {
    self.rendererView.VRModeEnabled = !self.rendererView.VRModeEnabled;
  } else {
    // We are in embedded mode, present another instance of GVRRendererViewController.
    if ([self.delegate respondsToSelector:@selector(rendererForDisplayMode:)]) {
      // Check if cardboard or fullscreen button was shown on the overlay view to determine
      // VRModeEnabled flag.
      BOOL VRModeEnabled = self.rendererView.overlayView.hidesFullscreenButton &&
                           !self.rendererView.overlayView.hidesCardboardButton;
      GVRDisplayMode displayMode = (VRModeEnabled ? kGVRDisplayModeFullscreenStereoscopic
                                                  : kGVRDisplayModeFullscreenMonoscopic);
      GVRRenderer *renderer = [self.delegate rendererForDisplayMode:displayMode];

      GVRRendererViewController *viewController =
          [[GVRRendererViewController alloc] initWithRenderer:renderer];
      GVRRendererView *rendererView = viewController.rendererView;

      if ([self.delegate respondsToSelector:@selector(shouldHideTransitionView)]) {
        rendererView.overlayView.hidesTransitionView = [self.delegate shouldHideTransitionView];
      }

      rendererView.VRModeEnabled = VRModeEnabled;

      [self.parentViewController presentViewController:viewController animated:YES completion:nil];
    }
  }
}

#pragma mark - NSNotificationCenter

- (void)didChangeOrientation:(NSNotification *)notification {
  // Request a layout change on the render view since iOS does not call layoutSubviews on 180-degree
  // orientation changes.
  [self.view setNeedsLayout];
}

#pragma mark - Private

// Returns YES if this view controller is being presented. */
- (BOOL)isModal {
  if ([self presentingViewController]) {
    return YES;
  }
  if ([[[self navigationController] presentingViewController] presentedViewController] ==
      [self navigationController]) {
    return YES;
  }
  if ([[[self tabBarController] presentingViewController]
          isKindOfClass:[UITabBarController class]]) {
    return YES;
  }

  return NO;
}

@end
