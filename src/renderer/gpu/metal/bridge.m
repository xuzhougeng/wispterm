#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define PHANTTY_METAL_MAX_BUFFERS 4096
#define PHANTTY_METAL_MAX_TEXTURES 4096
#define PHANTTY_METAL_MAX_PIPELINES 1024

#define PHANTTY_GL_RED 0x1903
#define PHANTTY_GL_RGBA 0x1908
#define PHANTTY_GL_BGRA 0x80E1
#define PHANTTY_GL_UNSIGNED_BYTE 0x1401
#define PHANTTY_GL_TRIANGLES 0x0004
#define PHANTTY_GL_TRIANGLE_STRIP 0x0005

typedef struct PhanttyMetalContext {
    void *device;
    void *command_queue;
    void *layer;
    void *drawable;
    void *command_buffer;
    void *encoder;
} PhanttyMetalContext;

typedef struct PhanttyMetalBufferSlot {
    id<MTLBuffer> buffer;
    unsigned int target;
} PhanttyMetalBufferSlot;

// These registries are _Thread_local: each AppWindow runs its render loop on
// its own worker thread and the zig-side GPU handles (ui_pipeline, cell
// pipelines, font atlas, …) are likewise threadlocal. Keeping the slot tables
// and handle counters per-thread gives every window an independent handle
// namespace, so two windows rendering concurrently can't clobber each other's
// buffers/textures/pipelines or the active-texture binding. (Process-global
// here was the multi-window "one window renders incomplete" bug.)
static _Thread_local PhanttyMetalBufferSlot phantty_metal_buffers[PHANTTY_METAL_MAX_BUFFERS];
static _Thread_local unsigned int phantty_metal_next_buffer = 1;

typedef struct PhanttyMetalTextureSlot {
    id<MTLTexture> texture;
    unsigned int wrap;   // 0 = clamp-to-edge, 1 = repeat
    unsigned int filter; // 0 = nearest, 1 = linear
    size_t width;
    size_t height;
    size_t bpp;
} PhanttyMetalTextureSlot;

static _Thread_local PhanttyMetalTextureSlot phantty_metal_textures[PHANTTY_METAL_MAX_TEXTURES];
static _Thread_local unsigned int phantty_metal_next_texture = 1;

typedef struct PhanttyMetalPipelineSlot {
    // Metal bakes blend into the pipeline state, so each logical pipeline keeps
    // one PSO per blend mode and the encoder picks by the current blend state.
    // `pipeline` is the straight-alpha default (the `!= nil` validity check).
    id<MTLRenderPipelineState> pipeline;          // alpha: (src_alpha, 1-src_alpha)
    id<MTLRenderPipelineState> pipeline_premult;  // premultiplied: (one, 1-src_alpha)
    id<MTLRenderPipelineState> pipeline_opaque;   // blending disabled
    unsigned int vao;
    struct {
        float projection[16];
        float text_color[4];
        float overlay_color[4];
        float cell_size_grid_offset[4];
        float scalars[4];
    } uniforms;
} PhanttyMetalPipelineSlot;

static _Thread_local PhanttyMetalPipelineSlot phantty_metal_pipelines[PHANTTY_METAL_MAX_PIPELINES];
static _Thread_local unsigned int phantty_metal_next_pipeline = 1;
static _Thread_local unsigned int phantty_metal_active_textures[16];

// Encoder render state recorded by the Zig render_state layer (GL lower-left
// convention) and applied on the active encoder before each draw. The drawable
// size is captured at frame begin so we can flip y to Metal's upper-left origin.
static _Thread_local int phantty_metal_vp_x = 0;
static _Thread_local int phantty_metal_vp_y = 0;
static _Thread_local int phantty_metal_vp_w = 0;
static _Thread_local int phantty_metal_vp_h = 0;
static _Thread_local bool phantty_metal_vp_set = false;
static _Thread_local bool phantty_metal_scissor_enabled = false;
static _Thread_local int phantty_metal_sc_x = 0;
static _Thread_local int phantty_metal_sc_y = 0;
static _Thread_local int phantty_metal_sc_w = 0;
static _Thread_local int phantty_metal_sc_h = 0;
static _Thread_local int phantty_metal_drawable_w = 0;
static _Thread_local int phantty_metal_drawable_h = 0;

void phantty_metal_set_viewport(int x, int y, int w, int h) {
    phantty_metal_vp_x = x;
    phantty_metal_vp_y = y;
    phantty_metal_vp_w = w;
    phantty_metal_vp_h = h;
    phantty_metal_vp_set = true;
}

void phantty_metal_set_scissor(bool enabled, int x, int y, int w, int h) {
    phantty_metal_scissor_enabled = enabled;
    phantty_metal_sc_x = x;
    phantty_metal_sc_y = y;
    phantty_metal_sc_w = w;
    phantty_metal_sc_h = h;
}

// Blend state recorded by the Zig render_state layer. Metal can't change blend
// on the encoder (it is fixed in the PSO), so encode_draw selects the matching
// per-mode PSO instead.
static _Thread_local bool phantty_metal_blend_enabled = true;
static _Thread_local bool phantty_metal_blend_premult = false;

