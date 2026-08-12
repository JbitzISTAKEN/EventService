--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local Trove          = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)
local Observers      = require(ReplicatedStorage.Packages.Observers)
local CreateTween    = require(ReplicatedStorage.Packages.CreateTween)
local SoundController = require(ReplicatedStorage.Controllers.SoundController)
local CycleController = require(ReplicatedStorage.Controllers.CycleController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local ShakePresets   = require(ReplicatedStorage.Shared.ShakePresets)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

local UFO_MODEL   = ReplicatedStorage.Models.Events.UFO.UFO
local EVENT_NAME  = "UFO"

local STRIKE_COOLDOWN_MIN   = 6
local STRIKE_COOLDOWN_MAX   = 12
local RECENT_TARGET_TIMEOUT = 15
local APPROACH_DURATION     = 1.5
local BEAM_DOWN_DURATION    = 0.5
local LIFT_DURATION         = 2
local HOLD_DURATION         = 0.5
local TRAIT_WAIT            = 1.5
local LOWER_DURATION        = 1
local BEAM_OFF_WAIT         = 1
local DEPART_DURATION       = 1
local DEPART_DISTANCE       = 200
local HOVER_HEIGHT          = 50
local SPAWN_RADIUS          = 50
local SPAWN_HEIGHT          = 50

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove        = Trove.new()
local isActive          = true
local recentlyTargeted: { [string]: number } = {}
local activeAbductions: { { animal: Model, originalCFrame: CFrame } } = {}

ReplicatedStorage:SetAttribute("UFOEvent", true)

eventTrove:Add(function()
	ReplicatedStorage:SetAttribute("UFOEvent", nil)
	CycleController:Update()
	SoundController:UpdateOST()
end)

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function hasTrait(animal: Model, name: string): boolean
	local json = animal:GetAttribute("Traits")
	if not json then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return false end
	for _, t in decoded do if t == name then return true end end
	return false
end

local function applyTrait(animal: Model, name: string)
	local json = animal:GetAttribute("Traits")
	local traits = {}
	if json then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
		if ok and type(decoded) == "table" then traits = decoded end
	end
	for _, t in traits do if t == name then return end end
	table.insert(traits, name)
	animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function playSpawnFX()
	local gui = Instance.new("ScreenGui")
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn   = false
	gui.DisplayOrder   = 10000
	gui.Name           = "UFO_SpawnFlash"

	local frame = Instance.new("Frame")
	frame.Size                  = UDim2.fromScale(1, 1)
	frame.BackgroundColor3      = Color3.fromRGB(60, 255, 120)
	frame.BackgroundTransparency = 1
	frame.Parent                = gui

	gui.Parent = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")

	local t1 = CreateTween(frame, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),  { BackgroundTransparency = 0.4 }, false)
	local t2 = CreateTween(frame, TweenInfo.new(0.3,  Enum.EasingStyle.Quad, Enum.EasingDirection.In),   { BackgroundTransparency = 1   }, false)
	t1:Play()
	t1.Completed:Once(function()
		t2:Play()
		t2.Completed:Once(function() gui:Destroy() end)
	end)

	local shake = ShakePresets.BumpS:Clone()
	shake.Sustain = true
	local unbind = ShakePresets.BindShakeToCamera(shake, workspace.CurrentCamera)
	shake:Start()
	task.delay(0.3, function()
		shake:StopSustain()
		task.delay(0.2, function()
			shake:Destroy()
			unbind()
		end)
	end)
end

local function createMarker(position: Vector3): BasePart
	local marker = Instance.new("Part")
	marker.Size        = Vector3.new(1, 1, 1)
	marker.Transparency = 1
	marker.CanCollide  = false
	marker.Anchored    = true
	marker.CFrame      = CFrame.new(position)
	CollectionService:AddTag(marker, "GalaxyUFO")
	marker.Parent = workspace
	return marker
end

local function moveMarker(marker: BasePart, target: Vector3, duration: number)
	local tween = TweenService:Create(
		marker,
		TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ CFrame = CFrame.new(target) }
	)
	tween:Play()
	tween.Completed:Wait()
end

