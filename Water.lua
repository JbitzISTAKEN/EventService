-- LocalScript: WaterLogic
-- StarterPlayerScripts

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local Observers        = require(ReplicatedStorage.Packages.Observers)

local EVENT_NAME = "Water"

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local sharks: {[string]: Part}                              = {}
local sharkModels: {[string]: Model}                        = {}
local sharkTasks: {[string]: {wander: thread, attack: thread}} = {}
local recentlyTargeted: {[string]: number}                  = {}
local activeAttacks    = 0
local isActive         = true

local WanderArea = workspace:WaitForChild("Events"):WaitForChild("Water"):WaitForChild("Wander")

local SHARK_SPEED           = 20
local MIN_TRALALEROS        = 4
local MAX_TRALALEROS        = 4
local MIN_ORCALEROS         = 4
local MAX_ORCALEROS         = 4
local TARGET_CHECK_MIN      = 15
local TARGET_CHECK_MAX      = 25
local RECENT_TARGET_COOLDOWN = 30
local MIN_WANDER_DISTANCE   = 50
local MAX_ATTACKS           = 1

local EventScript = ReplicatedStorage.Controllers.EventController.Events.Water

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getRandomWanderPosition(currentPosition: Vector3?): Vector3
	local halfY = WanderArea.Size.Y / 2
	local topY  = WanderArea.Position.Y + halfY

	for _ = 1, 20 do
		local x   = WanderArea.Position.X + (math.random() - 0.5) * WanderArea.Size.X
		local z   = WanderArea.Position.Z + (math.random() - 0.5) * WanderArea.Size.Z
		local pos = Vector3.new(x, topY, z)
		if not currentPosition or (pos - currentPosition).Magnitude >= MIN_WANDER_DISTANCE then
			return pos
		end
	end

	local x = WanderArea.Position.X + (math.random() - 0.5) * WanderArea.Size.X
	local z = WanderArea.Position.Z + (math.random() - 0.5) * WanderArea.Size.Z
	return Vector3.new(x, topY, z)
end

local function clampToWanderArea(pos: Vector3): Vector3
	local half     = WanderArea.Size / 2
	local minBound = WanderArea.Position - half
	local maxBound = WanderArea.Position + half
	return Vector3.new(
		math.clamp(pos.X, minBound.X, maxBound.X),
		WanderArea.Position.Y + half.Y,
		math.clamp(pos.Z, minBound.Z, maxBound.Z)
	)
end

local function tweenSharkTo(shark: Part, position: Vector3, constrain: boolean): Tween?
	if constrain then position = clampToWanderArea(position) end

	local dir  = position - shark.Position
	local dist = dir.Magnitude
	if dist < 0.1 then return nil end

	shark.CFrame = CFrame.lookAt(shark.Position, position)

	local finalCFrame = CFrame.lookAt(position, position + dir.Unit)
	local tween = TweenService:Create(
		shark,
		TweenInfo.new(dist / SHARK_SPEED, Enum.EasingStyle.Linear),
		{ CFrame = finalCFrame }
	)
	tween:Play()
	return tween
end

local function applySharkTrait(animal: Instance)
	if animal:GetAttribute("HasSharkFin") then return end

	local raw    = animal:GetAttribute("Traits")
	local traits = {}
	if raw then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(decoded) == "table" then traits = decoded end
	end

	if animal:GetAttribute("HasSharkFin") then return end
	for _, t in ipairs(traits) do
		if t == "Shark Fin" then
			animal:SetAttribute("HasSharkFin", true)
			return
		end
	end

	table.insert(traits, "Shark Fin")
	animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
	animal:SetAttribute("HasSharkFin", true)
end

