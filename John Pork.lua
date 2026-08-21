local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

if not game:IsLoaded() then game.Loaded:Wait() end

local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local Trove            = require(ReplicatedStorage.Packages.Trove)

local EVENT_NAME = "John Pork"
local COOLDOWN   = 20
local TRAIT      = "John Pork"

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startTime = eventData.startedAt

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local isActive         = true
local recentlyTargeted = {}
local hitboxes         = {}

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

local function hasTrait(animal)
    local _, set = getTraits(animal)
    return set[TRAIT] == true
end

local function grantTrait(animal)
    if not animal or not animal.Parent then return end
    local traits, set = getTraits(animal)
    if set[TRAIT] then return end
    table.insert(traits, TRAIT)
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function pick()
    local now = workspace:GetServerTimeNow()
    for name, lastTime in pairs(recentlyTargeted) do
        if (now - lastTime) > COOLDOWN then
            recentlyTargeted[name] = nil
        end
    end
    local candidates = {}
    for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
        if animal.PrimaryPart
            and not recentlyTargeted[animal.Name]
            and not hasTrait(animal)
        then
            table.insert(candidates, animal)
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(1, #candidates)]
end

-- ─── Hit — 1:1 to server hit() ────────────────────────────────────────────────

local function hit(animal)
    if not animal or not animal.PrimaryPart then return end

    local animalId  = animal.Name
    local animalPos = animal.PrimaryPart.Position
    local hitTrove  = eventTrove:Extend()

    local hitboxPart = hitTrove:Add(Instance.new("Part"))
    hitboxPart.Name        = "John PorkHitbox_" .. animalId
    hitboxPart.Size        = Vector3.new(1, 1, 1)
    hitboxPart.Transparency = 1
    hitboxPart.Anchored    = true
    hitboxPart.CanCollide  = false
    hitboxPart.CFrame      = CFrame.new(animalPos.X, animalPos.Y + 9, animalPos.Z)
    hitboxPart.Parent      = workspace

    hitboxes[animalId] = hitboxPart
    recentlyTargeted[animalId] = workspace:GetServerTimeNow()

    hitTrove:Add(task.spawn(function()
        local focusTime = workspace:GetServerTimeNow() + 1
        hitboxPart:SetAttribute("Focused", focusTime)

        grantTrait(animal)

        ClientEventUtils.playBurst(
            ReplicatedStorage.Controllers.EventController.Events["John Pork"].Burst,
            animalId,
            { ReplicatedStorage.Sounds.Events["John Pork"].BrainrotHit }
        )

        task.wait(2)
        hitboxes[animalId] = nil
        hitTrove:Clean()
    end))
end

-- ─── Event loop — 1:1 to server event() timing ────────────────────────────────

local function main()
    eventTrove:Add(task.spawn(function()
        task.wait(5)
        while isActive do
            local now        = workspace:GetServerTimeNow()
            local runTime    = now - startTime

            if runTime >= 6 and runTime <= 90 then
                task.wait(math.random(4, 7))
                local target = pick()
                if target then hit(target) end
            elseif runTime > 85 then
                task.wait(math.random(8, 12))
                local target = pick()
                if target then hit(target) end
            else
                task.wait(1)
            end
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    hitboxes = {}
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
