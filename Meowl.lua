if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)

local EVENT_NAME          = "Meowl"
local FLY_SPEED           = 50
local REACH_DIST          = 5
local ATTACK_COOLDOWN_MIN = 5
local ATTACK_COOLDOWN_MAX = 10
local BURST_DURATION      = 0.5

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local sessionTrove      = Trove.new()
local spawnedMeowls     = {}
local originalPositions = {}
local recentlyTargeted  = {}
local isActive          = true

-- ─── Load meowls from asset ───────────────────────────────────────────────────

local meowlsFolder = sessionTrove:Add(Instance.new("Folder"))
meowlsFolder.Name   = "Meowls"
meowlsFolder.Parent = workspace

local objects = game:GetObjects("rbxassetid://139716127145162")
for _, obj in objects do
    obj.Parent = meowlsFolder
    obj:SetAttribute("Flying", false)
    obj:SetAttribute("Attack", false)
    if obj:IsA("BasePart") then
        originalPositions[obj] = obj.CFrame
    elseif obj:IsA("Model") and obj.PrimaryPart then
        originalPositions[obj] = obj:GetPivot()
    end
    table.insert(spawnedMeowls, obj)
end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getAnimals()
    return CollectionService:GetTagged("Animal")
end

local function getPivotPos(obj)
    if obj:IsA("BasePart") then
        return obj.Position
    elseif obj:IsA("Model") then
        return obj:GetPivot().Position
    end
end

local function setPivot(obj, cf)
    if obj:IsA("BasePart") then
        obj.CFrame = cf
    elseif obj:IsA("Model") then
        obj:PivotTo(cf)
    end
end

local function isFlying(obj)
    if obj:IsA("BasePart") then
        return obj:GetAttribute("Flying")
    elseif obj:IsA("Model") and obj.PrimaryPart then
        return obj.PrimaryPart:GetAttribute("Flying")
    end
end

local function setAttr(obj, key, val)
    if obj:IsA("BasePart") then
        obj:SetAttribute(key, val)
    elseif obj:IsA("Model") and obj.PrimaryPart then
        obj.PrimaryPart:SetAttribute(key, val)
    end
end

-- ─── Burst (local visual only) ────────────────────────────────────────────────

local function doBurst(target)
    if not target or not target.PrimaryPart then return end
    local part = Instance.new("Part")
    part.Size         = Vector3.new(6, 6, 6)
    part.Shape        = Enum.PartType.Ball
    part.Anchored     = true
    part.CanCollide   = false
    part.Transparency = 0.3
    part.BrickColor   = BrickColor.new("Bright violet")
    part.Material     = Enum.Material.Neon
    part.CFrame       = CFrame.new(target.PrimaryPart.Position)
    part.Parent       = workspace
    task.delay(BURST_DURATION, function()
        if part and part.Parent then part:Destroy() end
    end)
end

-- ─── Fly to target ────────────────────────────────────────────────────────────

local function flyToTarget(meowl, target)
    if not meowl or not meowl.Parent then return false end
    if not target or not target.Parent or not target.PrimaryPart then return false end

    setAttr(meowl, "Flying", true)

    while isActive and meowl.Parent and target and target.Parent and target.PrimaryPart do
        local targetPos  = target.PrimaryPart.Position + Vector3.new(0, 10, 0)
        local currentPos = getPivotPos(meowl)
        local distance   = (targetPos - currentPos).Magnitude

        if distance < REACH_DIST then
            setAttr(meowl, "Flying", false)
            return true
        end

        local dir  = (targetPos - currentPos).Unit
        local move = math.min(FLY_SPEED * RunService.Heartbeat:Wait(), distance)
        setPivot(meowl, CFrame.new(currentPos + dir * move, currentPos + dir * move + dir))
    end

    setAttr(meowl, "Flying", false)
    return false
end

-- ─── Fly back ─────────────────────────────────────────────────────────────────

local function flyBack(meowl)
    if not meowl or not meowl.Parent then return end
    local original = originalPositions[meowl]
    if not original then
        setAttr(meowl, "Flying", false)
        return
    end

    local start    = getPivotPos(meowl)
    local target   = original.Position
    local distance = (target - start).Magnitude
    local duration = distance / FLY_SPEED
    local t0       = os.clock()

    setAttr(meowl, "Flying", true)

    while os.clock() - t0 < duration and isActive and meowl.Parent do
        local alpha      = (os.clock() - t0) / duration
        local currentPos = start:Lerp(target, alpha)
        local lookDir    = target - currentPos
        if lookDir.Magnitude > 0 then
            setPivot(meowl, CFrame.new(currentPos, currentPos + lookDir.Unit))
        else
            setPivot(meowl, CFrame.new(currentPos))
        end
        task.wait()
    end

    if meowl and meowl.Parent then
        setPivot(meowl, original)
        setAttr(meowl, "Flying", false)
    end
end

-- ─── Select target ────────────────────────────────────────────────────────────

local function selectTarget()
    local now = workspace:GetServerTimeNow()

    for k, t in pairs(recentlyTargeted) do
        if now - t > 20 then recentlyTargeted[k] = nil end
    end

    local candidates = {}
    for _, animal in ipairs(getAnimals()) do
        if animal.PrimaryPart and not recentlyTargeted[animal.Name] then
            table.insert(candidates, animal)
        end
    end
    if #candidates == 0 then return nil, nil end

    local available = {}
    for _, meowl in ipairs(spawnedMeowls) do
        if meowl.Parent and not isFlying(meowl) then
            table.insert(available, meowl)
        end
    end
    if #available == 0 then return nil, nil end

    return candidates[math.random(1, #candidates)],
           available[math.random(1, #available)]
end

-- ─── Attack loop ──────────────────────────────────────────────────────────────

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
                setAttr(meowl, "Attack", true)
                doBurst(animal)
                task.wait(BURST_DURATION)
                setAttr(meowl, "Attack", false)
                task.wait(0.5)
            end
            flyBack(meowl)
        end)
    end
end))

-- ─── Shutdown when event ends ─────────────────────────────────────────────────

sessionTrove:Add(task.spawn(function()
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    sessionTrove:Destroy()
    table.clear(spawnedMeowls)
    table.clear(originalPositions)
    table.clear(recentlyTargeted)
end))
