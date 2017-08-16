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

#import "GVRTextureRenderer.h"

// Constants related to vertex data.
static const NSInteger POSITION_COORDS_PER_VERTEX = 3;
// The vertex contains texture coordinates for both the left & right eyes. If the SCENE is
// rendered in VR, the appropriate part of the vertex would be selected at runtime. For mono
// SCENES, only the left eye's UV coordinates are used.
// For mono MEDIA, the UV coordinates are duplicated in each. For stereo MEDIA, the UV coords
// poNSInteger to the appropriate part of the source media.
static const NSInteger TEXTURE_COORDS_PER_VERTEX = 2 * 2;
static const NSInteger COORDS_PER_VERTEX = POSITION_COORDS_PER_VERTEX + TEXTURE_COORDS_PER_VERTEX;
static const NSInteger VERTEX_STRIDE_BYTES = COORDS_PER_VERTEX * sizeof(float);

// Vertex shader implementation.
static const char *kVertexShaderString = R"(
  #version 100

  uniform mat4 uMvpMatrix;
  attribute vec4 aPosition;
  attribute vec2 aTexCoords;
  varying vec2 vTexCoords;
  void main(void) {
    gl_Position = uMvpMatrix * aPosition;
    vTexCoords = aTexCoords;
  }
)";

// Simple pass-through texture fragment shader.
static const char *kPassThroughFragmentShaderString = R"(

    #ifdef GL_ES
    precision mediump float;
    #endif
    uniform sampler2D uTexture;
    varying vec2 vTexCoords;

    void main(void) {
      gl_FragColor = texture2D(uTexture, vTexCoords);
    }
)";

// Simple pass-through video fragment shader.
static const char *kPassThroughVideoFragmentShaderString = R"(

    #ifdef GL_ES
    precision mediump float;
    #endif
    uniform sampler2D uTextureY;
    uniform sampler2D uTextureUV;
    uniform mat4 uColorConversionMatrix;
    varying vec2 vTexCoords;

    void main(void) {
      float u = vTexCoords.x;
      float v = vTexCoords.y;

      vec3 yuv;
      yuv.x = texture2D(uTextureY, vec2(u, v)).r;
      yuv.yz = texture2D(uTextureUV, vec2(u, v)).rg;
      gl_FragColor = uColorConversionMatrix * vec4(yuv, 1.0);
    }
)";

@implementation GVRTextureRenderer {
  BOOL _initialized;
  BOOL _hidden;
  BOOL _hasTextureId;
  BOOL _isVideoTextureRenderer;
  BOOL _flipTextureVertically;
  BOOL _needsRebindVertexData;
  NSData *_vertexData;
  GLuint _textureId;
  GLuint _yTextureId;
  GLuint _uvTextureId;
  GLKMatrix4 _colorConversionMatrix;

  GLuint _program;
  GLint _positionAttrib;
  GLint _texCoords;
  GLint _mvpMatrix;
  GLint _texture;
  GLint _yTexture;
  GLint _uvTexture;
  GLint _colorMatrix;
  GLuint _vertex_buffer;
}

@synthesize initialized;
@synthesize hidden;

- (instancetype)init {
  if (self = [super init]) {
    _position = GLKMatrix4Identity;
  }
  return self;
}

- (void)setSphericalMeshOfRadius:(CGFloat)radius
                       latitudes:(NSInteger)latitudes
                      longitudes:(NSInteger)longitudes
                     verticalFov:(NSInteger)verticalFov
                   horizontalFov:(NSInteger)horizontalFov
                        meshType:(GVRMeshType)meshType {
  _vertexData = [GVRTextureRenderer makeSphereWithRadius:radius
                                               latitudes:latitudes
                                              longitudes:longitudes
                                             verticalFov:verticalFov
                                           horizontalFov:horizontalFov
                                                meshType:meshType];
  [self computeAabbFromVertexData:_vertexData];
  _needsRebindVertexData = YES;
}

- (void)setQuadMeshOfWidth:(CGFloat)width height:(CGFloat)height meshType:(GVRMeshType)meshType {
  _vertexData = [GVRTextureRenderer makeQuadWithWidth:width height:height meshType:meshType];
  [self computeAabbFromVertexData:_vertexData];
  _needsRebindVertexData = YES;
}