void phantty_metal_set_blend_enabled(bool enabled) {
    phantty_metal_blend_enabled = enabled;
}

void phantty_metal_set_blend_mode(int premultiplied) {
    phantty_metal_blend_premult = (premultiplied != 0);
}

// Lazily-built MTLSamplerState cache, indexed by (filter, wrap). Replaces the
// per-shader `constexpr sampler` so a texture's configured filter/wrap (e.g.
// nearest for pixel-exact bitmaps) actually applies, mirroring the GL backend's
// sampler parameters. Threadlocal to match the per-render-thread registries.
static _Thread_local id<MTLSamplerState> phantty_metal_samplers[4]; // idx = filter*2 + wrap

static id<MTLSamplerState> phantty_metal_sampler_for(id<MTLDevice> device, unsigned int filter, unsigned int wrap) {
    if (device == nil) return nil;
    const unsigned int idx = (filter ? 2u : 0u) + (wrap ? 1u : 0u);
    if (phantty_metal_samplers[idx] == nil) {
        MTLSamplerDescriptor *desc = [[MTLSamplerDescriptor alloc] init];
        const MTLSamplerMinMagFilter f = filter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        desc.minFilter = f;
        desc.magFilter = f;
        const MTLSamplerAddressMode mode = wrap ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        desc.sAddressMode = mode;
        desc.tAddressMode = mode;
        phantty_metal_samplers[idx] = [device newSamplerStateWithDescriptor:desc];
        [desc release];
    }
    return phantty_metal_samplers[idx];
}

// Apply the recorded viewport + scissor to the encoder before a draw. Without a
// per-pane viewport every split pane drew at the window origin; without scissor
// the markdown preview / file explorer clip regions had no effect. Both convert
// GL lower-left → Metal upper-left; the scissor is clamped to the drawable
// because an out-of-bounds MTLScissorRect raises and kills the command buffer.
static void phantty_metal_apply_viewport_scissor(id<MTLRenderCommandEncoder> encoder) {
    int dw = phantty_metal_drawable_w;
    int dh = phantty_metal_drawable_h;
    if (dw <= 0 || dh <= 0) return; // drawable size unknown — keep encoder defaults

    int vx, vy, vw, vh;
    if (phantty_metal_vp_set && phantty_metal_vp_w > 0 && phantty_metal_vp_h > 0) {
        vx = phantty_metal_vp_x;
        vw = phantty_metal_vp_w;
        vh = phantty_metal_vp_h;
        vy = dh - phantty_metal_vp_y - phantty_metal_vp_h;
    } else {
        vx = 0; vy = 0; vw = dw; vh = dh;
    }
    [encoder setViewport:(MTLViewport){ (double)vx, (double)vy, (double)vw, (double)vh, 0.0, 1.0 }];

    int sx, sy, sw, sh;
    if (phantty_metal_scissor_enabled) {
        sx = phantty_metal_sc_x;
        sw = phantty_metal_sc_w;
        sh = phantty_metal_sc_h;
        sy = dh - phantty_metal_sc_y - phantty_metal_sc_h;
    } else {
        sx = 0; sy = 0; sw = dw; sh = dh; // Metal has no scissor-off; reset to full
    }
    if (sx < 0) { sw += sx; sx = 0; }
    if (sy < 0) { sh += sy; sy = 0; }
    if (sx > dw) sx = dw;
    if (sy > dh) sy = dh;
    if (sw < 0) sw = 0;
    if (sh < 0) sh = 0;
    if (sx + sw > dw) sw = dw - sx;
    if (sy + sh > dh) sh = dh - sy;
    [encoder setScissorRect:(MTLScissorRect){ (NSUInteger)sx, (NSUInteger)sy, (NSUInteger)sw, (NSUInteger)sh }];
}

static void phantty_metal_set_error(char *error_buf, size_t error_buf_len, const char *message) {
    if (error_buf == NULL || error_buf_len == 0) return;
    snprintf(error_buf, error_buf_len, "%s", message);
}

bool phantty_metal_frame_begin(
    PhanttyMetalContext *ctx,
    float r,
    float g,
    float b,
    float a,
    char *error_buf,
    size_t error_buf_len
);
bool phantty_metal_frame_end(PhanttyMetalContext *ctx, char *error_buf, size_t error_buf_len);

static bool phantty_metal_buffer_valid(unsigned int handle) {
    return handle > 0 && handle < PHANTTY_METAL_MAX_BUFFERS;
}

static id<MTLBuffer> phantty_metal_buffer_object(unsigned int handle) {
    if (!phantty_metal_buffer_valid(handle)) return nil;
    return phantty_metal_buffers[handle].buffer;
}

static id<MTLBuffer> phantty_metal_new_buffer(void *device_handle, const void *bytes, size_t len) {
    id<MTLDevice> device = (id<MTLDevice>)device_handle;
    if (device == nil || len == 0) return nil;

    if (bytes != NULL) {
        return [device newBufferWithBytes:bytes length:len options:MTLResourceStorageModeShared];
    }
    return [device newBufferWithLength:len options:MTLResourceStorageModeShared];
}

