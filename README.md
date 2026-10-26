# XeGTAO for Godot

Ground-truth ambient occlusion for Godot's Forward+ renderer: a port of
Intel's [XeGTAO](https://github.com/GameTechDev/XeGTAO) to Godot compute
shaders, running as a compositor effect. It replaces Godot's built-in SSAO
with sharper, steadier occlusion in creases and wherever objects meet.

## Requirements

- Godot 4.7 (tested on 4.7.1; needs compositor effects and `Texture2DRD`)
- The Forward+ renderer. Mobile and Compatibility can't run compute-based
  compositor effects; there the effect does nothing.

## Installation

The repository is the plugin folder itself. Put it at `addons/xe_gtao` in
your project, either as a git submodule:

```
git submodule add https://github.com/tomwor/godot-xegtao.git addons/xe_gtao
```

or by downloading it and copying its contents to `addons/xe_gtao`.

## Setup

1. Enable **XeGTAO** under Project Settings → Plugins. This registers the
   global shader texture `xe_gtao_texture`.
2. On your `WorldEnvironment` (or a `Camera3D`), create a `Compositor` and add
   an `XeGTAOEffect` to its effects.
3. Turn off SSAO in the environment, so the two don't overlap.
4. Pick an apply mode (below).

## Apply modes

**Materials** (default): the effect runs right after the depth prepass and
publishes its result as `xe_gtao_texture`. Shaders feed it into Godot's `AO`
output, so it darkens ambient light like proper AO and combines with any other
AO the material has:

```glsl
#include "res://addons/xe_gtao/xe_gtao.gdshaderinc"

void fragment() {
	// ...
	AO = xe_gtao(SCREEN_UV);  // or min(your_ao, xe_gtao(SCREEN_UV))
	AO_LIGHT_AFFECT = 0.0;    // 0 = ambient light only, 1 = direct light too
}
```

`StandardMaterial3D` can't read the texture; convert it to a ShaderMaterial
or use Multiply mode.

**Multiply**: the effect darkens the rendered image after transparent objects,
by `intensity`. It works with every material, but also darkens direct light,
emission and transparent surfaces in front of occluded areas.

## Settings

| Setting | Default | |
|---|---|---|
| `quality` | High | Slices × steps: Low 1×2, Medium 2×2, High 3×3, Ultra 9×3 |
| `radius` | 4.0 | Occlusion radius in world units |
| `falloff_range` | 0.615 | Share of the radius over which occluders fade out |
| `final_value_power` | 2.2 | Higher is darker |
| `denoise_passes` | 2 | 0 = off, 1 = sharp, 2 = medium, 3 = soft |
| `intensity` | 1.0 | Strength in Multiply mode |
| `temporal_noise` | off | Varies the sample pattern per frame; only useful with TAA |

`radius_multiplier`, `sample_distribution_power`, `thin_occluder_compensation`
and `depth_mip_sampling_offset` are XeGTAO's own tuning values.

## Notes

- In Materials mode, all materials share one AO texture, so use one 3D
  viewport per effect. Split-screen or picture-in-picture views would need
  their own handling.
- To switch the effect off at runtime, call `set_active(false)` rather than
  setting `enabled`, so materials stop using the last result.

## Licence

MIT, see `LICENSE`. The compute shaders are a port of XeGTAO, Copyright (C)
2016-2021 Intel Corporation, also under the MIT licence; see
`LICENSE.XeGTAO.txt`.
