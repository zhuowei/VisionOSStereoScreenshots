#pragma once
@class NSData;

#ifdef __cplusplus
extern "C" {
#endif

// implemented in miniserver.mm
void visionos_stereo_screenshots_initialize_streaming(void);
void visionos_stereo_screenshots_submit_frame(NSData* yuvFrame, NSData* aFrame);
// implemented in visionos_stereo_screenshots.m
void visionos_stereo_screenshots_streaming_did_start(void);
void visionos_stereo_screenshots_streaming_did_stop(void);

#ifdef __cplusplus
}
#endif
