-- --- Ay Mi Gatito.lua (LocalScript / loadstring) ---

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Trove"))
local EventController  = require(ReplicatedStorage:WaitForChild("Controllers"):WaitForChild("EventController"))
local ClientEventUtils = require(ReplicatedStorage:WaitForChild("Controllers"):WaitForChild("EventController"):WaitForChild("ClientEventUtils"))

local NpcPathfinding = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"
))()

local EVENT_NAME = "Ay Mi Gatito"

-- ─── Constants ────────────────────────────────────────────────────────────────

local WANDER_SPEED        = 16
local CHASE_SPEED         = 20
local REACH_DIST          = 5
local ATTACK_COOLDOWN_MIN = 5
local ATTACK_COOLDOWN_MAX = 10
local BURST_DURATION      = 0.5
local POST_ATTACK_WAIT    = 1.5
local WANDER_LOOP_RATE    = 2
local GATITOS_PER_WANDER  = 3
local BLOCKING_TRAIT      = ":3"
local VARIANTS            = { "Angry Gatito", "Crying Gatito" }
local variantIndex        = 1

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local GatitoAssets = ReplicatedStorage
    :WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("Ay Mi Gatito")

local burstAsset    = GatitoAssets:WaitForChild("Burst")
local WANDER_FOLDER = workspace:WaitForChild("Events"):FindFirstChild("Ay Mi Gatito")

-- ─── State ────────────────────────────────────────────────────────────────────

local sessionTrove      = Trove.new()
local spawnedGatitos    = {}    -- { Model: BasePart, Home: BasePart }[]
local originalPositions = {}    -- BasePart → CFrame
local lockedTargets     = {}    -- Model → true
local recentlyTargeted  = {}    -- string → server timestamp
local isActive          = true
local rng               = Random.new()

-- ─── Trait helpers ────────────────────────────────────────────────────────────

local function getTraits(animal: Model): ({ string }, { [string]: boolean })
    local raw = animal:GetAttribute("Traits")
    if not raw then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local traitSet = {}
    for _, t in ipairs(decoded) do traitSet[t] = true end
    return decoded, traitSet
end

local function hasBlockingTrait(animal: Model): boolean
    local _, traitSet = getTraits(animal)
    return traitSet[BLOCKING_TRAIT] == true
end

-- ─── Burst ────────────────────────────────────────────────────────────────────

local function doBurst(target: Model)
    if not target or not target.PrimaryPart then return end
    ClientEventUtils.playBurst(burstAsset, target.PrimaryPart, {
        ReplicatedStorage.Sounds.Events["Ay Mi Gatito"].Hit,
    })
end

-- ─── Entity creation ──────────────────────────────────────────────────────────

local function createGatito(position: Vector3): BasePart
    local model = Instance.new("Model")
    model.Name  = "Gatito"

    local root             = Instance.new("Part")
    root.Name              = "HumanoidRootPart"
    root.Size              = Vector3.new(2, 2, 2)
    root.Transparency      = 1
    root.Anchored          = true
    root.CanCollide        = false
    root.CFrame            = CFrame.new(position)
    root.Parent            = model
    model.PrimaryPart      = root

    local totalOptions     = #VARIANTS + 1
    local randomVariant    = VARIANTS[variantIndex]
    if randomVariant then
        model:SetAttribute("Variant", randomVariant)
    end
    model:SetAttribute("Dance",      true)
    model:SetAttribute("IsRunning",  false)
    model:SetAttribute("IsChasing",  false)

    CollectionService:AddTag(model, "Gatito")
    variantIndex = (variantIndex % totalOptions) + 1

    return model
end

