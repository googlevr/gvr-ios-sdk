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

#import "GVRSceneRenderer.h"

#import "GVRReticleRenderer.h"

@implementation GVRSceneRenderer {
  GVRReticleRenderer *_reticle;
}

#pragma mark - GVRRenderer

- (instancetype)init {
  if (self = [super init]) {
    _renderList = [[GVRRenderList alloc] init];
    _reticle = [[GVRReticleRenderer alloc] init];
  }
  return self;
}

- (void)initializeGl {
  [super initializeGl];

  [_renderList initializeGl];
  [_reticle initializeGl];
}

- (void)clearGl {
  [super clearGl];

  [_reticle clearGl];
  [_renderList clearGl];
}

- (void)update:(GVRHeadPose *)headPose {
  checkGLError("pre update");
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  glEnable(GL_DEPTH_TEST);
  glEnable(GL_SCISSOR_TEST);
  checkGLError("update");

  [_renderList update:headPose];

  if (!self.hidesReticle) {
    [_reticle update:headPose];
  }
}

- (void)draw:(GVRHeadPose *)headPose {
  CGRect viewport = [headPose viewport];
  glViewport(viewport.origin.x, viewport.origin.y, viewport.size.width, viewport.size.height);
  glScissor(viewport.origin.x, viewport.origin.y, viewport.size.width, viewport.size.height);

  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  checkGLError("glClear");

  [_renderList draw:headPose];

  if (!self.hidesReticle) {
    [_reticle draw:headPose];
  }
}

- (void)pause:(BOOL)pause {
  [super pause:pause];

  [_renderList pause:pause];
}

- (BOOL)handleTrigger:(GVRHeadPose *)headPose {
  return [_renderList handleTrigger:headPose];
}

@end

#pragma mark - GVRRenderList

@implementation GVRRenderList {
  NSMutableArray<GVRRenderObject> *_renderObjects;
}

@synthesize initialized;
@synthesize hidden;

- (instancetype)init {
  if (self = [super init]) {
    _renderObjects = [[NSMutableArray<GVRRenderObject> alloc] init];
  }
  return self;
}

- (void)addRenderObject:(id<GVRRenderObject>)renderTarget {
  [_renderObjects addObject:renderTarget];
}

- (void)insertRenderObject:(id<GVRRenderObject>)renderTarget atIndex:(NSUInteger)index {
  [_renderObjects insertObject:renderTarget atIndex:index];
}

- (void)removeRenderObject:(id<GVRRenderObject>)renderTarget {
  [_renderObjects removeObject:renderTarget];
}

- (void)removeRenderObjectAtIndex:(NSUInteger)index {
  [_renderObjects removeObjectAtIndex:index];
}

- (void)removeAll {
  [_renderObjects removeAllObjects];
}

- (id<GVRRenderObject>)objectAtIndex:(NSUInteger)index {
  return [_renderObjects objectAtIndex:index];
}

- (NSUInteger)count {
  return _renderObjects.count;
}

#pragma mark - GVRRenderObject

- (void)initializeGl {
  for (id<GVRRenderObject>target in _renderObjects) {
    [target initializeGl];
  }
  initialized = YES;
}

- (void)clearGl {
  for (id<GVRRenderObject>target in _renderObjects) {
    if ([target respondsToSelector:@selector(clearGl)]) {
      [target clearGl];
    }
  }
  initialized = NO;
}

- (void)update:(GVRHeadPose *)headPose {
  for (id<GVRRenderObject>target in _renderObjects) {
    if (!target.initialized) {
      [target initializeGl];
    }
    if (!target.hidden && target.initialized && [target respondsToSelector:@selector(update:)]) {
      [target update:headPose];
    }
  }
}

- (void)draw:(GVRHeadPose *)headPose {
  for (id<GVRRenderObject>target in _renderObjects) {
    if (!target.hidden && target.initialized) {
      [target draw:headPose];
    }
  }
}

- (void)pause:(BOOL)pause {
  for (id<GVRRenderObject>target in _renderObjects) {
    if ([target respondsToSelector:@selector(pause:)]) {
      [target pause:pause];
    }
  }
}

- (BOOL)handleTrigger:(GVRHeadPose *)headPose {
  for (id<GVRRenderObject>target in _renderObjects) {
    if ([target respondsToSelector:@selector(handleTrigger:)]) {
      if ([target handleTrigger:headPose]) {
        return YES;
      }
    }
  }
  return NO;
}

@end

#pragma mark - GL Helper methods

void checkGLError(const char *label) {
  int gl_error = glGetError();
  if (gl_error != GL_NO_ERROR) {
    NSLog(@"GL error %s: %d", label, gl_error);
  }
  assert(glGetError() == GL_NO_ERROR);
}

GLuint loadShader(GLenum type, const char *shader_src) {
  GLint compiled = 0;

  // Create the shader object
  const GLuint shader = glCreateShader(type);
  if (shader == 0) {
    return 0;
  }
  // Load the shader source
  glShaderSource(shader, 1, &shader_src, NULL);

  // Compile the shader
  glCompileShader(shader);
  // Check the compile status
  glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);

  if (!compiled) {
    GLint info_len = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &info_len);

    if (info_len > 1) {
      char *info_log = ((char *)malloc(sizeof(char) * info_len));
      glGetShaderInfoLog(shader, info_len, NULL, info_log);
      NSLog(@"Error compiling shader:%s", info_log);
      free(info_log);
    }
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

// Checks the link status of the given program.
bool checkProgramLinkStatus(GLuint shader_program) {
  GLint linked = 0;
  glGetProgramiv(shader_program, GL_LINK_STATUS, &linked);

  if (!linked) {
    GLint info_len = 0;
    glGetProgramiv(shader_program, GL_INFO_LOG_LENGTH, &info_len);

    if (info_len > 1) {
      char *info_log = ((char *)malloc(sizeof(char) * info_len));
      glGetProgramInfoLog(shader_program, info_len, NULL, info_log);
      NSLog(@"Error linking program: %s", info_log);
      free(info_log);
    }
    glDeleteProgram(shader_program);
    return false;
  }
  return true;
}
