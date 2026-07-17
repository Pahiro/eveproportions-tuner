-- EveProportions: event-driven post-process refresh without mesh replacement.

local ABP_PATH = "/Game/Mods/EveProportions/ABP_EveProportions.ABP_EveProportions_C"
local EVE_CLASS = "/Game/Art/Character/PC/CH_P_EVE_01/Blueprints/CH_P_EVE_01_Blueprint.CH_P_EVE_01_Blueprint_C"
local SET_MESH_HOOK = EVE_CLASS .. ":NotifyBP_SetMesh"
local CNS_CLASS = "/Game/Mods/DekCNS_P/ModActor.ModActor_C"
local CNS_UI_CLASS = "/Game/Mods/DekCNS_P/Widgets/WB_CustomNanoSootUI.WB_CustomNanoSootUI_C"
local CNS_HOOKS = {
    CNS_CLASS .. ":Set Custom Outfit",
    CNS_CLASS .. ":UpdateOutfitConfiguration",
    CNS_CLASS .. ":UpdateActiveOutfit",
    CNS_CLASS .. ":RemoveCustomOutfit",
    CNS_CLASS .. ":ReloadDataFromLastSave",
    CNS_CLASS .. ":PrepareNanoSootDatas",
    CNS_UI_CLASS .. ":OnOutfitButtonClicked",
    CNS_UI_CLASS .. ":BndEvt__WB_CustomNanoSootUI_WB_OutfitPresets_K2Node_ComponentBoundEvent_33_OnClickedSelectPreset__DelegateSignature"
}

local CONFIG = { EnableCNSTracking = true, DebugLogging = false }
pcall(function()
    local supplied = require("EveProportionsConfig")
    if type(supplied) == "table" then
        if supplied.EnableCNSTracking ~= nil then
            CONFIG.EnableCNSTracking = supplied.EnableCNSTracking == true
        end
        if supplied.DebugLogging ~= nil then
            CONFIG.DebugLogging = supplied.DebugLogging == true
        end
    end
end)

local Tuner = nil
pcall(function() Tuner = require("EveProportionsTuner") end)

local logBudget = 12
local function log(message)
    if not CONFIG.DebugLogging or logBudget <= 0 then return end
    logBudget = logBudget - 1
    print("[EveProportions] " .. message .. "\n")
end

local function unwrap(value)
    if value == nil then return nil end
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end

local function live(value)
    if value == nil then return false end
    local ok, result = pcall(function() return value:IsValid() end)
    return ok and result == true
end

local function fullName(value)
    if not live(value) then return nil end
    local ok, result = pcall(function() return value:GetFullName() end)
    if ok then return result end
    return nil
end

local function isEve(character)
    local name = fullName(character)
    return name ~= nil and name:find("CH_P_EVE_01_Blueprint_C", 1, true) ~= nil
end

local function isCustomMesh(asset)
    local name = fullName(asset)
    return name ~= nil and name:find("/Game/Art/Character/", 1, true) == nil
end

local cachedABP = nil
local function getABP()
    if live(cachedABP) then return cachedABP end
    local ok, result = pcall(function() return StaticFindObject(ABP_PATH) end)
    if ok and live(result) then cachedABP = result; return result end
    return nil
end

local function getBody(character)
    if not isEve(character) then return nil end
    local mesh = nil
    pcall(function() mesh = character:GetSBSkeletalMeshComponent(0) end)
    if live(mesh) then return mesh end
    pcall(function() mesh = character.Mesh end)
    if live(mesh) then return mesh end
    return nil
end

local function getMeshAsset(component)
    local asset = nil
    if live(component) then pcall(function() asset = component.SkeletalMesh end) end
    if live(asset) then return asset end
    return nil
end

local function shouldTrackAsset(asset)
    return CONFIG.EnableCNSTracking or not isCustomMesh(asset)
end

local function stampAsset(asset, source)
    local abp = getABP()
    if not live(abp) or not live(asset) or not shouldTrackAsset(asset) then return false end
    local ok = pcall(function() asset.PostProcessAnimBlueprint = abp end)
    if ok then log("stamp " .. tostring(source)) end
    return ok
end

