local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local SharedEventUtils           = require(ReplicatedStorage.Shared.SharedEventUtils)
local MathUtils                  = require(ReplicatedStorage.Utils.MathUtils)
local Trove                      = require(ReplicatedStorage.Packages.Trove)
local Spr                        = require(ReplicatedStorage.Packages.Spr)
local VFX                        = require(ReplicatedStorage.Shared.VFX)
local SoundController            = require(ReplicatedStorage.Controllers.SoundController)
local ShakePresets               = require(ReplicatedStorage.Shared.ShakePresets)
local Shake                      = require(ReplicatedStorage.Packages.Shake)
local EffectController           = require(ReplicatedStorage.Controllers.EffectController)
local SkullEmojiEffectController = require(ReplicatedStorage.Controllers.SkullEmojiEffectController)
local EventController            = require(ReplicatedStorage.Controllers.EventController)

local EventScript   = ReplicatedStorage.Controllers.EventController.Events.Mygame43
local Mygame43Model = ReplicatedStorage:WaitForChild("Models").Events.Mygame43.mygame43
local Sounds        = ReplicatedStorage.Sounds.Events.Mygame43

repeat task.wait() until EventController:GetActiveEventData("Mygame43")
local startedAt = EventController:GetActiveEventData("Mygame43").startedAt

local function timeLeftFor(t)
	return startedAt + t - workspace:GetServerTimeNow()
end

local shakeBase = Shake.new()
shakeBase.Amplitude         = 5.5
shakeBase.Frequency         = 0.05
shakeBase.FadeInTime        = 0
shakeBase.FadeOutTime       = 0.6
shakeBase.PositionInfluence = Vector3.new(0.5, 0.5, 0.5)
shakeBase.RotationInfluence = Vector3.new(2.5, 0.5, 0.5)

local trove       = Trove.new()
local recentlyHit = {}

local v22 = Mygame43Model:Clone()
v22.Parent = workspace
trove:Add(v22)

Sounds.Appear:Play()

trove:Add(function()
	EffectController:Activate("Blink")
end)

local function shakeCameraBasedOnProximity(pos)
	local mag = (workspace.CurrentCamera.CFrame.Position - pos).Magnitude
	if mag > 300 then return end
	local s  = shakeBase:Clone()
	local v2 = (1 - mag / 300 * 0.5) ^ 2
	s.Amplitude         = s.Amplitude         * v2
	s.RotationInfluence = s.RotationInfluence * v2
	ShakePresets.BindShakeToCamera(s)
	s:Start()
end

local animator = v22.Humanoid and v22.Humanoid.Animator
if animator then
	local idle  = animator:LoadAnimation(EventScript.Idle)
	local spawn = animator:LoadAnimation(EventScript.Spawn)
	idle:Play()
	spawn:Play()
	spawn.TimePosition = math.max(0, 7 - timeLeftFor(7))
	trove:Add(function()
		idle:Stop()
		spawn:Stop()
	end)
end

trove:Add(task.delay(math.max(0, timeLeftFor(7.7)), function()
	for i = 1, 4 do
		local offsetCF = CFrame.new(
			(i - 1) * 30 + -45,
			(i == 2 or i == 3) and 70 or 50,
			15
		)
		local anchorCF = v22.HumanoidRootPart.CFrame * offsetCF
		local orb = trove:Clone(EventScript.Orb)
		orb.CFrame = anchorCF - Vector3.new(0, 100, 0)
		orb.Parent = workspace
		trove:Add(function() Spr.stop(orb) end)

		local floatSpeed = Random.new():NextNumber(2, 3)
		trove:Add(RunService.PostSimulation:Connect(function()
			debug.profilebegin("Mygame43:FloatOrb")
			Spr.target(orb, 0.8, 1, {
				Pivot = anchorCF + Vector3.new(0, math.sin((os.clock() + i * 90) * floatSpeed) * 4, 0),
			})
			debug.profileend()
		end))
	end
end))

trove:Add(task.delay(math.max(0, timeLeftFor(3.7)), function()
	if not v22 or not v22.Parent then return end
	VFX.enable(v22)

	local focusConn = RunService.PreRender:Connect(function(dt)
		debug.profilebegin("Mygame43:Focus")
		if not v22 or not v22.Parent then return end
		local cf = workspace.CurrentCamera.CFrame
		workspace.CurrentCamera.CFrame = cf:Lerp(
			CFrame.lookAt(cf.Position, v22:GetPivot().Position),
			math.clamp(dt ^ 0.45, 0, 0.1)
		)
		debug.profileend()
	end)

	task.delay(0.6, function()
		focusConn:Disconnect()
		SkullEmojiEffectController:Play(3, "Lower")
	end)
end))

