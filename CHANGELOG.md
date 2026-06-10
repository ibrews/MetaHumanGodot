# Changelog

All notable changes to **MetaHuman → Godot Look-Dev** are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/); this project
is a developer tool, so versions are milestones rather than a strict semver API.

## [0.3.0] — 2026-06-09

The "body in motion" release. v0.2.0 rigged both characters with a single body
idle; v0.3.0 adds a library of full-body motions that actually stand on the
floor, plus UI organization and skin-shading fixes.

### Added
- **Body-animation clip dropdown** — six Mixamo motions retargeted onto the
  MetaHuman rig via UE 5.7's IK Retargeter (*Idle, Sway, Walk, Turn, Wave,
  HappyIdle*) alongside the hand-authored procedural idle, which stays the
  default clip. Switching clips crossfades live; body animation still starts
  OFF so the character stands at rest on launch.
- **Planted feet** across the motion library: per-clip foot grounding to the
  scene floor, a foot-flatten that undoes the retarget's toe-down ankle bias,
  and analytic two-bone **foot-lock IK** on the stationary clips so the stance
  feet no longer skate while the body sways (Walk/Turn keep their natural
  stepping).
- **Collapsible panel sections** — the long control list now folds into labeled
  sections (CAMERA and PRESETS open by default; click a header to expand).
- **`hairshadow` lighting preset** (both characters) — strong key, low fill,
  full shadow strength, hair-rake on: the hair throws a crisp, readable shadow
  across the forehead. Presets can now carry the hair-rake state.
- Animation QA hooks: `RELEASE_FOOTDBG` prints the live skeleton's foot/pelvis
  heights in-tool; `scenes/diag_feet.gd` + `scenes/diag_footlock.gd` measure
  per-clip foot height and world drift headlessly.

### Fixed
- **Skin normal-map convention** — the specular/`NORMAL_MAP` path now flips the
  green channel to match the diffuse path (MetaHuman normal maps are
  DirectX-convention), so skin relief lights consistently.
- Neck-through-collar clipping during body animation (a casualty of the old
  un-grounded walk).

## [0.2.0] — 2026-06-08

The "two characters, fully rigged" release. v0.1.0 shipped a single static-posed
male face; v0.2.0 adds a second MetaHuman, real rigs on both, a per-character
lighting library, and a pile of look-dev and animation polish.

### Added
- **Second built-in MetaHuman** (a female face) and a live **character toggle**
  (press **C**) that re-wires skin / eyes / hair / hidden slots per character.
- **Both characters fully rigged** — body idle, bone-driven eye gaze, and a baked
  ARKit blendshape set on each (no more static-posed demo).
- **ARKit blendshape panel shown by default** (52 named shapes; still toggleable
  with **B**).
- **Per-character preset + lighting library** — ~15 looks per character
  (*moonlight, studio, beauty, clinical, noir, sunset, teal_orange, golden_hour,
  rembrandt, cyberpunk, high_key, candlelight, split, overcast, emerald*) plus a
  **Cycle light colours** demo toggle that hue-shifts the whole rig non-destructively.
- **Load custom character** — a runtime GLB/GLTF loader (per-mesh cm/m
  unit-normalize, best-effort skin/eye/hair wiring) for any model, MetaHuman or not.
- Opt-in **hair rake** light that skims the hairline so the hair casts a crisp
  shadow on the forehead.
- Naturalistic **eye gaze** (look-at-camera + saccadic darts + blinks), a face
  **emote** (now with a nose-scrunch pose), a subtle **leg idle**, an **intro
  reveal**, a **hero** ping-pong camera, and the auto-turntable.
- Grooms (hair / beard / brows) **attach to the head bone**, so they follow head
  motion during the body idle.
- A pipeline **regression harness** (`verify_pipeline`) — excluded from builds.

### Changed
- **Bust↔body collar seam** is now closed at runtime via a **LeaderPose**
  emulation (the face skeleton's shared neck/clavicle/bust bones are driven from
  the animated body skeleton through global-pose deltas), with a small
  per-character outfit "inflate" as a complementary anti-poke cover.
- Eye look refined — natural iris size and calmer sclera/sheen (fixed a milky,
  over-bright read on the female face's moonlight preset).
- Packed-PCK asset loading now tries the resource system first, so a build is a
  clean **exe + pck** (no loose files dumped beside the executable).
- Lowered the front-light shadow normal-bias so the thin hair contact shadow lands
  on the face; "Shadow strength" also drives screen-space AO.

### Fixed
- Female face rendering flat-gray (wire the MetaHuman face by **surface index**,
  not material name — surface 0 is mislabeled but is the main skin).
- A compounding **leg-idle** bug that spun the calves around.
- Preset loading from inside a packed build (read `res://` directly rather than via
  a path that doesn't resolve in a PCK).

## [0.1.0] — 2026-05-31

Initial public release: a single-character (male face) real-time look-dev &
turntable tool for a MetaHuman in stock Godot 4.6 (Forward+) — MatMADNESS SSS skin,
3-point UE-matched lighting, hair/eye controls, orbit + hero cameras, headless
still/turntable capture, and a Windows demo build. Bring-your-own-MetaHuman; no
character assets in the repo.