-- replaces Burst:FireAllClients — plays attack anim + burst VFX locally
local function fireBurst(sharkName: string, animal: Instance)
	-- flip Attack attribute to trigger animation in the visual observer
	local model = sharkModels[sharkName]
	if model then
		model.Parent:SetAttribute("Attack", not model.Parent:GetAttribute("Attack"))
	end

	-- play burst sound at animal position
	if animal and animal.PrimaryPart then
		ClientEventUtils.playBurst(
			EventScript.Burst,
			animal.PrimaryPart.Position,
			{ ReplicatedStorage.Sounds.Events.Water["Brainrot Hit"] }
		)
	end
end

-- ─── Wander ───────────────────────────────────────────────────────────────────

local function wanderShark(shark: Part)
	while isActive and shark.Parent do
		if shark:GetAttribute("IsAttacking") then
			task.wait(0.5)
			continue
		end

		local tween = tweenSharkTo(shark, getRandomWanderPosition(shark.Position), true)

		if tween then
			local interruptConn = shark:GetAttributeChangedSignal("IsAttacking"):Connect(function()
				if shark:GetAttribute("IsAttacking") then tween:Cancel() end
			end)
			tween.Completed:Wait()
			interruptConn:Disconnect()
		end

		task.wait(0.1)
	end
end

-- ─── Attack ───────────────────────────────────────────────────────────────────