- (void)setIsVideoTextureRenderer:(BOOL)isVideoTextureRenderer {
  _isVideoTextureRenderer = YES;
}

- (void)setFlipTextureVertically:(BOOL)flipTextureVertically {
  _flipTextureVertically = flipTextureVertically;
}

- (void)setImageTextureId:(GLuint)textureId {
  _hasTextureId = YES;
  _textureId = textureId;
}

- (void)setVideoYTextureId:(GLuint)yTextureId
               uvTextureId:(GLuint)uvTextureId
     colorConversionMatrix:(GLKMatrix4)colorConversionMatrix {
  _hasTextureId = YES;
  _yTextureId = yTextureId;
  _uvTextureId = uvTextureId;
  _colorConversionMatrix = colorConversionMatrix;
}

- (void)initializeGl {
  // Load the vertex/fragment shaders.
  const GLuint vertex_shader = loadShader(GL_VERTEX_SHADER, kVertexShaderString);
  NSAssert(vertex_shader != 0, @"Failed to load vertex shader");
  const GLuint fragment_shader =
      loadShader(GL_FRAGMENT_SHADER,
                 _isVideoTextureRenderer ? kPassThroughVideoFragmentShaderString
                                         : kPassThroughFragmentShaderString);
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
  _texCoords = glGetAttribLocation(_program, "aTexCoords");
  NSAssert(_texCoords != -1, @"glGetAttribLocation failed for aTexCoords");
  _mvpMatrix = glGetUniformLocation(_program, "uMvpMatrix");
  if (_isVideoTextureRenderer) {
    _yTexture = glGetUniformLocation(_program, "uTextureY");
    _uvTexture = glGetUniformLocation(_program, "uTextureUV");
    _colorMatrix = glGetUniformLocation(_program, "uColorConversionMatrix");
    NSAssert(_mvpMatrix != -1 && _yTexture != -1 && _uvTexture != -1 && _colorMatrix != -1,
             @"Error fetching uniform values for shader.");
  } else {
    _texture = glGetUniformLocation(_program, "uTexture");
    NSAssert(_mvpMatrix != -1 && _texture != -1, @"Error fetching uniform values for shader.");
  }

  checkGLError("initialize");

  initialized = YES;
}

- (void)clearGl {
  if (_vertex_buffer) {
    GLuint buffers[] = {_vertex_buffer};
    glDeleteBuffers(1, buffers);
    _vertex_buffer = 0;
  }
  if (_program) {
    glDeleteProgram(_program);
    _program = 0;
  }
  if (_hasTextureId) {
    _hasTextureId = NO;
    if (_isVideoTextureRenderer) {
      GLuint textures[] = {_yTextureId, _uvTextureId};
      glDeleteTextures(2, textures);
    } else {
      GLuint textures[] = {_textureId};
      glDeleteTextures(1, textures);
    }
  }
  initialized = NO;
}

