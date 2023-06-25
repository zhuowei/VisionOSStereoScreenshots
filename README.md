Take stereoscopic (3D) screenshots in the visionOS simulator.

## Setup

### Non-Metal Immersive apps

Disable SIP

```
./build.sh
./inject.sh
# this resprings the simulator
```

### Metal Immersive (CompositorService) apps

```
./build.sh
```

Link against libvisionos_stereo_screenshots.dylib.

## Usage

### Non-Metal Immersive apps

```
./screenshot.sh
```

Screenshots are saved in `/tmp/visionos_stereo_screenshots/screenshot_{time}.png`.

### Metal Immersive apps

Send SIGUSR1 to your app, or call visionos_stereo_screenshots_take_screenshot(@"/path/to/screenshot");

### How it works

This hooks CompositorService to add two extra output views for cp_drawable_t, which causes the app to render two extra views, one for each eye.
