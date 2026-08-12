local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local CollectionService  = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")

local Observers = require(ReplicatedStorage.Packages.Observers)
local Trove     = require(ReplicatedStorage.Packages.Trove)

local EventScript = ReplicatedStorage.Controllers.EventController.Events["Ay Mi Gatito"]

repeat task.wait() until ReplicatedStorage:GetAttribute("AyMiGatitoEvent")

local managedObj = Trove.new()

-- ── NpcPathfinding inlined ─────────────────────────────────────────────────
local WALKABLE_TAGS           = { "Ground", "Carpet" }
local DEFAULT_REACH_THRESHOLD = 1.5
local DEFAULT_TURN_SPEED      = 8
local DEFAULT_AGENT_PARAMS    = {
    AgentRadius     = 2,
    AgentHeight     = 5,
    AgentCanJump    = false,
    AgentCanClimb   = false,
    WaypointSpacing = 4,
}

local walkableParts = {}
local walkableSet   = {}
local filterDirty   = true

local groundRayParams = RaycastParams.new()
groundRayParams.FilterType = Enum.RaycastFilterType.Include
groundRayParams.FilterDescendantsInstances = {}
groundRayParams.IgnoreWater = true

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

local function isModelValid(model)
    return model and model.Parent and model.PrimaryPart and model.PrimaryPart.Parent
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
    local cf = model.PrimaryPart.CFrame
    local targetCF = CFrame.new(newPos, newPos + flatDir)
    local currentRot = CFrame.new(newPos) * CFrame.fromMatrix(Vector3.zero, cf.RightVector, Vector3.new(0, 1, 0))
    local alpha = math.min(1, turnSpeed * dt)
    if not isModelValid(model) then return end
    pcall(function() model:PivotTo(currentRot:Lerp(targetCF, alpha)) end)
end

local function stickToGround(position, yOffset, castUp, castDown)
    if not position then return Vector3.zero end
    local up  = castUp   or 10
    local dn  = castDown or 50
    local off = yOffset  or 1.5
    refreshGroundFilter()
    if #walkableParts == 0 then return position end
    local origin = position + Vector3.new(0, up, 0)
    local ok, result = pcall(function()
        return workspace:Raycast(origin, Vector3.new(0, -(up + dn), 0), groundRayParams)
    end)
    if ok and result then return result.Position + Vector3.new(0, off, 0) end
    return position
end

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

local function moveTo(model, targetPos, speed, opts)
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
            local pPart = model.PrimaryPart
            if not pPart then return false end
            local toWp    = wp - pPart.Position
            local flatVec = Vector3.new(toWp.X, 0, toWp.Z)
            if flatVec.Magnitude <= threshold then break end
            local dt = RunService.Heartbeat:Wait()
            if dt <= 0 then continue end
            if not isModelValid(model) then return false end
            local pPart2  = model.PrimaryPart
            if not pPart2 then return false end
            local moveAmt = math.min(speed * dt, flatVec.Magnitude)
            local flatDir = flatVec.Unit
            local newPos  = stickToGround(pPart2.Position + flatDir * moveAmt, opts.yOffset)
            smoothTurn(model, newPos, flatDir, dt, opts.turnSpeed or DEFAULT_TURN_SPEED)
        end
    end
    return isModelValid(model)
end

-- ── animation speed curve ──────────────────────────────────────────────────
local function getAnimSpeed(startedAt)
    local t       = workspace:GetServerTimeNow() - startedAt
    local elapsed = t - 7
    if t < 7 then return 0 end
    if t >= 222.313 then return math.max(0, 1 - (t - 222.313) / 3) end
    local phase = elapsed % 72.771
    if phase >= 43 and phase < 48 then return 0.4
    elseif phase >= 48 and phase < 50 then return (phase - 48) / 2 * 0.3 + 0.4
    elseif phase >= 50 and phase < 55.5 then return 0.7
    elseif phase >= 55.5 and phase < 57 then return (phase - 55.5) / 1.5 * 0.3 + 0.7
    else return 1 end
end

-- ── wander ─────────────────────────────────────────────────────────────────
local WANDER_FOLDER = workspace.Events:FindFirstChild("Ay Mi Gatito")
local WANDER_SPEED  = 16
local rng           = Random.new()

local function startWander(gatito)
    if not gatito or not gatito.Parent then return end
    if gatito:GetAttribute("IsChasing") or gatito:GetAttribute("IsRunning") then return end
    if not WANDER_FOLDER then return end

    local home, bestDist = nil, math.huge
    for _, part in WANDER_FOLDER:GetChildren() do
        if part.Name == "Wander" then
            local d = (part.Position - gatito:GetPivot().Position).Magnitude
            if d < bestDist then home = part bestDist = d end
        end
    end
    if not home then return end

    local size      = home.Size
    local offset    = Vector3.new(rng:NextNumber(-size.X/2, size.X/2), 0, rng:NextNumber(-size.Z/2, size.Z/2))
    local targetPos = stickToGround(home.Position + offset)

    gatito:SetAttribute("IsRunning", true)
    task.spawn(function()
        moveTo(gatito, targetPos, WANDER_SPEED, {
            maxTime = 10,
            shouldStop = function()
                return not gatito.Parent or gatito:GetAttribute("IsChasing")
            end,
        })
        if gatito.Parent then gatito:SetAttribute("IsRunning", false) end
    end)
