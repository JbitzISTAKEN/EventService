local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local MathUtils        = require(ReplicatedStorage.Utils.MathUtils)
local Trove            = require(ReplicatedStorage.Packages.Trove)
local VFX              = require(ReplicatedStorage.Shared.VFX)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local ShakePresets     = require(ReplicatedStorage.Shared.ShakePresets)
local Shake            = require(ReplicatedStorage.Packages.Shake)
local EffectController = require(ReplicatedStorage.Controllers.EffectController)
local EventController  = require(ReplicatedStorage.Controllers.EventController)

local EVENT_NAME     = "Bombardiro Crocodilo"
local EventAssets    = ReplicatedStorage.Controllers.EventController.Events[EVENT_NAME]
local SvininaAsset   = EventAssets["Svinina Bombardino"]   -- drops as bomb (cloneObj)
local CrocodiloAsset = EventAssets["Bombardiro Crocodilo"] -- plane visual (cloneObj_2)
local ExplosionAsset = EventAssets["ExplosionBoom"]
local Sounds         = ReplicatedStorage.Sounds.Events[EVENT_NAME]

local SKY_OFFSET  = 200
local PLANE_SPEED = 25
local NUM_PLANES  = 6
local DROP_MIN    = 5
local DROP_MAX    = 10
local BOUNCE_H    = 2
local DRY_SPELL   = 25

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local startedAt = EventController:GetActiveEventData(EVENT_NAME).startedAt

local function timeLeftFor(t)
	return startedAt + t - workspace:GetServerTimeNow()
end

local shakeBase = Shake.new()
shakeBase.Amplitude         = 4.5
shakeBase.Frequency         = 0.05
shakeBase.FadeInTime        = 0
shakeBase.FadeOutTime       = 0.6
shakeBase.PositionInfluence = Vector3.new(0.5, 0.5, 0.5)
shakeBase.RotationInfluence = Vector3.new(2.5, 0.5, 0.5)

local trove            = Trove.new()
local recentlyHit      = {}
local planeModels      = {} -- [plane.Name] = Bombardiro Crocodilo model
local lastTraitApplied = os.clock()

local WanderFolder = workspace:WaitForChild("Events"):WaitForChild("Wander")

trove:Add(function()
	EffectController:Activate("Blink")
end)

-- ─── Helpers ──────────────────────────────────────────────────────────────────

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

