-- LocalScript: Ay Mi Gatito Client Spawner — Complete
-- Animations: ReplicatedStorage.Controllers.EventController.Events["Ay Mi Gatito"]
-- Raycasting: inline, no external deps, no RemoteEvents

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)

local EVENT_SCRIPT = ReplicatedStorage.Controllers.EventController.Events["Ay Mi Gatito"]

local EVENT_NAME     = "Ay Mi Gatito"
local TAG_NAME       = "Gatito"
local BLOCKING_TRAIT = ":3"

local VARIANTS     = { "Angry Gatito", "Crying Gatito" }
local variantIndex = 1

local WANDER_FOLDER = workspace:WaitForChild("Events"):WaitForChild("Wander")

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

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventData  = EventController:GetActiveEventData(EVENT_NAME)
local startedAt  = eventData.startedAt

local eventTrove      = Trove.new()
local spawnedEntities = {}
local lockedTargets   = {}
local isActive        = true
local rng             = Random.new()

-- ─── Raycast ─────────────────────────────────────────────────────────────────

local RAY_PARAMS = RaycastParams.new()
RAY_PARAMS.FilterType = Enum.RaycastFilterType.Include
RAY_PARAMS.FilterDescendantsInstances = {
    workspace:FindFirstChild("Map") or workspace,
    workspace.Terrain,
}

local function stickToGround(position: Vector3): Vector3
    local result = workspace:Raycast(
        position + Vector3.new(0, 10, 0),
        Vector3.new(0, -20, 0),
        RAY_PARAMS
    )
    return result and result.Position + Vector3.new(0, 1, 0) or position
end

-- ─── Animation speed — exact mirror of decompiled controller ─────────────────

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

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function getWanderParts(): { BasePart }
    local parts = {}
    for _, p in ipairs(WANDER_FOLDER:GetChildren()) do
        if p:IsA("BasePart") then table.insert(parts, p) end
    end
    return parts
end

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

-- ─── Animation controller ────────────────────────────────────────────────────
-- Unified state machine: one syncState function driven by three attribute signals.
-- Animator is the Animator instance sitting inside the Humanoid named
-- "AnimationController" on the cloned mesh model.

local function buildAnimController(
    rootModel : Model,   -- the invisible-root Gatito model (carries attributes)
    animator  : Animator,
    trove     : typeof(Trove.new())
)
    local danceAnim  = EVENT_SCRIPT:FindFirstChild("GatitoDance1")
    local dance2Anim = EVENT_SCRIPT:FindFirstChild("GatitoDance2_")
    local walkAnim   = EVENT_SCRIPT:FindFirstChild("GatitoWalk")
    local idleAnim   = EVENT_SCRIPT:FindFirstChild("GatitoIdle")
    local attackAnim = EVENT_SCRIPT:FindFirstChild("GatitoAttack")

    local danceTrack  = danceAnim and animator:LoadAnimation(danceAnim) or nil
    local dance2Track = dance2Anim and animator:LoadAnimation(dance2Anim) or nil
    local walkTrack   = walkAnim  and animator:LoadAnimation(walkAnim)  or nil
    local idleTrack   = idleAnim  and animator:LoadAnimation(idleAnim)  or nil

    if danceTrack  then
        danceTrack.Looped   = true
        danceTrack.Priority = Enum.AnimationPriority.Action
    end
    if dance2Track then
        dance2Track.Looped   = true
        dance2Track.Priority = Enum.AnimationPriority.Action
    end
    if walkTrack then
        walkTrack.Priority = Enum.AnimationPriority.Action2
    end
    if idleTrack then
        idleTrack.Looped   = true
        idleTrack.Priority = Enum.AnimationPriority.Idle
    end

    trove:Add(function()
        if danceTrack  then danceTrack:Stop(0);  danceTrack:Destroy()  end
        if dance2Track then dance2Track:Stop(0); dance2Track:Destroy() end
        if walkTrack   then walkTrack:Stop(0);   walkTrack:Destroy()   end
        if idleTrack   then idleTrack:Stop(0);   idleTrack:Destroy()   end
    end)

    -- Single resolver — called on every relevant attribute change
    local function syncState()
        local isRunning = rootModel:GetAttribute("IsRunning")
        local isChasing = rootModel:GetAttribute("IsChasing")
        local isDancing = rootModel:GetAttribute("Dance")

        if isRunning or isChasing then
            if walkTrack   and not walkTrack.IsPlaying   then walkTrack:Play()    end
            if danceTrack  and danceTrack.IsPlaying       then danceTrack:Stop()  end
            if dance2Track and dance2Track.IsPlaying      then dance2Track:Stop() end
            if idleTrack   and idleTrack.IsPlaying        then idleTrack:Stop()   end
        elseif isDancing then
            -- Use dance1 by default; dance2 selection matches player controller
            -- logic (loop 2, phase 7.308–29.126) — gatitos always use dance1
            if danceTrack  and not danceTrack.IsPlaying  then danceTrack:Play()  end
            if dance2Track and dance2Track.IsPlaying      then dance2Track:Stop() end
            if walkTrack   and walkTrack.IsPlaying        then walkTrack:Stop()   end
            if idleTrack   and idleTrack.IsPlaying        then idleTrack:Stop()   end
        else
            if idleTrack   and not idleTrack.IsPlaying   then idleTrack:Play()   end
            if danceTrack  and danceTrack.IsPlaying       then danceTrack:Stop()  end
            if dance2Track and dance2Track.IsPlaying      then dance2Track:Stop() end
            if walkTrack   and walkTrack.IsPlaying        then walkTrack:Stop()   end
        end
    end

    trove:Add(rootModel:GetAttributeChangedSignal("IsRunning"):Connect(syncState))
    trove:Add(rootModel:GetAttributeChangedSignal("IsChasing"):Connect(syncState))
    trove:Add(rootModel:GetAttributeChangedSignal("Dance"):Connect(syncState))

    -- Attack: fresh track per trigger, Action4 wins over everything
    trove:Add(rootModel:GetAttributeChangedSignal("AttackAnimation"):Connect(function()
        if not rootModel:GetAttribute("AttackAnimation") then return end
        if not attackAnim then return end
        local attackTrack = animator:LoadAnimation(attackAnim)
        attackTrack.Looped   = false
        attackTrack.Priority = Enum.AnimationPriority.Action4
        attackTrack:Play()
        attackTrack.Stopped:Once(function()
            attackTrack:Destroy()
        end)
    end))

    -- Speed tick — PostSimulation keeps all playing tracks locked to music phase
    trove:Add(RunService.PostSimulation:Connect(function()
        local elapsed = workspace:GetServerTimeNow() - startedAt
        local speed   = calcAnimSpeed(elapsed)
        if danceTrack  and danceTrack.IsPlaying  then danceTrack:AdjustSpeed(speed)  end
        if dance2Track and dance2Track.IsPlaying then dance2Track:AdjustSpeed(speed) end
        if walkTrack   and walkTrack.IsPlaying   then walkTrack:AdjustSpeed(speed)   end
        if idleTrack   and idleTrack.IsPlaying   then idleTrack:AdjustSpeed(speed)   end
    end))

    syncState()
