@import CompositorServices;
@import Darwin;
@import ObjectiveC;
@import UniformTypeIdentifiers;

#define DYLD_INTERPOSE(_replacement, _replacee)                                           \
  __attribute__((used)) static struct {                                                   \
    const void* replacement;                                                              \
    const void* replacee;                                                                 \
  } _interpose_##_replacee __attribute__((section("__DATA,__interpose,interposing"))) = { \
      (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee}

// 6.5cm translation on x
static simd_float4x4 gRightEyeMatrix = {.columns = {
                                            {1, 0, 0, 0},
                                            {0, 1, 0, 0},
                                            {0, 0, 1, 0},
                                            {0.065, 0, 0, 1},
                                        }};

// cp_drawable_get_view
struct cp_view {
  simd_float4x4 transform;     // 0x0
  char unknown[0x110 - 0x40];  // 0x40
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

static id<MTLTexture> gHookedExtraScrapTexture = nil;
static id<MTLTexture> gHookedExtraScrapDepthTexture = nil;

static id<MTLDevice> gMetalDevice;
static id<MTLComputePipelineState> gYUVAComputePipelineState;

// pointer to the drawable
static NSMutableDictionary<NSNumber*, NSMutableDictionary<NSString*, id>*>* gDrawableDictionaries;

static void DumpScreenshot(NSMutableDictionary<NSString*, id>* replacements);

static id<MTLTexture> MakeOurTextureBasedOnTheirTexture(id<MTLDevice> device,
                                                        id<MTLTexture> originalTexture,
                                                        NSUInteger width, NSUInteger height);

static NSMutableDictionary* CreateDrawableReplacements(cp_drawable_t drawable) {
  NSMutableDictionary* replacements = [NSMutableDictionary new];
  id<MTLDevice> metalDevice = gMetalDevice;
  id<MTLTexture> originalTexture = cp_drawable_get_color_texture(drawable, 0);
  id<MTLTexture> originalDepthTexture = cp_drawable_get_depth_texture(drawable, 0);
  // TODO(zhuowei): pull the width and height out of the JSON
  int eyeWidth = 1280;
  int eyeHeight = 720;
  replacements[@"ColorTexture0"] =
      MakeOurTextureBasedOnTheirTexture(metalDevice, originalTexture, eyeWidth, eyeHeight);
  replacements[@"ColorTexture1"] =
      MakeOurTextureBasedOnTheirTexture(metalDevice, originalTexture, eyeWidth, eyeHeight);
  replacements[@"DepthTexture0"] =
      MakeOurTextureBasedOnTheirTexture(metalDevice, originalDepthTexture, eyeWidth, eyeHeight);
  replacements[@"DepthTexture1"] =
      MakeOurTextureBasedOnTheirTexture(metalDevice, originalDepthTexture, eyeWidth, eyeHeight);

  id<MTLTexture> combinedColorTexture =
      MakeOurTextureBasedOnTheirTexture(metalDevice, originalTexture, eyeWidth * 2, eyeHeight);
  replacements[@"CombinedColorTexture"] = combinedColorTexture;

  // YUV420 Planar + A conversion
  replacements[@"CombinedColorTextureFakeLinear"] =
      [combinedColorTexture newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm];

  MTLTextureDescriptor* yDescriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                         width:combinedColorTexture.width
                                                        height:combinedColorTexture.height
                                                     mipmapped:false];
  MTLTextureDescriptor* uDescriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                         width:combinedColorTexture.width / 2
                                                        height:combinedColorTexture.height / 2
                                                     mipmapped:false];
  replacements[@"YTexture"] = [metalDevice newTextureWithDescriptor:yDescriptor];
  replacements[@"UTexture"] = [metalDevice newTextureWithDescriptor:uDescriptor];
  replacements[@"VTexture"] = [metalDevice newTextureWithDescriptor:uDescriptor];
  replacements[@"ATexture"] = [metalDevice newTextureWithDescriptor:yDescriptor];

  return replacements;
}

