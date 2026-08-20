local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage.Packages.Trove)
local Observers        = require(ReplicatedStorage.Packages.Observers)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)

local NpcPathfinding = loadstring(game:HttpGet("https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"))()

local EVENT_NAME   = "Sammyni Spyderini"
local TAG_NAME     = "SammyniSpyderini"
local EVENT_SCRIPT = ReplicatedStorage.Controllers.EventController.Events[EVENT_NAME]

local WALK_SPEED               = 20
local TOTAL_SPIDERS            = 10
local MAX_SIMULTANEOUS_ATTACKS = 2
local RECENT_TARGET_COOLDOWN   = 30
local MIN_SPAWN_DISTANCE       = 10
local MAX_SPAWN_DISTANCE       = 30
local ATTACK_DISTANCE          = 6
local CHASE_MAX_TIME           = 20
local WANDER_MAX_TIME          = 15
local ATTACK_COOLDOWN_MIN      = 12
local ATTACK_COOLDOWN_MAX      = 15
local ACTIVATION_DELAY         = 7
local GROUND_Y_OFFSET          = 0.9
local EMERGENCE_DELAY          = 0.2
local EMERGENCE_HOLD           = 1.0
local HOLE_EXIT_WAIT           = 2.0
local MIN_IDLE_THRESHOLD       = 0.5
local MAX_IDLE_THRESHOLD       = 3.0
local MIN_WANDERS              = 3
local MAX_WANDERS              = 5

local burstAsset = EVENT_SCRIPT:WaitForChild("Burst")
local WANDER_FOLDER = workspace:WaitForChild("Events"):WaitForChild("Wander")

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove        = Trove.new()
local spawnedSpiders    = {}
local recentlyTargeted  = {}
local activeAttackCount = 0
local isActive          = true

local function getWanderParts()
    local parts = {}
    for _, p in ipairs(WANDER_FOLDER:GetChildren()) do
        if p:IsA("BasePart") then table.insert(parts, p) end
    end
    return parts
end

