local CollectionService  = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local RunService         = game:GetService("RunService")

local NpcPathfinding = {}

local WALKABLE_TAGS = { "Ground", "Carpet" }

local walkableParts = {}
local walkableSet   = {}
local filterDirty   = true
local DEFAULT_REACH_THRESHOLD = 1.5
local DEFAULT_TURN_SPEED = 8

local function isModelValid(model: Model): boolean
	if not model then return false end
	if not model.Parent then return false end
	if not model.PrimaryPart then return false end
	if not model.PrimaryPart.Parent then return false end
	return true
end

local function smoothTurn(model: Model, newPos: Vector3, flatDir: Vector3, dt: number, turnSpeed: number)
	if not isModelValid(model) then return end
	if not newPos then return end
	if not flatDir then return end
	if dt <= 0 then return end

	if flatDir.Magnitude < 1e-4 then
		local primaryPart = model.PrimaryPart
		if not primaryPart then return end

		local look = primaryPart.CFrame.LookVector
		flatDir = Vector3.new(look.X, 0, look.Z)
		if flatDir.Magnitude < 1e-4 then
			flatDir = Vector3.new(0, 0, 1)
		end
	end
	flatDir = flatDir.Unit

	if not isModelValid(model) then return end

	local primaryPart = model.PrimaryPart
	if not primaryPart then return end

	local currentCFrame = primaryPart.CFrame
	if not currentCFrame then return end

	local targetCF = CFrame.new(newPos, newPos + flatDir)

	local currentRot = CFrame.new(newPos)
		* CFrame.fromMatrix(
			Vector3.zero,
			currentCFrame.RightVector,
			Vector3.new(0, 1, 0)
		)

	local alpha = math.min(1, turnSpeed * dt)

	if not isModelValid(model) then return end

	local ok, err = pcall(function()
		model:PivotTo(currentRot:Lerp(targetCF, alpha))
	end)

	if not ok then
		warn("[NpcPathfinding] smoothTurn PivotTo failed:", err)
	end
end

local function addWalkable(inst: Instance)
	if not inst then return end
	if not inst:IsA("BasePart") then return end
	if walkableSet[inst] then return end
	walkableSet[inst] = true
	table.insert(walkableParts, inst)
	filterDirty = true
end

local function removeWalkable(inst: Instance)
	if not inst then return end
	if not walkableSet[inst] then return end
	walkableSet[inst] = nil
	for i = #walkableParts, 1, -1 do
		if walkableParts[i] == inst then
			table.remove(walkableParts, i)
			break
		end
	end
	filterDirty = true
end

for _, tag in ipairs(WALKABLE_TAGS) do
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		addWalkable(inst)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(addWalkable)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(removeWalkable)
end

local groundRayParams = RaycastParams.new()
groundRayParams.FilterType = Enum.RaycastFilterType.Include
groundRayParams.FilterDescendantsInstances = {}
groundRayParams.IgnoreWater = true

local function refreshGroundFilter()
	if filterDirty then
		groundRayParams.FilterDescendantsInstances = walkableParts
		filterDirty = false
	end
end

function NpcPathfinding.stickToGround(
	position: Vector3,
	yOffset: number?,
	castUp: number?,
	castDown: number?,
	ignoreModel: Model?
): Vector3
	if not position then return Vector3.new(0, 0, 0) end

	local up  = castUp   or 10
	local down = castDown or 50
	local off  = yOffset  or 1.5

	refreshGroundFilter()
	if #walkableParts == 0 then
		return position
	end

	local rayParams = groundRayParams
	if ignoreModel then
		rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Include
		rayParams.FilterDescendantsInstances = walkableParts
		rayParams.IgnoreWater = true
	end

	local origin = position + Vector3.new(0, up, 0)
	local dir    = Vector3.new(0, -(up + down), 0)

	local ok, result = pcall(function()
		return workspace:Raycast(origin, dir, rayParams)
	end)

	if ok and result then
		return result.Position + Vector3.new(0, off, 0)
	end

	return position
end

local DEFAULT_AGENT_PARAMS = {
	AgentRadius     = 2,
	AgentHeight     = 5,
	AgentCanJump    = false,
	AgentCanClimb   = false,
	WaypointSpacing = 4,
}