end

-- ─── Model ───────────────────────────────────────────────────────────────────

local GATITOS_FOLDER = EVENT_SCRIPT:FindFirstChild("Gatitos")

local function createGatito(position: Vector3): (Model, Animator?)
    local model = Instance.new("Model")
    model.Name  = "Gatito"

    -- Invisible anchor root — server spawner expects this exact structure
    local root = Instance.new("Part")
    root.Name         = "HumanoidRootPart"
    root.Size         = Vector3.new(2, 2, 2)
    root.Transparency = 1
    root.Anchored     = true
    root.CanCollide   = false
    root.CFrame       = CFrame.new(stickToGround(position))
    root.Parent       = model
    model.PrimaryPart = root

    -- Variant cycling — matches server module exactly
    local totalOptions  = #VARIANTS + 1
    local chosenVariant = VARIANTS[variantIndex]
    if chosenVariant then
        model:SetAttribute("Variant", chosenVariant)
    end
    model:SetAttribute("Dance",           true)
    model:SetAttribute("IsRunning",       false)
    model:SetAttribute("IsChasing",       false)
    model:SetAttribute("AttackAnimation", false)

    CollectionService:AddTag(model, TAG_NAME)
    variantIndex = (variantIndex % totalOptions) + 1

    -- Mesh clone + animator rig
    local animator: Animator? = nil

    if GATITOS_FOLDER then
        local templateName = chosenVariant or "Gatito"
        local template = GATITOS_FOLDER:FindFirstChild(templateName)
            or GATITOS_FOLDER:FindFirstChild("Gatito")

        if template then
            local meshClone = template:Clone()

            -- Strip whatever AnimationController shipped with the template
            local existingAC = meshClone:FindFirstChild("AnimationController")
            if existingAC then existingAC:Destroy() end

            -- Proper Humanoid+Animator rig — same pattern as decompiled initGatitoObserver
            local humanoid = Instance.new("Humanoid")
            humanoid.Name                 = "AnimationController"
            humanoid.EvaluateStateMachine = false
            humanoid.DisplayDistanceType  = Enum.HumanoidDisplayDistanceType.None
            humanoid.PlatformStand        = true
            humanoid.Parent               = meshClone

            local animatorInst = Instance.new("Animator")
            animatorInst.Parent = humanoid
            animator = animatorInst

            -- Weld mesh primary to invisible root so movement drives the visual
            local weld   = Instance.new("Weld")
            weld.Part0   = meshClone.PrimaryPart
            weld.Part1   = root
            weld.Parent  = meshClone.PrimaryPart

            meshClone.Parent = model
        end
    end

    model.Parent = workspace
    return model, animator
end

-- ─── Wander ──────────────────────────────────────────────────────────────────

