if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

local EVENT_NAME   = "Rain"
local EVENT_SCRIPT = ReplicatedStorage:WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("Rain")

-- ─── Constants (1:1 server) ───────────────────────────────────────────────────

local BLOCKING_TRAIT  = "Wet"
local ATTACK_LOOP_MIN = 4
local ATTACK_LOOP_MAX = 9
local COOLDOWN_WINDOW = 15
local TRAIT_DELAY     = 0.1

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local burstAsset = EVENT_SCRIPT:WaitForChild("StruckVFX")

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local recentlyTargeted = {}
local isActive         = true
local rng              = Random.new()

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
            task.wait(rng:NextNumber(ATTACK_LOOP_MIN, ATTACK_LOOP_MAX))
            if not isActive then break end

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
                    and SharedEventUtils.isPointInCarpet(animal.PrimaryPart.Position)
                then
                    table.insert(candidates, animal)
                end
            end

            if #candidates == 0 then continue end

            local selected = candidates[rng:NextInteger(1, #candidates)]
            recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()

            ClientEventUtils.playBurst(burstAsset, selected.Name, {
                ReplicatedStorage.Sounds.Events.Rain.Burst
            })

            task.delay(TRAIT_DELAY, function()
                if not selected or not selected.Parent then return end
                local traits, set = getTraits(selected)
                if set[BLOCKING_TRAIT] then return end
                table.insert(traits, BLOCKING_TRAIT)
                selected:SetAttribute("Traits", HttpService:JSONEncode(traits))
            end)
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
