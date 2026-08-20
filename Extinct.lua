local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

if not game:IsLoaded() then game.Loaded:Wait() end

local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)
local Trove            = require(ReplicatedStorage.Packages.Trove)

local EVENT_NAME = "Extinct"

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

local EventFolder = ReplicatedStorage.Controllers.EventController.Events.Extinct

-- ─── Constants ────────────────────────────────────────────────────────────────

local COOLDOWN_DURATION = 15
local MIN_WAIT          = 4
local MAX_WAIT          = 9
local PIVOT_POSITION    = CFrame.new(-381.939, -9.341, 20.176)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local isActive         = true
local recentlyTargeted = {}

local extinctModel = workspace:WaitForChild("Events")
    :WaitForChild("Extinct")
    :WaitForChild("Model")

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

local function hasSkeleton(animal)
    local _, set = getTraits(animal)
    return set["Skeleton"] == true
end

local function grantSkeleton(animal)
    if not animal or not animal.Parent then return end
    local traits, set = getTraits(animal)
    if set["Skeleton"] then return end
    table.insert(traits, "Skeleton")
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function getValidCandidates()
    local now = workspace:GetServerTimeNow()
    for name, lastTime in pairs(recentlyTargeted) do
        if (now - lastTime) > COOLDOWN_DURATION then
            recentlyTargeted[name] = nil
        end
    end
    local candidates = {}
    for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
        if animal.PrimaryPart
            and not recentlyTargeted[animal.Name]
            and not hasSkeleton(animal)
        then
            table.insert(candidates, animal)
        end
    end
    return candidates
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    extinctModel:PivotTo(PIVOT_POSITION)

    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(MIN_WAIT, MAX_WAIT))
            if not isActive then break end

            local candidates = getValidCandidates()
            if #candidates == 0 then continue end

            local selected = candidates[math.random(1, #candidates)]
            if not selected.PrimaryPart
                or not SharedEventUtils.isPointInCarpet(selected.PrimaryPart.Position)
            then
                continue
            end

            recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()

            task.delay(0.1, function()
                grantSkeleton(selected)
            end)

            ClientEventUtils.playBurst(EventFolder.Burst, selected.Name, {
                ReplicatedStorage.Sounds.Events.Extinct.Hit
            })
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    extinctModel:PivotTo(CFrame.new(0, 100000, 0))
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
