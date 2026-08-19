local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

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

local GATITOS_FOLDER = EVENT_SCRIPT:WaitForChild("Gatitos")
local burstAsset     = EVENT_SCRIPT:WaitForChild("Burst")

local animDance1  = EVENT_SCRIPT:WaitForChild("GatitoDance1")
local animDance2  = EVENT_SCRIPT:WaitForChild("GatitoDance2_")
local animWalk    = EVENT_SCRIPT:WaitForChild("GatitoWalk")
local animIdle    = EVENT_SCRIPT:WaitForChild("GatitoIdle")
local animAttack  = EVENT_SCRIPT:WaitForChild("GatitoAttack")

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

-- ─── NpcPathfinding (inlined) ─────────────────────────────────────────────────

local WALKABLE_TAGS           = { "Ground", "Carpet" }
local walkableParts           = {}
local walkableSet             = {}
local filterDirty             = true
local DEFAULT_REACH_THRESHOLD = 1.5
local DEFAULT_TURN_SPEED      = 8

local groundRayParams = RaycastParams.new()
groundRayParams.FilterType               = Enum.RaycastFilterType.Include
groundRayParams.FilterDescendantsInstances = {}
groundRayParams.IgnoreWater              = true

local function addWalkable(inst)
    if not inst or not inst:IsA("BasePart") or walkableSet[inst] then return end
    walkableSet[inst] = true
    table.insert(walkableParts, inst)
    filterDirty = true
end

local function removeWalkable(inst)
    if not inst or not walkableSet[inst] then return end
    walkableSet[inst] = nil
    for i = #walkableParts, 1, -1 do
        if walkableParts[i] == inst then table.remove(walkableParts, i) break end
    end
    filterDirty = true
end

for _, tag in ipairs(WALKABLE_TAGS) do
    for _, inst in ipairs(CollectionService:GetTagged(tag)) do addWalkable(inst) end
    CollectionService:GetInstanceAddedSignal(tag):Connect(addWalkable)
    CollectionService:GetInstanceRemovedSignal(tag):Connect(removeWalkable)
end

local function refreshGroundFilter()
    if filterDirty then
        groundRayParams.FilterDescendantsInstances = walkableParts
        filterDirty = false
    end
end

local function isModelValid(model): boolean
    return model ~= nil
        and model.Parent ~= nil
        and model.PrimaryPart ~= nil
        and model.PrimaryPart.Parent ~= nil
end

local function smoothTurn(model, newPos, flatDir, dt, turnSpeed)
    if not isModelValid(model) or not newPos or not flatDir or dt <= 0 then return end
    if flatDir.Magnitude < 1e-4 then
        local look = model.PrimaryPart.CFrame.LookVector
        flatDir = Vector3.new(look.X, 0, look.Z)
        if flatDir.Magnitude < 1e-4 then flatDir = Vector3.new(0, 0, 1) end
    end
    flatDir = flatDir.Unit
    if not isModelValid(model) then return end
    local pp         = model.PrimaryPart
    local targetCF   = CFrame.new(newPos, newPos + flatDir)
    local currentRot = CFrame.new(newPos)
        * CFrame.fromMatrix(Vector3.zero, pp.CFrame.RightVector, Vector3.new(0, 1, 0))
    local alpha = math.min(1, turnSpeed * dt)
    if not isModelValid(model) then return end
    local ok, err = pcall(function() model:PivotTo(currentRot:Lerp(targetCF, alpha)) end)
    if not ok then warn("[NpcPathfinding] smoothTurn failed:", err) end
end

local function stickToGround(position, yOffset, castUp, castDown)
    if not position then return Vector3.new(0, 0, 0) end
    local up   = castUp   or 10
    local down = castDown or 50
    local off  = yOffset  or 1.5
    refreshGroundFilter()
    if #walkableParts == 0 then return position end
    local ok, result = pcall(function()
        return workspace:Raycast(
            position + Vector3.new(0, up, 0),
            Vector3.new(0, -(up + down), 0),
            groundRayParams
        )
    end)
    if ok and result then return result.Position + Vector3.new(0, off, 0) end
    return position
end

