local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService      = game:GetService("TweenService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")

local Trove                  = require(ReplicatedStorage.Packages.Trove)
local EventController        = require(ReplicatedStorage.Controllers.EventController)
local NotificationController = require(ReplicatedStorage.Controllers.NotificationController)
local VFX                    = require(ReplicatedStorage.Shared.VFX)
local SoundController        = require(ReplicatedStorage.Controllers.SoundController)
local SharedEventUtils       = require(ReplicatedStorage.Shared.SharedEventUtils)

local EVENT_NAME = "Bubblegum"

local DETECTION_RADIUS     = 3
local DETECTION_INTERVAL   = 0.5
local COOLDOWN_MIN         = 10
local COOLDOWN_MAX         = 20
local PROCESS_CLEANUP_DELAY = 5
local HIDDEN_POSITION      = Vector3.new(0, 100000, 0)
local Y_OFFSET             = 1.5

local Machine  = workspace.Events.Bubblegum.Machine
local Machine2 = workspace.Events.Bubblegum.Machine2
local Machine3 = workspace.Events.Bubblegum.Machine3

local MACHINE_POSITIONS = {
	Machine1 = { Position = Vector3.new(-389.653, -0.416, -47.629), Rotation = -90 },
	Machine2 = { Position = Vector3.new(-412.653, -0.416, -47.629), Rotation = -90 },
	Machine3 = { Position = Vector3.new(-366.653, -0.416, -47.629), Rotation = -90 },
}

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove          = Trove.new()
local isActive            = true
local cooldownUntil       = 0
local machine2And3Positioned = false

local MachineStatus = {
	[Machine]  = { IsBusy = false },
	[Machine2] = { IsBusy = false },
	[Machine3] = { IsBusy = false },
}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function DecodeTraits(json: string?): { string }
	if not json then return {} end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, json)
	return (ok and type(data) == "table") and data or {}
end

local function EncodeTraits(tbl: { string }): string
	local ok, data = pcall(HttpService.JSONEncode, HttpService, tbl)
	return (ok and type(data) == "string") and data or "[]"
end

local function HasTrait(traits: { string }, name: string): boolean
	for _, v in traits do if v == name then return true end end
	return false
end

local function AddTrait(animal: Instance, name: string)
	local traits = DecodeTraits(animal:GetAttribute("Traits"))
	if not HasTrait(traits, name) then
		table.insert(traits, name)
		animal:SetAttribute("Traits", EncodeTraits(traits))
	end
end

local function MoveToTarget(part: BasePart, target: CFrame, duration: number)
	local tween = TweenService:Create(
		part,
		TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ CFrame = target }
	)
	tween:Play()
	tween.Completed:Wait()
end

local function CooldownRandom()
	cooldownUntil = os.clock() + math.random(COOLDOWN_MIN, COOLDOWN_MAX)
end

local function Is3RoadsActive(): boolean
	return ReplicatedStorage:GetAttribute("3RoadsEvent") == true
end

local function PositionMachine2And3()
	if not isActive or machine2And3Positioned then return end
	local m2 = MACHINE_POSITIONS.Machine2
	Machine2:PivotTo(CFrame.new(m2.Position) * CFrame.Angles(0, math.rad(m2.Rotation), 0))
	local m3 = MACHINE_POSITIONS.Machine3
	Machine3:PivotTo(CFrame.new(m3.Position) * CFrame.Angles(0, math.rad(m3.Rotation), 0))
	machine2And3Positioned = true
end

local function HideMachine2And3()
	if not isActive or not machine2And3Positioned then return end
	Machine2:PivotTo(CFrame.new(HIDDEN_POSITION))
	Machine3:PivotTo(CFrame.new(HIDDEN_POSITION))
	machine2And3Positioned = false
end