function NpcPathfinding.computePath(
	startPos: Vector3,
	endPos: Vector3,
	agentParams: {[string]: any}?
): { Vector3 }?
	if not startPos then return nil end
	if not endPos then return nil end

	local path = PathfindingService:CreatePath(agentParams or DEFAULT_AGENT_PARAMS)
	if not path then return nil end

	local ok = pcall(function()
		path:ComputeAsync(startPos, endPos)
	end)

	if not ok or path.Status ~= Enum.PathStatus.Success then
		return nil
	end

	local waypoints = path:GetWaypoints()
	if not waypoints or #waypoints == 0 then
		return nil
	end

	local result = table.create(#waypoints)
	for i = 2, #waypoints do
		local wp = waypoints[i]
		if wp and wp.Position then
			table.insert(result, NpcPathfinding.stickToGround(wp.Position))
		end
	end

	if #result == 0 then
		table.insert(result, NpcPathfinding.stickToGround(endPos))
	end

	return result
end

function NpcPathfinding.moveTo(
	model: Model,
	targetPos: Vector3,
	speed: number,
	opts: {[string]: any}?
): boolean
	if not isModelValid(model) then return false end
	if not targetPos then return false end
	if not speed or speed <= 0 then return false end

	opts = opts or {}

	local maxTime    = opts.maxTime or 30
	local threshold  = opts.reachThreshold or DEFAULT_REACH_THRESHOLD
	local shouldStop = opts.shouldStop
	local onStep     = opts.onStep

	local primaryPart = model.PrimaryPart
	if not primaryPart then return false end

	local waypoints = NpcPathfinding.computePath(primaryPart.Position, targetPos)
	if not waypoints or #waypoints == 0 then
		return false
	end

	local startClock = os.clock()

	for _, wp in ipairs(waypoints) do
		if not wp then continue end

		while true do
			if shouldStop and shouldStop() then return false end
			if not isModelValid(model) then return false end
			if os.clock() - startClock > maxTime then return false end

			local pPart = model.PrimaryPart
			if not pPart then return false end

			local current = pPart.Position
			local toWp    = wp - current
			local flatVec = Vector3.new(toWp.X, 0, toWp.Z)
			local wpDist  = flatVec.Magnitude

			if wpDist <= threshold then break end

			local dt = RunService.Heartbeat:Wait()
			if dt <= 0 then continue end

			if not isModelValid(model) then return false end

			local pPart2 = model.PrimaryPart
			if not pPart2 then return false end

			local moveAmt = math.min(speed * dt, wpDist)
			local flatDir = flatVec.Unit
			local newXZ   = pPart2.Position + flatDir * moveAmt
			local newPos  = NpcPathfinding.stickToGround(newXZ, opts.yOffset)

			smoothTurn(model, newPos, flatDir, dt, opts.turnSpeed or DEFAULT_TURN_SPEED)

			if onStep and isModelValid(model) then
				local ok, err = pcall(onStep, model, newPos)
				if not ok then
					warn("[NpcPathfinding] onStep error:", err)
				end
			end
		end
	end

	return isModelValid(model)
end

function NpcPathfinding.chase(
	model: Model,
	getTargetPos: () -> Vector3?,
	speed: number,
	stopDistance: number,
	maxTime: number,
	opts: {[string]: any}?
): boolean
	if not isModelValid(model) then return false end
	if not getTargetPos then return false end
	if not speed or speed <= 0 then return false end
	if not stopDistance then stopDistance = 3 end
	if not maxTime then maxTime = 30 end

	opts = opts or {}

	local repathInterval = opts.repathInterval or 0.6
	local moveRepath     = opts.targetMoveRepathThreshold or 5
	local shouldStop     = opts.shouldStop
	local onStep         = opts.onStep

	local startClock    = os.clock()
	local lastRepath    = -math.huge
	local lastTargetPos = nil
	local waypoints     = nil
	local wpIndex       = 1

	while true do
		if shouldStop and shouldStop() then return false end
		if not isModelValid(model) then return false end
		if os.clock() - startClock > maxTime then return false end

		local targetPos = getTargetPos()
		if not targetPos then return false end

		local pPart = model.PrimaryPart
		if not pPart then return false end

		local current  = pPart.Position
		local toTarget = targetPos - current

		if toTarget.Magnitude <= stopDistance then return true end

		local now        = os.clock()
		local needRepath = false

		if not waypoints or wpIndex > #waypoints then
			needRepath = true
		elseif now - lastRepath >= repathInterval then
			needRepath = true
		elseif lastTargetPos and (targetPos - lastTargetPos).Magnitude >= moveRepath then
			needRepath = true
		end

		if needRepath then
			if not isModelValid(model) then return false end

			local pPart2 = model.PrimaryPart
			if not pPart2 then return false end

			waypoints     = NpcPathfinding.computePath(pPart2.Position, targetPos)
			wpIndex       = 1
			lastRepath    = now
			lastTargetPos = targetPos

			if not waypoints or #waypoints == 0 then
				task.wait(0.1)
				continue
			end
		end

		if not waypoints or wpIndex > #waypoints then
			continue
		end

		local wp = waypoints[wpIndex]
		if not wp then
			wpIndex += 1
			continue
		end

		if not isModelValid(model) then return false end

		local pPart3 = model.PrimaryPart
		if not pPart3 then return false end

		local toWp    = wp - pPart3.Position
		local flatVec = Vector3.new(toWp.X, 0, toWp.Z)
		local wpDist  = flatVec.Magnitude

		if wpDist <= DEFAULT_REACH_THRESHOLD then
			wpIndex += 1
			continue
		end

		local dt = RunService.Heartbeat:Wait()
		if dt <= 0 then continue end

		if not isModelValid(model) then return false end

		local pPart4 = model.PrimaryPart
		if not pPart4 then return false end

		local moveAmt = math.min(speed * dt, wpDist)
		local flatDir = flatVec.Unit
		local newXZ   = pPart4.Position + flatDir * moveAmt
		local newPos  = NpcPathfinding.stickToGround(newXZ, opts.yOffset)

		smoothTurn(model, newPos, flatDir, dt, opts.turnSpeed or DEFAULT_TURN_SPEED)

		if onStep and isModelValid(model) then
			local ok, err = pcall(onStep, model, newPos)
			if not ok then
				warn("[NpcPathfinding] onStep error:", err)
			end
		end
	end
end

return NpcPathfinding
