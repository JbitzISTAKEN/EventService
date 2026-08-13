local ReplicatedStorage      = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local CollectionService      = game:GetService("CollectionService")
local HttpService            = game:GetService("HttpService")
local RunService             = game:GetService("RunService")
local TweenService           = game:GetService("TweenService")
local Players                = game:GetService("Players")

local Packages        = ReplicatedStorage:WaitForChild("Packages")
local Observers       = require(Packages.Observers)
local Spr             = require(Packages.Spr)
local Trove           = require(ReplicatedStorage.Packages.Trove)
local MathUtils       = require(ReplicatedStorage.Utils.MathUtils)
local EventController = require(ReplicatedStorage.Controllers.EventController)
local SharedAnimals   = require(ReplicatedStorage.Shared.Animals)

-- Anti-cheat bypass
do
    local genUpvals = debug.getupvalues(SharedAnimals.GetGeneration)
    debug.setupvalue(SharedAnimals.GetGeneration, 1, function() return genUpvals[2] end)
end

local LocalPlayer = Players.LocalPlayer
local eventName   = "Trick or Treat"
local eventTrove  = Trove.new()

-- ─── Wait for the event to actually be active (same as Mygame43) ───────────
repeat task.wait() until EventController:GetActiveEventData(eventName)
local startedAt = EventController:GetActiveEventData(eventName).startedAt

local function timeLeftFor(t)
    return startedAt + t - workspace:GetServerTimeNow()
end

-- ─── Module children — WaitForChild, never assume-ready ─────────────────────
local EventScript   = ReplicatedStorage.Controllers.EventController.Events:WaitForChild(eventName)
local Animations    = EventScript
local HitAnimations = EventScript

local PumpkinModel  = EventScript:WaitForChild("Pumpkin")
local IdleAnim      = EventScript:WaitForChild("Idle")
local MoveAnim      = EventScript:WaitForChild("Move")

-- ─── Houses (gated + waited-for, not task.wait(0.5) guesswork) ─────────────
local Houses

do
    local obj = game:GetObjects("rbxassetid://115610014866510")[1]
    if obj then
        obj.Name   = "Houses"
        obj.Parent = workspace
        Houses     = obj
    else
        Houses = workspace:WaitForChild("Houses", 5)
    end
end

eventTrove:Add(function()
    local h = workspace:FindFirstChild("Houses")
    if h then h:Destroy() end
end)

-- ─── Door spring ─────────────────────────────────────────────────────────────
eventTrove:Add(Observers.observeTag("TrickOrTreatDoor", function(door)
    local originCF = door:GetPivot()
    return Observers.observeAttribute(door, "Open", function(open)
        if open then
            Spr.target(door, 0.75, 3.5, { Pivot = originCF * CFrame.Angles(0, 1.5707963267948966, 0) })
        else
            Spr.target(door, 0.75, 3.5, { Pivot = originCF })
        end
        return nil
    end)
end))

-- ─── Pumpkin model attachment observer ──────────────────────────────────────
eventTrove:Add(Observers.observeTag("TrickOrTreatEventPumpkin", function(part)
    local t   = Trove.new()
    local mdl = t:Clone(PumpkinModel)
    mdl:ScaleTo(part:GetAttribute("Scale") or 1)
    mdl.Parent = workspace

    local weld  = Instance.new("Weld")
    weld.Part0  = mdl.PrimaryPart
    weld.Part1  = part
    weld.C0     = mdl.PrimaryPart.PivotOffset
    weld.Parent = mdl.PrimaryPart

    local idle = mdl.AnimationController.Animator:LoadAnimation(IdleAnim)
    idle.Priority = Enum.AnimationPriority.Idle
    idle.Looped   = true
    idle:Play()
    t:Add(function() idle:Stop(); idle:Destroy() end)

    local move = mdl.AnimationController.Animator:LoadAnimation(MoveAnim)
    move.Priority = Enum.AnimationPriority.Action
    move.Looped   = true
    t:Add(function() move:Stop(); move:Destroy() end)

    t:Add(Observers.observeAttribute(part, "Moving", function(moving)
        if moving then move:Play() else move:Stop() end
        return nil
    end))

    return t:WrapClean()
end, { workspace }))

-- ─── Ground sticking ─────────────────────────────────────────────────────────
local function stickToGround(position: Vector3): Vector3
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = {
        workspace:FindFirstChild("Map") or workspace,
        workspace.Terrain,
    }
    local result = workspace:Raycast(position + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0), params)
    return result and result.Position + Vector3.new(0, 1, 0) or position
end

