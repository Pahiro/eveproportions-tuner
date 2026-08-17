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
-- Groups listed in SHAPE narrow that: they can apply the multiplier to only
-- some Scale axes and leave Translation/Rotation alone, which is how the
-- girth sliders slim a limb without also shortening it or dragging the joint
-- inward. Where several groups name the same bone the multipliers compose.
-- Values persist to TunerValues.lua next to this script.
--
-- Keys while the panel is open:
--   Up/Down arrows      move the selection (marked "> " in its label)
--   Left/Right arrows   nudge the selected slider by FineTuneStep; hold to
--                       repeat where the input mode allows it, and
--                       Shift+Left/Right steps 10x for the times it does not
--   1..9                load preset slot        Shift+1..9  save preset slot
--   0                   bind current values to the worn outfit
--   Shift+0             remove the worn outfit's binding
--   F8                  toggle game-input passthrough (see below)
-- Presets live in TunerPresets.lua; outfit bindings (keyed by the body
-- mesh asset path) in TunerOutfits.lua. A bound outfit adopts its values
-- whenever it is equipped, and slider edits made while wearing it save to
-- the binding instead of the global TunerValues defaults.
--
-- Passthrough (F8): the panel normally forces UIOnly input mode, which
-- blocks ALL native/action-mapped input while open -- not just mouse, so
-- other mods' native keybinds (e.g. DekCNS's own hotkeys and its camera
-- right-click-drag) go dead too, even though our own F7/arrow/preset keys
-- keep working (those are UE4SS OS-level hooks, outside UE's input system
-- entirely). F8 flips to GameAndUI so native input reaches the game again;
-- trades away the UIOnly slider-drag safety while active. Resets off when
-- the panel closes.

local UEHelpers = require("UEHelpers")

local Tuner = {}

local CONFIG = {
    EnableTuner = true,
    TunerKey = "F7",
    PassthroughKey = "F8",
    DebugLogging = false,
    DumpBoneInventory = false,
    FineTuneStep = 0.01,
}
pcall(function()
    local supplied = require("EveProportionsConfig")
    if type(supplied) == "table" then
        if supplied.EnableTuner ~= nil then CONFIG.EnableTuner = supplied.EnableTuner == true end
        if type(supplied.TunerKey) == "string" then CONFIG.TunerKey = supplied.TunerKey end
        if type(supplied.PassthroughKey) == "string" then CONFIG.PassthroughKey = supplied.PassthroughKey end
        if supplied.DebugLogging ~= nil then CONFIG.DebugLogging = supplied.DebugLogging == true end
        if supplied.DumpBoneInventory ~= nil then CONFIG.DumpBoneInventory = supplied.DumpBoneInventory == true end
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

-- SB hides the hardware cursor no matter how often bShowMouseCursor is
-- reasserted, so mouse input works over the panel but the pointer is
-- invisible. DekCNS solves this with a self-ticking virtual-cursor widget
-- (an image following GetMousePositionScaledByDPI, HitTestInvisible). If
-- CNS is installed, spawn one of those above the panel; without CNS the
-- panel still works, just with the invisible pointer.
local CURSOR_ASSET = "/Game/Mods/DekCNS_P/Widgets/WB_MouseCursor"
local CURSOR_CLASS = CURSOR_ASSET .. ".WB_MouseCursor_C"
local ABP_MARKER = "ABP_EveProportions_C"
local ABP_CLASS_PATH = "/Game/Mods/EveProportions/ABP_EveProportions.ABP_EveProportions_C"

-- Slider name (widget child) -> ABP node property names it drives.
-- The first eight keys match the cooked widget's child names
-- (Slider_<key>/Label_<key>); anything past those has no cooked slider and
-- gets one built at runtime (see buildSliderRow). DISPLAY below holds what
-- the label actually shows. In-game effects per observation 2026-07-17.
--
-- Several groups may name the same bone on purpose (e.g. Thigh covers the
-- whole leg while ThighGirth covers only its cross-section); their
-- multipliers compose in applyToInstance rather than the last one winning.
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
    -- Cross-section-only groups (see SHAPE): slim or thicken without
    -- changing bone length or joint placement.
    ThighGirth = {
        "B_Ab_L_Thigh_Tw0", "B_Ab_L_Thigh_Tw1",
        "B_Ab_R_Thigh_Tw0", "B_Ab_R_Thigh_Tw1",
    },
    -- Split across the two calf twist bones so the ankle can be held back
    -- while the calf belly grows. Which of Tw0/Tw1 sits at the knee end and
    -- which at the ankle end is unverified -- if the labels turn out to be
    -- the wrong way round, swap the two DISPLAY strings, nothing else.
    CalfGirth = { "B_Ab_L_Calf_Tw0", "B_Ab_R_Calf_Tw0" },
    AnkleGirth = { "B_Ab_L_Calf_Tw1", "B_Ab_R_Calf_Tw1" },
    WaistGirth = {
        "B_Ab_L_Venter", "B_Ab_R_Venter",
        "B_Ab_L_Venter2", "B_Ab_R_Venter2",
    },
}
local GROUP_ORDER = {
    "Size", "Breast", "FacBreast", "Hip", "Waist", "Belly", "Thigh", "FacBody",
    -- Runtime-built rows, appended to the panel in this order.
    "ThighGirth", "CalfGirth", "AnkleGirth", "WaistGirth",
}

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
    ThighGirth = "Thigh Width",
    CalfGirth = "Calf Width",
    AnkleGirth = "Ankle Width",
    WaistGirth = "Waist Line",
}