local function attackLoop(shark: Part)
	while isActive and shark.Parent do
		task.wait(math.random(TARGET_CHECK_MIN, TARGET_CHECK_MAX))

		if not isActive or activeAttacks >= MAX_ATTACKS then continue end
		if shark:GetAttribute("IsAttacking") then continue end

		local now        = workspace:GetServerTimeNow()
		local candidates = {}

		for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
			local lastHit = recentlyTargeted[animal.Name] or 0
			if animal.PrimaryPart
				and not animal:GetAttribute("HasSharkFin")
				and not animal:GetAttribute("TargetedBy")
				and (now - lastHit) > RECENT_TARGET_COOLDOWN
			then
				table.insert(candidates, animal)
			end
		end

		if #candidates == 0 then continue end

		local selected = candidates[math.random(1, #candidates)]
		if activeAttacks >= MAX_ATTACKS then continue end

		activeAttacks += 1
		shark:SetAttribute("IsAttacking", true)
		selected:SetAttribute("TargetedBy", shark.Name)

		local chaseStart    = os.clock()
		local reachedTarget = false
		local conn

		conn = RunService.Heartbeat:Connect(function(dt)
			local dead    = not selected.Parent or not selected.PrimaryPart
			local alreadyHit = selected:GetAttribute("HasSharkFin")

			if not isActive or dead or alreadyHit or (os.clock() - chaseStart) > 15 then
				conn:Disconnect()
				return
			end

			local targetPos = selected.PrimaryPart.Position
			local myPos     = shark.Position

			shark.CFrame   = CFrame.lookAt(myPos, targetPos)
			shark.Position += shark.CFrame.LookVector * SHARK_SPEED * dt

			if (targetPos - myPos).Magnitude <= 6 then
				reachedTarget = true
				conn:Disconnect()
			end
		end)

		repeat RunService.Heartbeat:Wait() until not conn.Connected

		if reachedTarget and isActive and selected.Parent then
			recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()

			-- replaces Burst:FireAllClients
			fireBurst(shark.Name, selected)
			applySharkTrait(selected)

			task.wait(0.25)
		end

		if selected and selected.Parent then
			selected:SetAttribute("TargetedBy", nil)
		end
		shark:SetAttribute("IsAttacking", false)
		activeAttacks = math.max(0, activeAttacks - 1)
	end
end

-- ─── Visuals — mirrors createSharks from decompiled client ───────────────────

local function startVisuals()
	local tracked: {Part}      = {}
	local primaryParts: {BasePart} = {}

	eventTrove:Add(Observers.observeTag("WaterShark", function(hitbox)
		local sharkType  = hitbox:GetAttribute("SharkType") or "Orcalero Orcala"
		local template   = EventScript[sharkType]
		local model      = template:Clone()

		model.PrimaryPart.Anchored = true
		model.Parent = hitbox

		sharkModels[hitbox.Name] = model

		-- load animations
		local swimAnim   = if sharkType == "Orcalero Orcala" then EventScript.OrcaleroSwim   else EventScript.TralaleroSwim
		local attackAnim = if sharkType == "Orcalero Orcala" then EventScript.OrcaleroAttack else EventScript.TralaleroAttack

		local animator   = model.AnimationController.Animator
		local swimTrack  = animator:LoadAnimation(swimAnim)
		local attackTrack = animator:LoadAnimation(attackAnim)

		swimTrack.Priority  = Enum.AnimationPriority.Action
		attackTrack.Priority = Enum.AnimationPriority.Action4
		attackTrack.Looped  = false
		swimTrack:Play()

		-- Attack attribute flip triggers attack animation
		local attackConn = hitbox:GetAttributeChangedSignal("Attack"):Connect(function()
			attackTrack:Play()
		end)

		table.insert(tracked, hitbox)

		return function()
			local idx = table.find(tracked, hitbox)
			if idx then table.remove(tracked, idx) end
			attackConn:Disconnect()
			swimTrack:Stop(0)
			swimTrack:Destroy()
			attackTrack:Stop(0)
			attackTrack:Destroy()
			model:Destroy()
			sharkModels[hitbox.Name] = nil
		end
	end))

	-- BulkMoveTo every PreRender — same as decompiled client
	eventTrove:Add(RunService.PreRender:Connect(function()
		debug.profilebegin("WaterEvent:Update Sharks")
		local parts:  {BasePart} = {}
		local cframes: {CFrame}   = {}
		for _, hitbox in tracked do
			local m = sharkModels[hitbox.Name]
			if m and m.PrimaryPart then
				table.insert(parts,  m.PrimaryPart)
				table.insert(cframes, hitbox.CFrame)
			end
		end
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
		debug.profileend()
	end))
end

-- ─── Spawn ────────────────────────────────────────────────────────────────────

local function createSharkHitbox(sharkType: string): Part
	local hitbox = Instance.new("Part")
	hitbox.Name        = HttpService:GenerateGUID(false)
	hitbox.Size        = Vector3.new(1, 1, 1)
	hitbox.Transparency = 1
	hitbox.CanCollide  = false
	hitbox.Anchored    = true
	hitbox.CFrame      = CFrame.new(getRandomWanderPosition(nil))
	hitbox:SetAttribute("SharkType", sharkType)
	CollectionService:AddTag(hitbox, "WaterShark")
	hitbox.Parent = workspace
	eventTrove:Add(hitbox)
	return hitbox
end

local function spawnShark(sharkType: string)
	local hitbox = createSharkHitbox(sharkType)
	sharks[hitbox.Name] = hitbox
	sharkTasks[hitbox.Name] = {
		wander = task.spawn(function() wanderShark(hitbox) end),
		attack = task.spawn(function() attackLoop(hitbox) end),
	}
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
	ReplicatedStorage:SetAttribute("WaterEvent", true)

	startVisuals()

	for _ = 1, math.random(MIN_TRALALEROS, MAX_TRALALEROS) do
		if not isActive then break end
		spawnShark("Tralalero Tralala")
	end
	for _ = 1, math.random(MIN_ORCALEROS, MAX_ORCALEROS) do
		if not isActive then break end
		spawnShark("Orcalero Orcala")
	end

	while EventController:GetActiveEventData(EVENT_NAME) do
		task.wait(1)
	end

	isActive = false
	ReplicatedStorage:SetAttribute("WaterEvent", false)

	for _, tasks in pairs(sharkTasks) do
		if tasks.wander then pcall(task.cancel, tasks.wander) end
		if tasks.attack  then pcall(task.cancel, tasks.attack)  end
	end

	for _, hitbox in pairs(sharks) do
		if hitbox then hitbox:Destroy() end
	end

	sharks         = {}
	sharkModels    = {}
	sharkTasks     = {}
	recentlyTargeted = {}
	activeAttacks  = 0

	eventTrove:Destroy()
end

task.spawn(main)
