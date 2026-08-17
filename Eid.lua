-- LocalScript: Eid Balloon Client Spawner
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local Trove             = require(ReplicatedStorage.Packages.Trove)
local EventController   = require(ReplicatedStorage.Controllers.EventController)
local SoundController   = require(ReplicatedStorage.Controllers.SoundController)
local ClientEventUtils  = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local EVENT_NAME             = "Eid"
local TAG_NAME               = "EidBalloon"
local BALLOON_COUNT          = 10
local BALLOON_SPEED          = 14
local MIN_WANDER_DISTANCE    = 40
local MAX_ATTACKS            = 1
local TARGET_CHECK_MIN       = 8
local TARGET_CHECK_MAX       = 16
local RECENT_TARGET_COOLDOWN = 25

local BALLOON_WEIGHTS = {
	["Red"]     = 50,
	["Orange"]  = 80,
	["Green"]   = 65,
	["Blue"]    = 55,
	["Pink"]    = 35,
	["Rainbow"] = 15,
}

local events = workspace:FindFirstChild("Events") or Instance.new("Folder")
events.Name   = "Events"
events.Parent = workspace

local model = game:GetObjects("rbxassetid://104189817203567")[1]
if model then
	model.Name   = "Eid"
	model.Parent = events
end

local WANDER_PART = workspace:WaitForChild("Events"):WaitForChild("Eid"):WaitForChild("Wander")

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local burstAsset = ReplicatedStorage.Controllers.EventController.Events.Eid.Burst

local isActive         = true
local eventTrove       = Trove.new()
local balloons         = {}
local balloonTasks     = {}
local recentlyTargeted = {}
local activeAttacks    = 0

local function getRandomWanderPosition(currentPosition: Vector3?): Vector3
	local halfY = WANDER_PART.Size.Y / 2
	local topY  = WANDER_PART.Position.Y + halfY
	for _ = 1, 20 do
		local x   = WANDER_PART.Position.X + (math.random() - 0.5) * WANDER_PART.Size.X
		local z   = WANDER_PART.Position.Z + (math.random() - 0.5) * WANDER_PART.Size.Z
		local pos = Vector3.new(x, topY, z)
		if not currentPosition or (pos - currentPosition).Magnitude >= MIN_WANDER_DISTANCE then
			return pos
		end
	end
	local x = WANDER_PART.Position.X + (math.random() - 0.5) * WANDER_PART.Size.X
	local z = WANDER_PART.Position.Z + (math.random() - 0.5) * WANDER_PART.Size.Z
	return Vector3.new(x, WANDER_PART.Position.Y + halfY, z)
end

local function clampToWanderArea(pos: Vector3): Vector3
	local half = WANDER_PART.Size / 2
	local minB = WANDER_PART.Position - half
	local maxB = WANDER_PART.Position + half
	return Vector3.new(
		math.clamp(pos.X, minB.X, maxB.X),
		WANDER_PART.Position.Y + half.Y,
		math.clamp(pos.Z, minB.Z, maxB.Z)
	)
end

local function pickWeightedBalloonType(): string
	local totalWeight = 0
	for _, w in pairs(BALLOON_WEIGHTS) do totalWeight += w end
	local roll       = math.random() * totalWeight
	local cumulative = 0
	for balloonType, weight in pairs(BALLOON_WEIGHTS) do
		cumulative += weight
		if roll <= cumulative then return balloonType end
	end
	return "Red"
end

local function createBalloonHitbox(balloonType: string): Part
	local hitbox        = Instance.new("Part")
	hitbox.Name         = HttpService:GenerateGUID(false)
	hitbox.Size         = Vector3.new(2, 2, 2)
	hitbox.Transparency = 1
	hitbox.CanCollide   = false
	hitbox.Anchored     = true
	hitbox.CFrame       = CFrame.new(getRandomWanderPosition(nil))
	hitbox:SetAttribute("BalloonType",  balloonType)
	hitbox:SetAttribute("BalloonColor", balloonType)
	CollectionService:AddTag(hitbox, TAG_NAME)
	hitbox.Parent = workspace
	return hitbox
end

