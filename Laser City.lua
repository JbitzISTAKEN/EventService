local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local EVENT_NAME = "Laser City"
local TRAIT_NAME = "Aura Shades"
local TAG_NAME   = "LaserCityImpact"

local EVENT_SCRIPT = ReplicatedStorage:WaitForChild("Controllers")
	:WaitForChild("EventController")
	:WaitForChild("Events")
	:WaitForChild("Laser City")

-- ─── Constants ────────────────────────────────────────────────────────────────

local LASER_SPEED  = 26
local HIT_RADIUS   = 8
local HIT_COOLDOWN = 4
local DWELL_MIN    = 0.15
local DWELL_MAX    = 0.6

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove   = Trove.new()
local isActive     = true
local hitCooldowns: { [Model]: number } = {}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getFloors(): { BasePart }
	local folder = workspace:FindFirstChild("Events")
	local model  = folder and folder:FindFirstChild("Laser City")
	if not model then return {} end
	local out = {}
	for _, name in ipairs({ "MapFloorLeft", "MapFloorRight" }) do
		local p = model:FindFirstChild(name)
		if p and p:IsA("BasePart") then table.insert(out, p) end
	end
	return out
end

local function pickRandomPoint(): Vector3
	local floors = getFloors()
	if #floors == 0 then return Vector3.new(0, 0, 0) end
	local floor = floors[math.random(1, #floors)]
	local s, p  = floor.Size, floor.Position
	return Vector3.new(
		p.X + (math.random() * 2 - 1) * (s.X / 2),
		p.Y + s.Y / 2,
		p.Z + (math.random() * 2 - 1) * (s.Z / 2)
	)
end

local function decodeTraits(json: string?): { string }
	if not json then return {} end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return {} end
	return decoded
end

local function hasTrait(traits: { string }, name: string): boolean
	for _, t in ipairs(traits) do
		if t == name then return true end
	end
	return false
end

local function giveTrait(animal: Model): boolean
	local traits = decodeTraits(animal:GetAttribute("Traits"))
	if hasTrait(traits, TRAIT_NAME) then return false end
	table.insert(traits, TRAIT_NAME)
	animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
	return true
end

-- ─── Burst ────────────────────────────────────────────────────────────────────

local burstAsset = EVENT_SCRIPT:WaitForChild("Burst")

local function doBurst(animalName: string)
	ClientEventUtils.playBurst(burstAsset, animalName, {
		ReplicatedStorage.Sounds.Events["Laser City"].BeamDirectHit,
	})
end

-- ─── Laser hitbox ─────────────────────────────────────────────────────────────

local function createLaserPart(): BasePart
	local part = Instance.new("Part")
	part.Name        = "LaserCityImpact"
	part.Size        = Vector3.new(1, 1, 1)
	part.Transparency = 1
	part.Anchored    = true
	part.CanCollide  = false
	part.CanQuery    = false
	part.CanTouch    = false
	part.Massless    = true
	part.Position    = pickRandomPoint()
	CollectionService:AddTag(part, TAG_NAME)
	part.Parent = workspace.Events:FindFirstChild("Laser City") or workspace
	return part
end

-- ─── Hit detection ────────────────────────────────────────────────────────────

local function applyHits(pos: Vector3)
	local now = tick()
	for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
		if not animal.PrimaryPart then continue end
		if hitCooldowns[animal] and now < hitCooldowns[animal] then continue end
		if (animal.PrimaryPart.Position - pos).Magnitude <= HIT_RADIUS then
			if giveTrait(animal) then
				hitCooldowns[animal] = now + HIT_COOLDOWN
				doBurst(animal.Name)
			end
		end
	end
end

-- ─── Laser movement ───────────────────────────────────────────────────────────

local function moveLaser(laserPart: BasePart)
	eventTrove:Add(task.spawn(function()
		while isActive and laserPart and laserPart.Parent do
			local target   = pickRandomPoint()
			local distance = (target - laserPart.Position).Magnitude
			local duration = math.max(distance / LASER_SPEED, 0.001)

			TweenService:Create(
				laserPart,
				TweenInfo.new(duration, Enum.EasingStyle.Linear),
				{ Position = target }
			):Play()

			local step    = 0.05
			local elapsed = 0
			while elapsed < duration do
				if not isActive or not laserPart or not laserPart.Parent then break end
				applyHits(laserPart.Position)
				task.wait(step)
				elapsed += step
			end

			if isActive and laserPart and laserPart.Parent then
				applyHits(laserPart.Position)
				task.wait(DWELL_MIN + math.random() * (DWELL_MAX - DWELL_MIN))
			end
		end
	end))
end

-- ─── Impact visual sync ───────────────────────────────────────────────────────

local function bindImpactToLaser(laserPart: BasePart)
	local LaserCityMap = workspace:WaitForChild("LaserCityMap")
	local LaserCaylus  = LaserCityMap:WaitForChild("LaserCaylus")
	local Impact       = LaserCaylus:WaitForChild("Impact")

	eventTrove:Add(RunService.PostSimulation:Connect(function()
		if laserPart and laserPart.Parent then
			Impact:PivotTo(laserPart:GetPivot())
		end
	end))
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	local elapsed   = workspace:GetServerTimeNow() - startedAt
	local remaining = math.max(0, 0 - elapsed)
	if remaining > 0 then task.wait(remaining) end
	if not isActive then return end

	local laserPart = createLaserPart()
	eventTrove:Add(laserPart)
	eventTrove:Add(function()
		CollectionService:RemoveTag(laserPart, TAG_NAME)
	end)

	bindImpactToLaser(laserPart)
	moveLaser(laserPart)

	-- Cleanup watchdog
	while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
	isActive = false
	eventTrove:Destroy()
	table.clear(hitCooldowns)
end

task.spawn(main)
