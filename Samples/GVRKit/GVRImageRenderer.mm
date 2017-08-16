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

#import "GVRImageRenderer.h"

@implementation GVRImageRenderer {
  dispatch_block_t _textureLoader;
}

- (instancetype)initWithContentsOfFile:(NSString *)path {
  if (self = [super init]) {
    // Defer loading until the renderer is initialized.
    __weak __typeof(self) weakSelf = self;
    _textureLoader = ^{
      GLKTextureLoader *loader =
          [[GLKTextureLoader alloc] initWithSharegroup:EAGLContext.currentContext.sharegroup];
      [loader textureWithContentsOfFile:path
                                options:nil
                                  queue:NULL
                      completionHandler:^(GLKTextureInfo *textureInfo, NSError *outError) {
                        __strong __typeof(self) strongSelf = weakSelf;
                        if (textureInfo) {
                          // Allow non-power of 2 sized textures.
                          glBindTexture(textureInfo.target, textureInfo.name);
                          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                          glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                          glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

                          [strongSelf setImageTextureId:textureInfo.name];
                        }
                      }];
    };
  }
  return self;
}

- (instancetype)initWithImage:(UIImage *)image {
  if (self = [super init]) {
    // Defer loading until the renderer is initialized.
    __weak __typeof(self) weakSelf = self;
    _textureLoader = ^{
      GLKTextureLoader *loader =
          [[GLKTextureLoader alloc] initWithSharegroup:EAGLContext.currentContext.sharegroup];
      [loader textureWithCGImage:image.CGImage
                         options:nil
                           queue:NULL
               completionHandler:^(GLKTextureInfo *textureInfo, NSError *outError) {
                 __strong __typeof(self) strongSelf = weakSelf;
                 if (textureInfo) {
                   // Allow non-power of 2 sized textures.
                   glBindTexture(textureInfo.target, textureInfo.name);
                   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                   glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                   glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

                   [strongSelf setImageTextureId:textureInfo.name];
                 }
               }];
    };
  }
  return self;
}

#pragma mark - GVRTextureRenderer

- (void)initializeGl {
  [super initializeGl];
  // Load the texture once GL is initialized.
  if (_textureLoader) {
    _textureLoader();
  }
}

@end
