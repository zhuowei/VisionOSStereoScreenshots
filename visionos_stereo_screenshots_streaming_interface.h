#pragma once
#include <stdint.h>
@class NSData;

#ifdef __cplusplus
extern "C" {
#endif

// implemented in miniserver.mm
void visionos_stereo_screenshots_initialize_streaming(void);
void visionos_stereo_screenshots_submit_frame(NSData* yuvFrame, NSData* aFrame, uint64_t width, uint64_t height);
// implemented in visionos_stereo_screenshots.m
void visionos_stereo_screenshots_streaming_did_start(void);
void visionos_stereo_screenshots_streaming_did_stop(void);

#ifdef __cplusplus
}
#endif