end

-- ── gatito observer ────────────────────────────────────────────────────────
local animData  = {}
local startedAt = 0

managedObj:Add(RunService.PostSimulation:Connect(function()
    if #animData == 0 then return end
    local speed = getAnimSpeed(startedAt)
    for _, entry in animData do
        if entry.dance and entry.dance.IsPlaying then entry.dance:AdjustSpeed(speed) end
        if entry.walk  and entry.walk.IsPlaying  then entry.walk:AdjustSpeed(speed)  end
        if entry.idle  and entry.idle.IsPlaying  then entry.idle:AdjustSpeed(speed)  end
    end
end))

managedObj:Add(Observers.observeTag("Gatito", function(gatito)
    local addObj  = Trove.new()
    local root    = gatito:WaitForChild("HumanoidRootPart")
    local variant = gatito:GetAttribute("Variant") or "Gatito"
    local model   = addObj:Clone(EventScript.Gatitos:FindFirstChild(variant) or EventScript.Gatitos.Gatito)

    local weld   = addObj:Add(Instance.new("Weld"))
    weld.Part0   = model.PrimaryPart
    weld.Part1   = root
    weld.Parent  = model.PrimaryPart
    model.Parent = gatito

    local ac = model:FindFirstChild("AnimationController")
    if ac then ac:Destroy() end

    local humanoid = Instance.new("Humanoid", model)
    Instance.new("Animator", humanoid)
    humanoid.Name                 = "AnimationController"
    humanoid.EvaluateStateMachine = false
    humanoid.DisplayDistanceType  = Enum.HumanoidDisplayDistanceType.None
    humanoid.PlatformStand        = true

    local Animator = model.AnimationController.Animator
    local dance, walk, idle

    local GatitoDance1 = EventScript:FindFirstChild("GatitoDance1")
    if GatitoDance1 then
        dance = Animator:LoadAnimation(GatitoDance1)
        dance.Looped = true
        dance.Priority = Enum.AnimationPriority.Action
        addObj:Add(function() dance:Stop(0) dance:Destroy() end)
    end

    local GatitoWalk = EventScript:FindFirstChild("GatitoWalk")
    if GatitoWalk then
        walk = Animator:LoadAnimation(GatitoWalk)
        walk.Priority = Enum.AnimationPriority.Action2
        addObj:Add(function() walk:Stop(0) walk:Destroy() end)
    end

    local GatitoIdle = EventScript:FindFirstChild("GatitoIdle")
    if GatitoIdle then
        idle = Animator:LoadAnimation(GatitoIdle)
        idle.Looped = true
        idle.Priority = Enum.AnimationPriority.Idle
        addObj:Add(function() idle:Stop(0) idle:Destroy() end)
    end

    addObj:Add(gatito:GetAttributeChangedSignal("AttackAnimation"):Connect(function()
        local GatitoAttack = EventScript:FindFirstChild("GatitoAttack")
        if not GatitoAttack then return end
        local track = Animator:LoadAnimation(GatitoAttack)
        track.Looped   = false
        track.Priority = Enum.AnimationPriority.Action4
        track:Play()
        addObj:Add(function() track:Stop(0) track:Destroy() end)
    end))

    local function updateMovement()
        local running = gatito:GetAttribute("IsRunning")
        local chasing = gatito:GetAttribute("IsChasing")
        if running or chasing then
            if walk and not walk.IsPlaying then walk:Play() end
            if idle  then idle:Stop() end
            if dance then dance:Stop() end
        else
            if walk then walk:Stop() end
            if gatito:GetAttribute("Dance") then
                if dance and not dance.IsPlaying then dance:Play() end
            elseif idle and not idle.IsPlaying then
                idle:Play()
            end
        end
    end

    addObj:Add(gatito:GetAttributeChangedSignal("IsRunning"):Connect(updateMovement))
    addObj:Add(gatito:GetAttributeChangedSignal("IsChasing"):Connect(updateMovement))
    addObj:Add(Observers.observeAttribute(gatito, "Dance", function(val)
        if not val then
            if dance then dance:Stop() end
            if idle and not idle.IsPlaying then idle:Play() end
        else
            if idle then idle:Stop() end
            if dance and not dance.IsPlaying then dance:Play() end
        end
        return nil
    end))

    updateMovement()

    local entry = { dance = dance, walk = walk, idle = idle }
    table.insert(animData, entry)
    addObj:Add(function()
        local idx = table.find(animData, entry)
        if idx then table.remove(animData, idx) end
    end)

    addObj:Add(task.spawn(function()
        while gatito.Parent and ReplicatedStorage:GetAttribute("AyMiGatitoEvent") do
            if not gatito:GetAttribute("IsChasing") and not gatito:GetAttribute("IsRunning") then
                startWander(gatito)
            end
            task.wait(2 + rng:NextNumber(0, 1))
        end
    end))

    return addObj:WrapClean()
end))

task.spawn(function()
    while ReplicatedStorage:GetAttribute("AyMiGatitoEvent") do task.wait(1) end
    managedObj:Destroy()
end)
