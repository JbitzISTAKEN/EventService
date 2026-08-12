-- LocalScript: BrazilLogic
-- StarterPlayerScripts

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

local EVENT_NAME = "Brazil"

local BURST_GROW_DURATION    = 2.25
local LIGHT_SPEED            = 50
local RECENT_TARGET_COOLDOWN = 20
local ACTIVATION_DELAY       = 6

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove        = Trove.new()
local recentlyTargeted: {[string]: number} = {}
local isActive          = true
local isTargetingAnimal = false
local currentTween: Tween?                   = nil
local trackedAnimal: Model?                  = nil
local trackingConn: RBXScriptConnection?     = nil

local MapFloor = workspace:WaitForChild("Events")
	:WaitForChild("Brazil")
	:WaitForChild("MapFloor")

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getRandomPosition(): Vector3
	return Vector3.new(
		MapFloor.Position.X + (math.random() - 0.5) * MapFloor.Size.X,
		MapFloor.Position.Y,
		MapFloor.Position.Z + (math.random() - 0.5) * MapFloor.Size.Z
	)
end

local function getLightPart(): Part?
	for _, p in CollectionService:GetTagged("BrazilHitbox") do
		if p:IsA("BasePart") then return p :: Part end
	end
	return nil
end

local function cancelTween()
	if currentTween then
		currentTween:Cancel()
		currentTween = nil
	end
end

-- non-blocking tween — fires and forgets, caller does NOT yield
local function moveLightTo(light: Part, position: Vector3)
	cancelTween()
	local dist = (light.Position - position).Magnitude
	local dur  = math.max(dist / LIGHT_SPEED, 0.05)
	local t    = TweenService:Create(
		light,
		TweenInfo.new(dur, Enum.EasingStyle.Linear),
		{ CFrame = CFrame.new(position) }
	)
	currentTween = t
	t:Play()
end

-- blocking tween only used during focus cycle where we own the light exclusively
local function moveLightToAndWait(light: Part, position: Vector3)
	cancelTween()
	local dist = (light.Position - position).Magnitude
	local dur  = math.max(dist / LIGHT_SPEED, 0.05)
	local t    = TweenService:Create(
		light,
		TweenInfo.new(dur, Enum.EasingStyle.Linear),
		{ CFrame = CFrame.new(position) }
	)
	currentTween = t
	t:Play()
	-- poll instead of Completed:Wait() — never suspends across ownership change
	local elapsed = 0
	repeat
		local dt = task.wait(0.03)
		elapsed += dt
	until elapsed >= dur or not isActive or not isTargetingAnimal
	currentTween = nil
end

local function stopTracking()
	if trackingConn then
		trackingConn:Disconnect()
		trackingConn = nil
	end
	trackedAnimal = nil
end

local function trackAnimal(animal: Model, light: Part)
	stopTracking()
	trackedAnimal = animal
	trackingConn = RunService.Heartbeat:Connect(function()
		if not trackedAnimal or not trackedAnimal.PrimaryPart
			or not light or not light.Parent then
			stopTracking()
			return
		end
		local p = trackedAnimal.PrimaryPart.Position
		light.CFrame = CFrame.new(p.X, light.Position.Y, p.Z)
	end)
end

local function decodeTraits(json: string?): {string}
	if not json then return {} end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, json)
	return (ok and typeof(data) == "table") and data or {}
end

local function hasTrait(traits: {string}, name: string): boolean
	for _, t in traits do if t == name then return true end end
	return false
end

local function addTraitIfMissing(animal: Model, name: string)
	local traits = decodeTraits(animal:GetAttribute("Traits"))
	if hasTrait(traits, name) then return end
	table.insert(traits, name)
	local ok, enc = pcall(HttpService.JSONEncode, HttpService, traits)
	if ok then animal:SetAttribute("Traits", enc) end
end

local function fireBurst(light: Part)
	local hit = ReplicatedStorage:FindFirstChild("Sounds")
		and ReplicatedStorage.Sounds:FindFirstChild("Events")
		and ReplicatedStorage.Sounds.Events:FindFirstChild("Brazil")
		and ReplicatedStorage.Sounds.Events.Brazil:FindFirstChild("Hit")
	if hit then
		local s = hit:Clone()
		s.Parent = light
		s:Play()
		s.Ended:Once(function() s:Destroy() end)
	end
	light:SetAttribute("Focused",   nil)
	light:SetAttribute("BurstTime", nil)
end

-- ─── Wander — pure PostSimulation, no yields ─────────────────────────────────

local wanderClock   = 0
local WANDER_PERIOD = 2.5   -- seconds between random wander targets

eventTrove:Add(RunService.PostSimulation:Connect(function(dt)
	if not isActive or isTargetingAnimal then return end
	wanderClock -= dt
	if wanderClock > 0 then return end
	wanderClock = WANDER_PERIOD

	local light = getLightPart()
	if not light then return end
	moveLightTo(light, getRandomPosition())
end))

-- ─── Focus cycle ──────────────────────────────────────────────────────────────

local function animalCheckLoop()
	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(math.random(7, 12))
			if not isActive then break end
			if isTargetingAnimal then continue end

			local light = getLightPart()
			if not light then continue end

			local now = workspace:GetServerTimeNow()

			for name, last in recentlyTargeted do
				if now - last > RECENT_TARGET_COOLDOWN then
					recentlyTargeted[name] = nil
				end
			end

			local selected: Model? = nil
			local shortest         = math.huge

			for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
				if not animal.PrimaryPart then continue end
				local traits = decodeTraits(animal:GetAttribute("Traits"))
				if recentlyTargeted[animal.Name] then continue end
				if hasTrait(traits, "Brazil") then continue end
				local d = (light.Position - animal.PrimaryPart.Position).Magnitude
				if d < shortest then
					shortest  = d
					selected  = animal
				end
			end

			if not selected or not selected.PrimaryPart then continue end
			if not SharedEventUtils.isPointInCarpet(selected.PrimaryPart.Position) then continue end

			isTargetingAnimal = true
			cancelTween()  -- kill wander tween before we take ownership

			local pos = selected.PrimaryPart.Position
			moveLightToAndWait(light, Vector3.new(pos.X, light.Position.Y, pos.Z))

			light = getLightPart()
			if not light then isTargetingAnimal = false continue end

			trackAnimal(selected, light)
			task.wait(0.5)

			now = workspace:GetServerTimeNow()
			light:SetAttribute("Focused",   now)
			light:SetAttribute("BurstTime", now + BURST_GROW_DURATION)
			recentlyTargeted[selected.Name] = now

			task.wait(BURST_GROW_DURATION)

			stopTracking()

			light = getLightPart()
			if light then fireBurst(light) end

			local target = selected
			task.delay(0.1, function()
				if target and target.Parent then
					addTraitIfMissing(target, "Brazil")
				end
			end)

			isTargetingAnimal = false
		end
	end))
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	task.wait(ACTIVATION_DELAY)
	if not isActive then return end

	animalCheckLoop()

	while EventController:GetActiveEventData(EVENT_NAME) do
		task.wait(1)
	end

	isActive = false
	stopTracking()
	cancelTween()
	eventTrove:Destroy()
	table.clear(recentlyTargeted)
end

task.spawn(main)