local function attachVisual(gatito: Model)
    local variant    = gatito:GetAttribute("Variant") or "Gatito"
    local visual     = GatitoAssets:FindFirstChild(variant) or GatitoAssets:WaitForChild("Gatito")
    local visualClone = visual:Clone()
    visualClone.Parent = workspace
    sessionTrove:Add(visualClone)

    local weld       = Instance.new("Weld")
    weld.Part0       = visualClone.PrimaryPart
    weld.Part1       = gatito.PrimaryPart
    weld.C0          = visualClone.PrimaryPart.PivotOffset
    weld.Parent      = visualClone.PrimaryPart

    local animator   = visualClone.AnimationController.Animator

    local danceTrack        = animator:LoadAnimation(GatitoAssets:WaitForChild("GatitoDance1"))
    danceTrack.Priority     = Enum.AnimationPriority.Action
    danceTrack.Looped       = true

    local walkTrack         = animator:LoadAnimation(GatitoAssets:WaitForChild("GatitoWalk"))
    walkTrack.Priority      = Enum.AnimationPriority.Action2
    walkTrack.Looped        = true

    local idleTrack         = animator:LoadAnimation(GatitoAssets:WaitForChild("GatitoIdle"))
    idleTrack.Priority      = Enum.AnimationPriority.Idle
    idleTrack.Looped        = true

    local attackTrack       = animator:LoadAnimation(GatitoAssets:WaitForChild("GatitoAttack"))
    attackTrack.Priority    = Enum.AnimationPriority.Action4
    attackTrack.Looped      = false

    sessionTrove:Add(function()
        danceTrack:Stop(0);  danceTrack:Destroy()
        walkTrack:Stop(0);   walkTrack:Destroy()
        idleTrack:Stop(0);   idleTrack:Destroy()
        attackTrack:Stop(0); attackTrack:Destroy()
    end)

    -- initial state
    if gatito:GetAttribute("Dance") then
        danceTrack:Play()
    else
        idleTrack:Play()
    end

    local function updateMovement()
        local running = gatito:GetAttribute("IsRunning")
        local chasing = gatito:GetAttribute("IsChasing")
        if running or chasing then
            if not walkTrack.IsPlaying then walkTrack:Play() end
            danceTrack:Stop()
            idleTrack:Stop()
        else
            walkTrack:Stop()
            if gatito:GetAttribute("Dance") then
                if not danceTrack.IsPlaying then danceTrack:Play() end
                idleTrack:Stop()
            else
                if not idleTrack.IsPlaying then idleTrack:Play() end
                danceTrack:Stop()
            end
        end
    end

    sessionTrove:Add(gatito:GetAttributeChangedSignal("IsRunning"):Connect(updateMovement))
    sessionTrove:Add(gatito:GetAttributeChangedSignal("IsChasing"):Connect(updateMovement))
    sessionTrove:Add(gatito:GetAttributeChangedSignal("Dance"):Connect(updateMovement))

    sessionTrove:Add(gatito:GetAttributeChangedSignal("AttackAnimation"):Connect(function()
        if gatito:GetAttribute("AttackAnimation") then
            attackTrack:Play()
        end
    end))
end

-- ─── Wander ───────────────────────────────────────────────────────────────────

local function wander(gatitoData: { Model: Model, Home: BasePart })
    local gatito   = gatitoData.Model
    local homePart = gatitoData.Home

    if not gatito or not gatito.PrimaryPart then return end
    if gatito:GetAttribute("IsChasing") then return end
    if gatito:GetAttribute("IsRunning") then return end

    local size   = homePart.Size
    local offset = Vector3.new(
        rng:NextNumber(-size.X / 2, size.X / 2),
        0,
        rng:NextNumber(-size.Z / 2, size.Z / 2)
    )

    local targetPos = NpcPathfinding.stickToGround(homePart.Position + offset)
    local distance  = (targetPos - gatito:GetPivot().Position).Magnitude
    if distance < 1 then return end

    gatito:SetAttribute("IsRunning", true)

    local wanderTrove = sessionTrove:Extend()
    wanderTrove:Add(task.spawn(function()
        NpcPathfinding.moveTo(gatito, targetPos, WANDER_SPEED, {
            maxTime = math.max(5, distance / WANDER_SPEED + 2),
            shouldStop = function()
                return (not isActive)
                    or (not gatito.Parent)
                    or gatito:GetAttribute("IsChasing")
            end,
        })
        if gatito.Parent then
            gatito:SetAttribute("IsRunning", false)
        end
        wanderTrove:Clean()
    end))
end

-- ─── Attack ───────────────────────────────────────────────────────────────────

