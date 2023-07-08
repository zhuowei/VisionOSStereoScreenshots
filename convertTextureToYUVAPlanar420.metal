#include <metal_stdlib>

using namespace metal;

// Converts a texture to YUV 4:2:0 + alpha in separate planar textures.
// Based on ALVR rgbtoyuv420.comp/FFmpeg libavfilter/vf_scale_vulkan.c
kernel void convertTextureToYUVAPlanar420(
    texture2d<half, access::read> in_img [[texture(0)]],
    array<texture2d<half, access::write>, 4> out_img [[texture(1)]],
    uint2 pos [[thread_position_in_grid]]) {
  // clang-format off
  half4x4 yuv_matrix = half4x4(0.0, 1.0, 0.0, 0.0,
                               0.0, -0.5, 0.5, 0.0,
                               0.5, -0.5, 0, 0.0,
                               0.0, 0.0, 0.0, 1.0);
  // clang-format on

  half4 res = in_img.read(pos);
  out_img[3].write(half4(res.a, 0.0, 0.0, 0.0), pos);

  res *= yuv_matrix;
  res *= half4(219.0 / 255.0, 224.0 / 255.0, 224.0 / 255.0, 1.0);
  res += half4(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, 0.0);

  out_img[0].write(half4(res.r, 0.0, 0.0, 0.0), pos);
  // TODO(zhuowei): should it?
  if ((pos[0] & 1) == 0 && (pos[1] & 1) == 0) {
    pos /= 2;
    out_img[1].write(half4(res.g, 0.0, 0.0, 0.0), pos);
    out_img[2].write(half4(res.b, 0.0, 0.0, 0.0), pos);
  }
}
