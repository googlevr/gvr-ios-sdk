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

#import "GVRRenderer.h"

static const uint64_t kPredictionTimeWithoutVsyncNanos = 50000000;

// Exposes internal methods of GVRHeadPose.
@interface GVRHeadPose (GVRInternal)

// Set the head pose transform, orientation and render size.
- (void)setHeadPose:(gvr::Mat4f &)headPose
         renderSize:(gvr::Sizei)renderSize
        orientation:(UIInterfaceOrientation)orientation
      nextFrameTime:(NSTimeInterval)nextFrameTime;

// Set the eye transform for a given eye and its viewport.
- (void)setEyePose:(gvr::Mat4f &)eyePose
            forEye:(GVREye)eye
    bufferViewport:(gvr::BufferViewport *)bufferViewport;

// Add yaw and pitch rotation to the head pose.
- (void)addToHeadRotationYaw:(CGFloat)yaw andPitch:(CGFloat)pitch;

// Remove all yaw and pitch rotations from the head pose.
- (void)resetHeadRotation;

@end

@interface GVRRenderer () {
  std::unique_ptr<gvr::GvrApi> _gvrApi;
  std::unique_ptr<gvr::BufferViewportList> _viewportList;
  std::unique_ptr<gvr::SwapChain> _swapchain;
  gvr::Sizei _renderSize;
  gvr::Sizei _size;
  UIInterfaceOrientation _orientation;
  GLKMatrix4 _headRotation;
  GVRHeadPose *_headPose;
}
@end

@implementation GVRRenderer

- (instancetype)init {
  if (self = [super init]) {
    _headPose = [[GVRHeadPose alloc] init];
  }
  return self;
}

- (void)initializeGl {
  _gvrApi = gvr::GvrApi::Create();
  _gvrApi->InitializeGl();

  std::vector<gvr::BufferSpec> specs;
  specs.push_back(_gvrApi->CreateBufferSpec());
  _renderSize = specs[0].GetSize();
  _swapchain.reset(new gvr::SwapChain(_gvrApi->CreateSwapChain(specs)));
  _viewportList.reset(new gvr::BufferViewportList(_gvrApi->CreateEmptyBufferViewportList()));

  _headRotation = GLKMatrix4Identity;
}

- (void)clearGl {
  _viewportList.release();
  _swapchain.release();
  _gvrApi.release();
}

- (void)drawFrame:(NSTimeInterval)nextFrameTime {
  gvr::ClockTimePoint target_time = gvr::GvrApi::GetTimePointNow();
  target_time.monotonic_system_time_nanos += kPredictionTimeWithoutVsyncNanos;

  gvr::Mat4f gvr_head_pose = _gvrApi->GetHeadSpaceFromStartSpaceRotation(target_time);
  [_headPose setHeadPose:gvr_head_pose
             renderSize:(_VRModeEnabled ? _renderSize : _size)
            orientation:_orientation
          nextFrameTime:nextFrameTime];

  [self update:_headPose];

  if (!self.VRModeEnabled) {
    // Draw head (center eye) for monoscopic rendering.
    [self draw:_headPose];
  } else {
    _viewportList->SetToRecommendedBufferViewports();

    gvr::Frame frame = _swapchain->AcquireFrame();
    frame.BindBuffer(0);

    // Draw eyes.
    gvr::BufferViewport viewport;
    for (int eye = GVR_LEFT_EYE; eye <= GVR_RIGHT_EYE; eye++) {
      _viewportList->GetBufferViewport(eye, &viewport);

      gvr::Mat4f eye_pose = _gvrApi->GetEyeFromHeadMatrix(static_cast<gvr_eye>(eye));

      [_headPose setEyePose:eye_pose forEye:static_cast<GVREye>(eye) bufferViewport:&viewport];

      [self draw:_headPose];
    }

    // Bind back to the default framebuffer.
    frame.Unbind();
    frame.Submit(*_viewportList, gvr_head_pose);
  }
}

- (void)refresh {
  if (_gvrApi) {
    _gvrApi->RefreshViewerProfile();
  }
}

- (void)addToHeadRotationYaw:(CGFloat)yaw andPitch:(CGFloat)pitch {
  [_headPose addToHeadRotationYaw:yaw andPitch:pitch];
}

- (void)resetHeadRotation {
  [_headPose resetHeadRotation];
  if (_gvrApi) {
    gvr_reset_tracking(_gvrApi->GetContext());
  }
}

- (void)setSize:(CGSize)size andOrientation:(UIInterfaceOrientation)orientation {
  CGFloat scale = [GVRRenderer screenDpi];
  _size = {static_cast<int32_t>(size.width * scale), static_cast<int32_t>(size.height * scale)};

  _orientation = orientation;
}

- (void)pause:(BOOL)pause {
  if (!_gvrApi) {
    return;
  }

  if (pause) {
    _gvrApi->PauseTracking();
  } else {
    _gvrApi->ResumeTracking();
  }
}

- (BOOL)handleTrigger {
  return [self handleTrigger:_headPose];
}

- (BOOL)handleTrigger:(GVRHeadPose *)headPose {
  // Overridden by subclasses.
  return NO;
}

- (void)update:(GVRHeadPose *)headPose {
  // Overridden by subclasses.
}

- (void)draw:(GVRHeadPose *)headPose {
  // Overridden by subclasses.
}

#pragma mark - Private

+ (CGFloat)screenDpi {
  static dispatch_once_t onceToken;
  static CGFloat scale;
  dispatch_once(&onceToken, ^{
    if ([[UIScreen mainScreen] respondsToSelector:@selector(nativeScale)]) {
      scale = [UIScreen mainScreen].nativeScale;
    } else {
      scale = [UIScreen mainScreen].scale;
    }
  });

  return scale;
}

@end
