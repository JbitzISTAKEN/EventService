local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local NpcPathfinding = loadstring(game:HttpGet("https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"))()

local EVENT_NAME   = "Ay Mi Gatito"
local TAG_NAME     = "Gatito"
local EVENT_SCRIPT = ReplicatedStorage:WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("Ay Mi Gatito")

-- ─── Constants ────────────────────────────────────────────────────────────────

local BLOCKING_TRAIT     = ":3"
local VARIANTS           = { "Angry Gatito", "Crying Gatito" }
local variantIndex       = 1

local ACTIVATION_DELAY   = 7
local GATITOS_PER_WANDER = 3
local WANDER_SPEED       = 16
local CHASE_SPEED        = 20
local CHASE_REACH_DIST   = 5
local CHASE_STICK_DIST   = 0.5
local ATTACK_DURATION    = 0.5
local POST_ATTACK_WAIT   = 1.5
local WANDER_LOOP_RATE   = 2
local ATTACK_LOOP_MIN    = 5
local ATTACK_LOOP_MAX    = 10

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local burstAsset = EVENT_SCRIPT:WaitForChild("Burst")
local animAttack = EVENT_SCRIPT:WaitForChild("GatitoAttack")

-- ─── Wander folder injection ──────────────────────────────────────────────────

local WANDER_FOLDER do
    local objects = game:GetObjects("rbxassetid://88036131806728")
    local folder  = objects and objects[1]
    if folder then
        folder.Name   = "Ay Mi Gatito"
        folder.Parent = workspace:WaitForChild("Events")
    end
    WANDER_FOLDER = folder
end

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove      = Trove.new()
local spawnedEntities = {}
local lockedTargets   = {}
local isActive        = true
local rng             = Random.new()

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function randomPointInPart(part: BasePart): Vector3
    local s = part.Size
    return part.Position + Vector3.new(
        rng:NextNumber(-s.X / 2, s.X / 2),
        0,
        rng:NextNumber(-s.Z / 2, s.Z / 2)
    )
end

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

-- ─── Burst ────────────────────────────────────────────────────────────────────

local function doBurst(target: Model)
    if not target or not target.PrimaryPart then return end
    ClientEventUtils.playBurst(burstAsset, target.PrimaryPart, {
        ReplicatedStorage.Sounds.Events["Ay Mi Gatito"].Hit,
    })
end

-- ─── Model creation ───────────────────────────────────────────────────────────

local function createGatito(position: Vector3): Model
    local model = Instance.new("Model")
    model.Name  = "Gatito"

    local root = Instance.new("Part")
    root.Name         = "HumanoidRootPart"
    root.Size         = Vector3.new(2, 2, 2)
    root.Transparency = 1
    root.Anchored     = true
    root.CanCollide   = false
    root.CFrame       = CFrame.new(NpcPathfinding.stickToGround(position))
    root.Parent       = model
    model.PrimaryPart = root

    local totalOptions  = #VARIANTS + 1
    local chosenVariant = VARIANTS[variantIndex]
    if chosenVariant then model:SetAttribute("Variant", chosenVariant) end
    model:SetAttribute("Dance",           true)
    model:SetAttribute("IsRunning",       false)
    model:SetAttribute("IsChasing",       false)
    model:SetAttribute("AttackAnimation", false)

    CollectionService:AddTag(model, TAG_NAME)
    variantIndex = (variantIndex % totalOptions) + 1

    model.Parent = workspace
    return model
end

-- ─── Wander ───────────────────────────────────────────────────────────────────

local function wander(hunterData)
    local entity   = hunterData.Model
    local homePart = hunterData.Home
    if not entity or not entity.PrimaryPart then return end
    if entity:GetAttribute("IsChasing") or entity:GetAttribute("IsRunning") then return end

    local targetPos = NpcPathfinding.stickToGround(randomPointInPart(homePart))
    local distance  = (targetPos - entity:GetPivot().Position).Magnitude
    if distance < 1 then return end

    entity:SetAttribute("IsRunning", true)

    local wanderTrove = eventTrove:Extend()
    wanderTrove:Add(task.spawn(function()
        NpcPathfinding.moveTo(entity, targetPos, WANDER_SPEED, {
            maxTime = math.max(5, distance / WANDER_SPEED + 2),
            shouldStop = function()
                return not isActive
                    or not entity.Parent
                    or entity:GetAttribute("IsChasing")
            end,
        })
        if entity and entity.Parent then
            entity:SetAttribute("IsRunning", false)
        end
        wanderTrove:Clean()
    end))
end

-- ─── Chase + attack ───────────────────────────────────────────────────────────