local function findCandidates(): { Model }
	local now  = os.clock()
	local out  = {}
	for name, t in recentlyTargeted do
		if now - t > RECENT_TARGET_TIMEOUT then recentlyTargeted[name] = nil end
	end
	for _, animal in CollectionService:GetTagged("Animal") do
		local a = animal :: Model
		if a.PrimaryPart
			and not recentlyTargeted[a.Name]
			and not hasTrait(a, "UFO")
			and SharedEventUtils.isPointInCarpet(a.PrimaryPart.Position)
		then
			table.insert(out, a)
		end
	end
	return out
end

-- ─── UFO visual observer — mirrors controller exactly ─────────────────────────

eventTrove:Add(Observers.observeTag("GalaxyUFO", function(marker)
	if not marker:IsA("BasePart") then return nil end

	local vizTrove  = eventTrove:Extend()
	local ufoClone  = vizTrove:Clone(UFO_MODEL)

	for _, desc in ufoClone:GetDescendants() do
		if desc:IsA("BasePart") then desc.Anchored = true end
	end

	local flyingSound = ReplicatedStorage.Sounds.Events.UFO.Flying:Clone()
	flyingSound.Parent = marker
	flyingSound:Play()

	ufoClone.Parent = workspace

	local beamPart = ufoClone:FindFirstChild("BeamPart", true)
	local att0     = beamPart and beamPart:FindFirstChild("att0")
	local att1     = beamPart and beamPart:FindFirstChild("att1")

	if not beamPart or not att0 or not att1
		or not att0:IsA("Attachment") or not att1:IsA("Attachment")
	then
		vizTrove:Destroy()
		return nil
	end

	local beams: { Beam } = {}
	for _, child in att1:GetChildren() do
		if child:IsA("Beam") then
			child.Attachment0 = att0
			child.Attachment1 = att1
			child.Enabled     = false
			table.insert(beams, child)
		end
	end

	local restPosition = att1.Position
	local cancelTween: typeof(CreateTween(...))? = nil

	local function cancelCurrent()
		if cancelTween then cancelTween:Cancel(); cancelTween = nil end
	end

	local function setState(state: string)
		if state == "down" then
			local abductSound = ReplicatedStorage.Sounds.Events.UFO.Abducting:Clone()
			abductSound.Parent = marker
			abductSound:Play()
			for _, b in beams do b.Enabled = true end
			att1.Position = att0.Position
			cancelCurrent()
			cancelTween = CreateTween(att1, TweenInfo.new(BEAM_DOWN_DURATION, Enum.EasingStyle.Quad), { Position = restPosition })
		elseif state == "off" then
			cancelCurrent()
			cancelTween = CreateTween(att1, TweenInfo.new(BEAM_DOWN_DURATION, Enum.EasingStyle.Quad), { Position = att0.Position })
			if cancelTween then cancelTween.Completed:Wait() end
			for _, b in beams do b.Enabled = false end
			att1.Position = restPosition
		end
	end

	-- apply initial beam state
	vizTrove:Add(task.spawn(function()
		local state = marker:GetAttribute("BeamState")
		if type(state) == "string" then
			setState(state)
		else
			for _, b in beams do b.Enabled = false end
			att1.Position = restPosition
		end
	end))

	vizTrove:Add(marker:GetAttributeChangedSignal("BeamState"):Connect(function()
		local state = marker:GetAttribute("BeamState")
		if type(state) == "string" then setState(state) end
	end))

	-- track marker position every frame
	vizTrove:Add(RunService.PostSimulation:Connect(function()
		debug.profilebegin("UFO:MoveUFO")
		if ufoClone.PrimaryPart and marker.Parent then
			ufoClone:PivotTo(marker.CFrame)
		else
			vizTrove:Destroy()
		end
		debug.profileend()
	end))

	vizTrove:Add(cancelCurrent)

	return function() vizTrove:Destroy() end
end))

-- ─── Abduction sequence ───────────────────────────────────────────────────────

