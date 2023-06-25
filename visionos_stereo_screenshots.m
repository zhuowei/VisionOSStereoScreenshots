@import CompositorServices;

#define DYLD_INTERPOSE(_replacement, _replacee)                                           \
  __attribute__((used)) static struct {                                                   \
    const void* replacement;                                                              \
    const void* replacee;                                                                 \
  } _interpose_##_replacee __attribute__((section("__DATA,__interpose,interposing"))) = { \
      (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee}

// cp_drawable_get_view
struct cp_view {
  char unknown[0x110];
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

static void DumpScreenshot(void);

static id<MTLTexture> MakeOurTextureBasedOnTheirTexture(id<MTLDevice> device,
                                                        id<MTLTexture> originalTexture) {
  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:originalTexture.pixelFormat
                                                         width:originalTexture.width * 2
                                                        height:originalTexture.height
                                                     mipmapped:false];
  descriptor.storageMode = originalTexture.storageMode;
  return [device newTextureWithDescriptor:descriptor];
}

static cp_drawable_t hook_cp_frame_query_drawable(cp_frame_t frame) {
  cp_drawable_t retval = cp_frame_query_drawable(frame);
  gHookedDrawable = nil;
  if (gTakeScreenshotStatus == kTakeScreenshotStatusScreenshotNextFrame) {
    gTakeScreenshotStatus = kTakeScreenshotStatusScreenshotInProgress;
    gHookedDrawable = retval;
    if (!gHookedExtraTexture) {
      // only make this once
      id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
      id<MTLTexture> originalTexture = cp_drawable_get_color_texture(gHookedDrawable, 0);
      id<MTLTexture> originalDepthTexture = cp_drawable_get_depth_texture(gHookedDrawable, 0);
      gHookedExtraTexture = MakeOurTextureBasedOnTheirTexture(metalDevice, originalTexture);
      gHookedExtraDepthTexture =
          MakeOurTextureBasedOnTheirTexture(metalDevice, originalDepthTexture);
    }
    NSLog(@"visionos_stereo_screenshots starting screenshot!");
  }
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
  if (gHookedDrawable != drawable) {
    return cp_drawable_get_view_count(drawable);
  }
  NSLog(@"visionos_stereo_screenshots calling get_view_count");
  return cp_drawable_get_view_count(drawable) + gHookedExtraViewCount;
}

DYLD_INTERPOSE(hook_cp_drawable_get_view_count, cp_drawable_get_view_count);

static cp_view_t hook_cp_drawable_get_view(cp_drawable_t drawable, size_t index) {
  if (gHookedDrawable != drawable) {
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
// size_t textureCount = cp_drawable_get_texture_count(drawable);
#if 0
  if (index == viewCount) {
    // Left eye is easy: same as original
    // TODO(zhuowei): set the texture to point to ours
    cp_view_t view = &gHookedLeftView;
    memcpy(view, baseView, sizeof(gHookedLeftView));
    cp_view_texture_map_t textureMap = cp_view_get_view_texture_map(view);
    textureMap->texture_index = textureCount;
    if (cp_view_texture_map_get_texture_index(textureMap) != textureCount) {
      NSLog(@"visionos_stereo_screenshots texture_index offset is wrong!");
      abort();
    }
    NSLog(@"visionos_stereo_screenshots get left view! %zu %zu", textureCount, cp_view_texture_map_get_texture_index(textureMap));
    return view;
  }

  if (index == viewCount + 1) {
    // TODO(zhuowei): good luck
    return &gHookedRightView;
  }
#endif
  if (index == viewCount) {
    cp_view_t view = &gHookedRightView;
    memcpy(view, baseView, sizeof(*view));
    cp_view_texture_map_t textureMap = cp_view_get_view_texture_map(view);
    NSLog(@"Current texture map for right: %lf %lf %lf %lf", textureMap->viewport.originX,
          textureMap->viewport.originY, textureMap->viewport.width, textureMap->viewport.height);
    textureMap->viewport.originX += textureMap->viewport.width;
    MTLViewport p = cp_view_texture_map_get_viewport(textureMap);
    NSLog(@"New texture map for right: %lf %lf %lf %lf", p.originX, p.originY, p.width, p.height);
    return view;
  }
  return cp_drawable_get_view(drawable, index);
}

DYLD_INTERPOSE(hook_cp_drawable_get_view, cp_drawable_get_view);

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

static id<MTLTexture> hook_cp_drawable_get_color_texture(cp_drawable_t drawable, size_t index) {
  if (gHookedDrawable != drawable) {
    return cp_drawable_get_color_texture(drawable, index);
  }
  // TODO(zhuowei): hack
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
  // TODO(zhuowei): hack
  return gHookedExtraDepthTexture;
  size_t textureCount = cp_drawable_get_texture_count(drawable);
  if (index == textureCount) {
    NSLog(@"visionos_stereo_screenshots cp_drawable_get_depth_texture called");
    return gHookedExtraDepthTexture;
  }
  return cp_drawable_get_depth_texture(drawable, index);
}

DYLD_INTERPOSE(hook_cp_drawable_get_depth_texture, cp_drawable_get_depth_texture);

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
}
