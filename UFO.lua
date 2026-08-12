-- LocalScript: UFOLogic
-- StarterPlayerScripts

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)
local CreateTween      = require(ReplicatedStorage.Packages.CreateTween)
local Observers        = require(ReplicatedStorage.Packages.Observers)
local ShakePresets     = require(ReplicatedStorage.Shared.ShakePresets)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local EVENT_NAME = "UFO"

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove        = Trove.new()
local recentlyTargeted: {[string]: number} = {}
local activeAbductions: {{animal: Instance, originalCFrame: CFrame}} = {}
local isActive          = true
local strikeTask: thread? = nil

local UFOModel = ReplicatedStorage.Models.Events.UFO.UFO

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function applyTrait(animal: Instance, trait: string)
	local raw = animal:GetAttribute("Traits")
	local traits = {}
	if raw then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(decoded) == "table" then traits = decoded end
	end
	for _, t in ipairs(traits) do
		if t == trait then return end
	end
	table.insert(traits, trait)
	animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function hasTrait(animal: Instance, trait: string): boolean
	local raw = animal:GetAttribute("Traits")
	if not raw then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(decoded) ~= "table" then return false end
	for _, t in ipairs(decoded) do
		if t == trait then return true end
	end
	return false
end

local function createUFOMarker(spawnPosition: Vector3): Part
	local marker = Instance.new("Part")
	marker.Size         = Vector3.new(1, 1, 1)
	marker.Transparency = 1
	marker.CanCollide   = false
	marker.Anchored     = true
	marker.CFrame       = CFrame.new(spawnPosition)
	CollectionService:AddTag(marker, "GalaxyUFO")
	marker.Parent = workspace
	eventTrove:Add(marker)
	return marker
end

local function playUFOSpawnFX()
	local PlayerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not PlayerGui then return end

	local gui = Instance.new("ScreenGui")
	gui.IgnoreGuiInset   = true
	gui.ResetOnSpawn     = false
	gui.DisplayOrder     = 10000
	gui.Name             = "UFO_SpawnFlash"

	local frame = Instance.new("Frame")
	frame.Size                   = UDim2.fromScale(1, 1)
	frame.BackgroundColor3       = Color3.fromRGB(60, 255, 120)
	frame.BackgroundTransparency = 1
	frame.Parent = gui
	gui.Parent   = PlayerGui

	local t1 = CreateTween(frame, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 0.4 }, false)
	local t2 = CreateTween(frame, TweenInfo.new(0.3,  Enum.EasingStyle.Quad, Enum.EasingDirection.In),  { BackgroundTransparency = 1   }, false)

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

local function playAbductionBurst(position: Vector3)
	ClientEventUtils.playBurst(
		ReplicatedStorage.Controllers.EventController.Events.UFO.Effects.ufoemit,
		position,
		{ ReplicatedStorage.Sounds.Events.UFO.Burst }
	)
end

local function moveUFOToPosition(marker: Part, target: Vector3, duration: number)
	local tween = TweenService:Create(
		marker,
		TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ CFrame = CFrame.new(target) }
	)
	tween:Play()
	tween.Completed:Wait()
end

