#pragma once
#include <stdint.h>
@class NSData;

#ifdef __cplusplus
extern "C" {
#endif

struct visionos_stereo_screenshots_streaming_fov {
  float fovAngleLeft;
  float fovAngleRight;
  float fovAngleTop;
  float fovAngleBottom;
};

struct visionos_stereo_screenshots_streaming_fov_both {
  struct visionos_stereo_screenshots_streaming_fov left;
  struct visionos_stereo_screenshots_streaming_fov right;
  ;
};

struct visionos_stereo_screenshots_streaming_head_pose {
  float position[3];
  float rotation[4];
  uint64_t targetTimestamp;
};

// implemented in miniserver.mm
void visionos_stereo_screenshots_initialize_streaming(void);
void visionos_stereo_screenshots_submit_frame(NSData* yuvFrame, NSData* aFrame, uint64_t width,
                                              uint64_t height, uint64_t timestamp);
// implemented in visionos_stereo_screenshots.m
void visionos_stereo_screenshots_streaming_did_start(void);
void visionos_stereo_screenshots_streaming_did_stop(void);
struct visionos_stereo_screenshots_streaming_fov_both visionos_stereo_screenshots_streaming_get_fov(
    void);
struct visionos_stereo_screenshots_streaming_head_pose
visionos_stereo_screenshots_streaming_get_head_pose(void);
uint64_t visionos_stereo_screenshots_streaming_get_timestamp(void);

#ifdef __cplusplus
}
#endif
