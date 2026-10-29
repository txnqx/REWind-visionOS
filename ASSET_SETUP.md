# Runtime asset setup

The public repository intentionally omits raw 3D models and derived lighting textures whose public redistribution rights have not been established. Some models, including the house and Christmas tree, were purchased separately. A purchase or free download does not itself establish permission to publish the source asset.

The Swift implementation is unchanged. To run the complete immersive experience, an authorized reviewer needs the matching assets from the project owner under the applicable licenses.

1. Obtain an authorized copy of the required asset set from the owner. Do not substitute arbitrary models: the code references named entities, markers, and rig joints.
2. Place each file at the repository-relative path listed in `ASSET_MANIFEST.json`.
3. Open `REWind_tanqianhui.xcodeproj` and select the `REWind_tanqianhui` scheme.
4. Build for Apple Vision Pro Simulator, or choose your own signing team for a physical headset.

The placeholder `AssetSetup.txt` ensures that the Swift package has a resource bundle before the licensed assets are restored. The source-only build is for code review; missing models prevent the immersive experience from loading.

The omitted file patterns are ignored by Git to prevent accidental public upload. Confirm the exact asset license before changing those rules. This public snapshot does not include Blender authoring files or grant redistribution rights for third-party content.
