-- EveProportionsTuner: runtime adjustment UI for the EveProportions post-process ABP.
--
-- The pak ships WBP_EveProportions (sliders + Reset/Hide buttons) with no
-- blueprint logic of its own. This module creates that widget on demand,
-- polls its sliders, and writes the values into the ABP instance's
-- Transform (Modify) Bone nodes via reflection. The ABP exposes per-bone
-- float variables named B_<bone> (node Alphas, clamped 0..1 by the engine)
-- and the FAnimNode_ModifyBone structs as separate class properties, which
-- are discovered at runtime via BoneToModify.BoneName.
--
-- Slider semantics: value is a size multiplier on the authored offsets.
--   Scale'       = authored * value   (1.0 = authored; up = bigger)
--   Translation' = authored * value
--   Rotation'    = authored * value
-- Values persist to TunerValues.lua next to this script.
--
-- Keys while the panel is open:
--   Left/Right arrows   nudge the last-touched slider by FineTuneStep
--   1..9                load preset slot        Shift+1..9  save preset slot
--   0                   bind current values to the worn outfit
--   Shift+0             remove the worn outfit's binding
-- Presets live in TunerPresets.lua; outfit bindings (keyed by the body
-- mesh asset path) in TunerOutfits.lua. A bound outfit adopts its values
-- whenever it is equipped, and slider edits made while wearing it save to
-- the binding instead of the global TunerValues defaults.

local UEHelpers = require("UEHelpers")

local Tuner = {}

local CONFIG = { EnableTuner = true, TunerKey = "F7", DebugLogging = false, FineTuneStep = 0.01 }
pcall(function()
    local supplied = require("EveProportionsConfig")
    if type(supplied) == "table" then
        if supplied.EnableTuner ~= nil then CONFIG.EnableTuner = supplied.EnableTuner == true end
        if type(supplied.TunerKey) == "string" then CONFIG.TunerKey = supplied.TunerKey end
        if supplied.DebugLogging ~= nil then CONFIG.DebugLogging = supplied.DebugLogging == true end
        if tonumber(supplied.FineTuneStep) ~= nil then CONFIG.FineTuneStep = tonumber(supplied.FineTuneStep) end
    end
end)

local function log(message)
    if not CONFIG.DebugLogging then return end
    print("[EveProportionsTuner] " .. message .. "\n")
end

-- Unconditional breadcrumbs on the rare user-triggered UI path, so a hard
-- crash in UE code pinpoints the last step reached in UE4SS.log.
local function crumb(message)
    print("[EveProportionsTuner] " .. message .. "\n")
end

local WIDGET_ASSET = "/Game/Mods/EveProportions/WBP_EveProportions"
local WIDGET_CLASS = WIDGET_ASSET .. ".WBP_EveProportions_C"
local WBL_PATH = "/Script/UMG.Default__WidgetBlueprintLibrary"
local ABP_MARKER = "ABP_EveProportions_C"
local ABP_CLASS_PATH = "/Game/Mods/EveProportions/ABP_EveProportions.ABP_EveProportions_C"

-- Slider name (widget child) -> ABP node property names it drives.
-- Keys must match the cooked widget's child names (Slider_<key>/Label_<key>);
-- DISPLAY below holds what the label actually shows. In-game effects per
-- observation 2026-07-17.
local GROUPS = {
    Size = { "B_Root" }, -- whole body, feet stay grounded
    Breast = { "B_Dm_L_Breast_Point", "B_Dm_R_Breast_Point" },
    -- Subtle: top-of-breast fullness only.
    FacBreast = { "B_Ab_L_Pectro0", "B_Ab_L_Pectro1", "B_Ab_R_Pectro0", "B_Ab_R_Pectro1" },
    -- Hip_Reg = butt. B_Bip001_Pelvis removed: it scaled the whole skeleton
    -- from the pelvis origin (duplicate of Size, but the feet sink).
    Hip = { "B_Ab_L_Hip_Reg", "B_Ab_R_Hip_Reg" },
    Waist = { "B_Ab_L_Venter", "B_Ab_R_Venter" }, -- front hip bone area
    Belly = { "B_Ab_L_Venter2", "B_Ab_R_Venter2" }, -- reads as hips in game
    Thigh = {
        "B_Ab_L_Thigh_Tw0", "B_Ab_L_Thigh_Tw1", "B_Ab_L_Knee",
        "B_Ab_L_Calf_Tw0", "B_Ab_L_Calf_Tw1",
        "B_Ab_R_Thigh_Tw0", "B_Ab_R_Thigh_Tw1", "B_Ab_R_Knee",
        "B_Ab_R_Calf_Tw0", "B_Ab_R_Calf_Tw1",
    },
    FacBody = {
        "B_Ab_L_Becep", "B_Ab_L_Deltoid", "B_Ab_L_Shoulder0", "B_Ab_L_Shoulder1",
        "B_Ab_L_Trape0", "B_Ab_L_Trape1", "B_Ab_L_UpperArm_Tw0", "B_Ab_L_UpperArm_Tw1",
        "B_Ab_R_Becep", "B_Ab_R_Deltoid", "B_Ab_R_Shoulder0", "B_Ab_R_Shoulder1",
        "B_Ab_R_Trape0", "B_Ab_R_Trape1", "B_Ab_R_UpperArm_Tw0", "B_Ab_R_UpperArm_Tw1",
    },
}
local GROUP_ORDER = { "Size", "Breast", "FacBreast", "Hip", "Waist", "Belly", "Thigh", "FacBody" }