local function wander(hunterData)
    local entity   = hunterData.Model
    local homePart = hunterData.Home
    if not entity or not entity.PrimaryPart then return end
    if entity:GetAttribute("IsChasing") or entity:GetAttribute("IsRunning") then return end

    local targetPos = stickToGround(randomPointInPart(homePart))
    local startPos  = entity:GetPivot().Position
    local diff      = targetPos - startPos
    local distance  = diff.Magnitude
    if distance < 1 then return end

    local direction = diff.Unit
    local duration  = distance / WANDER_SPEED

    hunterData.wanderGen = (hunterData.wanderGen or 0) + 1
    local myGen = hunterData.wanderGen

    entity:SetAttribute("IsRunning", true)

    eventTrove:Add(task.spawn(function()
        local elapsed = 0
        while elapsed < duration
            and isActive
            and entity and entity.Parent
            and not entity:GetAttribute("IsChasing")
            and hunterData.wanderGen == myGen
        do
            local dt  = task.wait()
            elapsed  += dt
            local alpha = math.clamp(elapsed / duration, 0, 1)
            local pos   = stickToGround(startPos:Lerp(targetPos, alpha))
            entity:PivotTo(CFrame.new(pos, pos + direction))
        end
        if entity and entity.Parent and hunterData.wanderGen == myGen then
            entity:SetAttribute("IsRunning", false)
        end
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

    eventTrove:Add(task.spawn(function()
        local chaseStart = os.clock()
        local reached    = false

        while isActive
            and gatito and gatito.Parent
            and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart
        do
            if os.clock() - chaseStart > 30 then break end

            local myPos   = gatito:GetPivot().Position
            local tgtPos  = targetAnimal.PrimaryPart.Position
            local delta   = tgtPos - myPos
            local dist    = delta.Magnitude

            if dist <= CHASE_REACH_DIST then
                reached = true
                break
            end

            local dt      = task.wait()
            local flatDir = Vector3.new(delta.X, 0, delta.Z)
            if flatDir.Magnitude < 1e-4 then continue end
            flatDir = flatDir.Unit

            local newPos = stickToGround(myPos + flatDir * math.min(CHASE_SPEED * dt, dist))
            gatito:PivotTo(CFrame.new(newPos, newPos + flatDir))
        end

        gatito:SetAttribute("IsRunning", false)

        if reached and targetAnimal and targetAnimal.Parent then
            gatito:SetAttribute("AttackAnimation", true)

            local elapsed    = 0
            local attackConn: RBXScriptConnection
            attackConn = RunService.Heartbeat:Connect(function(dt)
                elapsed += dt
                if elapsed >= ATTACK_DURATION
                    or not isActive
                    or not (targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart)
                then
                    attackConn:Disconnect()
                    return
                end

                local tPos    = targetAnimal.PrimaryPart.Position
                local mPos    = gatito.PrimaryPart.Position
                local delta2  = tPos - mPos
                local dist2   = delta2.Magnitude

                if dist2 > CHASE_STICK_DIST then
                    local flatDir = Vector3.new(delta2.X, 0, delta2.Z)
                    if flatDir.Magnitude < 1e-4 then return end
                    flatDir = flatDir.Unit
                    local newPos = stickToGround(mPos + delta2.Unit * math.min(CHASE_SPEED * dt, dist2))
                    gatito:PivotTo(CFrame.new(newPos, newPos + flatDir))
                end
            end)

            task.wait(ATTACK_DURATION)
            attackConn:Disconnect()

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
    end))
end

-- ─── Spawn ────────────────────────────────────────────────────────────────────

local function spawnGatito(homePart: BasePart)
    if not isActive or not homePart then return end

    local spawnPos          = randomPointInPart(homePart)
    local model, animator   = createGatito(spawnPos)

    local gatitoTrove = eventTrove:Extend()
    gatitoTrove:Add(model)

    -- Wire animation state machine directly — animator returned from createGatito,
    -- no child-search needed
    if animator then
        buildAnimController(model, animator, gatitoTrove)
    end

    local data = {
        Model     = model,
        Home      = homePart,
        Trove     = gatitoTrove,
        wanderGen = 0,
    }
    table.insert(spawnedEntities, data)
    return data
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    local elapsed   = workspace:GetServerTimeNow() - startedAt
    local remaining = math.max(0, ACTIVATION_DELAY - elapsed)
    if remaining > 0 then task.wait(remaining) end
    if not isActive then return end

    local wanderParts = getWanderParts()
    if #wanderParts == 0 then
        warn("[AyMiGatito] No BaseParts in", WANDER_FOLDER:GetFullName())
        return
    end

    for _, part in ipairs(wanderParts) do
        for _ = 1, GATITOS_PER_WANDER do
            spawnGatito(part)
        end
    end

    -- Wander tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            for _, hunterData in ipairs(spawnedEntities) do
                local model = hunterData.Model
                if model and model.Parent
                    and not model:GetAttribute("IsChasing")
                    and not model:GetAttribute("IsRunning")
                then
                    task.delay(rng:NextNumber(0, 2), function()
                        if isActive and model and model.Parent
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

    -- Live animal cache — avoids GetTagged on every attack tick
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

    -- Attack tick
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

    -- Watchdog — cleans up when event ends
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end

    isActive = false
    eventTrove:Destroy()
    table.clear(spawnedEntities)
    table.clear(lockedTargets)
end

task.spawn(main)