static NSMutableDictionary* GetDrawableReplacements(cp_drawable_t drawable) {
  if (gTakeScreenshotStatus != kTakeScreenshotStatusScreenshotInProgress) {
    return nil;
  }
  NSNumber* number = [NSNumber numberWithUnsignedLongLong:(uint64_t)drawable];
  NSMutableDictionary* replacements = gDrawableDictionaries[number];
  if (!replacements) {
    replacements = CreateDrawableReplacements(drawable);
    gDrawableDictionaries[number] = replacements;
  }
  return replacements;
}

static id<MTLTexture> MakeOurTextureBasedOnTheirTexture(id<MTLDevice> device,
                                                        id<MTLTexture> originalTexture,
                                                        NSUInteger width, NSUInteger height) {
  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:originalTexture.pixelFormat
                                                         width:width
                                                        height:height
                                                     mipmapped:false];
  descriptor.storageMode = originalTexture.storageMode;
  return [device newTextureWithDescriptor:descriptor];
}

static cp_drawable_t hook_cp_frame_query_drawable(cp_frame_t frame) {
  cp_drawable_t retval = cp_frame_query_drawable(frame);
  if (gTakeScreenshotStatus == kTakeScreenshotStatusScreenshotInProgress) {
    gTakeScreenshotStatus = kTakeScreenshotStatusIdle;
  } else if (gTakeScreenshotStatus == kTakeScreenshotStatusScreenshotNextFrame) {
    gDrawableDictionaries = [NSMutableDictionary new];
    gTakeScreenshotStatus = kTakeScreenshotStatusScreenshotInProgress;
  }

  if (!gHookedExtraScrapTexture) {
    // only make this once
    id<MTLDevice> metalDevice = gMetalDevice;
    id<MTLTexture> originalTexture = cp_drawable_get_color_texture(retval, 0);
    id<MTLTexture> originalDepthTexture = cp_drawable_get_depth_texture(retval, 0);
    gHookedExtraScrapTexture = MakeOurTextureBasedOnTheirTexture(
        metalDevice, originalTexture, originalTexture.width, originalTexture.height);
    gHookedExtraScrapDepthTexture = MakeOurTextureBasedOnTheirTexture(
        metalDevice, originalDepthTexture, originalDepthTexture.width, originalDepthTexture.height);
  }

  cp_view_t leftView = cp_drawable_get_view(retval, 0);
  cp_view_t rightView = cp_drawable_get_view(retval, 1);
  memcpy(rightView, leftView, sizeof(*leftView));
  rightView->transform = gRightEyeMatrix;
  cp_view_get_view_texture_map(rightView)->texture_index = 1;

  NSMutableDictionary* replacements = GetDrawableReplacements(retval);
  if (replacements) {
    // TODO(zhuowei): pull FoV info
  }
  return retval;
}

DYLD_INTERPOSE(hook_cp_frame_query_drawable, cp_frame_query_drawable);

static void hook_cp_drawable_encode_present(cp_drawable_t drawable,
                                            id<MTLCommandBuffer> commandBuffer) {
  NSMutableDictionary* replacements = GetDrawableReplacements(drawable);
  if (!replacements) {
    return cp_drawable_encode_present(drawable, commandBuffer);
  }
  id<MTLBlitCommandEncoder> blitCommandEncoder = [commandBuffer blitCommandEncoder];
  id<MTLTexture> combinedColorTexture = replacements[@"CombinedColorTexture"];
  id<MTLTexture> colorTexture0 = replacements[@"ColorTexture0"];
  [blitCommandEncoder copyFromTexture:colorTexture0
                          sourceSlice:0
                          sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0)
                           sourceSize:MTLSizeMake(colorTexture0.width, colorTexture0.height, 1)
                            toTexture:combinedColorTexture
                     destinationSlice:0
                     destinationLevel:0
                    destinationOrigin:MTLOriginMake(0, 0, 0)];
  id<MTLTexture> colorTexture1 = replacements[@"ColorTexture1"];
  [blitCommandEncoder copyFromTexture:colorTexture1
                          sourceSlice:0
                          sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0)
                           sourceSize:MTLSizeMake(colorTexture1.width, colorTexture1.height, 1)
                            toTexture:combinedColorTexture
                     destinationSlice:0
                     destinationLevel:0
                    destinationOrigin:MTLOriginMake(colorTexture0.width, 0, 0)];
  [blitCommandEncoder endEncoding];
  id<MTLComputeCommandEncoder> computeCommandEncoder = [commandBuffer computeCommandEncoder];
  [computeCommandEncoder setComputePipelineState:gYUVAComputePipelineState];
  [computeCommandEncoder setTexture:replacements[@"CombinedColorTextureFakeLinear"] atIndex:0];
  [computeCommandEncoder setTexture:replacements[@"YTexture"] atIndex:1];
  [computeCommandEncoder setTexture:replacements[@"UTexture"] atIndex:2];
  [computeCommandEncoder setTexture:replacements[@"VTexture"] atIndex:3];
  [computeCommandEncoder setTexture:replacements[@"ATexture"] atIndex:4];
  [computeCommandEncoder
            dispatchThreads:MTLSizeMake(combinedColorTexture.width, combinedColorTexture.height, 1)
      threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
  [computeCommandEncoder endEncoding];
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
    DumpScreenshot(replacements);
  }];
  return cp_drawable_encode_present(drawable, commandBuffer);
}

