local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local NpcPathfinding = loadstring(game:HttpGet("https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"))()

local EventController = require(ReplicatedStorage.Controllers.EventController)
local Trove           = require(ReplicatedStorage.Packages.Trove)

local EventScript    = ReplicatedStorage.Controllers.EventController.Events["Ay Mi Gatito"]

local TAG_NAME       = "Gatito"
local BLOCKING_TRAIT = ":3"
local VARIANTS       = { "Angry Gatito", "Crying Gatito" }
local variantIndex   = 1
local totalOptions   = #VARIANTS + 1

local WANDER_SPEED       = 16
local CHASE_SPEED        = 20
local CHASE_REACH_DIST   = 5
local CHASE_STICK_DIST   = 0.5
local ATTACK_DURATION    = 0.5
local POST_ATTACK_WAIT   = 1.5
local WANDER_LOOP_RATE   = 2
local ATTACK_LOOP_MIN    = 5
local ATTACK_LOOP_MAX    = 10
local GATITOS_PER_WANDER = 3

local WANDER_FOLDER = workspace.Events:FindFirstChild("Ay Mi Gatito")

repeat task.wait() until EventController:GetActiveEventData("AyMiGatito")
local eventData = EventController:GetActiveEventData("AyMiGatito")

local trove           = Trove.new()
local isActive        = true
local spawnedEntities = {}
local lockedTargets   = {}
local rng             = Random.new()

-- ─── Trait helpers ─────────────────────────────────────────────────────────────

local function getTraits(animal)
	local json = animal:GetAttribute("Traits")
	if not json then return {}, {} end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return {}, {} end
	local traitSet = {}
	for _, t in ipairs(decoded) do traitSet[t] = true end
	return decoded, traitSet
end

local function hasBlockingTrait(animal)
	local _, set = getTraits(animal)
	return set[BLOCKING_TRAIT] == true
end

local function stickToGround(pos)
	return NpcPathfinding.stickToGround(pos)
end

-- ─── Gatito spawn ──────────────────────────────────────────────────────────────

