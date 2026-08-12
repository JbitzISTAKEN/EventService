local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")

local NpcPathfinding = loadstring(game:HttpGet("https://raw.githubusercontent.com/JbitzISTAKEN/EventService/refs/heads/main/NPCPathfinding.lua"))()

local EffectController  = require(ReplicatedStorage.Controllers.EffectController)
local EventController   = require(ReplicatedStorage.Controllers.EventController)
local CycleController   = require(ReplicatedStorage.Controllers.CycleController)
local SoundController   = require(ReplicatedStorage.Controllers.SoundController)
local ClientEventUtils  = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local Trove             = require(ReplicatedStorage.Packages.Trove)

local EventScript = ReplicatedStorage.Controllers.EventController.Events.Spain
local SpainEvent  = workspace.Sounds.SpainEvent
local Sounds      = ReplicatedStorage.Sounds.Events.Spain

local TRAIT_NAME     = "Spain"
local TRAIT_INTERVAL = 5

local BULL_Y_OFFSET            = 3
local BULL_WALK_SPEED          = 16
local BULL_CHARGE_SPEED        = 30
local BULL_CHASE_DISTANCE      = 40
local BULL_ATTACK_DISTANCE     = 6
local BULL_WANDER_MIN          = 4
local BULL_WANDER_MAX          = 8
local BULL_CHARGE_COOLDOWN_MIN = 8
local BULL_CHARGE_COOLDOWN_MAX = 15

local SpainFolder  = workspace.Events:FindFirstChild("Spain")
local SpawnPoints  = SpainFolder and SpainFolder:FindFirstChild("SpawnPoints")
local WalkAreas    = SpainFolder and SpainFolder:FindFirstChild("WalkAreas")

repeat task.wait() until EventController:GetActiveEventData("Spain")
local eventData = EventController:GetActiveEventData("Spain")

local trove      = Trove.new()
local isActive   = true
local spawnedBulls = {}

-- ─── Effects / OST ─────────────────────────────────────────────────────────────

EffectController:Activate("Blink")
CycleController:Update()
SoundController:UpdateOST()

trove:Add(function()
	EffectController:Activate("Blink")
	CycleController:Update()
	SoundController:UpdateOST()
end)

EffectController:Run("SpainEvent", "GrassRecolor")
trove:Add(function() EffectController:Stop("SpainEvent", "GrassRecolor") end)

EffectController:Run("SpainEvent", "WallRecolor")
trove:Add(function() EffectController:Stop("SpainEvent", "WallRecolor") end)

EffectController:Run("SpainEvent", "WallBottomRecolor")
trove:Add(function() EffectController:Stop("SpainEvent", "WallBottomRecolor") end)

-- ─── Spain Map ─────────────────────────────────────────────────────────────────

local SpainMap = EventScript:FindFirstChild("SpainMap")
if SpainMap then
	local mapClone = trove:Clone(SpainMap)
	mapClone.Parent = workspace
end

-- ─── Music ─────────────────────────────────────────────────────────────────────

trove:Add(task.spawn(function()
	if not SpainEvent.IsLoaded then
		SpainEvent.Volume = 0
		SpainEvent:Play()
	end

	while not SpainEvent.IsLoaded do task.wait() end

	SpainEvent.Volume = 0.25
	SpainEvent:Stop()
	SpainEvent.Looped = false

	local elapsed    = workspace:GetServerTimeNow() - eventData.startedAt
	local timeLength = SpainEvent.TimeLength

	if timeLength > 0 and timeLength <= elapsed then return end

	SpainEvent.TimePosition = elapsed
	SpainEvent:Play()
	trove:Add(function() SpainEvent:Stop() end)
end))

-- ─── Burst VFX ─────────────────────────────────────────────────────────────────

