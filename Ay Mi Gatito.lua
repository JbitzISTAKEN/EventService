local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Observers        = require(ReplicatedStorage.Packages.Observers)
local Trove            = require(ReplicatedStorage.Packages.Trove)
local NpcPathfinding   = require(ReplicatedStorage.Controllers.EventController.Events["Ay Mi Gatito"].NpcPathfinding)

local EventScript = ReplicatedStorage.Controllers.EventController.Events["Ay Mi Gatito"]
local Sounds      = ReplicatedStorage.Sounds.Events["Ay Mi Gatito"]

repeat task.wait() until ReplicatedStorage:GetAttribute("AyMiGatitoEvent")

local managedObj = Trove.new()

local function getAnimSpeed(t, startedAt)
    local elapsed = t - startedAt
    if elapsed < 7 then return 0 end
    local inner = elapsed - 7
    if t >= 222.313 then
        return math.max(0, 1 - (t - 222.313) / 3)
    end
    local phase = inner % 72.771
    if phase >= 43 and phase < 48 then return 0.4
    elseif phase >= 48 and phase < 50 then return (phase - 48) / 2 * 0.3 + 0.4
    elseif phase >= 50 and phase < 55.5 then return 0.7
    elseif phase >= 55.5 and phase < 57 then return (phase - 55.5) / 1.5 * 0.3 + 0.7
    else return 1 end
end

local WANDER_FOLDER = workspace.Events:FindFirstChild("Ay Mi Gatito")
local WANDER_SPEED  = 16
local rng           = Random.new()

local function startWander(gatito)
    if not gatito or not gatito.Parent then return end
    if gatito:GetAttribute("IsChasing") then return end
    if not WANDER_FOLDER then return end

    local home, bestDist = nil, math.huge
    for _, part in WANDER_FOLDER:GetChildren() do
        if part.Name == "Wander" then
            local d = (part.Position - gatito:GetPivot().Position).Magnitude
            if d < bestDist then home = part bestDist = d end
        end
    end
    if not home then return end

    local size   = home.Size
    local offset = Vector3.new(
        rng:NextNumber(-size.X / 2, size.X / 2),
        0,
        rng:NextNumber(-size.Z / 2, size.Z / 2)
    )
    local targetPos = NpcPathfinding.stickToGround(home.Position + offset)

    gatito:SetAttribute("IsRunning", true)
    task.spawn(function()
        NpcPathfinding.moveTo(gatito, targetPos, WANDER_SPEED, {
            maxTime = 10,
            shouldStop = function()
                return not gatito.Parent or gatito:GetAttribute("IsChasing")
            end,
        })
        if gatito.Parent then
            gatito:SetAttribute("IsRunning", false)
        end
    end)
end

local animData = {}

managedObj:Add(RunService.PostSimulation:Connect(function()
    if #animData == 0 then return end
    local speed = getAnimSpeed(workspace:GetServerTimeNow(), 0)
    for _, entry in animData do
        if entry.dance and entry.dance.IsPlaying then entry.dance:AdjustSpeed(speed) end
        if entry.walk  and entry.walk.IsPlaying  then entry.walk:AdjustSpeed(speed)  end
        if entry.idle  and entry.idle.IsPlaying  then entry.idle:AdjustSpeed(speed)  end
    end
end))

managedObj:Add(Observers.observeTag("Gatito", function(gatito)
    local addObj = Trove.new()

    local root    = gatito:WaitForChild("HumanoidRootPart")
    local variant = gatito:GetAttribute("Variant") or "Gatito"
    local model   = addObj:Clone(EventScript.Gatitos:FindFirstChild(variant) or EventScript.Gatitos.Gatito)

    local weld    = addObj:Add(Instance.new("Weld"))
    weld.Part0    = model.PrimaryPart
    weld.Part1    = root
    weld.Parent   = model.PrimaryPart
    model.Parent  = gatito

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
        dance          = Animator:LoadAnimation(GatitoDance1)
        dance.Looped   = true
        dance.Priority = Enum.AnimationPriority.Action
        addObj:Add(function() dance:Stop(0) dance:Destroy() end)
    end

    local GatitoWalk = EventScript:FindFirstChild("GatitoWalk")
    if GatitoWalk then
        walk          = Animator:LoadAnimation(GatitoWalk)
        walk.Priority = Enum.AnimationPriority.Action2
        addObj:Add(function() walk:Stop(0) walk:Destroy() end)
    end

    local GatitoIdle = EventScript:FindFirstChild("GatitoIdle")
    if GatitoIdle then
        idle          = Animator:LoadAnimation(GatitoIdle)
        idle.Looped   = true
        idle.Priority = Enum.AnimationPriority.Idle
        addObj:Add(function() idle:Stop(0) idle:Destroy() end)
    end

    addObj:Add(gatito:GetAttributeChangedSignal("AttackAnimation"):Connect(function()
        local GatitoAttack = EventScript:FindFirstChild("GatitoAttack")
        if not GatitoAttack then return end
        local track    = Animator:LoadAnimation(GatitoAttack)
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
