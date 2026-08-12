local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)
local NpcPathfinding  = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"
))()

local EVENT_NAME     = "Ay Mi Gatito"
local TAG_NAME       = "Gatito"
local BLOCKING_TRAIT = ":3"

local GATITO_FOLDER = ReplicatedStorage.Controllers.EventController.Events["Ay Mi Gatito"].Gatitos
local GATITO_MODELS = {
    GATITO_FOLDER:WaitForChild("Gatito"),
    GATITO_FOLDER:WaitForChild("Angry Gatito"),
    GATITO_FOLDER:WaitForChild("Crying Gatito"),
}

local WANDER_FOLDER     = ReplicatedStorage.Controllers.EventController.Events["Ay Mi Gatito"]
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

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove      = Trove.new()
local spawnedEntities = {}
local lockedTargets   = {}
local isActive        = true
local variantIndex    = 1
local rng             = Random.new()

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function stickToGround(position)
    return NpcPathfinding.stickToGround(position)
end

local function getTraits(animal)
    local traitsJson = animal:GetAttribute("Traits")
    if not traitsJson then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, traitsJson)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local traitSet = {}
    for _, t in ipairs(decoded) do traitSet[t] = true end
    return decoded, traitSet
end

local function hasBlockingTrait(animal)
    local _, traitSet = getTraits(animal)
    return traitSet[BLOCKING_TRAIT] == true
end

-- ─── Model ────────────────────────────────────────────────────────────────────

local function createGatito(position)
    local template = GATITO_MODELS[variantIndex]
    variantIndex   = variantIndex % #GATITO_MODELS + 1

    local model = template:Clone()
    model.Name  = "Gatito"

    local root = model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart")

    root.Anchored   = true
    root.CanCollide = false
    root.CFrame     = CFrame.new(stickToGround(position))
    model.PrimaryPart = root

    model:SetAttribute("Dance",     true)
    model:SetAttribute("IsRunning", false)
    model:SetAttribute("IsChasing", false)

    CollectionService:AddTag(model, TAG_NAME)

    model.Parent = workspace
    return model
end

-- ─── Wander ───────────────────────────────────────────────────────────────────

local function wander(hunterData)
    local entity   = hunterData.Model
    local homePart = hunterData.Home

    if not entity or not entity.PrimaryPart then return end
    if entity:GetAttribute("IsChasing") or entity:GetAttribute("IsRunning") then return end

    local size = homePart.Size
    local targetPos = stickToGround(homePart.Position + Vector3.new(
        rng:NextNumber(-size.X / 2, size.X / 2),
        0,
        rng:NextNumber(-size.Z / 2, size.Z / 2)
    ))
    local distance = (targetPos - entity:GetPivot().Position).Magnitude
    if distance < 1 then return end

    entity:SetAttribute("IsRunning", true)
    entity:SetAttribute("Dance",     false)

    local wanderTrove = eventTrove:Extend()
    wanderTrove:Add(task.spawn(function()
        NpcPathfinding.moveTo(entity, targetPos, WANDER_SPEED, {
            maxTime = math.max(5, distance / WANDER_SPEED + 2),
            shouldStop = function()
                return (not isActive)
                    or (not entity.Parent)
                    or entity:GetAttribute("IsChasing")
            end,
        })

        if entity.Parent then
            entity:SetAttribute("IsRunning", false)
            entity:SetAttribute("Dance",     true)
        end
        wanderTrove:Clean()
    end))
end

-- ─── Chase + attack ───────────────────────────────────────────────────────────