-- How a group's multiplier is applied to its nodes.
--
--   axes    which axes of the node's Scale the multiplier touches; a
--           masked-out axis keeps its authored value. Which axis runs along
--           a limb depends on the node's ScaleSpace (printed by the
--           inventory dump), not just on bone naming: masking X left the leg
--           sliders changing length in testing 2026-08-17, so X is NOT the
--           length axis here. Z is masked instead, on the theory that these
--           nodes scale in component space where Z is up and legs run along
--           it. If a girth slider still changes length rather than
--           thickness, mask Y instead of Z -- that exhausts the options, and
--           Ctrl+R hot-reloads this file without restarting the game.
--           Note scale on a parent bone also propagates to its children, so
--           scaling a thigh along its chain axis pushes the knee and ankle
--           away, which reads as a longer leg on top of the stretch.
--   offsets whether the multiplier also scales the authored Translation and
--           Rotation. Scaling translation moves the joint, which is what
--           makes a uniform shrink pull the leg in toward the hip; girth
--           groups leave the offsets alone.
--
-- The eight original groups keep uniform-with-offsets behaviour so existing
-- TunerValues/presets/outfit bindings still produce the shape they did.
local DEFAULT_SHAPE = { x = true, y = true, z = true, offsets = true }
local SHAPE = {
    -- Legs: masking X still changed length (tested 2026-08-17), so the leg
    -- chain runs along Y or Z. Z masked first; if these still stretch rather
    -- than thicken, swap to { x = true, y = false, z = true }.
    ThighGirth = { x = true, y = true, z = false, offsets = false },
    CalfGirth = { x = true, y = true, z = false, offsets = false },
    AnkleGirth = { x = true, y = true, z = false, offsets = false },
    -- Waist reads correctly with X masked (tested 2026-08-17) -- these bones
    -- are oriented differently from the leg chain, so leave it alone.
    WaistGirth = { x = false, y = true, z = true, offsets = false },
}

-- Slider bounds per group; anything unlisted uses DEFAULT_RANGE. The
-- original eight keep the ranges they were forced to at widget creation.
local DEFAULT_RANGE = { min = 0.1, max = 5.0 }
local RANGE = {
    FacBreast = { min = 0.1, max = 3.0 },
    FacBody = { min = 0.1, max = 3.0 },
    ThighGirth = { min = 0.25, max = 2.0 },
    CalfGirth = { min = 0.25, max = 2.0 },
    AnkleGirth = { min = 0.25, max = 2.0 },
    WaistGirth = { min = 0.25, max = 2.0 },
}