- (void)update:(GVRHeadPose *)headPose {
  if (_needsRebindVertexData) {
    _needsRebindVertexData = NO;

    if (_vertex_buffer) {
      GLuint buffers[] = {_vertex_buffer};
      glDeleteBuffers(1, buffers);
      _vertex_buffer = 0;
    }
  }
  if (_vertex_buffer == 0) {
    glGenBuffers(1, &_vertex_buffer);
    NSAssert(_vertex_buffer != 0, @"glGenBuffers failed for vertex buffer");
    glBindBuffer(GL_ARRAY_BUFFER, _vertex_buffer);
    glBufferData(GL_ARRAY_BUFFER, _vertexData.length, _vertexData.bytes, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
  }
}

- (void)draw:(GVRHeadPose *)headPose {
  if (!_hasTextureId) {
    return;
  }

  GLKMatrix4 modelMatrix = _position;
  if (_flipTextureVertically) {
    modelMatrix = GLKMatrix4Scale(modelMatrix, 1, -1, 1);
  }
  GLKMatrix4 viewMatrix = headPose.viewTransform;
  GLKMatrix4 projectionMatrix = [headPose projectionMatrixWithNear:0.1f far:100.0f];

  GLKMatrix4 modelViewProjectionMatrix = GLKMatrix4Multiply(projectionMatrix, viewMatrix);
  modelViewProjectionMatrix = GLKMatrix4Multiply(modelViewProjectionMatrix, modelMatrix);

  // Select our shader.
  glUseProgram(_program);
  checkGLError("glUseProgram");

  glUniformMatrix4fv(_mvpMatrix, 1, GL_FALSE, modelViewProjectionMatrix.m);
  if (_isVideoTextureRenderer) {
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _yTextureId);
    glUniform1i(_yTexture, 0);

    checkGLError("bind video texture 0");

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, _uvTextureId);
    glUniform1i(_uvTexture, 1);

    checkGLError("bind video texture 1");

    glUniformMatrix4fv(_colorMatrix, 1, GL_FALSE, _colorConversionMatrix.m);

    checkGLError("color matrix");
  } else {
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _textureId);
    glUniform1i(_texture, 0);
    checkGLError("bind texture");
  }

  glEnableVertexAttribArray(_positionAttrib);
  glEnableVertexAttribArray(_texCoords);
  checkGLError("enable vertex attribs");

  // Load position data.
  glBindBuffer(GL_ARRAY_BUFFER, _vertex_buffer);
  glVertexAttribPointer(
      _positionAttrib, POSITION_COORDS_PER_VERTEX, GL_FLOAT, GL_FALSE, VERTEX_STRIDE_BYTES, 0);
  checkGLError("vertex position");

  // Load texture data.
  int textureOffset =
      (headPose.eye == kGVRRightEye) ? POSITION_COORDS_PER_VERTEX + 2 : POSITION_COORDS_PER_VERTEX;
  glVertexAttribPointer(_texCoords,
                        TEXTURE_COORDS_PER_VERTEX,
                        GL_FLOAT,
                        GL_FALSE,
                        VERTEX_STRIDE_BYTES,
                        (void *)(textureOffset * sizeof(float)));
  checkGLError("texture offset");

  // Render.
  GLsizei numVertices = (GLsizei)(_vertexData.length / sizeof(float)) / COORDS_PER_VERTEX;
  glDrawArrays(GL_TRIANGLE_STRIP, 0, numVertices);
  checkGLError("glDrawArrays");

  // Clear state.
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
  glDisableVertexAttribArray(_positionAttrib);
  glDisableVertexAttribArray(_texCoords);
  checkGLError("done drawing");
}

#pragma mark - Private

- (void)computeAabbFromVertexData:(NSData *)vertexData {
  for (int i = 0; i < vertexData.length; i = i + (sizeof(float) * COORDS_PER_VERTEX)) {
    float *pos = (float *)vertexData.bytes + i / sizeof(float);
    GLKVector3 v = GLKVector3Make(*(pos), *(pos + 1), *(pos + 2));
    _aabbMin = GLKVector3Minimum(_aabbMin, v);
    _aabbMax = GLKVector3Maximum(_aabbMax, v);
  }
}

