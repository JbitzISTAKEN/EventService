
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local Debris            = game:GetService("Debris")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EvLightning     = require(ReplicatedStorage.Packages.EvLightning)
local Shake           = require(ReplicatedStorage.Packages.Shake)
local ShakePresets    = require(ReplicatedStorage.Shared.ShakePresets)
local VFX             = require(ReplicatedStorage.Shared.VFX)
local SoundController = require(ReplicatedStorage.Controllers.SoundController)
local EventController = require(ReplicatedStorage.Controllers.EventController)
local MapInfo         = require(ReplicatedStorage.Shared.MapInformation)

local EVENT_NAME  = "Los Matteos"
local TRAIT_NAME  = "Matteo Hat"

local EVENT_SCRIPT = ReplicatedStorage.Controllers.EventController.Events["Los Matteos"]
local Sounds       = ReplicatedStorage.Sounds.Events["Los Matteos"]

-- ─── Constants ────────────────────────────────────────────────────────────────

local LIGHTNING_START_DELAY = 8
local LIGHTNING_INTERVAL    = 0.5
local FORCE_HIT_AFTER       = 10
local HIT_CHANCE            = 5
local RETARGET_COOLDOWN     = 15
local ROOTS_START_DELAY     = 7
local ROOTS_GROW_DURATION   = 5
local ROOTS_ASSET_ID        = "rbxassetid://103628309756671"
local CLOUD_STRIKE_RADIUS   = 100
local CLOUD_STRIKE_COLOR    = Color3.fromRGB(90, 109, 161)

-- ─── Cloud pool (mirrors v99 in decompiled client) ────────────────────────────

-- Each entry: { instance: BasePart, speed: number, startPos: Vector3, endPos: Vector3 }
local cloudPool: { { instance: BasePart, speed: number, startPos: Vector3, endPos: Vector3 } } = {}

-- ─── Preload roots ────────────────────────────────────────────────────────────

local rootsTemplate: Model? = nil

task.spawn(function()
	local objects = game:GetObjects(ROOTS_ASSET_ID)
	local obj     = objects and objects[1]
	if obj then
	obj.Name   = "Roots"
	obj.Parent = ReplicatedStorage
	rootsTemplate = obj
		else
		warn("[LosMatteos] Failed to load roots asset")
	end
end)

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

local function timeLeftFor(t)
	return startedAt + t - workspace:GetServerTimeNow()
end

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove      = Trove.new()
local isActive        = true
local strikesSinceHit = 0
local recentlyTargeted: { [string]: number } = {}
local strikeId        = 0

-- ─── Bolt part template ───────────────────────────────────────────────────────

local boltPart = Instance.new("Part")
boltPart.Anchored      = true
boltPart.CanCollide    = false
boltPart.TopSurface    = Enum.SurfaceType.Smooth
boltPart.BottomSurface = Enum.SurfaceType.Smooth
boltPart.Material      = Enum.Material.Neon
boltPart.Color         = Color3.fromRGB(96, 234, 255)

-- ─── Shake ────────────────────────────────────────────────────────────────────

local shakeBase = Shake.new()
shakeBase.Amplitude         = 3
shakeBase.Frequency         = 0.1
shakeBase.FadeInTime        = 0
shakeBase.FadeOutTime       = 0.6
shakeBase.PositionInfluence = Vector3.new(0.5, 0.5, 0.5)
shakeBase.RotationInfluence = Vector3.new(2.5, 0.5, 0.5)

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function animalHasTrait(animal: Model): boolean
	local json = animal:GetAttribute("Traits")
	if type(json) ~= "string" then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return false end
	for _, t in ipairs(decoded) do
		if t == TRAIT_NAME then return true end
	end
	return false
end

local function giveTrait(animal: Model)
	if not animal or not animal.Parent then return end
	local traits = {}
	local json   = animal:GetAttribute("Traits")
	if type(json) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
		if ok and type(decoded) == "table" then traits = decoded end
	end
	table.insert(traits, TRAIT_NAME)
	animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function getRainArea(): BasePart?
	local folder = workspace:FindFirstChild("Events")
	local model  = folder and folder:FindFirstChild("Los Matteos")
	return model and model:FindFirstChild("RainArea") :: BasePart
end

-- ─── Cloud pool registration ──────────────────────────────────────────────────
-- Call this whenever a cloud part is spawned into the scene so fireLocalLightning
-- can pick from it. Mirrors the table.insert(v99, ...) calls in the decompiled client.

local function registerCloud(inst: BasePart, speed: number, startPos: Vector3, endPos: Vector3)
	table.insert(cloudPool, {
		instance = inst,
		speed    = speed,
		startPos = startPos,
		endPos   = endPos,
	})
end

