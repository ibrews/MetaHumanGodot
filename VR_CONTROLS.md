# MetaHumanGodot — VR build controls

A stereo VR viewer for the MetaHumanGodot character, running on **Godot 4.7-beta3**
(stock Godot 4.6 cannot do stereo Forward+ — the XR multiview path was fixed in 4.7).
Reuses the desktop release tool's custom skin/eye/hair shaders, LeaderPose rig, and
lighting unchanged; `scenes/vr.gd` instances `release.tscn` and adds the XR viewer.

Requires an OpenXR runtime + headset (tested: Quest 3S via Air Link / Oculus runtime,
RTX 5090). With no headset it falls back to a flat desktop window.

## Controls

| Action | Keyboard | Touch controllers |
|---|---|---|
| Fly (gaze-relative) | `W` `A` `S` `D` | left thumbstick |
| Up / down | `Q` / `E` | right thumbstick Y |
| Smooth turn | mouse X (`M` toggles mouse-look) | right thumbstick X |
| Boost / brake | `Shift` / — | right grip / left grip |
| Swap Guy ↔ Gal | `Space` | `A` |
| Cycle Mixamo clip | `Tab` | right thumbstick click |
| Lighting demo (hue cycle) | `F` | `B` |
| Face animation | `G` | `X` |
| Body idle | `H` | `Y` |
| Quality: Low/Med/High/Epic | `1` `2` `3` `4` | left menu button (cycles) |
| Toggle auto-adaptive quality | `0` | — |

Mixamo clips: `BodyIdle_Procedural → Idle → Sway → Walk → Turn → Wave → HappyIdle`.

On by default (the 2D menu can't composite into the HMD): body idle, face animation,
animated lighting, hairline-shadow rake.

## Quality / performance

Four tiers scale SSAA supersample, MSAA, and foveation together:

| Tier | SSAA | MSAA | Foveation |
|---|---|---|---|
| Low | 0.85× | 2× | aggressive |
| Medium | 1.0× | 4× | medium |
| High | 1.5× | 8× | light |
| Epic | 2.0× | 8× | off |

**Auto-adaptive** (default on) starts at Epic and drops a tier if the framerate can't
hold the 72 Hz floor, climbing back when there's headroom. Turn it off with `0` and pick
a fixed tier with `1`–`4`.

## Launch / env overrides

```
Godot_v4.7-beta3 --path . res://scenes/vr.tscn
```

| Env | Effect |
|---|---|
| `VR_QUALITY=low\|medium\|high\|epic` | starting tier |
| `VR_ADAPTIVE=0` | disable auto-adaptive |
| `VR_SS=<n>` | force a raw supersample (disables adaptive) |
| `VR_DEADZONE=<n>` | thumbstick radial deadzone (default 0.25) |
| `VR_MENU=1` | experimental worldspace menu (right-controller ray + trigger) |
| `RELEASE_CHAR=her` | start on Gal |

Thumbsticks auto-recenter (learn their rest center) to cancel hardware drift; a radial
deadzone + square response curve keep a resting thumb from moving you.

## Worldspace menu (experimental, `VR_MENU=1`)

Reparents the desktop tool's real UI into a SubViewport shown on a floating panel; point
the right controller and pull the trigger to click. First-pass — placement/aim may need
tuning.
