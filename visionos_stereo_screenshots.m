@import CompositorServices;
@import Darwin;
@import ObjectiveC;

#define DYLD_INTERPOSE(_replacement, _replacee)                                           \
  __attribute__((used)) static struct {                                                   \
    const void* replacement;                                                              \
    const void* replacee;                                                                 \
  } _interpose_##_replacee __attribute__((section("__DATA,__interpose,interposing"))) = { \
      (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee}

// 6.5cm translation on x
static simd_float4x4 gRightEyeMatrix = {
  .columns = {
    {1, 0, 0, 0},
    {0, 1, 0, 0},
    {0, 0, 1, 0},
    {0.065, 0, 0, 1},
  }
};

// cp_drawable_get_view
struct cp_view {
simd_float4x4 transform;     // 0x0
  char unknown[0x110-0x40]; // 0x40
};
static_assert(sizeof(struct cp_view) == 0x110, "cp_view size is wrong");

// cp_view_texture_map_get_texture_index
struct cp_view_texture_map {
  size_t texture_index;  // 0x0
  size_t slice_index;    // 0x8
  MTLViewport viewport;  // 0x10
};

static const int kTakeScreenshotStatusIdle = 0;
static const int kTakeScreenshotStatusScreenshotNextFrame = 1;
static const int kTakeScreenshotStatusScreenshotInProgress = 2;

// TODO(zhuowei): do I need locking for this?
static int gTakeScreenshotStatus = kTakeScreenshotStatusIdle;

// TODO(zhuowei): multiple screenshots in flight
static cp_drawable_t gHookedDrawable;

// TODO(zhuowei): backboardd ONLY supports 1 or 2 views
static const int gHookedExtraViewCount = 1;
static const int gHookedExtraTextureCount = 1;
static id<MTLTexture> gHookedExtraTexture = nil;
static id<MTLTexture> gHookedExtraDepthTexture = nil;
// static struct cp_view gHookedLeftView;
static struct cp_view gHookedRightView;
@class RSRenderer;
static RSRenderer* gRSRenderer;

static void DumpScreenshot(void);

static id<MTLTexture> MakeOurTextureBasedOnTheirTexture(id<MTLDevice> device,
                                                        id<MTLTexture> originalTexture) {
  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:originalTexture.pixelFormat
                                                         width:originalTexture.width*2
                                                        height:originalTexture.height
                                                     mipmapped:false];
  descriptor.storageMode = originalTexture.storageMode;
  return [device newTextureWithDescriptor:descriptor];
}

static cp_drawable_t hook_cp_frame_query_drawable(cp_frame_t frame) {
  cp_drawable_t retval = cp_frame_query_drawable(frame);
  gHookedDrawable = nil;
#if 0
  if (gRSRenderer) {
    *(int*)((uintptr_t)gRSRenderer + 0x50) = 3; // simulator
  }
#endif
  if (gTakeScreenshotStatus == kTakeScreenshotStatusScreenshotNextFrame) {
    gTakeScreenshotStatus = kTakeScreenshotStatusScreenshotInProgress;
    gHookedDrawable = retval;
#if 0
    if (!gHookedExtraTexture) {
      // only make this once
      id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
      id<MTLTexture> originalTexture = cp_drawable_get_color_texture(retval, 0);
      id<MTLTexture> originalDepthTexture = cp_drawable_get_depth_texture(retval, 0);
      gHookedExtraTexture = MakeOurTextureBasedOnTheirTexture(metalDevice, originalTexture);
      gHookedExtraDepthTexture =
          MakeOurTextureBasedOnTheirTexture(metalDevice, originalDepthTexture);
    }
#endif
      id<MTLTexture> originalTexture = cp_drawable_get_color_texture(retval, 0);
    gHookedExtraTexture = originalTexture;
#if 0
  if (gRSRenderer) {
    *(int*)((uintptr_t)gRSRenderer + 0x50) = 2; // shared
  }
#endif
    NSLog(@"visionos_stereo_screenshots starting screenshot!");
  }
  cp_view_t leftView = cp_drawable_get_view(retval, 0);
  cp_view_t rightView = cp_drawable_get_view(retval, 1);
  memcpy(rightView, leftView, sizeof(*leftView));
  rightView->transform = gRightEyeMatrix;
  return retval;
}