local function unregisterCloud(inst: BasePart)
	for i = #cloudPool, 1, -1 do
		if cloudPool[i].instance == inst then
			table.remove(cloudPool, i)
			break
		end
	end
end

-- ─── Lightning ────────────────────────────────────────────────────────────────

local function fireLocalLightning(strikePos: Vector3, hitAnimal: boolean)
	strikeId += 1
	local rng = Random.new(strikeId)

	-- camera shake
	local camDist = (workspace.CurrentCamera.CFrame.Position - strikePos).Magnitude
	if camDist <= 75 then
		local s   = shakeBase:Clone()
		local fac = (1 - camDist / 75 * 0.5) ^ 2
		s.Amplitude         = s.Amplitude * fac
		s.RotationInfluence = s.RotationInfluence * fac
		ShakePresets.BindShakeToCamera(s)
		s:Start()
	end

	-- pick bolt origin from cloud pool (mirrors decompiled v99 cloud pick)
	local nearbyClouds = {}
	for _, entry in cloudPool do
		local flat = (entry.instance.Position - strikePos) * Vector3.new(1, 0, 1)
		if flat.Magnitude < CLOUD_STRIKE_RADIUS then
			table.insert(nearbyClouds, entry.instance)
		end
	end

	local boltStart: Vector3
	if #nearbyClouds > 0 then
		local chosenCloud = nearbyClouds[rng:NextInteger(1, #nearbyClouds)]
		boltStart = chosenCloud.Position

		-- tint cloud on strike, tween back (mirrors decompiled flash)
		local originalColor = chosenCloud.Color
		chosenCloud.Color = CLOUD_STRIKE_COLOR
		TweenService:Create(
			chosenCloud,
			TweenInfo.new(1, Enum.EasingStyle.Sine),
			{ Color = originalColor }
		):Play()

		-- cloud particles on strike (mirrors script.CloudParticles loop)
		if EVENT_SCRIPT:FindFirstChild("CloudParticles") then
			for _, particle in EVENT_SCRIPT.CloudParticles:GetChildren() do
				local p = particle:Clone()
				p.Parent = chosenCloud
				VFX.emit(p)
				Debris:AddItem(p, 2)
			end
		end

		SoundController:PlaySound(Sounds["Lightning Strike"], chosenCloud.Position, false)
	else
		boltStart = strikePos + Vector3.new(0, 70, 0)
		SoundController:PlaySound(Sounds["Lightning Strike"], boltStart, false)
	end

	-- build bolt
	local bolt = EvLightning.create(boltStart, strikePos, {
		bends       = 4,
		thickness   = 1,
		max_depth   = 1,
		fork_bends  = 1,
		fork_chance = 30,
		decay       = 3,
		material    = Enum.Material.Neon,
	})

	local boltModel = Instance.new("Model")
	boltModel.Name = "LightningBolt"
	bolt.model     = boltModel

	local lines = bolt:GetLines()
	table.sort(lines, function(a, b) return a.origin.Y > b.origin.Y end)

	local highestY  = lines[1].origin.Y
	local lowestY   = lines[#lines].origin.Y
	local yRange    = math.max(highestY - lowestY, 1)
	local baseDelay = bolt.random:NextInteger(10, 20) / 100

	local tweenedParts = {}

	for i, line in lines do
		if line.goal.Y >= strikePos.Y then
			local t    = math.max((highestY - line.origin.Y) / yRange * baseDelay, 0)
			local part = boltPart:Clone()
			part.Size  = Vector3.new(
				bolt.thickness - line.depth * 2 * 0.1,
				bolt.thickness - line.depth * 2 * 0.1,
				(line.origin - line.goal).Magnitude + 0.5
			)
			part.CFrame       = CFrame.new((line.goal + line.origin) / 2, line.goal)
			part.Transparency = 1
			part.Parent       = boltModel
			tweenedParts[i]   = part

			TweenService:Create(
				part,
				TweenInfo.new(0.05, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, t),
				{ Transparency = line.transparency }
			):Play()
		end
	end

	task.delay(baseDelay + 0.05, function()
		local strikeAsset = if hitAnimal
			then EVENT_SCRIPT.StrikeBrainrot:Clone()
			else EVENT_SCRIPT.Strike:Clone()

		strikeAsset.Position = strikePos
		strikeAsset.Parent   = workspace
		VFX.emit(strikeAsset)

		if hitAnimal then
			SoundController:PlaySound(Sounds.Hit, strikePos, false)
		else
			SoundController:PlaySound(Sounds.HitNothing, strikePos, false)
		end

		for _, p in tweenedParts do
			if not p then continue end
			task.spawn(function()
				p.Transparency = 0
				task.wait(0.1)
				p.Transparency = 1
				task.wait(0.1)
				TweenService:Create(
					p,
					TweenInfo.new(0.1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, true),
					{ Transparency = 0.4 }
				):Play()
			end)
		end

		task.delay(bolt.options.decay or 1, function()
			strikeAsset:Destroy()
			boltModel:Destroy()
			bolt.destroyed = true
		end)
	end)

	boltModel.Parent = workspace.CurrentCamera
	bolt.drew        = true
end

-- ─── Strike logic ─────────────────────────────────────────────────────────────

local function runLightningStrike()
	local rainArea = getRainArea()
	if not rainArea then return end

	local s, cf       = rainArea.Size, rainArea.CFrame
	local strikeCount = math.random(1, 2)

	for i = 1, strikeCount do
		local strikePos = (cf * CFrame.new(
			math.random(-s.X / 2, s.X / 2),
			0,
			math.random(-s.Z / 2, s.Z / 2)
		)).Position

		local forceHit  = strikesSinceHit >= FORCE_HIT_AFTER
		local shouldHit = forceHit or (math.random(1, 100) <= HIT_CHANCE)

		if shouldHit then
			local now = workspace:GetServerTimeNow()
			for name, lastTime in pairs(recentlyTargeted) do
				if (now - lastTime) > RETARGET_COOLDOWN then
					recentlyTargeted[name] = nil
				end
			end

			local candidates = {}
			for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
				if not animal:IsA("Model") or not animal.PrimaryPart then continue end
				if recentlyTargeted[animal.Name] then continue end
				if animalHasTrait(animal) then continue end
				local dist = (animal.PrimaryPart.Position - strikePos).Magnitude
				if forceHit or dist <= 150 then
					table.insert(candidates, { animal = animal, distance = dist })
				end
			end

			if #candidates > 0 then
				table.sort(candidates, function(a, b) return a.distance < b.distance end)
				local targetAnimal = candidates[1].animal :: Model
				local pp           = targetAnimal.PrimaryPart
				local hatPos       = pp.Position + Vector3.new(0, targetAnimal:GetExtentsSize().Y * 0.5, 0)

				recentlyTargeted[targetAnimal.Name] = workspace:GetServerTimeNow()
				strikesSinceHit = 0

				task.delay(0.15, giveTrait, targetAnimal)
				task.spawn(fireLocalLightning, hatPos, true)
			else
				strikesSinceHit += 1
				task.spawn(fireLocalLightning, strikePos, false)
			end
		else
			strikesSinceHit += 1
			task.spawn(fireLocalLightning, strikePos, false)
		end

		if i < strikeCount then task.wait(0.3) end
	end
end

-- ─── Cloud spawner (mirrors v142/v128 in decompiled client) ──────────────────

local function startClouds()
	local cloudsStart = workspace.Events["Los Matteos"]:FindFirstChild("CloudsStart")
	local cloudsEnd   = workspace.Events["Los Matteos"]:FindFirstChild("CloudsEnd")
	if not cloudsStart or not cloudsEnd then
		warn("[LosMatteos] CloudsStart or CloudsEnd not found")
		return
	end

	local cloudTemplates = EVENT_SCRIPT.Clouds:GetChildren()
	if #cloudTemplates == 0 then
		warn("[LosMatteos] No cloud templates found")
		return
	end

	local startPos  = cloudsStart.Position
	local startSize = cloudsStart.Size
	local endPos    = cloudsEnd.Position

	local function spawnCloud(row: number?, col: number?)
		local zOffset = startPos.Z + (row or 0) * 30 + (col or 0)
		local template = cloudTemplates[math.random(1, #cloudTemplates)]
		local cloud    = eventTrove:Clone(template)
		cloud.Transparency = 1

		cloud.CFrame = CFrame.new(
			startPos.X + math.random(-startSize.X * 0.5, startSize.X * 0.5),
			startPos.Y,
			zOffset
		)

		local targetPos = Vector3.new(cloud.Position.X, startPos.Y, endPos.Z)

		-- skip clouds already past the end
		if (endPos - startPos):Dot(targetPos - cloud.Position) < 0 then
			cloud:Destroy()
			return
		end

		cloud.Parent = workspace.CurrentCamera

		local speed = math.clamp(50 / cloud.Size.Magnitude, 5, 15) * (math.random(80, 120) / 100)
		local colDelay = (col or 0) * 0.1 + (math.abs(row or 0) + 1) * 0.5

		TweenService:Create(
			cloud,
			TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, colDelay),
			{ Transparency = 0 }
		):Play()

		local entry = {
			instance = cloud,
			speed    = speed,
			startPos = cloud.Position,
			endPos   = targetPos,
		}
		registerCloud(cloud, speed, cloud.Position, targetPos)

		return entry
	end

	-- initial spawn: 50 clouds, same row/col pattern as decompiled
	local row = 0
	for col = 1, 50 do
		spawnCloud(row, col)
		if col % 3 == 1 then
			row += 1
		end
	end

	-- movement loop (mirrors PostSimulation connect in decompiled)
	eventTrove:Add(RunService.PostSimulation:Connect(function(dt)
		for i = #cloudPool, 1, -1 do
			local entry = cloudPool[i]
			local inst  = entry.instance
			if not inst or not inst.Parent then
				table.remove(cloudPool, i)
				continue
			end

			local pos      = inst.Position
			local dir      = (entry.endPos - pos)
			local mag      = dir.Magnitude
			local step     = entry.speed * dt

			if mag < step then
				-- cloud reached end, fade and replace
				table.remove(cloudPool, i)
				TweenService:Create(
					inst,
					TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
					{ Transparency = 1 }
				).Completed:Connect(function()
					inst:Destroy()
				end)
				spawnCloud()
			else
				local norm = dir / mag
				inst.CFrame = CFrame.lookAt(pos + norm * step, pos + norm * step + norm)
			end
		end
	end))
end

-- ─── Roots ────────────────────────────────────────────────────────────────────

local function spawnRoots()
	local deadline = os.clock() + 10
	while not rootsTemplate and os.clock() < deadline do
		task.wait()
	end
	if not rootsTemplate then
		warn("[LosMatteos] Roots template not ready in time")
		return
	end

	local rootsClone = rootsTemplate:Clone()

	local mapCenterPos = MapInfo.MapCenter.Position
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = {
		workspace.Events["Los Matteos"]:FindFirstChild("Areas") or workspace,
	}
	local hit      = workspace:Raycast(mapCenterPos, Vector3.new(0, -25, 0), rp)
	local spawnPos = hit
		and Vector3.new(mapCenterPos.X, hit.Position.Y, mapCenterPos.Z)
		or mapCenterPos

	local partsWithDistances = {}
	for _, desc in rootsClone:GetDescendants() do
		if desc:IsA("BasePart") then
			local dist = (desc.Position - spawnPos).Magnitude
			table.insert(partsWithDistances, { part = desc, distance = dist })
		end
	end
	table.sort(partsWithDistances, function(a, b) return a.distance < b.distance end)

	local minDist   = partsWithDistances[1] and partsWithDistances[1].distance or 0
	local maxDist   = #partsWithDistances > 0 and partsWithDistances[#partsWithDistances].distance or 1
	local distRange = math.max(maxDist - minDist, 1)

	for _, entry in partsWithDistances do
		entry.part.Parent = nil
		entry.delay = ((entry.distance - minDist) / distRange) * ROOTS_GROW_DURATION
	end

	rootsClone.Parent = workspace
	eventTrove:Add(rootsClone)

	-- roots sound: looped, killed when LosMatteosGrowing flips false
	local rootsSound = Sounds:FindFirstChild("Roots")
	if rootsSound then
		rootsSound.Looped = true
		rootsSound:Play()
		eventTrove:Add(ReplicatedStorage:GetAttributeChangedSignal("LosMatteosGrowing"):Connect(function()
			local growing = ReplicatedStorage:GetAttribute("LosMatteosGrowing")
			if rootsSound then
				rootsSound.Looped = growing ~= false
				if growing == false then
					rootsSound:Stop()
				end
			end
		end))
		-- hard stop at grow completion in case attribute never fires
		eventTrove:Add(task.delay(ROOTS_GROW_DURATION, function()
			if rootsSound and rootsSound.IsPlaying then
				rootsSound:Stop()
			end
		end))
	end

	for _, entry in partsWithDistances do
		eventTrove:Add(task.delay(entry.delay, function()
			if rootsClone.Parent then
				entry.part.Parent = rootsClone
			end
		end))
	end
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	-- clouds
	local cloudsDelay = math.max(0, timeLeftFor(8))
	eventTrove:Add(task.delay(cloudsDelay, function()
		if not isActive then return end
		startClouds()
	end))

	-- roots
	eventTrove:Add(task.delay(math.max(0, timeLeftFor(ROOTS_START_DELAY)), function()
		if not isActive then return end
		spawnRoots()
	end))

	-- lightning loop
	eventTrove:Add(task.delay(math.max(0, timeLeftFor(LIGHTNING_START_DELAY)), function()
		while isActive and EventController:GetActiveEventData(EVENT_NAME) do
			task.wait(LIGHTNING_INTERVAL)
			runLightningStrike()
		end
	end))

	-- cleanup watchdog
	while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
	isActive = false
	table.clear(cloudPool)
	eventTrove:Destroy()
	table.clear(recentlyTargeted)

	if rootsTemplate and rootsTemplate.Parent then
		rootsTemplate:Destroy()
		rootsTemplate = nil
	end
end

task.spawn(main)
