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

#import "GVRHeadPose.h"

// For monoscopic rendering, define 45 degree half angle horizontally and vertically.
static const float kMonoFieldOfView = 45.0f;

namespace {

static void GVRMatrixToGLKMatrix4(const gvr::Mat4f &matrix, GLKMatrix4 *glkMatrix) {
  // Note that this performs a *tranpose* to a column-major matrix array, as
  // expected by GL.
  float result[16];
  for (int i = 0; i < 4; ++i) {
    for (int j = 0; j < 4; ++j) {
      result[j * 4 + i] = matrix.m[i][j];
    }
  }
  *glkMatrix = GLKMatrix4MakeWithArray(result);
}

static gvr::Recti CalculatePixelSpaceRect(const gvr::Sizei &size, const gvr::Rectf &source_rect) {
  float width = static_cast<float>(size.width);
  float height = static_cast<float>(size.height);
  gvr::Rectf rect = {source_rect.left * width, source_rect.right * width,
                     source_rect.bottom * height, source_rect.top * height};
  gvr::Recti result = {static_cast<int>(rect.left), static_cast<int>(rect.right),
                       static_cast<int>(rect.bottom), static_cast<int>(rect.top)};
  return result;
}

static gvr::Mat4f PerspectiveMatrixFromView(const GVRFieldOfView &fov, float z_near, float z_far) {
  gvr::Mat4f result;
  const float x_left = -std::tan(fov.left * M_PI / 180.0f) * z_near;
  const float x_right = std::tan(fov.right * M_PI / 180.0f) * z_near;
  const float y_bottom = -std::tan(fov.bottom * M_PI / 180.0f) * z_near;
  const float y_top = std::tan(fov.top * M_PI / 180.0f) * z_near;
  const float zero = 0.0f;

  assert(x_left < x_right && y_bottom < y_top && z_near < z_far && z_near > zero && z_far > zero);
  const float X = (2 * z_near) / (x_right - x_left);
  const float Y = (2 * z_near) / (y_top - y_bottom);
  const float A = (x_right + x_left) / (x_right - x_left);
  const float B = (y_top + y_bottom) / (y_top - y_bottom);
  const float C = (z_near + z_far) / (z_near - z_far);
  const float D = (2 * z_near * z_far) / (z_near - z_far);

  for (int i = 0; i < 4; ++i) {
    for (int j = 0; j < 4; ++j) {
      result.m[i][j] = 0.0f;
    }
  }
  result.m[0][0] = X;
  result.m[0][2] = A;
  result.m[1][1] = Y;
  result.m[1][2] = B;
  result.m[2][2] = C;
  result.m[2][3] = D;
  result.m[3][2] = -1;

  return result;
}

}  // namespace

@implementation GVRHeadPose {
  UIInterfaceOrientation _orientation;
  gvr::Sizei _renderSize;
  CGFloat _yaw;
  CGFloat _pitch;
}

- (instancetype)init {
  if (self = [super init]) {
    _yaw = _pitch = 0.0f;
  }
  return self;
}

- (void)setHeadPose:(gvr::Mat4f &)headPose
         renderSize:(gvr::Sizei)renderSize
        orientation:(UIInterfaceOrientation)orientation
      nextFrameTime:(NSTimeInterval)nextFrameTime {
  // Next frame time.
  _nextFrameTime = nextFrameTime;

  // Eye.
  _eye = kGVRCenterEye;

  // Head transform.
  GVRMatrixToGLKMatrix4(headPose, &_headTransform);

  // Apply yaw rotation.
  _headTransform = GLKMatrix4Multiply(_headTransform, GLKMatrix4MakeYRotation(_yaw));

  // For pitch rotation we have to take the interface orientation into account. GVR always draws in
  // landscape right orientation, where the pitch is correctly applied to X axis. But in portrait
  // mode, we apply the pitch to the Y axis.
  if (UIInterfaceOrientationIsLandscape(_orientation)) {
    _headTransform = GLKMatrix4Multiply(GLKMatrix4MakeXRotation(_pitch), _headTransform);
  } else {
    _headTransform = GLKMatrix4Multiply(GLKMatrix4MakeYRotation(_pitch), _headTransform);
  }

  // Eye transform.
  _eyeTransform = GLKMatrix4Identity;

  // View transform.
  _viewTransform = _headTransform;

  // Viewport.
  _renderSize = renderSize;
  _viewport = CGRectMake(0, 0, _renderSize.width, _renderSize.height);

  // Field of view.
  const float aspect_ratio = (float)_renderSize.width / (float)_renderSize.height;
  float vertFov = kMonoFieldOfView;
  float horizFov =
      std::atan(aspect_ratio * std::tan(kMonoFieldOfView * M_PI / 180.0f)) * 180 / M_PI;
  _fieldOfView = {horizFov, horizFov, vertFov, vertFov};

  _orientation = orientation;
}

- (void)setEyePose:(gvr::Mat4f &)eyePose
            forEye:(GVREye)eye
    bufferViewport:(gvr::BufferViewport *)bufferViewport {
  // Eye.
  _eye = eye;

  // Eye transform.
  GVRMatrixToGLKMatrix4(eyePose, &_eyeTransform);

  // View transform.
  _viewTransform = GLKMatrix4Multiply(_eyeTransform, _headTransform);

  // Viewport.
  gvr::Recti pixel_rect = CalculatePixelSpaceRect(_renderSize, bufferViewport->GetSourceUv());
  _viewport = CGRectMake(pixel_rect.left,
                         pixel_rect.bottom,
                         pixel_rect.right - pixel_rect.left,
                         pixel_rect.top - pixel_rect.bottom);

  // Field of view.
  const gvr::Rectf &fov = bufferViewport->GetSourceFov();
  _fieldOfView = {fov.left, fov.right, fov.bottom, fov.top};
}

- (void)addToHeadRotationYaw:(CGFloat)yaw andPitch:(CGFloat)pitch {
  _yaw += yaw;
  _pitch += pitch;
}

- (void)resetHeadRotation {
  _yaw = _pitch = 0.0f;
}

- (void)setProjectionMatrixWithNear:(CGFloat)near far:(CGFloat)far {
  _projectionTransform = [self projectionMatrixWithNear:near far:far];
}

- (GLKMatrix4)projectionMatrixWithNear:(CGFloat)near far:(CGFloat)far {
  gvr::Mat4f perspective = PerspectiveMatrixFromView(_fieldOfView, near, far);
  GLKMatrix4 transform;
  GVRMatrixToGLKMatrix4(perspective, &transform);
  return GLKMatrix4Multiply(transform, [self interfaceRotationFromOrientation:_orientation]);
}

- (GLKMatrix4)interfaceRotationFromOrientation:(UIInterfaceOrientation)orientation {
  // Compute interface rotation matrix based on interface orientation.
  switch (orientation) {
    case UIInterfaceOrientationPortrait:
      return GLKMatrix4MakeZRotation(-M_PI_2);
      break;
    case UIInterfaceOrientationPortraitUpsideDown:
      return GLKMatrix4MakeZRotation(M_PI_2);
      break;
    case UIInterfaceOrientationLandscapeLeft:
      return GLKMatrix4MakeZRotation(M_PI);
      break;

    case UIInterfaceOrientationLandscapeRight:
    default:
      return GLKMatrix4Identity;
      break;
  }
}

@end