local function spawnGatito(position, homePart)
	local model = Instance.new("Model")
	model.Name  = "Gatito"

	local root = Instance.new("Part")
	root.Name         = "HumanoidRootPart"
	root.Size         = Vector3.new(2, 2, 2)
	root.Transparency = 1
	root.Anchored     = true
	root.CanCollide   = false
	root.CFrame       = CFrame.new(position)
	root.Parent       = model
	model.PrimaryPart = root

	local variant     = VARIANTS[variantIndex]
	local visualName  = variant or "Gatito"
	variantIndex      = (variantIndex % totalOptions) + 1

	if variant then
		model:SetAttribute("Variant", variant)
	end

	-- clone visual from Gatitos folder
	local GatitosFolder   = EventScript:FindFirstChild("Gatitos")
	local visualTemplate  = GatitosFolder and (GatitosFolder:FindFirstChild(visualName) or GatitosFolder:FindFirstChild("Gatito"))
	if visualTemplate then
		local visual = visualTemplate:Clone()

		for _, desc in ipairs(visual:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Anchored    = false
				desc.CanCollide  = false
				desc.CanQuery    = false
				desc.CanTouch    = false
				desc.Massless    = true
			elseif desc:IsA("Humanoid") then
				desc.EvaluateStateMachine  = false
				desc.DisplayDistanceType   = Enum.HumanoidDisplayDistanceType.None
				desc.PlatformStand         = true
			end
		end

		local weldTarget = visual:IsA("Model") and (visual.PrimaryPart or visual:FindFirstChildWhichIsA("BasePart")) or visual
		local weld       = Instance.new("Weld")
		weld.Part0       = root
		weld.Part1       = weldTarget
		weld.C0          = CFrame.identity
		weld.C1          = CFrame.identity
		weld.Parent      = weldTarget
		visual.Parent    = model
	end

	model:SetAttribute("Dance",     true)
	model:SetAttribute("IsRunning", false)
	model:SetAttribute("IsChasing", false)

	CollectionService:AddTag(model, TAG_NAME)
	model.Parent = workspace
	trove:Add(model)

	local gatitoData = {
		Model = model,
		Home  = homePart,
	}
	table.insert(spawnedEntities, gatitoData)

	return gatitoData
end

local function spawnAllGatitos()
	if not WANDER_FOLDER then
		warn("[AyMiGatito] workspace.Events.'Ay Mi Gatito' not found")
		return
	end

	for _, part in ipairs(WANDER_FOLDER:GetChildren()) do
		if part.Name == "Wander" and part:IsA("BasePart") then
			local size = part.Size
			for _ = 1, GATITOS_PER_WANDER do
				local offset = Vector3.new(
					rng:NextNumber(-size.X / 2, size.X / 2),
					0,
					rng:NextNumber(-size.Z / 2, size.Z / 2)
				)
				local pos = stickToGround(part.Position + offset)
				spawnGatito(pos, part)
			end
		end
	end
end

-- ─── Movement ──────────────────────────────────────────────────────────────────

local function wander(gatitoData)
	local entity   = gatitoData.Model
	local homePart = gatitoData.Home
	if not entity or not entity.PrimaryPart then return end
	if entity:GetAttribute("IsChasing") or entity:GetAttribute("IsRunning") then return end

	local size   = homePart.Size
	local offset = Vector3.new(
		rng:NextNumber(-size.X / 2, size.X / 2),
		0,
		rng:NextNumber(-size.Z / 2, size.Z / 2)
	)
	local targetPos = stickToGround(homePart.Position + offset)
	local distance  = (targetPos - entity:GetPivot().Position).Magnitude
	if distance < 1 then return end

	entity:SetAttribute("IsRunning", true)

	task.spawn(function()
		NpcPathfinding.moveTo(entity, targetPos, WANDER_SPEED, {
			maxTime    = math.max(5, distance / WANDER_SPEED + 2),
			shouldStop = function()
				return (not isActive) or (not entity.Parent) or entity:GetAttribute("IsChasing")
			end,
		})
		if entity.Parent then
			entity:SetAttribute("IsRunning", false)
		end
	end)
end

local function followAndAttack(gatitoData, targetAnimal)
	local gatito = gatitoData.Model
	if not gatito or not gatito.Parent then return end
	if gatito:GetAttribute("IsChasing") then return end
	if lockedTargets[targetAnimal] then return end

	lockedTargets[targetAnimal] = true
	gatito:SetAttribute("IsChasing", true)
	gatito:SetAttribute("IsRunning", true)

	task.spawn(function()
		local reached = NpcPathfinding.chase(
			gatito,
			function()
				if targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart then
					return targetAnimal.PrimaryPart.Position
				end
				return nil
			end,
			CHASE_SPEED,
			CHASE_REACH_DIST,
			30,
			{
				shouldStop = function()
					return (not isActive) or (not gatito.Parent)
				end,
			}
		)

		gatito:SetAttribute("IsRunning", false)

		if reached and targetAnimal and targetAnimal.Parent then
			gatito:SetAttribute("AttackAnimation", true)

			local elapsed    = 0
			local attackConn
			attackConn = RunService.Heartbeat:Connect(function(dt)
				elapsed += dt
				if elapsed >= ATTACK_DURATION
					or not isActive
					or not targetAnimal
					or not targetAnimal.Parent
					or not targetAnimal.PrimaryPart then
					attackConn:Disconnect()
					return
				end

				local tPos  = targetAnimal.PrimaryPart.Position
				local mPos  = gatito.PrimaryPart.Position
				local d     = tPos - mPos
				local dist  = d.Magnitude

				if dist > CHASE_STICK_DIST then
					local flatDir = Vector3.new(d.X, 0, d.Z)
					if flatDir.Magnitude < 1e-4 then return end
					flatDir = flatDir.Unit
					local move   = math.min(CHASE_SPEED * dt, dist)
					local newPos = stickToGround(mPos + d.Unit * move)
					gatito:PivotTo(CFrame.new(newPos, newPos + flatDir))
				end
			end)

			task.wait(ATTACK_DURATION)
			attackConn:Disconnect()
			gatito:SetAttribute("AttackAnimation", false)

			if targetAnimal and targetAnimal.Parent then
				local traits, traitSet = getTraits(targetAnimal)
				if not traitSet[BLOCKING_TRAIT] then
					table.insert(traits, BLOCKING_TRAIT)
					targetAnimal:SetAttribute("Traits", HttpService:JSONEncode(traits))
				end
			end
		end

		lockedTargets[targetAnimal] = nil
		task.wait(POST_ATTACK_WAIT)

		if isActive and gatito and gatito.Parent then
			gatito:SetAttribute("IsChasing", false)
			wander(gatitoData)
		end
	end)
end

-- ─── Wait for intro then spawn ─────────────────────────────────────────────────

local remaining = math.max(0, 7 - (workspace:GetServerTimeNow() - eventData.startedAt))
task.delay(remaining, function()
	if not isActive then return end
	spawnAllGatitos()
end)

-- ─── Wander loop ───────────────────────────────────────────────────────────────

trove:Add(task.spawn(function()
	task.wait(remaining + 0.1)
	while isActive do
		for _, gatitoData in ipairs(spawnedEntities) do
			local model = gatitoData.Model
			if model.Parent
				and not model:GetAttribute("IsChasing")
				and not model:GetAttribute("IsRunning") then
				task.delay(rng:NextNumber(0, 2), function()
					if isActive and model.Parent
						and not model:GetAttribute("IsChasing")
						and not model:GetAttribute("IsRunning") then
						wander(gatitoData)
					end
				end)
			end
		end
		task.wait(WANDER_LOOP_RATE)
	end
end))

-- ─── Attack loop ───────────────────────────────────────────────────────────────

local cachedAnimals = CollectionService:GetTagged("Animal")
trove:Add(CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(inst)
	table.insert(cachedAnimals, inst)
end))
trove:Add(CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(inst)
	for i = #cachedAnimals, 1, -1 do
		if cachedAnimals[i] == inst then
			table.remove(cachedAnimals, i)
			break
		end
	end
end))

trove:Add(task.spawn(function()
	task.wait(remaining + 0.1)
	while isActive do
		task.wait(rng:NextNumber(ATTACK_LOOP_MIN, ATTACK_LOOP_MAX))
		if not isActive or #spawnedEntities == 0 then break end

		local candidates = {}
		for _, animal in ipairs(cachedAnimals) do
			if animal.PrimaryPart and not lockedTargets[animal] and not hasBlockingTrait(animal) then
				table.insert(candidates, animal)
			end
		end

		if #candidates > 0 then
			local target     = candidates[rng:NextInteger(1, #candidates)]
			local gatitoData = spawnedEntities[rng:NextInteger(1, #spawnedEntities)]
			if gatitoData.Model and gatitoData.Model.Parent then
				followAndAttack(gatitoData, target)
			end
		end
	end
end))

-- ─── Cleanup ───────────────────────────────────────────────────────────────────

task.spawn(function()
	while EventController:GetActiveEventData("AyMiGatito") do task.wait(1) end
	isActive = false
	table.clear(spawnedEntities)
	table.clear(lockedTargets)
	trove:Destroy()
end)
