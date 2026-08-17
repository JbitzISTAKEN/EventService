if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local Observers        = require(ReplicatedStorage.Packages.Observers)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local EVENT_NAME = "Meowl"

local function getEffectEventName()
    for attr, val in ReplicatedStorage:GetAttributes() do
        if type(val) == "boolean" and val and attr:sub(-5) == "Event" then
            return attr
        end
    end
end

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local effectEventName = getEffectEventName()
if not effectEventName then
    repeat
        ReplicatedStorage.AttributeChanged:Wait()
        effectEventName = getEffectEventName()
    until effectEventName
end

while not (_G.EffectStartSignals and _G.EffectStartSignals[effectEventName]) do
    task.wait()
end

local MeowlAssets = ReplicatedStorage.Controllers.EventController.Events.Meowl

local sessionTrove     = Trove.new()
local recentlyTargeted = {}
local isActive         = true

local ATTACK_COOLDOWN_MIN = 5
local ATTACK_COOLDOWN_MAX = 10
local FLY_SPEED           = 50
local REACH_DIST          = 5

-- ─── NO observeTag here — controller's data.OnStart already handles visuals ──
-- ─── Burst ────────────────────────────────────────────────────────────────────

local function onBurst(animalName: string)
    for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
        if animal.Name == animalName and animal.PrimaryPart then
            sessionTrove:Add(ClientEventUtils.playBurst(MeowlAssets.Burst, animal.PrimaryPart, {
                ReplicatedStorage.Sounds.Events.Meowl.BrainrotHit,
                ReplicatedStorage.Sounds.Events.Meowl.Flap,
            }))
            return
        end
    end
end

-- ─── Movement — drives the hitbox parts the controller's visuals weld to ─────

local originalPositions: { [BasePart]: CFrame } = {}

local function getSpawnedMeowls(): { BasePart }
    local result = {}
    for _, part in ipairs(CollectionService:GetTagged("MeowlEventMeowl")) do
        if part:IsA("BasePart") then
            if not originalPositions[part] then
                originalPositions[part] = part.CFrame
            end
            table.insert(result, part)
        end
    end
    return result
end

local function flyToTarget(meowl: BasePart, target: Model): boolean
    if not meowl or not meowl.Parent then return false end
    if not target or not target.Parent or not target.PrimaryPart then return false end

    meowl:SetAttribute("Flying", true)

    while isActive and meowl.Parent and target and target.Parent and target.PrimaryPart do
        local targetPos  = target.PrimaryPart.Position + Vector3.new(0, 10, 0)
        local currentPos = meowl.Position
        local distance   = (targetPos - currentPos).Magnitude

        if distance < REACH_DIST then
            meowl:SetAttribute("Flying", false)
            return true
        end

        local dir  = (targetPos - currentPos).Unit
        local move = math.min(FLY_SPEED * RunService.Heartbeat:Wait(), distance)
        meowl.CFrame = CFrame.new(currentPos + dir * move, currentPos + dir * move + dir)
    end

    meowl:SetAttribute("Flying", false)
    return false
end

local function flyBack(meowl: BasePart, originalCFrame: CFrame)
    if not meowl or not meowl.Parent then return end

    local start    = meowl.Position
    local target   = originalCFrame.Position
    local distance = (target - start).Magnitude
    local duration = distance / FLY_SPEED
    local t0       = os.clock()

    meowl:SetAttribute("Flying", true)

    while os.clock() - t0 < duration and isActive and meowl.Parent do
        local alpha      = (os.clock() - t0) / duration
        local currentPos = start:Lerp(target, alpha)
        local lookDir    = target - currentPos
        if lookDir.Magnitude > 0 then
            meowl.CFrame = CFrame.new(currentPos, currentPos + lookDir.Unit)
        else
            meowl.CFrame = CFrame.new(currentPos)
        end
        task.wait()
    end

    if meowl and meowl.Parent then
        meowl.CFrame = originalCFrame
        meowl:SetAttribute("Flying", false)
    end
end

-- ─── Attack loop ──────────────────────────────────────────────────────────────

local function selectTarget(): (Model?, BasePart?)
    local now = workspace:GetServerTimeNow()
    for k, t in pairs(recentlyTargeted) do
        if now - t > 20 then recentlyTargeted[k] = nil end
    end

    local candidates = {}
    for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
        if animal.PrimaryPart and not recentlyTargeted[animal.Name] then
            table.insert(candidates, animal)
        end
    end
    if #candidates == 0 then return nil, nil end

    local available = {}
    for _, meowl in ipairs(getSpawnedMeowls()) do
        if meowl.Parent and not meowl:GetAttribute("Flying") then
            table.insert(available, meowl)
        end
    end
    if #available == 0 then return nil, nil end

    return candidates[math.random(1, #candidates)],
           available[math.random(1, #available)]
end

sessionTrove:Add(task.spawn(function()
    while isActive do
        task.wait(math.random(ATTACK_COOLDOWN_MIN, ATTACK_COOLDOWN_MAX))
        if not isActive then break end

        local animal, meowl = selectTarget()
        if not animal or not meowl then continue end

        recentlyTargeted[animal.Name] = workspace:GetServerTimeNow()
        local originalCFrame = originalPositions[meowl] or meowl.CFrame

        task.spawn(function()
            local reached = flyToTarget(meowl, animal)
            if reached then
                meowl:SetAttribute("Attack", true)
                onBurst(animal.Name)
                task.wait(0.5)
                meowl:SetAttribute("Attack", false)
                task.wait(0.5)
            end
            flyBack(meowl, originalCFrame)
        end)
    end
end))

-- ─── Cleanup ──────────────────────────────────────────────────────────────────

sessionTrove:Add(task.spawn(function()
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end
    isActive = false
    sessionTrove:Destroy()
    table.clear(recentlyTargeted)
    table.clear(originalPositions)
end))