DYLD_INTERPOSE(hook_cp_drawable_encode_present, cp_drawable_encode_present);

static size_t hook_cp_drawable_get_view_count(cp_drawable_t drawable) { return 2; }

DYLD_INTERPOSE(hook_cp_drawable_get_view_count, cp_drawable_get_view_count);

static size_t hook_cp_drawable_get_texture_count(cp_drawable_t drawable) { return 2; }

DYLD_INTERPOSE(hook_cp_drawable_get_texture_count, cp_drawable_get_texture_count);

static id<MTLTexture> hook_cp_drawable_get_color_texture(cp_drawable_t drawable, size_t index) {
  NSMutableDictionary* replacements = GetDrawableReplacements(drawable);
  if (replacements) {
    return replacements[index == 0 ? @"ColorTexture0" : @"ColorTexture1"];
  }
  if (index == 1) {
    return gHookedExtraScrapTexture;
  }
  return cp_drawable_get_color_texture(drawable, 0);
}

DYLD_INTERPOSE(hook_cp_drawable_get_color_texture, cp_drawable_get_color_texture);

static id<MTLTexture> hook_cp_drawable_get_depth_texture(cp_drawable_t drawable, size_t index) {
  NSMutableDictionary* replacements = GetDrawableReplacements(drawable);
  if (replacements) {
    return replacements[index == 0 ? @"DepthTexture0" : @"DepthTexture1"];
  }
  if (index == 1) {
    return gHookedExtraScrapDepthTexture;
  }
  return cp_drawable_get_depth_texture(drawable, 0);
}

DYLD_INTERPOSE(hook_cp_drawable_get_depth_texture, cp_drawable_get_depth_texture);

size_t cp_layer_properties_get_view_count(cp_layer_renderer_properties_t properties);

static size_t hook_cp_layer_properties_get_view_count(cp_layer_renderer_properties_t properties) {
  return 2;
}

DYLD_INTERPOSE(hook_cp_layer_properties_get_view_count, cp_layer_properties_get_view_count);

cp_layer_renderer_layout cp_layer_configuration_get_layout_private(
    cp_layer_renderer_configuration_t configuration);

static cp_layer_renderer_layout hook_cp_layer_configuration_get_layout_private(
    cp_layer_renderer_configuration_t configuration) {
  return cp_layer_renderer_layout_dedicated;
}

DYLD_INTERPOSE(hook_cp_layer_configuration_get_layout_private,
               cp_layer_configuration_get_layout_private);

