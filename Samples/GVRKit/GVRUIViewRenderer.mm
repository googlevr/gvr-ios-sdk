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

#import "GVRUIViewRenderer.h"

#include <OpenGLES/ES2/glext.h>

// 1 meter width at 1 meter depth = 2 * atan(0.5) = 53.13 degrees per meter.
// 15 pixels per degree * 53.13 degrees per meter = 796.951535313 pixels per meter.
static const CGFloat kPixelsPerMeter = 796.951535313f;
static constexpr float kDefaultEpsilon = 1.0e-5f;

@interface GVRTextureRenderer (Subclassing)
- (void)setFlipTextureVertically:(BOOL)flipTextureVertically;
@end

@implementation GVRUIViewRenderer {
  UIView *_view;
  CVPixelBufferRef _pixelBuffer;
  CVOpenGLESTextureRef _texture;
  CVOpenGLESTextureCacheRef _textureCache;
  CGPoint _hitTestPoint;
}

- (instancetype)initWithView:(UIView *)view {
  if (self = [super init]) {
    super.flipTextureVertically = YES;

    _view = view;
  }
  return self;
}

- (void)dealloc {
  [self cleanUpTextures];
  [self clearGl];
}

- (void)setView:(UIView *)view {
  [self willChangeValueForKey:@"view"];
  _view = view;
  [self didChangeValueForKey:@"view"];
}

#pragma mark - GVRTextureRenderer

- (void)initializeGl {
  [super initializeGl];

  if (self.initialized) {
    // Create texture cache.
    CVReturn status = CVOpenGLESTextureCacheCreate(
        kCFAllocatorDefault, NULL, [EAGLContext currentContext], NULL, &_textureCache);
    NSAssert(status == noErr, @"Error at CVOpenGLESTextureCacheCreate %d", status);
  }
}

- (void)clearGl {
  [super clearGl];

  if (_pixelBuffer) {
    CVPixelBufferRelease(_pixelBuffer);
    _pixelBuffer = NULL;
  }
  if (_textureCache) {
    CFRelease(_textureCache);
    _textureCache = NULL;
  }
}

- (void)update:(GVRHeadPose *)headPose {
  // We should have a non-empty view to render.
  if (!_view || CGRectIsEmpty(_view.bounds)) {
    // Cleanup previous textures.
    [self cleanUpTextures];
    return;
  }

  // Create a pixel buffer to render the UIView if it does not exist or view's size has changed.
  if (!_pixelBuffer || CVPixelBufferGetWidth(_pixelBuffer) != _view.bounds.size.width ||
      CVPixelBufferGetHeight(_pixelBuffer) != _view.bounds.size.height) {
    // De-allocate previous pixel buffer.
    if (_pixelBuffer) {
      CVPixelBufferRelease(_pixelBuffer);
    }

    // Set the mesh from the view size.
    [self setMeshFromSize:_view.bounds.size];

    // Now create the pixel buffer.
    NSDictionary *options = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferOpenGLCompatibilityKey : @(YES),
      (id)kCVPixelBufferOpenGLESTextureCacheCompatibilityKey : @(YES)
    };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          (int)_view.bounds.size.width,
                                          (int)_view.bounds.size.height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)options,
                                          &_pixelBuffer);
    NSAssert(status == kCVReturnSuccess, @"Error allocating pixel buffer %d", status);
  }

  CVReturn status = CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
  NSAssert(status == kCVReturnSuccess, @"Error locking pixel buffer %d", status);

  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  NSAssert(colorSpace != NULL, @"Error creating color space");

  CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(_pixelBuffer),
                                               CVPixelBufferGetWidth(_pixelBuffer),
                                               CVPixelBufferGetHeight(_pixelBuffer),
                                               8,
                                               CVPixelBufferGetBytesPerRow(_pixelBuffer),
                                               colorSpace,
                                               kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(colorSpace);
  NSAssert(context != NULL, @"Error creating bitmap context.");

  // Draw the view to the pixel buffer.
  [_view.layer renderInContext:context];

  CGContextRelease(context);
  CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);

  // Cleanup previous textures.
  [self cleanUpTextures];

  // Create a texture from the pixel buffer.
  status = CVOpenGLESTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,  // The CFAllocatorRef to use for allocating the texture object.
      _textureCache,        // The texture cache object that will manage the texture.
      _pixelBuffer,         // The CVImageBufferRef that you want to create a texture from.
      NULL,                 // A CFDictionaryRef for creating the CVOpenGLESTextureRef objects.
      GL_TEXTURE_2D,        // The target texture. Can be GL_TEXTURE_2D or GL_RENDERBUFFER.
      GL_RGBA,              // The number of color components in the texture.
      (GLsizei)CVPixelBufferGetWidth(_pixelBuffer),   // The width of the texture image.
      (GLsizei)CVPixelBufferGetHeight(_pixelBuffer),  // The height of the texture image.
      GL_RGBA,                                        // The format of the pixel data.
      GL_UNSIGNED_BYTE,                               // The data type of the pixel data.
      0,           // The plane of the CVImageBufferRef to map bind.
      &_texture);  // Where the newly created texture object will be placed.

  if (status == kCVReturnSuccess) {
    [self setImageTextureId:CVOpenGLESTextureGetName(_texture)];
  }

  // Perform hittest for hover animations.
  // if (_view.userInteractionEnabled) {
  //  [self hitTest:headPose];
  //}

  [super update:headPose];
}