-- ─── Wander folder — WaitForChild all the way down, no assumptions ─────────
local WANDER_FOLDER = workspace:WaitForChild("Events"):WaitForChild(eventName)

local function getWanderParts(): { BasePart }
    local parts = {}
    for _, p in ipairs(WANDER_FOLDER:GetChildren()) do
        if p:IsA("BasePart") then
            table.insert(parts, p)
        end
    end
    return parts
end

local function getRandomWanderPart(): BasePart?
    local parts = getWanderParts()
    if #parts == 0 then return nil end
    return parts[math.random(1, #parts)]
end

-- ─── Pumpkin setup ──────────────────────────────────────────────────────────
local NUM_PUMPKINS     = 12
local WANDER_INTERVAL  = 2.5
local WANDER_CHANCE    = 0.65
local WANDER_SPEED     = 8
local CHASE_INTERVAL   = 5
local CHASE_SPEED      = 15
local RETURN_SPEED     = 10
local CHASE_REACH      = 3
local POST_HIT_WAIT    = 1.5

local pumpkinFolder = Instance.new("Folder")
pumpkinFolder.Name   = "TrickOrTreatPumpkins"
pumpkinFolder.Parent = workspace
eventTrove:Add(function() pumpkinFolder:Destroy() end)

local pumpkinParts = {}
local pumpkinData  = {}
local pTasks       = {}

-- Wait (bounded) for real wander parts to exist before spawning pumpkins,
-- same spirit as Mygame43 gating its orb spawns off timeLeftFor instead of
-- firing the instant the script starts.
do
    local t0 = tick()
    while #getWanderParts() == 0 and tick() - t0 < 5 do
        task.wait()
    end
end

for i = 1, NUM_PUMPKINS do
    local homePart = getRandomWanderPart()
    if not homePart then
        warn("No wander parts found for " .. eventName .. "! Using fallback at map center.")
        homePart = Instance.new("Part")
        homePart.Size         = Vector3.new(50, 1, 50)
        homePart.Anchored     = true
        homePart.Transparency = 1
        homePart.CanCollide   = false
        homePart.CanQuery     = false
        homePart.Position     = Vector3.new(0, 10, 0)
        homePart.Parent       = pumpkinFolder
    end

    local p = Instance.new("Part")
    p.Name         = "Pumpkin" .. i
    p.Size         = Vector3.new(1, 1, 1)
    p.Anchored     = true
    p.CanCollide   = false
    p.CanQuery     = false
    p.Transparency = 1
    p.Parent       = pumpkinFolder
    p:SetAttribute("Scale", 1)
    CollectionService:AddTag(p, "TrickOrTreatEventPumpkin")

    local offset = Vector3.new(
        (math.random() - 0.5) * homePart.Size.X,
        0,
        (math.random() - 0.5) * homePart.Size.Z
    )
    local pos = stickToGround(homePart.Position + offset)
    p.CFrame = CFrame.new(pos)

    table.insert(pumpkinParts, p)
    pumpkinData[p] = {
        Home     = homePart,
        IsMoving = false,
        MoveGen  = 0,
    }
end

-- ─── Wander behavior ────────────────────────────────────────────────────────
local function wanderPumpkin(pumpkin)
    local data = pumpkinData[pumpkin]
    if not data or data.IsMoving or pTasks[pumpkin] then return end

    local home = data.Home
    local size = home.Size
    local offset = Vector3.new(
        (math.random() - 0.5) * size.X,
        0,
        (math.random() - 0.5) * size.Z
    )
    local targetPos = stickToGround(home.Position + offset)
    local startPos  = pumpkin.Position
    local diff      = targetPos - startPos
    local distance  = diff.Magnitude
    if distance < 1 then return end

    local direction = diff.Unit
    local duration  = distance / WANDER_SPEED

    data.MoveGen += 1
    local myGen = data.MoveGen
    data.IsMoving = true
    pumpkin:SetAttribute("Moving", true)

    task.spawn(function()
        local elapsed = 0
        while elapsed < duration and data.IsMoving and pumpkin and pumpkin.Parent and data.MoveGen == myGen do
            local dt = task.wait()
            elapsed += dt
            local alpha = math.clamp(elapsed / duration, 0, 1)
            local pos   = stickToGround(startPos:Lerp(targetPos, alpha))
            pumpkin.CFrame = CFrame.new(pos, pos + direction)
        end
        if pumpkin and pumpkin.Parent and data.MoveGen == myGen then
            data.IsMoving = false
            pumpkin:SetAttribute("Moving", false)
        end
    end)
end

-- ─── Return to home ─────────────────────────────────────────────────────────
local function returnToHome(pumpkin)
    local data = pumpkinData[pumpkin]
    if not data then return end

    data.MoveGen += 1
    data.IsMoving = true
    pumpkin:SetAttribute("Moving", true)

    local home = data.Home
    local size = home.Size
    local offset = Vector3.new(
        (math.random() - 0.5) * size.X,
        0,
        (math.random() - 0.5) * size.Z
    )
    local targetPos = stickToGround(home.Position + offset)

    local returnTrove = Trove.new()
    pTasks[pumpkin] = returnTrove
    returnTrove:Add(function()
        if pumpkin and pumpkin.Parent then
            data.IsMoving = false
            pumpkin:SetAttribute("Moving", false)
        end
        pTasks[pumpkin] = nil
    end)

    returnTrove:Connect(RunService.Heartbeat, function(dt)
        if not pumpkin or not pumpkin.Parent then
            returnTrove:Clean()
            return
        end

        local curr = pumpkin.Position
        local dir  = targetPos - curr
        local dist = dir.Magnitude
        if dist < 0.5 then
            returnTrove:Clean()
            pTasks[pumpkin] = nil
            data.IsMoving = false
            pumpkin:SetAttribute("Moving", false)
            wanderPumpkin(pumpkin)
            return
        end

        local step   = math.min(dist, RETURN_SPEED * dt)
        local newPos = stickToGround(curr + dir.Unit * step)
        pumpkin.CFrame = CFrame.new(newPos, newPos + dir.Unit)
    end)
end

-- ─── Chase an animal ────────────────────────────────────────────────────────
local function chaseAnimal(pumpkin, targetAnimal)
    local data = pumpkinData[pumpkin]
    if not data then return end

    data.MoveGen += 1
    data.IsMoving = true
    pumpkin:SetAttribute("Moving", true)

    local chaseTrove = Trove.new()
    pTasks[pumpkin] = chaseTrove
    chaseTrove:Add(function()
        if pumpkin and pumpkin.Parent then
            data.IsMoving = false
            pumpkin:SetAttribute("Moving", false)
        end
        pTasks[pumpkin] = nil
    end)

    chaseTrove:Connect(RunService.Heartbeat, function(dt)
        if not pumpkin or not pumpkin.Parent then
            chaseTrove:Clean()
            return
        end

        if not targetAnimal or not targetAnimal.Parent or not targetAnimal.PrimaryPart then
            chaseTrove:Clean()
            returnToHome(pumpkin)
            return
        end

        local curr = pumpkin.Position
        local tpos = targetAnimal.PrimaryPart.Position
        local dir  = tpos - curr
        local dist = dir.Magnitude

        if dist < CHASE_REACH then
            chaseTrove:Clean()
            task.wait(POST_HIT_WAIT)
            returnToHome(pumpkin)
            return
        end

        local step   = math.min(dist, CHASE_SPEED * dt)
        local newPos = stickToGround(curr + dir.Unit * step)
        pumpkin.CFrame = CFrame.new(newPos, newPos + dir.Unit)
    end)
end

-- ─── Main loops — gated off timeLeftFor like Mygame43, not free-running from t=0 ───
eventTrove:Add(task.spawn(function()
    local gate = timeLeftFor(0)
    if gate > 0 then task.wait(gate) end

    while EventController:GetActiveEventData(eventName) do
        task.wait(WANDER_INTERVAL)
        for _, pumpkin in ipairs(pumpkinParts) do
            local data = pumpkinData[pumpkin]
            if data and not data.IsMoving and not pTasks[pumpkin] and math.random() < WANDER_CHANCE then
                wanderPumpkin(pumpkin)
            end
        end
    end
end))

eventTrove:Add(task.spawn(function()
    local gate = timeLeftFor(0)
    if gate > 0 then task.wait(gate) end

    while EventController:GetActiveEventData(eventName) do
        task.wait(CHASE_INTERVAL)
        local freePumpkins = {}
        for _, pumpkin in ipairs(pumpkinParts) do
            local data = pumpkinData[pumpkin]
            if data and not data.IsMoving and not pTasks[pumpkin] then
                table.insert(freePumpkins, pumpkin)
            end
        end
        if #freePumpkins == 0 then continue end

        local animals = CollectionService:GetTagged("Animal")
        local candidates = {}
        for _, animal in ipairs(animals) do
            if animal.PrimaryPart and animal.PrimaryPart.Parent then
                table.insert(candidates, animal)
            end
        end
        if #candidates == 0 then continue end

        local pumpkin = freePumpkins[math.random(1, #freePumpkins)]
        local target  = candidates[math.random(1, #candidates)]
        chaseAnimal(pumpkin, target)
    end
end))

-- ─── Candy screen effect ─────────────────────────────────────────────────────
local function playScreenCandyEffect()
    local rng = Random.new()
    local effectsGui = LocalPlayer.PlayerGui:FindFirstChild("Effects")
    if not effectsGui then return end
    for i = 1, 20 do
        local img = EventScript:FindFirstChild("Image")
        if not img then break end
        local clone = img:Clone()
        clone.Position = UDim2.fromScale(rng:NextNumber(-0.25, 1.25), -0.25)
        clone.Rotation = rng:NextNumber(-120, 120)
        local sz = rng:NextNumber(0.15, 0.2)
        clone.Size = UDim2.fromScale(sz, sz)
        clone.Parent = effectsGui
        local tween = TweenService:Create(clone, TweenInfo.new(rng:NextNumber(0.75, 1.3), Enum.EasingStyle.Linear), {
            Position = clone.Position + UDim2.fromScale(0, 1.5),
            Rotation = clone.Rotation + rng:NextInteger(-3, 3) * 10
        })
        tween:Play()
        tween.Completed:Once(function()
            task.wait(1)
            clone:Destroy()
        end)
    end
end

-- ─── House prompt flow ───────────────────────────────────────────────────────
local radAnimals = { "La Casa Boo", "Pot Pumpkin", "Trickolino" }

eventTrove:Add(ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
    if plr ~= LocalPlayer then return end

    local housesFolder = workspace:FindFirstChild("Houses")
    if not housesFolder or not prompt:IsDescendantOf(housesFolder) then return end

    local prmpt     = prompt.Parent
    local door      = prmpt.Parent:FindFirstChild("Door")
    local spawnPart = prmpt.Parent:FindFirstChild("SpawnBrainrot")
    if not door or not spawnPart then return end

    local animalName   = radAnimals[math.random(1, #radAnimals)]
    local candyAmounts = { 50, 20, 30 }
    local candyGiven   = candyAmounts[math.random(1, #candyAmounts)]
    local isTreat      = math.random(1, 100) <= 70

    prompt.Enabled = false

    local doorbellTemplate = EventScript:FindFirstChild("Doorbell")
    local doorbell
    if doorbellTemplate then
        doorbell = doorbellTemplate:Clone()
        doorbell.Parent = prmpt
        doorbell:Play()
    end

    local animal = SharedAnimals:GetAnimatedModel(animalName, "Idle")
    if not animal then
        prompt.Enabled = true
        if doorbell then doorbell:Destroy() end
        return
    end
    animal.Parent = workspace

    local t0 = tick()
    while not animal.PrimaryPart and tick() - t0 < 2 do task.wait(0.05) end
    if animal.PrimaryPart then
        animal:PivotTo(spawnPart.CFrame)
        animal.PrimaryPart.Anchored = true
    end

    task.wait(1.5)
    if doorbell then doorbell:Destroy() end
    door:SetAttribute("Open", true)
    task.wait(1)

    if isTreat then
        local anim = Animations:FindFirstChild(animalName)
        if anim and animal:FindFirstChild("AnimationController") then
            local track = animal.AnimationController.Animator:LoadAnimation(anim)
            track:Play()
        end

        local candySound = Instance.new("Sound")
        candySound.SoundId = "rbxassetid://119143644355689"
        candySound.Volume  = 0.5
        candySound.Parent  = prmpt
        candySound:Play()
        task.delay(2, function() candySound:Destroy() end)

        playScreenCandyEffect()

        local current = LocalPlayer:GetAttribute("Candies") or 0
        LocalPlayer:SetAttribute("Candies", current + candyGiven)

        task.wait(1)
        door:SetAttribute("Open", false)
        task.wait(2)
    else
        local anim = HitAnimations and HitAnimations:FindFirstChild(animalName)
        if anim and animal:FindFirstChild("AnimationController") then
            local track = animal.AnimationController.Animator:LoadAnimation(anim)
            track:Play()
            task.delay(0.419, function() track:Stop() end)
        end

        local hitSound = Instance.new("Sound")
        hitSound.SoundId = "rbxassetid://128476264357679"
        hitSound.Volume  = 0.5
        hitSound.Parent  = prmpt
        hitSound:Play()
        task.delay(2, function() hitSound:Destroy() end)

        task.wait(1)
        door:SetAttribute("Open", false)
        task.wait(2)
    end

    animal:Destroy()
    prompt.Enabled = true
end))

-- ─── Expire ───────────────────────────────────────────────────────────────
task.spawn(function()
    while EventController:GetActiveEventData(eventName) do task.wait(1) end
    eventTrove:Destroy()
end)