static bool phantty_metal_texture_valid(unsigned int handle) {
    return handle > 0 && handle < PHANTTY_METAL_MAX_TEXTURES;
}

static id<MTLTexture> phantty_metal_texture_object(unsigned int handle) {
    if (!phantty_metal_texture_valid(handle)) return nil;
    return phantty_metal_textures[handle].texture;
}

static bool phantty_metal_pipeline_valid(unsigned int handle) {
    return handle > 0 && handle < PHANTTY_METAL_MAX_PIPELINES;
}

static MTLPrimitiveType phantty_metal_primitive_type(unsigned int mode) {
    switch (mode) {
        case PHANTTY_GL_TRIANGLE_STRIP:
            return MTLPrimitiveTypeTriangleStrip;
        case PHANTTY_GL_TRIANGLES:
        default:
            return MTLPrimitiveTypeTriangle;
    }
}

static void phantty_metal_pipeline_init_uniforms(PhanttyMetalPipelineSlot *slot) {
    memset(&slot->uniforms, 0, sizeof(slot->uniforms));
    slot->uniforms.projection[0] = 1.0f;
    slot->uniforms.projection[5] = 1.0f;
    slot->uniforms.projection[10] = 1.0f;
    slot->uniforms.projection[15] = 1.0f;
    slot->uniforms.text_color[0] = 1.0f;
    slot->uniforms.text_color[1] = 1.0f;
    slot->uniforms.text_color[2] = 1.0f;
    slot->uniforms.text_color[3] = 1.0f;
    slot->uniforms.overlay_color[3] = 1.0f;
    slot->uniforms.scalars[1] = 1.0f; // opacity
}

static MTLPixelFormat phantty_metal_texture_pixel_format(unsigned int format) {
    switch (format) {
        case PHANTTY_GL_RED:
            return MTLPixelFormatR8Unorm;
        case PHANTTY_GL_BGRA:
            return MTLPixelFormatBGRA8Unorm;
        case PHANTTY_GL_RGBA:
        default:
            return MTLPixelFormatRGBA8Unorm;
    }
}

static size_t phantty_metal_texture_bpp(unsigned int format) {
    switch (format) {
        case PHANTTY_GL_RED:
            return 1;
        case PHANTTY_GL_BGRA:
        case PHANTTY_GL_RGBA:
        default:
            return 4;
    }
}

bool phantty_metal_context_init(void *layer, PhanttyMetalContext *out, char *error_buf, size_t error_buf_len) {
    if (out == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing output context");
        return false;
    }

    out->device = NULL;
    out->command_queue = NULL;
    out->layer = NULL;
    out->drawable = NULL;
    out->command_buffer = NULL;
    out->encoder = NULL;

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            phantty_metal_set_error(error_buf, error_buf_len, "MTLCreateSystemDefaultDevice returned nil");
            return false;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (queue == nil) {
            [device release];
            phantty_metal_set_error(error_buf, error_buf_len, "newCommandQueue returned nil");
            return false;
        }

        CAMetalLayer *metal_layer = nil;
        if (layer != NULL) {
            metal_layer = (CAMetalLayer *)layer;
        } else {
            metal_layer = [CAMetalLayer layer];
        }
        if (metal_layer == nil) {
            [queue release];
            [device release];
            phantty_metal_set_error(error_buf, error_buf_len, "CAMetalLayer allocation returned nil");
            return false;
        }

        [metal_layer retain];
        metal_layer.device = device;
        metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metal_layer.framebufferOnly = YES;
        metal_layer.opaque = YES;
        metal_layer.contentsScale = 1.0;
        metal_layer.drawableSize = CGSizeMake(64.0, 64.0);

        out->device = device;
        out->command_queue = queue;
        out->layer = metal_layer;
        out->drawable = NULL;
        out->command_buffer = NULL;
        out->encoder = NULL;
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }
}

void phantty_metal_context_deinit(PhanttyMetalContext *ctx) {
    if (ctx == NULL) return;

    @autoreleasepool {
        char ignored[1] = {0};
        (void)phantty_metal_frame_end(ctx, ignored, sizeof(ignored));
        if (ctx->layer != NULL) {
            [(id)ctx->layer release];
            ctx->layer = NULL;
        }
        if (ctx->command_queue != NULL) {
            [(id)ctx->command_queue release];
            ctx->command_queue = NULL;
        }
        if (ctx->device != NULL) {
            [(id)ctx->device release];
            ctx->device = NULL;
        }
    }
}

bool phantty_metal_context_is_usable(const PhanttyMetalContext *ctx) {
    return ctx != NULL && ctx->device != NULL && ctx->command_queue != NULL && ctx->layer != NULL;
}

unsigned int phantty_metal_buffer_create(unsigned int target) {
    for (unsigned int i = 0; i < PHANTTY_METAL_MAX_BUFFERS - 1; i++) {
        unsigned int handle = phantty_metal_next_buffer++;
        if (phantty_metal_next_buffer >= PHANTTY_METAL_MAX_BUFFERS) {
            phantty_metal_next_buffer = 1;
        }
        if (phantty_metal_buffers[handle].target == 0 && phantty_metal_buffers[handle].buffer == nil) {
            phantty_metal_buffers[handle].target = target;
            return handle;
        }
    }
    return 0;
}

