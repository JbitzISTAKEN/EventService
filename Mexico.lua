
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local CollectionService  = game:GetService("CollectionService")
local HttpService        = game:GetService("HttpService")
local RunService         = game:GetService("RunService")
local Players            = game:GetService("Players")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local NpcPathfinding = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"
))()

local EVENT_NAME       = "Mexico"
local ROACH_SPEED      = 20
local ROACH_Y_OFFSET   = 5
local PUT_HAT_DURATION = 0.5
local CHASE_STOP_DIST  = 10
local CHASE_MAX_TIME   = 30

local ATTACK_COOLDOWN_MIN        = 5
local ATTACK_COOLDOWN_MAX        = 10
local PLAYER_ATTACK_COOLDOWN_MIN = 15
local PLAYER_ATTACK_COOLDOWN_MAX = 25
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
    local size = wanderPart.Size
    local cf   = wanderPart.CFrame
    return NpcPathfinding.stickToGround(
        (cf * CFrame.new(
            math.random(-size.X / 2, size.X / 2),
            0,
            math.random(-size.Z / 2, size.Z / 2)
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

local function doBurst(val2)
    ClientEventUtils.playBurst(EVENT_SCRIPT.Burst, val2, {
        ReplicatedStorage.Sounds.Events.Mexico.Hit
    })
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
    model:SetAttribute("Instrument", instrument)
    model:SetAttribute("Dance",      true)
    model:SetAttribute("IsRunning",  false)
    model:SetAttribute("Shuffle",    false)

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

local function followAndAttackAnimal(roachData, targetAnimal)
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
        roach:SetAttribute("Instrument", "Sombrero")

        local reachedTarget = NpcPathfinding.chase(
            roach,
            function()
                if targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart then
                    return targetAnimal.PrimaryPart.Position
                end
                return nil
            end,
            ROACH_SPEED,
            CHASE_STOP_DIST,
            CHASE_MAX_TIME,
            {
                yOffset    = ROACH_Y_OFFSET,
                shouldStop = function()
                    return (not activeAttacks[attackId]) or (not isActive) or isPaused
                end,
            }
        )

        roach:SetAttribute("Instrument", "Sombrero")
        roach:SetAttribute("IsRunning",  false)

        if reachedTarget and targetAnimal and targetAnimal.Parent then
            roach:SetAttribute("Dance",           true)
            roach:SetAttribute("Instrument",      "Sombrero")
            roach:SetAttribute("AttackAnimation", (roach:GetAttribute("AttackAnimation") or 0) + 1)

            local elapsed  = 0
            local lastTime = os.clock()
            while elapsed < PUT_HAT_DURATION
                and targetAnimal
                and targetAnimal.Parent
                and targetAnimal.PrimaryPart
                and not isPaused
            do
                local now = os.clock()
                local dt  = now - lastTime
                lastTime  = now
                elapsed  += dt

                local targetPos = targetAnimal.PrimaryPart.Position
                local roachPos  = roach.PrimaryPart.Position
                local diff      = targetPos - roachPos
                local distance  = diff.Magnitude

                if distance > 0.5 then
                    local direction     = diff.Unit
                    local flatDirection = Vector3.new(direction.X, 0, direction.Z).Unit
                    local moveAmount    = math.min(ROACH_SPEED * dt, distance)
                    local newPos        = stickToGround(roachPos + direction * moveAmount)
                    roach:PivotTo(CFrame.new(newPos, newPos + flatDirection))
                end

                task.wait()
            end

            roach:SetAttribute("Instrument", originalInstrument)

            -- 1:1 server: animals get Name string, players get the character model
            -- playBurst on client side needs position for both
            doBurst(targetAnimal.Name)

            local player = Players:GetPlayerFromCharacter(targetAnimal)
            if player then
                if player:GetAttribute("HasSombreroHat") == true then
                    if not targetAnimal:FindFirstChild("SombreroHat") then
                        task.spawn(function()
                            local a = game:GetObjects("rbxassetid://99466679730663")[1]
                            local h = a.Handle
                            h.CanCollide = false
                            h.Massless   = true
                            a.Name       = "SombreroHat"
                            a.Parent     = targetAnimal

                            local w  = Instance.new("Weld", h)
                            w.Part0  = targetAnimal.Head
                            w.Part1  = h
                            w.C0     = targetAnimal.Head.HatAttachment.CFrame
                            w.C1     = h.HatAttachment.CFrame

                            -- burst fires after hat is placed, passes position 1:1 to how
                            -- server fires Burst:FireAllClients(targetAnimal) for players
                            if targetAnimal.PrimaryPart then
                                doBurst(targetAnimal.PrimaryPart.Position)
                            end
                        end)
                    end
                end
            else
                local currentTraitsJson = targetAnimal:GetAttribute("Traits")
                local currentTraits     = {}
                if currentTraitsJson then
                    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, currentTraitsJson)
                    if ok and type(decoded) == "table" then
                        currentTraits = decoded
                    end
                end
                local hasSombrero = false
                for _, trait in ipairs(currentTraits) do
                    if trait == "Sombrero" then hasSombrero = true break end
                end
                if not hasSombrero then
                    table.insert(currentTraits, "Sombrero")
                    targetAnimal:SetAttribute("Traits", HttpService:JSONEncode(currentTraits))
                end
                doBurst(targetAnimal.Name)
            end

            task.wait(1)
        end

        roach:SetAttribute("Instrument", originalInstrument)
        activeAttacks[attackId] = nil
        roachData.IsAttacking   = false
        attackTrove:Destroy()
    end))
end

local function moveRoachToTarget(roachData, targetPosition)
    local roach = roachData.Model
    if not roach or not roach.Parent or not roach.PrimaryPart then return end

    roach:SetAttribute("IsRunning", true)
    roach:SetAttribute("Dance",     true)

    local speed    = 30
    local distance = (targetPosition - roach.PrimaryPart.Position).Magnitude

    NpcPathfinding.moveTo(roach, targetPosition, speed, {
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
                            local instr = r:GetAttribute("Instrument")
                            if instr == "Sombrero" then
                                r:SetAttribute("Instrument", rd.BaseInstrument or "Violin")
                            end
                            r:SetAttribute("IsRunning", false)
                            r:SetAttribute("Dance",     true)
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
                    moveRoachToTarget(rd, getRandomWanderPos(rd.WanderPart))
                end)
            end
        end
    end))

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
                    and not recentlyTargeted[animal.Name]
                    and not animalHasSombrero(animal)
                then
                    table.insert(candidates, animal)
                end
            end
            if #candidates == 0 then continue end

            local selected  = candidates[math.random(1, #candidates)]
            local roachData = spawnedRoaches[math.random(1, #spawnedRoaches)]

            if roachData.Model and roachData.Model.Parent then
                followAndAttackAnimal(roachData, selected)
                recentlyTargeted[selected.Name] = now
            end
        end
    end))

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
                local character = player.Character
                if character
                    and character:FindFirstChild("HumanoidRootPart")
                    and not recentlyTargetedPlayers[player.Name]
                    and player:GetAttribute("HasSombreroHat") ~= true
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
