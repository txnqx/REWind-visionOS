## Re.Wind

Memories move you forward.

Re.Wind is an immersive emotional storytelling prototype for Apple Vision Pro. It invites users to reconnect with the warmth of home and family through familiar childhood memories: preparing breakfast, decorating a Christmas tree and playing ball with Dad. Each story unfolds through gentle, guided movement, giving everyday actions a personal meaning.

<br>

### The problem

The project responds to a challenge described in its design research: children undergoing cancer treatment may experience fatigue, reduced movement and a sense of disconnection from everyday childhood experiences. Re.Wind explores whether the warmth of familiar places, family voices and meaningful routines can offer a more personal reason to move.

<br>

### Who it is designed for

The concept centres on children and adolescents undergoing cancer treatment who experience fatigue and low motivation. It also considers paediatric rehabilitation teams and physiotherapists as potential collaborators in defining appropriate movement goals. This is an academic design and interaction prototype, not a clinically validated rehabilitation tool; the intended audience does not establish suitability for headset use.

<br>

### What the experience does

Users begin in a bedroom and choose a memory from an album. Each memory opens into a guided activity with hand interactions, audio cues and progress feedback. After completing an activity, users can revisit another memory or return home.

| Memory | Interaction | Movement explored |
| --- | --- | --- |
| Breakfast in the Morning | Lift and tilt cereal and milk, then use a spoon in the bowl | Grasping, wrist rotation and controlled reaching |
| Decorating the Christmas Tree | Pick up, inspect and hang ornaments | Shoulder and arm reach |
| Playing Ball with Dad | Catch and return a ball with a virtual father figure | Reaching, grasping and releasing |

The home environment, family audio and memory videos give these movements an emotional context. Gentle transitions connect the activities, while visible prompts help users follow each task. The design aims to support familiarity, choice and motivation; these are design intentions rather than measured clinical outcomes.

<br>

### Technology and project status

- SwiftUI for the home interface, memory album and activity guidance.
- RealityKit for the immersive environment, props and character animation.
- ARKit hand tracking for direct hand interactions on Apple Vision Pro.
- Spatial audio for environmental sound and family voices.

Created by Tan Qian Hui for *Spatial Computing and AI, Semester 1 AY 2026/2027*.

This repository is a public source snapshot. The raw 3D models and derived lighting assets are supplied separately, subject to their licenses. The source snapshot compiles, but the immersive experience cannot run correctly until those assets are restored. See [asset setup](ASSET_SETUP.md) and the [asset manifest](ASSET_MANIFEST.json).

<br>

### Run the project

Requirements: a Mac with Xcode 26.6 or a compatible newer version, the visionOS SDK, visionOS 26.5 or later, and Git LFS for the included videos, images and audio. A physical Vision Pro is needed to assess hand tracking and device performance.

```sh
git lfs install
git clone https://github.com/txnqx/REWind-visionOS.git
cd REWind-visionOS
git lfs pull
open REWind_tanqianhui.xcodeproj
```

1. Restore the permitted assets following [ASSET_SETUP.md](ASSET_SETUP.md).
2. Select the REWind_tanqianhui scheme and an Apple Vision Pro simulator or paired headset.
3. For a physical headset, select your own development team in Signing & Capabilities and use a bundle identifier available to your team if necessary.

Prefer cloning with Git LFS over Download ZIP, which may contain pointer files instead of media. Neither method includes the separately licensed models.

<br>

### Project layout

- `REWind_tanqianhui/`: Swift source, interfaces, audio and memory videos.
- `REWind_tanqianhui.xcodeproj/`: Xcode project and shared scheme.
- `Packages/RealityKitContent/`: local Swift package and runtime asset location.

The snapshot excludes previous Git history, authoring files, intermediate exports, local diagnostics, credentials and Xcode user settings. Personal signing team settings have been cleared in this copy.

<br>

### Credits and review notes

Audio sources are listed in [AudioSources.json](REWind_tanqianhui/AudioSources.json) and [AudioCredits.txt](REWind_tanqianhui/AudioCredits.txt). Third-party assets retain their own terms. This repository does not grant a blanket open-source license to the code or assets.

Simulator smoothness does not establish headset performance. This prototype still requires device testing; successful compilation does not guarantee every interaction or frame rate is stable.