local function getRandomWanderPart()
    local parts = getWanderParts()
    if #parts == 0 then return nil end
    return parts[math.random(1, #parts)]
end

local function randomPointInPart(part)
    local s = part.Size
    return part.Position + Vector3.new(
        (math.random() - 0.5) * s.X,
        0,
        (math.random() - 0.5) * s.Z
    )
end

local function getRandomPositionNearTarget(target)
    if not target or not target.PrimaryPart then return nil end
    local parts     = getWanderParts()
    local targetPos = target.PrimaryPart.Position

    for _ = 1, 20 do
        local wp  = parts[math.random(1, #parts)]
        local pos = NpcPathfinding.stickToGround(randomPointInPart(wp))
        local d   = (pos - targetPos).Magnitude
        if d >= MIN_SPAWN_DISTANCE and d <= MAX_SPAWN_DISTANCE then return pos end
    end

    local angle    = math.random() * math.pi * 2
    local d        = math.random(MIN_SPAWN_DISTANCE, MAX_SPAWN_DISTANCE)
    local fallback = targetPos + Vector3.new(math.cos(angle) * d, 0, math.sin(angle) * d)
    return NpcPathfinding.stickToGround(fallback)
end

local function hasSpiderTrait(animal)
    return animal:GetAttribute("HasSpiderTrait") == true
end

local function targetGone(animal)
    if not animal or not animal.Parent or not animal.PrimaryPart then return true end
    return hasSpiderTrait(animal)
end

local function removeFromList(spider)
    local idx = table.find(spawnedSpiders, spider)
    if idx then
        spawnedSpiders[idx] = spawnedSpiders[#spawnedSpiders]
        spawnedSpiders[#spawnedSpiders] = nil
    end
end

local function createSpider(position)
    local model = Instance.new("Model")
    model.Name  = "SammyniSpyderini"

    local root = Instance.new("Part")
    root.Name         = "HumanoidRootPart"
    root.Size         = Vector3.new(2, 2, 2)
    root.Transparency = 1
    root.Anchored     = true
    root.CanCollide   = false
    root.CanQuery     = false
    root.CanTouch     = false
    root.CFrame       = CFrame.new(position)
    root.Parent       = model

    model.PrimaryPart = root
    model:SetAttribute("IsRunning",       false)
    model:SetAttribute("Ground",          false)
    model:SetAttribute("InitialGround",   true)
    model:SetAttribute("AttackAnimation", false)

    -- parent first, tag second — observer fires after visual is welded and ready
    model.Parent = workspace
    CollectionService:AddTag(model, TAG_NAME)
    return model
end

local spawnAndEmergeSpider
local retireSpider

local function startBehavior(spider, stateName, behaviorFn)
    spider.BehaviorTrove:Clean()
    if spider.Model and spider.Model.Parent then
        spider.Model:SetAttribute("IsRunning", false)
    end
    spider.State = stateName
    spider.BehaviorTrove:Add(task.spawn(function()
        local ok, err = pcall(behaviorFn, spider)
        if not ok then
            warn(("[SammyniSpyderini] '%s' errored: %s"):format(stateName, tostring(err)))
        end
        if spider.State == stateName then
            spider.State = "Idle"
            if spider.Model and spider.Model.Parent then
                spider.Model:SetAttribute("IsRunning", false)
            end
        end
    end))
end

retireSpider = function(spider)
    if spider.State == "Retiring" or spider.State == "Dead" then return end
    spider.State = "Retiring"
    spider.BehaviorTrove:Clean()

    local model = spider.Model
    if model and model.Parent then
        model:SetAttribute("IsRunning", false)
        model:SetAttribute("Ground",    true)
    end

    spider.Trove:Add(task.delay(HOLE_EXIT_WAIT, function()
        local wasAttack     = spider.IsAttack
        local wasWanderPart = spider.WanderPart

        removeFromList(spider)
        spider.State = "Dead"
        eventTrove:Remove(spider.Trove)

        if isActive and not wasAttack then
            local wp = (wasWanderPart and wasWanderPart.Parent) and wasWanderPart or getRandomWanderPart()
            if wp then spawnAndEmergeSpider(wp) end
        end
    end))
end

local function doWander(spider)
    local wp = spider.WanderPart
    if not wp or not wp.Parent then
        wp = getRandomWanderPart()
        spider.WanderPart = wp
    end
    if not wp then return end

    local targetPos = NpcPathfinding.stickToGround(randomPointInPart(wp))
    spider.Model:SetAttribute("IsRunning", true)

    NpcPathfinding.moveTo(spider.Model, targetPos, WALK_SPEED, {
        maxTime    = WANDER_MAX_TIME,
        shouldStop = function() return not isActive end,
    })

    spider.WanderCount = spider.WanderCount + 1
    spider.LastMoved   = os.clock()
    spider.Model:SetAttribute("IsRunning", false)
end

local function doAttack(spider)
    local model  = spider.Model
    local target = spider.Target
    if not model or not target then return end

    model:SetAttribute("IsRunning", true)

    local reached = NpcPathfinding.chase(
        model,
        function()
            if targetGone(target) then return nil end
            return target.PrimaryPart.Position
        end,
        WALK_SPEED,
        ATTACK_DISTANCE,
        CHASE_MAX_TIME,
        { shouldStop = function() return not isActive end }
    )

    model:SetAttribute("IsRunning", false)

    if not reached or not isActive or targetGone(target) then
        if isActive then retireSpider(spider) end
        return
    end

    local myPos    = model.PrimaryPart.Position
    local toTarget = target.PrimaryPart.Position - myPos
    local flat     = Vector3.new(toTarget.X, 0, toTarget.Z)
    if flat.Magnitude > 0.1 then
        model:PivotTo(CFrame.lookAt(myPos, myPos + flat.Unit))
    end
    task.wait(0.1)

    model:SetAttribute("AttackAnimation", true)
    task.wait(0.5)

    if isActive and not targetGone(target) then
        ClientEventUtils.playBurst(burstAsset, target.PrimaryPart, {
            ReplicatedStorage.Sounds.Events["Sammyni Spyderini"].Hit,
        })
        local traits = {}
        local tj = target:GetAttribute("Traits")
        if tj then
            local ok, decoded = pcall(HttpService.JSONDecode, HttpService, tj)
            if ok and type(decoded) == "table" then traits = decoded end
        end
        local already = false
        for _, t in ipairs(traits) do
            if t == "Spider" then already = true break end
        end
        if not already then
            table.insert(traits, "Spider")
            target:SetAttribute("Traits", HttpService:JSONEncode(traits))
        end
        target:SetAttribute("HasSpiderTrait", true)
    end

    task.wait(0.5)
    if model.Parent then model:SetAttribute("AttackAnimation", false) end
    task.wait(0.3)
    if isActive then retireSpider(spider) end
end

spawnAndEmergeSpider = function(wanderPart)
    if not isActive or not wanderPart then return nil end

    local spawnPos    = NpcPathfinding.stickToGround(randomPointInPart(wanderPart))
    local model       = createSpider(spawnPos)
    local spiderTrove = eventTrove:Extend()
    spiderTrove:Add(model)

    local spider = {
        Model         = model,
        WanderPart    = wanderPart,
        Trove         = spiderTrove,
        BehaviorTrove = spiderTrove:Extend(),
        State         = "Emerging",
        IsAttack      = false,
        WanderCount   = 0,
        MaxWanders    = math.random(MIN_WANDERS, MAX_WANDERS),
        LastMoved     = math.huge,
        IdleThreshold = MIN_IDLE_THRESHOLD + math.random() * (MAX_IDLE_THRESHOLD - MIN_IDLE_THRESHOLD),
    }

    table.insert(spawnedSpiders, spider)

    spiderTrove:Add(task.spawn(function()
        task.wait(EMERGENCE_DELAY)
        if not isActive or not model.Parent then return end
        model:SetAttribute("InitialGround", false)

        task.wait(EMERGENCE_HOLD)
        if not isActive or not model.Parent then return end

        spider.State     = "Idle"
        spider.LastMoved = os.clock()
    end))

    return spider
end

local function spawnAttackSpider(target)
    if activeAttackCount >= MAX_SIMULTANEOUS_ATTACKS then return end
    if not isActive then return end
    if not target or not target.Parent or not target.PrimaryPart then return end

    local spawnPos = getRandomPositionNearTarget(target)
    if not spawnPos then return end

    local model       = createSpider(spawnPos)
    local spiderTrove = eventTrove:Extend()
    spiderTrove:Add(model)

    local spider = {
        Model         = model,
        WanderPart    = nil,
        Trove         = spiderTrove,
        BehaviorTrove = spiderTrove:Extend(),
        State         = "Emerging",
        IsAttack      = true,
        Target        = target,
    }

    target:SetAttribute("TargetedBy", model.Name)
    activeAttackCount += 1

    spiderTrove:Add(function()
        if target and target.Parent then
            target:SetAttribute("TargetedBy", nil)
        end
        activeAttackCount = math.max(0, activeAttackCount - 1)
    end)

    table.insert(spawnedSpiders, spider)

    spiderTrove:Add(task.spawn(function()
        task.wait(EMERGENCE_DELAY)
        if not isActive or not model.Parent then return end
        model:SetAttribute("InitialGround", false)

        task.wait(EMERGENCE_HOLD)
        if not isActive or not model.Parent then return end

        spider.State = "Idle"
        startBehavior(spider, "Attack", doAttack)
    end))

    return spider
end

local function main()
    task.wait(ACTIVATION_DELAY)
    if not isActive then return end

    for _ = 1, TOTAL_SPIDERS do
        local wp = getRandomWanderPart()
        if wp then spawnAndEmergeSpider(wp) end
    end

    -- Wander tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(0.25)
            local now = os.clock()
            for _, spider in ipairs(spawnedSpiders) do
                if spider.IsAttack then continue end
                if spider.State ~= "Idle" then continue end
                if not spider.Model or not spider.Model.Parent then continue end

                if spider.WanderCount >= spider.MaxWanders then
                    retireSpider(spider)
                    continue
                end

                if now - spider.LastMoved >= spider.IdleThreshold then
                    spider.IdleThreshold = MIN_IDLE_THRESHOLD
                        + math.random() * (MAX_IDLE_THRESHOLD - MIN_IDLE_THRESHOLD)
                    startBehavior(spider, "Wander", doWander)
                end
            end
        end
    end))

    -- Live animal cache
    local cachedAnimals = CollectionService:GetTagged("Animal")
    eventTrove:Add(CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(inst)
        table.insert(cachedAnimals, inst)
    end))
    eventTrove:Add(CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(inst)
        for i = #cachedAnimals, 1, -1 do
            if cachedAnimals[i] == inst then table.remove(cachedAnimals, i) break end
        end
    end))

    -- Attack tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(ATTACK_COOLDOWN_MIN, ATTACK_COOLDOWN_MAX))
            if not isActive then break end
            if activeAttackCount >= MAX_SIMULTANEOUS_ATTACKS then continue end

            local now = workspace:GetServerTimeNow()
            for name, last in pairs(recentlyTargeted) do
                if now - last > RECENT_TARGET_COOLDOWN then
                    recentlyTargeted[name] = nil
                end
            end

            local candidates = {}
            for _, animal in ipairs(cachedAnimals) do
                if animal.PrimaryPart
                    and not hasSpiderTrait(animal)
                    and animal:GetAttribute("TargetedBy") == nil
                    and not recentlyTargeted[animal.Name]
                then
                    table.insert(candidates, animal)
                end
            end

            if #candidates > 0 then
                local selected = candidates[math.random(1, #candidates)]
                recentlyTargeted[selected.Name] = now
                spawnAttackSpider(selected)
            end
        end
    end))

    -- Watchdog
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    eventTrove:Destroy()
    table.clear(spawnedSpiders)
    table.clear(recentlyTargeted)
    activeAttackCount = 0
end

task.spawn(main)
