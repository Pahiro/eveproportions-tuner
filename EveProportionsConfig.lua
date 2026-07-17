-- Set false to disable CNS/custom-outfit-specific tracking.
-- Vanilla outfits and initial save/level loading remain enabled.
return {
    EnableCNSTracking = true,
    DebugLogging = false,

    -- In-game adjustment UI (sliders for breast/hip/waist/thigh/etc.).
    -- Toggle with TunerKey; values persist to Scripts/TunerValues.lua.
    --
    -- While the panel is open:
    --   Left/Right arrows  nudge the last-touched slider by FineTuneStep
    --   1..9               load preset slot     Shift+1..9  save preset slot
    --   0                  bind current values to the worn outfit
    --   Shift+0            remove the worn outfit's binding
    -- Presets are stored in Scripts/TunerPresets.lua, outfit bindings in
    -- Scripts/TunerOutfits.lua. A bound outfit applies its own values
    -- whenever you wear it; edits made while wearing it save to the binding.
    EnableTuner = true,
    TunerKey = "F7",
    FineTuneStep = 0.01,
}
