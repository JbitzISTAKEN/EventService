-- LocalScript: SummerHourLogic
-- StarterPlayerScripts

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)
local Spring           = require(ReplicatedStorage.Packages.Spring)
local VFX              = require(ReplicatedStorage.Shared.VFX)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)

local EVENT_NAME  = "Summer Hour"
local EventScript = ReplicatedStorage.Controllers.EventController.Events[EVENT_NAME]

local WANDER_FOLDER = workspace:WaitForChild("Events"):WaitForChild(EVENT_NAME)

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove                           = Trove.new()
local recentlyTargeted: {[string]: number} = {}
local isActive                             = true
local isRunning                            = true

local v5 = Spring.new(11.203) v5.Speed = 10  v5.Damper = 0.4
local v6 = Spring.new(0)      v6.Speed = 3   v6.Damper = 0.4
local v7 = Spring.new(0)      v7.Speed = 3   v7.Damper = 0.4
local v8 = Spring.new(0)      v8.Speed = 3   v8.Damper = 0.4

local sunScale = 0.25
local sunYaw   = 0
local sunRoll  = 0
local isAiming = false

local sunModel: Model?           = nil
local sunHome:  CFrame?          = nil
local idleTrack: AnimationTrack? = nil

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getAnimalTop(animal: Instance): Vector3?
	local primary = animal.PrimaryPart
	if not primary then return nil end
	return primary.Position + Vector3.new(0, animal:GetExtentsSize().Y / 2, 0)
end

local function decodeTraits(animal: Instance): {string}
	local raw = animal:GetAttribute("Traits")
	if not raw then return {} end
	local ok, result = pcall(HttpService.JSONDecode, HttpService, raw)
	return (ok and type(result) == "table") and result or {}
end

local function hasSunTrait(animal: Instance): boolean
	for _, t in decodeTraits(animal) do
		if t == "Sun" then return true end
	end
	return false
end

local function addSunTrait(animal: Instance)
	local traits = decodeTraits(animal)
	for _, t in traits do
		if t == "Sun" then return end
	end
	table.insert(traits, "Sun")
	local ok, enc = pcall(HttpService.JSONEncode, HttpService, traits)
	if ok then animal:SetAttribute("Traits", enc) end
end