+ (NSData *)makeSphereWithRadius:(CGFloat)radius
                       latitudes:(NSInteger)latitudes
                      longitudes:(NSInteger)longitudes
                     verticalFov:(NSInteger)verticalFov
                   horizontalFov:(NSInteger)horizontalFov
                        meshType:(GVRMeshType)meshType {
  // Compute angular size of each UV quad.
  float verticalFovRads = GLKMathDegreesToRadians(verticalFov);
  float horizontalFovRads = GLKMathDegreesToRadians(horizontalFov);
  float quadHeightRads = verticalFovRads / latitudes;
  float quadWidthRads = horizontalFovRads / longitudes;
  NSInteger vertexCount = (2 * (longitudes + 1) + 2) * latitudes;

  NSInteger CPV = COORDS_PER_VERTEX;
  float vertexData[vertexCount * CPV];

  // Generate the data for the sphere which is a set of triangle strips representing each
  // latitude band.
  NSInteger v = 0;  // Index into the vertex array.
  // (i, j) represents a quad in the equirectangular sphere.
  for (NSInteger j = 0; j < latitudes; ++j) {
    // Each latitude band lies between the two phi values. Each vertical edge on a band lies on
    // a theta value.
    float phiLow = (quadHeightRads * j - verticalFovRads / 2.0f);
    float phiHigh = (quadHeightRads * (j + 1) - verticalFovRads / 2.0f);
    for (NSInteger i = 0; i < longitudes + 1; ++i) {  // For each vertical edge in the band.
      for (NSInteger k = 0; k < 2; ++k) {             // For low and high points on an edge.
        // For each point, determine it's angular position.
        float phi = (k == 0) ? phiLow : phiHigh;
        float theta = quadWidthRads * i + (float)M_PI - horizontalFovRads / 2.0f;

        // Set vertex position data.
        vertexData[CPV * v + 0] = -(float)(radius * sin(theta) * cos(phi));
        vertexData[CPV * v + 1] = (float)(radius * sin(phi));
        vertexData[CPV * v + 2] = (float)(radius * cos(theta) * cos(phi));

        // Set vertex texture.x data.
        if (meshType == kGVRMeshTypeStereoLeftRight) {
          vertexData[CPV * v + 3] = (i * quadWidthRads / horizontalFovRads) / 2.0f;
          vertexData[CPV * v + 5] = (i * quadWidthRads / horizontalFovRads) / 2.0f + .5f;
        } else {
          vertexData[CPV * v + 3] = i * quadWidthRads / horizontalFovRads;
          vertexData[CPV * v + 5] = i * quadWidthRads / horizontalFovRads;
        }

        // Set vertex texture.y data. The "1 - ..." is due to Canvas vs GL coords.
        if (meshType == kGVRMeshTypeStereoTopBottom) {
          vertexData[CPV * v + 4] = 1 - (((j + k) * quadHeightRads / verticalFovRads) / 2.0f + .5f);
          vertexData[CPV * v + 6] = 1 - ((j + k) * quadHeightRads / verticalFovRads) / 2.0f;
        } else {
          vertexData[CPV * v + 4] = 1 - (j + k) * quadHeightRads / verticalFovRads;
          vertexData[CPV * v + 6] = 1 - (j + k) * quadHeightRads / verticalFovRads;
        }
        v++;

        // Break up the triangle strip using degenerate vertices by copying first and last points.
        if ((i == 0 && k == 0) || (i == longitudes && k == 1)) {
          // System.arraycopy(vertexData, CPV * (v - 1), vertexData, CPV * v, CPV);
          memcpy(vertexData + (CPV * v), vertexData + (CPV * (v - 1)), CPV * sizeof(float));
          v++;
        }
      }
      // Move on to the next vertical edge in the triangle strip.
    }
    // Move on to the next triangle strip.
  }

  return [NSData dataWithBytes:vertexData length:sizeof(vertexData)];
}

+ (NSData *)makeQuadWithWidth:(CGFloat)width height:(CGFloat)height meshType:(GVRMeshType)meshType {
  NSData *data = nil;
  float w = (float)width;
  float h = (float)height;

  switch (meshType) {
    case kGVRMeshTypeStereoLeftRight: {
      float vertices[] = {-w / 2, -h / 2, 0, 0, 1, .5f, 1, w, -h / 2, 0, .5f, 1, 1, 1,
                          -w / 2, h,      0, 0, 0, .5f, 0, w, h,      0, .5f, 0, 1, 0};
      data = [NSData dataWithBytes:vertices length:sizeof(vertices)];
    } break;

    case kGVRMeshTypeStereoTopBottom: {
      float vertices[] = {-w / 2, -h / 2, 0, 0, .5f, 0, 1,   w, -h / 2, 0, 1, .5f, 1, 1,
                          -w / 2, h,      0, 0, 0,   0, .5f, w, h,      0, 1, 0,   1, .5f};
      data = [NSData dataWithBytes:vertices length:sizeof(vertices)];
    } break;

    case kGVRMeshTypeMonoscopic:
    default: {
      float vertices[] = {-w / 2, -h / 2, 0, 0, 1, 0, 1, w, -h / 2, 0, 1, 1, 1, 1,
                          -w / 2, h,      0, 0, 0, 0, 0, w, h,      0, 1, 0, 1, 0};
      data = [NSData dataWithBytes:vertices length:sizeof(vertices)];
    } break;
  }
  return data;
}

@end
