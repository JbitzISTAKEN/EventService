if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

local EVENT_NAME   = "Raining Burgers"
local EVENT_SCRIPT = ReplicatedStorage:WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("Raining Burgers")

-- ─── Constants (1:1 server) ───────────────────────────────────────────────────

local BLOCKING_TRAIT  = "Burger"
local FALL_SPEED      = 145
local DROP_HEIGHT     = 120
local EXPIRE_TIME     = 12
local TRAIT_DELAY     = 1.0
local COOLDOWN_WINDOW = 20
local LOOP_MIN        = 700
local LOOP_MAX        = 1200

local MULTI_STRIKE_CHANCES = {
    { strikes = 3, chance = 0.15 },
    { strikes = 2, chance = 0.35 },
    { strikes = 1, chance = 1.00 },
}

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local struckVFX = EVENT_SCRIPT:WaitForChild("StruckVFX")
local burgerTemplate = EVENT_SCRIPT:WaitForChild("Burger")

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local recentlyTargeted = {}
local isActive         = true
local activeDrops      = {}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getTraits(animal: Model): ({string}, {[string]: boolean})
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasBlockingTrait(animal: Model): boolean
    local _, set = getTraits(animal)
    return set[BLOCKING_TRAIT] == true
end

local function getStrikeCount(): number
    local roll = math.random()
    for _, entry in ipairs(MULTI_STRIKE_CHANCES) do
        if roll <= entry.chance then
            return entry.strikes
        end
    end
    return 1
end

-- ─── Strike burger (1:1 controller OnClientEvent) ────────────────────────────

local function strikeAnimal(animalName: string, animal: Model)
    local topPos = ClientEventUtils.getAnimalPosition(animalName, { top = true })
    if not topPos or topPos == Vector3.zero then return end

    local burger = burgerTemplate:Clone()
    local motor  = nil

    -- 1:1 setupBurger
    local primaryPart = burger.PrimaryPart
    if not primaryPart then
        burger:Destroy()
        return
    end
    for _, desc in burger:GetDescendants() do
        if desc:IsA("BasePart") then
            desc.Anchored = false
        end
    end
    local existing = primaryPart:FindFirstChild("__burger_transform")
    if existing and existing:IsA("Motor6D") then
        motor = existing
    else
        motor = Instance.new("Motor6D")
        motor.Name  = "__burger_transform"
        motor.Part0 = workspace.Terrain
        motor.Part1 = primaryPart
        motor.Parent = primaryPart
    end

    burger.Parent = workspace

    local dropData = {
        model    = burger,
        motor    = motor,
        x        = topPos.X,
        z        = topPos.Z,
        y        = topPos.Y + DROP_HEIGHT,
        groundY  = topPos.Y,
        rotation = CFrame.Angles(
            math.random() * math.pi * 2,
            math.random() * math.pi * 2,
            math.random() * math.pi * 2
        ),
        expires    = os.clock() + EXPIRE_TIME,
        strikeUid  = animalName,
    }
    table.insert(activeDrops, dropData)
end

-- ─── Drop simulation (1:1 PostSimulation loop) ───────────────────────────────

eventTrove:Add(RunService.PostSimulation:Connect(function(dt: number)
    local now = os.clock()
    for i = #activeDrops, 1, -1 do
        local drop = activeDrops[i]
        if not drop.model.Parent then
            table.remove(activeDrops, i)
            continue
        end

        drop.y -= dt * FALL_SPEED

        -- 1:1: track animal live position while falling
        local livePos = ClientEventUtils.getAnimalPosition(drop.strikeUid, { top = true })
        if livePos and livePos ~= Vector3.zero then
            drop.x       = livePos.X
            drop.z       = livePos.Z
            drop.groundY = livePos.Y
        end

        drop.motor.Transform = CFrame.new(drop.x, drop.y, drop.z) * drop.rotation

        local hit     = drop.y <= drop.groundY
        local expired = now >= drop.expires

        if hit or expired then
            if hit then
                ClientEventUtils.playBurst(struckVFX, drop.strikeUid, {
                    ReplicatedStorage.Sounds.Events["Raining Burgers"]["Brainrot Hit"]
                })
            end
            drop.model:Destroy()
            table.remove(activeDrops, i)
        end
    end
end))

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    local cachedAnimals = CollectionService:GetTagged("Animal")
    eventTrove:Add(CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(inst)
        table.insert(cachedAnimals, inst)
    end))
    eventTrove:Add(CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(inst)
        for i = #cachedAnimals, 1, -1 do
            if cachedAnimals[i] == inst then
                table.remove(cachedAnimals, i)
                break
            end
        end
    end))

    eventTrove:Add(task.spawn(function()
        while isActive do
            local waitTime = math.random(LOOP_MIN, LOOP_MAX) / 100
            if ReplicatedStorage:GetAttribute("3RoadsEvent") == true then
                waitTime = waitTime / 3
            end
            task.wait(waitTime)
            if not isActive then break end

            local strikeCount = getStrikeCount()
            for i = 1, strikeCount do
                local candidates = {}
                for _, animal in ipairs(cachedAnimals) do
                    if animal.PrimaryPart
                        and not recentlyTargeted[animal.Name]
                        and not hasBlockingTrait(animal)
                        and SharedEventUtils.isPointInCarpet(animal.PrimaryPart.Position)
                    then
                        table.insert(candidates, animal)
                    end
                end

                if #candidates > 0 then
                    local selected = candidates[math.random(1, #candidates)]
                    recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()
                    strikeAnimal(selected.Name, selected)

                    -- stamp trait 1:1 server delay
                    local delayTrove = eventTrove:Extend()
                    delayTrove:Add(task.delay(TRAIT_DELAY, function()
                        if not selected or not selected.Parent then
                            delayTrove:Clean()
                            return
                        end
                        local traits, set = getTraits(selected)
                        if set[BLOCKING_TRAIT] then
                            delayTrove:Clean()
                            return
                        end
                        table.insert(traits, BLOCKING_TRAIT)
                        selected:SetAttribute("Traits", HttpService:JSONEncode(traits))
                        delayTrove:Clean()
                    end))
                end

                if i < strikeCount then
                    task.wait(1)
                    if not isActive then break end
                end
            end

            local currentTime = workspace:GetServerTimeNow()
            for name, lastTime in pairs(recentlyTargeted) do
                if (currentTime - lastTime) > COOLDOWN_WINDOW then
                    recentlyTargeted[name] = nil
                end
            end
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
    table.clear(activeDrops)
end

task.spawn(main)
