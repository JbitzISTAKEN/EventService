-- LocalScript: AyMiGatitoLogic
-- StarterPlayerScripts

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local Trove      = require(ReplicatedStorage.Packages.Trove)
local Observers  = require(ReplicatedStorage.Packages.Observers)

-- pathfinding from the provided module
local NpcPathfinding = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"
))()

local EventScript = ReplicatedStorage.Controllers.EventController.Events["Ay Mi Gatito"]

-- ─── Config — mirrors server constants exactly ────────────────────────────────

local TAG_NAME           = "Gatito"
local VARIANTS           = { "Angry Gatito", "Crying Gatito" }
local BLOCKING_TRAIT     = ":3"
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

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove     = Trove.new()
local isActive       = true
local spawnedEntities: {{Model: Model, Home: BasePart}} = {}
local lockedTargets: {[Instance]: boolean}              = {}
local variantIndex   = 1
local rng            = Random.new()

-- ─── Trait helpers ────────────────────────────────────────────────────────────

local function getTraits(animal: Instance): ({string}, {[string]: boolean})
	local json = animal:GetAttribute("Traits")
	if not json then return {}, {} end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return {}, {} end
	local set = {}
	for _, t in ipairs(decoded) do set[t] = true end
	return decoded, set
end

local function hasBlockingTrait(animal: Instance): boolean
	local _, set = getTraits(animal)
	return set[BLOCKING_TRAIT] == true
end

local function applyBlockingTrait(animal: Instance)
	local traits, set = getTraits(animal)
	if set[BLOCKING_TRAIT] then return end
	table.insert(traits, BLOCKING_TRAIT)
	local ok, enc = pcall(HttpService.JSONEncode, HttpService, traits)
	if ok then animal:SetAttribute("Traits", enc) end
end

-- ─── stickToGround ───────────────────────────────────────────────────────────

local function stickToGround(pos: Vector3): Vector3
	local result = workspace:Raycast(
		pos + Vector3.new(0, 5, 0),
		Vector3.new(0, -50, 0),
		RaycastParams.new()
	)
	return result and result.Position or pos
end

-- ─── Gatito model setup — mirrors initGatitoObserver from decompiled ──────────