-- What the panel labels display for each group (internal keys and saved
-- TunerValues.lua keys are unchanged).
local DISPLAY = {
    Size = "Size",
    Breast = "Breast",
    FacBreast = "Bust Top",
    Hip = "Butt",
    Waist = "Front Hip",
    Belly = "Hips",
    Thigh = "Legs",
    FacBody = "Arms",
}

local function live(value)
    if value == nil then return false end
    local ok, result = pcall(function() return value:IsValid() end)
    return ok and result == true
end

-- FText() needs the native FText constructor, which UE4SS finds by AOB scan.
-- On some installs the scan fails ("[PS] Failed to find FText::FText" in
-- UE4SS.log) and constructing one crashes the game. Fall back to
-- KismetTextLibrary::Conv_StringToText, which is a plain UFunction call and
-- doesn't need the scan. The proper fix is UE4SS_Signatures/FText_Constructor.lua
-- (bundled with this mod), but degrade to blank text rather than crash.
local textConv = nil
local function makeText(s)
    local ok, txt = pcall(FText, s)
    if ok and txt ~= nil then return txt end
    if textConv == nil then
        pcall(function()
            textConv = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        end)
    end
    if live(textConv) then
        local ok2, txt2 = pcall(function() return textConv:Conv_StringToText(s) end)
        if ok2 and txt2 ~= nil then return txt2 end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Settings persistence
-- ---------------------------------------------------------------------------

local scriptDir = nil
pcall(function()
    local source = debug.getinfo(1, "S").source:sub(2)
    scriptDir = source:gsub("[\\/][^\\/]+$", "")
end)

-- Copy only known groups, clamped to sane bounds; missing groups become 1.0.
local function snapshot(values)
    local copy = {}
    for _, name in ipairs(GROUP_ORDER) do
        local v = tonumber(values and values[name])
        copy[name] = v ~= nil and math.max(0.0, math.min(5.0, v)) or 1.0
    end
    return copy
end

local settings = snapshot(nil)        -- values currently applied/shown
local defaultSettings = snapshot(nil) -- last saved non-outfit values
local presets = {}                    -- slot (1..9) -> values table
local outfits = {}                    -- body mesh full name -> values table
local currentOutfitKey = nil          -- mesh key of the last adopted instance
local adopted = false                 -- true while settings came from an outfit binding

local function filePath(name)
    if scriptDir == nil then return nil end
    return scriptDir .. "/" .. name
end

local function loadTable(name)
    local path = filePath(name)
    if path == nil then return nil end
    local ok, chunk = pcall(loadfile, path)
    if not ok or chunk == nil then return nil end
    local ran, saved = pcall(chunk)
    if ran and type(saved) == "table" then return saved end
    return nil
end

local function writeValues(file, values, indent)
    for _, name in ipairs(GROUP_ORDER) do
        file:write(string.format("%s%s = %.4f,\n", indent, name, values[name] or 1.0))
    end
end

local function openSaveFile(name)
    local path = filePath(name)
    if path == nil then return nil end
    local file = io.open(path, "w")
    if file == nil then log("cannot write " .. path) end
    return file
end

local function loadSettings()
    local saved = loadTable("TunerValues.lua")
    if saved ~= nil then
        settings = snapshot(saved)
        defaultSettings = snapshot(saved)
        log("settings loaded")
    end
    saved = loadTable("TunerPresets.lua")
    if saved ~= nil then
        for slot = 1, 9 do
            if type(saved[slot]) == "table" then presets[slot] = snapshot(saved[slot]) end
        end
    end
    saved = loadTable("TunerOutfits.lua")
    if saved ~= nil then
        for key, values in pairs(saved) do
            if type(key) == "string" and type(values) == "table" then
                outfits[key] = snapshot(values)
            end
        end
    end
end

local function saveSettings()
    local file = openSaveFile("TunerValues.lua")
    if file == nil then return end
    defaultSettings = snapshot(settings)
    file:write("-- Written by EveProportionsTuner; edit in-game with " .. CONFIG.TunerKey .. "\nreturn {\n")
    writeValues(file, settings, "    ")
    file:write("}\n")
    file:close()
    log("settings saved")
end

