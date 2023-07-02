Take stereoscopic (3D) screenshots in the visionOS simulator.

![example screenshot](https://github.com/zhuowei/VisionOSStereoScreenshots/assets/704768/c9945210-eaf8-4a59-90da-5a0787b25598)

An example screenshot from the visionOS simulator in side-by-side stereo.

## Setup

### Non-Metal Immersive apps

Disable SIP

```
./build.sh
./inject.sh
# this resprings the simulator
```

### Metal Immersive (CompositorService) apps

TODO

## Usage

### Non-Metal Immersive apps

```
./screenshot.sh
```

Screenshots are saved in `/tmp/visionos_stereo_screenshot_{time}.png`.

### How it works

This hooks CompositorService to give backboardd an extra right eye view to render.
