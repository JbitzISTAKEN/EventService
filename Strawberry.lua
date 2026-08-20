local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

if not game:IsLoaded() then game.Loaded:Wait() end

local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)
local Trove            = require(ReplicatedStorage.Packages.Trove)

local EVENT_NAME = "Strawberry"

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

local EventFolder = ReplicatedStorage.Controllers.EventController.Events.Strawberry

-- ─── Constants ────────────────────────────────────────────────────────────────

local COOLDOWN_TIME  = 20
local INITIAL_DELAY  = 5
local BURST_ON_START = 4
local ATTACK_MIN     = 4
local ATTACK_MAX     = 7

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local isActive         = true
local recentlyTargeted = {}
local strikeCount      = 0
local startTime        = startedAt

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getTraits(animal)
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasStrawberry(animal)
    local _, set = getTraits(animal)
    return set["Strawberry"] == true
end

local function grantStrawberry(animal)
    if not animal or not animal.Parent then return end
    local traits, set = getTraits(animal)
    if set["Strawberry"] then return end
    table.insert(traits, "Strawberry")
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function pick()
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
            and not hasStrawberry(animal)
        then
            table.insert(candidates, animal)
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(1, #candidates)]
end

local function hit(animal)
    if not animal or not animal.PrimaryPart then return end

    strikeCount += 1
    if strikeCount > BURST_ON_START then
        if not SharedEventUtils.isPointInCarpet(animal.PrimaryPart.Position) then
            return
        end
    end

    recentlyTargeted[animal.Name] = workspace:GetServerTimeNow()
    grantStrawberry(animal)
    ClientEventUtils.playBurst(EventFolder.Burst, animal.Name, {
        ReplicatedStorage.Sounds.Events.Strawberry.BrainrotHit
    })
end

local function burstOnStart()
    for _ = 1, BURST_ON_START do
        local target = pick()
        if target then hit(target) end
    end
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    burstOnStart()

    eventTrove:Add(task.spawn(function()
        task.wait(INITIAL_DELAY)
        while isActive do
            if not isActive then break end
            local target = pick()
            if target then hit(target) end
            task.wait(math.random(ATTACK_MIN, ATTACK_MAX))
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
