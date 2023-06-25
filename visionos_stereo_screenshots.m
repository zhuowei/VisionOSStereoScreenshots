@import CompositorServices;

#define DYLD_INTERPOSE(_replacement, _replacee)                                           \
  __attribute__((used)) static struct {                                                   \
    const void* replacement;                                                              \
    const void* replacee;                                                                 \
  } _interpose_##_replacee __attribute__((section("__DATA,__interpose,interposing"))) = { \
      (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee}

static const int kTakeScreenshotStatusIdle = 0;
static const int kTakeScreenshotStatusScreenshotNextFrame = 1;
static const int kTakeScreenshotStatusScreenshotInProgress = 2;

// TODO(zhuowei): do I need locking for this?
static int gTakeScreenshotStatus = kTakeScreenshotStatusIdle;

// TODO(zhuowei): multiple screenshots in flight
static cp_drawable_t gHookedDrawable;

// TODO(zhuowei): DO IT
static const int gHookedExtraViewCount = 0;
static id<MTLTexture> gHookedExtraTexture = 0;

static void DumpScreenshot(void);

static cp_drawable_t hook_cp_frame_query_drawable(cp_frame_t frame) {
  cp_drawable_t retval = cp_frame_query_drawable(frame);
  gHookedDrawable = nil;
  if (gTakeScreenshotStatus == kTakeScreenshotStatusScreenshotNextFrame) {
    gTakeScreenshotStatus = kTakeScreenshotStatusScreenshotInProgress;
    gHookedDrawable = retval;
    // TODO(zhuowei): allocate our own
    gHookedExtraTexture = cp_drawable_get_color_texture(gHookedDrawable, 0);
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
  return cp_drawable_get_view_count(drawable) + gHookedExtraViewCount;
}

DYLD_INTERPOSE(hook_cp_drawable_get_view_count, cp_drawable_get_view_count);

static void DumpScreenshot() {
  NSLog(@"TODO(zhuowei): DumpScreenshot");
  gTakeScreenshotStatus = kTakeScreenshotStatusIdle;
  // TODO(zhuowei): use our own textures for this. Right now we're taking a mono screenshot, and
  // we're racing the compositor to do it
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
