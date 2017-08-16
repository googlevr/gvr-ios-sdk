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

#import "GVRReticleRenderer.h"

// The reticle quad is 2 * SIZE units.
static const float kReticleSize = .01f;
static const float kReticleDistance = 0.3;
static const int kCoordsPerVertex = 3;
static const NSInteger kVertexStrideBytes = kCoordsPerVertex * sizeof(float);
static const float kVertexData[] = {
  -kReticleSize, -kReticleSize, -kReticleDistance,
  kReticleSize, -kReticleSize, -kReticleDistance,
  -kReticleSize, kReticleSize, -kReticleDistance,
  kReticleSize, kReticleSize, -kReticleDistance,
};

// Vertex shader implementation.
static const char *kVertexShaderString = R"(
uniform mat4 uMvpMatrix;
attribute vec3 aPosition;
varying vec2 vCoords;

// Passthrough normalized vertex coordinates.
void main() {
  gl_Position = uMvpMatrix * vec4(aPosition, 1);
  vCoords = aPosition.xy / vec2(.01, .01);
}
)";

// Procedurally render a ring on the quad between the specified radii.
static const char *kPassThroughFragmentShaderString = R"(
precision mediump float;
varying vec2 vCoords;

// Simple ring shader that is white between the radii and transparent elsewhere.
void main() {
  float r = length(vCoords);
  // Blend the edges of the ring at .55 +/- .05 and .85 +/- .05.
  float alpha = smoothstep(0.5, 0.6, r) * (1.0 - smoothstep(0.8, 0.9, r));
  if (alpha == 0.0) {
    discard;
  } else {
    gl_FragColor = vec4(alpha);
  }
}
)";

@implementation GVRReticleRenderer {
  GLuint _program;
  GLint _positionAttrib;
  GLint _mvpMatrix;
  GLuint _vertex_buffer;
}

- (instancetype)init {
  if (self = [super init]) {
    _depth = -0.3;
  }
  return self;
}

@synthesize initialized;
@synthesize hidden;

- (void)initializeGl {
  // Load the vertex/fragment shaders.
  const GLuint vertex_shader = loadShader(GL_VERTEX_SHADER, kVertexShaderString);
  NSAssert(vertex_shader != 0, @"Failed to load vertex shader");
  const GLuint fragment_shader =
  loadShader(GL_FRAGMENT_SHADER, kPassThroughFragmentShaderString);
  NSAssert(fragment_shader != 0, @"Failed to load fragment shader");

  _program = glCreateProgram();
  NSAssert(_program != 0, @"Failed to create program");
  glAttachShader(_program, vertex_shader);
  glAttachShader(_program, fragment_shader);

  // Link the shader program.
  glLinkProgram(_program);
  NSAssert(checkProgramLinkStatus(_program), @"Failed to link _program");

  // Get the location of our attributes so we can bind data to them later.
  _positionAttrib = glGetAttribLocation(_program, "aPosition");
  NSAssert(_positionAttrib != -1, @"glGetAttribLocation failed for aPosition");
  _mvpMatrix = glGetUniformLocation(_program, "uMvpMatrix");
  NSAssert(_mvpMatrix != -1, @"Error fetching uniform values for shader.");

  glGenBuffers(1, &_vertex_buffer);
  NSAssert(_vertex_buffer != 0, @"glGenBuffers failed for vertex buffer");
  glBindBuffer(GL_ARRAY_BUFFER, _vertex_buffer);
  glBufferData(GL_ARRAY_BUFFER, sizeof(kVertexData), kVertexData, GL_STATIC_DRAW);

  checkGLError("initialize");

  initialized = YES;
}

- (void)clearGl {
  if (_vertex_buffer) {
    GLuint buffers[] = {_vertex_buffer};
    glDeleteBuffers(1, buffers);
  }
  if (_program) {
    glDeleteProgram(_program);
  }
  initialized = NO;
}

- (void)update:(GVRHeadPose *)headPose {
}

- (void)draw:(GVRHeadPose *)headPose {
  glDisable(GL_DEPTH_TEST);
  glClear(GL_DEPTH_BUFFER_BIT);
  checkGLError("glClear");

  // Configure shader.
  glUseProgram(_program);
  checkGLError("program");

  GLKMatrix4 modelViewMatrix =   headPose.eyeTransform;
  modelViewMatrix = GLKMatrix4Translate(modelViewMatrix, 0, 0, _depth);
  GLKMatrix4 projection_matrix = [headPose projectionMatrixWithNear:0.1f far:100.0f];
  modelViewMatrix = GLKMatrix4Multiply(projection_matrix, modelViewMatrix);

  glUniformMatrix4fv(_mvpMatrix, 1, GL_FALSE, modelViewMatrix.m);
  checkGLError("mvpMatrix");

  // Render quad.
  glBindBuffer(GL_ARRAY_BUFFER, _vertex_buffer);
  glEnableVertexAttribArray(_positionAttrib);
  glVertexAttribPointer(
      _positionAttrib, kCoordsPerVertex, GL_FLOAT, GL_FALSE, kVertexStrideBytes, 0);

  checkGLError("vertex data");

  int numVertices = sizeof(kVertexData) / sizeof(float) / kCoordsPerVertex;
  glDrawArrays(GL_TRIANGLE_STRIP, 0, numVertices);
  checkGLError("glDrawArrays");

  glDisableVertexAttribArray(_positionAttrib);
}

@end
