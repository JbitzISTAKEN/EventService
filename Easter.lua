local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)

local EVENT_NAME  = "Easter"
local TAG_NAME    = "EasterEventBunny"
local TRAIT_NAME  = "Bunny Ears"

local WANDER_FOLDER = workspace:WaitForChild("Events"):WaitForChild("Wander")

-- ─── Constants ────────────────────────────────────────────────────────────────

local TOTAL_BUNNIES       = math.random(6, 10)
local HOP_SPEED           = 18
local BUNNY_SCALE         = 1

local ATTACK_COOLDOWN_MIN = 6
local ATTACK_COOLDOWN_MAX = 10
local CHASE_TIMEOUT       = 12
local CHASE_REACH_DIST    = 10
local JUMP_DURATION       = 1.4
local POST_JUMP_WAIT      = 1
local RETIRE_WAIT         = 2
local WANDER_INTERVAL     = 2.5
local WANDER_CHANCE       = 0.65

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove     = Trove.new()
local spawnedBunnies = {}
local isActive       = true

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function stickToGround(position: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {
		workspace:FindFirstChild("Map") or workspace,
		workspace.Terrain,
	}
	local result = workspace:Raycast(position + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0), params)
	return result and result.Position + Vector3.new(0, 1, 0) or position
end

local function getWanderParts(): { BasePart }
	local parts = {}
	for _, p in ipairs(WANDER_FOLDER:GetChildren()) do
		if p:IsA("BasePart") then table.insert(parts, p) end
	end
	return parts
end

