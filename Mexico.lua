if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)

-- ─── NpcPathfinding via loadstring ────────────────────────────────────────────

local NpcPathfinding = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"
))()
print("heheh")
-- ─── Config ───────────────────────────────────────────────────────────────────

local EVENT_NAME       = "Mexico"
local ROACH_Y_OFFSET   = 1.5
local PUT_HAT_DURATION = 0.5
local WANDER_FOLDER    = workspace:WaitForChild("Events"):WaitForChild("Wander")

-- ─── Wait for spoofer ─────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove             = Trove.new()
local spawnedRoaches         = {}
local activeAttacks          = {}
local recentlyTargeted       = {}
local recentlyTargetedPlayers = {}
local isActive               = true
local isPaused               = false

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

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function stickToGround(position: Vector3): Vector3
    return NpcPathfinding.stickToGround(position, ROACH_Y_OFFSET)
end

local function getRandomWanderPosition(wanderPart: BasePart): Vector3
    local size = wanderPart.Size
    local cf   = wanderPart.CFrame
    local rx   = math.random(-size.X / 2, size.X / 2)
    local rz   = math.random(-size.Z / 2, size.Z / 2)
    return NpcPathfinding.stickToGround((cf * CFrame.new(rx, 0, rz)).Position, ROACH_Y_OFFSET)
end

local function animalHasSombrero(animal: Model): boolean
    local json = animal:GetAttribute("Traits")
    if not json then return false end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return false end
    for _, t in ipairs(decoded) do
        if t == "Sombrero" then return true end
    end
    return false
end

local function giveSombrero(animal: Model)
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

local function createCockroach(position: Vector3): Model
    local roach = Instance.new("Model")
    roach.Name  = "Roach"

    local root = Instance.new("Part")
    root.Name         = "HumanoidRootPart"
    root.Size         = Vector3.new(2, 2, 2)
    root.Transparency = 1
    root.CanCollide   = false
    root.Anchored     = true
    root.CFrame       = CFrame.new(position)
    root.Parent       = roach

    roach.PrimaryPart = root
    CollectionService:AddTag(roach, "Roach")
    return roach
end

-- ─── Spawn roaches ────────────────────────────────────────────────────────────

local instruments = { "Violin", "Maracas", "Trumpet" }

local function spawnRoaches()
    for _, wanderPart in ipairs(WANDER_FOLDER:GetChildren()) do
        if not wanderPart:IsA("BasePart") then continue end
        local count = math.random(1, 3)
        for _ = 1, count do
            local pos   = getRandomWanderPosition(wanderPart)
            local roach = createCockroach(pos)
            eventTrove:Add(roach)
            roach.Parent = workspace

            local instrument = instruments[math.random(1, #instruments)]
            roach:SetAttribute("Instrument",  instrument)
            roach:SetAttribute("Dance",       true)
            roach:SetAttribute("IsRunning",   false)
            roach:SetAttribute("Shuffle",     false)

            table.insert(spawnedRoaches, {
                Model          = roach,
                WanderPart     = wanderPart,
                LastWander     = 0,
                BaseInstrument = instrument,
                IsAttacking    = false,
            })
        end
    end
end

-- ─── Sombrero cleanup loop ────────────────────────────────────────────────────

local function startSombreroCleanupLoop()
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

-- ─── Attack ───────────────────────────────────────────────────────────────────

local function followAndAttackAnimal(roachData, targetAnimal: Model)
    local roach = roachData.Model
    if not roach or not roach.Parent or not roach.PrimaryPart then return end
    if roachData.IsAttacking then return end

    roachData.IsAttacking = true
    local attackId = HttpService:GenerateGUID(false)
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
        local reachedTarget = NpcPathfinding.chase(
            roach,
            function()
                if targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart then
                    return targetAnimal.PrimaryPart.Position
                end
                return nil
            end,
            20, 10, 30,
            {
                yOffset    = ROACH_Y_OFFSET,
                shouldStop = function()
                    return (not activeAttacks[attackId]) or (not isActive) or isPaused
                end,
            }
        )

        roach:SetAttribute("IsRunning", false)

        if reachedTarget and targetAnimal and targetAnimal.Parent then
            roach:SetAttribute("Dance",            true)
            roach:SetAttribute("Instrument",       "Sombrero")
            roach:SetAttribute("AttackAnimation",  (roach:GetAttribute("AttackAnimation") or 0) + 1)

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

                local targetPos = targetAnimal.PrimaryPart.Position
                local roachPos  = roach.PrimaryPart.Position
                local diff      = targetPos - roachPos
                local dist      = diff.Magnitude

                if dist > 0.5 then
                    local dir     = diff.Unit
                    local flatDir = Vector3.new(dir.X, 0, dir.Z).Unit
                    local newPos  = stickToGround(roachPos + dir * math.min(20 * dt, dist))
                    roach:PivotTo(CFrame.new(newPos, newPos + flatDir))
                end

                task.wait()
            end

            roach:SetAttribute("Instrument", originalInstrument)

            -- give sombrero trait to animal
            giveSombrero(targetAnimal)

            -- place sombrero accessory on player character if applicable
            local player = Players:GetPlayerFromCharacter(targetAnimal)
            if player and sombreroTemplate then
                if not targetAnimal:FindFirstChild("SombreroHat") then
                    local hat = sombreroTemplate:Clone()
                    hat.Name   = "SombreroHat"
                    hat.Parent = targetAnimal
                end
            end

            task.wait(1)
        end

        roach:SetAttribute("Instrument", originalInstrument)
        activeAttacks[attackId] = nil
        roachData.IsAttacking   = false
        attackTrove:Destroy()
    end))