- (BOOL)handleTrigger:(GVRHeadPose *)headPose {
  if (_view.userInteractionEnabled && [self hitTest:headPose]) {
    UIView *subview = [_view hitTest:_hitTestPoint withEvent:nil];
    if ([subview respondsToSelector:@selector(sendActionsForControlEvents:)]) {
      [(UIControl *)subview sendActionsForControlEvents:UIControlEventTouchUpInside];
      return YES;
    }
  }
  return NO;
}

#pragma mark - Private

- (void)setMeshFromSize:(CGSize)size {
  CGFloat width = size.width / kPixelsPerMeter;
  CGFloat height = size.height / kPixelsPerMeter;

  [self setQuadMeshOfWidth:width height:height meshType:kGVRMeshTypeMonoscopic];
}

- (void)cleanUpTextures {
  if (_texture) {
    CFRelease(_texture);
    _texture = NULL;
  }

  if (_textureCache) {
    CVOpenGLESTextureCacheFlush(_textureCache, 0);
  }
}

- (BOOL)hitTest:(GVRHeadPose *)headPose {
  _hitTestPoint.x = nan(NULL);
  _hitTestPoint.y = nan(NULL);

  GLKQuaternion headRotation =
      GLKQuaternionMakeWithMatrix4(GLKMatrix4Transpose([headPose headTransform]));

  GLKVector3 cameraOrigin = GLKVector3Make(0.0f, 0.0f, 0.0f);
  GLKVector3 cameraDirection = GLKQuaternionRotateVector3(headRotation, GLKVector3Make(0, 0, -1));
  cameraDirection = GLKVector3Normalize(cameraDirection);

  // Transform camera "ray" to our model space.
  GLKMatrix4 modelSpace = GLKMatrix4Invert(self.position, nil);
  GLKVector3 modelOrigin = GLKMatrix4MultiplyVector3WithTranslation(modelSpace, cameraOrigin);
  GLKVector3 modelDirection = GLKMatrix4MultiplyVector3(modelSpace, cameraDirection);

  // If the ray is negative or only barely positive, then the ray is pointing away from the plane.
  if (fabs(modelDirection.v[2]) < kDefaultEpsilon) {
    return NO;
  }

  // If bounding box is zero, the intersection point is 0,0.
  GLKVector3 aabbDiff = GLKVector3Subtract(self.aabbMax, self.aabbMin);
  if (GLKVector3Length(aabbDiff) < kDefaultEpsilon) {
    return NO;
  }

  const float lambda = -modelOrigin.v[2] / modelDirection.v[2];
  GLKVector3 delta = GLKVector3Add(modelOrigin, GLKVector3MultiplyScalar(modelDirection, lambda));
  GLKVector3 relativeDelta =
      GLKVector3Divide(GLKVector3Subtract(delta, self.aabbMin), aabbDiff);
  CGPoint intersection = CGPointMake(relativeDelta.v[0], relativeDelta.v[1]);

  intersection.y += -self.aabbMax.v[1] / aabbDiff.v[1];
  intersection.y *= -1;

  intersection.x *= _view.bounds.size.width;
  intersection.y *= _view.bounds.size.height;

  if (intersection.x >= 0 && intersection.x < _view.bounds.size.width &&
      intersection.y >= 0 && intersection.y < _view.bounds.size.height) {
    _hitTestPoint = intersection;
    return YES;
  }

  return NO;
}


@end
