if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)

-- ─── Config ───────────────────────────────────────────────────────────────────

local EVENT_NAME       = "Mexico"
local ROACH_SPEED      = 30
local ROACH_Y_OFFSET   = 1.5
local PUT_HAT_DURATION = 0.5
local WANDER_FOLDER    = workspace:WaitForChild("Events"):WaitForChild("Wander")

local ATTACK_COOLDOWN_MIN        = 5
local ATTACK_COOLDOWN_MAX        = 10
local PLAYER_ATTACK_COOLDOWN_MIN = 15
local PLAYER_ATTACK_COOLDOWN_MAX = 25
local CHASE_MAX_TIME             = 30
local RECENT_ANIMAL_COOLDOWN     = 15
local RECENT_PLAYER_COOLDOWN     = 30

local DEFAULT_REACH_THRESHOLD = 1.5
local DEFAULT_TURN_SPEED      = 8

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove              = Trove.new()
local spawnedRoaches          = {}
local activeAttacks           = {}
local recentlyTargeted        = {}
local recentlyTargetedPlayers = {}
local isActive                = true
local isPaused                = false

-- ─── Sombrero asset ───────────────────────────────────────────────────────────

local sombreroTemplate = nil
do
    local obj = game:GetObjects("rbxassetid://99466679730663")[1]
    if obj then
        obj.Name   = "Sombrero"
        obj.Parent = workspace
        sombreroTemplate = obj
        eventTrove:Add(obj)
    end
end

-- ─── Walkable tag set — mirrors NpcPathfinding exactly ───────────────────────

local WALKABLE_TAGS = { "Ground", "Carpet" }
local walkableParts = {}
local walkableSet   = {}
local filterDirty   = true

local groundRayParams = RaycastParams.new()
groundRayParams.FilterType                 = Enum.RaycastFilterType.Include
groundRayParams.FilterDescendantsInstances = {}
groundRayParams.IgnoreWater                = true

local function addWalkable(inst)
    if not inst then return end
    if not inst:IsA("BasePart") then return end
    if walkableSet[inst] then return end
    walkableSet[inst] = true
    table.insert(walkableParts, inst)
    filterDirty = true
end

local function removeWalkable(inst)
    if not inst then return end
    if not walkableSet[inst] then return end
    walkableSet[inst] = nil
    for i = #walkableParts, 1, -1 do
        if walkableParts[i] == inst then
            table.remove(walkableParts, i)
            break
        end
    end
    filterDirty = true
end

for _, tag in ipairs(WALKABLE_TAGS) do
    for _, inst in ipairs(CollectionService:GetTagged(tag)) do
        addWalkable(inst)
    end
    CollectionService:GetInstanceAddedSignal(tag):Connect(addWalkable)
    CollectionService:GetInstanceRemovedSignal(tag):Connect(removeWalkable)
end

local function refreshGroundFilter()
    if filterDirty then
        groundRayParams.FilterDescendantsInstances = walkableParts
        filterDirty = false
    end
end

-- ─── stickToGround — exact NpcPathfinding contract ───────────────────────────

local function stickToGround(position, yOffset, castUp, castDown)
    if not position then return Vector3.new(0, 0, 0) end
    local up   = castUp   or 10
    local down = castDown or 50
    local off  = yOffset  or ROACH_Y_OFFSET
    refreshGroundFilter()
    if #walkableParts == 0 then return position end
    local origin = position + Vector3.new(0, up, 0)
    local dir    = Vector3.new(0, -(up + down), 0)
    local ok, result = pcall(function()
        return workspace:Raycast(origin, dir, groundRayParams)
    end)
    if ok and result then
        return result.Position + Vector3.new(0, off, 0)
    end
    return position
end

-- ─── smoothTurn — exact NpcPathfinding contract ──────────────────────────────

local function isModelValid(model)
    if not model then return false end
    if not model.Parent then return false end
    if not model.PrimaryPart then return false end
    if not model.PrimaryPart.Parent then return false end
    return true
end