local function getRandomWanderPosition(): Vector3
	local parts = WanderFolder:GetChildren()
	if #parts == 0 then return Vector3.new(0, SKY_OFFSET, 0) end
	local p    = parts[math.random(1, #parts)]
	local pos  = p.Position
	local size = p.Size
	return Vector3.new(
		pos.X + (math.random() - 0.5) * size.X,
		pos.Y + SKY_OFFSET,
		pos.Z + (math.random() - 0.5) * size.Z
	)
end

local function getGroundY(): number
	local parts = WanderFolder:GetChildren()
	if #parts == 0 then return 0 end
	local p = parts[math.random(1, #parts)]
	return p.Position.Y + p.Size.Y / 2
end

local function hasExplosive(animal: Model): boolean
	local json = animal:GetAttribute("Traits")
	if not json then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return false end
	for _, t in ipairs(decoded) do
		if t == "Explosive" then return true end
	end
	return false
end

local function pruneRecents()
	local now = workspace:GetServerTimeNow()
	for name, t in pairs(recentlyHit) do
		if now - t > 15 then recentlyHit[name] = nil end
	end
end

local function findValidAnimalTarget(): Model?
	local candidates = {}
	for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
		if animal.PrimaryPart and animal.Parent and not hasExplosive(animal) then
			table.insert(candidates, animal)
		end
	end
	if #candidates == 0 then return nil end
	return candidates[math.random(1, #candidates)]
end

local function isDrySpell(): boolean
	return (os.clock() - lastTraitApplied) >= DRY_SPELL
end

-- ─── Plane hitbox ─────────────────────────────────────────────────────────────

local function createPlaneHitbox(): BasePart
	local plane = Instance.new("Part")
	plane.Name         = HttpService:GenerateGUID(false)
	plane.Size         = Vector3.new(10, 5, 15)
	plane.Transparency = 1
	plane.CanCollide   = false
	plane.Anchored     = true
	plane.CFrame       = CFrame.new(getRandomWanderPosition())
	plane.Parent       = workspace
	return plane
end

-- ─── Plane movement ───────────────────────────────────────────────────────────

local function tweenPlaneToPosition(plane: BasePart, pos: Vector3)
	if not plane or not plane.Parent then return end
	local startPos = plane.Position
	local dist     = (pos - startPos).Magnitude
	local dur      = math.max(dist / PLANE_SPEED, 0.05)
	local T0       = os.clock()

	while os.clock() - T0 < dur and plane.Parent and EventController:GetActiveEventData(EVENT_NAME) do
		local p  = (os.clock() - T0) / dur
		local x  = startPos.X + (pos.X - startPos.X) * p
		local y  = startPos.Y + (pos.Y - startPos.Y) * p
		local z  = startPos.Z + (pos.Z - startPos.Z) * p
		local bo = math.sin(p * math.pi * 4) * BOUNCE_H * (1 - p * 0.3)
		local nx = startPos.X + (pos.X - startPos.X) * math.min(p + 0.01, 1)
		local nz = startPos.Z + (pos.Z - startPos.Z) * math.min(p + 0.01, 1)
		plane.CFrame = CFrame.lookAt(Vector3.new(x, y + bo, z), Vector3.new(nx, y + bo, nz))
		task.wait()
	end

	if plane.Parent and EventController:GetActiveEventData(EVENT_NAME) then
		local dir = (pos - startPos).Unit
		plane.CFrame = CFrame.lookAt(pos, pos + dir)
	end
end

local function flyPlane(plane: BasePart)
	while EventController:GetActiveEventData(EVENT_NAME) and plane.Parent do
		tweenPlaneToPosition(plane, getRandomWanderPosition())
		task.wait(0.5)
	end
end

-- ─── Bomb drop — Svinina Bombardino falls, 1:1 with original client ───────────

local function dropBomb(plane: BasePart)
	local dropPos   = Vector3.new(plane.Position.X, plane.Position.Y - plane.Size.Y / 2 - 1, plane.Position.Z)
	local groundY   = getGroundY()
	local impactPos = Vector3.new(dropPos.X, groundY, dropPos.Z)

	-- flash Crocodilo body on the plane briefly (mirrors original OnClientEvent behavior)
	local croco = planeModels[plane.Name]
	if croco then
		for _, child in croco["Svinina Bombardino"]:GetChildren() do
			if child.Name ~= "RootPart" and child:IsA("BasePart") then
				child.Transparency = 1
				task.delay(1, function() child.Transparency = 0 end)
			end
		end
	end

	-- Svinina Bombardino is the falling bomb — matches cloneObj in original
	local bomb = SvininaAsset:Clone()
	bomb.PrimaryPart.Anchored = true
	bomb:PivotTo(CFrame.new(dropPos))
	bomb.Parent = workspace
	trove:Add(bomb)

	local dropSound = Sounds.DroppingBomb:Clone()
	dropSound.Parent = bomb.PrimaryPart
	dropSound:Play()

	local elapsed  = 0
	local fallTime = MathUtils.calculateTimeToGround(dropPos.Y, groundY)

	local conn
	conn = trove:Add(RunService.PostSimulation:Connect(function(dt)
		debug.profilebegin("Bombardiro:Bomb")
		elapsed = elapsed + dt
		bomb:PivotTo(
			CFrame.new(dropPos - vector.create(0, MathUtils.simulateGravity(elapsed), 0))
			* CFrame.Angles(-elapsed * math.pi * 2, 0, 0)
		)
		if elapsed / fallTime >= 1 then
			trove:Remove(conn)
			conn = nil

			for _, d in bomb:GetDescendants() do
				if d:IsA("BasePart") then
					d.Transparency = 1
				elseif d:IsA("ParticleEmitter") then
					d:Destroy()
				end
			end
			task.delay(3, function() trove:Remove(bomb) end)

			-- explosion
			local explosion = ExplosionAsset:Clone()
			explosion.CFrame  = CFrame.new(impactPos)
			explosion.Parent  = workspace
			VFX.emit(explosion)
			task.delay(5, function() explosion:Destroy() end)

			local hitSound = Sounds:FindFirstChild("BombHit")
			if hitSound then
				SoundController:PlaySound(hitSound, impactPos, false)
			end

			shakeCameraBasedOnProximity(impactPos)

			-- apply explosive trait client-side
			for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
				if animal.PrimaryPart and animal.Parent then
					local apos = animal.PrimaryPart.Position
					local dist2d = Vector3.new(apos.X, 0, apos.Z) - Vector3.new(impactPos.X, 0, impactPos.Z)
					if dist2d.Magnitude <= 15 and not hasExplosive(animal) then
						local traits = {}
						local tj = animal:GetAttribute("Traits")
						if tj then
							local ok, decoded = pcall(HttpService.JSONDecode, HttpService, tj)
							if ok and type(decoded) == "table" then traits = decoded end
						end
						table.insert(traits, "Explosive")
						animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
						lastTraitApplied = os.clock()
					end
				end
			end
		end
		debug.profileend()
	end))
end

local function bombLoop(plane: BasePart)
	while EventController:GetActiveEventData(EVENT_NAME) and plane.Parent do
		task.wait(math.random(DROP_MIN, DROP_MAX))
		if not EventController:GetActiveEventData(EVENT_NAME) or not plane.Parent then break end

		-- dry spell: steer toward a valid animal first
		if isDrySpell() then
			local target = findValidAnimalTarget()
			if target and target.PrimaryPart then
				local above = Vector3.new(target.PrimaryPart.Position.X, plane.Position.Y, target.PrimaryPart.Position.Z)
				tweenPlaneToPosition(plane, above)
				if not EventController:GetActiveEventData(EVENT_NAME) or not plane.Parent then break end
			end
		end

		dropBomb(plane)
	end
end

-- ─── Sync Crocodilo model to plane hitbox every frame ────────────────────────

local activePlanes = {} -- ordered list for BulkMoveTo

trove:Add(RunService.PreRender:Connect(function()
	debug.profilebegin("Bombardiro:BulkMoveTo")
	local parts  = {}
	local frames = {}
	for _, plane in ipairs(activePlanes) do
		local model = planeModels[plane.Name]
		if plane.Parent and model and model.Parent then
			table.insert(parts,  model.PrimaryPart)
			table.insert(frames, plane.CFrame)
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	debug.profileend()
end))

-- ─── Spawn plane ──────────────────────────────────────────────────────────────

local function spawnPlane()
	local plane = createPlaneHitbox()
	trove:Add(plane)

	-- Bombardiro Crocodilo model is the plane visual — matches cloneObj_2
	-- starts with Svinina Bombardino children hidden for 5s (mirrors original observer)
	local croco = CrocodiloAsset:Clone()
	croco.PrimaryPart.Anchored = true
	for _, child in croco["Svinina Bombardino"]:GetChildren() do
		if child.Name ~= "RootPart" then
			child.Transparency = 1
		end
	end
	croco.Parent = workspace
	task.delay(5, function()
		if croco.Parent then
			for _, child in croco["Svinina Bombardino"]:GetChildren() do
				if child.Name ~= "RootPart" then
					child.Transparency = 0
				end
			end
		end
	end)

	planeModels[plane.Name] = croco
	table.insert(activePlanes, plane)

	trove:Add(croco)
	trove:Add(function()
		planeModels[plane.Name] = nil
		local idx = table.find(activePlanes, plane)
		if idx then table.remove(activePlanes, idx) end
	end)

	trove:Add(task.spawn(function() flyPlane(plane) end))
	trove:Add(task.spawn(function() bombLoop(plane) end))
end

-- ─── Entry ────────────────────────────────────────────────────────────────────

local function loop()
	local gate = timeLeftFor(8)
	if gate > 0 then task.wait(gate) end

	for i = 1, NUM_PLANES do
		if not EventController:GetActiveEventData(EVENT_NAME) then break end
		spawnPlane()
		task.wait(0.5)
	end

	while EventController:GetActiveEventData(EVENT_NAME) do
		task.wait(1)
	end

	trove:Destroy()
	recentlyHit  = {}
	planeModels  = {}
	activePlanes = {}
end

task.spawn(loop)
