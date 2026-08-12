local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local EffectController = require(ReplicatedStorage.Controllers.EffectController)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local CreateTween      = require(ReplicatedStorage.Packages.CreateTween)

local NpcPathfinding = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"
))()

local EVENT_NAME = "Sammyni Spyderini"
local TAG_NAME   = "SammyniSpyderini"

local WALK_SPEED               = 20
local TOTAL_SPIDERS            = 10
local MAX_SIMULTANEOUS_ATTACKS = 2
local RECENT_TARGET_COOLDOWN   = 30
local MIN_SPAWN_DISTANCE       = 10
local MAX_SPAWN_DISTANCE       = 30
local ATTACK_DISTANCE          = 6
local CHASE_MAX_TIME           = 20
local WANDER_MAX_TIME          = 15
local ATTACK_COOLDOWN_MIN      = 12
local ATTACK_COOLDOWN_MAX      = 15
local ACTIVATION_DELAY         = 7
local GROUND_Y_OFFSET          = 0.9
local EMERGENCE_DELAY          = 0.2
local EMERGENCE_HOLD           = 1.0
local HOLE_EXIT_WAIT           = 2.0
local MIN_IDLE_THRESHOLD       = 0.5
local MAX_IDLE_THRESHOLD       = 3.0
local MIN_WANDERS              = 3
local MAX_WANDERS              = 5

local EventAssets = ReplicatedStorage.Controllers.EventController.Events[EVENT_NAME]
local Sounds      = ReplicatedStorage.Sounds.Events[EVENT_NAME]

local WANDER_FOLDER = workspace:WaitForChild("Events"):WaitForChild("Wander")

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove        = Trove.new()
local spawnedSpiders    = {}
local recentlyTargeted  = {}
local activeAttackCount = 0
local isActive          = true

eventTrove:Add(function()
	EffectController:Activate("Blink")
end)

-- ─── Helpers ──────────────────────────────────────────────────────────────────

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

local function randomPointInPart(part: BasePart): Vector3
	local s = part.Size
	return part.Position + Vector3.new(
		(math.random() - 0.5) * s.X,
		0,
		(math.random() - 0.5) * s.Z
	)
end