local function setupGatitoVisuals(model: Model)
	-- clone the visual model from EventScript.Gatitos, same as decompiled
	local variantName  = model:GetAttribute("Variant") or "Gatito"
	local sourceModel  = EventScript:FindFirstChild("Gatitos")
		and EventScript.Gatitos:FindFirstChild(variantName)
		or  (EventScript:FindFirstChild("Gatitos") and EventScript.Gatitos:FindFirstChild("Gatito"))

	if not sourceModel then
		warn("[AyMiGatito] Could not find Gatito visual model:", variantName)
		return
	end

	local gatitoTrove = eventTrove:Extend()
	local visual      = gatitoTrove:Clone(sourceModel)

	-- weld visual to HumanoidRootPart — mirrors decompiled weld setup
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		gatitoTrove:Clean()
		return
	end

	local weld    = gatitoTrove:Add(Instance.new("Weld"))
	weld.Part0    = visual.PrimaryPart
	weld.Part1    = root
	weld.Parent   = visual.PrimaryPart
	visual.Parent = model

	-- replace AnimationController with Humanoid+Animator — mirrors decompiled exactly
	local oldAC = visual:FindFirstChild("AnimationController")
	if oldAC then oldAC:Destroy() end

	local hum = Instance.new("Humanoid", visual)
	hum.Name                  = "AnimationController"
	hum.EvaluateStateMachine  = false
	hum.DisplayDistanceType   = Enum.HumanoidDisplayDistanceType.None
	hum.PlatformStand         = true
	Instance.new("Animator", hum)

	local animator = hum.Animator

	-- load animations
	local danceTrack: AnimationTrack? = nil
	local walkTrack:  AnimationTrack? = nil
	local idleTrack:  AnimationTrack? = nil

	local GatitoDance1 = EventScript:FindFirstChild("GatitoDance1")
	local GatitoWalk   = EventScript:FindFirstChild("GatitoWalk")
	local GatitoIdle   = EventScript:FindFirstChild("GatitoIdle")

	if GatitoDance1 then
		local t = animator:LoadAnimation(GatitoDance1)
		t.Looped   = true
		t.Priority = Enum.AnimationPriority.Action
		danceTrack = t
		gatitoTrove:Add(function() t:Stop(0) t:Destroy() end)
	end
	if GatitoWalk then
		local t = animator:LoadAnimation(GatitoWalk)
		t.Priority = Enum.AnimationPriority.Action2
		walkTrack  = t
		gatitoTrove:Add(function() t:Stop(0) t:Destroy() end)
	end
	if GatitoIdle then
		local t = animator:LoadAnimation(GatitoIdle)
		t.Looped   = true
		t.Priority = Enum.AnimationPriority.Idle
		idleTrack  = t
		gatitoTrove:Add(function() t:Stop(0) t:Destroy() end)
	end

	-- attack animation on attribute change — mirrors decompiled AttackAnimation signal
	gatitoTrove:Add(model:GetAttributeChangedSignal("AttackAnimation"):Connect(function()
		if not model:GetAttribute("AttackAnimation") then return end
		local GatitoAttack = EventScript:FindFirstChild("GatitoAttack")
		if not GatitoAttack then return end
		local t = animator:LoadAnimation(GatitoAttack)
		t.Looped   = false
		t.Priority = Enum.AnimationPriority.Action4
		t:Play()
		gatitoTrove:Add(function() t:Stop(0) t:Destroy() end)
	end))

	-- IsRunning observer — mirrors decompiled observeAttribute("IsRunning")
	gatitoTrove:Add(model:GetAttributeChangedSignal("IsRunning"):Connect(function()
		local running = model:GetAttribute("IsRunning")
		if running then
			if walkTrack  then walkTrack:Play()  end
			if idleTrack  and idleTrack.IsPlaying  then idleTrack:Stop()  end
			if danceTrack and danceTrack.IsPlaying then danceTrack:Stop() end
		else
			if walkTrack then walkTrack:Stop() end
			if danceTrack and model:GetAttribute("Dance") and not danceTrack.IsPlaying then
				danceTrack:Play()
			end
		end
	end))

	-- Dance observer — mirrors decompiled observeAttribute("Dance")
	gatitoTrove:Add(model:GetAttributeChangedSignal("Dance"):Connect(function()
		local dancing = model:GetAttribute("Dance")
		if dancing then
			if idleTrack  and idleTrack.IsPlaying  then idleTrack:Stop()  end
			if danceTrack and not danceTrack.IsPlaying then danceTrack:Play() end
		else
			if danceTrack then danceTrack:Stop() end
			if idleTrack  and not idleTrack.IsPlaying then idleTrack:Play() end
		end
	end))

	-- start dance immediately if Dance attr is set
	if model:GetAttribute("Dance") and danceTrack then
		danceTrack:Play()
	end

	-- animation speed controller — mirrors PostSimulation speed adjust from decompiled
	-- uses startedAt from the event data baked in at start
	local startedAt = ReplicatedStorage:GetAttribute("AyMiGatitoStartedAt") or workspace:GetServerTimeNow()

	gatitoTrove:Add(RunService.PostSimulation:Connect(function()
		local elapsed = workspace:GetServerTimeNow() - startedAt
		local speed

		if elapsed < 7 then
			speed = 0
		elseif elapsed >= 222.313 then
			speed = math.max(0, 1 - (elapsed - 222.313) / 3)
		else
			local cycle = (elapsed - 7) % 72.771
			if     cycle >= 55.5 and cycle < 57  then speed = (cycle - 55.5) / 1.5 * 0.3 + 0.7
			elseif cycle >= 50   and cycle < 55.5 then speed = 0.7
			elseif cycle >= 48   and cycle < 50   then speed = (cycle - 48) / 2 * 0.3 + 0.4
			elseif cycle >= 43   and cycle < 48   then speed = 0.4
			else                                       speed = 1
			end
		end

		if danceTrack and danceTrack.IsPlaying then danceTrack:AdjustSpeed(speed) end
		if walkTrack  and walkTrack.IsPlaying  then walkTrack:AdjustSpeed(speed)  end
		if idleTrack  and idleTrack.IsPlaying  then idleTrack:AdjustSpeed(speed)  end
	end))
end