-- Groups with no cooked Slider_<key>/Label_<key> in the pak; built at runtime.
local RUNTIME_GROUPS = {
    ThighGirth = true, CalfGirth = true, AnkleGirth = true, WaistGirth = true,
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

-- One-shot inventory of every ModifyBone node the ABP actually ships, with
-- its authored transform and which slider group (if any) drives it. Two
-- things to read out of it: bones that appear here but in no group are free
-- sliders needing no pak change, and a non-uniform authored Scale tells you
-- which local axis the mod author used for girth -- i.e. whether the X-is-
-- length assumption in SHAPE holds for this skeleton. Off by default; flip
-- DumpBoneInventory in EveProportionsConfig.lua for one run.
-- EBoneControlSpace / EBoneModificationMode, printed by name rather than as
-- the bare enum value.
local BONE_SPACE = { [0] = "World", [1] = "Component", [2] = "ParentBone", [3] = "Bone" }
local BONE_MODE = { [0] = "Ignore", [1] = "Replace", [2] = "Additive" }

local function enumName(map, value)
    if type(value) ~= "number" then return "?" end
    return (map[value] or "?") .. "(" .. tostring(value) .. ")"
end
local function spaceName(value) return enumName(BONE_SPACE, value) end
local function modeName(value) return enumName(BONE_MODE, value) end

local function dumpBoneInventory(src)
    if not CONFIG.DumpBoneInventory or Tuner._inventoryDumped then return end
    Tuner._inventoryDumped = true

    local groupOf = {}
    for group, props in pairs(GROUPS) do
        for _, prop in ipairs(props) do
            local bone = boneFromProp(prop)
            groupOf[bone] = groupOf[bone] and (groupOf[bone] .. "+" .. group) or group
        end
    end

    local bones = {}
    for bone in pairs(nodePropByBone) do table.insert(bones, bone) end
    table.sort(bones)

    crumb(string.format("--- bone inventory: %d ModifyBone nodes ---", #bones))
    local unmapped = 0
    for _, bone in ipairs(bones) do
        local nodeProp = nodePropByBone[bone]
        local line = bone .. " [" .. nodeProp .. "]"
        local ok = pcall(function()
            local node = src[nodeProp]
            local s, t, r = node.Scale, node.Translation, node.Rotation
            line = line .. string.format(
                " S=(%.3f, %.3f, %.3f) T=(%.3f, %.3f, %.3f) R=(%.3f, %.3f, %.3f)",
                s.X, s.Y, s.Z, t.X, t.Y, t.Z, r.Pitch, r.Yaw, r.Roll)
            -- The space is the thing that decides which axis runs along a
            -- limb: in bone space X is usually down the bone, in component
            -- space Z is up (so Z is leg length). Without this the axis
            -- masks in SHAPE are guesswork.
            line = line .. " ScaleSpace=" .. spaceName(node.ScaleSpace) ..
                " ScaleMode=" .. modeName(node.ScaleMode) ..
                " TransSpace=" .. spaceName(node.TranslationSpace) ..
                " RotSpace=" .. spaceName(node.RotationSpace)
        end)
        if not ok then line = line .. " <transform unreadable>" end
        local group = groupOf[bone]
        if group == nil then
            unmapped = unmapped + 1
            line = line .. "  *** NO GROUP ***"
        else
            line = line .. "  -> " .. group
        end
        crumb(line)
    end

    -- Groups naming a bone the ABP has no node for: a typo, or a bone that
    -- really would need the pak rebuilt.
    for group, props in pairs(GROUPS) do
        for _, prop in ipairs(props) do
            if nodePropByBone[boneFromProp(prop)] == nil then
                crumb(string.format("group %s references %s -- no node in the ABP", group, prop))
            end
        end
    end
    crumb(string.format("--- end inventory (%d node(s) in no group) ---", unmapped))
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
    dumpBoneInventory(src)
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

    -- Accumulate each property's multipliers before writing anything: a bone
    -- can belong to more than one group (Thigh covers the whole leg,
    -- ThighGirth only its cross-section) and those should compose. Writing
    -- inside the group loop would just let whichever group came last in
    -- pairs() order win.
    local mult = {}
    for group, props in pairs(GROUPS) do
        local t = settings[group] or 1.0
        local shape = SHAPE[group] or DEFAULT_SHAPE
        for _, prop in ipairs(props) do
            local m = mult[prop]
            if m == nil then
                m = { x = 1.0, y = 1.0, z = 1.0, offsets = 1.0, alpha = 1.0 }
                mult[prop] = m
            end
            if shape.x then m.x = m.x * t end
            if shape.y then m.y = m.y * t end
            if shape.z then m.z = m.z * t end
            if shape.offsets then m.offsets = m.offsets * t end
            m.alpha = m.alpha * t
        end
    end

    for prop, m in pairs(mult) do
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
                s.X = base.s[1] * m.x
                s.Y = base.s[2] * m.y
                s.Z = base.s[3] * m.z
                local tr = node.Translation
                tr.X = base.t[1] * m.offsets
                tr.Y = base.t[2] * m.offsets
                tr.Z = base.t[3] * m.offsets
                local r = node.Rotation
                r.Pitch = base.r[1] * m.offsets
                r.Yaw = base.r[2] * m.offsets
                r.Roll = base.r[3] * m.offsets
                if base.alpha ~= nil then inst[prop] = base.alpha end
            elseif base.alpha ~= nil then
                -- Fallback: alpha attenuation only; engine clamps blend
                -- weight to [0,1], so t>1 saturates at authored shape.
                -- Alpha has no axes, so it takes every group's multiplier.
                inst[prop] = base.alpha * m.alpha
            end
        end) end
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

local ui = { widget = nil, cursor = nil, visible = false, pollActive = false, passthrough = false }

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
-- Panel row order as laid out on screen; see orderedGroups. Invalidated
-- together with childCache whenever the widget is (re)built.
local rowOrderCache = nil

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
local function loadClass(assetPath, classPath, quiet)
    local cls = StaticFindObject(classPath)
    if live(cls) then return cls end

    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if live(helpers) then
        log("loading " .. classPath .. " via GetAsset")
        local ok, err = pcall(function()
            local assetData = {
                ObjectPath = UEHelpers.FindOrAddFName(classPath),
            }
            helpers:GetAsset(assetData)
        end)
        if not ok and not quiet then print("[EveProportionsTuner] GetAsset failed: " .. tostring(err) .. "\n") end
        cls = StaticFindObject(classPath)
        if live(cls) then return cls end
    elseif not quiet then
        print("[EveProportionsTuner] AssetRegistryHelpers not found\n")
    end

    local ok, err = pcall(function() LoadAsset(assetPath) end)
    if not ok and not quiet then print("[EveProportionsTuner] LoadAsset failed: " .. tostring(err) .. "\n") end
    cls = StaticFindObject(classPath)
    if live(cls) then return cls end
    return nil
end

local function loadWidgetClass()
    return loadClass(WIDGET_ASSET, WIDGET_CLASS, false)
end

-- Companion to dumpBoneInventory: print the cooked panel's widget tree, so
-- the runtime-built rows below can be checked against how the authored rows
-- are actually nested.
local function dumpWidgetTree(widget)
    if not CONFIG.DumpBoneInventory or Tuner._treeDumped then return end
    Tuner._treeDumped = true
    crumb("--- panel widget tree ---")
    local function walk(node, depth)
        if not live(node) or depth > 6 then return end
        local name, class = "?", "?"
        pcall(function() name = node:GetFName():ToString() end)
        pcall(function() class = node:GetClass():GetFName():ToString() end)
        crumb(string.rep("  ", depth) .. name .. " (" .. class .. ")")
        local count = 0
        pcall(function() count = node:GetChildrenCount() end)
        if type(count) ~= "number" then return end
        for i = 0, count - 1 do
            local child = nil
            pcall(function() child = node:GetChildAt(i) end)
            walk(child, depth + 1)
        end
    end
    pcall(function() walk(widget.WidgetTree.RootWidget, 0) end)
    crumb("--- end widget tree ---")
end

-- Build a label+slider row for a group the pak has no cooked widgets for,
-- and register it in childCache so findChild/eachSlider treat it exactly
-- like an authored one. Same trick the shortcut-hint TextBlock uses, so it
-- must run before AddToViewport for Slate to build it with the rest of the
-- tree. Cosmetics are copied off the Size row and each step is optional:
-- worst case the row looks out of place but still works. Returns true if
-- both widgets made it into the tree.
-- Clone a cooked widget, so the copy inherits every authored property
-- (font, outline, justification, the whole FSliderStyle with its brushes)
-- rather than the handful worth hand-copying. StaticConstructObject takes a
-- Template for exactly this; if that argument shape isn't supported we fall
-- back to a bare construct plus the properties that matter most, which
-- looks off but still works.
local function cloneWidget(reference, outer, name)
    if not live(reference) then return nil, false end
    local class = nil
    pcall(function() class = reference:GetClass() end)
    if not live(class) then return nil, false end

    local fname = nil
    pcall(function() fname = UEHelpers.FindOrAddFName(name) end)

    local clone = nil
    pcall(function()
        clone = StaticConstructObject(class, outer, fname, 0, 0, false, false, reference)
    end)
    if live(clone) then return clone, true end

    pcall(function() clone = StaticConstructObject(class, outer, fname) end)
    if not live(clone) then
        pcall(function() clone = StaticConstructObject(class, outer) end)
    end
    return live(clone) and clone or nil, false
end

-- Slot layout has to be copied field by field into plain Lua numbers, never
-- as whole structs. Assigning `slot.Padding = other.Padding` silently does
-- nothing here (UE4SS hands back a reference into the source struct rather
-- than a value to store) -- the working idiom in this file is mutating
-- fields, e.g. `slot.Padding.Top = 10.0`. Reading into numbers also matters
-- for moveButtonsToEnd, where the source slot is destroyed by RemoveChild
-- before the values get used again.
local function captureSlotLayout(widget)
    if not live(widget) then return nil end
    local layout = {}
    local ok = pcall(function()
        local slot = widget.Slot
        pcall(function()
            local p = slot.Padding
            layout.padding = { left = p.Left, top = p.Top, right = p.Right, bottom = p.Bottom }
        end)
        pcall(function() layout.hAlign = slot.HorizontalAlignment end)
        pcall(function() layout.vAlign = slot.VerticalAlignment end)
        pcall(function()
            local s = slot.Size
            layout.size = { value = s.Value, rule = s.SizeRule }
        end)
    end)
    if not ok then return nil end
    if CONFIG.DebugLogging then
        -- The runtime rows shipped with zero gap between them once (rows
        -- touching) despite applySlotLayout appearing to run cleanly. This
        -- narrows down which side the fault is actually on: a nil/zero
        -- padding here means the source widget's Slot isn't what we think
        -- it is; a sane value here but a bad result on screen means the
        -- apply side is the one silently no-opping.
        local name = "?"
        pcall(function() name = widget:GetFName():ToString() end)
        if layout.padding ~= nil then
            local p = layout.padding
            log(string.format("captureSlotLayout(%s) padding L=%.2f T=%.2f R=%.2f B=%.2f",
                name, p.left, p.top, p.right, p.bottom))
        else
            log("captureSlotLayout(" .. name .. ") got no padding (slot.Padding read failed, or widget has no Slot yet)")
        end
    end
    return layout
end

-- Same whole-struct caveat as the slot layout above: assigning
-- `dst.Font = src.Font` does not take, so copy the fields that decide how
-- the text reads. sizeOverride keeps a caller's own point size.
local function copyFont(dst, src, sizeOverride)
    if not live(dst) or not live(src) then return end
    pcall(function()
        local from, to = src.Font, dst.Font
        pcall(function() to.FontObject = from.FontObject end)
        pcall(function() to.FontMaterial = from.FontMaterial end)
        pcall(function() to.TypefaceFontName = from.TypefaceFontName end)
        pcall(function() to.LetterSpacing = from.LetterSpacing end)
        pcall(function() to.Size = sizeOverride or from.Size end)
        pcall(function()
            local fo, too = from.OutlineSettings, to.OutlineSettings
            too.OutlineSize = fo.OutlineSize
            too.bSeparateFillAlpha = fo.bSeparateFillAlpha
        end)
    end)
end

local function applySlotLayout(slot, layout)
    if slot == nil or layout == nil then return end
    -- Setter-then-fallback-on-throw was the original shape here, on the
    -- theory that the setter both applies the value and marks the slot
    -- dirty for Slate. In practice the new rows came out with zero padding
    -- (rows touching, no gap at all) even though nothing threw -- i.e.
    -- SetPadding can complete "successfully" without the struct argument
    -- actually landing, the same silent-no-op class of bug already found in
    -- the whole-struct-assignment case (see the comment above
    -- captureSlotLayout). A pcall that doesn't throw is not proof the value
    -- took. So: always follow the setter with the field-mutation idiom
    -- that's proven to stick (the shortcut-hint code has relied on it for a
    -- while), rather than only reaching for it when the setter errors.
    if layout.padding ~= nil then
        local p = layout.padding
        pcall(function()
            slot:SetPadding({ Left = p.left, Top = p.top, Right = p.right, Bottom = p.bottom })
        end)
        pcall(function()
            local m = slot.Padding
            m.Left, m.Top, m.Right, m.Bottom = p.left, p.top, p.right, p.bottom
        end)
        if CONFIG.DebugLogging then
            local after = "?"
            pcall(function()
                local m = slot.Padding
                after = string.format("L=%.2f T=%.2f R=%.2f B=%.2f", m.Left, m.Top, m.Right, m.Bottom)
            end)
            log(string.format("applySlotLayout padding target L=%.2f T=%.2f R=%.2f B=%.2f, readback=%s",
                p.left, p.top, p.right, p.bottom, after))
        end
    end
    if layout.hAlign ~= nil then
        pcall(function() slot:SetHorizontalAlignment(layout.hAlign) end)
        pcall(function() slot.HorizontalAlignment = layout.hAlign end)
    end
    if layout.vAlign ~= nil then
        pcall(function() slot:SetVerticalAlignment(layout.vAlign) end)
        pcall(function() slot.VerticalAlignment = layout.vAlign end)
    end
    if layout.size ~= nil then
        local s = layout.size
        pcall(function() slot:SetSize({ Value = s.value, SizeRule = s.rule }) end)
        pcall(function()
            local sz = slot.Size
            sz.Value, sz.SizeRule = s.value, s.rule
        end)
    end
end

-- New rows can only be appended -- UPanelWidget::ShiftChild isn't a UFUNCTION
-- so it can't be called by reflection, and there's no InsertChildAt either.
-- Appending puts them below Reset/Hide, which already sit at the bottom of
-- the VBox. Fix it from the other end: once the rows are in, take the
-- buttons out and re-add them so they land last again. Slot properties are
-- captured and restored, since RemoveChild drops the slot.
local function moveButtonsToEnd(widget)
    local vbox = findChild(widget, "VBox")
    if not live(vbox) then return end

    -- A button may sit directly in the VBox or inside a row container; move
    -- whichever direct child of the VBox contains it.
    local function directChildContaining(name)
        local target = findChild(widget, name)
        if not live(target) then return nil end
        local targetAddr = nil
        pcall(function() targetAddr = target:GetAddress() end)
        if targetAddr == nil then return nil end

        local function contains(node, depth)
            if not live(node) or depth > 6 then return false end
            local addr = nil
            pcall(function() addr = node:GetAddress() end)
            if addr == targetAddr then return true end
            local count = 0
            pcall(function() count = node:GetChildrenCount() end)
            if type(count) ~= "number" then return false end
            for i = 0, count - 1 do
                local child = nil
                pcall(function() child = node:GetChildAt(i) end)
                if contains(child, depth + 1) then return true end
            end
            return false
        end

        local count = 0
        pcall(function() count = vbox:GetChildrenCount() end)
        if type(count) ~= "number" then return nil end
        for i = 0, count - 1 do
            local child = nil
            pcall(function() child = vbox:GetChildAt(i) end)
            if contains(child, 0) then return child end
        end
        return nil
    end

    local moved, seen = {}, {}
    for _, name in ipairs({ "Btn_Reset", "Btn_Hide" }) do
        local holder = directChildContaining(name)
        if live(holder) then
            local addr = nil
            pcall(function() addr = holder:GetAddress() end)
            if addr ~= nil and not seen[addr] then
                seen[addr] = true
                table.insert(moved, holder)
            end
        end
    end

    for _, holder in ipairs(moved) do
        local ok = pcall(function()
            -- Read the layout out as numbers first: RemoveChild destroys the
            -- slot these values live in.
            local layout = captureSlotLayout(holder)
            if not vbox:RemoveChild(holder) then error("RemoveChild refused") end
            applySlotLayout(vbox:AddChild(holder), layout)
        end)
        if not ok then
            log("could not move buttons below the new rows")
            return
        end
    end
    if #moved > 0 then log("moved " .. #moved .. " button row(s) back to the bottom") end
end

-- Which authored row the new ones are modelled on. Deliberately not the
-- first row: a list's first entry usually carries different top padding from
-- the ones below it, and copying that is what makes an appended row sit at
-- the wrong spacing. Prefer a row from the middle/end of the list.
local ROW_TEMPLATE_ORDER = { "FacBody", "Thigh", "Belly", "Size" }

local function findRowTemplate(widget)
    for _, group in ipairs(ROW_TEMPLATE_ORDER) do
        local label = findChild(widget, "Label_" .. group)
        local slider = findChild(widget, "Slider_" .. group)
        if label ~= nil and slider ~= nil then return label, slider, group end
    end
    return nil, nil, nil
end

local function buildSliderRow(widget, group)
    local refLabel, refSlider, refGroup = findRowTemplate(widget)
    if refLabel == nil or refSlider == nil then
        log("cannot build row for " .. group .. " (no authored row to copy)")
        return false
    end

    -- Rows only line up with the rest of the panel if they share the
    -- authored rows' container. Use the Size row's own parent when that is
    -- the VBox; if the authored rows turn out to be wrapped in something
    -- per-row, appending into that wrapper would nest the new row inside the
    -- Size row, so fall back to the VBox and say so (the widget-tree dump
    -- under DumpBoneInventory shows which case this is).
    --
    -- Confirmed via that dump: sliders are each wrapped in their own SizeBox
    -- (Label_X sits directly in VBox, but Slider_X sits inside SB_X, which
    -- is VBox's actual child). refSlider's own Slot -- inside SB_X -- reads
    -- zero padding every time; the row-to-row gap lives on SB_X's Slot, one
    -- level up. That's why capturing refSlider directly always produced a
    -- flush/no-gap row: the padding was being read off the wrong widget.
    -- sliderLayoutSource remembers the actual wrapper so captureSlotLayout
    -- below reads the slot that really carries the spacing.
    local vbox = findChild(widget, "VBox")
    local parent = nil
    local sliderLayoutSource = refSlider
    pcall(function() parent = refSlider:GetParent() end)
    if live(parent) and live(vbox) then
        local pa, va = nil, nil
        pcall(function() pa = parent:GetAddress() end)
        pcall(function() va = vbox:GetAddress() end)
        if pa ~= nil and va ~= nil and pa ~= va then
            log("authored rows are nested below VBox; appending to VBox instead, " ..
                "reading row spacing off the wrapper instead of the slider itself")
            sliderLayoutSource = parent
            parent = vbox
        end
    elseif not live(parent) then
        parent = vbox
    end
    if not live(parent) then
        log("cannot build row for " .. group .. " (no row container)")
        return false
    end

    local tree = widget.WidgetTree
    local label, labelCloned = cloneWidget(refLabel, tree, "Label_" .. group)
    local slider, sliderCloned = cloneWidget(refSlider, tree, "Slider_" .. group)
    if label == nil or slider == nil then
        log("row construction failed for " .. group)
        return false
    end

    if not labelCloned then
        -- Bare construct: copy what visibly matters.
        copyFont(label, refLabel)
        pcall(function() label.ColorAndOpacity = refLabel.ColorAndOpacity end)
        pcall(function() label.Justification = refLabel.Justification end)
        pcall(function() label.ShadowOffset = refLabel.ShadowOffset end)
        pcall(function() label.ShadowColorAndOpacity = refLabel.ShadowColorAndOpacity end)
    end
    if not sliderCloned then
        -- FSliderStyle is deeply nested (brush per state), so there is no
        -- practical field-by-field copy; this whole-struct assign may not
        -- take. Only reached when cloning failed, which is already the
        -- degraded path.
        pcall(function() slider.WidgetStyle = refSlider.WidgetStyle end)
        pcall(function() slider.Orientation = refSlider.Orientation end)
        pcall(function() slider.SliderBarColor = refSlider.SliderBarColor end)
        pcall(function() slider.SliderHandleColor = refSlider.SliderHandleColor end)
        pcall(function() slider.IndentHandle = refSlider.IndentHandle end)
    end

    local txt = makeText(DISPLAY[group] or group)
    if txt ~= nil then pcall(function() label:SetText(txt) end) end

    -- Capture the authored rows' slot layout before adding anything: padding
    -- and alignment are what make a row sit at the same width and spacing as
    -- its neighbours, and cloning the widget doesn't bring the slot along
    -- (AddChild always makes a fresh one).
    local labelLayout = captureSlotLayout(refLabel)
    local sliderLayout = captureSlotLayout(sliderLayoutSource)

    local added = pcall(function()
        applySlotLayout(parent:AddChild(label), labelLayout)
        applySlotLayout(parent:AddChild(slider), sliderLayout)
    end)
    if not added then
        log("row for " .. group .. " could not be added to its container")
        return false
    end

    childCache["Label_" .. group] = label
    childCache["Slider_" .. group] = slider
    log(string.format("built runtime row for %s from %s (cloned label=%s slider=%s)",
        group, tostring(refGroup), tostring(labelCloned), tostring(sliderCloned)))
    return true
end

local function ensureWidget()
    if live(ui.widget) then return ui.widget end
    ui.widget = nil

    -- Purge instances orphaned by Lua hot-reload: the old state's widget
    -- stays on the viewport and can sit on top of (and eat input meant
    -- for) the fresh one. Same for a cursor left behind by the old state
    -- (this can also catch CNS's own cursor if its UI is open right now —
    -- acceptable, reopening the CNS UI restores it).
    pcall(function()
        local stale = FindAllOf("WBP_EveProportions_C")
        if stale ~= nil then
            local purged = 0
            for _, w in ipairs(stale) do
                if pcall(function() w:RemoveFromParent() end) then purged = purged + 1 end
            end
            if purged > 0 then log("purged " .. purged .. " stale widget instances") end
        end
        local staleCursors = FindAllOf("WB_MouseCursor_C")
        if staleCursors ~= nil then
            for _, w in ipairs(staleCursors) do pcall(function() w:RemoveFromParent() end) end
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
    rowOrderCache = nil
    ui.widget = widget -- findChild callers below need it set
    dumpWidgetTree(widget)

    -- Rows the pak doesn't ship, appended in GROUP_ORDER before the hint
    -- text below so the hint stays at the bottom of the panel. A group whose
    -- row can't be built keeps its saved value and applies as usual, just
    -- with no way to change it from the panel.
    local builtRows = false
    for _, group in ipairs(GROUP_ORDER) do
        if RUNTIME_GROUPS[group] then
            builtRows = buildSliderRow(widget, group) or builtRows
        end
    end
    -- Appending put the new rows below Reset/Hide; put the buttons back at
    -- the bottom. Before the hint block, so the hint stays last as it was.
    if builtRows then moveButtonsToEnd(widget) end

    local found, expected = 0, #GROUP_ORDER
    eachSlider(widget, function(group, slider)
        found = found + 1
        -- Reassert the intended ranges; runtime instances have shown up with
        -- USlider defaults (0..1) instead of the cooked values.
        pcall(function()
            local range = RANGE[group] or DEFAULT_RANGE
            slider.MinValue = range.min
            slider.MaxValue = range.max
        end)
        pcall(function() slider:SetValue(settings[group]) end)
    end)
    log("sliders found: " .. found .. "/" .. expected)

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
        copyFont(hint, findChild(widget, "Label_Size"), 16)
        pcall(function() hint:SetAutoWrapText(true) end)
        local hintText = makeText(
            "Up/Down arrows: pick slider (marked >)\n" ..
            "Left/Right: fine-tune it   Shift+Left/Right: coarse\n" ..
            "1-9: load preset    Shift+1-9: save preset\n" ..
            "0: bind to worn outfit    Shift+0: unbind\n" ..
            "F8: game input passthrough (camera/other mods)")
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

local function hideCursor()
    if ui.cursor ~= nil then pcall(function() ui.cursor:RemoveFromParent() end) end
    ui.cursor = nil
end

local cursorMissing = false -- CNS absent; don't retry the load every open
local function showCursor()
    if cursorMissing then return end
    if live(ui.cursor) then
        local onViewport = false
        pcall(function() onViewport = ui.cursor:IsInViewport() end)
        if onViewport then return end
        hideCursor()
    end
    local cls = loadClass(CURSOR_ASSET, CURSOR_CLASS, true)
    if not live(cls) then
        cursorMissing = true
        log("virtual cursor unavailable (DekCNS not installed?)")
        return
    end
    local pc = UEHelpers.GetPlayerController()
    local wbl = getWBL()
    if not live(pc) or wbl == nil then return end
    local cursor = nil
    pcall(function() cursor = wbl:Create(pc, cls, pc) end)
    if not live(cursor) then return end
    pcall(function() cursor:AddToViewport(200) end) -- above the panel (100)
    ui.cursor = cursor
    log("virtual cursor shown")
end

-- Which group the arrow keys act on: Up/Down move the selection, Left/Right
-- nudge it. Declared here because updateLabel marks the selected row.
local lastTouched = "Size"

local function updateLabel(widget, group)
    local label = findChild(widget, "Label_" .. group)
    if label == nil then return end
    pcall(function()
        -- The selected row is marked in its label; there is no focus ring to
        -- lean on, and nothing else would show which slider Left/Right hits.
        local mark = (group == lastTouched) and "> " or "   "
        local txt = makeText(string.format("%s%s  %.2f", mark, DISPLAY[group] or group, settings[group]))
        if txt ~= nil then label:SetText(txt) end
    end)
end

-- Repaint every label, e.g. after the selection moved off one row onto another.
local function updateAllLabels()
    if not live(ui.widget) then return end
    for _, group in ipairs(GROUP_ORDER) do updateLabel(ui.widget, group) end
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
        if ui.passthrough then
            -- UIOnly blocks ALL native/action-mapped input, not just mouse --
            -- that's why other mods' keybinds (e.g. DekCNS's own camera-drag
            -- and its "N" shortcut) go dead while our panel is open, even
            -- though our own F7/arrow/preset keys keep working (those are
            -- UE4SS OS-level hooks, not routed through UE's input system at
            -- all). Passthrough mode trades the UIOnly slider-drag safety
            -- for letting native input reach the game again.
            pcall(function() wbl:SetInputMode_GameAndUIEx(pc, ui.widget, 0, false) end)
        else
            -- UIOnly is the aggressive option: SB's own input handling
            -- consumes mouse events in GameAndUI mode. Game input is
            -- restored on hide.
            local ok = pcall(function() wbl:SetInputMode_UIOnlyEx(pc, ui.widget, 0) end)
            if not ok then
                crumb("UIOnlyEx failed, falling back to GameAndUIEx")
                pcall(function() wbl:SetInputMode_GameAndUIEx(pc, ui.widget, 0, false) end)
            end
        end
    else
        pcall(function() wbl:SetInputMode_GameOnly(pc) end)
    end
end

local function togglePassthrough()
    if not ui.visible then return end
    ui.passthrough = not ui.passthrough
    crumb(ui.passthrough and "game input passthrough ON (camera/other mods' keys active; slider drags may misbehave)"
                          or "game input passthrough OFF (sliders safe again)")
end

local hideUI -- forward declaration

local dirtyAt = nil
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
-- allowRebuild=false suppresses the rebuild branch for callers that run many
-- times a second (held-arrow repeat): rebuilding the whole panel at 12 Hz
-- would be far worse than a handle that lags until the key comes back up.
local function pushSettingsToSliders(allowRebuild)
    if allowRebuild == nil then allowRebuild = true end
    if not ui.visible or not live(ui.widget) then return end
    local mismatch = false
    eachSlider(ui.widget, function(group, slider)
        pcall(function() slider:SetValue(settings[group]) end)
        local rb = readSlider(slider)
        if rb == nil or math.abs(rb - settings[group]) > 0.0005 then mismatch = true end
        updateLabel(ui.widget, group)
    end)
    if mismatch and allowRebuild then
        crumb("slider push: SetValue readback mismatch, rebuilding widget")
        pcall(function() ui.widget:RemoveFromParent() end)
        ui.widget = nil
        local rebuilt = ensureWidget()
        if rebuilt ~= nil then
            for _, group in ipairs(GROUP_ORDER) do updateLabel(rebuilt, group) end
            pcall(function() rebuilt:SetVisibility(0) end)
            setUIInputMode(true)
            showCursor() -- ensureWidget's purge may have taken the cursor down too
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
        -- Reject out-of-range reads. A slider whose Slate widget never built
        -- reads back its USlider default (0.0 on a 0..1 range) forever, and
        -- without this the poll would keep stamping that over the real
        -- setting -- fighting the arrow keys and wiping the saved value.
        local range = RANGE[group] or DEFAULT_RANGE
        if value ~= nil and (value < range.min - 0.0005 or value > range.max + 0.0005) then
            if not Tuner._rangeWarned then
                Tuner._rangeWarned = true
                log(string.format("ignoring out-of-range read from %s slider: %.3f", group, value))
            end
            value = nil
        end
        if value ~= nil and math.abs(value - settings[group]) > 0.0005 then
            settings[group] = value
            -- Dragging a slider also selects it, which moves the marker off
            -- whichever row had it.
            local selectionMoved = lastTouched ~= group
            lastTouched = group
            if selectionMoved then updateAllLabels() else updateLabel(widget, group) end
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
    showCursor()
    startPolling()
    log("UI shown")
end

hideUI = function()
    ui.visible = false
    ui.passthrough = false
    if dirtyAt ~= nil then dirtyAt = nil; flushSave() end
    if live(ui.widget) then
        pcall(function() ui.widget:SetVisibility(1) end) -- ESlateVisibility::Collapsed
    end
    hideCursor()
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

-- Selection order must follow the panel as drawn, not GROUP_ORDER: the
-- cooked WBP lays its rows out in its own order, so walking GROUP_ORDER made
-- the marker jump around the list. Walk the widget tree instead and record
-- each slider in the order it is actually laid out.
local function orderedGroups()
    if rowOrderCache ~= nil then return rowOrderCache end
    if not live(ui.widget) then return {} end

    -- Address -> group, for the sliders we know about.
    local byAddress, pending = {}, {}
    for _, group in ipairs(GROUP_ORDER) do
        local slider = findChild(ui.widget, "Slider_" .. group)
        if slider ~= nil then
            local addr = nil
            pcall(function() addr = slider:GetAddress() end)
            if addr ~= nil then
                byAddress[addr] = group
                pending[group] = true
            end
        end
    end

    local ordered = {}
    local function walk(node, depth)
        if not live(node) or depth > 8 then return end
        local addr = nil
        pcall(function() addr = node:GetAddress() end)
        local group = addr ~= nil and byAddress[addr] or nil
        if group ~= nil and pending[group] then
            pending[group] = nil
            table.insert(ordered, group)
        end
        local count = 0
        pcall(function() count = node:GetChildrenCount() end)
        if type(count) ~= "number" then return end
        for i = 0, count - 1 do
            local child = nil
            pcall(function() child = node:GetChildAt(i) end)
            walk(child, depth + 1)
        end
    end
    pcall(function() walk(ui.widget.WidgetTree.RootWidget, 0) end)

    -- Anything the walk missed (not reachable through GetChildAt) still
    -- belongs in the list; append it in GROUP_ORDER order.
    for _, group in ipairs(GROUP_ORDER) do
        if pending[group] then table.insert(ordered, group) end
    end

    rowOrderCache = ordered
    log("row order: " .. table.concat(ordered, ", "))
    return ordered
end

-- Move the arrow-key selection up/down the panel. Groups whose row failed to
-- build are skipped -- selecting a slider that isn't on screen would leave
-- Left/Right adjusting something invisible.
local function selectSlider(direction)
    if not ui.visible or not live(ui.widget) then return end

    local rows = orderedGroups()
    if #rows == 0 then return end

    local at = 1
    for i, group in ipairs(rows) do
        if group == lastTouched then
            at = i
            break
        end
    end
    -- Down (direction 1) moves toward the bottom of the panel; wraps at
    -- both ends.
    local target = ((at - 1 + direction) % #rows) + 1
    if rows[target] == lastTouched then return end
    lastTouched = rows[target]
    updateAllLabels()
    log("selected slider: " .. lastTouched)
end

local function nudge(direction, step, allowRebuild)
    if not ui.visible then return end
    local range = RANGE[lastTouched] or DEFAULT_RANGE
    local v = settings[lastTouched] + (step or CONFIG.FineTuneStep) * direction
    v = math.max(range.min, math.min(range.max, v))
    if math.abs(v - settings[lastTouched]) < 0.00005 then return end
    settings[lastTouched] = v
    pushSettingsToSliders(allowRebuild)
    applyToAllInstances(true)
    dirtyAt = os.clock()
end

-- Held-arrow repeat was tried and dropped: RegisterKeyBind only delivers a
-- press, never a release or OS auto-repeat, so a poll-driven repeat needed
-- PlayerController:IsInputKeyDown to see the key was still down. The panel
-- runs in UIOnly input mode, which consumes key state before it reaches the
-- PlayerController, so the poll never saw the hold -- confirmed dead end,
-- not worth keeping the complexity around. Shift+arrow below is the
-- keeper: it covers the same "cross a wide range quickly" need in a
-- handful of presses without depending on input-mode plumbing at all.
local COARSE_MULTIPLIER = 10

local function nudgeCoarse(direction)
    nudge(direction, CONFIG.FineTuneStep * COARSE_MULTIPLIER)
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

    local passthroughKey = Key[CONFIG.PassthroughKey]
    if passthroughKey ~= nil then
        RegisterKeyBind(passthroughKey, function() ExecuteInGameThread(togglePassthrough) end)
        log("passthrough toggle bound to " .. CONFIG.PassthroughKey)
    else
        print("[EveProportionsTuner] unknown PassthroughKey '" .. tostring(CONFIG.PassthroughKey) .. "'\n")
    end

    -- Panel-only keys (each handler no-ops while the panel is closed):
    -- Up/Down pick the slider, Left/Right fine-adjust it, 1..9 load /
    -- Shift+1..9 save presets, 0 binds the worn outfit, Shift+0 unbinds it.
    pcall(function()
        RegisterKeyBind(Key.LEFT_ARROW, function() ExecuteInGameThread(function() nudge(-1) end) end)
        RegisterKeyBind(Key.RIGHT_ARROW, function() ExecuteInGameThread(function() nudge(1) end) end)
        RegisterKeyBind(Key.LEFT_ARROW, { ModifierKey.SHIFT }, function() ExecuteInGameThread(function() nudgeCoarse(-1) end) end)
        RegisterKeyBind(Key.RIGHT_ARROW, { ModifierKey.SHIFT }, function() ExecuteInGameThread(function() nudgeCoarse(1) end) end)
        RegisterKeyBind(Key.UP_ARROW, function() ExecuteInGameThread(function() selectSlider(-1) end) end)
        RegisterKeyBind(Key.DOWN_ARROW, function() ExecuteInGameThread(function() selectSlider(1) end) end)
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
