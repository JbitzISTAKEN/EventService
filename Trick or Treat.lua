local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local CollectionService      = game:GetService("CollectionService")
local HttpService             = game:GetService("HttpService")
local RunService              = game:GetService("RunService")
local TweenService            = game:GetService("TweenService")
local Players                 = game:GetService("Players")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove                  = require(ReplicatedStorage.Packages.Trove)
local Observers              = require(ReplicatedStorage.Packages.Observers)
local Spr                    = require(ReplicatedStorage.Packages.Spr)
local EventController        = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils       = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local NotificationController = require(ReplicatedStorage.Controllers.NotificationController)
local SoundController        = require(ReplicatedStorage.Controllers.SoundController)
local SharedAnimals          = require(ReplicatedStorage.Shared.Animals)

local LocalPlayer = Players.LocalPlayer
local EVENT_NAME  = "Trick or Treat"
local EventScript = ReplicatedStorage.Controllers.EventController.Events:WaitForChild(EVENT_NAME)
local Sounds      = ReplicatedStorage.Sounds.Events[EVENT_NAME]

local CHASE_SPEED    = 15
local RETURN_SPEED   = 10
local CHASE_REACH    = 1
local POST_HIT_WAIT  = 1.5
local CHASE_INTERVAL = 3
local BLOCKING_TRAIT = "Jackolantern Pet"
local RAD_ANIMALS    = { "La Casa Boo", "Pot Pumpkin", "Trickolino" }
local CANDY_AMOUNTS  = { 50, 20, 30 }
local TREAT_CHANCE   = 70

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

local function getEffectEventName()
	for attr, val in ReplicatedStorage:GetAttributes() do
		if type(val) == "boolean" and val and attr:sub(-5) == "Event" then
			return attr
		end
	end
end

local effectEventName = getEffectEventName()
if not effectEventName then
	repeat
		ReplicatedStorage.AttributeChanged:Wait()
		effectEventName = getEffectEventName()
	until effectEventName
end

while not (_G.EffectStartSignals and _G.EffectStartSignals[effectEventName]) do
	task.wait()
end

local eventTrove = Trove.new()
local isActive   = true

local housesModel do
	local objects = game:GetObjects("rbxassetid://115610014866510")
	local model   = objects and objects[1]
	if model then
		model.Name   = "Houses"
		model.Parent = workspace
		eventTrove:Add(model)
	end
	housesModel = model
end

local function has(animal)
	if not animal or not animal.Parent then return false end
	local json = animal:GetAttribute("Traits")
	if not json then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return false end
	for _, t in ipairs(decoded) do
		if t == BLOCKING_TRAIT then return true end
	end
	return false
end

local function apply(animal)
	if not animal or not animal.Parent then return end
	local json = animal:GetAttribute("Traits")
	local list = {}
	if json then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
		if ok and type(decoded) == "table" then list = decoded end
	end
	for _, t in ipairs(list) do
		if t == BLOCKING_TRAIT then return end
	end
	table.insert(list, BLOCKING_TRAIT)
	animal:SetAttribute("Traits", HttpService:JSONEncode(list))
end

local function playScreenCandyEffect()
	local rng        = Random.new()
	local effectsGui = LocalPlayer.PlayerGui:FindFirstChild("Effects")
	if not effectsGui then return end
	for _ = 1, 20 do
		local img = EventScript:FindFirstChild("Image")
		if not img then break end
		local clone    = img:Clone()
		clone.Position = UDim2.fromScale(rng:NextNumber(-0.25, 1.25), -0.25)
		clone.Rotation = rng:NextNumber(-120, 120)
		local sz       = rng:NextNumber(0.15, 0.2)
		clone.Size     = UDim2.fromScale(sz, sz)
		clone.Parent   = effectsGui
		local tween    = TweenService:Create(clone,
			TweenInfo.new(rng:NextNumber(0.75, 1.3), Enum.EasingStyle.Linear),
			{
				Position = clone.Position + UDim2.fromScale(0, 1.5),
				Rotation = clone.Rotation + rng:NextInteger(-3, 3) * 10,
			}
		)
		tween:Play()
		tween.Completed:Once(function()
			task.wait(1)
			clone:Destroy()
		end)
	end
end

local wanderFolder do
	local objects = game:GetObjects("rbxassetid://112482579241084")
	local folder  = objects and objects[1]
	if folder then
		folder.Name   = "Trick or Treat"
		folder.Parent = workspace.Events["Trick or Treat"]
		eventTrove:Add(folder)
	end
	wanderFolder = folder
end

local PumpkinTemplate = wanderFolder and wanderFolder:FindFirstChild("Template")
local IdleAnim        = PumpkinTemplate and PumpkinTemplate:FindFirstChild("Idle", true)
local MoveAnim        = PumpkinTemplate and PumpkinTemplate:FindFirstChild("Move", true)