local DEFAULT_AGENT_PARAMS = {
    AgentRadius     = 2,
    AgentHeight     = 5,
    AgentCanJump    = false,
    AgentCanClimb   = false,
    WaypointSpacing = 4,
}

local function computePath(startPos, endPos, agentParams)
    if not startPos or not endPos then return nil end
    local path = PathfindingService:CreatePath(agentParams or DEFAULT_AGENT_PARAMS)
    if not path then return nil end
    local ok = pcall(function() path:ComputeAsync(startPos, endPos) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then return nil end
    local waypoints = path:GetWaypoints()
    if not waypoints or #waypoints == 0 then return nil end
    local result = table.create(#waypoints)
    for i = 2, #waypoints do
        local wp = waypoints[i]
        if wp and wp.Position then table.insert(result, stickToGround(wp.Position)) end
    end
    if #result == 0 then table.insert(result, stickToGround(endPos)) end
    return result
end

local function npcMoveTo(model, targetPos, speed, opts)
    if not isModelValid(model) or not targetPos or not speed or speed <= 0 then return false end
    opts = opts or {}
    local maxTime    = opts.maxTime or 30
    local threshold  = opts.reachThreshold or DEFAULT_REACH_THRESHOLD
    local shouldStop = opts.shouldStop
    local waypoints  = computePath(model.PrimaryPart.Position, targetPos)
    if not waypoints or #waypoints == 0 then return false end
    local startClock = os.clock()
    for _, wp in ipairs(waypoints) do
        if not wp then continue end
        while true do
            if shouldStop and shouldStop() then return false end
            if not isModelValid(model) then return false end
            if os.clock() - startClock > maxTime then return false end
            local pp      = model.PrimaryPart
            if not pp then return false end
            local toWp    = wp - pp.Position
            local flatVec = Vector3.new(toWp.X, 0, toWp.Z)
            if flatVec.Magnitude <= threshold then break end
            local dt = RunService.Heartbeat:Wait()
            if dt <= 0 then continue end
            if not isModelValid(model) then return false end
            local pp2     = model.PrimaryPart
            if not pp2 then return false end
            local flatDir = flatVec.Unit
            local newPos  = stickToGround(pp2.Position + flatDir * math.min(speed * dt, flatVec.Magnitude))
            smoothTurn(model, newPos, flatDir, dt, DEFAULT_TURN_SPEED)
        end
    end
    return isModelValid(model)
end

local function npcChase(model, getTargetPos, speed, stopDistance, maxTime, opts)
    if not isModelValid(model) or not getTargetPos or not speed or speed <= 0 then return false end
    stopDistance = stopDistance or 3
    maxTime      = maxTime      or 30
    opts         = opts         or {}
    local shouldStop     = opts.shouldStop
    local repathInterval = 0.6
    local moveRepath     = 5
    local startClock     = os.clock()
    local lastRepath     = -math.huge
    local lastTargetPos  = nil
    local waypoints      = nil
    local wpIndex        = 1
    while true do
        if shouldStop and shouldStop() then return false end
        if not isModelValid(model) then return false end
        if os.clock() - startClock > maxTime then return false end
        local targetPos = getTargetPos()
        if not targetPos then return false end
        local pp = model.PrimaryPart
        if not pp then return false end
        if (targetPos - pp.Position).Magnitude <= stopDistance then return true end
        local now        = os.clock()
        local needRepath = not waypoints
            or wpIndex > #waypoints
            or now - lastRepath >= repathInterval
            or (lastTargetPos and (targetPos - lastTargetPos).Magnitude >= moveRepath)
        if needRepath then
            if not isModelValid(model) then return false end
            local pp2 = model.PrimaryPart
            if not pp2 then return false end
            waypoints     = computePath(pp2.Position, targetPos)
            wpIndex       = 1
            lastRepath    = now
            lastTargetPos = targetPos
            if not waypoints or #waypoints == 0 then task.wait(0.1) continue end
        end
        if not waypoints or wpIndex > #waypoints then continue end
        local wp = waypoints[wpIndex]
        if not wp then wpIndex += 1 continue end
        if not isModelValid(model) then return false end
        local pp3     = model.PrimaryPart
        if not pp3 then return false end
        local toWp    = wp - pp3.Position
        local flatVec = Vector3.new(toWp.X, 0, toWp.Z)
        if flatVec.Magnitude <= DEFAULT_REACH_THRESHOLD then wpIndex += 1 continue end
        local dt = RunService.Heartbeat:Wait()
        if dt <= 0 then continue end
        if not isModelValid(model) then return false end
        local pp4 = model.PrimaryPart
        if not pp4 then return false end
        local flatDir = flatVec.Unit
        local newPos  = stickToGround(pp4.Position + flatDir * math.min(speed * dt, flatVec.Magnitude))
        smoothTurn(model, newPos, flatDir, dt, DEFAULT_TURN_SPEED)
    end
end

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

local function calcAnimSpeed(elapsed: number): number
    if elapsed < 7 then return 0 end
    if elapsed >= 222.313 then
        return math.max(0, 1 - (elapsed - 222.313) / 3)
    end
    local phase = (elapsed - 7) % 72.771
    if phase >= 43   and phase < 48   then return 0.4 end
    if phase >= 48   and phase < 50   then return (phase - 48) / 2 * 0.3 + 0.4 end
    if phase >= 50   and phase < 55.5 then return 0.7 end
    if phase >= 55.5 and phase < 57   then return (phase - 55.5) / 1.5 * 0.3 + 0.7 end
    return 1
end

-- ─── Burst ────────────────────────────────────────────────────────────────────

local function doBurst(target: Model)
    if not target or not target.PrimaryPart then return end
    ClientEventUtils.playBurst(burstAsset, target.PrimaryPart, {
        ReplicatedStorage.Sounds.Events["Ay Mi Gatito"].Hit,
    })
end

-- ─── Animation controller ─────────────────────────────────────────────────────

local function buildAnimController(
    rootModel : Model,
    animator  : Animator,
    trove     : typeof(Trove.new())
)
    local function loadTrack(animObj, looped, priority)
        if not animObj then return nil end
        local track    = animator:LoadAnimation(animObj)
        track.Looped   = looped
        track.Priority = priority
        trove:Add(function() track:Stop(0) track:Destroy() end)
        return track
    end

    local danceTrack  = loadTrack(animDance1, true,  Enum.AnimationPriority.Action)
    local dance2Track = loadTrack(animDance2, true,  Enum.AnimationPriority.Action)
    local walkTrack   = loadTrack(animWalk,   false, Enum.AnimationPriority.Action2)
    local idleTrack   = loadTrack(animIdle,   true,  Enum.AnimationPriority.Idle)

    local function syncState()
        local running = rootModel:GetAttribute("IsRunning")
        local chasing = rootModel:GetAttribute("IsChasing")
        local dancing = rootModel:GetAttribute("Dance")

        if running or chasing then
            if walkTrack   and not walkTrack.IsPlaying   then walkTrack:Play()    end
            if danceTrack  and danceTrack.IsPlaying       then danceTrack:Stop()   end
            if dance2Track and dance2Track.IsPlaying      then dance2Track:Stop()  end
            if idleTrack   and idleTrack.IsPlaying        then idleTrack:Stop()    end
        elseif dancing then
            if danceTrack  and not danceTrack.IsPlaying  then danceTrack:Play()   end
            if dance2Track and dance2Track.IsPlaying      then dance2Track:Stop()  end
            if walkTrack   and walkTrack.IsPlaying        then walkTrack:Stop()    end
            if idleTrack   and idleTrack.IsPlaying        then idleTrack:Stop()    end
        else
            if idleTrack   and not idleTrack.IsPlaying   then idleTrack:Play()    end
            if danceTrack  and danceTrack.IsPlaying       then danceTrack:Stop()   end
            if dance2Track and dance2Track.IsPlaying      then dance2Track:Stop()  end
            if walkTrack   and walkTrack.IsPlaying        then walkTrack:Stop()    end
        end
    end

    trove:Add(rootModel:GetAttributeChangedSignal("IsRunning"):Connect(syncState))
    trove:Add(rootModel:GetAttributeChangedSignal("IsChasing"):Connect(syncState))
    trove:Add(rootModel:GetAttributeChangedSignal("Dance"):Connect(syncState))

    trove:Add(rootModel:GetAttributeChangedSignal("AttackAnimation"):Connect(function()
        if not rootModel:GetAttribute("AttackAnimation") then return end
        local attackTrack      = animator:LoadAnimation(animAttack)
        attackTrack.Looped     = false
        attackTrack.Priority   = Enum.AnimationPriority.Action4
        attackTrack:Play()
        attackTrack.Stopped:Once(function() attackTrack:Destroy() end)
    end))

    trove:Add(RunService.PostSimulation:Connect(function()
        local speed = calcAnimSpeed(workspace:GetServerTimeNow() - startedAt)
        if danceTrack  and danceTrack.IsPlaying  then danceTrack:AdjustSpeed(speed)  end
        if dance2Track and dance2Track.IsPlaying then dance2Track:AdjustSpeed(speed) end
        if walkTrack   and walkTrack.IsPlaying   then walkTrack:AdjustSpeed(speed)   end
        if idleTrack   and idleTrack.IsPlaying   then idleTrack:AdjustSpeed(speed)   end
    end))

    syncState()
end

-- ─── Model creation ───────────────────────────────────────────────────────────

local function createGatito(position: Vector3): (Model, Animator?)
    local model = Instance.new("Model")
    model.Name  = "Gatito"

    local root = Instance.new("Part")
    root.Name         = "HumanoidRootPart"
    root.Size         = Vector3.new(2, 2, 2)
    root.Transparency = 1
    root.Anchored     = true
    root.CanCollide   = false
    root.CFrame       = CFrame.new(stickToGround(position))
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

    local animator: Animator? = nil

    local templateName = chosenVariant or "Gatito"
    local template     = GATITOS_FOLDER:FindFirstChild(templateName)
                      or GATITOS_FOLDER:FindFirstChild("Gatito")

    if template then
        local mesh = template:Clone()

        local existingAC = mesh:FindFirstChild("AnimationController")
        if existingAC then existingAC:Destroy() end

        -- Exact rig from decompiled initGatitoObserver
        local humanoid = Instance.new("Humanoid")
        humanoid.Name                 = "AnimationController"
        humanoid.EvaluateStateMachine = false
        humanoid.DisplayDistanceType  = Enum.HumanoidDisplayDistanceType.None
        humanoid.PlatformStand        = true
        humanoid.Parent               = mesh

        local animatorInst  = Instance.new("Animator")
        animatorInst.Parent = humanoid
        animator            = animatorInst

        local weld    = Instance.new("Weld")
        weld.Part0    = mesh.PrimaryPart
        weld.Part1    = root
        weld.Parent   = mesh.PrimaryPart

        mesh.Parent = model
    end

    model.Parent = workspace
    return model, animator
end

-- ─── Wander ───────────────────────────────────────────────────────────────────

local function wander(hunterData)
    local entity   = hunterData.Model
    local homePart = hunterData.Home
    if not entity or not entity.PrimaryPart then return end
    if entity:GetAttribute("IsChasing") or entity:GetAttribute("IsRunning") then return end

    local targetPos = stickToGround(randomPointInPart(homePart))
    local distance  = (targetPos - entity:GetPivot().Position).Magnitude
    if distance < 1 then return end

    entity:SetAttribute("IsRunning", true)

    local wanderTrove = eventTrove:Extend()
    wanderTrove:Add(task.spawn(function()
        npcMoveTo(entity, targetPos, WANDER_SPEED, {
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
        local reached = npcChase(
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
                    return not isActive or not gatito.Parent
                end,
            }
        )

        gatito:SetAttribute("IsRunning", false)

        if reached and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart then
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
                    local newPos = stickToGround(mPos + delta.Unit * math.min(CHASE_SPEED * dt, delta.Magnitude))
                    gatito:PivotTo(CFrame.new(newPos, newPos + flat.Unit))
                end
            end)

            task.wait(ATTACK_DURATION)
            attackConn:Disconnect()

            doBurst(targetAnimal)
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
    local pos             = randomPointInPart(homePart)
    local model, animator = createGatito(pos)
    local gatitoTrove     = eventTrove:Extend()
    gatitoTrove:Add(model)
    if animator then
        buildAnimController(model, animator, gatitoTrove)
    end
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
