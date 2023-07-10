## visionOS Simulator to ALVR / Meta Quest wireless streaming

Streams the visionOS Simulator to a Meta Quest wirelessly with [ALVR](https://github.com/alvr-org/ALVR) installed.

Tested with Xcode 15 beta 2 / macOS 14 beta 2 on Apple Silicon, Meta Quest (original).

### Usage

1. First, sideload [ALVR Nightly 2023.07.06](https://github.com/alvr-org/ALVR-nightly/releases/tag/v21.0.0-dev00%2Bnightly.2023.07.06) onto your Meta Quest.

   (This does not currently work with stable ALVR)

2. Start the visionOS Simulator from Xcode.

3. Download and extract [alvr_visionos_streaming.zip](https://github.com/zhuowei/VisionOSStereoScreenshots/releases).

4. Inject the streaming library into the Simulator:

   ```
   ./inject.sh
   # this resprings the simulator
   ```

5. Open ALVR on your Meta Quest: if all goes well, the visionOS interface should stream into your headset.

6. To configure streaming settings, you can use the ALVR dashboard (./alvr_dashboard). See [ALVR's documentation](https://github.com/alvr-org/ALVR) for more info.

7. You can't control the Simulator using the Quest's controllers yet (I'm looking into it).

   For now, use the computer's mouse/keyboard to control the Simulator.

   You probably want to enable a visible mouse cursor inside the Simulator (Settings -> Accessibility -> Pointer Control)

### How it works

This hooks CompositorService APIs inside backboardd so that it renders to our own textures instead of to the simulator screen. We then pass these textures to ALVR's server, which encodes them and streams them to the headset.

### What's next

- Enable passthrough
- Hook up Quest controllers / eye gaze?


### Credits

Thank you so much to [@ShinyQuagsire](https://mastodon.social/@ShinyQuagsire): he [released](https://mastodon.social/@ShinyQuagsire/110670442474420349) the [first ever tool](https://github.com/shinyquagsire23/XRGyroControls_OpenXR) for streaming the visionOS Simulator to a Quest headset (via wired Quest Link), and helped me figure out how to port this to work wirelessly using ALVR.

Thanks to [@JJTech](https://infosec.exchange/@jjtech) and [@keithahern](https://mastodon.social/@keithahern) for figuring out how the visionOS Simulator handles input.

Thanks to [the ALVR developers](https://github.com/alvr-org/ALVR) for making an amazing cross-platform VR streaming system.