end

-- ─── Wander ───────────────────────────────────────────────────────────────────

local function moveRoachToTarget(roachData, targetPos: Vector3)
    local roach = roachData.Model
    if not roach or not roach.Parent or not roach.PrimaryPart then return end

    roach:SetAttribute("IsRunning", true)
    roach:SetAttribute("Dance",     true)

    local speed    = 30
    local distance = (targetPos - roach.PrimaryPart.Position).Magnitude

    NpcPathfinding.moveTo(roach, targetPos, speed, {
        maxTime    = math.max(5, distance / speed + 2),
        yOffset    = ROACH_Y_OFFSET,
        shouldStop = function()
            return (not isActive) or (not roach.Parent)
        end,
    })

    if roach.Parent then
        roach:SetAttribute("IsRunning", false)
    end
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    spawnRoaches()
    startSombreroCleanupLoop()

    local eventData = EventController:GetActiveEventData(EVENT_NAME)

    -- shuffle pause at 28.5s (mirrors server timing)
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
                        isPaused     = false
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
                if (now - rd.LastWander) > math.random(5, 10)
                    and not roach:GetAttribute("IsRunning")
                    and not rd.IsAttacking
                    and not isPaused
                then
                    rd.LastWander = now
                    task.spawn(moveRoachToTarget, rd, getRandomWanderPosition(rd.WanderPart))
                end
            end
        end
    end))

    -- animal attack tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(5, 10))
            if not isActive or #spawnedRoaches == 0 or isPaused then
                if isPaused then continue end
                break
            end

            local now = workspace:GetServerTimeNow()
            for name, t in pairs(recentlyTargeted) do
                if (now - t) > 15 then recentlyTargeted[name] = nil end
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
            local roachData = spawnedRoaches[math.random(1, #spawnedRoaches)]

            if roachData.Model and roachData.Model.Parent then
                followAndAttackAnimal(roachData, target)
                recentlyTargeted[target.Name] = now
            end
        end
    end))

    -- player attack tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(15, 25))
            if not isActive or #spawnedRoaches == 0 or isPaused then
                if isPaused then continue end
                break
            end

            local now = workspace:GetServerTimeNow()
            for name, t in pairs(recentlyTargetedPlayers) do
                if (now - t) > 30 then recentlyTargetedPlayers[name] = nil end
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
            local roachData = spawnedRoaches[math.random(1, #spawnedRoaches)]

            if roachData.Model and roachData.Model.Parent then
                recentlyTargetedPlayers[selected.Name] = now
                selected:SetAttribute("HasSombreroHat", true)
                followAndAttackAnimal(roachData, selected.Character)
            end
        end
    end))

    -- shutdown
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end

    isActive  = false
    isPaused  = false
    activeAttacks = {}
    spawnedRoaches = {}
    recentlyTargeted = {}
    recentlyTargetedPlayers = {}
    eventTrove:Destroy()
end

task.spawn(main)