bool phantty_metal_buffer_allocate(unsigned int handle, void *device_handle, size_t len, char *error_buf, size_t error_buf_len) {
    if (!phantty_metal_buffer_valid(handle)) {
        phantty_metal_set_error(error_buf, error_buf_len, "invalid Metal buffer handle");
        return false;
    }
    if (len == 0) {
        phantty_metal_set_error(error_buf, error_buf_len, "cannot allocate zero-length Metal buffer");
        return false;
    }

    @autoreleasepool {
        id<MTLBuffer> buffer = phantty_metal_new_buffer(device_handle, NULL, len);
        if (buffer == nil) {
            phantty_metal_set_error(error_buf, error_buf_len, "newBufferWithLength returned nil");
            return false;
        }

        if (phantty_metal_buffers[handle].buffer != nil) {
            [phantty_metal_buffers[handle].buffer release];
        }
        phantty_metal_buffers[handle].buffer = buffer;
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }
}

bool phantty_metal_buffer_upload_data(unsigned int handle, void *device_handle, const void *bytes, size_t len, char *error_buf, size_t error_buf_len) {
    if (!phantty_metal_buffer_valid(handle)) {
        phantty_metal_set_error(error_buf, error_buf_len, "invalid Metal buffer handle");
        return false;
    }
    if (bytes == NULL && len > 0) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing Metal buffer upload bytes");
        return false;
    }
    if (len == 0) {
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }

    @autoreleasepool {
        id<MTLBuffer> buffer = phantty_metal_new_buffer(device_handle, bytes, len);
        if (buffer == nil) {
            phantty_metal_set_error(error_buf, error_buf_len, "newBufferWithBytes returned nil");
            return false;
        }

        if (phantty_metal_buffers[handle].buffer != nil) {
            [phantty_metal_buffers[handle].buffer release];
        }
        phantty_metal_buffers[handle].buffer = buffer;
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }
}

bool phantty_metal_buffer_upload(unsigned int handle, void *device_handle, const void *bytes, size_t len, char *error_buf, size_t error_buf_len) {
    if (!phantty_metal_buffer_valid(handle)) {
        phantty_metal_set_error(error_buf, error_buf_len, "invalid Metal buffer handle");
        return false;
    }
    if (bytes == NULL && len > 0) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing Metal buffer update bytes");
        return false;
    }
    if (len == 0) {
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }

    // IMPORTANT: every upload allocates a fresh MTLBuffer. Reusing the same
    // backing storage (via memcpy) is unsafe under Metal's deferred-execution
    // model: setVertexBuffer:offset:atIndex: stores a pointer that's only read
    // when the command buffer commits, so multiple "upload + drawArrays" pairs
    // sharing a single MTLBuffer all end up reading the *last* upload — every
    // overlay/quad gets stamped at the same coordinates. The previous buffer
    // is released here; Metal keeps it alive via the encoder's retain until
    // commit completes, then deallocates asynchronously. The per-call alloc
    // cost is negligible for the small vertex blobs ui_pipeline uses (~96B/quad).
    @autoreleasepool {
        id<MTLBuffer> old_buffer = phantty_metal_buffers[handle].buffer;
        id<MTLBuffer> new_buffer = phantty_metal_new_buffer(device_handle, bytes, len);
        if (new_buffer == nil) {
            phantty_metal_set_error(error_buf, error_buf_len, "newBufferWithBytes returned nil");
            return false;
        }
        phantty_metal_buffers[handle].buffer = new_buffer;
        if (old_buffer != nil) [old_buffer release];
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }
}

size_t phantty_metal_buffer_length(unsigned int handle) {
    if (!phantty_metal_buffer_valid(handle)) return 0;
    id<MTLBuffer> buffer = phantty_metal_buffers[handle].buffer;
    if (buffer == nil) return 0;
    return [buffer length];
}

void phantty_metal_buffer_destroy(unsigned int handle) {
    if (!phantty_metal_buffer_valid(handle)) return;

    @autoreleasepool {
        if (phantty_metal_buffers[handle].buffer != nil) {
            [phantty_metal_buffers[handle].buffer release];
        }
        phantty_metal_buffers[handle].buffer = nil;
        phantty_metal_buffers[handle].target = 0;
    }
}

unsigned int phantty_metal_texture_create(void) {
    for (unsigned int i = 0; i < PHANTTY_METAL_MAX_TEXTURES - 1; i++) {
        unsigned int handle = phantty_metal_next_texture++;
        if (phantty_metal_next_texture >= PHANTTY_METAL_MAX_TEXTURES) {
            phantty_metal_next_texture = 1;
        }
        if (phantty_metal_textures[handle].texture == nil) {
            return handle;
        }
    }
    return 0;
}

