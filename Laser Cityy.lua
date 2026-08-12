local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local EventController = require(ReplicatedStorage.Controllers.EventController)

local EVENT_NAME  = "Laser City"
local LASER_SPEED = 26
local DWELL_MIN   = 0.15
local DWELL_MAX   = 0.6

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local LaserCaylus = workspace:WaitForChild("LaserCityMap"):WaitForChild("LaserCaylus")
local impact      = LaserCaylus:WaitForChild("Impact")

local function getFloorParts(): { BasePart }
	local folder = workspace:FindFirstChild("Events")
	local model  = folder and folder:FindFirstChild("Laser City")
	if not model then return {} end
	local out = {}
	for _, name in ipairs({ "MapFloorLeft", "MapFloorRight" }) do
		local p = model:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			table.insert(out, p)
		end
	end
	return out
end

local function pickRandomPoint(): Vector3
	local floors = getFloorParts()
	if #floors == 0 then return Vector3.new(0, 0, 0) end
	local floor = floors[math.random(1, #floors)]
	local s, p  = floor.Size, floor.Position
	return Vector3.new(
		p.X + (math.random() * 2 - 1) * (s.X / 2),
		p.Y + s.Y / 2,
		p.Z + (math.random() * 2 - 1) * (s.Z / 2)
	)
end

task.spawn(function()
	while EventController:GetActiveEventData(EVENT_NAME) and impact and impact.Parent do
		local target   = pickRandomPoint()
		local dist     = (target - impact.Position).Magnitude
		local duration = math.max(dist / LASER_SPEED, 0.001)

		TweenService:Create(
			impact,
			TweenInfo.new(duration, Enum.EasingStyle.Linear),
			{ Position = target }
		):Play()

		task.wait(duration + DWELL_MIN + math.random() * (DWELL_MAX - DWELL_MIN))
	end
end)
