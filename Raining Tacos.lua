if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)
local ServerData       = require(ReplicatedStorage.Datas.ServerData)
local MathUtils        = require(ReplicatedStorage.Utils.MathUtils)
local Spring           = require(ReplicatedStorage.Packages.Spring)

local EVENT_NAME   = "Raining Tacos"
local EVENT_SCRIPT = ReplicatedStorage:WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("Raining Tacos")

local BLOCKING_TRAIT  = "Taco"
local TRAVEL_TIME     = 2.5
local COOLDOWN_WINDOW = 20
local TRAIT_DELAY     = 2.5

local MULTI_SHOT_CHANCES = {
    { shots = 3, chance = 0.15 },
    { shots = 2, chance = 0.35 },
    { shots = 1, chance = 1.00 },
}

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove       = Trove.new()
local recentlyTargeted = {}
local isActive         = true
local rng              = Random.new()
local isTsunami        = ServerData.IsTsunamiServer()

-- ─── Cannon already in workspace, just find it ───────────────────────────────

local getPivotObj = workspace:WaitForChild("Cannon")
local ref1 = getPivotObj.Top["Meshes/tacolauncher_Cube.004"]["Meshes/tacolauncher_Cube.003"]
local ref2 = getPivotObj.Bottom.RootPart["Meshes/tacolauncher_Cube.004"]

-- ─── Springs (1:1) ───────────────────────────────────────────────────────────

local springBarrel = Spring.new(0)
springBarrel.Speed  = 6.5
springBarrel.Damper = 0.85

local springRecoil = Spring.new(0)
springRecoil.Speed  = 9
springRecoil.Damper = 0.6

eventTrove:Add(RunService.PostSimulation:Connect(function()
    debug.profilebegin("Raining Tacos Cannon Spring")
    ref1.C1 = CFrame.new(springBarrel.Position, 0, 0)
    ref2.C1 = CFrame.Angles(0, 0, -math.rad(springRecoil.Position))
    debug.profileend()
end))

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function getTraits(animal)
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasBlockingTrait(animal)
    local _, set = getTraits(animal)
    return set[BLOCKING_TRAIT] == true
end

local function getShotCount()
    local roll = rng:NextNumber()
    for _, entry in ipairs(MULTI_SHOT_CHANCES) do
        if roll <= entry.chance then return entry.shots end
    end
    return 1
end

local function getValidCandidates(cachedAnimals)
    local currentTime = workspace:GetServerTimeNow()
    for name, lastTime in pairs(recentlyTargeted) do
        if (currentTime - lastTime) > COOLDOWN_WINDOW then
            recentlyTargeted[name] = nil
        end
    end
    local candidates = {}
    for _, animal in ipairs(cachedAnimals) do
        if animal.PrimaryPart
            and not recentlyTargeted[animal.Name]
            and not hasBlockingTrait(animal)
        then
            table.insert(candidates, animal)
        end
    end
    return candidates
end

-- ─── Shoot ───────────────────────────────────────────────────────────────────

local function shootAnimal(animalName, animal)
    if not animal or not animal.PrimaryPart then return end
    if not SharedEventUtils.isPointInCarpet(animal.PrimaryPart.Position) then return end

    local now      = workspace:GetServerTimeNow()
    local shootPos = getPivotObj.ShootPart.CFrame.Position

    local taco = EVENT_SCRIPT:WaitForChild("Taco"):Clone()
    taco.Parent = workspace

    task.spawn(function()
        SoundController:PlaySound(
            ReplicatedStorage.Sounds.Events["Raining Tacos"].Shoot,
            getPivotObj:GetPivot().Position
        )
    end)

    task.spawn(function()
        springRecoil:Impulse(650)
        task.wait(0.05)
        springBarrel:Impulse(35)
    end)

    local tacoConn
    tacoConn = RunService.PreRender:Connect(function()
        debug.profilebegin("Raining Tacos")

        local animalPos = ClientEventUtils.getAnimalPosition(animalName)
        if not animalPos then
            debug.profileend()
            return
        end

        local arcHeight = isTsunami and 120 or 60
        local midPos    = shootPos + (animalPos - shootPos) * 0.5 + Vector3.new(0, arcHeight, 0)
        local t         = math.clamp(1 - (now + TRAVEL_TIME - workspace:GetServerTimeNow()) / TRAVEL_TIME, 0, 1)

        taco.CFrame = CFrame.lookAt(
            MathUtils.quadBezier(t, shootPos, midPos, animalPos),
            MathUtils.quadBezier(t + 0.1, shootPos, midPos, animalPos)
        )

        if t >= 1 then
            tacoConn:Disconnect()
            taco:Destroy()
            ClientEventUtils.playBurst(EVENT_SCRIPT:WaitForChild("StruckVFX"), animalName, {
                ReplicatedStorage.Sounds.Events["Raining Tacos"].Hit
            })

            local delayTrove = eventTrove:Extend()
            delayTrove:Add(task.delay(TRAIT_DELAY, function()
                if not animal or not animal.Parent then
                    delayTrove:Clean()
                    return
                end
                local traits, set = getTraits(animal)
                if set[BLOCKING_TRAIT] then
                    delayTrove:Clean()
                    return
                end
                table.insert(traits, BLOCKING_TRAIT)
                animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
                delayTrove:Clean()
            end))
        end

        debug.profileend()
    end)

    eventTrove:Add(tacoConn)
end

-- ─── Main ────────────────────────────────────────────────────────────────────

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
            local waitTime = math.random(700, 1200) / 100
            if ReplicatedStorage:GetAttribute("3RoadsEvent") == true then
                waitTime = waitTime / 3
            end
            task.wait(waitTime)
            if not isActive then break end

            local shotCount = getShotCount()
            for i = 1, shotCount do
                local candidates = getValidCandidates(cachedAnimals)
                if #candidates > 0 then
                    local selected = candidates[math.random(1, #candidates)]
                    recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()
                    shootAnimal(selected.Name, selected)
                end
                if i < shotCount then
                    task.wait(1)
                    if not isActive then break end
                end
            end
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