local function followAndAttack(gatitoData: { Model: Model, Home: BasePart }, target: Model)
    local gatito = gatitoData.Model
    if not gatito or not gatito.Parent then return end
    if gatito:GetAttribute("IsChasing") then return end
    if lockedTargets[target] then return end

    lockedTargets[target] = true
    gatito:SetAttribute("IsChasing", true)
    gatito:SetAttribute("IsRunning", true)

    local chaseTrove = sessionTrove:Extend()
    chaseTrove:Add(task.spawn(function()
        local reached = NpcPathfinding.chase(
            gatito,
            function()
                if target and target.Parent and target.PrimaryPart then
                    return target.PrimaryPart.Position
                end
                return nil
            end,
            CHASE_SPEED,
            REACH_DIST,
            30,
            {
                shouldStop = function()
                    return (not isActive) or (not gatito.Parent)
                end,
            }
        )

        gatito:SetAttribute("IsRunning", false)

        if reached and target and target.Parent and target.PrimaryPart then
            gatito:SetAttribute("AttackAnimation", true)
            task.wait(BURST_DURATION)
            doBurst(target)
            gatito:SetAttribute("AttackAnimation", false)

            -- apply blocking trait server-side only; client just fires visual
        end

        lockedTargets[target] = nil
        task.wait(POST_ATTACK_WAIT)

        if isActive and gatito and gatito.Parent then
            gatito:SetAttribute("IsChasing", false)
            wander(gatitoData)
        end

        chaseTrove:Clean()
    end))
end

-- ─── Target selection ─────────────────────────────────────────────────────────

local function selectTarget(): (Model?, { Model: Model, Home: BasePart }?)
    local now = workspace:GetServerTimeNow()
    for k, t in pairs(recentlyTargeted) do
        if now - t > 20 then recentlyTargeted[k] = nil end
    end

    local candidates = {}
    for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
        if animal.PrimaryPart
            and not lockedTargets[animal]
            and not recentlyTargeted[animal.Name]
            and not hasBlockingTrait(animal)
        then
            table.insert(candidates, animal)
        end
    end
    if #candidates == 0 then return nil, nil end

    local available = {}
    for _, data in ipairs(spawnedGatitos) do
        if data.Model.Parent
            and not data.Model:GetAttribute("IsChasing")
            and not data.Model:GetAttribute("IsRunning")
        then
            table.insert(available, data)
        end
    end
    if #available == 0 then return nil, nil end

    return candidates[rng:NextInteger(1, #candidates)],
           available[rng:NextInteger(1, #available)]
end

-- ─── Spawn ────────────────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

if WANDER_FOLDER then
    for _, part in ipairs(WANDER_FOLDER:GetChildren()) do
        if part.Name == "Wander" then
            local size = part.Size
            for _ = 1, GATITOS_PER_WANDER do
                local offset = Vector3.new(
                    rng:NextNumber(-size.X / 2, size.X / 2),
                    0,
                    rng:NextNumber(-size.Z / 2, size.Z / 2)
                )
                local spawnPos = NpcPathfinding.stickToGround(part.Position + offset)
                local gatito   = createGatito(spawnPos)
                gatito.Parent  = workspace
                sessionTrove:Add(gatito)

                local data = { Model = gatito, Home = part }
                table.insert(spawnedGatitos, data)
                originalPositions[gatito] = CFrame.new(spawnPos)

                attachVisual(gatito)
            end
        end
    end
end

-- ─── Wander loop ──────────────────────────────────────────────────────────────

sessionTrove:Add(task.spawn(function()
    while isActive do
        for _, data in ipairs(spawnedGatitos) do
            local gatito = data.Model
            if gatito.Parent
                and not gatito:GetAttribute("IsChasing")
                and not gatito:GetAttribute("IsRunning")
            then
                task.delay(rng:NextNumber(0, 2), function()
                    if isActive
                        and gatito.Parent
                        and not gatito:GetAttribute("IsChasing")
                        and not gatito:GetAttribute("IsRunning")
                    then
                        wander(data)
                    end
                end)
            end
        end
        task.wait(WANDER_LOOP_RATE)
    end
end))

-- ─── Attack loop ──────────────────────────────────────────────────────────────

sessionTrove:Add(task.spawn(function()
    while isActive do
        task.wait(rng:NextNumber(ATTACK_COOLDOWN_MIN, ATTACK_COOLDOWN_MAX))
        if not isActive then break end

        local target, gatitoData = selectTarget()
        if not target or not gatitoData then continue end

        recentlyTargeted[target.Name] = workspace:GetServerTimeNow()
        followAndAttack(gatitoData, target)
    end
end))

-- ─── Cleanup ──────────────────────────────────────────────────────────────────

sessionTrove:Add(task.spawn(function()
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end
    isActive = false
    sessionTrove:Destroy()
    table.clear(spawnedGatitos)
    table.clear(originalPositions)
    table.clear(lockedTargets)
    table.clear(recentlyTargeted)
end))
