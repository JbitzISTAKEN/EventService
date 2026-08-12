local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

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
local SvininaAsset   = EventAssets["Svinina Bombardino"]   -- plane visual model
local CrocodiloAsset = EventAssets["Bombardiro Crocodilo"] -- falling bomb model
local ExplosionAsset = EventAssets["ExplosionBoom"]        -- BasePart VFX
local Sounds         = ReplicatedStorage.Sounds.Events[EVENT_NAME]

local SKY_OFFSET  = 200
local PLANE_SPEED = 25
local NUM_PLANES  = 6
local DROP_MIN    = 5
local DROP_MAX    = 10
local BOUNCE_H    = 2

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

local trove       = Trove.new()
local recentlyHit = {}

-- plane hitbox (invisible BasePart) → svinina model tracks it via BulkMoveTo
-- [plane.Name] = svinina Model in workspace
local planeModels = {}

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

local function pickTarget(): (Vector3?, number?, boolean?)
	pruneRecents()

	if math.random(1, 100) <= 35 then
		local candidates = {}
		for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
			if animal.PrimaryPart
				and not recentlyHit[animal.Name]
				and not hasExplosive(animal) then
				table.insert(candidates, animal)
			end
		end
		if #candidates > 0 then
			local animal = candidates[math.random(1, #candidates)]
			local flight = Random.new():NextNumber(1.5, 2.5)
			local vel    = Vector3.zero
			if animal.PrimaryPart:IsA("BasePart") then
				vel = animal.PrimaryPart.AssemblyLinearVelocity
			end
			recentlyHit[animal.Name] = workspace:GetServerTimeNow()
			return animal.PrimaryPart.Position + vel * flight, flight, true
		end
	end

	local parts = WanderFolder:GetChildren()
	if #parts > 0 then
		return parts[math.random(1, #parts)].Position, Random.new():NextNumber(1.5, 2.5), false
	end

	return nil, nil, false
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

-- ─── Plane movement — loops forever until event ends ──────────────────────────

local function flyPlane(plane: BasePart)
	while EventController:GetActiveEventData(EVENT_NAME) and plane.Parent do
		local target   = getRandomWanderPosition()
		local startPos = plane.Position
		local dist     = (target - startPos).Magnitude
		local dur      = math.max(dist / PLANE_SPEED, 0.05)
		local elapsed  = 0
		local done     = false

		local conn
		conn = trove:Add(RunService.PostSimulation:Connect(function(dt)
			debug.profilebegin("Bombardiro:FlyPlane")
			if not plane.Parent then
				conn:Disconnect()
				done = true
				debug.profileend()
				return
			end
			elapsed = elapsed + dt
			local p  = math.clamp(elapsed / dur, 0, 1)
			local x  = startPos.X + (target.X - startPos.X) * p
			local y  = startPos.Y + (target.Y - startPos.Y) * p
			local z  = startPos.Z + (target.Z - startPos.Z) * p
			local bo = math.sin(p * math.pi * 4) * BOUNCE_H * (1 - p * 0.3)
			local nx = startPos.X + (target.X - startPos.X) * math.min(p + 0.01, 1)
			local nz = startPos.Z + (target.Z - startPos.Z) * math.min(p + 0.01, 1)
			plane.CFrame = CFrame.lookAt(
				Vector3.new(x, y + bo, z),
				Vector3.new(nx, y + bo, nz)
			)
			if p >= 1 then
				conn:Disconnect()
				done = true
			end
			debug.profileend()
		end))

		repeat task.wait() until done
			or not plane.Parent
			or not EventController:GetActiveEventData(EVENT_NAME)
		task.wait(0.3)
	end
end

-- ─── Drop Bombardiro Crocodilo model as falling bomb ──────────────────────────

local function dropBomb(plane: BasePart)
	local dropPos   = plane.Position - Vector3.new(0, plane.Size.Y / 2 + 1, 0)
	local groundY   = getGroundY()
	local impactPos = Vector3.new(dropPos.X, groundY, dropPos.Z)

	-- clone the full Bombardiro Crocodilo model — this is what falls
	local bomb = CrocodiloAsset:Clone()
	bomb.PrimaryPart.Anchored = true
	bomb:PivotTo(CFrame.new(dropPos))
	bomb.Parent = workspace
	trove:Add(bomb)

	local dropSound = Sounds.DroppingBomb:Clone()
	dropSound.Parent = bomb.PrimaryPart
	dropSound:Play()

	local gravity  = workspace.Gravity
	local dist     = math.max(dropPos.Y - groundY, 0)
	local fallTime = math.sqrt(2 * dist / gravity)
	local elapsed  = 0

	local conn
	conn = trove:Add(RunService.PostSimulation:Connect(function(dt)
		debug.profilebegin("Bombardiro:Bomb")
		elapsed = elapsed + dt
		local fall = 0.5 * gravity * elapsed * elapsed
		bomb:PivotTo(
			CFrame.new(dropPos - Vector3.new(0, fall, 0))
			* CFrame.Angles(-elapsed * math.pi * 2, 0, 0)
		)
		if elapsed >= fallTime then
			trove:Remove(conn)
			conn = nil

			-- hide bomb parts, let particles finish
			for _, d in bomb:GetDescendants() do
				if d:IsA("BasePart") then
					d.Transparency = 1
				elseif d:IsA("ParticleEmitter") then
					d:Destroy()
				end
			end
			task.delay(3, function() trove:Remove(bomb) end)

			-- explosion VFX
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
		end
		debug.profileend()
	end))
end

-- ─── Bomb loop — steer then drop, repeat ──────────────────────────────────────

local function bombLoop(plane: BasePart)
	while EventController:GetActiveEventData(EVENT_NAME) and plane.Parent do
		task.wait(math.random(DROP_MIN, DROP_MAX))
		if not EventController:GetActiveEventData(EVENT_NAME) or not plane.Parent then break end

		local targetPos, _, didHit = pickTarget()

		-- steer plane above target before dropping
		if targetPos and didHit then
			local above        = Vector3.new(targetPos.X, plane.Position.Y, targetPos.Z)
			local steerDist    = (above - plane.Position).Magnitude
			local steerTime    = math.max(steerDist / PLANE_SPEED, 0.05)
			local steerStart   = plane.Position
			local steerElapsed = 0
			local steerDone    = false

			local steerConn
			steerConn = trove:Add(RunService.PostSimulation:Connect(function(dt)
				debug.profilebegin("Bombardiro:Steer")
				if not plane.Parent then
					steerConn:Disconnect()
					steerDone = true
					debug.profileend()
					return
				end
				steerElapsed = steerElapsed + dt
				local p  = math.clamp(steerElapsed / steerTime, 0, 1)
				local nx = steerStart.X + (above.X - steerStart.X) * p
				local nz = steerStart.Z + (above.Z - steerStart.Z) * p
				plane.CFrame = CFrame.lookAt(
					Vector3.new(nx, plane.Position.Y, nz),
					Vector3.new(above.X, plane.Position.Y, above.Z)
				)
				if p >= 1 then
					steerConn:Disconnect()
					steerDone = true
				end
				debug.profileend()
			end))

			repeat task.wait() until steerDone or not plane.Parent
		end

		if plane.Parent and EventController:GetActiveEventData(EVENT_NAME) then
			dropBomb(plane)
		end
	end
end

-- ─── Sync svinina visuals to plane hitbox CFrame every frame ─────────────────

trove:Add(RunService.PreRender:Connect(function()
	debug.profilebegin("Bombardiro:BulkMoveTo")
	local parts  = {}
	local frames = {}
	for name, model in pairs(planeModels) do
		local plane = workspace:FindFirstChild(name)
		if plane and plane:IsA("BasePart") and model and model.Parent then
			table.insert(parts,  model.PrimaryPart)
			table.insert(frames, plane.CFrame)
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	debug.profileend()
end))

-- ─── Spawn one plane + its svinina visual + both loops ────────────────────────

local function spawnPlane()
	local plane = createPlaneHitbox()
	trove:Add(plane)

	-- svinina is the plane visual — lives in workspace, tracked by BulkMoveTo
	local svinina = SvininaAsset:Clone()
	svinina.PrimaryPart.Anchored = true
	svinina.Parent = workspace
	planeModels[plane.Name] = svinina
	trove:Add(svinina)

	VFX.enable(svinina)

	trove:Add(task.spawn(function() flyPlane(plane) end))
	trove:Add(task.spawn(function() bombLoop(plane) end))
end

-- ─── Main loop — mirrors Mygame43 structure exactly ───────────────────────────

local function loop()
	local gate = timeLeftFor(8)
	if gate > 0 then task.wait(gate) end

	-- spawn all planes staggered
	for i = 1, NUM_PLANES do
		if not EventController:GetActiveEventData(EVENT_NAME) then break end
		spawnPlane()
		task.wait(0.5)
	end

	-- hold until event dies
	while EventController:GetActiveEventData(EVENT_NAME) do
		task.wait(1)
	end

	trove:Destroy()
	recentlyHit = {}
	planeModels = {}
end

task.spawn(loop)