local function getValidCandidates(): {Instance}
	local now = workspace:GetServerTimeNow()

	for name, last in pairs(recentlyTargeted) do
		if now - last > 20 then recentlyTargeted[name] = nil end
	end

	local candidates = {}
	for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
		if animal and animal.Parent and animal.PrimaryPart
			and not recentlyTargeted[animal.Name]
			and not hasSunTrait(animal)
			and SharedEventUtils.isPointInCarpet(animal.PrimaryPart.Position)
		then
			table.insert(candidates, animal)
		end
	end

	print("[SummerHour] Valid candidates:", #candidates)
	return candidates
end

-- ─── Projectile ───────────────────────────────────────────────────────────────

local function fireProjectile(animal: Instance): number
	if not sunModel or not sunHome then
		warn("[SummerHour] sunModel or sunHome nil")
		return 0
	end

	local animalPos = getAnimalTop(animal)
	if not animalPos then
		warn("[SummerHour] Could not resolve animal position")
		return 0
	end

	v5:Impulse(130)

	task.spawn(function()
		VFX.emit(sunModel.RootPart.Bone.Burst)
		SoundController:PlaySound(
			ReplicatedStorage.Sounds.Events["Summer Hour"].Shoot,
			sunModel:GetPivot().Position,
			false
		)
	end)

	local clone = sunModel:Clone()
	clone.Parent = workspace

	local animator = clone:FindFirstChildWhichIsA("Animator", true)
	local idleAnim = EventScript.IdleAnimation
	if animator and idleAnim and idleAnim:IsA("Animation") then
		local track = animator:LoadAnimation(idleAnim)
		track.Looped = true
		track:Play()
	end

	local startCF    = sunModel:GetPivot()
	local startPos   = startCF.Position
	local startRot   = startCF.Rotation
	local fireTime   = workspace:GetServerTimeNow()
	local travelTime = (animalPos - startPos).Magnitude / 90
	local lastTarget = animalPos
	local conn: RBXScriptConnection

	print(string.format("[SummerHour] Firing at %s — %.1f studs / %.2fs travel",
		animal.Name, (animalPos - startPos).Magnitude, travelTime))

	conn = RunService.PostSimulation:Connect(function()
		if not isActive then
			conn:Disconnect()
			if clone.Parent then clone:Destroy() end
			return
		end

		local cur = ClientEventUtils.getAnimalPosition(animal, { top = true })
		if cur ~= Vector3.new(0, 0, 0) then
			lastTarget = cur
		else
			local fallback = getAnimalTop(animal)
			if fallback then lastTarget = fallback end
		end

		local t = TweenService:GetValue(
			travelTime == 0 and 1
				or math.clamp((workspace:GetServerTimeNow() - fireTime) / travelTime, 0, 1),
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.In
		)

		local pos = startPos:Lerp(lastTarget, t)
		clone:PivotTo(CFrame.new(pos) * startRot * CFrame.Angles(0, 0, t * math.pi * 8))
		clone:ScaleTo(math.lerp(14.203, 1, t))

		if t >= 1 then
			conn:Disconnect()
			clone:Destroy()
		end
	end)

	task.delay(10, function()
		if conn.Connected then conn:Disconnect() end
		if clone.Parent then clone:Destroy() end
	end)

	return travelTime
end

-- ─── Strike ───────────────────────────────────────────────────────────────────

local function tryShootAnimal(animal: Instance)
	if not animal or not animal.Parent or not animal.PrimaryPart then return end

	local aimDelay = 0.7
	recentlyTargeted[animal.Name] = workspace:GetServerTimeNow()

	if sunHome then
		local animalPos = getAnimalTop(animal)
		if animalPos then
			local rot        = CFrame.lookAt(sunHome.Position, animalPos).Rotation
			local rx, ry, rz = (sunHome.Rotation:Inverse() * rot):ToEulerAnglesXYZ()
			isAiming = true
			sunScale = rx
			sunYaw   = ry
			sunRoll  = rz
		end
	end

	print("[SummerHour] Targeting:", animal.Name)

	eventTrove:Add(task.delay(aimDelay, function()
		if not isActive or not animal or not animal.Parent then return end

		local travelTime = fireProjectile(animal)

		task.delay(0.5, function()
			sunScale = 0.25
			sunYaw   = 0
			sunRoll  = 0
			isAiming = false
		end)

		task.delay(travelTime, function()
			if not isActive or not animal or not animal.Parent then return end

			local burstVFX = EventScript:FindFirstChild("Burst")
			local rootPart = animal.PrimaryPart
			if burstVFX and rootPart then
				ClientEventUtils.playBurst(
					burstVFX,
					rootPart,
					{ ReplicatedStorage.Sounds.Events["Summer Hour"].Burst }
				)
			end

			addSunTrait(animal)
			print("[SummerHour] Sun trait applied:", animal.Name)
		end)
	end))
end

-- ─── Sun animation ────────────────────────────────────────────────────────────

local function startSunAnimation()
	eventTrove:Add(RunService.PostSimulation:Connect(function()
		if not isRunning or not sunModel or not sunHome then return end

		local t = os.clock()
		v6.Target = sunScale
		v7.Target = sunYaw
		v8.Target = sunRoll
		sunModel:ScaleTo(v5.Position)

		local cf = sunHome * CFrame.Angles(v6.Position, v7.Position, v8.Position)
		sunModel:PivotTo(cf + Vector3.new(0, math.sin(t * 1.75) * 7, 0))
	end))

	eventTrove:Add(task.spawn(function()
		while isRunning do
			if not isAiming then
				sunYaw  = 0
				sunRoll = 0
			end

			local deadline = os.clock() + math.random(20, 50) / 10
			local flip     = math.random() < 0.5

			while isRunning and os.clock() < deadline do
				if not isAiming then
					sunScale = flip and 0.5 or 0
					flip     = not flip
				end
				task.wait(math.random(80, 160) / 100)
			end

			task.wait(0.1)
		end
	end))
end

-- ─── Attack loop ──────────────────────────────────────────────────────────────

local function startAttackLoop()
	eventTrove:Add(task.spawn(function()
		while isActive do
			local waitTime = math.random(700, 1200) / 100
			if ReplicatedStorage:GetAttribute("3RoadsEvent") == true then
				waitTime = waitTime / 3
			end
			task.wait(waitTime)
			if not isActive then break end

			local candidates = getValidCandidates()
			if #candidates > 0 then
				tryShootAnimal(candidates[math.random(1, #candidates)])
			end
		end
	end))
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	sunModel = WANDER_FOLDER:WaitForChild("SunTrait")

	local homeAttr = sunModel:GetAttribute("Home")
	sunHome = typeof(homeAttr) == "CFrame" and homeAttr or sunModel:GetPivot()

	print("[SummerHour] Ready — sunHome:", sunHome)

	local animator = sunModel:FindFirstChildWhichIsA("Animator", true)
	local idleAnim = EventScript.IdleAnimation
	if animator and idleAnim and idleAnim:IsA("Animation") then
		local track = animator:LoadAnimation(idleAnim)
		track.Looped = true
		track:Play()
		idleTrack = track
		eventTrove:Add(function()
			if idleTrack then
				idleTrack:Stop(0)
				idleTrack:Destroy()
				idleTrack = nil
			end
		end)
	end

	ReplicatedStorage:SetAttribute("SummerHourEvent", true)
	startSunAnimation()
	startAttackLoop()

	while EventController:GetActiveEventData(EVENT_NAME) do
		task.wait(1)
	end

	print("[SummerHour] Event ended — cleaning up")

	isActive  = false
	isRunning = false

	if sunModel and sunModel.Parent then
		sunModel.RootPart.CFrame = CFrame.new(9999, 9999, 9999)
		sunModel = nil
	end

	eventTrove:Destroy()
	table.clear(recentlyTargeted)

	ReplicatedStorage:SetAttribute("SummerHourEvent", nil)
end

task.spawn(main)