bool phantty_metal_texture_upload_2d(
    unsigned int handle,
    void *device_handle,
    int width,
    int height,
    const void *data,
    unsigned int format,
    unsigned int data_type,
    unsigned int wrap,
    unsigned int filter,
    char *error_buf,
    size_t error_buf_len
) {
    if (!phantty_metal_texture_valid(handle)) {
        phantty_metal_set_error(error_buf, error_buf_len, "invalid Metal texture handle");
        return false;
    }
    if (device_handle == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing Metal device for texture upload");
        return false;
    }
    if (width <= 0 || height <= 0) {
        phantty_metal_set_error(error_buf, error_buf_len, "invalid Metal texture dimensions");
        return false;
    }
    if (data_type != PHANTTY_GL_UNSIGNED_BYTE) {
        phantty_metal_set_error(error_buf, error_buf_len, "unsupported Metal texture data type");
        return false;
    }

    @autoreleasepool {
        id<MTLDevice> device = (id<MTLDevice>)device_handle;
        MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
        desc.textureType = MTLTextureType2D;
        desc.pixelFormat = phantty_metal_texture_pixel_format(format);
        desc.width = (NSUInteger)width;
        desc.height = (NSUInteger)height;
        desc.mipmapLevelCount = 1;
        desc.storageMode = MTLStorageModeShared;
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

        id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
        [desc release];
        if (texture == nil) {
            phantty_metal_set_error(error_buf, error_buf_len, "newTextureWithDescriptor returned nil");
            return false;
        }

        const size_t bpp = phantty_metal_texture_bpp(format);
        if (data != NULL) {
            MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height);
            [texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:bpp * (size_t)width];
        }

        if (phantty_metal_textures[handle].texture != nil) {
            [phantty_metal_textures[handle].texture release];
        }
        phantty_metal_textures[handle].texture = texture;
        phantty_metal_textures[handle].wrap = wrap;
        phantty_metal_textures[handle].filter = filter;
        phantty_metal_textures[handle].width = (size_t)width;
        phantty_metal_textures[handle].height = (size_t)height;
        phantty_metal_textures[handle].bpp = bpp;
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }
}

bool phantty_metal_texture_sub_image_2d(
    unsigned int handle,
    int x,
    int y,
    int width,
    int height,
    const void *data,
    unsigned int format,
    unsigned int data_type,
    char *error_buf,
    size_t error_buf_len
) {
    if (!phantty_metal_texture_valid(handle) || phantty_metal_textures[handle].texture == nil) {
        phantty_metal_set_error(error_buf, error_buf_len, "invalid Metal texture handle");
        return false;
    }
    if (data == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing Metal texture sub-image bytes");
        return false;
    }
    if (x < 0 || y < 0 || width <= 0 || height <= 0) {
        phantty_metal_set_error(error_buf, error_buf_len, "invalid Metal texture sub-image dimensions");
        return false;
    }
    if (data_type != PHANTTY_GL_UNSIGNED_BYTE) {
        phantty_metal_set_error(error_buf, error_buf_len, "unsupported Metal texture data type");
        return false;
    }

    @autoreleasepool {
        id<MTLTexture> texture = phantty_metal_textures[handle].texture;
        const size_t bpp = phantty_metal_texture_bpp(format);
        MTLRegion region = MTLRegionMake2D((NSUInteger)x, (NSUInteger)y, (NSUInteger)width, (NSUInteger)height);
        [texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:bpp * (size_t)width];
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }
}

void phantty_metal_texture_set_wrap(unsigned int handle, unsigned int wrap) {
    if (!phantty_metal_texture_valid(handle)) return;
    phantty_metal_textures[handle].wrap = wrap;
}

void phantty_metal_texture_bind(unsigned int handle, unsigned int unit) {
    if (unit >= 16) return;
    phantty_metal_active_textures[unit] = handle;
}

int phantty_metal_texture_level_width(unsigned int handle) {
    if (!phantty_metal_texture_valid(handle)) return 0;
    return (int)phantty_metal_textures[handle].width;
}

void phantty_metal_texture_destroy(unsigned int handle) {
    if (!phantty_metal_texture_valid(handle)) return;

    @autoreleasepool {
        if (phantty_metal_textures[handle].texture != nil) {
            [phantty_metal_textures[handle].texture release];
        }
        phantty_metal_textures[handle].texture = nil;
        phantty_metal_textures[handle].wrap = 0;
        phantty_metal_textures[handle].width = 0;
        phantty_metal_textures[handle].height = 0;
        phantty_metal_textures[handle].bpp = 0;
    }
}

// Build one MTLRenderPipelineState for a given blend mode. Metal fixes blend in
// the pipeline state, so Phantty mirrors the OpenGL backend's mutable
// glBlendFunc by pre-building a PSO per mode; encode_draw selects by the
// recorded blend state.
static id<MTLRenderPipelineState> phantty_metal_make_pso(
    id<MTLDevice> device,
    id<MTLFunction> vertex_fn,
    id<MTLFunction> fragment_fn,
    bool blend_enabled,
    bool premultiplied,
    NSError **error
) {
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertex_fn;
    desc.fragmentFunction = fragment_fn;
    MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
    color.pixelFormat = MTLPixelFormatBGRA8Unorm;
    if (blend_enabled) {
        MTLBlendFactor src = premultiplied ? MTLBlendFactorOne : MTLBlendFactorSourceAlpha;
        color.blendingEnabled = YES;
        color.rgbBlendOperation = MTLBlendOperationAdd;
        color.alphaBlendOperation = MTLBlendOperationAdd;
        color.sourceRGBBlendFactor = src;
        color.sourceAlphaBlendFactor = src;
        color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    } else {
        color.blendingEnabled = NO;
    }
    id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:desc error:error];
    [desc release];
    return pso;
}