local function smoothTurn(model, newPos, flatDir, dt, turnSpeed)
    if not isModelValid(model) then return end
    if not newPos or not flatDir then return end
    if dt <= 0 then return end
    if flatDir.Magnitude < 1e-4 then
        local look = model.PrimaryPart.CFrame.LookVector
        flatDir = Vector3.new(look.X, 0, look.Z)
        if flatDir.Magnitude < 1e-4 then
            flatDir = Vector3.new(0, 0, 1)
        end
    end
    flatDir = flatDir.Unit
    if not isModelValid(model) then return end
    local pPart = model.PrimaryPart
    if not pPart then return end
    local currentCFrame = pPart.CFrame
    local targetCF = CFrame.new(newPos, newPos + flatDir)
    local currentRot = CFrame.new(newPos)
        * CFrame.fromMatrix(
            Vector3.zero,
            currentCFrame.RightVector,
            Vector3.new(0, 1, 0)
        )
    local alpha = math.min(1, turnSpeed * dt)
    if not isModelValid(model) then return end
    local ok, err = pcall(function()
        model:PivotTo(currentRot:Lerp(targetCF, alpha))
    end)
    if not ok then
        warn("[Mexico] smoothTurn PivotTo failed:", err)
    end
end

-- ─── moveTo — waypoint-based, exact NpcPathfinding moveTo pattern ────────────

local PathfindingService = game:GetService("PathfindingService")

local DEFAULT_AGENT_PARAMS = {
    AgentRadius     = 2,
    AgentHeight     = 5,
    AgentCanJump    = false,
    AgentCanClimb   = false,
    WaypointSpacing = 4,
}

