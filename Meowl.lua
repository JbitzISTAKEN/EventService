local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local Debris            = game:GetService("Debris")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove           = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Trove"))
local EventController = require(ReplicatedStorage:WaitForChild("Controllers"):WaitForChild("EventController"))

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

local FLY_SPEED           = 50
local REACH_DIST          = 5
local ATTACK_COOLDOWN_MIN = 5
local ATTACK_COOLDOWN_MAX = 10
local BURST_DURATION      = 0.5

local MeowlAssets = ReplicatedStorage:WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("Meowl")

local sessionTrove      = Trove.new()
local spawnedMeowls     = {}
local originalPositions = {}
local recentlyTargeted  = {}
local isActive          = true

-- ─── Track every animated Meowl model that gets parented to workspace ─────────

local visualCount = 0
local trackerConnection = workspace.DescendantAdded:Connect(function(desc)
    if desc:IsA("Model") and desc.Name == "Meowl" then
        visualCount += 1
        local id = visualCount
        warn(string.format(
            "[MEOWL TRACKER] Visual #%d spawned | Parent: %s | Time: %.3f",
            id,
            tostring(desc.Parent),
            os.clock()
        ))
        warn("[MEOWL TRACKER] Stack trace:\n" .. debug.traceback())

        -- also watch who welds to it
        desc.DescendantAdded:Connect(function(child)
            if child:IsA("Weld") then
                warn(string.format(
                    "[MEOWL TRACKER] Visual #%d got Weld | Part0: %s | Part1: %s",
                    id,
                    tostring(child.Part0 and child.Part0.Name),
                    tostring(child.Part1 and child.Part1.Name)
                ))
            end
        end)
    end
end)

-- ─── Load asset and build visuals ─────────────────────────────────────────────

print("[MEOWL DEBUG] Loading asset 139716127145162")
local objects = game:GetObjects("rbxassetid://139716127145162")
print("[MEOWL DEBUG] GetObjects returned " .. #objects .. " objects:")
for i, obj in objects do
    print(string.format("  [%d] %s (class: %s)", i, obj.Name, obj.ClassName))
    if obj:IsA("Folder") or obj:IsA("Model") then
        for _, child in obj:GetChildren() do
            print(string.format("      child: %s (class: %s) CFrame: %s",
                child.Name, child.ClassName,
                child:IsA("BasePart") and tostring(child.CFrame) or "N/A"
            ))
        end
    end
end

for _, obj in objects do
    obj.Name   = "Meowls"
    obj.Parent = workspace
    sessionTrove:Add(obj)
end

local meowlsFolder = workspace:WaitForChild("Meowls")
print("[MEOWL DEBUG] meowlsFolder children count: " .. #meowlsFolder:GetChildren())

for _, part in ipairs(meowlsFolder:GetChildren()) do
    if part:IsA("BasePart") then
        print(string.format("[MEOWL DEBUG] Registering part: %s at CFrame %s", part.Name, tostring(part.CFrame)))
        part.Anchored   = true
        part.CanCollide = false
        part:SetAttribute("Flying", false)
        part:SetAttribute("Attack", false)
        originalPositions[part] = part.CFrame
        table.insert(spawnedMeowls, part)

        print(string.format("[MEOWL DEBUG] Spawning visual for part: %s", part.Name))
        local visual = MeowlAssets:WaitForChild("Meowl"):Clone()
        visual.Parent = workspace
        sessionTrove:Add(visual)

        local weld     = Instance.new("Weld")
        weld.Part0     = visual.PrimaryPart
        weld.Part1     = part
        weld.C0        = visual.PrimaryPart.PivotOffset
        weld.Parent    = visual.PrimaryPart

        local animator = visual.AnimationController.Animator

        local idleTrack        = animator:LoadAnimation(MeowlAssets:WaitForChild("Idle"))
        idleTrack.Priority     = Enum.AnimationPriority.Idle
        idleTrack.Looped       = true
        idleTrack:Play()
        sessionTrove:Add(function() idleTrack:Stop(0) idleTrack:Destroy() end)

        local flyTrack         = animator:LoadAnimation(MeowlAssets:WaitForChild("Fly"))
        flyTrack.Priority      = Enum.AnimationPriority.Action
        flyTrack.Looped        = true
        sessionTrove:Add(function() flyTrack:Stop(0) flyTrack:Destroy() end)

        local attackTrack      = animator:LoadAnimation(MeowlAssets:WaitForChild("Attack"))
        attackTrack.Priority   = Enum.AnimationPriority.Action2
        attackTrack.Looped     = false
        sessionTrove:Add(function() attackTrack:Stop(0) attackTrack:Destroy() end)

        sessionTrove:Add(part:GetAttributeChangedSignal("Flying"):Connect(function()
            if part:GetAttribute("Flying") then flyTrack:Play() else flyTrack:Stop() end
        end))

        sessionTrove:Add(part:GetAttributeChangedSignal("Attack"):Connect(function()
            if part:GetAttribute("Attack") then attackTrack:Play() end
        end))
    end
end

print("[MEOWL DEBUG] Total parts registered: " .. #spawnedMeowls)
print("[MEOWL DEBUG] Watching workspace for any additional Meowl model spawns from other sources...")

-- ─── Burst ────────────────────────────────────────────────────────────────────

local function doBurst(target: Model)
    if not target or not target.PrimaryPart then return end
    local burst = MeowlAssets:WaitForChild("Burst"):Clone()
    burst.Parent = target.PrimaryPart
    if burst:IsA("BasePart") then
        burst.CFrame = CFrame.new(target.PrimaryPart.Position)
    end
    for _, v in ipairs(burst:GetDescendants()) do
        if v:IsA("ParticleEmitter") then
            v.Enabled = true
            task.delay(BURST_DURATION, function() v.Enabled = false end)
        elseif v:IsA("Sound") then
            v:Play()
        end
    end
    Debris:AddItem(burst, BURST_DURATION + 2)
end

-- ─── Movement ─────────────────────────────────────────────────────────────────

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

local function flyBack(meowl: BasePart)
    if not meowl or not meowl.Parent then return end
    local original = originalPositions[meowl]
    if not original then
        meowl:SetAttribute("Flying", false)
        return
    end

    local start    = meowl.Position
    local target   = original.Position
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
        meowl.CFrame = original
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
    for _, meowl in ipairs(spawnedMeowls) do
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

        task.spawn(function()
            local reached = flyToTarget(meowl, animal)
            if reached then
                meowl:SetAttribute("Attack", true)
                doBurst(animal)
                task.wait(BURST_DURATION)
                meowl:SetAttribute("Attack", false)
                task.wait(0.5)
            end
            flyBack(meowl)
        end)
    end
end))

-- ─── Cleanup ──────────────────────────────────────────────────────────────────

sessionTrove:Add(task.spawn(function()
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end
    isActive = false
    trackerConnection:Disconnect()
    sessionTrove:Destroy()
    table.clear(spawnedMeowls)
    table.clear(originalPositions)
    table.clear(recentlyTargeted)
end))
