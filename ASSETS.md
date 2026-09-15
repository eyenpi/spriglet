# Code and artwork license

The [MIT license](LICENSE) applies to the Spriglet code, documentation, original character concepts, editable Blender models and rigs, generated animation frames, app icon, original sound cues, and demo media included in this repository.

Sprout is an original character developed for this project. Its initial concept exploration used AI-generated imagery; the editable geometry, groom, materials, rig, and animation pipeline were built in Blender. The source `.blend` files have no external texture or add-on dependencies. The demo uses the same rendered frames and motion metadata as the app.

The [current app icon](art/app-icon/README.md) is an original AI-generated interpretation of Sprout, with rounded leaf ears, a cream face, and a welcoming wave. It was created with the built-in image generation tool and packaged with macOS `sips`. Its original image, exact prompt, approved master, and provenance hashes are included in `art/app-icon/`. It uses no third-party character artwork. The earlier Blender icon remains in `art/sprout/public-preview/` as historical source material.

The [Acorn Hopper and Moss Mouse models](art/candidates/README.md) are additional original characters under the same MIT license. Their concepts used AI-generated images; their editable meshes, materials, small rigs, shape keys, finite idle/locomotion/affection animations, sleep/wake transitions, and held sleep poses were authored in Blender without third-party 3D assets. The current refinement and original proof are both retained. Acorn Hopper is the only pet bundled by current source, using exact Blender PNGs and a [96-point normalized manifest](tools/CharacterAssets/README.md). Moss Mouse remains a future candidate; Sprout remains historical artwork and a compatibility fixture. There is no character selection UI.

The optional `greeting.wav` and `play.wav` chimes in `Sources/Spriglet/Resources/PetSounds/` are original synthesized tones created for Spriglet. They use deterministic sine partials and finite attack/decay envelopes, with no sampled recording or third-party sound asset. Their [generator](tools/EverydayServicesValidation/generate_chimes.py) and [provenance](tools/EverydayServicesValidation/chime-provenance.json) reproduce and identify the bundled files.

Blender, Xcode, Swift, GitHub Copilot, FFmpeg, and other authoring tools are not included in or relicensed by this repository. System fonts and SF Symbols are supplied by macOS at runtime; their source assets are not bundled here.

Keep the MIT copyright and license notice with copies or substantial portions of the code or artwork.