static void DumpScreenshot(NSMutableDictionary<NSString*, id>* replacements) {
  NSLog(@"visionos_stereo_screenshot: DumpScreenshot");
  id<MTLTexture> yTexture = replacements[@"YTexture"];
  id<MTLTexture> uTexture = replacements[@"UTexture"];
  id<MTLTexture> vTexture = replacements[@"VTexture"];
  id<MTLTexture> aTexture = replacements[@"ATexture"];
  uint64_t pixelCount = yTexture.width * yTexture.height;
  NSMutableData* outputData = [NSMutableData dataWithLength:pixelCount + (pixelCount / 2)];
  [yTexture getBytes:outputData.mutableBytes
         bytesPerRow:yTexture.width
          fromRegion:MTLRegionMake2D(0, 0, yTexture.width, yTexture.height)
         mipmapLevel:0];
  [uTexture getBytes:outputData.mutableBytes + pixelCount
         bytesPerRow:uTexture.width
          fromRegion:MTLRegionMake2D(0, 0, uTexture.width, uTexture.height)
         mipmapLevel:0];
  [vTexture getBytes:outputData.mutableBytes + pixelCount + (pixelCount / 4)
         bytesPerRow:vTexture.width
          fromRegion:MTLRegionMake2D(0, 0, vTexture.width, vTexture.height)
         mipmapLevel:0];
  [outputData writeToFile:@"/tmp/yuv420.bin" options:0 error:nil];
  NSMutableData* outputData2 = [NSMutableData dataWithLength:pixelCount];
  [aTexture getBytes:outputData2.mutableBytes
         bytesPerRow:aTexture.width
          fromRegion:MTLRegionMake2D(0, 0, aTexture.width, aTexture.height)
         mipmapLevel:0];
  [outputData2 writeToFile:@"/tmp/a.bin" options:0 error:nil];
#if 0
  id<MTLTexture> gHookedRealTexture = replacements[@"CombinedColorTexture"];

  size_t textureDataSize = gHookedRealTexture.width * gHookedRealTexture.height * 4;
  NSMutableData* outputData = [NSMutableData dataWithLength:textureDataSize];
  [gHookedRealTexture
           getBytes:outputData.mutableBytes
        bytesPerRow:gHookedRealTexture.width * 4
      bytesPerImage:textureDataSize
         fromRegion:MTLRegionMake2D(0, 0, gHookedRealTexture.width, gHookedRealTexture.height)
        mipmapLevel:0
              slice:0];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)outputData);
  CGImageRef outputImage = CGImageCreate(
      gHookedRealTexture.width, gHookedRealTexture.height, /*bitsPerComponent=*/8,
      /*bitsPerPixel=*/32, /*bytesPerRow=*/gHookedRealTexture.width * 4, colorSpace,
      kCGImageByteOrder32Little | kCGImageAlphaPremultipliedFirst, provider, /*decode=*/nil,
      /*shouldInterpolate=*/false, /*intent=*/kCGRenderingIntentDefault);

  NSString* filePath =
      [NSString stringWithFormat:@"/tmp/visionos_stereo_screenshot_%ld.png", time(nil)];
  ;

  CGImageDestinationRef destination =
      CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:filePath],
                                      (__bridge CFStringRef)UTTypePNG.identifier, 1, nil);
  CGImageDestinationAddImage(destination, outputImage, nil);
  bool success = CGImageDestinationFinalize(destination);

  if (success) {
    NSLog(@"visionos_stereo_screenshots wrote screenshot to %@", filePath);
  } else {
    NSLog(@"visionos_stereo_screenshots failed to write screenshot to %@", filePath);
  }

  CFRelease(destination);
  CFRelease(outputImage);
  CFRelease(colorSpace);
  CFRelease(provider);
#endif
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
  gMetalDevice = MTLCreateSystemDefaultDevice();
  NSURL* libraryPath = [[NSURL fileURLWithPath:NSProcessInfo.processInfo.environment[@"ALVR_DIR"]]
      URLByAppendingPathComponent:@"default.metallib"];
  NSError* error;
  id<MTLLibrary> defaultLibrary = [gMetalDevice newLibraryWithURL:libraryPath error:&error];
  if (!defaultLibrary) {
    NSLog(@"visionos_stereo_screenshots: failed to load metal library: %@", error);
    return;
  }
  id<MTLFunction> kernelFunction =
      [defaultLibrary newFunctionWithName:@"convertTextureToYUVAPlanar420"];
  gYUVAComputePipelineState = [gMetalDevice newComputePipelineStateWithFunction:kernelFunction
                                                                          error:&error];
  if (!gYUVAComputePipelineState) {
    NSLog(@"visionos_stereo_screenshots: failed to load metal yuva pipeline state: %@", error);
    return;
  }
}