local function savePresets()
    local file = openSaveFile("TunerPresets.lua")
    if file == nil then return end
    file:write("-- Written by EveProportionsTuner; load with 1..9, save with Shift+1..9\nreturn {\n")
    for slot = 1, 9 do
        if presets[slot] ~= nil then
            file:write(string.format("    [%d] = {\n", slot))
            writeValues(file, presets[slot], "        ")
            file:write("    },\n")
        end
    end
    file:write("}\n")
    file:close()
    log("presets saved")
end

local function saveOutfits()
    local file = openSaveFile("TunerOutfits.lua")
    if file == nil then return end
    file:write("-- Written by EveProportionsTuner; bind with 0, unbind with Shift+0\nreturn {\n")
    for key, values in pairs(outfits) do
        file:write(string.format("    [%q] = {\n", key))
        writeValues(file, values, "        ")
        file:write("    },\n")
    end
    file:write("}\n")
    file:close()
    log("outfit bindings saved")
end

-- Route the debounced save: edits made while a bound outfit is worn update
-- the outfit's binding; otherwise they update the global defaults.
local function flushSave()
    if adopted and currentOutfitKey ~= nil and outfits[currentOutfitKey] ~= nil then
        outfits[currentOutfitKey] = snapshot(settings)
        saveOutfits()
    else
        saveSettings()
    end
end

-- ---------------------------------------------------------------------------
-- Applying settings to ABP instances
-- ---------------------------------------------------------------------------

-- Authored node values captured from the first pristine instance we see.
-- Instances are always constructed from the CDO, so these are constant.
local baseCache = nil
local captureFailWarned = false

