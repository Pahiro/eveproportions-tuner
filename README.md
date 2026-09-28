# EveProportions — In-Game Tuner (contribution)

Adds an in-game adjustment panel to EveProportions: press **F7** and the
`WBP_EveProportions` widget that already ships in the mod's pak (currently
dormant — pure layout, no blueprint logic) appears with 14 working sliders,
8 of them cooked into the pak and 6 (Thigh/Calf/Ankle Width, Waist Line,
Bust Height, Bust Weight) built at runtime and grafted into the same panel. Values apply live to the
post-process AnimBP, persist across sessions, and re-apply automatically on
outfit changes. **No pak changes are needed** — everything runs through
UE4SS Lua against the existing assets.

<img width="232" height="436" alt="image" src="https://github.com/user-attachments/assets/26fca8a7-389f-4f05-bc0e-0987b5366b12" />

While the panel is open:

| Key | Action |
|---|---|
| Up/Down arrows | pick which slider Left/Right fine-tunes (marked `>` in its label) |
| Left/Right arrows | fine-tune the selected slider (`FineTuneStep`, or that row's own step for the ones measured in cm/degrees) |
| Shift+Left/Right | fine-tune by 10x that step |
| 1–9 / Shift+1–9 | load / save preset slot (`TunerPresets.lua`) |
| 0 / Shift+0 | bind / unbind current values to the worn outfit (`TunerOutfits.lua`) |
| PassthroughKey (`F8`) | toggle native game input through to other mods (e.g. DekCNS hotkeys) while the panel is open |

**Bust Height** and **Bust Weight** are the two sliders that are not size
multipliers. Every other slider multiplies what the mod author already wrote
into a bone, which can only ever make the bust bigger or smaller — the
authored Translation on those nodes is `(0, 0, 0)`, and no multiplier over
zero will move anything. These two add instead: Bust Height is a signed
offset in centimetres (−8 … +8, 0 = untouched) that slides the bust up or
down the chest, and Bust Weight is a signed tilt in degrees (−30 … +30) that
tips it down from its root the way mass would, reading as sag rather than as
a shorter chest. Both act on `B_Dm_L/R_Breast_Point`, the same pair the
Breast size slider drives, and stack with it rather than fighting it. Their
labels carry the unit so a `-2.50 cm` row doesn't read as a multiplier
driven far out of range, and their arrow-key step is 0.1 cm / 0.5° rather
than `FineTuneStep` (0.01 cm a press would be 800 presses to cross the
range). Reset returns them to 0, not to 1.

Both offsets are written in **component space**, which is what makes them
mirror correctly: left and right move down for the same −Z and tip the same
way for the same rotation, where a bone-space delta would send the two sides
opposite ways. A ModifyBone node ignores a channel whose mode is `Ignore`,
so the tuner switches Translation/Rotation to `Additive` while an offset is
non-zero — but only where the author left that channel on `Ignore`, i.e.
where there's nothing of theirs to trample; back at zero it restores the
authored mode and space. Bust Height's axis isn't in doubt (component space
is Z-up). Bust Weight's is: a droop is a rotation about the body's
left-right axis, and whether that's component-space Y (Pitch) or X (Roll)
depends on which way this skeleton's mesh faces in component space. Pitch is
the assumption; if Bust Weight swings the bust sideways instead of tipping
it down, change `axis = "pitch"` to `"roll"` in the `OFFSET` table — that
exhausts the options, and Ctrl+R hot-reloads the file.

The four girth sliders scale only the axes that make a limb thinner, not the
length — the original groups scale all three axes and translation together,
which also shortens the limb and drags the joint inward. `ThighGirth` and
`AnkleGirth` share bones with `Thigh`/`Legs`, so per-bone multipliers are
accumulated across every group a bone belongs to rather than the last one
written winning.

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
- Groups named in `OFFSET` opt out of that entirely: their slider value is a
  delta added to the node's Translation or Rotation in centimetres or
  degrees, neutral at 0.0, accumulated per bone alongside the multipliers so
  a bone driven by both (the breast bones are) gets scaled and then moved.
  They're skipped by the multiplier pass — running a slider that rests at
  0.0 through it would multiply its bones' scale by zero.
- Slider→bone grouping lives in the `GROUPS` table at the top of the tuner
  script — trivially editable if you'd group them differently. `RANGE`,
  `NEUTRAL`, `STEP` and `UNIT` beside it decide how a row behaves in the
  panel; a group listed in `RUNTIME_GROUPS` has no cooked widgets and gets
  its row built and grafted in at load.

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
- SB hides the **hardware cursor** no matter how often `bShowMouseCursor` is
  reasserted — mouse input works over the panel, but the pointer is
  invisible. DekCNS solved this with a self-ticking virtual-cursor widget
  (`WB_MouseCursor`: a `HitTestInvisible` image following
  `GetMousePositionScaledByDPI` every frame), so if CNS is installed the
  tuner spawns one of those above the panel and removes it on hide. Without
  CNS the panel still works with the invisible pointer.
- On Lua hot-reload, stale widget instances are purged from the viewport
  before creating a new one.
- `DumpBoneInventory` now also prints each node's `TransMode`/`RotMode`
  alongside the spaces — which channels the ABP actually drives is exactly
  what decides whether a translation or rotation written from Lua reaches
  the pose at all.
- Cloning a Slot's properties has to be read into plain Lua numbers and
  written back field-by-field (`slot.Padding.Top = ...`); assigning the
  whole struct, or trusting a `SetPadding`/`SetSize`-style setter call that
  didn't throw, can both silently no-op. And the source widget for that
  capture matters: this panel wraps each cooked slider in its own `SizeBox`
  (`Label_X` sits directly in the row `VerticalBox`, but `Slider_X` sits
  inside `SB_X`, which is the actual `VerticalBox` child) — the row-to-row
  gap lives on the `SizeBox`'s slot, not the slider's own, so runtime rows
  cloned from the slider directly came out with zero spacing until the
  capture read from the wrapper instead.

Tested on the Steam release (UE4SS 3.0.1, also under Proton). Feel free to
use, adapt, or rewrite any of this for the mod — no credit needed.
