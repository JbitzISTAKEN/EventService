if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local CollectionService  = game:GetService("CollectionService")
local HttpService        = game:GetService("HttpService")
local RunService         = game:GetService("RunService")
local Players            = game:GetService("Players")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local NpcPathfinding = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"
))()

local EVENT_NAME       = "Mexico"
local ROACH_SPEED      = 30
local ROACH_Y_OFFSET   = 5
local PUT_HAT_DURATION = 0.5

local ATTACK_COOLDOWN_MIN        = 5
local ATTACK_COOLDOWN_MAX        = 10
local PLAYER_ATTACK_COOLDOWN_MIN = 15
local PLAYER_ATTACK_COOLDOWN_MAX = 25
local CHASE_MAX_TIME             = 30
local CHASE_REACH_DIST           = 6
local RECENT_ANIMAL_COOLDOWN     = 15
local RECENT_PLAYER_COOLDOWN     = 30

local WANDER_FOLDER = workspace:WaitForChild("Events"):WaitForChild("Wander")
local instruments   = { "Violin", "Maracas", "Trumpet" }

local EVENT_SCRIPT = ReplicatedStorage
    :WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("Mexico")

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

local eventTrove              = Trove.new()
local spawnedRoaches          = {}
local activeAttacks           = {}
local recentlyTargeted        = {}
local recentlyTargetedPlayers = {}
local isActive                = true
local isPaused                = false

local function stickToGround(position)
    return NpcPathfinding.stickToGround(position, ROACH_Y_OFFSET)
end

local function getRandomWanderPos(wanderPart)
    local s  = wanderPart.Size
    local cf = wanderPart.CFrame
    return NpcPathfinding.stickToGround(
        (cf * CFrame.new(
            math.random(-s.X / 2, s.X / 2),
            0,
            math.random(-s.Z / 2, s.Z / 2)
        )).Position,
        ROACH_Y_OFFSET
    )
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
    local traits = {}
    local json   = animal:GetAttribute("Traits")
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

local function doBurst(targetModel)
    if not targetModel or not targetModel.PrimaryPart then return end
    ClientEventUtils.playBurst(
        EVENT_SCRIPT.Burst,
        targetModel.PrimaryPart.Position,
        { ReplicatedStorage.Sounds.Events.Mexico.Hit }
    )
end

local function weldSombreroToHead(character)
    local head = character:FindFirstChild("Head")
    if not head then return end
    if character:FindFirstChild("SombreroHat") then return end

    task.spawn(function()
        local ok, objects = pcall(game.GetObjects, game, "rbxassetid://99466679730663")
        if not ok or not objects or not objects[1] then
            warn("[Mexico] GetObjects failed: " .. tostring(objects))
            return
        end

        local a = objects[1]
        local h = a.Handle
        h.CanCollide = false
        h.Massless   = true
        a.Name       = "SombreroHat"
        a.Parent     = character

        local w  = Instance.new("Weld", h)
        w.Part0  = head
        w.Part1  = h
        w.C0     = head.HatAttachment.CFrame
        w.C1     = h.HatAttachment.CFrame
    end)