local currentEve = nil
local refreshing = false
local refreshQueued = false
local pendingCharacter = nil
local pendingSource = nil

-- SetAnimationMode intentionally reinitializes an existing Animation Blueprint
-- mode in UE 4.26. This recreates the post-process instance without replacing
-- the skeletal mesh or rebuilding its render, physics, and clothing state.
local function refreshAnimation(character, source)
    if refreshing then return end
    local body = getBody(character)
    local asset = getMeshAsset(body)
    if not live(body) or not live(asset) or not stampAsset(asset, source) then return end

    local active = nil
    pcall(function() active = body:GetPostProcessInstance() end)
    local activeName = fullName(active)
    if activeName ~= nil and activeName:find("ABP_EveProportions_C", 1, true) ~= nil then
        log("skip refresh " .. tostring(source) .. " (already active)")
        if Tuner then pcall(function() Tuner.ApplyTo(active) end) end
        return
    end

    local mode = nil
    local gotMode = pcall(function() mode = body:GetAnimationMode() end)
    if not gotMode or mode == nil then return end

    local before = active
    refreshing = true
    local initialized = pcall(function() body:SetAnimationMode(mode) end)
    refreshing = false
    local after = nil
    pcall(function() after = body:GetPostProcessInstance() end)
    if Tuner then pcall(function() Tuner.ApplyTo(after) end) end
    log("refresh " .. tostring(source) .. " mode=" .. tostring(mode) ..
        " call=" .. tostring(initialized) .. " before=" .. tostring(fullName(before)) ..
        " after=" .. tostring(fullName(after)))
end

local function queueRefresh(character, source)
    character = unwrap(character)
    if not isEve(character) then return end
    currentEve = character
    pendingCharacter = character
    pendingSource = source
    if refreshQueued then return end
    refreshQueued = true
    ExecuteInGameThread(function()
        refreshQueued = false
        local target, trigger = pendingCharacter, pendingSource
        pendingCharacter, pendingSource = nil, nil
        refreshAnimation(target, trigger)
    end)
end

local characterHookRegistered = false
local registerCNSHooks
local function registerCharacterHook()
    if characterHookRegistered then return end
    local ok = pcall(function()
        RegisterHook(SET_MESH_HOOK, function(context, meshSlot)
            if refreshing then return end
            local slot = tonumber(unwrap(meshSlot))
            if slot ~= 0 then return end
            local character = unwrap(context)
            if isEve(character) then currentEve = character end
            -- CNS classes are commonly unavailable at ClientRestart and become
            -- resident by the first real body SetMesh event.
            registerCNSHooks()
            local asset = getMeshAsset(getBody(currentEve))
            if not shouldTrackAsset(asset) then return end
            stampAsset(asset, "NotifyBP_SetMesh post")
            -- Custom/CNS changes refresh at CNS's outfit boundaries. Vanilla can
            -- refresh immediately at the standard character SetMesh boundary.
            if not isCustomMesh(asset) then queueRefresh(currentEve, "SetMesh") end
        end)
    end)
    if ok then characterHookRegistered = true; log("character post-hook registered") end
end

local cnsHooksRegistered = {}
registerCNSHooks = function()
    if not CONFIG.EnableCNSTracking then return end
    local count = 0
    for _, hookPath in ipairs(CNS_HOOKS) do
        if not cnsHooksRegistered[hookPath] then
            local ok = pcall(function()
                RegisterHook(hookPath, function()
                    queueRefresh(currentEve, "CNS " .. hookPath)
                end)
            end)
            if ok then cnsHooksRegistered[hookPath] = true; count = count + 1 end
        end
    end
    if count > 0 then log("CNS animation hooks added=" .. tostring(count)) end
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart",
    function() end,
    function(context, newPawn)
        local pawn = unwrap(newPawn)
        if not isEve(pawn) then
            local controller = unwrap(context)
            if live(controller) then pcall(function() pawn = controller:GetPawn() end) end
        end
        if isEve(pawn) then currentEve = pawn end
        registerCharacterHook()
        registerCNSHooks()
        queueRefresh(pawn, "ClientRestart")
    end)

log("loaded (animation-only refresh; CNS tracking=" .. tostring(CONFIG.EnableCNSTracking) .. ")")
