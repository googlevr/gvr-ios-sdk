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

#import "GVRVideoRenderer.h"

#include <OpenGLES/ES2/glext.h>
#include <OpenGLES/ES3/gl.h>

// Studio swing implies:
//     Y values are in the range [16, 235];
//     Cb and Cr are [16, 240].
// (see e.g. BT.601 Annex 1, Table 3, Row 8; BT.709 Section 4 ('Digital representation') Row 4.6)
//
// In OpenGL RGB land, all three channels are [0, 255].
//
// The matrices below handle the necessary scale, origin and axis adjustments necessary to translate
// from the BT colour spaces to RGB.

// BT.601 colorspace, studio swing.
static const GLKMatrix4 kColorConversionMatrix601 = {
    1.164, 1.164,  1.164, 0.0, 0.0,       -0.392,   2.017,    0.0,  // NOLINT
    1.596, -0.813, 0.0,   0.0, -0.874165, 0.531828, -1.08549, 1.0}; // NOLINT

// BT.709 colorspace, studio swing.
static const GLKMatrix4 kColorConversionMatrix709 = {
    1.164, 1.164,  1.164, 0.0, 0.0,       -0.213,   2.112,    0.0,  // NOLINT
    1.793, -0.533, 0,     0.0, -0.973051, 0.301427, -1.13318, 1.0}; // NOLINT

@interface GVRTextureRenderer (Subclassing)
- (void)setIsVideoTextureRenderer:(BOOL)isVideoTextureRenderer;
@end

@implementation GVRVideoRenderer {
  AVPlayer *_player;
  AVPlayerItemVideoOutput *_videoOutput;

  CVOpenGLESTextureRef _lumaTexture;
  CVOpenGLESTextureRef _chromaTexture;
  CVOpenGLESTextureCacheRef _videoTextureCache;
}

- (void)dealloc {
  [_player.currentItem removeOutput:_videoOutput];
  [_player removeObserver:self forKeyPath:@"status"];
}

- (void)setPlayer:(AVPlayer *)player {
  // Remove KVO from previous player.
  [_player.currentItem removeOutput:_videoOutput];
  [_player removeObserver:self forKeyPath:@"status"];

  _player = player;

  // Create a pixel buffer to hold AVPlayerItemVideoOutput.
  NSDictionary *attributes =
      @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
  _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attributes];

  // Observe player's status property.
  [_player addObserver:self forKeyPath:@"status" options:0 context:nil];
  if (_player.status == AVPlayerStatusReadyToPlay) {
    [_player.currentItem addOutput:_videoOutput];
  }
}

#pragma mark - Private

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (object == _player && [keyPath isEqualToString:@"status"]) {
    if (_player.status == AVPlayerStatusReadyToPlay) {
      if (![_player.currentItem.outputs containsObject:_videoOutput]) {
        [_player.currentItem addOutput:_videoOutput];
      }
    }
  }
}

#pragma mark - GVRTextureRenderer

- (void)initializeGl {
  super.isVideoTextureRenderer = YES;
  [super initializeGl];

  // Create texture cache.
  CVReturn err = CVOpenGLESTextureCacheCreate(
      kCFAllocatorDefault, NULL, [EAGLContext currentContext], NULL, &_videoTextureCache);
  NSAssert(err == noErr, @"Error at CVOpenGLESTextureCacheCreate %d", err);
}

- (void)clearGl {
  [super clearGl];

  [self cleanUpTextures];
  if (_videoTextureCache) {
    CFRelease(_videoTextureCache);
    _videoTextureCache = NULL;
  }
}

- (void)update:(GVRHeadPose *)headPose {
  CMTime itemTime = [_videoOutput itemTimeForHostTime:headPose.nextFrameTime];

  if ([_videoOutput hasNewPixelBufferForItemTime:itemTime]) {
    CVPixelBufferRef pixelBuffer =
        [_videoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
    if (pixelBuffer) {
      [self cleanUpTextures];
      int videoWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
      int videoHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
      BOOL requiresChannelSizes = EAGLContext.currentContext.API > kEAGLRenderingAPIOpenGLES2;

      // Create Y and UV textures from the pixel buffer. RGB is not supported.
      _lumaTexture = [self createSourceTexture:pixelBuffer
                                         index:0
                                        format:requiresChannelSizes ? GL_RED : GL_RED_EXT
                                internalFormat:requiresChannelSizes ? GL_R8 : GL_RED_EXT
                                         width:videoWidth
                                        height:videoHeight];
      // UV-plane.
      _chromaTexture = [self createSourceTexture:pixelBuffer
                                           index:1
                                          format:requiresChannelSizes ? GL_RG : GL_RG_EXT
                                  internalFormat:requiresChannelSizes ? GL_RG8 : GL_RG_EXT
                                           width:(videoWidth + 1) / 2
                                          height:(videoHeight + 1) / 2];

      // Use the color attachment to determine the appropriate color conversion matrix.
      CFTypeRef colorAttachments =
          CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL);
      GLKMatrix4 colorConversionMatrix =
          CFEqual(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
              ? kColorConversionMatrix601
              : kColorConversionMatrix709;

      GLuint lumaTextureId = CVOpenGLESTextureGetName(_lumaTexture);
      GLuint chromaTextureId = CVOpenGLESTextureGetName(_chromaTexture);
      [self setVideoYTextureId:lumaTextureId
                    uvTextureId:chromaTextureId
          colorConversionMatrix:colorConversionMatrix];

      CFRelease(pixelBuffer);
      pixelBuffer = 0;
    }
  }
  [super update:headPose];
}

- (CVOpenGLESTextureRef)createSourceTexture:(CVPixelBufferRef)pixelBuffer
                                      index:(int)index
                                     format:(GLint)format
                             internalFormat:(GLint)internalFormat
                                      width:(int)width
                                     height:(int)height {
  CVOpenGLESTextureRef texture;
  CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,  // The CFAllocatorRef to use for allocating the texture object.
      _videoTextureCache,   // The texture cache object that will manage the texture.
      pixelBuffer,          // The CVImageBufferRef that you want to create a texture from.
      NULL,                 // A CFDictionaryRef for creating the CVOpenGLESTextureRef objects.
      GL_TEXTURE_2D,        // The target texture. Can be GL_TEXTURE_2D or GL_RENDERBUFFER.
      internalFormat,       // The number of color components in the texture.
      width,                // The width of the texture image.
      height,               // The height of the texture image.
      format,               // The format of the pixel data.
      GL_UNSIGNED_BYTE,     // The data type of the pixel data.
      index,                // The plane of the CVImageBufferRef to map bind.
      &texture);            // Where the newly created texture object will be placed.

  if (err) {
    NSLog(@"Could not create Texture, err = %d", err);
    return NULL;
  }

  glBindTexture(CVOpenGLESTextureGetTarget(texture), CVOpenGLESTextureGetName(texture));
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  return texture;
}

- (void)cleanUpTextures {
  if (_lumaTexture) {
    CFRelease(_lumaTexture);
    _lumaTexture = NULL;
  }

  if (_chromaTexture) {
    CFRelease(_chromaTexture);
    _chromaTexture = NULL;
  }

  if (_videoTextureCache) {
    CVOpenGLESTextureCacheFlush(_videoTextureCache, 0);
  }
}

@end