local Burst = EventScript:FindFirstChild("Burst")
if not (Burst and Burst:IsA("BasePart")) then
	local b = Instance.new("Part")
	b.Name         = "Burst"
	b.Anchored     = true
	b.CanCollide   = false
	b.CanQuery     = false
	b.CanTouch     = false
	b.Size         = Vector3.new(0.25, 0.25, 0.25)
	b.Transparency = 1

	local pe = Instance.new("ParticleEmitter")
	pe.Name          = "SpainBurst"
	pe.Color         = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(198, 0, 43)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 196, 0)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(198, 0, 43)),
	})
	pe.Drag          = 4
	pe.Enabled       = false
	pe.Lifetime      = NumberRange.new(0.3, 0.55)
	pe.LightEmission = 1
	pe.Rate          = 0
	pe.Rotation      = NumberRange.new(0, 360)
	pe.RotSpeed      = NumberRange.new(-180, 180)
	pe.Size          = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 0) })
	pe.Speed         = NumberRange.new(10, 18)
	pe.SpreadAngle   = Vector2.new(180, 180)
	pe.Texture       = "rbxasset://textures/particles/sparkles_main.dds"
	pe:SetAttribute("EmitCount", 20)
	pe.Parent = b
	Burst = b
end

-- ─── Trait helpers ─────────────────────────────────────────────────────────────

local function hasSpainTrait(animal)
	local json = animal:GetAttribute("Traits")
	if not json then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return false end
	for _, trait in ipairs(decoded) do
		if trait == TRAIT_NAME then return true end
	end
	return false
end

local function fireBurstAt(position)
	ClientEventUtils.playBurst(Burst, position, { Sounds.Burst })
end