DYLD_INTERPOSE(hook_cp_frame_query_drawable, cp_frame_query_drawable);

static void hook_cp_drawable_encode_present(cp_drawable_t drawable,
                                            id<MTLCommandBuffer> command_buffer) {
  if (gHookedDrawable == drawable) {
    [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
      DumpScreenshot();
    }];
  }
  return cp_drawable_encode_present(drawable, command_buffer);
}

DYLD_INTERPOSE(hook_cp_drawable_encode_present, cp_drawable_encode_present);

static size_t hook_cp_drawable_get_view_count(cp_drawable_t drawable) {
  return 2;
  if (false && gHookedDrawable != drawable) {
    return cp_drawable_get_view_count(drawable);
  }
  NSLog(@"visionos_stereo_screenshots calling get_view_count");
  return cp_drawable_get_view_count(drawable) + gHookedExtraViewCount;
}

DYLD_INTERPOSE(hook_cp_drawable_get_view_count, cp_drawable_get_view_count);

static cp_view_t hook_cp_drawable_get_view(cp_drawable_t drawable, size_t index) {
  return cp_drawable_get_view(drawable, 0);
  if (gHookedDrawable != drawable) {
    size_t viewCount = cp_drawable_get_view_count(drawable);
    if (index >= viewCount) {
      index = viewCount;
    }
    return cp_drawable_get_view(drawable, index);
  }
  NSLog(@"visionos_stereo_screenshots calling get_view %zu", index);
  size_t viewCount = cp_drawable_get_view_count(drawable);
  if (index < viewCount) {
    return cp_drawable_get_view(drawable, index);
  }
  cp_view_t baseView = cp_drawable_get_view(drawable, 0);
  cp_view_t secondViewMaybe = cp_drawable_get_view(drawable, 1);
  if ((uintptr_t)secondViewMaybe - (uintptr_t)baseView != sizeof(struct cp_view)) {
    NSLog(@"visionos_stereo_screenshots view size is wrong!");
    abort();
  }
  size_t textureCount = cp_drawable_get_texture_count(drawable);
  if (index == viewCount) {
    // Right eye is original with our texture
    // TODO(zhuowei): set the texture to point to ours
    cp_view_t view = &gHookedRightView;
    memcpy(view, baseView, sizeof(*view));
#if 0
    cp_view_texture_map_t textureMap = cp_view_get_view_texture_map(view);
    textureMap->texture_index = textureCount;
    if (cp_view_texture_map_get_texture_index(textureMap) != textureCount) {
      NSLog(@"visionos_stereo_screenshots texture_index offset is wrong!");
      abort();
    }
    NSLog(@"visionos_stereo_screenshots get right view! %zu %zu", textureCount,
          cp_view_texture_map_get_texture_index(textureMap));
#endif
    return view;
  }

#if 0
  if (index == viewCount + 1) {
    // TODO(zhuowei): good luck
    return &gHookedRightView;
  }
#endif
  return cp_drawable_get_view(drawable, index);
}

DYLD_INTERPOSE(hook_cp_drawable_get_view, cp_drawable_get_view);

#if 0
static size_t hook_cp_drawable_get_texture_count(cp_drawable_t drawable) {
  NSLog(@"visionos_stereo_screenshots cp_drawable_get_texture_count called RIGHT NOW");
  size_t retval = cp_drawable_get_texture_count(drawable);
  if (gHookedDrawable != drawable) {
    return retval;
  }
  NSLog(@"visionos_stereo_screenshots cp_drawable_get_texture_count called: orig %zu", retval);
  return retval + gHookedExtraTextureCount;
}

