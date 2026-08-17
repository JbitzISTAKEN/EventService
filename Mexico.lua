if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)

-- ─── Pathfinding (loadstring, no server module required) ──────────────────────

local NpcPathfinding = loadstring(game:HttpGet("https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"))()

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

-- ─── Ground snap (delegates to NpcPathfinding) ────────────────────────────────

local function stickToGround(position)
    return NpcPathfinding.stickToGround(position, ROACH_Y_OFFSET)
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
        local reached = NpcPathfinding.chase(
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
                yOffset    = ROACH_Y_OFFSET,
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

    -- wander tick — NpcPathfinding.moveTo handles waypoints
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
                    NpcPathfinding.moveTo(roach, getRandomWanderPos(rd.WanderPart), ROACH_SPEED, {
                        maxTime    = 15,
                        yOffset    = ROACH_Y_OFFSET,
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

    isActive              = false
    isPaused              = false
    activeAttacks         = {}
    spawnedRoaches        = {}
    recentlyTargeted      = {}
    recentlyTargetedPlayers = {}
    eventTrove:Destroy()
end

task.spawn(main)