local function computePath(startPos, endPos)
    if not startPos or not endPos then return nil end
    local path = PathfindingService:CreatePath(DEFAULT_AGENT_PARAMS)
    if not path then return nil end
    local ok = pcall(function() path:ComputeAsync(startPos, endPos) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then return nil end
    local waypoints = path:GetWaypoints()
    if not waypoints or #waypoints == 0 then return nil end
    local result = table.create(#waypoints)
    for i = 2, #waypoints do
        local wp = waypoints[i]
        if wp and wp.Position then
            table.insert(result, stickToGround(wp.Position))
        end
    end
    if #result == 0 then
        table.insert(result, stickToGround(endPos))
    end
    return result
end

local function moveTo(model, targetPos, speed, opts)
    if not isModelValid(model) then return end
    if not targetPos then return end
    opts = opts or {}
    local maxTime    = opts.maxTime or 30
    local threshold  = opts.reachThreshold or DEFAULT_REACH_THRESHOLD
    local shouldStop = opts.shouldStop
    local pPart = model.PrimaryPart
    if not pPart then return end
    local waypoints = computePath(pPart.Position, targetPos)
    if not waypoints or #waypoints == 0 then return end
    local startClock = os.clock()
    for _, wp in ipairs(waypoints) do
        if not wp then continue end
        while true do
            if shouldStop and shouldStop() then return end
            if not isModelValid(model) then return end
            if os.clock() - startClock > maxTime then return end
            local pp = model.PrimaryPart
            if not pp then return end
            local toWp    = wp - pp.Position
            local flatVec = Vector3.new(toWp.X, 0, toWp.Z)
            local wpDist  = flatVec.Magnitude
            if wpDist <= threshold then break end
            local dt = RunService.Heartbeat:Wait()
            if dt <= 0 then continue end
            if not isModelValid(model) then return end
            local pp2 = model.PrimaryPart
            if not pp2 then return end
            local moveAmt = math.min(speed * dt, wpDist)
            local flatDir = flatVec.Unit
            local newXZ   = pp2.Position + flatDir * moveAmt
            local newPos  = stickToGround(newXZ)
            smoothTurn(model, newPos, flatDir, dt, DEFAULT_TURN_SPEED)
        end
    end
end

-- ─── chase — repath loop, exact NpcPathfinding chase pattern ─────────────────

local function chase(model, getTargetPos, speed, stopDistance, maxTime, opts)
    if not isModelValid(model) then return false end
    stopDistance = stopDistance or 3
    maxTime      = maxTime      or 30
    opts         = opts         or {}
    local repathInterval = opts.repathInterval            or 0.6
    local moveRepath     = opts.targetMoveRepathThreshold or 5
    local shouldStop     = opts.shouldStop
    local startClock    = os.clock()
    local lastRepath    = -math.huge
    local lastTargetPos = nil
    local waypoints     = nil
    local wpIndex       = 1
    while true do
        if shouldStop and shouldStop() then return false end
        if not isModelValid(model) then return false end
        if os.clock() - startClock > maxTime then return false end
        local targetPos = getTargetPos()
        if not targetPos then return false end
        local pPart = model.PrimaryPart
        if not pPart then return false end
        if (targetPos - pPart.Position).Magnitude <= stopDistance then return true end
        local now        = os.clock()
        local needRepath = false
        if not waypoints or wpIndex > #waypoints then
            needRepath = true
        elseif now - lastRepath >= repathInterval then
            needRepath = true
        elseif lastTargetPos and (targetPos - lastTargetPos).Magnitude >= moveRepath then
            needRepath = true
        end
        if needRepath then
            if not isModelValid(model) then return false end
            local pp2 = model.PrimaryPart
            if not pp2 then return false end
            waypoints     = computePath(pp2.Position, targetPos)
            wpIndex       = 1
            lastRepath    = now
            lastTargetPos = targetPos
            if not waypoints or #waypoints == 0 then
                task.wait(0.1)
                continue
            end
        end
        if not waypoints or wpIndex > #waypoints then continue end
        local wp = waypoints[wpIndex]
        if not wp then wpIndex += 1 continue end
        if not isModelValid(model) then return false end
        local pp3 = model.PrimaryPart
        if not pp3 then return false end
        local toWp    = wp - pp3.Position
        local flatVec = Vector3.new(toWp.X, 0, toWp.Z)
        local wpDist  = flatVec.Magnitude
        if wpDist <= DEFAULT_REACH_THRESHOLD then
            wpIndex += 1
            continue
        end
        local dt = RunService.Heartbeat:Wait()
        if dt <= 0 then continue end
        if not isModelValid(model) then return false end
        local pp4 = model.PrimaryPart
        if not pp4 then return false end
        local moveAmt = math.min(speed * dt, wpDist)
        local flatDir = flatVec.Unit
        local newXZ   = pp4.Position + flatDir * moveAmt
        local newPos  = stickToGround(newXZ)
        smoothTurn(model, newPos, flatDir, dt, DEFAULT_TURN_SPEED)
    end
end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local instruments = { "Violin", "Maracas", "Trumpet" }

local function getRandomWanderPos(wanderPart)
    local s = wanderPart.Size
    local offset = Vector3.new(
        (math.random() - 0.5) * s.X,
        0,
        (math.random() - 0.5) * s.Z
    )
    return stickToGround(wanderPart.Position + offset)
end

local function animalHasSombrero(animal)
    local json = animal:GetAttribute("Traits")
    if not json then return false end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return false end
    for _, t in ipairs(decoded) do
        if t == "Sombrero" then return true end
    end
    return false
end

local function giveSombrero(animal)
    local json   = animal:GetAttribute("Traits")
    local traits = {}
    if json then
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
        if ok and type(decoded) == "table" then traits = decoded end
    end
    for _, t in ipairs(traits) do
        if t == "Sombrero" then return end
    end
    table.insert(traits, "Sombrero")
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

-- ─── Roach model ──────────────────────────────────────────────────────────────

local function createRoach(position)
    local model = Instance.new("Model")
    model.Name  = "Roach"

    local root = Instance.new("Part")
    root.Name         = "HumanoidRootPart"
    root.Size         = Vector3.new(2, 2, 2)
    root.Transparency = 1
    root.CanCollide   = false
    root.Anchored     = true
    root.CFrame       = CFrame.new(position)
    root.Parent       = model

    model.PrimaryPart = root
    CollectionService:AddTag(model, "Roach")

    model:SetAttribute("Instrument",  instruments[math.random(1, #instruments)])
    model:SetAttribute("Dance",       true)
    model:SetAttribute("IsRunning",   false)
    model:SetAttribute("Shuffle",     false)
    return model
end

-- ─── Spawn ────────────────────────────────────────────────────────────────────

local function spawnRoaches()
    for _, wanderPart in ipairs(WANDER_FOLDER:GetChildren()) do
        if not wanderPart:IsA("BasePart") then continue end
        local count = math.random(1, 3)
        for _ = 1, count do
            local pos   = getRandomWanderPos(wanderPart)
            local model = createRoach(pos)
            eventTrove:Add(model)
            model.Parent = workspace

            local instrument = instruments[math.random(1, #instruments)]
            model:SetAttribute("Instrument", instrument)

            table.insert(spawnedRoaches, {
                Model          = model,
                WanderPart     = wanderPart,
                LastWander     = 0,
                BaseInstrument = instrument,
                IsAttacking    = false,
            })
        end
    end
end

-- ─── Attack ───────────────────────────────────────────────────────────────────

local function followAndAttack(roachData, targetAnimal)
    local roach = roachData.Model
    if not roach or not roach.Parent then return end
    if roachData.IsAttacking then return end

    roachData.IsAttacking = true
    local attackId = tostring(math.random(1e9))
    activeAttacks[attackId] = true

    local originalInstrument = roachData.BaseInstrument
    if not originalInstrument or originalInstrument == "Sombrero" then
        originalInstrument = instruments[math.random(1, #instruments)]
        roachData.BaseInstrument = originalInstrument
    end

    roach:SetAttribute("Instrument", "Sombrero")
    roach:SetAttribute("IsRunning",  true)
    roach:SetAttribute("Dance",      true)

    local attackTrove = eventTrove:Extend()

    attackTrove:Add(task.spawn(function()
        local reached = chase(
            roach,
            function()
                if not targetAnimal or not targetAnimal.Parent or not targetAnimal.PrimaryPart then
                    return nil
                end
                return targetAnimal.PrimaryPart.Position
            end,
            ROACH_SPEED,
            3,
            CHASE_MAX_TIME,
            {
                shouldStop = function()
                    return not activeAttacks[attackId] or not isActive or isPaused
                end,
            }
        )

        roach:SetAttribute("IsRunning", false)

        if reached and targetAnimal and targetAnimal.Parent then
            roach:SetAttribute("Dance",           true)
            roach:SetAttribute("Instrument",      "Sombrero")
            roach:SetAttribute("AttackAnimation", (roach:GetAttribute("AttackAnimation") or 0) + 1)

            local elapsed  = 0
            local lastTime = os.clock()

            while elapsed < PUT_HAT_DURATION
                and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart
                and not isPaused
            do
                local now = os.clock()
                local dt  = now - lastTime
                lastTime  = now
                elapsed  += dt

                local tgtPos = targetAnimal.PrimaryPart.Position
                local myPos  = roach.PrimaryPart.Position
                local diff   = tgtPos - myPos
                local dist   = diff.Magnitude

                if dist > 0.5 then
                    local dir    = diff.Unit
                    local flat   = Vector3.new(dir.X, 0, dir.Z).Unit
                    local newPos = stickToGround(myPos + dir * math.min(ROACH_SPEED * dt, dist))
                    roach:PivotTo(CFrame.new(newPos, newPos + flat))
                end
                task.wait()
            end

            giveSombrero(targetAnimal)
            roach:SetAttribute("Instrument", originalInstrument)

            local player = Players:GetPlayerFromCharacter(targetAnimal)
            if player and sombreroTemplate and not targetAnimal:FindFirstChild("SombreroHat") then
                local hat  = sombreroTemplate:Clone()
                hat.Name   = "SombreroHat"
                hat.Parent = targetAnimal
            end

            task.wait(1)
        end

        roach:SetAttribute("Instrument", originalInstrument)
        activeAttacks[attackId] = nil
        roachData.IsAttacking   = false
        attackTrove:Destroy()
    end))
end

-- ─── Sombrero cleanup ─────────────────────────────────────────────────────────

local function startSombreroCleanup()
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(3)
            for _, rd in ipairs(spawnedRoaches) do
                local roach = rd.Model
                if not roach or not roach.Parent then continue end
                if roach:GetAttribute("Instrument") == "Sombrero"
                    and not roach:GetAttribute("IsRunning")
                then
                    local restore = rd.BaseInstrument
                    if not restore or restore == "Sombrero" then
                        restore = instruments[math.random(1, #instruments)]
                        rd.BaseInstrument = restore
                    end
                    roach:SetAttribute("Instrument", restore)
                end
            end
        end
    end))
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    spawnRoaches()
    startSombreroCleanup()

    local eventData = EventController:GetActiveEventData(EVENT_NAME)

    if eventData then
        eventTrove:Add(task.delay(
            math.max(eventData.startedAt + 28.5 - workspace:GetServerTimeNow(), 0),
            function()
                if not isActive then return end
                isPaused = true
                for _, rd in ipairs(spawnedRoaches) do
                    local r = rd.Model
                    if r and r.Parent then
                        r:SetAttribute("IsRunning", false)
                        r:SetAttribute("Dance",     false)
                        r:SetAttribute("Shuffle",   true)
                    end
                end

                eventTrove:Add(task.delay(
                    math.max(eventData.startedAt + 34.5 - workspace:GetServerTimeNow(), 0),
                    function()
                        if not isActive then return end
                        isPaused      = false
                        activeAttacks = {}
                        for _, rd in ipairs(spawnedRoaches) do
                            local r = rd.Model
                            if r and r.Parent then
                                rd.IsAttacking = false
                                r:SetAttribute("Shuffle",   false)
                                r:SetAttribute("IsRunning", false)
                                r:SetAttribute("Dance",     true)
                                if r:GetAttribute("Instrument") == "Sombrero" then
                                    r:SetAttribute("Instrument", rd.BaseInstrument or "Violin")
                                end
                            end
                        end
                    end
                ))
            end
        ))
    end

    -- wander tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(1)
            local now = os.clock()
            for _, rd in ipairs(spawnedRoaches) do
                local roach = rd.Model
                if not roach or not roach.Parent then continue end
                if rd.IsAttacking or isPaused then continue end
                if roach:GetAttribute("IsRunning") then continue end
                if (now - rd.LastWander) < math.random(5, 10) then continue end

                rd.LastWander = now
                task.spawn(function()
                    roach:SetAttribute("IsRunning", true)
                    moveTo(roach, getRandomWanderPos(rd.WanderPart), ROACH_SPEED, {
                        maxTime    = 15,
                        shouldStop = function()
                            return not isActive or not roach.Parent or rd.IsAttacking or isPaused
                        end,
                    })
                    if roach.Parent then
                        roach:SetAttribute("IsRunning", false)
                    end
                end)
            end
        end
    end))

    -- animal attack tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(ATTACK_COOLDOWN_MIN, ATTACK_COOLDOWN_MAX))
            if not isActive or #spawnedRoaches == 0 or isPaused then
                if isPaused then continue end
                break
            end

            local now = workspace:GetServerTimeNow()
            for name, t in pairs(recentlyTargeted) do
                if (now - t) > RECENT_ANIMAL_COOLDOWN then recentlyTargeted[name] = nil end
            end

            local candidates = {}
            for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                if animal.PrimaryPart
                    and not recentlyTargeted[animal.Name]
                    and not animalHasSombrero(animal)
                then
                    table.insert(candidates, animal)
                end
            end
            if #candidates == 0 then continue end

            local target    = candidates[math.random(1, #candidates)]
            local freeRoach = nil
            for _, rd in ipairs(spawnedRoaches) do
                if not rd.IsAttacking and rd.Model and rd.Model.Parent then
                    freeRoach = rd
                    break
                end
            end
            if not freeRoach then continue end

            recentlyTargeted[target.Name] = now
            followAndAttack(freeRoach, target)
        end
    end))

    -- player attack tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(PLAYER_ATTACK_COOLDOWN_MIN, PLAYER_ATTACK_COOLDOWN_MAX))
            if not isActive or #spawnedRoaches == 0 or isPaused then
                if isPaused then continue end
                break
            end

            local now = workspace:GetServerTimeNow()
            for name, t in pairs(recentlyTargetedPlayers) do
                if (now - t) > RECENT_PLAYER_COOLDOWN then recentlyTargetedPlayers[name] = nil end
            end

            local candidates = {}
            for _, player in ipairs(Players:GetPlayers()) do
                local char = player.Character
                if char and char:FindFirstChild("HumanoidRootPart")
                    and not player:GetAttribute("HasSombreroHat")
                    and not recentlyTargetedPlayers[player.Name]
                then
                    table.insert(candidates, player)
                end
            end
            if #candidates == 0 then continue end

            local selected  = candidates[math.random(1, #candidates)]
            local freeRoach = nil
            for _, rd in ipairs(spawnedRoaches) do
                if not rd.IsAttacking and rd.Model and rd.Model.Parent then
                    freeRoach = rd
                    break
                end
            end
            if not freeRoach then continue end

            recentlyTargetedPlayers[selected.Name] = now
            selected:SetAttribute("HasSombreroHat", true)
            followAndAttack(freeRoach, selected.Character)
        end
    end))

    -- shutdown
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end

    isActive                = false
    isPaused                = false
    activeAttacks           = {}
    spawnedRoaches          = {}
    recentlyTargeted        = {}
    recentlyTargetedPlayers = {}
    eventTrove:Destroy()
end

task.spawn(main)