DYLD_INTERPOSE(hook_cp_drawable_get_texture_count, cp_drawable_get_texture_count);
#endif
#if 0
static id<MTLTexture> hook_cp_drawable_get_color_texture(cp_drawable_t drawable, size_t index) {
  if (gHookedDrawable != drawable) {
    return cp_drawable_get_color_texture(drawable, index);
  }
  return gHookedExtraTexture;
  size_t textureCount = cp_drawable_get_texture_count(drawable);
  if (index == textureCount) {
    NSLog(@"visionos_stereo_screenshots get color texture!");
    return gHookedExtraTexture;
  }
  return cp_drawable_get_color_texture(drawable, index);
}

DYLD_INTERPOSE(hook_cp_drawable_get_color_texture, cp_drawable_get_color_texture);

static id<MTLTexture> hook_cp_drawable_get_depth_texture(cp_drawable_t drawable, size_t index) {
  if (gHookedDrawable != drawable) {
    return cp_drawable_get_depth_texture(drawable, index);
  }
  return gHookedExtraDepthTexture;
  size_t textureCount = cp_drawable_get_texture_count(drawable);
  if (index == textureCount) {
    NSLog(@"visionos_stereo_screenshots cp_drawable_get_depth_texture called");
    return gHookedExtraDepthTexture;
  }
  return cp_drawable_get_depth_texture(drawable, index);
}

DYLD_INTERPOSE(hook_cp_drawable_get_depth_texture, cp_drawable_get_depth_texture);
#endif
#if 1
// we can't hook these since backboardd only reads these once at startup,
// and setting it to 2 blanks screens the simulator

size_t cp_layer_properties_get_view_count(cp_layer_renderer_properties_t properties);

static size_t hook_cp_layer_properties_get_view_count(cp_layer_renderer_properties_t properties) {
  // keep -[RSRenderer prepareRendererForSession:environmentLayer:] happy
  // view count 1: renderer mode (RSRenderer._inferredDisplayMode at 0x50) = 3 (simulator)
    NSLog(@"visionos_stereo_screenshots get layer properties view count");
    return 2;
}

DYLD_INTERPOSE(hook_cp_layer_properties_get_view_count, cp_layer_properties_get_view_count);

cp_layer_renderer_layout cp_layer_configuration_get_layout_private(cp_layer_renderer_configuration_t configuration);

static cp_layer_renderer_layout hook_cp_layer_configuration_get_layout_private(cp_layer_renderer_configuration_t configuration) {
  // the "private" version returns two more values:
  // 3 (layered internal)
  // 4 (shared internal)
  // the public version maps those both to the standard shared/layered constants
  // (We can't use _layered because simulator doesn't support MTLTextureType2DMultisampleArray)
  // view count 2: RSRenderer renderer mode
  // 0(dedicated)->0: not supported?
// 1(shared)->2
// 2(layered)->1
// 3(layered internal)->1
//1(shared internal)->2
  // so we aim to have RSRenderer set render mode 2 (shared)
  return cp_layer_renderer_layout_shared;
}

DYLD_INTERPOSE(hook_cp_layer_configuration_get_layout_private, cp_layer_configuration_get_layout_private);
#endif

#if 0
cp_layer_renderer_configuration_t cp_layer_configuration_copy_system_default(NSError** error);
static cp_layer_renderer_configuration_t hook_cp_layer_configuration_copy_system_default(NSError** error) {
  cp_layer_renderer_configuration_t retval = cp_layer_configuration_copy_system_default(error);
  if (!retval) {
    return retval;
  }
  cp_layer_renderer_configuration_set_layout(retval, cp_layer_renderer_layout_shared);
  return retval;
}

DYLD_INTERPOSE(hook_cp_layer_configuration_copy_system_default, cp_layer_configuration_copy_system_default);
#endif