local function liftAndReturnAnimal(selected: Instance, marker: Part)
	if not selected.PrimaryPart then return end

	selected:SetAttribute("ForceIdle", true)
	local originalCFrame = selected.PrimaryPart.CFrame
	local liftTarget     = originalCFrame.Position + Vector3.new(0, 30, 0)

	local entry = { animal = selected, originalCFrame = originalCFrame }
	table.insert(activeAbductions, entry)

	local function removeEntry()
		for i, e in ipairs(activeAbductions) do
			if e == entry then
				table.remove(activeAbductions, i)
				break
			end
		end
	end

	local function cleanup(returnAnimal: boolean)
		marker:SetAttribute("BeamState", "off")
		if selected and selected.Parent then
			if returnAnimal and selected.PrimaryPart then
				local lowerTween = TweenService:Create(
					selected.PrimaryPart,
					TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
					{ CFrame = originalCFrame }
				)
				lowerTween:Play()
				lowerTween.Completed:Wait()
			end
			selected:SetAttribute("ForceIdle", false)
		end
		removeEntry()
	end

	-- watch for animal dying mid-abduction
	local died = false
	local ancestryConn = selected.AncestryChanged:Connect(function()
		if not selected.Parent then
			died = true
		end
	end)

	-- lift
	if not selected.PrimaryPart then
		ancestryConn:Disconnect()
		cleanup(false)
		return
	end

	local liftTween = TweenService:Create(
		selected.PrimaryPart,
		TweenInfo.new(2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ CFrame = CFrame.new(liftTarget) * (originalCFrame - originalCFrame.Position) }
	)
	liftTween:Play()
	liftTween.Completed:Wait()

	if died or not selected.Parent or not selected.PrimaryPart then
		ancestryConn:Disconnect()
		cleanup(false)
		return
	end

	task.wait(0.5)

	if died or not selected.Parent or not selected.PrimaryPart then
		ancestryConn:Disconnect()
		cleanup(false)
		return
	end

	playAbductionBurst(selected.PrimaryPart.Position)
	applyTrait(selected, "UFO")

	task.wait(1.5)

	if died or not selected.Parent or not selected.PrimaryPart then
		ancestryConn:Disconnect()
		cleanup(false)
		return
	end

	ancestryConn:Disconnect()
	cleanup(true)
end

local function handleUFODeparture(marker: Part)
	local angle  = math.random() * math.pi * 2
	local offset = Vector3.new(math.cos(angle) * 200, 100, math.sin(angle) * 200)
	local tween  = TweenService:Create(
		marker,
		TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ CFrame = CFrame.new(marker.Position + offset) }
	)
	tween:Play()
	tween.Completed:Connect(function()
		marker:Destroy()
	end)
end

local function findCandidates(): {Instance}
	local now        = workspace:GetServerTimeNow()
	local candidates = {}

	for name, last in pairs(recentlyTargeted) do
		if now - last > 15 then recentlyTargeted[name] = nil end
	end

	for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
		if animal.PrimaryPart
			and not recentlyTargeted[animal.Name]
			and not hasTrait(animal, "UFO")
		then
			table.insert(candidates, animal)
		end
	end

	return candidates
end

-- ─── Visual observer ──────────────────────────────────────────────────────────

local function startVisuals()
	eventTrove:Add(Observers.observeTag("GalaxyUFO", function(marker)
		if not marker:IsA("BasePart") then return nil end

		local vizTrove = eventTrove:Extend()
		local ufo      = vizTrove:Clone(UFOModel)

		for _, d in ufo:GetDescendants() do
			if d:IsA("BasePart") then d.Anchored = true end
		end

		local flyingSound = ReplicatedStorage.Sounds.Events.UFO.Flying:Clone()
		flyingSound.Parent = marker
		flyingSound:Play()
		ufo.Parent = workspace

		local BeamPart = ufo:FindFirstChild("BeamPart", true)
		local att0     = BeamPart and BeamPart:FindFirstChild("att0")
		local att1     = BeamPart and BeamPart:FindFirstChild("att1")

		if not (BeamPart and att0 and att1
			and att0:IsA("Attachment") and att1:IsA("Attachment")) then
			vizTrove:Destroy()
			return nil
		end

		local beams: {Beam} = {}
		for _, child in att1:GetChildren() do
			if child:IsA("Beam") then
				child.Attachment0 = att0
				child.Attachment1 = att1
				child.Enabled     = false
				table.insert(beams, child)
			end
		end

		local restPosition  = att1.Position
		local activeTween: Tween? = nil

		local function cancelBeamTween()
			if activeTween then activeTween:Cancel() activeTween = nil end
		end

		local function setState(state: string)
			if state == "down" then
				local abductSound = ReplicatedStorage.Sounds.Events.UFO.Abducting:Clone()
				abductSound.Parent = marker
				abductSound:Play()

				for _, b in beams do b.Enabled = true end
				cancelBeamTween()
				att1.Position = att0.Position
				activeTween   = CreateTween(att1, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { Position = restPosition })
				activeTween:Play()

			elseif state == "off" then
				cancelBeamTween()
				activeTween = CreateTween(att1, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { Position = att0.Position })
				activeTween:Play()

				local captured = activeTween
				if captured then captured.Completed:Wait() end

				for _, b in beams do b.Enabled = false end
				att1.Position = restPosition
			end
		end

		vizTrove:Add(task.spawn(function()
			local state = marker:GetAttribute("BeamState")
			if typeof(state) == "string" then
				setState(state)
			else
				for _, b in beams do b.Enabled = false end
				att1.Position = restPosition
			end
		end))

		vizTrove:Add(marker:GetAttributeChangedSignal("BeamState"):Connect(function()
			local state = marker:GetAttribute("BeamState")
			if typeof(state) == "string" then setState(state) end
		end))

		vizTrove:Add(RunService.PostSimulation:Connect(function()
			if ufo.PrimaryPart == nil or not marker.Parent then
				vizTrove:Destroy()
				return
			end
			ufo:PivotTo(marker.CFrame)
		end))

		vizTrove:Add(cancelBeamTween)

		return function() vizTrove:Destroy() end
	end))