local function followAndAttackAnimal(gatitoData, targetAnimal)
    local gatito = gatitoData.Model
    if not gatito or not gatito.Parent then return end
    if gatito:GetAttribute("IsChasing") then return end
    if lockedTargets[targetAnimal] then return end

    lockedTargets[targetAnimal] = true
    gatito:SetAttribute("IsChasing", true)
    gatito:SetAttribute("IsRunning", true)
    gatito:SetAttribute("Dance",     false)

    local chaseTrove = eventTrove:Extend()

    chaseTrove:Add(task.spawn(function()
        local reachedTarget = NpcPathfinding.chase(
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
            {
                shouldStop = function()
                    return (not isActive) or (not gatito.Parent)
                end,
            }
        )

        gatito:SetAttribute("IsRunning", false)

        if reachedTarget and targetAnimal and targetAnimal.Parent then
            gatito:SetAttribute("AttackAnimation", true)

            local elapsed = 0
            local attackConn
            attackConn = chaseTrove:Add(RunService.Heartbeat:Connect(function(dt)
                elapsed += dt

                if elapsed >= ATTACK_DURATION
                    or (not isActive)
                    or (not targetAnimal) or (not targetAnimal.Parent) or (not targetAnimal.PrimaryPart)
                then
                    chaseTrove:Remove(attackConn)
                    attackConn:Disconnect()
                    return
                end

                local tPos = targetAnimal.PrimaryPart.Position
                local mPos = gatito.PrimaryPart.Position
                local d    = tPos - mPos
                local dist = d.Magnitude

                if dist > CHASE_STICK_DIST then
                    local dir     = d.Unit
                    local flatDir = Vector3.new(dir.X, 0, dir.Z)
                    if flatDir.Magnitude < 1e-4 then return end
                    flatDir = flatDir.Unit
                    local newPos = stickToGround(mPos + dir * math.min(CHASE_SPEED * dt, dist))
                    gatito:PivotTo(CFrame.new(newPos, newPos + flatDir))
                end
            end))

            while elapsed < ATTACK_DURATION and isActive do
                task.wait(ATTACK_DURATION - elapsed + 0.016)
            end

            gatito:SetAttribute("AttackAnimation", false)

            if targetAnimal and targetAnimal.Parent then
                local currentTraits, currentTraitSet = getTraits(targetAnimal)
                if not currentTraitSet[BLOCKING_TRAIT] then
                    table.insert(currentTraits, BLOCKING_TRAIT)
                    targetAnimal:SetAttribute("Traits", HttpService:JSONEncode(currentTraits))
                end
            end
        end

        lockedTargets[targetAnimal] = nil
        task.wait(POST_ATTACK_WAIT)

        if isActive and gatito and gatito.Parent then
            gatito:SetAttribute("IsChasing", false)
            gatito:SetAttribute("Dance",     true)
            wander(gatitoData)
        end

        chaseTrove:Clean()
    end))
end

-- ─── Spawn ────────────────────────────────────────────────────────────────────

local function spawnGatito(homePart)
    if not isActive or not homePart then return end

    local size = homePart.Size
    local pos  = homePart.Position + Vector3.new(
        rng:NextNumber(-size.X / 2, size.X / 2),
        0,
        rng:NextNumber(-size.Z / 2, size.Z / 2)
    )

    local model       = createGatito(pos)
    local gatitoTrove = eventTrove:Extend()
    gatitoTrove:Add(model)

    local data = {
        Model = model,
        Home  = homePart,
        Trove = gatitoTrove,
    }

    table.insert(spawnedEntities, data)
    return data
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    for _, part in ipairs(WANDER_FOLDER:GetChildren()) do
        if part.Name == "Wander" and part:IsA("BasePart") then
            for _ = 1, GATITOS_PER_WANDER do
                spawnGatito(part)
            end
        end
    end

    -- wander tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            for _, hunterData in ipairs(spawnedEntities) do
                local model = hunterData.Model
                if model.Parent
                    and not model:GetAttribute("IsChasing")
                    and not model:GetAttribute("IsRunning")
                then
                    task.delay(rng:NextNumber(0, 2), function()
                        if isActive and model.Parent
                            and not model:GetAttribute("IsChasing")
                            and not model:GetAttribute("IsRunning")
                        then
                            wander(hunterData)
                        end
                    end)
                end
            end
            task.wait(WANDER_LOOP_RATE)
        end
    end))

    -- attack tick
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
            task.wait(rng:NextNumber(ATTACK_LOOP_MIN, ATTACK_LOOP_MAX))
            if not isActive or #spawnedEntities == 0 then break end

            local candidates = {}
            for _, animal in ipairs(cachedAnimals) do
                if animal.PrimaryPart and not lockedTargets[animal] and not hasBlockingTrait(animal) then
                    table.insert(candidates, animal)
                end
            end

            if #candidates > 0 then
                local selected   = candidates[rng:NextInteger(1, #candidates)]
                local gatitoData = spawnedEntities[rng:NextInteger(1, #spawnedEntities)]
                if gatitoData.Model and gatitoData.Model.Parent then
                    followAndAttackAnimal(gatitoData, selected)
                end
            end
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end

    isActive = false
    eventTrove:Destroy()
    table.clear(spawnedEntities)
    table.clear(lockedTargets)
end

task.spawn(main)