-- Diagnostic: when nothing captures, list the B_* properties the class
-- actually has, so we can see how the cooked names differ from GROUPS.
local function dumpNodeProperties(inst)
    local names = {}
    pcall(function()
        inst:GetClass():ForEachProperty(function(prop)
            local n = prop:GetFName():ToString()
            if n:find("B_", 1, true) == 1 then
                pcall(function() n = n .. " (" .. prop:GetClass():GetFName():ToString() .. ")" end)
                table.insert(names, n)
            end
        end)
    end)
    if #names == 0 then
        crumb("class property dump found no B_* properties")
    else
        crumb("class has " .. #names .. " B_* properties: " ..
            table.concat(names, ", ", 1, math.min(#names, 12)) ..
            (#names > 12 and ", ..." or ""))
    end
end

-- The B_<bone> properties are per-bone FLOAT variables on the ABP (driving
-- each ModifyBone node's Alpha through the anim fast path). The node structs
-- themselves are separate class properties with their own names; we discover
-- them by reading BoneToModify.BoneName off every struct-valued property.
-- Writing the node's Scale/Translation/Rotation gives real >1 exaggeration,
-- which the alpha floats cannot (blend weights clamp at 1).

-- B_Ab_L_Becep -> "Ab-L-Becep", B_Bip001_Pelvis -> "Bip001-Pelvis"
local function boneFromProp(prop)
    return prop:sub(3):gsub("_", "-")
end

local nodePropByBone = nil

local function discoverNodes(inst)
    if nodePropByBone ~= nil then return end
    nodePropByBone = {}
    local count = 0
    pcall(function()
        inst:GetClass():ForEachProperty(function(prop)
            pcall(function()
                local pn = prop:GetFName():ToString()
                local node = inst[pn]
                if type(node) ~= "number" and type(node) ~= "boolean" and node ~= nil then
                    local bone = node.BoneToModify.BoneName:ToString()
                    if bone ~= nil and bone ~= "" and bone ~= "None" then
                        nodePropByBone[bone] = pn
                        count = count + 1
                    end
                end
            end)
        end)
    end)
    log("discovered " .. count .. " modify-bone node structs")
end

local function captureBase(inst)
    if baseCache ~= nil then return true end
    -- Read authored values from the CDO, not the instance: after a Lua
    -- hot-reload the live instance still carries the previous session's
    -- writes, while the CDO is never touched.
    local src = inst
    pcall(function()
        local cdo = inst:GetClass():GetCDO()
        if live(cdo) then src = cdo end
    end)
    discoverNodes(src)
    local captured, okCount, failCount, firstErr = {}, 0, 0, nil
    for _, props in pairs(GROUPS) do
        for _, prop in ipairs(props) do
            local ok, err = pcall(function()
                local entry = {}
                local alpha = src[prop]
                if type(alpha) == "number" then entry.alpha = alpha end
                local nodeProp = nodePropByBone[boneFromProp(prop)]
                if nodeProp ~= nil then
                    local node = src[nodeProp]
                    local s, t, r = node.Scale, node.Translation, node.Rotation
                    entry.node = nodeProp
                    entry.s = { s.X, s.Y, s.Z }
                    entry.t = { t.X, t.Y, t.Z }
                    entry.r = { r.Pitch, r.Yaw, r.Roll }
                end
                if entry.alpha == nil and entry.node == nil then
                    error("neither alpha float nor node struct found")
                end
                captured[prop] = entry
            end)
            if ok and captured[prop] ~= nil then
                okCount = okCount + 1
            else
                failCount = failCount + 1
                if firstErr == nil then firstErr = prop .. ": " .. tostring(err) end
            end
        end
    end
    if okCount == 0 then
        if not captureFailWarned then
            captureFailWarned = true
            crumb("capture failed for all nodes; first error — " .. tostring(firstErr))
            dumpNodeProperties(inst)
        end
        return false
    end
    baseCache = captured
    local withNodes = 0
    for _, e in pairs(captured) do
        if e.node ~= nil then withNodes = withNodes + 1 end
    end
    log(string.format("captured %d entries (%d with node structs, %d failed%s)",
        okCount, withNodes, failCount,
        firstErr ~= nil and ("; first error — " .. firstErr) or ""))
    return true
end

local function isOurInstance(inst)
    if not live(inst) then return false end
    local ok, name = pcall(function() return inst:GetFullName() end)
    return ok and name ~= nil and name:find(ABP_MARKER, 1, true) ~= nil
end

local appliedAddresses = {}

-- The post-process anim instance's outer is the SkeletalMeshComponent, whose
-- mesh asset uniquely identifies the worn outfit (vanilla and CNS alike).
local function outfitKeyFor(inst)
    local key = nil
    pcall(function()
        local mesh = inst:GetOuter().SkeletalMesh
        if live(mesh) then key = mesh:GetFullName() end
    end)
    return key
end

-- Assigned after the widget code; pushes settings into the open panel.
local refreshPanel = nil

-- Called on the outfit-change paths only (main.lua refresh, new-instance
-- notify), never from UI edits: a bound outfit's values take over, and
-- leaving a bound outfit restores the saved defaults.
local function adoptOutfit(inst)
    local key = outfitKeyFor(inst)
    if key == nil then return end
    if outfits[key] ~= nil then
        if not (adopted and key == currentOutfitKey) then
            settings = snapshot(outfits[key])
            adopted = true
            log("adopted outfit binding: " .. key)
            if refreshPanel ~= nil then refreshPanel() end
        end
    elseif adopted then
        settings = snapshot(defaultSettings)
        adopted = false
        log("left bound outfit, defaults restored")
        if refreshPanel ~= nil then refreshPanel() end
    end
    currentOutfitKey = key
end

-- Must be called on the game thread.
local function applyToInstance(inst, adopt)
    if not isOurInstance(inst) then return false end
    if adopt then adoptOutfit(inst) end
    if not captureBase(inst) then return false end
    for group, props in pairs(GROUPS) do
        local t = settings[group]
        for _, prop in ipairs(props) do
            local base = baseCache[prop]
            if base ~= nil then pcall(function()
                if base.node ~= nil then
                    -- Slider is a size multiplier: scale = authored * t, so
                    -- up = bigger regardless of whether the authored value
                    -- shrinks or grows the bone (this mod's values shrink).
                    -- Multiplicative also can't flip sign at extremes. Keep
                    -- alpha at its authored value.
                    local node = inst[base.node]
                    local s = node.Scale
                    s.X = base.s[1] * t
                    s.Y = base.s[2] * t
                    s.Z = base.s[3] * t
                    local tr = node.Translation
                    tr.X = base.t[1] * t
                    tr.Y = base.t[2] * t
                    tr.Z = base.t[3] * t
                    local r = node.Rotation
                    r.Pitch = base.r[1] * t
                    r.Yaw = base.r[2] * t
                    r.Roll = base.r[3] * t
                    if base.alpha ~= nil then inst[prop] = base.alpha end
                elseif base.alpha ~= nil then
                    -- Fallback: alpha attenuation only; engine clamps blend
                    -- weight to [0,1], so t>1 saturates at authored shape.
                    inst[prop] = base.alpha * t
                end
            end) end
        end
    end
    pcall(function() appliedAddresses[inst:GetAddress()] = true end)
    if not Tuner._firstApplyLogged then
        Tuner._firstApplyLogged = true
        log("first apply ok")
    end
    return true
end

-- Must be called on the game thread.
local function applyToAllInstances(force, adopt)
    local instances = nil
    pcall(function() instances = FindAllOf(ABP_MARKER) end)
    if instances == nil then return end
    for _, inst in ipairs(instances) do
        if live(inst) then
            local addr = nil
            pcall(function() addr = inst:GetAddress() end)
            if force or addr == nil or not appliedAddresses[addr] then
                if applyToInstance(inst, adopt) then
                    log("applied to instance " .. tostring(addr))
                end
            end
        end
    end
end

-- Public: main.lua calls this right after it refreshes the post-process
-- instance so new instances pick up saved values without waiting for the
-- background watcher.
function Tuner.ApplyTo(inst)
    if not CONFIG.EnableTuner then return end
    applyToInstance(inst, true)
end

-- ---------------------------------------------------------------------------
-- Widget lifecycle
-- ---------------------------------------------------------------------------

local ui = { widget = nil, visible = false, pollActive = false }

-- Recursive fallback lookup through the widget tree, for the case where the
-- named widgets were not cooked as class variables (bIsVariable=false).
-- UContentWidget derives from UPanelWidget, so GetChildrenCount/GetChildAt
-- cover Border/Button/SizeBox wrappers too.
local function walkTree(node, name)
    if not live(node) then return nil end
    local ok, nodeName = pcall(function() return node:GetFName():ToString() end)
    if ok and nodeName == name then return node end
    local count = 0
    pcall(function() count = node:GetChildrenCount() end)
    if type(count) ~= "number" then return nil end
    for i = 0, count - 1 do
        local child = nil
        pcall(function() child = node:GetChildAt(i) end)
        local found = walkTree(child, name)
        if found ~= nil then return found end
    end
    return nil
end

local childCache = {}

local function findChild(widget, childName)
    local cached = childCache[childName]
    if live(cached) then return cached end
    childCache[childName] = nil

    local child = nil
    pcall(function() child = widget[childName] end)
    if not live(child) then
        local root = nil
        pcall(function() root = widget.WidgetTree.RootWidget end)
        child = walkTree(root, childName)
    end
    if live(child) then
        childCache[childName] = child
        return child
    end
    return nil
end

local function eachSlider(widget, fn)
    for _, group in ipairs(GROUP_ORDER) do
        local slider = findChild(widget, "Slider_" .. group)
        if slider ~= nil then fn(group, slider) end
    end
end

local function getWBL()
    local wbl = StaticFindObject(WBL_PATH)
    if live(wbl) then return wbl end
    return nil
end

-- Load the widget class the way BPModLoaderMod loads ModActor classes:
-- AssetRegistryHelpers:GetAsset loads straight from the pak even though
-- LogicMods paks never patch AssetRegistry.bin (UE4SS's LoadAsset relies
-- on the registry and fails for this asset).
local function loadWidgetClass()
    local widgetClass = StaticFindObject(WIDGET_CLASS)
    if live(widgetClass) then return widgetClass end

    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if live(helpers) then
        log("loading widget class via GetAsset")
        local ok, err = pcall(function()
            local assetData = {
                ObjectPath = UEHelpers.FindOrAddFName(WIDGET_CLASS),
            }
            helpers:GetAsset(assetData)
        end)
        if not ok then print("[EveProportionsTuner] GetAsset failed: " .. tostring(err) .. "\n") end
        widgetClass = StaticFindObject(WIDGET_CLASS)
        if live(widgetClass) then return widgetClass end
    else
        print("[EveProportionsTuner] AssetRegistryHelpers not found\n")
    end

    local ok, err = pcall(function() LoadAsset(WIDGET_ASSET) end)
    if not ok then print("[EveProportionsTuner] LoadAsset failed: " .. tostring(err) .. "\n") end
    widgetClass = StaticFindObject(WIDGET_CLASS)
    if live(widgetClass) then return widgetClass end
    return nil
end

local function ensureWidget()
    if live(ui.widget) then return ui.widget end
    ui.widget = nil

    -- Purge instances orphaned by Lua hot-reload: the old state's widget
    -- stays on the viewport and can sit on top of (and eat input meant
    -- for) the fresh one.
    pcall(function()
        local stale = FindAllOf("WBP_EveProportions_C")
        if stale ~= nil then
            local purged = 0
            for _, w in ipairs(stale) do
                if pcall(function() w:RemoveFromParent() end) then purged = purged + 1 end
            end
            if purged > 0 then log("purged " .. purged .. " stale widget instances") end
        end
    end)

    local widgetClass = loadWidgetClass()
    if not live(widgetClass) then
        print("[EveProportionsTuner] could not load " .. WIDGET_CLASS .. "\n")
        return nil
    end

    local pc = UEHelpers.GetPlayerController()
    local wbl = getWBL()
    if not live(pc) or wbl == nil then
        crumb("no PlayerController or WidgetBlueprintLibrary")
        return nil
    end

    log("creating widget")
    local widget = nil
    pcall(function() widget = wbl:Create(pc, widgetClass, pc) end)
    if not live(widget) then
        crumb("widget creation failed")
        return nil
    end

    log("initializing sliders")
    childCache = {}
    ui.widget = widget -- findChild callers below need it set
    local found = 0
    eachSlider(widget, function(group, slider)
        found = found + 1
        -- Reassert the intended ranges; runtime instances have shown up with
        -- USlider defaults (0..1) instead of the cooked values.
        pcall(function()
            slider.MinValue = 0.1
            slider.MaxValue = (group == "FacBody" or group == "FacBreast") and 3.0 or 5.0
        end)
        pcall(function() slider:SetValue(settings[group]) end)
    end)
    log("sliders found: " .. found .. "/8")

    -- Shortcut hints: the cooked layout ships no hint text, so append a
    -- TextBlock to the VBox at runtime. Do it before AddToViewport so Slate
    -- builds it together with the rest of the tree.
    pcall(function()
        local vbox = findChild(widget, "VBox")
        local textClass = StaticFindObject("/Script/UMG.TextBlock")
        if vbox == nil or not live(textClass) then return end
        local hint = StaticConstructObject(textClass, widget.WidgetTree)
        if not live(hint) then return end
        -- Match the label typeface but at a fixed small size; each step is
        -- optional and degrades to the default font.
        pcall(function()
            local ref = findChild(widget, "Label_Size")
            hint.Font = ref.Font
        end)
        pcall(function() hint.Font.Size = 16 end)
        pcall(function() hint:SetAutoWrapText(true) end)
        local hintText = makeText(
            "Left/Right arrows: fine-tune last slider\n" ..
            "1-9: load preset    Shift+1-9: save preset\n" ..
            "0: bind to worn outfit    Shift+0: unbind")
        if hintText == nil then return end
        hint:SetText(hintText)
        local slot = vbox:AddChildToVerticalBox(hint)
        pcall(function() slot.Padding.Top = 10.0 end)
        log("shortcut hints added")
    end)

    -- Widen the panel a bit beyond the cooked width so the hint text and
    -- longer labels breathe. Factor is relative to the authored width.
    pcall(function()
        local box = findChild(widget, "WidthBox")
        local w = box.WidthOverride
        if type(w) == "number" and w > 0 then box:SetWidthOverride(w * 1.25) end
    end)

    pcall(function() widget.bIsFocusable = true end)
    log("adding to viewport")
    pcall(function() widget:AddToViewport(100) end)
    log("widget ready")
    return widget
end

local function updateLabel(widget, group)
    local label = findChild(widget, "Label_" .. group)
    if label == nil then return end
    pcall(function()
        local txt = makeText(string.format("%s  %.2f", DISPLAY[group] or group, settings[group]))
        if txt ~= nil then label:SetText(txt) end
    end)
end

local function setUIInputMode(enabled)
    local pc = UEHelpers.GetPlayerController()
    if not live(pc) then return end
    local wbl = getWBL()
    pcall(function() pc.bShowMouseCursor = enabled end)
    pcall(function() pc.bEnableClickEvents = enabled end)
    pcall(function() pc.bEnableMouseOverEvents = enabled end)
    if wbl == nil then return end
    if enabled and live(ui.widget) then
        -- UIOnly is the aggressive option: SB's own input handling consumes
        -- mouse events in GameAndUI mode. Game input is restored on hide.
        local ok = pcall(function() wbl:SetInputMode_UIOnlyEx(pc, ui.widget, 0) end)
        if not ok then
            crumb("UIOnlyEx failed, falling back to GameAndUIEx")
            pcall(function() wbl:SetInputMode_GameAndUIEx(pc, ui.widget, 0, false) end)
        end
    else
        pcall(function() wbl:SetInputMode_GameOnly(pc) end)
    end
end

local hideUI -- forward declaration

local dirtyAt = nil
local lastTouched = "Size" -- arrow-key fine adjust targets this group
local buttonWasPressed = { Reset = false, Hide = false }
local firstChangeSeen = false
local firstTickSeen = false

-- USlider never writes drag changes back to its Value UPROPERTY — the live
-- number only exists on the Slate widget, exposed via GetValue(). The
-- property is just the stale design-time value, so it's the fallback.
local function readSlider(slider)
    local ok, value = pcall(function() return slider:GetValue() end)
    if ok and type(value) == "number" then return value end
    ok, value = pcall(function() return slider.Value end)
    if ok and type(value) == "number" then return value end
    return nil
end

-- Push current settings into the open panel (reset, preset load, outfit
-- adoption). SetValue on a live widget doesn't reliably move the Slate
-- handle — and a handle left in place would be read back by the next poll
-- tick, reverting settings — so verify with a readback and rebuild the
-- widget on mismatch (construction initializes Slate from values set before
-- AddToViewport, which always works).
local function pushSettingsToSliders()
    if not ui.visible or not live(ui.widget) then return end
    local mismatch = false
    eachSlider(ui.widget, function(group, slider)
        pcall(function() slider:SetValue(settings[group]) end)
        local rb = readSlider(slider)
        if rb == nil or math.abs(rb - settings[group]) > 0.0005 then mismatch = true end
        updateLabel(ui.widget, group)
    end)
    if mismatch then
        crumb("slider push: SetValue readback mismatch, rebuilding widget")
        pcall(function() ui.widget:RemoveFromParent() end)
        ui.widget = nil
        local rebuilt = ensureWidget()
        if rebuilt ~= nil then
            for _, group in ipairs(GROUP_ORDER) do updateLabel(rebuilt, group) end
            pcall(function() rebuilt:SetVisibility(0) end)
            setUIInputMode(true)
        end
    end
end
refreshPanel = pushSettingsToSliders

local function pollTick()
    if not ui.visible or not live(ui.widget) then
        ui.pollActive = false
        return
    end
    local widget = ui.widget
    if not firstTickSeen then
        firstTickSeen = true
        log("poll loop running")
    end

    -- SB's controller steals input mode back, and not always via a visible
    -- bShowMouseCursor flip — reassert every tick. UIOnly focus changes do
    -- not release slider mouse capture, so drags survive this.
    pcall(function()
        local pc = UEHelpers.GetPlayerController()
        if live(pc) and not pc.bShowMouseCursor then
            log("cursor stolen by game")
        end
        setUIInputMode(true)
    end)

    -- Hover diagnostic: fires once when hit-testing first reaches a slider.
    if not Tuner._hoverLogged then
        eachSlider(widget, function(_, slider)
            if Tuner._hoverLogged then return end
            local ok, hovered = pcall(function() return slider:IsHovered() end)
            if ok and hovered == true then
                Tuner._hoverLogged = true
                log("hover reaches sliders")
            end
        end)
    end

    -- Ground-truth dump: log actual slider reads every ~2s (first 10 dumps)
    -- to see whether Value moves with the handle at all.
    Tuner._tickCount = (Tuner._tickCount or 0) + 1
    if CONFIG.DebugLogging and Tuner._tickCount == 25 then
        pcall(function()
            local s = findChild(widget, "Slider_Size")
            log(string.format("Size slider range %.2f..%.2f", s.MinValue, s.MaxValue))
        end)
        pcall(function()
            local all = FindAllOf("WBP_EveProportions_C")
            log("widget instances alive: " .. tostring(all ~= nil and #all or 0))
        end)
    end
    if CONFIG.DebugLogging and Tuner._tickCount % 25 == 0 and Tuner._tickCount <= 250 then
        local parts = {}
        eachSlider(widget, function(group, slider)
            local v = readSlider(slider)
            table.insert(parts, string.format("%s=%s", group, v ~= nil and string.format("%.2f", v) or "nil"))
        end)
        -- Read one node back from the live instance to verify writes land.
        pcall(function()
            local insts = FindAllOf(ABP_MARKER)
            if insts ~= nil and insts[1] ~= nil and baseCache ~= nil then
                for prop, e in pairs(baseCache) do
                    if e.node ~= nil then
                        local node = insts[1][e.node]
                        table.insert(parts, string.format("| %s S.X=%.3f", e.node, node.Scale.X))
                        break
                    end
                end
            end
        end)
        log("values: " .. table.concat(parts, " "))
    end

    local changed = false
    eachSlider(widget, function(group, slider)
        local value = readSlider(slider)
        if value ~= nil and math.abs(value - settings[group]) > 0.0005 then
            settings[group] = value
            lastTouched = group
            updateLabel(widget, group)
            changed = true
            if not firstChangeSeen then
                firstChangeSeen = true
                log(string.format("first slider change: %s=%.2f", group, value))
            end
        end
    end)

    for name, _ in pairs(buttonWasPressed) do
        local button = findChild(widget, "Btn_" .. name)
        local pressed = false
        if button ~= nil then
            local ok, result = pcall(function() return button:IsPressed() end)
            pressed = ok and result == true
        end
        if pressed and not buttonWasPressed[name] then
            log("button pressed: " .. name)
            if name == "Reset" then
                for _, group in ipairs(GROUP_ORDER) do settings[group] = 1.0 end
                pushSettingsToSliders()
                changed = true
            elseif name == "Hide" then
                hideUI()
            end
        end
        buttonWasPressed[name] = pressed
    end

    if changed then
        applyToAllInstances(true)
        dirtyAt = os.clock()
    end
    if dirtyAt ~= nil and os.clock() - dirtyAt > 0.5 then
        dirtyAt = nil
        flushSave()
    end
end

local function startPolling()
    if ui.pollActive then return end
    ui.pollActive = true
    LoopAsync(80, function()
        -- pollTick runs game-thread-side and clears pollActive when the UI
        -- goes away; check the flag here because ExecuteInGameThread queues
        -- asynchronously and cannot return a value to this loop.
        if not ui.pollActive then return true end
        ExecuteInGameThread(pollTick)
        return false
    end)
end

local function showUI()
    log("showUI")
    local widget = ensureWidget()
    if widget == nil then return end
    for _, group in ipairs(GROUP_ORDER) do updateLabel(widget, group) end
    pcall(function() widget:SetVisibility(0) end) -- ESlateVisibility::Visible
    ui.visible = true
    log("setting input mode")
    setUIInputMode(true)
    startPolling()
    log("UI shown")
end

hideUI = function()
    ui.visible = false
    if dirtyAt ~= nil then dirtyAt = nil; flushSave() end
    if live(ui.widget) then
        pcall(function() ui.widget:SetVisibility(1) end) -- ESlateVisibility::Collapsed
    end
    setUIInputMode(false)
    log("UI hidden")
end

-- Keybind callbacks are not guaranteed to run on the game thread
-- (BPModLoaderMod wraps its own keybind the same way), so hop over
-- before touching any UObjects.
local function toggleUI()
    ExecuteInGameThread(function()
        if ui.visible and live(ui.widget) then hideUI() else showUI() end
    end)
end

-- ---------------------------------------------------------------------------
-- Panel-only keyboard actions (fine adjust, presets, outfit bindings).
-- All run on the game thread and no-op while the panel is closed.
-- ---------------------------------------------------------------------------

local function sliderMax(group)
    return (group == "FacBody" or group == "FacBreast") and 3.0 or 5.0
end

local function nudge(direction)
    if not ui.visible then return end
    local v = settings[lastTouched] + CONFIG.FineTuneStep * direction
    v = math.max(0.1, math.min(sliderMax(lastTouched), v))
    if math.abs(v - settings[lastTouched]) < 0.00005 then return end
    settings[lastTouched] = v
    pushSettingsToSliders()
    applyToAllInstances(true)
    dirtyAt = os.clock()
end

local function loadPreset(slot)
    if not ui.visible then return end
    if presets[slot] == nil then crumb("preset " .. slot .. " is empty"); return end
    settings = snapshot(presets[slot])
    pushSettingsToSliders()
    applyToAllInstances(true)
    dirtyAt = os.clock()
    crumb("preset " .. slot .. " loaded")
end

local function savePreset(slot)
    if not ui.visible then return end
    presets[slot] = snapshot(settings)
    savePresets()
    crumb("preset " .. slot .. " saved")
end

local function bindOutfit()
    if not ui.visible then return end
    if currentOutfitKey == nil then crumb("no outfit seen yet, cannot bind"); return end
    outfits[currentOutfitKey] = snapshot(settings)
    adopted = true
    saveOutfits()
    crumb("values bound to outfit: " .. currentOutfitKey)
end

local function unbindOutfit()
    if not ui.visible then return end
    if currentOutfitKey == nil or outfits[currentOutfitKey] == nil then
        crumb("worn outfit has no binding")
        return
    end
    outfits[currentOutfitKey] = nil
    adopted = false
    saveOutfits()
    settings = snapshot(defaultSettings)
    pushSettingsToSliders()
    applyToAllInstances(true)
    crumb("outfit binding removed, defaults restored")
end

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

if CONFIG.EnableTuner then
    loadSettings()

    local key = Key[CONFIG.TunerKey]
    if key ~= nil then
        RegisterKeyBind(key, toggleUI)
        log("toggle bound to " .. CONFIG.TunerKey)
    else
        print("[EveProportionsTuner] unknown TunerKey '" .. tostring(CONFIG.TunerKey) .. "'\n")
    end

    -- Panel-only keys (each handler no-ops while the panel is closed):
    -- arrows fine-adjust, 1..9 load / Shift+1..9 save presets, 0 binds the
    -- worn outfit, Shift+0 unbinds it.
    pcall(function()
        RegisterKeyBind(Key.LEFT_ARROW, function() ExecuteInGameThread(function() nudge(-1) end) end)
        RegisterKeyBind(Key.RIGHT_ARROW, function() ExecuteInGameThread(function() nudge(1) end) end)
        local slotKeys = { Key.ONE, Key.TWO, Key.THREE, Key.FOUR, Key.FIVE,
                           Key.SIX, Key.SEVEN, Key.EIGHT, Key.NINE }
        for slot, slotKey in ipairs(slotKeys) do
            local s = slot
            RegisterKeyBind(slotKey, function() ExecuteInGameThread(function() loadPreset(s) end) end)
            RegisterKeyBind(slotKey, { ModifierKey.SHIFT }, function() ExecuteInGameThread(function() savePreset(s) end) end)
        end
        RegisterKeyBind(Key.ZERO, function() ExecuteInGameThread(function() bindOutfit() end) end)
        RegisterKeyBind(Key.ZERO, { ModifierKey.SHIFT }, function() ExecuteInGameThread(function() unbindOutfit() end) end)
    end)

    -- Fallback: catches instances created outside main.lua's refresh path
    -- (e.g. after level load). Event-driven, not a timer -- the previous
    -- 1 s FindAllOf poll on the game thread caused a visible hitch every
    -- second during cinematics. The delay lets the anim instance finish
    -- construction before saved values are written into it.
    NotifyOnNewObject(ABP_CLASS_PATH, function()
        ExecuteWithDelay(300, function()
            ExecuteInGameThread(function() applyToAllInstances(false, true) end)
        end)
    end)
end

return Tuner
