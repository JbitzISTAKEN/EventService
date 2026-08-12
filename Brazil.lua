
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)

local EVENT_NAME = "Brazil"

local BURST_GROW_DURATION    = 2.25
local LIGHT_SPEED            = 50
local ATTACK_COOLDOWN_MIN    = 7
local ATTACK_COOLDOWN_MAX    = 12
local RECENT_TARGET_COOLDOWN = 20
local ACTIVATION_DELAY       = 6
local CARPET_Y_THRESHOLD     = 5

-- ─── Gate ─────────────────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local recentlyTargeted = {}
local isActive         = true
local currentTween: Tween? = nil

local MapFloor = workspace:WaitForChild("Events")
	:WaitForChild("Brazil")
	:WaitForChild("MapFloor")

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getRandomPosition(): Vector3
	local hx = MapFloor.Size.X * 0.5
	local hz = MapFloor.Size.Z * 0.5
	return Vector3.new(
		MapFloor.Position.X + (math.random() - 0.5) * hx * 2,
		MapFloor.Position.Y,
		MapFloor.Position.Z + (math.random() - 0.5) * hz * 2
	)
end

local function isOnCarpet(pos: Vector3): boolean
	local dy = math.abs(pos.Y - MapFloor.Position.Y)
	if dy > CARPET_Y_THRESHOLD then return false end
	return math.abs(pos.X - MapFloor.Position.X) <= MapFloor.Size.X * 0.5
		and math.abs(pos.Z - MapFloor.Position.Z) <= MapFloor.Size.Z * 0.5
end

local function getLightPart(): Part?
	for _, p in CollectionService:GetTagged("BrazilHitbox") do
		if p:IsA("Part") then return p end
	end
	return nil
end

local function cancelTween()
	if currentTween then
		currentTween:Cancel()
		currentTween = nil
	end
end

local function tweenLightTo(light: Part, position: Vector3)
	cancelTween()
	local distance = (light.Position - position).Magnitude
	local duration = math.max(distance / LIGHT_SPEED, 0.1)
	local tween = TweenService:Create(
		light,
		TweenInfo.new(duration, Enum.EasingStyle.Linear),
		{ CFrame = CFrame.new(position) }
	)
	currentTween = tween
	tween:Play()
	tween.Completed:Wait()
	currentTween = nil
end

local function decodeTraits(animal: Model): { string }
	local raw = animal:GetAttribute("Traits")
	if not raw then return {} end
	local ok, result = pcall(HttpService.JSONDecode, HttpService, raw)
	return (ok and type(result) == "table") and result or {}
end

local function hasBrazilTrait(animal: Model): boolean
	for _, t in decodeTraits(animal) do
		if t == "Brazil" then return true end
	end
	return false
end

local function addBrazilTrait(animal: Model)
	local traits = decodeTraits(animal)
	for _, t in traits do
		if t == "Brazil" then return end
	end
	table.insert(traits, "Brazil")
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, traits)
	if ok then
		animal:SetAttribute("Traits", encoded)
	end
end

local function pruneTargeted()
	local now = workspace:GetServerTimeNow()
	for name, last in pairs(recentlyTargeted) do
		if now - last > RECENT_TARGET_COOLDOWN then
			recentlyTargeted[name] = nil
		end
	end
end

-- ─── Single loop — wander and focus unified ───────────────────────────────────

local function mainLoop()
	while isActive do
		local light = getLightPart()
		if not light then
			task.wait(0.5)
			continue
		end

		pruneTargeted()

		local candidates = {}
		for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
			if not animal.PrimaryPart then continue end
			if hasBrazilTrait(animal) then continue end
			if recentlyTargeted[animal.Name] then continue end
			if not isOnCarpet(animal.PrimaryPart.Position) then continue end
			table.insert(candidates, animal)
		end

		if #candidates == 0 then
			-- no targets, wander randomly
			tweenLightTo(light, getRandomPosition())
			continue
		end

		-- wander 1-2 times before committing to a target
		local wanderCount = math.random(1, 2)
		for _ = 1, wanderCount do
			if not isActive then break end
			light = getLightPart()
			if not light then break end
			tweenLightTo(light, getRandomPosition())
			task.wait(0.3)
		end

		if not isActive then break end

		light = getLightPart()
		if not light then continue end

		-- re-check candidates after wander
		local selected: Model? = nil
		for _, animal in ipairs(candidates) do
			if animal.Parent and animal.PrimaryPart and not hasBrazilTrait(animal) then
				selected = animal
				break
			end
		end

		if not selected or not selected.PrimaryPart then continue end

		recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()

		-- move to animal
		local targetPos = Vector3.new(
			selected.PrimaryPart.Position.X,
			light.Position.Y,
			selected.PrimaryPart.Position.Z
		)
		tweenLightTo(light, targetPos)

		light = getLightPart()
		if not light then continue end

		-- set Focused — Square cage starts growing on the client event script
		local now = workspace:GetServerTimeNow()
		light:SetAttribute("Focused", now)

		-- track animal for burst duration with heartbeat, no blocking tween
		local elapsed  = 0
		local trackConn = RunService.Heartbeat:Connect(function(dt)
			elapsed += dt
			if not light or not light.Parent then return end
			if not selected or not selected.PrimaryPart then return end
			light.CFrame = CFrame.new(
				selected.PrimaryPart.Position.X,
				light.Position.Y,
				selected.PrimaryPart.Position.Z
			)
		end)

		-- wait out burst grow duration
		repeat task.wait(0.05) until elapsed >= BURST_GROW_DURATION or not isActive

		trackConn:Disconnect()

		light = getLightPart()
		if light then
			light:SetAttribute("Focused", nil)
		end

		task.delay(0.1, function()
			if selected and selected.Parent then
				addBrazilTrait(selected)
			end
		end)

		-- cooldown before next pick
		task.wait(math.random(ATTACK_COOLDOWN_MIN, ATTACK_COOLDOWN_MAX))
	end
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	task.wait(ACTIVATION_DELAY)
	if not isActive then return end

	eventTrove:Add(task.spawn(mainLoop))

	while EventController:GetActiveEventData(EVENT_NAME) do
		task.wait(1)
	end

	isActive = false
	eventTrove:Destroy()
	table.clear(recentlyTargeted)
end

task.spawn(main)