local function fireOrb(seed, orbIndex, targetPos, flightDuration, didHit)
	local originCF = CFrame.new(
		(orbIndex - 1) * 30 + -45,
		(orbIndex == 2 or orbIndex == 3) and 70 or 50,
		15
	)
	local Position = (v22 and v22.HumanoidRootPart.CFrame * originCF or originCF).Position

	local orb = trove:Clone(EventScript.OrbSmaller)
	orb.CFrame = CFrame.new(Position)

	local flySound = Sounds.OrbFlying:Clone()
	flySound.Parent = orb
	orb.Parent      = workspace
	flySound:Play()
	VFX.enable(orb)

	local rng = Random.new(seed)
	local cp1 = Position + (targetPos - Position) * 0.25
		+ Vector3.new(
			rng:NextNumber(50, 100)  * (rng:NextInteger(0, 1) * 2 - 1),
			rng:NextInteger(300, 400),
			0
		)
	local cp2 = Position + (targetPos - Position) * 0.6
		+ Vector3.new(
			rng:NextNumber(50, 150) * (rng:NextInteger(0, 1) * 2 - 1),
			rng:NextInteger(100, 200),
			0
		)

	local elapsed = 0
	local conn    = nil

	conn = trove:Add(RunService.PostSimulation:Connect(function(dt)
		debug.profilebegin("Mygame43:UpdateOrb")
		elapsed = elapsed + dt

		local t1 = TweenService:GetValue(
			elapsed / flightDuration,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.In
		)

		SharedEventUtils.pushPartCFrame(
			orb,
			CFrame.new(MathUtils.cubicBezier(t1, Position, cp1, cp2, targetPos))
		)

		if t1 >= 1 and conn then
			trove:Remove(conn)
			conn = nil
			VFX.disable(orb)
			task.delay(3, function() trove:Remove(orb) end)

			shakeCameraBasedOnProximity(targetPos)

			local strike = didHit
				and EventScript.StrikeBrainrot:Clone()
				or  EventScript.Strike:Clone()
			strike.Position = targetPos
			strike.Parent   = workspace
			VFX.emit(strike)
			task.delay(4, function() strike:Destroy() end)

			if didHit then
				SoundController:PlaySound(ReplicatedStorage.Sounds.Events["Los Matteos"].Hit, targetPos, false)
			else
				SoundController:PlaySound(Sounds.OrbHitNothing, targetPos, false)
			end
		end

		debug.profileend()
	end))
end

local function pruneRecents()
	local now = workspace:GetServerTimeNow()
	for name, t in pairs(recentlyHit) do
		if now - t > 15 then recentlyHit[name] = nil end
	end
end

local function hasLightning(animal)
	local json = animal:GetAttribute("Traits")
	if not json then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return false end
	for _, trait in ipairs(decoded) do
		if trait == "Lightning" then return true end
	end
	return false
end

local function pickTarget()
	pruneRecents()

	if math.random(1, 100) <= 35 then
		local candidates = {}
		for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
			if animal.PrimaryPart
			and not recentlyHit[animal.Name]
			and not hasLightning(animal) then
				table.insert(candidates, animal)
			end
		end

		if #candidates > 0 then
			local animal  = candidates[math.random(1, #candidates)]
			local flight  = Random.new():NextNumber(1.5, 2.5)
			local vel     = Vector3.zero
			if animal.PrimaryPart:IsA("BasePart") then
				vel = animal.PrimaryPart.AssemblyLinearVelocity
			end
			local predicted = animal.PrimaryPart.Position + vel * flight
			if SharedEventUtils.isPointInCarpet(predicted) then
				recentlyHit[animal.Name] = workspace:GetServerTimeNow()
				return predicted, flight, true
			end
		end
	end

	local wanderFolder = workspace.Events:FindFirstChild("Wander")
	if wanderFolder then
		local parts = wanderFolder:GetChildren()
		if #parts > 0 then
			local flight = Random.new():NextNumber(1.5, 2.5)
			return parts[Random.new():NextInteger(1, #parts)].Position, flight, false
		end
	end

	return nil, nil, false
end

local function loop()
	local gate = timeLeftFor(7.7)
	if gate > 0 then task.wait(gate) end

	while EventController:GetActiveEventData("Mygame43") do
		task.wait(Random.new():NextNumber(2, 4))
		if not EventController:GetActiveEventData("Mygame43") then break end

		local numBalls = math.random(1, 2)
		for i = 1, numBalls do
			if not EventController:GetActiveEventData("Mygame43") then break end

			local targetPos, flightDuration, didHit = pickTarget()
			if targetPos then
				local seed     = Random.new():NextInteger(1, 999999)
				local orbIndex = Random.new():NextInteger(1, 4)
				fireOrb(seed, orbIndex, targetPos, flightDuration, didHit)
			end

			if i < numBalls then task.wait(0.5) end
		end
	end

	trove:Destroy()
	recentlyHit = {}
end

task.spawn(loop)