static void DumpScreenshot() {
  NSLog(@"TODO(zhuowei): DumpScreenshot");
  gTakeScreenshotStatus = kTakeScreenshotStatusIdle;
  size_t textureDataSize = gHookedExtraTexture.width * gHookedExtraTexture.height * 4;
  NSMutableData* outputData = [NSMutableData dataWithLength:textureDataSize];
  [gHookedExtraTexture
           getBytes:outputData.mutableBytes
        bytesPerRow:gHookedExtraTexture.width * 4
      bytesPerImage:textureDataSize
         fromRegion:MTLRegionMake2D(0, 0, gHookedExtraTexture.width, gHookedExtraTexture.height)
        mipmapLevel:0
              slice:0];
  NSString* filePath = @"/tmp/output.dat";
  NSError* error;
  [outputData writeToFile:filePath options:0 error:&error];
  if (error) {
    NSLog(@"visionos_stereo_screenshots failed to write screenshot to %@: %@", filePath, error);
  } else {
    NSLog(@"visionos_stereo_screenshots wrote screenshot to %@", filePath);
  }
}

@interface RSRenderer: NSObject
- (void)prepareRendererForSession:(id)arg1 environmentLayer:(id)arg2;
@end
static void (*real_prepareRendererForSession_environmentLayer)(RSRenderer* self, SEL sel, id session, id environmentLayer);

static void hook_prepareRendererForSession_environmentLayer(RSRenderer* self, SEL sel, id session, id environmentLayer) {
  gRSRenderer = self;
  real_prepareRendererForSession_environmentLayer(self, sel, session, environmentLayer);
}

#if 0
struct RSGetViewportsFromDrawableRet {
  float first[4];
  float second[4];
};

struct RSGetViewportsFromDrawableRet RSGetViewportsFromDrawable(cp_drawable_t);
static struct RSGetViewportsFromDrawableRet hook_RSGetViewportsFromDrawable(cp_drawable_t drawable) {
  struct RSGetViewportsFromDrawableRet retval = {.first = {0, 0, 1, 1}, .second = {0, 0, 1, 1}};
  return retval;
}
DYLD_INTERPOSE(hook_RSGetViewportsFromDrawable, RSGetViewportsFromDrawable);
#endif

void RECameraViewDescriptorsComponentCameraViewDescriptorSetViewport(float a, float b, float c, float d, void* desc, uint64_t id, int index);
static void hook_RECameraViewDescriptorsComponentCameraViewDescriptorSetViewport(float x, float y, float w, float h, void* desc, uint64_t id, int index) {
  // RSGetViewportsFromDrawable divides by 0 if the screen is not foviated
  // and it's easier to just hook it here
  x = index == 1? 0: 0.5;
  y = 0;
  w = 0.5;
  h = 0.5;
  RECameraViewDescriptorsComponentCameraViewDescriptorSetViewport(x, y, w, h, desc, id, index);
}
DYLD_INTERPOSE(hook_RECameraViewDescriptorsComponentCameraViewDescriptorSetViewport, RECameraViewDescriptorsComponentCameraViewDescriptorSetViewport);


__attribute__((constructor)) static void SetupSignalHandler() {
  NSLog(@"visionos_stereo_screenshots starting!");
  static dispatch_queue_t signal_queue;
  static dispatch_source_t signal_source;
  signal_queue = dispatch_queue_create("com.worthdoingbadly.stereoscreenshots.signalqueue",
                                       DISPATCH_QUEUE_SERIAL);
  signal_source =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, /*mask=*/0, signal_queue);
  dispatch_source_set_event_handler(signal_source, ^{
    if (gTakeScreenshotStatus == kTakeScreenshotStatusIdle) {
      gTakeScreenshotStatus = kTakeScreenshotStatusScreenshotNextFrame;
      NSLog(@"visionos_stereo_screenshots preparing to take screenshot!");
    }
  });
  signal(SIGUSR1, SIG_IGN);
  dispatch_activate(signal_source);
  dlopen("System/Library/PrivateFrameworks/RealitySimulation.framework/RealitySimulation", RTLD_LAZY | RTLD_LOCAL);
  Class rsRendererClass = NSClassFromString(@"RSRenderer");
  Method origMethod = class_getInstanceMethod(rsRendererClass, @selector(prepareRendererForSession:environmentLayer:));
  real_prepareRendererForSession_environmentLayer = (void*)method_getImplementation(origMethod);
  //method_setImplementation(origMethod, (IMP)hook_prepareRendererForSession_environmentLayer);
}
