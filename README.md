# MetaHuman → Godot Look-Dev

> ⚠️ **Not an Epic Games product.** This is an independent, community tool made by
> Agile Lens. It is **not** created, published, endorsed, sponsored by, or
> affiliated with Epic Games, and is **not** official MetaHuman or Unreal Engine
> software. The repository name "MetaHumanGodot" describes what the tool *works
> with* — it does not imply any official Epic support. "MetaHuman", "Unreal", and
> "Unreal Engine" are trademarks of Epic Games, Inc. See [Licensing](#licensing).

A real-time **look-development tool for MetaHuman characters in Godot 4.6** — dial
in skin, lighting, and hair with live sliders and an orbit camera, then save the
look to JSON. Built around the [MatMADNESS](https://github.com/RustyRoboticsBV/GodotStandardLightShader)
HumanShader (MIT) for proper subsurface-scattering skin.

![Hero portrait](docs/hero.png)

> **Bring your own MetaHuman.** This repo ships the *tooling* — the Godot project,
> the look-dev UI, and the skin/eye/hair shaders. It does **not** include any
> MetaHuman character assets. You supply your own export (see
> [Bring your own MetaHuman](#bring-your-own-metahuman)). Without one, the tool
> launches with a neutral placeholder so you can still explore the lighting and
> skin sliders.

## Download

A prebuilt **Windows demo** (with a sample MetaHuman baked in) is on the
[**Releases**](../../releases) page — download `MetaHumanGodot-win64.zip`, unzip,
and run `MetaHumanGodot.exe`. Or build/run from source (below).

| The interactive tool | Live expressions |
| --- | --- |
| ![UI](docs/ui.png) | ![Smile](docs/smile.png) |

## Features

- **Live skin look-dev** — MatMADNESS subsurface-scattering skin with ~30 exposed
  uniforms (normal/SSS/smoothness, micro-detail, scatter, roughness, specular, AO…),
  each on a slider **and** a type-in box (values can exceed the slider range).
- **3-point lighting + environment** — key / fill / rim (energy, color, yaw, pitch),
  catchlight, ambient/exposure/tonemap/contrast/saturation, backdrop tint.
- **Hair** — scalp / beard / eyebrow colors, strand density, root darkening, backing shell.
- **Orbit camera** + **auto-turntable** (spins the model), a **hero camera**
  (wide→close push-in), and **Play animation** (face emote + body idle) — all
  combinable. Supersampled **screenshot** and **turntable-movie** capture.
- **Save / load** the whole look to `look_settings.json`.

## Quick start

1. Install **Godot 4.6** (stable, Forward+).
2. Launch the viewer:
   - **Windows:** double-click `run_lookdev.bat` (set the `GODOT` env var to your
     Godot binary if it isn't on `PATH`), **or**
   - **Any OS:** from a terminal —
     ```
     <godot-binary> --path <path-to-this-folder> scenes/look_dev.tscn --resolution 1366x860
     ```
     Use an **absolute** project path (a bare relative `--path godot_project`
     fails with *"Invalid project path specified"*).
3. With no `character.glb` present you'll see a placeholder bust — the skin and
   lighting sliders still work. Add your own MetaHuman (next section) for the full rig.

> Do **not** launch with `--headless` or `--write-movie` — this is an interactive
> GPU tool.

## Controls

| Action | Input |
| --- | --- |
| Orbit | **LMB**-drag |
| Zoom | **mouse wheel** |
| Pan | **RMB / MMB**-drag |
| Reset camera | **Reset cam** button |
| Spin the model | **Auto-turntable** toggle |
| Play face + body animation | **Play animation** toggle |
| Hero camera (wide → close, loops) | **Hero camera** toggle |
| Resize / collapse the panel | drag the right-edge **handle**, or the **‹‹** button |
| Reset one setting to default | the small **↺** next to it |
| Hide / show UI | **H** key (or *Hide UI* button) |
| Credits / legal | **Credits / Legal** button (top-right) |
| Screenshot | bottom-right **Screenshot** |
| Turntable movie | bottom-right **Capture movie** |

The turntable, animation, and hero camera can all run at once. Every slider has a
**numeric entry box** (type values beyond the slider range for extremes).
**Save settings** writes `look_settings.json` (next to the app and to `user://`);
it auto-loads on the next launch.

## Bring your own MetaHuman

Export your MetaHuman from Unreal Engine and assemble it into a single
`character.glb` placed at the project root (`character.glb`), with its baked
textures alongside (head/body BaseColor, Normal, SRMF, Scatter; eye iris/sclera;
groom coverage atlases). The viewer auto-wires the face by **surface index**
(Blender's glTF export shuffles material names), the body skin, grooms, and eyes.
*(The full, automated UE → Blender → Godot export pipeline — which produces that
`character.glb` for you, including ARKit morph targets — is a separate offering;
see below.)*

## Licensing

- **This tool's code + shaders:** see `LICENSE` (MatMADNESS shaders are MIT).
- **MetaHuman assets are NOT included and must not be added to this repo.** Epic's
  MetaHuman license (June 2025+) permits MetaHumans in non-Unreal engines for
  users under $1M USD revenue, with restrictions (notably **no AI-model training**).
  When you supply your own MetaHuman, you do so under **your** Epic license —
  read [metahuman.com/license](https://www.metahuman.com/license) and the
  [Unreal Engine EULA](https://www.unrealengine.com/eula/unreal). This note is
  not legal advice.

## The full pipeline

This viewer is the open, free slice. The complete **UE → Blender → Godot
automation** (one-shot export of the face/body/grooms, surface remapping, shader
wiring, ARKit/animation setup) is a separate, more involved offering. If you want
the turnkey workflow rather than hand-assembling `character.glb`, that's where to
look.