unsigned int phantty_metal_pipeline_create(
    void *device_handle,
    const char *vertex_source,
    const char *fragment_source,
    unsigned int vao,
    char *error_buf,
    size_t error_buf_len
) {
    if (device_handle == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing Metal device for pipeline");
        return 0;
    }
    if (vertex_source == NULL || fragment_source == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing MSL source");
        return 0;
    }

    @autoreleasepool {
        id<MTLDevice> device = (id<MTLDevice>)device_handle;
        NSString *source = [NSString stringWithFormat:@"%s\n%s", vertex_source, fragment_source];
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (library == nil) {
            const char *message = error != nil ? [[error localizedDescription] UTF8String] : "newLibraryWithSource returned nil";
            phantty_metal_set_error(error_buf, error_buf_len, message);
            return 0;
        }

        id<MTLFunction> vertex_fn = [library newFunctionWithName:@"vertex_main"];
        id<MTLFunction> fragment_fn = [library newFunctionWithName:@"fragment_main"];
        if (vertex_fn == nil || fragment_fn == nil) {
            if (vertex_fn != nil) [vertex_fn release];
            if (fragment_fn != nil) [fragment_fn release];
            [library release];
            phantty_metal_set_error(error_buf, error_buf_len, "MSL must export vertex_main and fragment_main");
            return 0;
        }

        error = nil;
        id<MTLRenderPipelineState> pipeline = phantty_metal_make_pso(device, vertex_fn, fragment_fn, true, false, &error);
        id<MTLRenderPipelineState> pipeline_premult = (pipeline != nil)
            ? phantty_metal_make_pso(device, vertex_fn, fragment_fn, true, true, &error) : nil;
        id<MTLRenderPipelineState> pipeline_opaque = (pipeline_premult != nil)
            ? phantty_metal_make_pso(device, vertex_fn, fragment_fn, false, false, &error) : nil;

        [vertex_fn release];
        [fragment_fn release];
        [library release];

        if (pipeline == nil || pipeline_premult == nil || pipeline_opaque == nil) {
            if (pipeline != nil) [pipeline release];
            if (pipeline_premult != nil) [pipeline_premult release];
            if (pipeline_opaque != nil) [pipeline_opaque release];
            const char *message = error != nil ? [[error localizedDescription] UTF8String] : "newRenderPipelineStateWithDescriptor returned nil";
            phantty_metal_set_error(error_buf, error_buf_len, message);
            return 0;
        }

        for (unsigned int i = 0; i < PHANTTY_METAL_MAX_PIPELINES - 1; i++) {
            unsigned int handle = phantty_metal_next_pipeline++;
            if (phantty_metal_next_pipeline >= PHANTTY_METAL_MAX_PIPELINES) {
                phantty_metal_next_pipeline = 1;
            }
            if (phantty_metal_pipelines[handle].pipeline == nil) {
                phantty_metal_pipelines[handle].pipeline = pipeline;
                phantty_metal_pipelines[handle].pipeline_premult = pipeline_premult;
                phantty_metal_pipelines[handle].pipeline_opaque = pipeline_opaque;
                phantty_metal_pipelines[handle].vao = vao;
                phantty_metal_pipeline_init_uniforms(&phantty_metal_pipelines[handle]);
                phantty_metal_set_error(error_buf, error_buf_len, "");
                return handle;
            }
        }

        [pipeline release];
        [pipeline_premult release];
        [pipeline_opaque release];
        phantty_metal_set_error(error_buf, error_buf_len, "Metal pipeline registry is full");
        return 0;
    }
}

void phantty_metal_pipeline_destroy(unsigned int handle) {
    if (!phantty_metal_pipeline_valid(handle)) return;

    @autoreleasepool {
        if (phantty_metal_pipelines[handle].pipeline != nil) {
            [phantty_metal_pipelines[handle].pipeline release];
        }
        if (phantty_metal_pipelines[handle].pipeline_premult != nil) {
            [phantty_metal_pipelines[handle].pipeline_premult release];
        }
        if (phantty_metal_pipelines[handle].pipeline_opaque != nil) {
            [phantty_metal_pipelines[handle].pipeline_opaque release];
        }
        phantty_metal_pipelines[handle].pipeline = nil;
        phantty_metal_pipelines[handle].pipeline_premult = nil;
        phantty_metal_pipelines[handle].pipeline_opaque = nil;
        phantty_metal_pipelines[handle].vao = 0;
        phantty_metal_pipeline_init_uniforms(&phantty_metal_pipelines[handle]);
    }
}