local function floatBalloon(balloon: Part)
	local timeOffset  = math.random() * math.pi * 2
	local xOffset     = math.random() * math.pi * 2
	local zOffset     = math.random() * math.pi * 2
	local floatRangeY = math.random(1, 3)
	local driftRangeX = math.random(3, 6)
	local driftRangeZ = math.random(3, 6)
	local freqY       = 0.20 + math.random() * 0.10
	local freqX       = 0.18 + math.random() * 0.12
	local freqZ       = 0.16 + math.random() * 0.12
	local origin      = balloon.Position

	local conn
	conn = RunService.Heartbeat:Connect(function()
		if not balloon.Parent or not isActive then
			conn:Disconnect()
			return
		end
		if balloon:GetAttribute("IsAttacking") then return end
		local t       = os.clock() + timeOffset
		local offsetY = math.sin(t * freqY * math.pi * 2) * floatRangeY
		local offsetX = math.sin(t * freqX * math.pi * 2 + xOffset) * driftRangeX
		local offsetZ = math.sin(t * freqZ * math.pi * 2 + zOffset) * driftRangeZ
		local newPos  = clampToWanderArea(origin + Vector3.new(offsetX, offsetY, offsetZ))
		balloon.CFrame = CFrame.new(newPos)
	end)

	eventTrove:Add(conn)
end

local spawnBalloon

local function attackAnimal(balloon: Part)
	while isActive and balloon.Parent do
		task.wait(math.random(TARGET_CHECK_MIN, TARGET_CHECK_MAX))

		if not isActive or not balloon.Parent then break end
		if activeAttacks >= MAX_ATTACKS then continue end
		if balloon:GetAttribute("IsAttacking") then continue end

		local animals     = CollectionService:GetTagged("Animal")
		local candidates  = {}
		local currentTime = workspace:GetServerTimeNow()

		for _, animal in ipairs(animals) do
			local lastHit  = recentlyTargeted[animal.Name] or 0
			local isLocked = animal:GetAttribute("TargetedByBalloon") ~= nil
			if animal.PrimaryPart
				and not isLocked
				and (currentTime - lastHit) > RECENT_TARGET_COOLDOWN
			then
				table.insert(candidates, animal)
			end
		end

		if #candidates == 0 then continue end
		if activeAttacks >= MAX_ATTACKS then continue end

		local selected = candidates[math.random(1, #candidates)]
		activeAttacks += 1
		balloon:SetAttribute("IsAttacking", true)
		selected:SetAttribute("TargetedByBalloon", balloon.Name)

		local chaseStart    = os.clock()
		local reachedTarget = false
		local connection

		connection = RunService.Heartbeat:Connect(function(dt)
			local targetLost = not selected.Parent or not selected.PrimaryPart
			if not isActive or targetLost or (os.clock() - chaseStart) > 20 or not balloon.Parent then
				connection:Disconnect()
				return
			end

			local targetPos  = selected.PrimaryPart.Position
			local currentPos = balloon.Position
			local direction  = targetPos - currentPos
			local dist       = direction.Magnitude

			if dist > 0.1 then
				local step = math.min(BALLOON_SPEED * dt, dist)
				balloon.CFrame = CFrame.new(currentPos + direction.Unit * step)
			end

			if dist <= 5 then
				reachedTarget = true
				connection:Disconnect()
			end
		end)

		repeat RunService.Heartbeat:Wait() until not connection.Connected

		if reachedTarget and isActive and selected.Parent and selected.PrimaryPart then
			recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()

			ClientEventUtils.playBurst(burstAsset, selected.PrimaryPart, {
				ReplicatedStorage.Sounds.Events.Eid.Hit
			})

			if selected.Parent then
				selected:SetAttribute("TargetedByBalloon", nil)
			end

			activeAttacks = math.max(0, activeAttacks - 1)

			local oldName = balloon.Name
			balloons[oldName]     = nil
			balloonTasks[oldName] = nil
			balloon:Destroy()

			if isActive then
				task.delay(2, function()
					if isActive then
						spawnBalloon(pickWeightedBalloonType())
					end
				end)
			end

			return
		end

		if selected and selected.Parent then
			selected:SetAttribute("TargetedByBalloon", nil)
		end
		balloon:SetAttribute("IsAttacking", false)
		activeAttacks = math.max(0, activeAttacks - 1)
	end
end

spawnBalloon = function(balloonType: string)
	if not isActive then return end
	local balloon = createBalloonHitbox(balloonType)
	balloons[balloon.Name]     = balloon
	balloonTasks[balloon.Name] = {
		attack = task.spawn(function() attackAnimal(balloon) end),
	}
	eventTrove:Add(balloon)
	floatBalloon(balloon)
end

local function main()
	for _ = 1, BALLOON_COUNT do
		spawnBalloon(pickWeightedBalloonType())
	end

	while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end

	isActive = false
	for _, tasks in pairs(balloonTasks) do
		if tasks.attack then task.cancel(tasks.attack) end
	end
	eventTrove:Destroy()
	table.clear(balloons)
	table.clear(balloonTasks)
	table.clear(recentlyTargeted)
	activeAttacks = 0
end

task.spawn(main)