local function pickTarget()
	local candidates = {}
	for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
		if animal.PrimaryPart and not hasSpainTrait(animal) then
			table.insert(candidates, animal)
		end
	end
	if #candidates == 0 then return nil end
	return candidates[math.random(1, #candidates)]
end

local function giveSpainTrait(animal)
	if not animal or not animal.PrimaryPart then return end
	if hasSpainTrait(animal) then return end

	local json   = animal:GetAttribute("Traits")
	local traits = {}
	if json then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
		if ok and type(decoded) == "table" then traits = decoded end
	end
	table.insert(traits, TRAIT_NAME)
	animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
	fireBurstAt(animal.PrimaryPart.Position)
end

trove:Add(task.spawn(function()
	while isActive do
		task.wait(TRAIT_INTERVAL)
		if not isActive then break end
		local target = pickTarget()
		if target then giveSpainTrait(target) end
	end
end))

-- ─── Bull visuals ──────────────────────────────────────────────────────────────

local function getVisual()
	local v = EventScript:FindFirstChild("BullVisual")
	if v and v:IsA("BasePart") then return v:Clone() end

	local part = Instance.new("Part")
	part.Name       = "BullVisual"
	part.Size       = Vector3.new(6, 4, 10)
	part.Color      = Color3.fromRGB(198, 0, 43)
	part.Material   = Enum.Material.SmoothPlastic
	part.Anchored   = false
	part.CanCollide = false
	part.CanQuery   = false
	part.CanTouch   = false
	part.Massless   = true
	return part
end

local function loadTrack(model, animName, localTrove)
	local anim = EventScript:FindFirstChild(animName)
	if not anim or not anim:IsA("Animation") or anim.AnimationId == "" then return nil end
	local animator = model:FindFirstChildWhichIsA("Animator", true)
	if not animator then return nil end
	local track = animator:LoadAnimation(anim)
	localTrove:Add(function()
		track:Stop(0)
		track:Destroy()
	end)
	return track
end

-- ─── Bull movement ─────────────────────────────────────────────────────────────

local function getRandomWalkPosition()
	if not WalkAreas then return nil end
	local areas = WalkAreas:GetChildren()
	if #areas == 0 then return nil end
	local area = areas[math.random(1, #areas)]
	if not area:IsA("BasePart") then return nil end
	local size = area.Size
	local cf   = area.CFrame
	local rx   = math.random(-size.X / 2, size.X / 2)
	local rz   = math.random(-size.Z / 2, size.Z / 2)
	local pos  = (cf * CFrame.new(rx, 0, rz)).Position
	return NpcPathfinding.stickToGround(pos, BULL_Y_OFFSET)
end

local function findNearestPlayer(bullModel)
	if not bullModel.PrimaryPart then return nil end
	local bullPos  = bullModel.PrimaryPart.Position
	local nearest  = nil
	local nearDist = BULL_CHASE_DISTANCE

	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				local dist = (char.HumanoidRootPart.Position - bullPos).Magnitude
				if dist < nearDist then
					nearDist = dist
					nearest  = char
				end
			end
		end
	end

	return nearest
end

local function chargeAtTarget(bullData, target)
	if bullData.IsCharging then return end
	bullData.IsCharging = true

	local bull = bullData.Model
	bull:SetAttribute("BullState", "Charge")
	bull:SetAttribute("Walking", false)

	task.spawn(function()
		local reached = NpcPathfinding.chase(
			bull,
			function()
				if target and target.Parent and target:FindFirstChild("HumanoidRootPart") then
					return target.HumanoidRootPart.Position
				end
				return nil
			end,
			BULL_CHARGE_SPEED,
			BULL_ATTACK_DISTANCE,
			15,
			{
				yOffset    = BULL_Y_OFFSET,
				shouldStop = function()
					return (not isActive) or (not bull.Parent) or (not target) or (not target.Parent)
				end,
			}
		)

		if reached and target and target.Parent and bull and bull.Parent then
			bull:SetAttribute("BullState", "Attack")
			bull:SetAttribute("Walking", false)
			task.wait(1)
		end

		if bull and bull.Parent then
			bull:SetAttribute("BullState", "Idle")
			bull:SetAttribute("Walking", false)
		end

		bullData.IsCharging    = false
		bullData.NextChargeTime = os.clock() + math.random(BULL_CHARGE_COOLDOWN_MIN, BULL_CHARGE_COOLDOWN_MAX)
	end)
end

local function wanderBull(bullData)
	local bull = bullData.Model
	if not bull or not bull.Parent or bullData.IsCharging then
		bullData.IsWandering = false
		return
	end

	local targetPos = getRandomWalkPosition()
	if not targetPos then
		bullData.IsWandering   = false
		bullData.NextWanderTime = os.clock() + math.random(BULL_WANDER_MIN, BULL_WANDER_MAX)
		return
	end

	bull:SetAttribute("BullState", "Walk")
	bull:SetAttribute("Walking", true)

	NpcPathfinding.moveTo(bull, targetPos, BULL_WALK_SPEED, {
		maxTime    = 20,
		yOffset    = BULL_Y_OFFSET,
		shouldStop = function()
			return (not isActive) or (not bull.Parent) or bullData.IsCharging
		end,
	})

	if bull and bull.Parent and not bullData.IsCharging then
		bull:SetAttribute("BullState", "Idle")
		bull:SetAttribute("Walking", false)
	end

	bullData.IsWandering   = false
	bullData.NextWanderTime = os.clock() + math.random(BULL_WANDER_MIN, BULL_WANDER_MAX)
end

-- ─── Bull spawning ─────────────────────────────────────────────────────────────

local function spawnBull(position)
	local bullTrove = trove:Extend()

	-- invisible root model
	local bull = Instance.new("Model")
	bull.Name  = "SpainBull"

	local rootPart = Instance.new("Part")
	rootPart.Name        = "RootPart"
	rootPart.Size        = Vector3.new(4, 4, 8)
	rootPart.Transparency = 1
	rootPart.CanCollide  = false
	rootPart.Anchored    = true
	rootPart.CFrame      = CFrame.new(position)
	rootPart.Parent      = bull

	bull.PrimaryPart = rootPart
	bull:SetAttribute("BullState", "Idle")
	bull:SetAttribute("Walking", false)
	bull.Parent = workspace
	bullTrove:Add(bull)

	-- visual welded onto root
	local visual = bullTrove:Add(getVisual())
	visual.CFrame = rootPart.CFrame

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

	visual.Parent = bull

	local weld = bullTrove:Add(Instance.new("Weld"))
	weld.Part0  = rootPart
	weld.Part1  = visual
	weld.C0     = CFrame.identity
	weld.C1     = CFrame.identity
	weld.Parent = visual

	-- animations
	local tracks = {}
	for _, animName in ipairs({ "Idle", "Walk", "Run", "RunAttack", "Charge", "Attack" }) do
		local track = loadTrack(visual, animName, bullTrove)
		if track then
			track.Looped   = animName ~= "Charge" and animName ~= "Attack"
			track.Priority = (animName == "Charge" or animName == "Attack")
				and Enum.AnimationPriority.Action3
				or  (animName == "Idle" and Enum.AnimationPriority.Action or Enum.AnimationPriority.Action2)
			tracks[animName] = track
		end
	end

	local function resolveTrack()
		local state = bull:GetAttribute("BullState")
		if state == "Charge"    then return tracks.Charge end
		if state == "Attack"    then return tracks.Attack end
		if state == "RunAttack" then return tracks.RunAttack or tracks.Run or tracks.Walk end
		if state == "Run"       then return tracks.Run or tracks.Walk end
		if state == "Walk" and bull:GetAttribute("Walking") == true then return tracks.Walk end
		return tracks.Idle
	end

	local currentTrack = nil
	local function updateTrack()
		local next = resolveTrack()
		if next == currentTrack then return end
		if currentTrack and currentTrack.IsPlaying then currentTrack:Stop(0.25) end
		currentTrack = next
		if next then next:Play(0.25) end
	end

	updateTrack()
	bullTrove:Add(bull:GetAttributeChangedSignal("BullState"):Connect(updateTrack))
	bullTrove:Add(bull:GetAttributeChangedSignal("Walking"):Connect(updateTrack))

	local bullData = {
		Model          = bull,
		IsWandering    = false,
		IsCharging     = false,
		NextWanderTime = os.clock() + math.random(BULL_WANDER_MIN, BULL_WANDER_MAX),
		NextChargeTime = os.clock() + math.random(BULL_CHARGE_COOLDOWN_MIN, BULL_CHARGE_COOLDOWN_MAX),
	}
	table.insert(spawnedBulls, bullData)
end

local function spawnAllBulls()
	if not SpawnPoints then
		warn("[Spain] workspace.Events.Spain.SpawnPoints not found")
		return
	end
	for _, spawnPoint in ipairs(SpawnPoints:GetChildren()) do
		if spawnPoint:IsA("BasePart") then
			local pos = NpcPathfinding.stickToGround(spawnPoint.Position, BULL_Y_OFFSET)
			spawnBull(pos)
		end
	end
end

spawnAllBulls()

-- ─── Bull AI loop ──────────────────────────────────────────────────────────────

trove:Add(task.spawn(function()
	while isActive do
		task.wait(1)
		local now = os.clock()

		for _, bullData in ipairs(spawnedBulls) do
			local bull = bullData.Model
			if not bull or not bull.Parent then continue end
			if bullData.IsCharging or bullData.IsWandering then continue end

			if now >= bullData.NextChargeTime then
				local target = findNearestPlayer(bull)
				if target then
					chargeAtTarget(bullData, target)
				else
					bullData.NextChargeTime = now + 3
				end
			elseif now >= bullData.NextWanderTime then
				bullData.IsWandering = true
				task.spawn(function() wanderBull(bullData) end)
			end
		end
	end
end))

-- ─── Cleanup ───────────────────────────────────────────────────────────────────

task.spawn(function()
	while EventController:GetActiveEventData("Spain") do task.wait(1) end
	isActive = false
	spawnedBulls = {}
	trove:Destroy()
end)