local function abduct(animal: Model, marker: BasePart)
	if not animal.PrimaryPart then return end

	animal:SetAttribute("ForceIdle", true)
	local primary      = animal.PrimaryPart
	local originalCF   = primary.CFrame
	local liftTarget   = originalCF.Position + Vector3.new(0, 30, 0)

	local entry = { animal = animal, originalCFrame = originalCF }
	table.insert(activeAbductions, entry)

	-- lift
	local liftTween = TweenService:Create(
		primary,
		TweenInfo.new(LIFT_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ CFrame = CFrame.new(liftTarget) * (originalCF - originalCF.Position) }
	)
	liftTween:Play()
	liftTween.Completed:Wait()

	task.wait(HOLD_DURATION)

	-- burst VFX inline
	ClientEventUtils.playBurst(
		ReplicatedStorage.Models.Events.UFO:FindFirstChild("Effects") and
		ReplicatedStorage.Models.Events.UFO.Effects:FindFirstChild("ufoemit") or
		ReplicatedStorage.Models.Events.UFO.UFO,
		primary.Position,
		{ ReplicatedStorage.Sounds.Events.UFO.Burst }
	)

	applyTrait(animal, "UFO")
	task.wait(TRAIT_WAIT)

	-- lower
	local lowerTween = TweenService:Create(
		primary,
		TweenInfo.new(LOWER_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ CFrame = originalCF }
	)
	lowerTween:Play()
	lowerTween.Completed:Wait()

	marker:SetAttribute("BeamState", "off")
	task.wait(BEAM_OFF_WAIT)
	animal:SetAttribute("ForceIdle", false)
	animal:SetAttribute("ForceIdle", nil)

	for i, e in activeAbductions do
		if e == entry then table.remove(activeAbductions, i) break end
	end
end

local function departMarker(marker: BasePart)
	local angle  = math.random() * math.pi * 2
	local offset = Vector3.new(math.cos(angle) * DEPART_DISTANCE, 100, math.sin(angle) * DEPART_DISTANCE)
	local tween  = TweenService:Create(
		marker,
		TweenInfo.new(DEPART_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ CFrame = CFrame.new(marker.Position + offset) }
	)
	tween:Play()
	tween.Completed:Once(function() marker:Destroy() end)
end

-- ─── Strike loop ──────────────────────────────────────────────────────────────

eventTrove:Add(task.spawn(function()
	while isActive do
		task.wait(math.random(STRIKE_COOLDOWN_MIN, STRIKE_COOLDOWN_MAX))
		if not isActive then break end

		local candidates = findCandidates()
		if #candidates == 0 then continue end

		local animal  = candidates[math.random(1, #candidates)]
		if not animal.PrimaryPart then continue end

		local pos      = animal.PrimaryPart.Position
		local angle    = math.random() * math.pi * 2
		local spawnPos = pos + Vector3.new(math.cos(angle) * SPAWN_RADIUS, SPAWN_HEIGHT, math.sin(angle) * SPAWN_RADIUS)

		local marker = createMarker(spawnPos)
		playSpawnFX()
		recentlyTargeted[animal.Name] = os.clock()

		-- approach
		moveMarker(marker, pos + Vector3.new(0, HOVER_HEIGHT, 0), APPROACH_DURATION)

		-- track animal horizontally while abducting
		local trackConn = RunService.Heartbeat:Connect(function()
			if animal.PrimaryPart and marker.Parent then
				local p = animal.PrimaryPart.Position
				marker.CFrame = CFrame.new(p.X, marker.Position.Y, p.Z)
			end
		end)

		marker:SetAttribute("BeamState", "down")
		abduct(animal, marker)
		trackConn:Disconnect()
		departMarker(marker)
	end
end))

-- ─── Shutdown ─────────────────────────────────────────────────────────────────

task.spawn(function()
	while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end

	isActive = false

	for _, entry in activeAbductions do
		local a = entry.animal
		if a and a.PrimaryPart then
			local t = TweenService:Create(
				a.PrimaryPart,
				TweenInfo.new(LOWER_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
				{ CFrame = entry.originalCFrame }
			)
			t:Play()
			t.Completed:Once(function()
				a:SetAttribute("ForceIdle", false)
				a:SetAttribute("ForceIdle", nil)
			end)
		else
			pcall(function() a:SetAttribute("ForceIdle", nil) end)
		end
	end
	table.clear(activeAbductions)
	table.clear(recentlyTargeted)

	for _, m in CollectionService:GetTagged("GalaxyUFO") do
		pcall(function() m:Destroy() end)
	end

	eventTrove:Destroy()
end)
