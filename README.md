# EveProportions — In-Game Tuner (contribution)

Adds an in-game adjustment panel to EveProportions: press **F7** and the
`WBP_EveProportions` widget that already ships in the mod's pak (currently
dormant — pure layout, no blueprint logic) appears with 8 working sliders.
Values apply live to the post-process AnimBP, persist across sessions, and
re-apply automatically on outfit changes. **No pak changes are needed** —
everything runs through UE4SS Lua against the existing assets.

## Files

| File | What it is |
|---|---|
| `EveProportionsTuner.lua` | New script — all tuner logic, self-contained module. |
| `main.lua.patch` | 5-line diff against the original `main.lua` (3 integration points, see below). |
| `main.lua` | Full patched copy, if you prefer that over applying the patch. |
| `EveProportionsConfig.lua` | Config with two new keys: `EnableTuner` (default `true`) and `TunerKey` (default `"F7"`). |

`Scripts/TunerValues.lua` is created at runtime next to the scripts to store
the user's slider values (safe to delete; regenerates with defaults).

## Integration points in main.lua

1. Top of file: `local Tuner = nil; pcall(function() Tuner = require("EveProportionsTuner") end)` —
   pcall-guarded, so main.lua behaves exactly as before if the tuner file is
   removed or `EnableTuner = false`.
2. In `refreshAnimation`, the "already active" early-return: `Tuner.ApplyTo(active)`.
3. In `refreshAnimation`, after `SetAnimationMode` recreates the instance: `Tuner.ApplyTo(after)`.

These two `ApplyTo` calls re-stamp the saved slider values onto fresh
post-process instances at your existing refresh boundaries. A
`NotifyOnNewObject` on the ABP class catches instances created outside those
paths (e.g. level load). Deliberately **not** a polling loop — a 1 s
`FindAllOf` watcher caused a visible once-per-second hitch in cinematics.

## How the sliders drive the ABP (implementation notes)

- Each slider is a **size multiplier**: 1.0 = your authored shape, below 1.0
  moves toward vanilla, above exaggerates. Since the authored bone scales
  shrink (0.7–0.9), this is implemented as `Scale' = authored * value`
  (Translation/Rotation likewise), writing directly into the
  `FAnimNode_ModifyBone` struct properties. The `B_<bone>` alpha floats can't
  be used for exaggeration — anim blend weights clamp at 1.0.
- The node struct properties are discovered at runtime by iterating class
  properties and reading `BoneToModify.BoneName`, so the script survives you
  adding/renaming nodes without a mapping update. Baselines are read from the
  **CDO**, not the instance (instances are polluted after Lua hot-reload).
- Slider→bone grouping lives in the `GROUPS` table at the top of the tuner
  script — trivially editable if you'd group them differently.

## UE4SS gotchas baked into the script (the hard-won stuff)

- Keybind callbacks are **not** on the game thread — everything hops via
  `ExecuteInGameThread` first, otherwise the game hard-crashes.
- UE4SS `LoadAsset` fails for LogicMods assets (no AssetRegistry patch); the
  widget class is loaded via `AssetRegistryHelpers:GetAsset()` like
  BPModLoader does.
- `USlider` drags never write back the `Value` UPROPERTY — live values must
  come from `GetValue()`.
- The game keeps stealing input mode while the panel is open, so
  `SetInputMode_UIOnlyEx` is re-asserted every poll tick (80 ms, only while
  the panel is visible; zero background cost when hidden).
- On Lua hot-reload, stale widget instances are purged from the viewport
  before creating a new one.

Tested on the Steam release (UE4SS 3.0.1, also under Proton). Feel free to
use, adapt, or rewrite any of this for the mod — no credit needed.