void phantty_metal_pipeline_set_float(unsigned int handle, const char *name, float value) {
    if (!phantty_metal_pipeline_valid(handle) || name == NULL) return;
    PhanttyMetalPipelineSlot *slot = &phantty_metal_pipelines[handle];
    if (strcmp(name, "windowHeight") == 0) {
        slot->uniforms.scalars[0] = value;
    } else if (strcmp(name, "opacity") == 0) {
        slot->uniforms.scalars[1] = value;
    }
}

void phantty_metal_pipeline_set_int(unsigned int handle, const char *name, int value) {
    (void)handle;
    (void)name;
    (void)value;
}

void phantty_metal_pipeline_set_vec2(unsigned int handle, const char *name, float x, float y) {
    if (!phantty_metal_pipeline_valid(handle) || name == NULL) return;
    PhanttyMetalPipelineSlot *slot = &phantty_metal_pipelines[handle];
    if (strcmp(name, "cellSize") == 0) {
        slot->uniforms.cell_size_grid_offset[0] = x;
        slot->uniforms.cell_size_grid_offset[1] = y;
    } else if (strcmp(name, "gridOffset") == 0) {
        slot->uniforms.cell_size_grid_offset[2] = x;
        slot->uniforms.cell_size_grid_offset[3] = y;
    }
}

void phantty_metal_pipeline_set_vec3(unsigned int handle, const char *name, float x, float y, float z) {
    if (!phantty_metal_pipeline_valid(handle) || name == NULL) return;
    PhanttyMetalPipelineSlot *slot = &phantty_metal_pipelines[handle];
    if (strcmp(name, "textColor") == 0) {
        slot->uniforms.text_color[0] = x;
        slot->uniforms.text_color[1] = y;
        slot->uniforms.text_color[2] = z;
        slot->uniforms.text_color[3] = 1.0f;
    }
}

void phantty_metal_pipeline_set_vec4(unsigned int handle, const char *name, float x, float y, float z, float w) {
    if (!phantty_metal_pipeline_valid(handle) || name == NULL) return;
    PhanttyMetalPipelineSlot *slot = &phantty_metal_pipelines[handle];
    if (strcmp(name, "overlayColor") == 0) {
        slot->uniforms.overlay_color[0] = x;
        slot->uniforms.overlay_color[1] = y;
        slot->uniforms.overlay_color[2] = z;
        slot->uniforms.overlay_color[3] = w;
    }
}

void phantty_metal_pipeline_set_mat4(unsigned int handle, const char *name, const float *values) {
    if (!phantty_metal_pipeline_valid(handle) || name == NULL || values == NULL) return;
    PhanttyMetalPipelineSlot *slot = &phantty_metal_pipelines[handle];
    if (strcmp(name, "projection") == 0) {
        memcpy(slot->uniforms.projection, values, sizeof(slot->uniforms.projection));
    }
}

bool phantty_metal_frame_begin(
    PhanttyMetalContext *ctx,
    float r,
    float g,
    float b,
    float a,
    char *error_buf,
    size_t error_buf_len
) {
    if (ctx == NULL || ctx->command_queue == NULL || ctx->layer == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing Metal context for frame begin");
        return false;
    }
    if (ctx->encoder != NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }

    @autoreleasepool {
        id<MTLCommandQueue> queue = (id<MTLCommandQueue>)ctx->command_queue;
        CAMetalLayer *layer = (CAMetalLayer *)ctx->layer;
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (drawable == nil) {
            phantty_metal_set_error(error_buf, error_buf_len, "CAMetalLayer nextDrawable returned nil");
            return false;
        }
        [drawable retain];

        // Capture the drawable size so per-pane viewport/scissor can flip y to
        // Metal's upper-left origin (see phantty_metal_apply_viewport_scissor).
        phantty_metal_drawable_w = (int)drawable.texture.width;
        phantty_metal_drawable_h = (int)drawable.texture.height;

        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        if (command_buffer == nil) {
            [drawable release];
            phantty_metal_set_error(error_buf, error_buf_len, "commandBuffer returned nil");
            return false;
        }
        [command_buffer retain];

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        MTLRenderPassColorAttachmentDescriptor *color = pass.colorAttachments[0];
        color.texture = drawable.texture;
        color.loadAction = MTLLoadActionClear;
        color.storeAction = MTLStoreActionStore;
        color.clearColor = MTLClearColorMake(r, g, b, a);

        id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];
        if (encoder == nil) {
            [command_buffer release];
            [drawable release];
            phantty_metal_set_error(error_buf, error_buf_len, "renderCommandEncoderWithDescriptor returned nil");
            return false;
        }
        [encoder retain];

        ctx->drawable = drawable;
        ctx->command_buffer = command_buffer;
        ctx->encoder = encoder;
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }
}