local function GetActiveMachineData()
	local machines = {
		{ machine = Machine, goal = Machine:FindFirstChild("Goal"), inMachine = Machine:FindFirstChild("InMachine") },
	}
	if Is3RoadsActive() and machine2And3Positioned then
		table.insert(machines, { machine = Machine2, goal = Machine2:FindFirstChild("Goal"), inMachine = Machine2:FindFirstChild("InMachine") })
		table.insert(machines, { machine = Machine3, goal = Machine3:FindFirstChild("Goal"), inMachine = Machine3:FindFirstChild("InMachine") })
	end
	local active = {}
	for _, d in machines do
		if d.goal and d.inMachine and MachineStatus[d.machine] then
			d.IsBusy = MachineStatus[d.machine].IsBusy
			table.insert(active, d)
		end
	end
	return active
end

-- ─── Process ──────────────────────────────────────────────────────────────────

local function ProcessAnimal(animal: Model, targetMachine: Model, goal: BasePart, inMachine: BasePart)
	MachineStatus[targetMachine].IsBusy = true

	local primary = animal:FindFirstChild("PrimaryPart") or animal.PrimaryPart
	if not primary or not primary:IsA("BasePart") then
		MachineStatus[targetMachine].IsBusy = false
		return
	end

	if not SharedEventUtils.isPointInCarpet(primary.Position) then
		MachineStatus[targetMachine].IsBusy = false
		return
	end

	local traits = DecodeTraits(animal:GetAttribute("Traits"))
	if HasTrait(traits, "Bubblegum") then
		MachineStatus[targetMachine].IsBusy = false
		return
	end

	local animalHeightOffset = math.max(primary.Size.Y / 2, Y_OFFSET)

	local ok = pcall(function()
		animal:SetAttribute("ForceIdle", true)
		task.wait(1)

		-- roll animation — spin the machine circles locally
		for _, circle in { targetMachine:FindFirstChild("Circle1"), targetMachine:FindFirstChild("Circle2") } do
			if not circle or not circle:IsA("BasePart") then continue end
			local val = Instance.new("NumberValue")
			val.Changed:Connect(function(p)
				circle.CFrame = CFrame.new(circle.CFrame.Position) * CFrame.Angles(0, -math.pi / 2, p)
			end)
			local tween = TweenService:Create(val, TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = math.pi * 2 })
			tween.Completed:Once(function() val:Destroy() end)
			tween:Play()
		end

		local machinePos = inMachine.Position
		SoundController:PlaySound("Sounds.Sfx.Bubblegum Machine.Pickup",  machinePos)
		SoundController:PlaySound("Sounds.Sfx.Bubblegum Machine.Crank",   machinePos)

		MoveToTarget(primary, inMachine.CFrame + Vector3.new(0, animalHeightOffset, 0), 1.5)

		AddTrait(animal, "Bubblegum")
		SoundController:PlaySound("Sounds.Sfx.Bubblegum Machine.Apply",        machinePos)
		SoundController:PlaySound("Sounds.Sfx.Bubblegum Machine.ApplyBrainrot", machinePos)

		-- burst VFX inline — no remote
		if not targetMachine:GetAttribute("Hidden") then
			local burstVfx = targetMachine:FindFirstChild("Vfx")
				and targetMachine.Vfx:FindFirstChild("bubblegumburst")
			if burstVfx then VFX.emit(burstVfx) end
		end

		task.wait(3)

		MoveToTarget(primary, goal.CFrame + Vector3.new(0, animalHeightOffset - 1.5, 0), 1.5)

		animal:SetAttribute("ForceIdle", false)
		animal:SetAttribute("ForceIdle", nil)
	end)

	if not ok then
		warn("[Bubblegum] ProcessAnimal failed:", targetMachine.Name, animal:GetFullName())
		pcall(function() animal:SetAttribute("ForceIdle", nil) end)
	end

	MachineStatus[targetMachine].IsBusy = false
	CooldownRandom()
end

-- ─── Detection loop ───────────────────────────────────────────────────────────

