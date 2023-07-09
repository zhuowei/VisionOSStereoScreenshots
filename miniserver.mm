#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>

#include <Dispatch/Dispatch.h>
#include <Foundation/Foundation.h>

#include "third_party/alvr/alvr/server/cpp/alvr_server/bindings.h"
#include "third_party/alvr/miniserver/EncodePipelineSW.h"
#include "visionos_stereo_screenshots_streaming_interface.h"

const unsigned char *FRAME_RENDER_VS_CSO_PTR;
unsigned int FRAME_RENDER_VS_CSO_LEN;
const unsigned char *FRAME_RENDER_PS_CSO_PTR;
unsigned int FRAME_RENDER_PS_CSO_LEN;
const unsigned char *QUAD_SHADER_CSO_PTR;
unsigned int QUAD_SHADER_CSO_LEN;
const unsigned char *COMPRESS_AXIS_ALIGNED_CSO_PTR;
unsigned int COMPRESS_AXIS_ALIGNED_CSO_LEN;
const unsigned char *COLOR_CORRECTION_CSO_PTR;
unsigned int COLOR_CORRECTION_CSO_LEN;

const unsigned char *QUAD_SHADER_COMP_SPV_PTR;
unsigned int QUAD_SHADER_COMP_SPV_LEN;
const unsigned char *COLOR_SHADER_COMP_SPV_PTR;
unsigned int COLOR_SHADER_COMP_SPV_LEN;
const unsigned char *FFR_SHADER_COMP_SPV_PTR;
unsigned int FFR_SHADER_COMP_SPV_LEN;
const unsigned char *RGBTOYUV420_SHADER_COMP_SPV_PTR;
unsigned int RGBTOYUV420_SHADER_COMP_SPV_LEN;

const char *g_sessionPath;
const char *g_driverRootDir;

void (*LogError)(const char *stringPtr);
void (*LogWarn)(const char *stringPtr);
void (*LogInfo)(const char *stringPtr);
void (*LogDebug)(const char *stringPtr);
void (*LogPeriodically)(const char *tag, const char *stringPtr);
void (*DriverReadyIdle)(bool setDefaultChaprone);
void (*InitializeDecoder)(const unsigned char *configBuffer, int len, int codec);
void (*VideoSend)(unsigned long long targetTimestampNs, unsigned char *buf, int len, bool isIdr);
void (*HapticsSend)(unsigned long long path, float duration_s, float frequency, float amplitude);
void (*ShutdownRuntime)();
unsigned long long (*PathStringToHash)(const char *path);
void (*ReportPresent)(unsigned long long timestamp_ns, unsigned long long offset_ns);
void (*ReportComposed)(unsigned long long timestamp_ns, unsigned long long offset_ns);
FfiDynamicEncoderParams (*GetDynamicEncoderParams)();
unsigned long long (*GetSerialNumber)(unsigned long long deviceID, char *outString);
void (*SetOpenvrProps)(unsigned long long deviceID);
void (*WaitForVSync)();

static std::unique_ptr<alvr::EncodePipelineSW> gEncodePipelineSW;
static bool gNextFrameIDR = true;

void *CppEntryPoint(const char *pInterfaceName, int *pReturnCode) {
  // Callback from HmdDriverFactory
  *pReturnCode = 0;
  return nullptr;
}

#define ALVR_H264 0

void InitializeStreaming() { visionos_stereo_screenshots_streaming_did_start(); }

void DeinitializeStreaming() { visionos_stereo_screenshots_streaming_did_stop(); }
void SendVSync() {}
void RequestIDR() { gNextFrameIDR = true; }
static std::mutex gDeviceMotionMutex;
static FfiDeviceMotion gDeviceMotion;
static uint64_t gDeviceTargetTimestamp;
void SetTracking(unsigned long long targetTimestampNs, float controllerPoseTimeOffsetS,
                 const FfiDeviceMotion *deviceMotions, int motionsCount,
                 const FfiHandSkeleton *leftHand, const FfiHandSkeleton *rightHand,
                 unsigned int controllersTracked) {
  std::lock_guard lock{gDeviceMotionMutex};
  if (motionsCount == 0) {
    return;
  }
  gDeviceTargetTimestamp = targetTimestampNs;
  gDeviceMotion = deviceMotions[0];
}
void VideoErrorReportReceive() {}
void ShutdownSteamvr() {}