-- ─── Gatito model factory — mirrors server createGatito() ────────────────────

local function createGatito(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name  = "Gatito"

	local root          = Instance.new("Part")
	root.Name           = "HumanoidRootPart"
	root.Size           = Vector3.new(2, 2, 2)
	root.Transparency   = 1
	root.Anchored       = true
	root.CanCollide     = false
	root.CFrame         = CFrame.new(position)
	root.Parent         = model
	model.PrimaryPart   = root

	local totalOptions  = #VARIANTS + 1
	local randomVariant = VARIANTS[variantIndex]
	if randomVariant then
		model:SetAttribute("Variant", randomVariant)
	end
	model:SetAttribute("Dance",     true)
	model:SetAttribute("IsRunning", false)
	model:SetAttribute("IsChasing", false)

	CollectionService:AddTag(model, TAG_NAME)

	variantIndex = (variantIndex % totalOptions) + 1

	return model
end

-- ─── Wander — mirrors server wander() ────────────────────────────────────────

local function wander(hunterData: {Model: Model, Home: BasePart})
	local entity   = hunterData.Model
	local homePart = hunterData.Home

	if not entity or not entity.PrimaryPart then return end
	if entity:GetAttribute("IsChasing") or entity:GetAttribute("IsRunning") then return end

	local size   = homePart.Size
	local offset = Vector3.new(
		rng:NextNumber(-size.X / 2, size.X / 2),
		0,
		rng:NextNumber(-size.Z / 2, size.Z / 2)
	)

	local targetPos = stickToGround(homePart.Position + offset)
	local startPos  = entity:GetPivot().Position
	local distance  = (targetPos - startPos).Magnitude
	if distance < 1 then return end

	entity:SetAttribute("IsRunning", true)

	local wanderTrove = eventTrove:Extend()
	wanderTrove:Add(task.spawn(function()
		NpcPathfinding.moveTo(entity, targetPos, WANDER_SPEED, {
			maxTime  = math.max(5, distance / WANDER_SPEED + 2),
			shouldStop = function()
				return (not isActive)
					or (not entity.Parent)
					or entity:GetAttribute("IsChasing")
			end,
		})
		if entity.Parent then
			entity:SetAttribute("IsRunning", false)
		end
		wanderTrove:Clean()
	end))
end

-- ─── Chase + attack — mirrors server followAndAttackAnimal() ─────────────────

local function followAndAttackAnimal(gatitoData: {Model: Model, Home: BasePart}, targetAnimal: Instance)
	local gatito = gatitoData.Model
	if not gatito or not gatito.Parent then return end
	if gatito:GetAttribute("IsChasing") then return end
	if lockedTargets[targetAnimal] then return end

	lockedTargets[targetAnimal] = true
	gatito:SetAttribute("IsChasing", true)
	gatito:SetAttribute("IsRunning", true)

	local chaseTrove = eventTrove:Extend()

	chaseTrove:Add(task.spawn(function()
		local reachedTarget = NpcPathfinding.chase(
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

		if reachedTarget and targetAnimal and targetAnimal.Parent then
			gatito:SetAttribute("AttackAnimation", true)

			local elapsed    = 0
			local attackConn: RBXScriptConnection
			attackConn = chaseTrove:Add(RunService.Heartbeat:Connect(function(dt)
				elapsed += dt

				if elapsed >= ATTACK_DURATION
					or not isActive
					or not targetAnimal
					or not targetAnimal.Parent
					or not targetAnimal.PrimaryPart
				then
					chaseTrove:Remove(attackConn)
					attackConn:Disconnect()
					return
				end

				local tPos = targetAnimal.PrimaryPart.Position
				local mPos = gatito.PrimaryPart.Position
				local diff = tPos - mPos
				local dist = diff.Magnitude

				if dist > CHASE_STICK_DIST then
					local dir     = diff.Unit
					local flatDir = Vector3.new(dir.X, 0, dir.Z)
					if flatDir.Magnitude < 1e-4 then return end
					flatDir = flatDir.Unit
					local move   = math.min(CHASE_SPEED * dt, dist)
					local newPos = stickToGround(mPos + dir * move)
					gatito:PivotTo(CFrame.new(newPos, newPos + flatDir))
				end
			end))

			while elapsed < ATTACK_DURATION and isActive do
				task.wait(ATTACK_DURATION - elapsed + 0.016)
			end

			-- burst VFX — local version: playBurst directly instead of remote
			local burstPart = EventScript:FindFirstChild("Burst")
			local rootPart  = targetAnimal.PrimaryPart
			if burstPart and rootPart then
				local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
				ClientEventUtils.playBurst(
					burstPart,
					rootPart,
					{ ReplicatedStorage.Sounds.Events["Ay Mi Gatito"].Hit }
				)
			end

			gatito:SetAttribute("AttackAnimation", false)

			if targetAnimal and targetAnimal.Parent then
				applyBlockingTrait(targetAnimal)
				print("[AyMiGatito] Applied :3 trait to:", targetAnimal.Name)
			end
		end

		lockedTargets[targetAnimal] = nil
		task.wait(POST_ATTACK_WAIT)

		if isActive and gatito and gatito.Parent then
			gatito:SetAttribute("IsChasing", false)
			wander(gatitoData)
		end

		chaseTrove:Clean()
	end))
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	-- wait for event folder
	local wanderFolder = workspace.Events:FindFirstChild("Ay Mi Gatito")
	while not wanderFolder do
		task.wait(0.1)
		wanderFolder = workspace.Events:FindFirstChild("Ay Mi Gatito")
	end

	-- store startedAt for animation speed calc
	local startedAt = workspace:GetServerTimeNow()
	ReplicatedStorage:SetAttribute("AyMiGatitoStartedAt", startedAt)

	-- wait 7s before spawning — mirrors server elapsed/remaining gate
	local gate = 7 - (workspace:GetServerTimeNow() - startedAt)
	if gate > 0 then task.wait(gate) end
	if not isActive then return end

	-- spawn gatitos at each Wander part — mirrors server OnStart spawn block
	for _, part in ipairs(wanderFolder:GetChildren()) do
		if part.Name == "Wander" then
			local size = part.Size
			for _ = 1, GATITOS_PER_WANDER do
				local offset = Vector3.new(
					rng:NextNumber(-size.X / 2, size.X / 2),
					0,
					rng:NextNumber(-size.Z / 2, size.Z / 2)
				)
				local pos    = stickToGround(part.Position + offset)
				local gatito = createGatito(pos)
				eventTrove:Add(gatito)
				gatito.Parent = workspace

				-- setup visuals immediately after parenting
				setupGatitoVisuals(gatito)

				table.insert(spawnedEntities, { Model = gatito, Home = part })
			end
		end
	end

	print("[AyMiGatito] Spawned", #spawnedEntities, "gatitos")

	-- wander loop — mirrors server wander task.spawn loop
	eventTrove:Add(task.spawn(function()
		while isActive do
			for _, hunterData in ipairs(spawnedEntities) do
				local model = hunterData.Model
				if model.Parent
					and not model:GetAttribute("IsChasing")
					and not model:GetAttribute("IsRunning")
				then
					task.delay(rng:NextNumber(0, 2), function()
						if isActive and model.Parent
							and not model:GetAttribute("IsChasing")
							and not model:GetAttribute("IsRunning")
						then
							wander(hunterData)
						end
					end)
				end
			end
			task.wait(WANDER_LOOP_RATE)
		end
	end))

	-- animal cache with live tag tracking — mirrors server cachedAnimals pattern
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

	-- attack loop — mirrors server attack task.spawn loop
	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(rng:NextNumber(ATTACK_LOOP_MIN, ATTACK_LOOP_MAX))
			if not isActive or #spawnedEntities == 0 then break end

			local candidates = {}
			for _, animal in ipairs(cachedAnimals) do
				if animal.PrimaryPart
					and not lockedTargets[animal]
					and not hasBlockingTrait(animal)
				then
					table.insert(candidates, animal)
				end
			end

			if #candidates > 0 then
				local selected   = candidates[rng:NextInteger(1, #candidates)]
				local gatitoData = spawnedEntities[rng:NextInteger(1, #spawnedEntities)]

				if gatitoData.Model and gatitoData.Model.Parent then
					followAndAttackAnimal(gatitoData, selected)
				end
			end
		end
	end))
end

task.spawn(main)