end

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

    local instrument = instruments[math.random(1, #instruments)]
    model:SetAttribute("Instrument",  instrument)
    model:SetAttribute("Dance",       true)
    model:SetAttribute("IsRunning",   false)
    model:SetAttribute("Shuffle",     false)

    return model, instrument
end

local function spawnRoaches()
    for _, wanderPart in ipairs(WANDER_FOLDER:GetChildren()) do
        if not wanderPart:IsA("BasePart") then continue end
        local count = math.random(1, 3)
        for _ = 1, count do
            local pos          = getRandomWanderPos(wanderPart)
            local model, instr = createRoach(pos)
            eventTrove:Add(model)
            model.Parent = workspace
            table.insert(spawnedRoaches, {
                Model          = model,
                WanderPart     = wanderPart,
                LastWander     = 0,
                BaseInstrument = instr,
                IsAttacking    = false,
            })
        end
    end
end

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

local function followAndAttack(roachData, targetModel, isPlayer)
    local roach = roachData.Model
    if not roach or not roach.Parent then return end
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
    roach:SetAttribute("Dance",      true)
    roach:SetAttribute("IsRunning",  true)

    local attackTrove = eventTrove:Extend()

    attackTrove:Add(task.spawn(function()

        local reached = NpcPathfinding.chase(
            roach,
            function()
                if not targetModel or not targetModel.Parent or not targetModel.PrimaryPart then
                    return nil
                end
                return targetModel.PrimaryPart.Position
            end,
            ROACH_SPEED,
            CHASE_REACH_DIST,
            CHASE_MAX_TIME,
            {
                yOffset    = ROACH_Y_OFFSET,
                shouldStop = function()
                    return not activeAttacks[attackId] or not isActive or isPaused
                end,
            }
        )

        roach:SetAttribute("IsRunning", false)

        if reached and targetModel and targetModel.Parent and targetModel.PrimaryPart then
            roach:SetAttribute("Dance",           true)
            roach:SetAttribute("Instrument",      "Sombrero")
            roach:SetAttribute("AttackAnimation", (roach:GetAttribute("AttackAnimation") or 0) + 1)

            -- close remaining gap
            local closeStart = os.clock()
            while targetModel and targetModel.Parent and targetModel.PrimaryPart
                and not isPaused
                and os.clock() - closeStart < PUT_HAT_DURATION + 1
            do
                if not roach.Parent or not roach.PrimaryPart then break end
                local tgtPos = targetModel.PrimaryPart.Position
                local myPos  = roach.PrimaryPart.Position
                local diff   = tgtPos - myPos
                local dist   = diff.Magnitude
                if dist <= 1.5 then break end
                local dt  = task.wait()
                local dir = diff.Unit
                local flat = Vector3.new(dir.X, 0, dir.Z)
                if flat.Magnitude > 1e-4 then
                    flat = flat.Unit
                    local newPos = stickToGround(myPos + dir * math.min(ROACH_SPEED * dt, dist))
                    roach:PivotTo(CFrame.new(newPos, newPos + flat))
                end
            end

            -- hat placement micro-loop
            local elapsed  = 0
            local lastTime = os.clock()
            while elapsed < PUT_HAT_DURATION
                and targetModel and targetModel.Parent and targetModel.PrimaryPart
                and not isPaused
            do
                local now = os.clock()
                local dt  = now - lastTime
                lastTime  = now
                elapsed  += dt
                local tgtPos = targetModel.PrimaryPart.Position
                local myPos  = roach.PrimaryPart.Position
                local diff   = tgtPos - myPos
                local dist   = diff.Magnitude
                if dist > 0.3 then
                    local dir  = diff.Unit
                    local flat = Vector3.new(dir.X, 0, dir.Z)
                    if flat.Magnitude > 1e-4 then
                        flat = flat.Unit
                        local newPos = stickToGround(myPos + dir * math.min(ROACH_SPEED * dt, dist))
                        roach:PivotTo(CFrame.new(newPos, newPos + flat))
                    end
                end
                task.wait()
            end

            if isPlayer then
                -- server: HasSombreroHat already set in tick before chase,
                -- check it here before applying hat, matching server guard
                local player = Players:GetPlayerFromCharacter(targetModel)
                if player and player:GetAttribute("HasSombreroHat") == true then
                    weldSombreroToHead(targetModel)
                    doBurst(targetModel)
                end
            else
                -- server order: giveSombrero → Burst:FireAllClients
                giveSombrero(targetModel)
                doBurst(targetModel)
            end

            roach:SetAttribute("Instrument", originalInstrument)
            roach:SetAttribute("Dance",      true)
            roach:SetAttribute("IsRunning",  false)

            task.wait(1)
        else
            roach:SetAttribute("Instrument", originalInstrument)
            roach:SetAttribute("Dance",      true)
            roach:SetAttribute("IsRunning",  false)
        end

        activeAttacks[attackId] = nil
        roachData.IsAttacking   = false
        attackTrove:Destroy()
    end))
end

local function main()
    spawnRoaches()
    startSombreroCleanup()

    eventTrove:Add(task.delay(
        math.max(startedAt + 28.5 - workspace:GetServerTimeNow(), 0),
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
                math.max(startedAt + 34.5 - workspace:GetServerTimeNow(), 0),
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

    -- animal attack tick — single random pick, retry up to #spawnedRoaches
    -- times matching server behavior of random grab + IsAttacking guard
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(ATTACK_COOLDOWN_MIN, ATTACK_COOLDOWN_MAX))
            if not isActive or #spawnedRoaches == 0 or isPaused then
                if isPaused then continue end
                break
            end

            local now = workspace:GetServerTimeNow()
            for inst, t in pairs(recentlyTargeted) do
                if (now - t) > RECENT_ANIMAL_COOLDOWN then recentlyTargeted[inst] = nil end
            end

            local candidates = {}
            for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                if animal.PrimaryPart
                    and not recentlyTargeted[animal]
                    and not animalHasSombrero(animal)
                then
                    table.insert(candidates, animal)
                end
            end
            if #candidates == 0 then continue end

            -- mirror server: random pick, retry until free roach found
            local freeRoach = nil
            local attempts  = #spawnedRoaches
            while attempts > 0 do
                local rd = spawnedRoaches[math.random(1, #spawnedRoaches)]
                if not rd.IsAttacking and rd.Model and rd.Model.Parent then
                    freeRoach = rd
                    break
                end
                attempts -= 1
            end
            if not freeRoach then continue end

            local target = candidates[math.random(1, #candidates)]
            recentlyTargeted[target] = now
            followAndAttack(freeRoach, target, false)
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
            for inst, t in pairs(recentlyTargetedPlayers) do
                if (now - t) > RECENT_PLAYER_COOLDOWN then recentlyTargetedPlayers[inst] = nil end
            end

            local candidates = {}
            for _, player in ipairs(Players:GetPlayers()) do
                local char = player.Character
                if char
                    and char:FindFirstChild("HumanoidRootPart")
                    and not char:FindFirstChild("SombreroHat")
                    and not recentlyTargetedPlayers[player]
                then
                    table.insert(candidates, player)
                end
            end
            if #candidates == 0 then continue end

            local freeRoach = nil
            local attempts  = #spawnedRoaches
            while attempts > 0 do
                local rd = spawnedRoaches[math.random(1, #spawnedRoaches)]
                if not rd.IsAttacking and rd.Model and rd.Model.Parent then
                    freeRoach = rd
                    break
                end
                attempts -= 1
            end
            if not freeRoach then continue end

            local selected = candidates[math.random(1, #candidates)]
            recentlyTargetedPlayers[selected] = now
            -- set attribute before chase, matching server tick order
            selected:SetAttribute("HasSombreroHat", true)
            followAndAttack(freeRoach, selected.Character, true)
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end

    isActive                = false
    isPaused                = false
    activeAttacks           = {}
    spawnedRoaches          = {}
    recentlyTargeted        = {}
    recentlyTargetedPlayers = {}
    eventTrove:Destroy()
end

task.spawn(main)