void SetOpenvrProperty(unsigned long long deviceID, FfiOpenvrProperty prop) {}

void SetChaperone(float areaWidth, float areaHeight) {}
static FfiViewsConfig gViewsConfig;
void SetViewsConfig(FfiViewsConfig config) { gViewsConfig = config; }
void SetBattery(unsigned long long deviceID, float gauge_value, bool is_plugged) {}
void SetButton(unsigned long long path, FfiButtonValue value) {}

void CaptureFrame() {}

extern "C" {
void *HmdDriverFactory(const char *interface_name, int32_t *return_code);
void CFRunLoopRun(void);
}

static dispatch_queue_t gEncodingQueue;

void visionos_stereo_screenshots_initialize_streaming() {
  gEncodingQueue = dispatch_queue_create("com.worthdoingbadly.stereoscreenshots.encodingqueue",
                                         DISPATCH_QUEUE_SERIAL);
  int32_t ret;
  HmdDriverFactory("hello", &ret);
  DriverReadyIdle(false);
}

static std::mutex gEncodingQueueMutex;
static int gInFlightRequests;

static void EncodeAndSendFrame(NSData *yuvFrame, NSData *aFrame, uint64_t width, uint64_t height, uint64_t targetTimestampNs) {
  if (!gEncodePipelineSW) {
    gEncodePipelineSW = std::make_unique<alvr::EncodePipelineSW>(width, height);
  }
  auto &picture = gEncodePipelineSW->picture;
  uint8_t *buf = (uint8_t *)yuvFrame.bytes;
  uint64_t imageSize = width * height;
  picture.img.plane[0] = buf;
  picture.img.plane[1] = buf + imageSize;
  picture.img.plane[2] = buf + imageSize + (imageSize / 4);
  picture.img.i_stride[0] = width;
  picture.img.i_stride[1] = width / 2;
  picture.img.i_stride[2] = width / 2;
  bool idr = gNextFrameIDR;
  gNextFrameIDR = false;
  gEncodePipelineSW->PushFrame(targetTimestampNs, idr);
  if (gEncodePipelineSW->nal_size == 0) {
    return;
  }
  ParseFrameNals(ALVR_H264, gEncodePipelineSW->nal[0].p_payload, gEncodePipelineSW->nal_size,
                 targetTimestampNs, idr);
}

void visionos_stereo_screenshots_submit_frame(NSData *yuvFrame, NSData *aFrame, uint64_t width,
                                              uint64_t height, uint64_t timestamp) {
  std::lock_guard lock{gEncodingQueueMutex};
  if (gInFlightRequests > 3) {
    NSLog(@"visionos_stereo_screenshots: Dropping frame!");
    return;
  }
  gInFlightRequests++;
  dispatch_async(gEncodingQueue, ^{
    EncodeAndSendFrame(yuvFrame, aFrame, width, height, timestamp);
    {
      std::lock_guard lock{gEncodingQueueMutex};
      gInFlightRequests--;
    }
  });
}

struct visionos_stereo_screenshots_streaming_fov_both
visionos_stereo_screenshots_streaming_get_fov() {
  return {
      .left =
          {
              .fovAngleLeft = gViewsConfig.fov[0].left,
              .fovAngleRight = gViewsConfig.fov[0].right,
              .fovAngleTop = gViewsConfig.fov[0].up,
              .fovAngleBottom = gViewsConfig.fov[0].down,
          },
      .right =
          {
              .fovAngleLeft = gViewsConfig.fov[1].left,
              .fovAngleRight = gViewsConfig.fov[1].right,
              .fovAngleTop = gViewsConfig.fov[1].up,
              .fovAngleBottom = gViewsConfig.fov[1].down,
          },

  };
}

struct visionos_stereo_screenshots_streaming_head_pose
visionos_stereo_screenshots_streaming_get_head_pose() {
  std::lock_guard lock{gDeviceMotionMutex};
  return {
      .position = {gDeviceMotion.position[0], gDeviceMotion.position[1], gDeviceMotion.position[2]},
      .rotation = {gDeviceMotion.orientation.x, gDeviceMotion.orientation.y,
                   gDeviceMotion.orientation.z, gDeviceMotion.orientation.w},
.targetTimestamp = gDeviceTargetTimestamp,
  };
}
uint64_t visionos_stereo_screenshots_streaming_get_timestamp() {
return gDeviceTargetTimestamp;
}