eventTrove:Add(Observers.observeTag("TrickOrTreatDoor", function(door)
	local originCF = door:GetPivot()
	return Observers.observeAttribute(door, "Open", function(open)
		if open then
			Spr.target(door, 0.75, 3.5, { Pivot = originCF * CFrame.Angles(0, math.pi / 2, 0) })
		else
			Spr.target(door, 0.75, 3.5, { Pivot = originCF })
		end
		return nil
	end)
end))

eventTrove:Add(Observers.observeTag("TrickOrTreatEventPumpkin", function(part)
	if not PumpkinTemplate then return end
	local t   = Trove.new()

	local ok, err = pcall(function()
		local mdl = t:Clone(PumpkinTemplate)

		pcall(function() mdl:ScaleTo(part:GetAttribute("Scale") or 1) end)

		mdl.Parent = workspace

		local weld      = Instance.new("Weld")
		weld.Part0      = mdl.PrimaryPart
		weld.Part1      = part
		weld.C0         = mdl.PrimaryPart.PivotOffset
		weld.Parent     = mdl.PrimaryPart

		local animator = mdl.AnimationController.Animator

		local idle = animator:LoadAnimation(IdleAnim)
		idle.Priority = Enum.AnimationPriority.Idle
		idle.Looped   = true
		idle:Play()
		t:Add(function() idle:Stop(); idle:Destroy() end)

		local move = animator:LoadAnimation(MoveAnim)
		move.Priority = Enum.AnimationPriority.Action
		move.Looped   = true
		t:Add(function() move:Stop(); move:Destroy() end)

		t:Add(Observers.observeAttribute(part, "Moving", function(moving)
			if moving then move:Play() else move:Stop() end
			return nil
		end))
	end)

	if not ok then
		t:Clean()
		return
	end

	return t:WrapClean()
end, { workspace }))

local pumpkinParts  = {}
local pTasks        = {}
local targetted     = {}
local cachedAnimals = {}

local function isOccupied(pumpkin)
	return pTasks[pumpkin] ~= nil
end

local function unoccupy(pumpkin)
	local trove = pTasks[pumpkin]
	if trove then trove:Clean() end
	pTasks[pumpkin] = nil
end

local function pickPumpkin()
	for _, p in ipairs(pumpkinParts) do
		if not isOccupied(p) then return p end
	end
	return nil
end

