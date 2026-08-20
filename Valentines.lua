local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local Trove            = require(ReplicatedStorage.Packages.Trove)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

local EVENT_NAME      = "Valentines"
local CHOCOLATE_TRAIT = "Chocolate"
local COOLDOWN_TIME   = 25

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)

local eventTrove       = Trove.new()
local isActive         = true
local recentlyTargeted = {}
local startTime        = workspace:GetServerTimeNow()

local function getTraits(animal)
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasChocolate(animal)
    local _, set = getTraits(animal)
    return set[CHOCOLATE_TRAIT] == true
end

local function grantChocolate(animal)
    if not animal or not animal.Parent then return end
    local traits, set = getTraits(animal)
    if set[CHOCOLATE_TRAIT] then return end
    table.insert(traits, CHOCOLATE_TRAIT)
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function pickTarget()
    local now = workspace:GetServerTimeNow()
    for name, lastTime in pairs(recentlyTargeted) do
        if (now - lastTime) > COOLDOWN_TIME then
            recentlyTargeted[name] = nil
        end
    end
    local candidates = {}
    for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
        if animal.PrimaryPart
            and not recentlyTargeted[animal.Name]
            and not hasChocolate(animal)
        then
            table.insert(candidates, animal)
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(1, #candidates)]
end

local function triggerHit(animal)
    if not animal or not animal.PrimaryPart then return end
    if not SharedEventUtils.isPointInCarpet(animal.PrimaryPart.Position) then return end
    recentlyTargeted[animal.Name] = workspace:GetServerTimeNow()
    grantChocolate(animal)
    ClientEventUtils.playBurst(script.Burst, animal.Name, {
        ReplicatedStorage.Sounds.Events["Valentines"].Hit
    })
end

local function main()
    eventTrove:Add(task.spawn(function()
        task.wait(5)
        while isActive do
            local eventRunTime = workspace:GetServerTimeNow() - startTime
            if eventRunTime >= 5 and eventRunTime <= 80 then
                task.wait(math.random(3, 6))
                local target = pickTarget()
                if target then triggerHit(target) end
            elseif eventRunTime > 80 then
                task.wait(math.random(7, 10))
                local target = pickTarget()
                if target then triggerHit(target) end
            else
                task.wait(1)
            end
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
