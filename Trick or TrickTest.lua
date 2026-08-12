-- LocalScript: TrickOrTreatLogic
-- StarterPlayerScripts

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)

local EVENT_NAME  = "Trick or Treat"
local LocalPlayer = Players.LocalPlayer

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local isActive         = true
local targetted        = {}
local pTasks           = {}

-- ─── Houses ───────────────────────────────────────────────────────────────────

local houseModel = game:GetObjects("rbxassetid://115610014866510")[1]
houseModel.Name   = "Houses"
houseModel.Parent = workspace
eventTrove:Add(houseModel)

task.wait(0.5)

-- ─── Pumpkins ─────────────────────────────────────────────────────────────────

local Pumpkins = workspace.Events[EVENT_NAME]:WaitForChild("Pumpkins")

local function isOccupied(pumpkin)
	return pTasks[pumpkin] ~= nil
end

local function unoccupy(pumpkin)
	local trove = pTasks[pumpkin]
	if trove then trove:Clean() end
	pTasks[pumpkin] = nil
end

local function pickPumpkin()
	for _, pumpkin in ipairs(Pumpkins:GetChildren()) do
		if not isOccupied(pumpkin) then return pumpkin end
	end
	return nil
end

-- ─── Trait helpers ────────────────────────────────────────────────────────────

local function hasJackoTrait(animal)
	if not animal or not animal.Parent then return false end
	local json = animal:GetAttribute("Traits")
	if not json then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(decoded) ~= "table" then return false end
	for _, t in ipairs(decoded) do
		if t == "Jackolantern Pet" then return true end
	end
	return false
end

local function applyJackoTrait(animal)
	if not animal or not animal.Parent then return end
	local json = animal:GetAttribute("Traits")
	local traits = {}
	if json then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
		if ok and type(decoded) == "table" then traits = decoded end
	end
	for _, t in ipairs(traits) do
		if t == "Jackolantern Pet" then return end
	end
	table.insert(traits, "Jackolantern Pet")
	animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

-- ─── Candidate picker ─────────────────────────────────────────────────────────

local function pickTarget()
	local now = workspace:GetServerTimeNow()
	for name, last in pairs(targetted) do
		if now - last > 20 then targetted[name] = nil end
	end

	local candidates = {}
	for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
		if animal.PrimaryPart and animal.Parent
			and not targetted[animal.Name]
			and not hasJackoTrait(animal)
		then
			table.insert(candidates, animal)
		end
	end

	if #candidates == 0 then return nil end
	return candidates[math.random(1, #candidates)]
end

-- ─── Pumpkin movement ─────────────────────────────────────────────────────────

local function hitAnimal(targetAnimal)
	if not targetAnimal or not targetAnimal.PrimaryPart then return end

	local pumpkin = pickPumpkin()
	if not pumpkin then return end

	local pumpkinTrove = eventTrove:Extend()
	pTasks[pumpkin] = pumpkinTrove

	pumpkin:SetAttribute("Moving", true)
	pumpkinTrove:Add(function()
		pumpkin:SetAttribute("Moving", false)
	end)

	local animalId = targetAnimal.Name
	local origPos  = pumpkin.Position
	targetted[animalId] = workspace:GetServerTimeNow()

	pumpkinTrove:Add(task.spawn(function()
		local chaseConn
		chaseConn = pumpkinTrove:Add(RunService.Heartbeat:Connect(function(dt)
			if not targetAnimal or not targetAnimal.Parent or not targetAnimal.PrimaryPart then
				unoccupy(pumpkin)
				return
			end

			local currPos   = pumpkin.Position
			local targetPos = targetAnimal.PrimaryPart.Position
			local dir       = targetPos - currPos
			local dist      = dir.Magnitude
			local moveStep  = math.min(dist, 15 * dt)

			if dist < 1 then
				pumpkinTrove:Remove(chaseConn)
				applyJackoTrait(targetAnimal)
				pumpkin:SetAttribute("Moving", false)

				task.wait(1.5)

				local returnTrove = eventTrove:Extend()
				pTasks[pumpkin] = returnTrove

				pumpkin:SetAttribute("Moving", true)
				returnTrove:Add(function()
					pumpkin:SetAttribute("Moving", false)
				end)

				local returnConn
				returnConn = returnTrove:Add(RunService.Heartbeat:Connect(function(dt2)
					local pos     = pumpkin.Position
					local dirBack = origPos - pos
					local distBack = dirBack.Magnitude

					if distBack < 0.5 then
						returnTrove:Remove(returnConn)
						returnTrove:Clean()
						pTasks[pumpkin] = nil
						return
					end

					local newPos = pos + dirBack.Unit * math.min(distBack, 10 * dt2)
					pumpkin.CFrame = CFrame.lookAt(newPos, newPos + dirBack.Unit)
				end))

				return
			end

			local newPos = currPos + dir.Unit * moveStep
			pumpkin.CFrame = CFrame.lookAt(newPos, newPos + dir.Unit)
		end))
	end))
end

-- ─── Prompts ──────────────────────────────────────────────────────────────────

local function setupPrompts()
	for _, prmpt in ipairs(CollectionService:GetTagged("TrickOrTreatHousePrompt")) do
		local prompt = prmpt:FindFirstChildWhichIsA("ProximityPrompt")
		if not prompt then continue end

		local promptTrove = eventTrove:Extend()
		promptTrove:Add(prompt.Triggered:Connect(function(plr)
			if plr ~= LocalPlayer then return end

			local door = prmpt.Parent:FindFirstChild("Door")
			if not door then return end

			prompt.Enabled = false

			if not door:GetAttribute("Open") then
				door:SetAttribute("Open", true)
			end

			promptTrove:Add(function()
				if door and door.Parent then
					door:SetAttribute("Open", false)
				end
			end)

			task.wait(2)
			door:SetAttribute("Open", false)
			promptTrove:Clean()
		end))
	end
end

setupPrompts()

-- ─── Attack loop ──────────────────────────────────────────────────────────────

eventTrove:Add(task.spawn(function()
	while isActive do
		task.wait(3)
		if not isActive then break end
		local target = pickTarget()
		if target then hitAnimal(target) end
	end
end))

-- ─── Shutdown ─────────────────────────────────────────────────────────────────

while EventController:GetActiveEventData(EVENT_NAME) do
	task.wait(1)
end

isActive = false

for pumpkin, trove in pairs(pTasks) do
	trove:Clean()
	pTasks[pumpkin] = nil
end

eventTrove:Destroy()
table.clear(targetted)