local function pick()
	local currentTime = workspace:GetServerTimeNow()
	for animalId, lastTime in pairs(targetted) do
		if (currentTime - lastTime) > 20 then
			targetted[animalId] = nil
		end
	end
	local candidates = {}
	for _, animal in ipairs(cachedAnimals) do
		if animal.PrimaryPart and not targetted[animal.Name] and not has(animal) then
			table.insert(candidates, animal)
		end
	end
	if #candidates == 0 then return nil end
	return candidates[math.random(1, #candidates)]
end

local function hit(targetAnimal)
	if not targetAnimal or not targetAnimal.PrimaryPart then return end

	local pumpkin = pickPumpkin()
	if not pumpkin then return end

	local pumpkinTrove = Trove.new()
	pTasks[pumpkin] = pumpkinTrove

	pumpkin:SetAttribute("Moving", true)
	pumpkinTrove:Add(function()
		pumpkin:SetAttribute("Moving", false)
	end)

	local animalId = targetAnimal.Name
	local origPos  = pumpkin.Position

	targetted[animalId] = workspace:GetServerTimeNow()

	task.spawn(function()
		pumpkinTrove:Connect(RunService.Heartbeat, function(dt)
			if not targetAnimal or not targetAnimal.Parent or not targetAnimal.PrimaryPart then
				unoccupy(pumpkin)
				pTasks[pumpkin] = nil
				return
			end

			local currentPos = pumpkin.Position
			local targetPos  = targetAnimal.PrimaryPart.Position
			local dir        = targetPos - currentPos
			local distance   = dir.Magnitude
			local moveStep   = math.min(distance, CHASE_SPEED * dt)

			if distance < CHASE_REACH then
				pumpkinTrove:Clean()

				if not has(targetAnimal) then
					apply(targetAnimal)
					ClientEventUtils.playBurst(EventScript.Burst, targetAnimal.Name, {
						Sounds.BrainrotHit,
					})
				end

				task.wait(POST_HIT_WAIT)

				local returnTrove = Trove.new()
				pTasks[pumpkin] = returnTrove

				pumpkin:SetAttribute("Moving", true)
				returnTrove:Add(function()
					pumpkin:SetAttribute("Moving", false)
				end)

				returnTrove:Connect(RunService.Heartbeat, function(dt2)
					local currPos  = pumpkin.Position
					local dirBack  = origPos - currPos
					local distBack = dirBack.Magnitude

					if distBack < 0.5 then
						returnTrove:Clean()
						pTasks[pumpkin] = nil
						return
					end

					local newPos = currPos + dirBack.Unit * math.min(distBack, RETURN_SPEED * dt2)
					pumpkin.CFrame = CFrame.lookAt(newPos, newPos + dirBack.Unit)
				end)

				return
			end

			local newPos = currentPos + dir.Unit * moveStep
			pumpkin.CFrame = CFrame.lookAt(newPos, newPos + dir.Unit)
		end)
	end)
end

eventTrove:Add(ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
	if plr ~= LocalPlayer then return end
	if not housesModel or not prompt:IsDescendantOf(housesModel) then return end

	local prmpt     = prompt.Parent
	local door      = prmpt.Parent:FindFirstChild("Door")
	local spawnPart = prmpt.Parent:FindFirstChild("SpawnBrainrot")
	if not door or not spawnPart then return end

	local animalName  = RAD_ANIMALS[math.random(1, #RAD_ANIMALS)]
	local candyAmount = CANDY_AMOUNTS[math.random(1, #CANDY_AMOUNTS)]
	local isTreat     = math.random(1, 100) <= TREAT_CHANCE

	prompt.Enabled = false
	prompt:Destroy()

	local doorbell = EventScript:FindFirstChild("Doorbell")
	local bell
	if doorbell then
		bell = doorbell:Clone()
		bell.Parent = prmpt
		bell:Play()
	end

	local animal = SharedAnimals:GetAnimatedModel(animalName, "Idle")
	if not animal then return end
	animal.Parent = workspace

	local t0 = tick()
	while not animal.PrimaryPart and tick() - t0 < 2 do task.wait(0.05) end
	if animal.PrimaryPart then
		animal:PivotTo(spawnPart.CFrame)
		animal.PrimaryPart.Anchored = true
	end

	task.wait(1.5)
	if bell then bell:Destroy() end
	door:SetAttribute("Open", true)
	task.wait(1)

	if isTreat then
		local anim = EventScript.Animations:FindFirstChild(animalName)
		if anim and animal:FindFirstChild("AnimationController") then
			local track = animal.AnimationController.Animator:LoadAnimation(anim)
			track:Play()
		end

		playScreenCandyEffect()

		local current = LocalPlayer:GetAttribute("Candies") or 0
		LocalPlayer:SetAttribute("Candies", current + candyAmount)

		NotificationController:Notify(
			("<b>%s</b> gave you <b>%d</b> <font color='#FFA500'>Candies</font>!"):format(animalName, candyAmount),
			6,
			nil
		)

		local candySound = Instance.new("Sound")
		candySound.SoundId = "rbxassetid://119143644355689"
		candySound.Volume  = 0.5
		candySound.Parent  = prmpt
		candySound:Play()
		task.delay(2, function() candySound:Destroy() end)

		task.wait(1)
		door:SetAttribute("Open", false)
		task.wait(2)
	else
		local hitAnim = EventScript.HitAnimations:FindFirstChild(animalName)
		if hitAnim and animal:FindFirstChild("AnimationController") then
			local track = animal.AnimationController.Animator:LoadAnimation(hitAnim)
			track:Play()
			task.delay(0.419, function() track:Stop() end)
		end

		local hitSound = Instance.new("Sound")
		hitSound.SoundId = "rbxassetid://128476264357679"
		hitSound.Volume  = 0.5
		hitSound.Parent  = prmpt
		hitSound:Play()
		task.delay(2, function() hitSound:Destroy() end)

		NotificationController:Notify(
			("<b>%s</b> tricked you!"):format(animalName),
			6,
			nil
		)

		task.wait(1)
		door:SetAttribute("Open", false)
		task.wait(2)
	end

	animal:Destroy()
end))

local function main()
	local pumpkinsFolder = wanderFolder and wanderFolder:FindFirstChild("Pumpkins")
	if not pumpkinsFolder then
		warn("[TrickOrTreat] Pumpkins folder not found in asset")
		return
	end

	for _, p in ipairs(pumpkinsFolder:GetChildren()) do
		if p:IsA("BasePart") then
			table.insert(pumpkinParts, p)
		end
	end

	if #pumpkinParts == 0 then
		warn("[TrickOrTreat] No pumpkin parts found")
		return
	end

	local elapsed   = workspace:GetServerTimeNow() - startedAt
	local remaining = math.max(0, 0 - elapsed)
	if remaining > 0 then task.wait(remaining) end
	if not isActive then return end

	cachedAnimals = CollectionService:GetTagged("Animal")
	eventTrove:Add(CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(inst)
		table.insert(cachedAnimals, inst)
	end))
	eventTrove:Add(CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(inst)
		for i = #cachedAnimals, 1, -1 do
			if cachedAnimals[i] == inst then table.remove(cachedAnimals, i) break end
		end
	end))

	eventTrove:Add(task.spawn(function()
		while isActive do
			task.wait(CHASE_INTERVAL)
			if not isActive then break end
			local targetAnimal = pick()
			if targetAnimal then
				hit(targetAnimal)
			end
		end
	end))

	while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
	isActive = false
	for pumpkin, trove in pairs(pTasks) do
		trove:Clean()
		pTasks[pumpkin] = nil
	end
	table.clear(pumpkinParts)
	table.clear(targetted)
	eventTrove:Destroy()
end

task.spawn(main)