end

-- ─── Strike loop ──────────────────────────────────────────────────────────────

local function startStrikeLoop()
	strikeTask = task.spawn(function()
		while isActive do
			task.wait(math.random(6, 12))
			if not isActive then break end

			local candidates = findCandidates()
			if #candidates == 0 then continue end

			local selected = candidates[math.random(1, #candidates)]
			if not selected.PrimaryPart then continue end
			if not SharedEventUtils.isPointInCarpet(selected.PrimaryPart.Position) then continue end

			local pos      = selected.PrimaryPart.Position
			local angle    = math.random() * math.pi * 2
			local spawnPos = pos + Vector3.new(math.cos(angle) * 50, 50, math.sin(angle) * 50)

			local marker = createUFOMarker(spawnPos)

			playUFOSpawnFX()
			recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()

			moveUFOToPosition(marker, pos + Vector3.new(0, 50, 0), 1.5)

			local trackConn = RunService.Heartbeat:Connect(function()
				if selected and selected.PrimaryPart and marker and marker.Parent then
					local p = selected.PrimaryPart.Position
					marker.CFrame = CFrame.new(p.X, marker.Position.Y, p.Z)
				end
			end)

			marker:SetAttribute("BeamState", "down")
			liftAndReturnAnimal(selected, marker)
			trackConn:Disconnect()
			handleUFODeparture(marker)
		end
	end)
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	ReplicatedStorage:SetAttribute("UFOEvent", true)

	startVisuals()
	startStrikeLoop()

	while EventController:GetActiveEventData(EVENT_NAME) do
		task.wait(1)
	end

	isActive = false
	ReplicatedStorage:SetAttribute("UFOEvent", false)

	if strikeTask then
		task.cancel(strikeTask)
		strikeTask = nil
	end

	for _, entry in ipairs(activeAbductions) do
		local animal = entry.animal
		if animal and animal.PrimaryPart then
			local t = TweenService:Create(
				animal.PrimaryPart,
				TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
				{ CFrame = entry.originalCFrame }
			)
			t:Play()
			t.Completed:Once(function()
				animal:SetAttribute("ForceIdle", false)
			end)
		else
			if animal then animal:SetAttribute("ForceIdle", false) end
		end
	end

	table.clear(activeAbductions)
	table.clear(recentlyTargeted)

	for _, m in CollectionService:GetTagged("GalaxyUFO") do
		m:Destroy()
	end

	eventTrove:Destroy()
end

task.spawn(main)
