# EveProportions — In-Game Tuner (contribution)

Adds an in-game adjustment panel to EveProportions: press **F7** and the
`WBP_EveProportions` widget that already ships in the mod's pak (currently
dormant — pure layout, no blueprint logic) appears with 8 working sliders.
Values apply live to the post-process AnimBP, persist across sessions, and
re-apply automatically on outfit changes. **No pak changes are needed** —
everything runs through UE4SS Lua against the existing assets.

<img width="232" height="436" alt="image" src="https://github.com/user-attachments/assets/26fca8a7-389f-4f05-bc0e-0987b5366b12" />

While the panel is open:

| Key | Action |
|---|---|
| Left/Right arrows | fine-tune the last-touched slider (step configurable) |
| 1–9 / Shift+1–9 | load / save preset slot (`TunerPresets.lua`) |
| 0 / Shift+0 | bind / unbind current values to the worn outfit (`TunerOutfits.lua`) |

Outfit bindings are keyed by the body mesh asset path (works for CNS custom
outfits too): a bound outfit adopts its own values whenever it's equipped,
and switching to an unbound outfit restores the saved defaults. A shortcut
legend is appended to the panel at runtime (a `TextBlock` constructed via
`StaticConstructObject` and added to the widget's VBox — again, no pak edit).

Slider labels are renamed at runtime to match their observed in-game effect
(the `DISPLAY` map), and `B_Bip001_Pelvis` was dropped from the Hip group:
scaling it scales the entire skeleton from the pelvis origin (a duplicate of
Size that sinks the feet into the ground). Without it, the group's `Hip_Reg`
bones turn out to be a clean butt-size control.

## Files

| File | What it is |
|---|---|
| `EveProportionsTuner.lua` | New script — all tuner logic, self-contained module. |
| `main.lua.patch` | 5-line diff against the original `main.lua` (3 integration points, see below). |
| `main.lua` | Full patched copy, if you prefer that over applying the patch. |
| `EveProportionsConfig.lua` | Config with two new keys: `EnableTuner` (default `true`) and `TunerKey` (default `"F7"`). |
| `UE4SS_Signatures/FText_Constructor.lua` | AOB signature for the FText constructor — copy to `ue4ss/UE4SS_Signatures/`. See below. |

`Scripts/TunerValues.lua`, `Scripts/TunerPresets.lua`, and
`Scripts/TunerOutfits.lua` are created at runtime next to the scripts to
store the user's values, presets, and outfit bindings (all safe to delete;
they regenerate with defaults).

## If pressing F7 crashes the game (FText signature)

UE4SS finds the native `FText` constructor by AOB scan, and on Stellar Blade
the stock UE4SS 3.0.1 scan **fails** — `UE4SS.log` shows:

```
[PS] Failed to find FText::FText(FString&&): expected at least one value
[PS] You can supply your own AOB in 'UE4SS_Signatures/FText_Constructor.lua'
```

Without it, constructing an `FText` from Lua (the tuner does this for slider
labels) can crash the game the moment the panel opens. Fix: copy
`UE4SS_Signatures/FText_Constructor.lua` from this repo into
`SB/Binaries/Win64/ue4ss/UE4SS_Signatures/` (create the folder if needed).
When it works, `UE4SS.log` shows `FText::FText address: ... <- Lua Script`
instead of the failure.

As of v1.1.1 the tuner also routes text through a helper that falls back to
`KismetTextLibrary::Conv_StringToText` (a plain UFunction call, no scan
needed) when `FText()` fails cleanly — but the signature file is the reliable
fix, so install it either way.

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
  come from `GetValue()`. The reverse also bites: `SetValue()` on a live
  widget doesn't reliably move the Slate handle, so programmatic writes
  (reset, preset load) verify with a readback and rebuild the widget on
  mismatch — construction initializes Slate from values set before
  `AddToViewport`, which always works.
- The game keeps stealing input mode while the panel is open, so
  `SetInputMode_UIOnlyEx` is re-asserted every poll tick (80 ms, only while
  the panel is visible; zero background cost when hidden).
- On Lua hot-reload, stale widget instances are purged from the viewport
  before creating a new one.

Tested on the Steam release (UE4SS 3.0.1, also under Proton). Feel free to
use, adapt, or rewrite any of this for the mod — no credit needed.
