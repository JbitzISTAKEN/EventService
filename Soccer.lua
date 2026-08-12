-- LocalScript: SoccerLogic
-- StarterPlayerScripts

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local PhysicsService    = game:GetService("PhysicsService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local Timer            = require(ReplicatedStorage.Packages.Timer)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)

local EventScript = ReplicatedStorage.Controllers.EventController.Events.Soccer

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove                           = Trove.new()
local recentlyTargeted: {[string]: number} = {}
local isActive                             = true

local rng = Random.new()

-- rain state — mirrors u18/u19/u20 from decompiled
local rainEndClock  = 0
local rainCenter    = Vector3.new(0, 0, 0)
local rainSize      = Vector3.new(0, 0, 0)

-- ─── Physics ──────────────────────────────────────────────────────────────────

pcall(function()
	if not PhysicsService:IsCollisionGroupRegistered("SoccerBall") then
		PhysicsService:RegisterCollisionGroup("SoccerBall")
	end
	PhysicsService:CollisionGroupSetCollidable("SoccerBall", "Player", false)
	PhysicsService:CollisionGroupSetCollidable("SoccerBall", "Animal", false)
end)

-- ─── Ball rain folder ─────────────────────────────────────────────────────────

local SoccerBallRain = Instance.new("Folder")
SoccerBallRain.Name   = "SoccerBallRain"
SoccerBallRain.Parent = workspace
eventTrove:Add(SoccerBallRain)

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

local function hasSoccerTrait(animal: Instance): boolean
	for _, t in decodeTraits(animal) do
		if t == "SoccerBall" or t == "Ball" then return true end
	end
	return false
end

local function addSoccerTrait(animal: Instance)
	local traits = decodeTraits(animal)
	for _, t in traits do
		if t == "SoccerBall" or t == "Ball" then return end
	end
	table.insert(traits, "SoccerBall")
	local ok, enc = pcall(HttpService.JSONEncode, HttpService, traits)
	if ok then animal:SetAttribute("Traits", enc) end
end

local function getValidCandidates(): {Instance}
	local now = workspace:GetServerTimeNow()
	for name, last in pairs(recentlyTargeted) do
		if now - last > 30 then recentlyTargeted[name] = nil end
	end

	local candidates = {}
	for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
		if animal and animal.Parent and animal.PrimaryPart
			and not recentlyTargeted[animal.Name]
			and not hasSoccerTrait(animal)
			and SharedEventUtils.isPointInCarpet(animal.PrimaryPart.Position)
		then
			table.insert(candidates, animal)
		end
	end

	print("[Soccer] Valid candidates:", #candidates)
	return candidates
end

-- ─── spawnBall — 1:1 with decompiled spawnBall() ─────────────────────────────

local function spawnBall(spawnPos: Vector3, velocity: Vector3, onLand: ((Vector3) -> ())?, trackAnimal: Instance?)
	local SoccerBall = EventScript:FindFirstChild("SoccerBall")
	if not (SoccerBall and SoccerBall:IsA("BasePart")) then
		warn("[Soccer] SoccerBall BasePart not found in EventScript")
		return
	end

	local ball = SoccerBall:Clone()
	ball.Anchored              = false
	ball.CanCollide            = true
	ball.CanQuery              = false
	ball.CanTouch              = true
	ball.Massless              = false
	ball.CollisionGroup        = "SoccerBall"
	ball.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.75, 1, 1)
	ball.CFrame = CFrame.new(spawnPos)
		* CFrame.Angles(
			rng:NextNumber(0, math.pi * 2),
			rng:NextNumber(0, math.pi * 2),
			rng:NextNumber(0, math.pi * 2)
		)
	ball.AssemblyLinearVelocity  = velocity
	ball.AssemblyAngularVelocity = Vector3.new(
		rng:NextNumber(-12, 12),
		rng:NextNumber(-12, 12),
		rng:NextNumber(-12, 12)
	)
	ball.Parent = SoccerBallRain

	-- no-collide with local character — mirrors decompiled block exactly
	local character = Players.LocalPlayer.Character
	if character then
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				local nc    = Instance.new("NoCollisionConstraint")
				nc.Part0    = ball
				nc.Part1    = part
				nc.Parent   = ball
			end
		end
	end

	local landed = false
	local fading = false

	-- mirrors fadeOut() from decompiled
	local function fadeOut()
		if fading or not ball.Parent then return end
		fading = true
		local tween = TweenService:Create(ball, TweenInfo.new(0.4), { Transparency = 1 })
		tween:Play()
		tween.Completed:Once(function()
			if ball.Parent then ball:Destroy() end
		end)
	end

	local touchConn: RBXScriptConnection
	local trackConn: RBXScriptConnection

	-- mirrors Touched connect from decompiled — same Y check, same folder check, same humanoid skip
	touchConn = ball.Touched:Connect(function(hit)
		if landed then return end
		if ball.CFrame.Position.Y > spawnPos.Y - 20 then return end
		if hit:IsDescendantOf(SoccerBallRain) then return end

		if not trackAnimal then
			local model = hit:FindFirstAncestorWhichIsA("Model")
			if model and model:FindFirstChildWhichIsA("Humanoid") then return end
		end

		landed = true
		touchConn:Disconnect()

		if trackConn then
			trackConn:Disconnect()
			trackConn = nil
		end

		if onLand then
			task.spawn(onLand, ball.CFrame.Position)
		end

		task.delay(rng:NextNumber(1, 2), fadeOut)
	end)

	-- homing toward tracked animal — mirrors PostSimulation block from decompiled exactly
	-- lateral push * 8, capped at 60 studs/s, Y velocity preserved
	if trackAnimal then
		trackConn = RunService.PostSimulation:Connect(function()
			if landed or not ball.Parent then
				if trackConn then trackConn:Disconnect() trackConn = nil end
				return
			end

			-- try ClientEventUtils first, fall back to getAnimalTop for spoofed animals
			local cur = ClientEventUtils.getAnimalPosition(trackAnimal, { top = true })
			if not cur or cur == Vector3.new(0, 0, 0) then
				cur = getAnimalTop(trackAnimal)
			end
			if not cur then return end

			local dir = Vector3.new(cur.X - ball.Position.X, 0, cur.Z - ball.Position.Z) * 8
			if dir.Magnitude > 60 then dir = dir.Unit * 60 end
			ball.AssemblyLinearVelocity = Vector3.new(dir.X, ball.AssemblyLinearVelocity.Y, dir.Z)
		end)
	end

	-- safety cleanup at 6s — mirrors decompiled task.delay(6)
	task.delay(6, function()
		if not landed then fadeOut() end
	end)
end

-- ─── dropBall — mirrors decompiled dropBall() exactly ────────────────────────

local BallHitGround = ReplicatedStorage.Sounds.Events.Soccer.BallHitGround

local function dropBall(pos: Vector3)
	spawnBall(
		pos,
		Vector3.new(rng:NextNumber(-22, 22), rng:NextNumber(-14, -4), rng:NextNumber(-22, 22)),
		function(landPos)
			-- mirrors playImpactSound — sound tracked in trove so it cleans on stop
			local sound = SoundController:PlaySound(BallHitGround, landPos, false)
			if sound then
				eventTrove:Add(sound)
				sound.Ended:Once(function()
					eventTrove:Remove(sound)
				end)
			end
		end
	)
end

-- ─── playBurst — mirrors decompiled playBurst() exactly ──────────────────────

local function playBurst(animal: Instance)
	local burstPart = EventScript:FindFirstChild("Burst")
	if not (burstPart and burstPart:IsA("BasePart")) then return end
	local rootPart = animal.PrimaryPart
	if not rootPart then return end
	ClientEventUtils.playBurst(
		burstPart,
		rootPart,
		{ ReplicatedStorage.Sounds.Events.Soccer.Burst }
	)
end

-- ─── Strike — mirrors Strike:OnClientEvent from decompiled ───────────────────
-- original: getAnimalPosition → spawnBall 45 above → onLand: playBurst + FireServer
-- local version: getAnimalTop fallback, addSoccerTrait instead of FireServer

local function strikeAnimal(animal: Instance)
	if not animal or not animal.Parent or not animal.PrimaryPart then return end

	recentlyTargeted[animal.Name] = workspace:GetServerTimeNow()

	local animalPos = getAnimalTop(animal)
	if not animalPos then return end

	print("[Soccer] Striking:", animal.Name)

	spawnBall(
		animalPos + Vector3.new(0, 45, 0),
		Vector3.new(0, -10, 0),
		function()
			if not animal or not animal.Parent then return end
			playBurst(animal)
			addSoccerTrait(animal)
			print("[Soccer] SoccerBall trait applied:", animal.Name)
		end,
		animal
	)
end

-- ─── Rain loop — mirrors Timer.Simple(0.2) + u18/u19/u20 from decompiled ─────

local function startRain(center: Vector3, size: Vector3, duration: number)
	rainCenter   = center
	rainSize     = size
	-- mirrors: u18 = os.clock() + math.max(0, endTime - serverNow)
	rainEndClock = os.clock() + duration

	print("[Soccer] Rain started — center:", center, "duration:", duration)
end

eventTrove:Add(Timer.Simple(0.2, function()
	-- mirrors decompiled: if u18 <= os.clock() or u20 == Vector3.zero then return end
	if rainEndClock <= os.clock() or rainSize == Vector3.zero then return end

	for _ = 1, 2 do
		local x = (math.random() - 0.5) * rainSize.X
		local y = (math.random() - 0.5) * rainSize.Y
		local z = (math.random() - 0.5) * rainSize.Z
		dropBall(rainCenter + Vector3.new(x, y, z))
	end
end))

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
				strikeAnimal(candidates[math.random(1, #candidates)])
			end
		end
	end))
end

-- ─── Rain refresh loop — mirrors server refresh every 25s ────────────────────

local function startRainRefresh(center: Vector3, size: Vector3)
	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(25)
			if not isActive then break end
			-- mirrors: miniEventRemote:FireAllClients(serverNow + 30, center, size)
			startRain(center, size, 30)
			print("[Soccer] Rain refreshed")
		end
	end))
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	-- wait for Soccer event assets — EventScript needs SoccerBall and Burst children
	while not EventScript:FindFirstChild("SoccerBall") do
		task.wait(0.1)
	end

	print("[Soccer] Ready")

	-- derive rain center from scoreboard, mirrors server Soccer.OnStart
	local scoreboard = workspace:FindFirstChild("SoccerScoreBoard")
	local centerPos  = scoreboard and scoreboard:GetPivot().Position or Vector3.new(0, 50, 0)
	local size       = Vector3.new(40, 10, 40)
	local duration   = 300

	-- mirrors task.delay(2) before first miniEventRemote:FireAllClients
	task.delay(2, function()
		if not isActive then return end
		startRain(centerPos, size, duration)
	end)

	startRainRefresh(centerPos, size)
	startAttackLoop()
end

task.spawn(main)
