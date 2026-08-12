local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local EffectController  = require(ReplicatedStorage.Controllers.EffectController)
local EventController   = require(ReplicatedStorage.Controllers.EventController)
local CycleController   = require(ReplicatedStorage.Controllers.CycleController)
local SoundController   = require(ReplicatedStorage.Controllers.SoundController)
local ClientEventUtils  = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local Observers         = require(ReplicatedStorage.Packages.Observers)
local Trove             = require(ReplicatedStorage.Packages.Trove)
local VFX               = require(ReplicatedStorage.Shared.VFX)

local EventScript  = ReplicatedStorage.Controllers.EventController.Events.Spain
local SpainEvent   = workspace.Sounds.SpainEvent
local Sounds       = ReplicatedStorage.Sounds.Events.Spain

local TRAIT_NAME     = "Spain"
local TRAIT_INTERVAL = 5

-- ─── Gate ─────────────────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData("Spain")
local eventData = EventController:GetActiveEventData("Spain")

local trove = Trove.new()

-- ─── Effects / OST ────────────────────────────────────────────────────────────

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

-- ─── Music ────────────────────────────────────────────────────────────────────

trove:Add(task.spawn(function()
	if not SpainEvent.IsLoaded then
		SpainEvent.Volume = 0
		SpainEvent:Play()
	end

	while not SpainEvent.IsLoaded do task.wait() end

	SpainEvent.Volume = 0.25
	SpainEvent:Stop()
	SpainEvent.Looped = false

	local elapsed = workspace:GetServerTimeNow() - eventData.startedAt
	local timeLength = SpainEvent.TimeLength

	if timeLength > 0 and timeLength <= elapsed then return end

	SpainEvent.TimePosition = elapsed
	SpainEvent:Play()
	trove:Add(function() SpainEvent:Stop() end)
end))

-- ─── Burst VFX (local, no remote) ─────────────────────────────────────────────

local Burst = EventScript:FindFirstChild("Burst")
if not (Burst and Burst:IsA("BasePart")) then
	local b = Instance.new("Part")
	b.Name = "Burst"
	b.Anchored = true
	b.CanCollide = false
	b.CanQuery = false
	b.CanTouch = false
	b.Size = Vector3.new(0.25, 0.25, 0.25)
	b.Transparency = 1
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "SpainBurst"
	pe.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(198, 0, 43)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 196, 0)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(198, 0, 43)),
	})
	pe.Drag = 4
	pe.Enabled = false
	pe.Lifetime = NumberRange.new(0.3, 0.55)
	pe.LightEmission = 1
	pe.Rate = 0
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-180, 180)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 0) })
	pe.Speed = NumberRange.new(10, 18)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe:SetAttribute("EmitCount", 20)
	pe.Parent = b
	Burst = b
end

local function fireBurstAt(position)
	ClientEventUtils.playBurst(Burst, position, { Sounds.Burst })
end

-- ─── Trait helpers (client-side attribute write) ───────────────────────────────

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

local function giveSpainTrait(animal)
	if not animal or not animal.PrimaryPart then return end
	if hasSpainTrait(animal) then return end

	local json = animal:GetAttribute("Traits")
	local traits = {}
	if json then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
		if ok and type(decoded) == "table" then traits = decoded end
	end
	table.insert(traits, TRAIT_NAME)
	animal:SetAttribute("Traits", HttpService:JSONEncode(traits))

	fireBurstAt(animal.PrimaryPart.Position)
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

-- ─── Bull visuals (Observers.observeTag — same as decompiled client) ───────────

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

local function getVisual()
	local v = EventScript:FindFirstChild("BullVisual")
	if v and v:IsA("BasePart") then return v:Clone() end
	local part = Instance.new("Part")
	part.Name = "BullVisual"
	part.Size = Vector3.new(6, 4, 10)
	part.Color = Color3.fromRGB(198, 0, 43)
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	return part
end

trove:Add(Observers.observeTag("SpainBull", function(p1)
	if not p1:IsA("Model") then return nil end

	local bullTrove = Trove.new()

	bullTrove:Add(task.spawn(function()
		local RootPart = p1:WaitForChild("RootPart", 10)
		if not (RootPart and RootPart:IsA("BasePart") and p1.Parent) then return end

		local visual = bullTrove:Add(getVisual())
		visual.Anchored = false
		visual.CanCollide = false
		visual.CanQuery = false
		visual.CanTouch = false
		visual.Massless = true

		for _, desc in ipairs(visual:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Anchored = false
				desc.CanCollide = false
				desc.CanQuery = false
				desc.CanTouch = false
				desc.Massless = true
			elseif desc:IsA("Humanoid") then
				desc.EvaluateStateMachine = false
				desc.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
				desc.PlatformStand = true
			end
		end

		visual.CFrame = RootPart.CFrame
		visual.Parent = p1

		local weld = bullTrove:Add(Instance.new("Weld"))
		weld.Part0 = RootPart
		weld.Part1 = visual
		weld.C0 = CFrame.identity
		weld.C1 = CFrame.identity
		weld.Parent = visual

		local tracks = {}
		for _, animName in ipairs({ "Idle", "Walk", "Run", "RunAttack", "Charge", "Attack" }) do
			local track = loadTrack(visual, animName, bullTrove)
			if track then
				track.Looped = animName ~= "Charge" and animName ~= "Attack"
				track.Priority = (animName == "Charge" or animName == "Attack")
					and Enum.AnimationPriority.Action3
					or (animName == "Idle" and Enum.AnimationPriority.Action or Enum.AnimationPriority.Action2)
				tracks[animName] = track
			end
		end

		local function resolveTrack()
			local state = p1:GetAttribute("BullState")
			if state == "Charge"     then return tracks.Charge end
			if state == "Attack"     then return tracks.Attack end
			if state == "RunAttack"  then return tracks.RunAttack or tracks.Run or tracks.Walk end
			if state == "Run"        then return tracks.Run or tracks.Walk end
			if state == "Walk" and p1:GetAttribute("Walking") == true then return tracks.Walk end
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
		bullTrove:Add(p1:GetAttributeChangedSignal("BullState"):Connect(updateTrack))
		bullTrove:Add(p1:GetAttributeChangedSignal("Walking"):Connect(updateTrack))
	end))

	return bullTrove:WrapClean()
end, { workspace }))

-- ─── Trait loop ───────────────────────────────────────────────────────────────

trove:Add(task.spawn(function()
	while EventController:GetActiveEventData("Spain") do
		task.wait(TRAIT_INTERVAL)
		if not EventController:GetActiveEventData("Spain") then break end
		local target = pickTarget()
		if target then giveSpainTrait(target) end
	end
end))

-- ─── Cleanup ──────────────────────────────────────────────────────────────────

task.spawn(function()
	while EventController:GetActiveEventData("Spain") do task.wait(1) end
	trove:Destroy()
end)
