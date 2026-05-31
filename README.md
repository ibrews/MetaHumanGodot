# MetaHuman → Godot Look-Dev

A real-time **look-development tool for MetaHuman characters in Godot 4.6** — dial
in skin, lighting, and hair with live sliders and an orbit camera, then save the
look to JSON. Built around the [MatMADNESS](https://github.com/RustyRoboticsBV/GodotStandardLightShader)
HumanShader (MIT) for proper subsurface-scattering skin.

> **Bring your own MetaHuman.** This repo ships the *tooling* — the Godot project,
>
> _(A hero screenshot lives in `docs/` once added — rendered MetaHuman output is
> permitted under Epic's license even where shipping the asset is not.)_
> the look-dev UI, the skin/eye/hair shaders. It does **not** include any
> MetaHuman character assets. You supply your own export (see below). Without one,
> the tool launches with a neutral placeholder so you can still explore the
> lighting and skin sliders.

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
| Hide / show UI | **H** key (or *Hide UI* button) |
| Screenshot | bottom-right **Screenshot** → `out/lookdev_shot_<ts>.png` |
| Turntable movie | bottom-right **Capture movie** → `out/lookdev_movie_<ts>.mp4` |

Every slider has a **numeric entry box** (type values beyond the slider range for
extremes). **Save settings** writes `look_settings.json` (next to the project and
to `user://`); it auto-loads on the next launch.

## Bring your own MetaHuman

Export your MetaHuman from Unreal Engine and assemble it into a single
`character.glb` placed at the project root (`godot_project/character.glb`), with
its baked textures alongside. The expected mesh/surface layout (face surfaces,
body, grooms, eye spheres) and texture names are documented in
[`docs/PIPELINE.md`](docs/PIPELINE.md). *(The full, automated UE→Blender→Godot
export pipeline is a separate offering — see below.)*

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
