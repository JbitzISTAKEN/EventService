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
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local EVENT_NAME = "Brazil"

local BURST_GROW_DURATION    = 2.25
local LIGHT_SPEED            = 50
local RECENT_TARGET_COOLDOWN = 20
local ACTIVATION_DELAY       = 6

-- ─── Gate ─────────────────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove        = Trove.new()
local recentlyTargeted: {[string]: number} = {}
local isActive          = true
local isTargetingAnimal = false
local currentTween: Tween?              = nil
local trackedAnimal: Model?             = nil
local trackingConnection: RBXScriptConnection? = nil

local MapFloor = workspace:WaitForChild("Events")
	:WaitForChild("Brazil")
	:WaitForChild("MapFloor")

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getRandomPosition(): Vector3
	local randomX = MapFloor.Position.X + (math.random() - 0.5) * MapFloor.Size.X
	local randomZ = MapFloor.Position.Z + (math.random() - 0.5) * MapFloor.Size.Z
	return Vector3.new(randomX, MapFloor.Position.Y, randomZ)
end

local function getLightPart(): Part?
	for _, p in CollectionService:GetTagged("BrazilHitbox") do
		if p:IsA("BasePart") then return p :: Part end
	end
	return nil
end

local function tweenLightToPosition(lightPart: Part, position: Vector3): Tween?
	if currentTween then currentTween:Cancel() end
	local distance = (lightPart.Position - position).Magnitude
	local duration = math.max(distance / LIGHT_SPEED, 0.05)
	local tween = TweenService:Create(
		lightPart,
		TweenInfo.new(duration, Enum.EasingStyle.Linear),
		{ CFrame = CFrame.new(position) }
	)
	currentTween = tween
	tween:Play()
	return tween
end

local function stopTrackingAnimal()
	if trackingConnection then
		trackingConnection:Disconnect()
		trackingConnection = nil
	end
	trackedAnimal = nil
end

local function trackAnimal(animal: Model, lightPart: Part)
	stopTrackingAnimal()
	trackedAnimal = animal
	trackingConnection = RunService.Heartbeat:Connect(function()
		if not trackedAnimal or not trackedAnimal.PrimaryPart or not lightPart or not lightPart.Parent then
			stopTrackingAnimal()
			return
		end
		local animalPos = trackedAnimal.PrimaryPart.Position
		lightPart.CFrame = CFrame.new(animalPos.X, lightPart.Position.Y, animalPos.Z)
	end)
end

local function decodeTraits(json: string?): {string}
	if not json then return {} end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, json)
	return (ok and typeof(data) == "table") and data or {}
end

local function hasTrait(traits: {string}, traitName: string): boolean
	for _, t in traits do
		if t == traitName then return true end
	end
	return false
end

local function addTraitIfMissing(animal: Model, traitName: string)
	local traits = decodeTraits(animal:GetAttribute("Traits"))
	if not hasTrait(traits, traitName) then
		table.insert(traits, traitName)
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, traits)
		if ok then animal:SetAttribute("Traits", encoded) end
	end
end

-- replaces Focus:FireAllClients — sets Focused and tells Square tracker the name
local function fireFocus(lightPart: Part, animalName: string)
	local now = workspace:GetServerTimeNow()
	lightPart:SetAttribute("Focused",    now)
	lightPart:SetAttribute("BurstTime",  now + BURST_GROW_DURATION)
	lightPart:SetAttribute("FocusedName", animalName)
end

-- replaces Burst:FireAllClients — plays burst sound locally, clears attributes
local function fireBurst(lightPart: Part, animal: Model)
	-- play burst sound on the light part directly, same as ClientEventUtils.playBurst
	local burstFolder = ReplicatedStorage:FindFirstChild("Sounds")
		and ReplicatedStorage.Sounds:FindFirstChild("Events")
		and ReplicatedStorage.Sounds.Events:FindFirstChild("Brazil")
		and ReplicatedStorage.Sounds.Events.Brazil:FindFirstChild("Hit")

	if burstFolder then
		local sound = burstFolder:Clone()
		sound.Parent = lightPart
		sound:Play()
		sound.Ended:Once(function() sound:Destroy() end)
	end

	lightPart:SetAttribute("Focused",     nil)
	lightPart:SetAttribute("BurstTime",   nil)
	lightPart:SetAttribute("FocusedName", nil)
end

-- ─── Wander ───────────────────────────────────────────────────────────────────

local function continuousRandomMovement()
	eventTrove:Add(task.spawn(function()
		while isActive do
			if not isTargetingAnimal then
				local light = getLightPart()
				if light then
					local tween = tweenLightToPosition(light, getRandomPosition())
					if tween then tween.Completed:Wait() end
				end
			else
				task.wait(0.1)
			end
			if not isActive then break end
		end
	end))
end

-- ─── Animal check ─────────────────────────────────────────────────────────────

local function animalCheckLoop()
	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(math.random(7, 12))
			if not isActive then break end

			local light = getLightPart()
			if not light then continue end

			local now = workspace:GetServerTimeNow()

			for name, last in recentlyTargeted do
				if now - last > RECENT_TARGET_COOLDOWN then
					recentlyTargeted[name] = nil
				end
			end

			local selected: Model?  = nil
			local shortestDistance  = math.huge

			for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
				if animal.PrimaryPart then
					local traits = decodeTraits(animal:GetAttribute("Traits"))
					if not recentlyTargeted[animal.Name] and not hasTrait(traits, "Brazil") then
						local dist = (light.Position - animal.PrimaryPart.Position).Magnitude
						if dist < shortestDistance then
							shortestDistance = dist
							selected = animal
						end
					end
				end
			end

			if not selected or not selected.PrimaryPart then continue end

			if not SharedEventUtils.isPointInCarpet(selected.PrimaryPart.Position) then
				isTargetingAnimal = false
				continue
			end

			isTargetingAnimal = true

			local pos   = selected.PrimaryPart.Position
			local tween = tweenLightToPosition(
				light,
				Vector3.new(pos.X, light.Position.Y, pos.Z)
			)
			if tween then tween.Completed:Wait() end

			light = getLightPart()
			if not light then isTargetingAnimal = false continue end

			trackAnimal(selected, light)
			task.wait(0.5)

			-- replaces Focus:FireAllClients
			fireFocus(light, selected.Name)
			recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()

			task.wait(BURST_GROW_DURATION)

			stopTrackingAnimal()

			light = getLightPart()
			if not light then isTargetingAnimal = false continue end

			-- replaces Burst:FireAllClients
			fireBurst(light, selected)

			local targetAnimal = selected
			task.delay(0.1, function()
				if not targetAnimal or not targetAnimal.Parent then return end
				addTraitIfMissing(targetAnimal, "Brazil")
			end)

			isTargetingAnimal = false
		end
	end))
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	task.wait(ACTIVATION_DELAY)
	if not isActive then return end

	continuousRandomMovement()
	animalCheckLoop()

	while EventController:GetActiveEventData(EVENT_NAME) do
		task.wait(1)
	end

	isActive = false
	stopTrackingAnimal()
	if currentTween then currentTween:Cancel() end
	eventTrove:Destroy()
	table.clear(recentlyTargeted)
end

task.spawn(main)