local function getRandomWanderPart(): BasePart?
	local parts = getWanderParts()
	if #parts == 0 then return nil end
	return parts[math.random(1, #parts)]
end

local function animalHasTrait(animal: Model): boolean
	local json = animal:GetAttribute("Traits")
	if not json then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return false end
	for _, t in ipairs(decoded) do
		if t == TRAIT_NAME then return true end
	end
	return false
end

local function giveTrait(animal: Model)
	local json   = animal:GetAttribute("Traits")
	local traits = {}
	if json then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
		if ok and type(decoded) == "table" then traits = decoded end
	end
	for _, t in ipairs(traits) do
		if t == TRAIT_NAME then return end
	end
	table.insert(traits, TRAIT_NAME)
	animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function removeFromList(bunny)
	local idx = table.find(spawnedBunnies, bunny)
	if idx then
		spawnedBunnies[idx] = spawnedBunnies[#spawnedBunnies]
		spawnedBunnies[#spawnedBunnies] = nil
	end
end

-- ─── Bunny model ──────────────────────────────────────────────────────────────

local function createBunny(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name  = "EasterBunny"
	model:SetAttribute("Scale",   BUNNY_SCALE)
	model:SetAttribute("Moving",  false)
	model:SetAttribute("Jumping", false)

	local anchor = Instance.new("Part")
	anchor.Name         = "AnchorPart"
	anchor.Size         = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CanCollide   = false
	anchor.Anchored     = true
	anchor.CFrame       = CFrame.new(position)
	anchor.Parent       = model

	model.PrimaryPart = anchor
	CollectionService:AddTag(anchor, TAG_NAME)
	model.Parent = workspace
	return model
end

-- ─── Wander ───────────────────────────────────────────────────────────────────

local function wander(bunny)
	if not bunny.Model or not bunny.Model.Parent then return end
	if bunny.IsBusy then return end

	local homePart = bunny.Home
	local size     = homePart.Size
	local offset   = Vector3.new(
		(math.random() - 0.5) * size.X,
		0,
		(math.random() - 0.5) * size.Z
	)

	local targetPos = stickToGround(homePart.Position + offset)
	local startPos  = bunny.Model:GetPivot().Position
	local diff      = targetPos - startPos
	local distance  = diff.Magnitude
	if distance < 1 then return end

	local direction = diff.Unit
	local duration  = distance / HOP_SPEED

	bunny.wanderGen = (bunny.wanderGen or 0) + 1
	local myGen = bunny.wanderGen

	bunny.Model:SetAttribute("Moving", true)

	bunny.Trove:Add(task.spawn(function()
		local elapsed = 0
		while elapsed < duration and not bunny.IsBusy and isActive and bunny.Model and bunny.Model.Parent do
			local dt = task.wait()
			elapsed += dt
			local alpha = math.clamp(elapsed / duration, 0, 1)
			local pos   = stickToGround(startPos:Lerp(targetPos, alpha))
			bunny.Model:PivotTo(CFrame.new(pos, pos + direction))
		end
		if bunny.Model and bunny.Model.Parent
			and bunny.wanderGen == myGen
			and not bunny.IsBusy
		then
			bunny.Model:SetAttribute("Moving", false)
		end
	end))
end

-- ─── Retire + respawn ─────────────────────────────────────────────────────────

local spawnBunny

local function retireAndRespawn(bunny)
	removeFromList(bunny)

	bunny.Trove:Add(task.delay(RETIRE_WAIT, function()
		eventTrove:Remove(bunny.Trove)

		if not isActive then return end
		local wp = getRandomWanderPart()
		if wp then spawnBunny(wp) end
	end))
end

-- ─── Jump + give trait ────────────────────────────────────────────────────────

local function jumpAndGiveTrait(bunny, targetAnimal: Model)
	if not bunny.Model or not bunny.Model.Parent then return end
	if bunny.IsBusy then return end

	bunny.IsBusy    = true
	bunny.wanderGen = (bunny.wanderGen or 0) + 1
	bunny.Model:SetAttribute("Moving", false)

	bunny.Trove:Add(task.spawn(function()
		local chaseStart = os.clock()
		local reached    = false

		bunny.Model:SetAttribute("Moving", true)

		while isActive and bunny.Model and bunny.Model.Parent
			and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart
		do
			if os.clock() - chaseStart > CHASE_TIMEOUT then break end

			local myPos  = bunny.Model:GetPivot().Position
			local tgtPos = targetAnimal.PrimaryPart.Position
			local dist   = (tgtPos - myPos).Magnitude

			if dist < CHASE_REACH_DIST then
				reached = true
				break
			end

			local dt     = task.wait()
			local dir    = (tgtPos - myPos).Unit
			local newPos = stickToGround(myPos + dir * math.min(HOP_SPEED * dt, dist))
			bunny.Model:PivotTo(CFrame.new(newPos, newPos + dir))
		end

		bunny.Model:SetAttribute("Moving", false)

		if not reached or not (targetAnimal and targetAnimal.Parent) then
			bunny.IsBusy = false
			return
		end

		bunny.Model:SetAttribute("JumpTarget", targetAnimal.Name)
		bunny.Model:SetAttribute("Jumping",    true)
		task.wait(JUMP_DURATION)

		giveTrait(targetAnimal)

		if bunny.Model and bunny.Model.Parent then
			bunny.Model:SetAttribute("Jumping",    false)
			bunny.Model:SetAttribute("JumpTarget", nil)
		end

		bunny.IsBusy = false
		task.wait(POST_JUMP_WAIT)

		if bunny.Model and bunny.Model.Parent then
			retireAndRespawn(bunny)
		end
	end))
end

-- ─── Spawn ────────────────────────────────────────────────────────────────────

spawnBunny = function(homePart: BasePart)
	if not isActive or not homePart then return end

	local size   = homePart.Size
	local offset = Vector3.new(
		(math.random() - 0.5) * size.X,
		0,
		(math.random() - 0.5) * size.Z
	)
	local pos   = stickToGround(homePart.Position + offset)
	local model = createBunny(pos)

	local bunnyTrove = eventTrove:Extend()
	bunnyTrove:Add(model)

	local bunny = {
		Model     = model,
		Home      = homePart,
		IsBusy    = false,
		wanderGen = 0,
		Trove     = bunnyTrove,
	}

	table.insert(spawnedBunnies, bunny)
	return bunny
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	local elapsed   = workspace:GetServerTimeNow() - startedAt
	local remaining = math.max(0, 0 - elapsed)
	if remaining > 0 then task.wait(remaining) end
	if not isActive then return end

	for _ = 1, TOTAL_BUNNIES do
		local wp = getRandomWanderPart()
		if wp then spawnBunny(wp) end
	end

	if #spawnedBunnies == 0 then
		warn("[Easter] No wander parts found")
		return
	end

	-- Live animal cache
	local cachedAnimals = CollectionService:GetTagged("Animal")
	eventTrove:Add(CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(inst)
		table.insert(cachedAnimals, inst)
	end))
	eventTrove:Add(CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(inst)
		for i = #cachedAnimals, 1, -1 do
			if cachedAnimals[i] == inst then table.remove(cachedAnimals, i) break end
		end
	end))

	-- Wander tick
	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(WANDER_INTERVAL)
			for _, bunny in ipairs(spawnedBunnies) do
				if bunny.Model and bunny.Model.Parent
					and not bunny.IsBusy
					and not bunny.Model:GetAttribute("Moving")
					and math.random() < WANDER_CHANCE
				then
					wander(bunny)
				end
			end
		end
	end))

	-- Attack tick
	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(math.random(ATTACK_COOLDOWN_MIN, ATTACK_COOLDOWN_MAX))
			if not isActive or #spawnedBunnies == 0 then break end

			local candidates = {}
			for _, animal in ipairs(cachedAnimals) do
				if animal.PrimaryPart and not animalHasTrait(animal) then
					table.insert(candidates, animal)
				end
			end
			if #candidates == 0 then continue end

			local free = {}
			for _, bunny in ipairs(spawnedBunnies) do
				if not bunny.IsBusy and bunny.Model and bunny.Model.Parent then
					table.insert(free, bunny)
				end
			end
			if #free == 0 then continue end

			jumpAndGiveTrait(
				free[math.random(1, #free)],
				candidates[math.random(1, #candidates)]
			)
		end
	end))

	-- Cleanup watchdog
	while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
	isActive = false
	eventTrove:Destroy()
	table.clear(spawnedBunnies)
end

task.spawn(main)
