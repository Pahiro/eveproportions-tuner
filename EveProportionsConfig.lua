-- Set false to disable CNS/custom-outfit-specific tracking.
-- Vanilla outfits and initial save/level loading remain enabled.
return {
    EnableCNSTracking = true,
    DebugLogging = false,

    -- One-shot: log every Transform (Modify) Bone node the ABP ships, its
    -- authored transform and the slider group driving it, then continue
    -- normally. Set true, load a save, read UE4SS.log, set false again.
    -- Useful when a slider does not do what its name suggests, or to check
    -- whether a bone someone asked for already has a node.
    -- Also prints the panel's widget tree.
    DumpBoneInventory = false,

    -- In-game adjustment UI (sliders for breast/hip/waist/thigh/etc.).
    -- Toggle with TunerKey; values persist to Scripts/TunerValues.lua.
    --
    -- While the panel is open:
    --   Up/Down arrows     pick which slider to fine-adjust (marked "> ")
    --   Left/Right arrows  nudge the selected slider by FineTuneStep
    --   Shift+Left/Right   nudge by 10x that (held-arrow repeat was tried
    --                      and dropped -- the panel's input mode never lets
    --                      the game see the key as held, so this is the
    --                      fast-adjust path instead)
    --   1..9               load preset slot     Shift+1..9  save preset slot
    --   0                  bind current values to the worn outfit
    --   Shift+0            remove the worn outfit's binding
    --   PassthroughKey     toggle game-input passthrough (see below)
    -- Presets are stored in Scripts/TunerPresets.lua, outfit bindings in
    -- Scripts/TunerOutfits.lua. A bound outfit applies its own values
    -- whenever you wear it; edits made while wearing it save to the binding.
    --
    -- Our panel normally blocks ALL native game input while open (so a
    -- slider drag can't also swing the camera or trigger an attack) -- but
    -- that also blocks other mods' native-input shortcuts, e.g. DekCNS's
    -- camera-drag and its own hotkeys (N to open, WASDQE to pan). Hit
    -- PassthroughKey to let native input through again so those work
    -- alongside our panel; hit it again to go back to safe slider-dragging.
    -- Resets to off whenever the panel is closed.
    EnableTuner = true,
    TunerKey = "F7",
    PassthroughKey = "F8",
    FineTuneStep = 0.01,
}
