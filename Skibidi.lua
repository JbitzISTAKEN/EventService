local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

if not game:IsLoaded() then game.Loaded:Wait() end

local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local Trove            = require(ReplicatedStorage.Packages.Trove)

local EVENT_NAME = "Skibidi"

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local EventFolder = ReplicatedStorage.Controllers.EventController.Events.Skibidi

-- ─── Constants ────────────────────────────────────────────────────────────────

local COOLDOWN_DURATION = 20
local MIN_WAIT          = 6
local MAX_WAIT          = 12

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local isActive         = true
local recentlyTargeted = {}

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

local function hasSkibidi(animal)
	local _, set = getTraits(animal)
	return set["Skibidi"] == true
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
			and not hasSkibidi(animal)
		then
			table.insert(candidates, animal)
		end
	end
	return candidates
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(math.random(MIN_WAIT, MAX_WAIT))
			if not isActive then break end

			local candidates = getValidCandidates()
			if #candidates == 0 then continue end

			local selected = candidates[math.random(1, #candidates)]
			if not selected.PrimaryPart then continue end

			recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()

			ClientEventUtils.playBurst(EventFolder.Burst, selected.Name, {
				ReplicatedStorage.Sounds.Events.Skibidi.BrainrotHit
			})
		end
	end))

	while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
	isActive = false
	eventTrove:Destroy()
	table.clear(recentlyTargeted)
end

task.spawn(main)
