-- LocalScript: Chicleteira Bicicleteira Event
-- Mirrors Ay Mi Gatito structure: no remotes, ClientEventUtils-based,
-- asset-injected Chicleteras, full spray + burst pipeline client-side.

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local CollectionService  = game:GetService("CollectionService")
local HttpService        = game:GetService("HttpService")
local RunService         = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local EVENT_NAME   = "Chicleteira Bicicleteira"
local EVENT_SCRIPT = ReplicatedStorage:WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("Chicleteira Bicicleteira")

-- ─── Constants ────────────────────────────────────────────────────────────────

local BLOCKING_TRAIT     = "Paint"
local SPRAY_WAIT_MIN     = 4
local SPRAY_WAIT_MAX     = 7
local SPRAY_REACH_DIST   = 50
local SPRAY_ANIM_WAIT    = 1.4
local FORCE_SPRAY_ATTR   = "ForceSpray"
local ACTIVATION_DELAY   = 3

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local burstAsset = EVENT_SCRIPT:WaitForChild("Burst")

-- ─── Chicleteras folder injection ─────────────────────────────────────────────

local CHICLETERAS_FOLDER do
    local objects = game:GetObjects("rbxassetid://111606243506873")
    for _, obj in ipairs(objects) do
        obj.Name   = "Chicleteras"
        obj.Parent = workspace
        CHICLETERAS_FOLDER = obj
    end
end

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove  = Trove.new()
local isActive    = true
local rng         = Random.new()

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getTraits(animal: Model): ({ string }, { [string]: boolean })
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasBlockingTrait(animal: Model): boolean
    local _, set = getTraits(animal)
    return set[BLOCKING_TRAIT] == true
end

local function getChicleteras(): { Model }
    local out = {}
    if not CHICLETERAS_FOLDER or not CHICLETERAS_FOLDER.Parent then return out end
    for _, obj in ipairs(CHICLETERAS_FOLDER:GetChildren()) do
        table.insert(out, obj)
    end
    return out
end

-- ─── Burst ────────────────────────────────────────────────────────────────────

local function doBurst(target: Model)
    if not target or not target.PrimaryPart then return end
    ClientEventUtils.playBurst(burstAsset, target.PrimaryPart, {
        ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"].Hit,
    })
end

-- ─── Spray ────────────────────────────────────────────────────────────────────

local function doSpray(chicletera: Model, target: Model)
    -- Set ForceSpray so the observer on the chicletera reacts (animation, sound)
    chicletera:SetAttribute(FORCE_SPRAY_ATTR, target.Name)

    task.wait(SPRAY_ANIM_WAIT)

    if not isActive then
        chicletera:SetAttribute(FORCE_SPRAY_ATTR, nil)
        return
    end

    -- Apply trait
    local traits, traitSet = getTraits(target)
    if not traitSet[BLOCKING_TRAIT] then
        table.insert(traits, BLOCKING_TRAIT)
        target:SetAttribute("Traits", HttpService:JSONEncode(traits))
    end

    -- Burst VFX
    doBurst(target)

    chicletera:SetAttribute(FORCE_SPRAY_ATTR, nil)
end

-- ─── Spray loop ───────────────────────────────────────────────────────────────

local function runSprayLoop()
    -- Live animal cache — same pattern as Ay Mi Gatito attack loop
    local cachedAnimals = CollectionService:GetTagged("Animal")
    eventTrove:Add(CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(inst)
        table.insert(cachedAnimals, inst)
    end))
    eventTrove:Add(CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(inst)
        for i = #cachedAnimals, 1, -1 do
            if cachedAnimals[i] == inst then
                table.remove(cachedAnimals, i)
                break
            end
        end
    end))

    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(rng:NextNumber(SPRAY_WAIT_MIN, SPRAY_WAIT_MAX))
            if not isActive then break end

            local chicleteras = getChicleteras()
            if #chicleteras == 0 then continue end

            local chicletera    = chicleteras[rng:NextInteger(1, #chicleteras)]
            local chicleteraPos = chicletera:GetPivot().Position

            -- Find closest unblocked animal within reach
            local closest     = nil
            local closestDist = SPRAY_REACH_DIST

            for _, animal in ipairs(cachedAnimals) do
                if animal.PrimaryPart and not hasBlockingTrait(animal) then
                    local dist = (animal.PrimaryPart.Position - chicleteraPos).Magnitude
                    if dist < closestDist then
                        closest     = animal
                        closestDist = dist
                    end
                end
            end

            if not closest then continue end
            -- Skip if chicletera already mid-spray
            if chicletera:GetAttribute(FORCE_SPRAY_ATTR) then continue end

            local sprayTrove = eventTrove:Extend()
            sprayTrove:Add(task.spawn(function()
                doSpray(chicletera, closest)
                sprayTrove:Clean()
            end))
        end
    end))
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    local elapsed   = workspace:GetServerTimeNow() - startedAt
    local remaining = math.max(0, ACTIVATION_DELAY - elapsed)
    if remaining > 0 then task.wait(remaining) end
    if not isActive then return end

    if not CHICLETERAS_FOLDER then
        warn("[ChicleteraBicicleteira] Folder failed to load from asset")
        return
    end

    runSprayLoop()

    -- Cleanup watchdog
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false

    -- Clear all ForceSpray attrs before teardown so observers don't fire into nil
    for _, chicletera in ipairs(getChicleteras()) do
        chicletera:SetAttribute(FORCE_SPRAY_ATTR, nil)
    end

    eventTrove:Destroy()

    if CHICLETERAS_FOLDER and CHICLETERAS_FOLDER.Parent then
        CHICLETERAS_FOLDER:Destroy()
    end
end

task.spawn(main)