local function followAndAttackAnimal(gatitoData, targetAnimal: Model)
    local gatito = gatitoData.Model
    if not gatito or not gatito.Parent then return end
    if gatito:GetAttribute("IsChasing") then return end
    if lockedTargets[targetAnimal] then return end

    lockedTargets[targetAnimal] = true
    gatito:SetAttribute("IsChasing", true)
    gatito:SetAttribute("IsRunning", true)

    local chaseTrove = eventTrove:Extend()
    chaseTrove:Add(task.spawn(function()
        local reached = NpcPathfinding.chase(
            gatito,
            function()
                if targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart then
                    return targetAnimal.PrimaryPart.Position
                end
                return nil
            end,
            CHASE_SPEED,
            CHASE_REACH_DIST,
            30,
            { shouldStop = function() return not isActive or not gatito.Parent end }
        )

        gatito:SetAttribute("IsRunning", false)

        if reached and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart then
            -- FIX: set true first, let the observer react, then manage the attack tick ourselves
            gatito:SetAttribute("AttackAnimation", true)

            local elapsed    = 0
            local attackConn = RunService.Heartbeat:Connect(function(dt)
                elapsed += dt
                if elapsed >= ATTACK_DURATION
                    or not isActive
                    or not (targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart)
                then return end
                local mPos  = gatito.PrimaryPart.Position
                local tPos  = targetAnimal.PrimaryPart.Position
                local delta = tPos - mPos
                if delta.Magnitude > CHASE_STICK_DIST then
                    local flat = Vector3.new(delta.X, 0, delta.Z)
                    if flat.Magnitude < 1e-4 then return end
                    local newPos = NpcPathfinding.stickToGround(mPos + delta.Unit * math.min(CHASE_SPEED * dt, delta.Magnitude))
                    gatito:PivotTo(CFrame.new(newPos, newPos + flat.Unit))
                end
            end)

            task.wait(ATTACK_DURATION)
            attackConn:Disconnect()

            doBurst(targetAnimal)
            -- FIX: clear AFTER burst, not before — observer guard below prevents double-load
            gatito:SetAttribute("AttackAnimation", false)

            if targetAnimal and targetAnimal.Parent then
                local traits, traitSet = getTraits(targetAnimal)
                if not traitSet[BLOCKING_TRAIT] then
                    table.insert(traits, BLOCKING_TRAIT)
                    targetAnimal:SetAttribute("Traits", HttpService:JSONEncode(traits))
                end
            end
        end

        lockedTargets[targetAnimal] = nil
        task.wait(POST_ATTACK_WAIT)

        if isActive and gatito and gatito.Parent then
            gatito:SetAttribute("IsChasing", false)
            wander(gatitoData)
        end

        chaseTrove:Clean()
    end))
end

-- ─── Spawn ────────────────────────────────────────────────────────────────────

local function spawnGatito(homePart: BasePart)
    if not isActive then return end
    local model       = createGatito(randomPointInPart(homePart))
    local gatitoTrove = eventTrove:Extend()
    gatitoTrove:Add(model)
    table.insert(spawnedEntities, {
        Model = model,
        Home  = homePart,
        Trove = gatitoTrove,
    })
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    local elapsed   = workspace:GetServerTimeNow() - startedAt
    local remaining = math.max(0, ACTIVATION_DELAY - elapsed)
    if remaining > 0 then task.wait(remaining) end
    if not isActive then return end

    if not WANDER_FOLDER then
        warn("[AyMiGatito] Wander folder failed to load from asset")
        return
    end

    for _, part in ipairs(WANDER_FOLDER:GetChildren()) do
        if part:IsA("BasePart") and part.Name == "Wander" then
            for _ = 1, GATITOS_PER_WANDER do
                spawnGatito(part)
            end
        end
    end

    if #spawnedEntities == 0 then
        warn("[AyMiGatito] No Wander parts found in asset folder")
        return
    end

    -- Wander loop
    eventTrove:Add(task.spawn(function()
        while isActive do
            for _, data in ipairs(spawnedEntities) do
                local m = data.Model
                if m and m.Parent
                    and not m:GetAttribute("IsChasing")
                    and not m:GetAttribute("IsRunning")
                then
                    task.delay(rng:NextNumber(0, 2), function()
                        if isActive and m and m.Parent
                            and not m:GetAttribute("IsChasing")
                            and not m:GetAttribute("IsRunning")
                        then
                            wander(data)
                        end
                    end)
                end
            end
            task.wait(WANDER_LOOP_RATE)
        end
    end))

    -- Live animal cache
    local cachedAnimals = CollectionService:GetTagged("Animal")
    eventTrove:Add(CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(inst)
        table.insert(cachedAnimals, inst)
    end))
    eventTrove:Add(CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(inst)
        for i = #cachedAnimals, 1, -1 do
            if cachedAnimals[i] == inst then table.remove(cachedAnimals, i) break end
        end
    end))

    -- Attack loop
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(rng:NextNumber(ATTACK_LOOP_MIN, ATTACK_LOOP_MAX))
            if not isActive or #spawnedEntities == 0 then break end
            local candidates = {}
            for _, animal in ipairs(cachedAnimals) do
                if animal.PrimaryPart
                    and not lockedTargets[animal]
                    and not hasBlockingTrait(animal)
                then
                    table.insert(candidates, animal)
                end
            end
            if #candidates == 0 then continue end
            local selected   = candidates[rng:NextInteger(1, #candidates)]
            local gatitoData = spawnedEntities[rng:NextInteger(1, #spawnedEntities)]
            if gatitoData.Model and gatitoData.Model.Parent then
                followAndAttackAnimal(gatitoData, selected)
            end
        end
    end))

    -- Cleanup watchdog
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    eventTrove:Destroy()
    table.clear(spawnedEntities)
    table.clear(lockedTargets)
    if WANDER_FOLDER and WANDER_FOLDER.Parent then
        WANDER_FOLDER:Destroy()
    end
end

task.spawn(main)