local function getRandomPositionNearTarget(target: Model): Vector3?
	if not target or not target.PrimaryPart then return nil end
	local wanderParts = getWanderParts()
	if #wanderParts == 0 then return nil end
	local targetPos = target.PrimaryPart.Position
	for _ = 1, 20 do
		local wp  = wanderParts[math.random(1, #wanderParts)]
		local pos = NpcPathfinding.stickToGround(randomPointInPart(wp), GROUND_Y_OFFSET)
		local d   = (pos - targetPos).Magnitude
		if d >= MIN_SPAWN_DISTANCE and d <= MAX_SPAWN_DISTANCE then return pos end
	end
	local angle    = math.random() * math.pi * 2
	local d        = math.random(MIN_SPAWN_DISTANCE, MAX_SPAWN_DISTANCE)
	local fallback = targetPos + Vector3.new(math.cos(angle) * d, 0, math.sin(angle) * d)
	return NpcPathfinding.stickToGround(fallback, GROUND_Y_OFFSET)
end

local function createHole(position: Vector3, duration: number)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { workspace:FindFirstChild("Map"), workspace:FindFirstChild("Plots") }

	local hitPos = position
	local result = workspace:Raycast(position, Vector3.new(0, -25, 0), rayParams)
	if result then hitPos = result.Position end

	local hole = EventAssets:FindFirstChild("Hole") and EventAssets.Hole:Clone()
		or Instance.new("Part")
	hole.CFrame = CFrame.new(hitPos + Vector3.new(0, 0.01, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	hole.Size   = Vector3.new(0.01, 0.01, 0.01)
	hole.Parent = workspace

	CreateTween(hole, TweenInfo.new(0.75, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.01, 8, 8)
	})
	task.delay(duration, function()
		CreateTween(hole, TweenInfo.new(0.75, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
			Size = Vector3.new(0.01, 0.01, 0.01)
		}).Completed:Wait()
		hole:Destroy()
	end)
end

local function hasSpiderTrait(animal: Model): boolean
	return animal:GetAttribute("HasSpiderTrait") == true
end

local function targetGone(animal: Model): boolean
	if not animal or not animal.Parent or not animal.PrimaryPart then return true end
	if hasSpiderTrait(animal) then return true end
	return false
end

local function removeFromList(spider)
	local idx = table.find(spawnedSpiders, spider)
	if idx then
		spawnedSpiders[idx] = spawnedSpiders[#spawnedSpiders]
		spawnedSpiders[#spawnedSpiders] = nil
	end
end

-- ─── Spider model ─────────────────────────────────────────────────────────────

local function createSpider(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name  = "SammyniSpyderini"

	local root = Instance.new("Part")
	root.Name         = "HumanoidRootPart"
	root.Size         = Vector3.new(2, 2, 2)
	root.Transparency = 1
	root.Anchored     = true
	root.CanCollide   = false
	root.CanQuery     = false
	root.CanTouch     = false
	root.CFrame       = CFrame.new(position)
	root.Parent       = model

	model.PrimaryPart = root
	model:SetAttribute("IsRunning",       false)
	model:SetAttribute("Ground",          false)
	model:SetAttribute("InitialGround",   true)
	model:SetAttribute("AttackAnimation", false)

	CollectionService:AddTag(model, TAG_NAME)

	local visual = EventAssets["Sammyni Spyderini"]:Clone()
	local weld   = Instance.new("Weld")
	weld.Part0   = visual.PrimaryPart
	weld.Part1   = root
	weld.C0      = CFrame.Angles(0, math.pi, 0)
	weld.Parent  = visual.PrimaryPart
	visual.Parent = model

	local animController = visual:FindFirstChildOfClass("AnimationController")
	local animator = animController and animController:FindFirstChildOfClass("Animator")

	local idle, walk, attack, ground, initialGround, jump
	local flag = nil

	if animator then
		local function loadAnim(name)
			local a = EventAssets:FindFirstChild(name)
			return a and animator:LoadAnimation(a) or nil
		end
		idle          = loadAnim("Idle")
		walk          = loadAnim("Walk")
		attack        = loadAnim("Attack")
		ground        = loadAnim("Ground")
		initialGround = loadAnim("InitialGround")
		jump          = loadAnim("Jump")

		if idle then
			idle.Priority = Enum.AnimationPriority.Idle
			idle:Play()
		end
		if walk then
			walk.Priority = Enum.AnimationPriority.Movement
		end
		if ground then
			ground.Looped = true
			ground:GetMarkerReachedSignal("Freeze"):Connect(function()
				ground:AdjustSpeed(0)
			end)
		end
		if initialGround then
			initialGround.Looped = true
			initialGround:GetMarkerReachedSignal("Freeze"):Connect(function()
				initialGround:AdjustSpeed(0)
			end)
		end
	end

	local function updateGround()
		if model:GetAttribute("InitialGround") then
			flag = true
			SoundController:PlaySound(Sounds:FindFirstChild("EnterHole"), root.Position, false)
			createHole(root.Position, 1.5)
			if initialGround and not initialGround.IsPlaying then
				initialGround:Play()
			end
		elseif model:GetAttribute("Ground") then
			SoundController:PlaySound(Sounds:FindFirstChild("EnterHole"), root.Position, false)
			createHole(root.Position, 1.5)
			if ground then
				if ground.IsPlaying then
					flag = false
					return
				end
				if flag then ground.TimePosition = 0.6 end
				ground:Play(flag and 0 or nil)
				if flag then ground.TimePosition = 0.6 end
			end
			flag = false
		else
			flag = false
			SoundController:PlaySound(Sounds:FindFirstChild("LeaveHole"), root.Position, false)
			createHole(root.Position, 1.5)
			if jump          then jump:Play()          end
			if ground        then ground:Stop()        end
			if initialGround then initialGround:Stop() end
		end
	end

	task.defer(function()
		if model:GetAttribute("IsRunning") and walk then walk:Play() end
	end)

	model:GetAttributeChangedSignal("IsRunning"):Connect(function()
		if not walk then return end
		if model:GetAttribute("IsRunning") then walk:Play() else walk:Stop() end
	end)

	-- matches controller exactly: only Play on true, no Stop on false
	model:GetAttributeChangedSignal("AttackAnimation"):Connect(function()
		if not attack then return end
		if model:GetAttribute("AttackAnimation") then attack:Play() end
	end)

	model:GetAttributeChangedSignal("Ground"):Connect(updateGround)
	model:GetAttributeChangedSignal("InitialGround"):Connect(updateGround)

	if model:GetAttribute("Ground") and ground and not ground.IsPlaying then
		ground.TimePosition = 0.6
		ground:Play(0)
		ground.TimePosition = 0.6
	end
	if model:GetAttribute("InitialGround") and initialGround and not initialGround.IsPlaying then
		flag = true
		initialGround:Play()
	end

	return model
end

-- ─── Behavior ─────────────────────────────────────────────────────────────────

local spawnAndEmergeSpider
local retireSpider

local function startBehavior(spider, stateName, behaviorFn)
	spider.BehaviorTrove:Clean()
	if spider.Model and spider.Model.Parent then
		spider.Model:SetAttribute("IsRunning", false)
	end
	spider.State = stateName
	spider.BehaviorTrove:Add(task.spawn(function()
		local ok, err = pcall(behaviorFn, spider)
		if not ok then
			warn(("[Sammyni Spyderini] '%s' errored: %s"):format(stateName, tostring(err)))
		end
		if spider.State == stateName then
			spider.State = "Idle"
			if spider.Model and spider.Model.Parent then
				spider.Model:SetAttribute("IsRunning", false)
			end
		end
	end))
end

retireSpider = function(spider)
	if spider.State == "Retiring" or spider.State == "Dead" then return end
	spider.State = "Retiring"
	spider.BehaviorTrove:Clean()

	local model = spider.Model
	if model and model.Parent then
		model:SetAttribute("IsRunning", false)
		model:SetAttribute("Ground",    true)
	end

	-- tracked in spider.Trove so eventTrove:Destroy() cancels it before it fires
	spider.Trove:Add(task.delay(HOLE_EXIT_WAIT, function()
		local wasAttack     = spider.IsAttack
		local wasWanderPart = spider.WanderPart

		removeFromList(spider)
		spider.State = "Dead"

		eventTrove:Remove(spider.Trove)

		if isActive and not wasAttack then
			local wp = (wasWanderPart and wasWanderPart.Parent) and wasWanderPart or getRandomWanderPart()
			if wp then spawnAndEmergeSpider(wp) end
		end
	end))
end

local function doWander(spider)
	local wp = spider.WanderPart
	if not wp or not wp.Parent then
		wp = getRandomWanderPart()
		spider.WanderPart = wp
	end
	if not wp then return end

	local targetPos = NpcPathfinding.stickToGround(randomPointInPart(wp), GROUND_Y_OFFSET)
	spider.Model:SetAttribute("IsRunning", true)
	NpcPathfinding.moveTo(spider.Model, targetPos, WALK_SPEED, {
		yOffset    = GROUND_Y_OFFSET,
		maxTime    = WANDER_MAX_TIME,
		shouldStop = function() return not isActive end,
	})
	spider.WanderCount = spider.WanderCount + 1
	spider.LastMoved   = os.clock()
end

local function doAttack(spider)
	local model  = spider.Model
	local target = spider.Target
	if not model or not target then return end

	model:SetAttribute("IsRunning", true)
	local reached = NpcPathfinding.chase(
		model,
		function()
			if targetGone(target) then return nil end
			return target.PrimaryPart.Position
		end,
		WALK_SPEED,
		ATTACK_DISTANCE,
		CHASE_MAX_TIME,
		{
			yOffset    = GROUND_Y_OFFSET,
			shouldStop = function() return not isActive end,
		}
	)

	if not reached or not isActive or targetGone(target) then
		if isActive then retireSpider(spider) end
		return
	end

	model:SetAttribute("IsRunning", false)

	local myPos    = model.PrimaryPart.Position
	local toTarget = target.PrimaryPart.Position - myPos
	local flat     = Vector3.new(toTarget.X, 0, toTarget.Z)
	if flat.Magnitude > 0.1 then
		model:PivotTo(CFrame.lookAt(myPos, myPos + flat.Unit))
	end
	task.wait(0.1)

	model:SetAttribute("AttackAnimation", true)
	task.wait(0.5)

	if isActive and not targetGone(target) then
		local traits = {}
		local tj = target:GetAttribute("Traits")
		if tj then
			local ok, decoded = pcall(HttpService.JSONDecode, HttpService, tj)
			if ok and type(decoded) == "table" then traits = decoded end
		end
		local already = false
		for _, t in ipairs(traits) do if t == "Spider" then already = true break end end
		if not already then
			table.insert(traits, "Spider")
			target:SetAttribute("Traits", HttpService:JSONEncode(traits))
		end
		target:SetAttribute("HasSpiderTrait", true)
	end

	task.wait(0.5)
	if model.Parent then model:SetAttribute("AttackAnimation", false) end
	task.wait(0.3)
	if isActive then retireSpider(spider) end
end

-- ─── Spawn ────────────────────────────────────────────────────────────────────

spawnAndEmergeSpider = function(wanderPart: BasePart)
	if not isActive or not wanderPart then return nil end

	local spawnPos    = NpcPathfinding.stickToGround(randomPointInPart(wanderPart), GROUND_Y_OFFSET)
	local model       = createSpider(spawnPos)
	local spiderTrove = eventTrove:Extend()
	spiderTrove:Add(model)

	local spider = {
		Model         = model,
		WanderPart    = wanderPart,
		Trove         = spiderTrove,
		BehaviorTrove = spiderTrove:Extend(),
		State         = "Emerging",
		IsAttack      = false,
		WanderCount   = 0,
		MaxWanders    = math.random(MIN_WANDERS, MAX_WANDERS),
		LastMoved     = math.huge,
		IdleThreshold = MIN_IDLE_THRESHOLD + math.random() * (MAX_IDLE_THRESHOLD - MIN_IDLE_THRESHOLD),
	}

	model.Parent = workspace
	table.insert(spawnedSpiders, spider)

	spiderTrove:Add(task.spawn(function()
		task.wait(EMERGENCE_DELAY)
		if not isActive or not model.Parent then return end
		model:SetAttribute("InitialGround", false)

		task.wait(EMERGENCE_HOLD)
		if not isActive or not model.Parent then return end

		spider.State     = "Idle"
		spider.LastMoved = os.clock()
	end))

	return spider
end

local function spawnAttackSpider(target: Model)
	if activeAttackCount >= MAX_SIMULTANEOUS_ATTACKS then return end
	if not isActive then return end
	if not target or not target.Parent or not target.PrimaryPart then return end

	local spawnPos = getRandomPositionNearTarget(target)
	if not spawnPos then return end

	local model       = createSpider(spawnPos)
	local spiderTrove = eventTrove:Extend()
	spiderTrove:Add(model)

	local spider = {
		Model         = model,
		WanderPart    = nil,
		Trove         = spiderTrove,
		BehaviorTrove = spiderTrove:Extend(),
		State         = "Emerging",
		IsAttack      = true,
		Target        = target,
	}

	target:SetAttribute("TargetedBy", model.Name)
	activeAttackCount += 1

	spiderTrove:Add(function()
		if target and target.Parent then
			target:SetAttribute("TargetedBy", nil)
		end
		activeAttackCount = math.max(0, activeAttackCount - 1)
	end)

	model.Parent = workspace
	table.insert(spawnedSpiders, spider)

	spiderTrove:Add(task.spawn(function()
		task.wait(EMERGENCE_DELAY)
		if not isActive or not model.Parent then return end
		model:SetAttribute("InitialGround", false)

		task.wait(EMERGENCE_HOLD)
		if not isActive or not model.Parent then return end

		spider.State = "Idle"
		startBehavior(spider, "Attack", doAttack)
	end))

	return spider
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	task.wait(ACTIVATION_DELAY)
	if not isActive then return end

	for _ = 1, TOTAL_SPIDERS do
		local wp = getRandomWanderPart()
		if wp then spawnAndEmergeSpider(wp) end
	end

	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(0.25)
			local now = os.clock()
			for _, spider in ipairs(spawnedSpiders) do
				if spider.IsAttack then continue end
				if spider.State ~= "Idle" then continue end
				if not spider.Model or not spider.Model.Parent then continue end

				if spider.WanderCount >= spider.MaxWanders then
					retireSpider(spider)
					continue
				end

				if now - spider.LastMoved >= spider.IdleThreshold then
					spider.IdleThreshold = MIN_IDLE_THRESHOLD
						+ math.random() * (MAX_IDLE_THRESHOLD - MIN_IDLE_THRESHOLD)
					startBehavior(spider, "Wander", doWander)
				end
			end
		end
	end))

	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(math.random(ATTACK_COOLDOWN_MIN, ATTACK_COOLDOWN_MAX))
			if not isActive then break end
			if activeAttackCount >= MAX_SIMULTANEOUS_ATTACKS then continue end

			local now = os.clock()
			for name, last in pairs(recentlyTargeted) do
				if now - last > RECENT_TARGET_COOLDOWN then recentlyTargeted[name] = nil end
			end

			local candidates = {}
			for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
				if animal.PrimaryPart
					and not hasSpiderTrait(animal)
					and animal:GetAttribute("TargetedBy") == nil
					and not recentlyTargeted[animal.Name]
				then
					table.insert(candidates, animal)
				end
			end

			if #candidates > 0 then
				local selected = candidates[math.random(1, #candidates)]
				recentlyTargeted[selected.Name] = now
				spawnAttackSpider(selected)
			end
		end
	end))

	while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end

	isActive = false
	eventTrove:Destroy()
	table.clear(spawnedSpiders)
	table.clear(recentlyTargeted)
	activeAttackCount = 0
end

task.spawn(main)