local function startDetection()
	local processed: { [Instance]: boolean } = {}

	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(DETECTION_INTERVAL)
			if os.clock() < cooldownUntil then continue end

			local available = GetActiveMachineData()
			if #available == 0 then continue end

			local animals = CollectionService:GetTagged("Animal")

			for _, machineData in available do
				if machineData.IsBusy then continue end

				local nearest, nearestDist = nil, DETECTION_RADIUS

				for _, animal in animals do
					if not animal:IsDescendantOf(workspace) then
						processed[animal] = nil
						continue
					end
					local primary = animal:FindFirstChild("PrimaryPart") or animal.PrimaryPart
					if not primary or not primary:IsA("BasePart") then continue end
					if processed[animal] then continue end
					if HasTrait(DecodeTraits(animal:GetAttribute("Traits")), "Bubblegum") then continue end

					local dist = (primary.Position - machineData.goal.Position).Magnitude
					if dist < nearestDist then
						nearestDist = dist
						nearest     = animal
					end
				end

				if nearest then
					processed[nearest] = true
					task.spawn(function()
						ProcessAnimal(nearest, machineData.machine, machineData.goal, machineData.inMachine)
						task.wait(PROCESS_CLEANUP_DELAY)
						processed[nearest] = nil
					end)
				end
			end
		end
	end))
end

-- ─── 3Roads listener ──────────────────────────────────────────────────────────

eventTrove:Add(ReplicatedStorage:GetAttributeChangedSignal("3RoadsEvent"):Connect(function()
	if Is3RoadsActive() then
		PositionMachine2And3()
	else
		HideMachine2And3()
	end
end))

-- ─── Machine observer — mirrors controller tag observer ───────────────────────

eventTrove:Add(require(ReplicatedStorage.Packages.Observers).observeTag("BubblegumMachine", function(part)
	return require(ReplicatedStorage.Packages.Observers).observeAttribute(part, "Hidden", function(hidden)
		if hidden then return nil end

		local machineTrove = Trove.new()
		local DisplayText  = part.Tank.BillboardGui.DisplayText

		VFX.emit(part.Vfx.Goal)
		machineTrove:Add(task.spawn(function()
			SoundController:PlaySound("Sounds.Sfx.Bubblegum Machine.Apply",       part.Goal.Position)
		end))
		machineTrove:Add(task.spawn(function()
			SoundController:PlaySound("Sounds.Sfx.Bubblegum Machine.Deactivation", part.Goal.Position)
		end))

		-- progress bar tick
		local progressParts = {}
		for _, desc in part:QueryDescendants("BasePart.BubbleGumProgress") do
			progressParts[desc] = { Position = desc.Position }
		end

		local eventData = EventController:GetActiveEventData(EVENT_NAME)
		machineTrove:Add(require(ReplicatedStorage.Packages.Timer).Simple(1, function()
			local remaining = math.max((eventData and eventData.endsAt or 0) - workspace:GetServerTimeNow(), 0)
			DisplayText.Text = require(ReplicatedStorage.Utils.TimeUtils):E(remaining)
			local fill = math.lerp(0, 7.3, math.clamp(remaining / 600, 0, 1))
			for part2, data in progressParts do
				part2.Size     = Vector3.new(part2.Size.X, part2.Size.Y, fill)
				part2.Position = data.Position + Vector3.new(0, 0, 1) * ((fill - 7.3) / 2)
			end
		end, true))

		return machineTrove:WrapClean()
	end)
end))

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	local m1 = MACHINE_POSITIONS.Machine1
	Machine:PivotTo(CFrame.new(m1.Position) * CFrame.Angles(0, math.rad(m1.Rotation), 0))

	if Is3RoadsActive() then PositionMachine2And3() end

	NotificationController:Notify(
		"<font color='#ff69af'>Bubblegum Machine</font> has been activated!",
		15,
		ReplicatedStorage.Sounds.Sfx.Success
	)

	local allData = GetActiveMachineData()
	if #allData == 0 then
		warn("[Bubblegum] No machine parts found.")
		isActive = false
		eventTrove:Destroy()
		return
	end

	startDetection()

	while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end

	isActive = false
	Machine:PivotTo(CFrame.new(HIDDEN_POSITION))
	Machine2:PivotTo(CFrame.new(HIDDEN_POSITION))
	Machine3:PivotTo(CFrame.new(HIDDEN_POSITION))
	eventTrove:Destroy()
end

task.spawn(main)