bool phantty_metal_frame_end(PhanttyMetalContext *ctx, char *error_buf, size_t error_buf_len) {
    if (ctx == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing Metal context for frame end");
        return false;
    }
    if (ctx->encoder == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }

    @autoreleasepool {
        id<MTLRenderCommandEncoder> encoder = (id<MTLRenderCommandEncoder>)ctx->encoder;
        id<MTLCommandBuffer> command_buffer = (id<MTLCommandBuffer>)ctx->command_buffer;
        id<CAMetalDrawable> drawable = (id<CAMetalDrawable>)ctx->drawable;

        [encoder endEncoding];
        if (drawable != nil) [command_buffer presentDrawable:drawable];

        // Report GPU errors asynchronously rather than blocking the render
        // thread on waitUntilCompleted every frame (that serialized CPU and GPU
        // with zero overlap). Metal retains the command buffer + drawable until
        // the GPU finishes and the frame is presented, so releasing our own refs
        // right after commit is safe without waiting.
        [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status == MTLCommandBufferStatusError) {
                NSError *error = completed.error;
                fprintf(stderr, "Metal command buffer error: %s\n",
                        error != nil ? [[error localizedDescription] UTF8String] : "unknown");
            }
        }];
        [command_buffer commit];
        phantty_metal_set_error(error_buf, error_buf_len, "");

        [encoder release];
        if (command_buffer != nil) [command_buffer release];
        if (drawable != nil) [drawable release];
        ctx->encoder = NULL;
        ctx->command_buffer = NULL;
        ctx->drawable = NULL;
        return true;
    }
}

static bool phantty_metal_encode_draw(
    PhanttyMetalContext *ctx,
    unsigned int handle,
    unsigned int mode,
    int first,
    int count,
    int instances,
    unsigned int buffer0,
    unsigned int buffer1,
    char *error_buf,
    size_t error_buf_len
) {
    if (ctx == NULL || ctx->encoder == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing Metal frame encoder for draw");
        return false;
    }
    if (!phantty_metal_pipeline_valid(handle) || phantty_metal_pipelines[handle].pipeline == nil) {
        phantty_metal_set_error(error_buf, error_buf_len, "invalid Metal pipeline handle");
        return false;
    }
    if (count <= 0) {
        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }

    @autoreleasepool {
        id<MTLRenderCommandEncoder> encoder = (id<MTLRenderCommandEncoder>)ctx->encoder;
        PhanttyMetalPipelineSlot *slot = &phantty_metal_pipelines[handle];
        id<MTLRenderPipelineState> pso = slot->pipeline; // straight-alpha default
        if (!phantty_metal_blend_enabled) {
            pso = slot->pipeline_opaque;
        } else if (phantty_metal_blend_premult) {
            pso = slot->pipeline_premult;
        }
        [encoder setRenderPipelineState:pso];
        phantty_metal_apply_viewport_scissor(encoder);

        id<MTLBuffer> vertex0 = phantty_metal_buffer_object(buffer0);
        id<MTLBuffer> vertex1 = phantty_metal_buffer_object(buffer1);
        if (vertex0 != nil) [encoder setVertexBuffer:vertex0 offset:0 atIndex:0];
        if (vertex1 != nil) [encoder setVertexBuffer:vertex1 offset:0 atIndex:1];

        NSUInteger uniform_index = vertex1 != nil ? 2 : 1;
        [encoder setVertexBytes:&slot->uniforms length:sizeof(slot->uniforms) atIndex:uniform_index];
        [encoder setFragmentBytes:&slot->uniforms length:sizeof(slot->uniforms) atIndex:1];

        const unsigned int tex_handle0 = phantty_metal_active_textures[0];
        id<MTLTexture> texture0 = phantty_metal_texture_object(tex_handle0);
        if (texture0 != nil) {
            [encoder setFragmentTexture:texture0 atIndex:0];
            id<MTLSamplerState> sampler0 = phantty_metal_sampler_for(
                (id<MTLDevice>)ctx->device,
                phantty_metal_textures[tex_handle0].filter,
                phantty_metal_textures[tex_handle0].wrap);
            if (sampler0 != nil) [encoder setFragmentSamplerState:sampler0 atIndex:0];
        }

        MTLPrimitiveType primitive = phantty_metal_primitive_type(mode);
        if (instances > 1) {
            [encoder drawPrimitives:primitive vertexStart:(NSUInteger)first vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances];
        } else {
            [encoder drawPrimitives:primitive vertexStart:(NSUInteger)first vertexCount:(NSUInteger)count];
        }

        phantty_metal_set_error(error_buf, error_buf_len, "");
        return true;
    }
}

bool phantty_metal_pipeline_draw_arrays(
    PhanttyMetalContext *ctx,
    unsigned int handle,
    unsigned int mode,
    int first,
    int count,
    int instances,
    unsigned int buffer0,
    unsigned int buffer1,
    char *error_buf,
    size_t error_buf_len
) {
    if (ctx == NULL || ctx->command_queue == NULL || ctx->layer == NULL) {
        phantty_metal_set_error(error_buf, error_buf_len, "missing Metal context for draw");
        return false;
    }

    const bool owns_frame = ctx->encoder == NULL;
    if (owns_frame && !phantty_metal_frame_begin(ctx, 0.0f, 0.0f, 0.0f, 1.0f, error_buf, error_buf_len)) {
        return false;
    }

    bool ok = phantty_metal_encode_draw(ctx, handle, mode, first, count, instances, buffer0, buffer1, error_buf, error_buf_len);
    if (owns_frame && !phantty_metal_frame_end(ctx, error_buf, error_buf_len)) {
        ok = false;
    }
    return ok;
}
