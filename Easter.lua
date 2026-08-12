local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local VFX             = require(ReplicatedStorage.Shared.VFX)
local SoundController = require(ReplicatedStorage.Controllers.SoundController)

local TRAIT_NAME         = "Bunny Ears"
local HOP_SPEED          = 18
local COIN_FLIGHT_TIME   = 1.2
local COIN_WAVE_MIN      = 3
local COIN_WAVE_MAX      = 6
local COIN_LOOP_MIN      = 5
local COIN_LOOP_MAX      = 9
local COIN_INITIAL_DELAY = 5
local COIN_LIFETIME      = 30
local TOTAL_BUNNIES      = math.random(6, 10)
local FALLOFF_RADIUS     = 40

-- wait for event to actually be active before touching any assets
repeat task.wait() until ReplicatedStorage:GetAttribute("EasterEvent")

-- paths confirmed from your explorer: EventController.Events.Easter
local EventAssets = ReplicatedStorage.Controllers.EventController.Events.Easter
local Sounds      = ReplicatedStorage.Sounds.Events.Easter

local WANDER_FOLDER = workspace:FindFirstChild("Events")
    and workspace.Events:FindFirstChild("Wander")

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Include
RayParams.FilterDescendantsInstances = {
    workspace:WaitForChild("Map"),
    workspace.Terrain,
}

local running        = true
local spawnedBunnies = {}
local activeCoins    = {}
local coinCounter    = 0

-- ── utils ──────────────────────────────────────────────────────────────────
local function stickToGround(pos)
    local result = workspace:Raycast(pos + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0), RayParams)
    return result and result.Position + Vector3.new(0, 1, 0) or pos
end

local function getRandomWanderPart()
    if not WANDER_FOLDER then return nil end
    local parts = WANDER_FOLDER:GetChildren()
    return #parts > 0 and parts[math.random(1, #parts)] or nil
end

local function hasTrait(animal)
    local json = animal:GetAttribute("Traits")
    if not json then return false end
    local ok, t = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(t) ~= "table" then return false end
    for _, v in ipairs(t) do if v == TRAIT_NAME then return true end end
    return false
end

-- ── bunny visuals ──────────────────────────────────────────────────────────
local function spawnBunnyVisual(pos)
    local model = EventAssets.Bunny:Clone()
    model:PivotTo(CFrame.new(pos))
    model.Parent = workspace
    return model
end

local function wanderBunny(bunnyData)
    if bunnyData.busy or not bunnyData.model.Parent then return end
    local home   = bunnyData.home
    local size   = home.Size
    local offset = Vector3.new((math.random()-0.5)*size.X, 0, (math.random()-0.5)*size.Z)
    local target = stickToGround(home.Position + offset)
    local start  = bunnyData.model:GetPivot().Position
    local dist   = (target - start).Magnitude
    if dist < 1 then return end

    local dir      = (target - start).Unit
    local duration = dist / HOP_SPEED
    local elapsed  = 0

    bunnyData.model:SetAttribute("Moving", true)
    task.spawn(function()
        while elapsed < duration and running and bunnyData.model.Parent and not bunnyData.busy do
            local dt = task.wait()
            elapsed += dt
            local p = stickToGround(start:Lerp(target, math.clamp(elapsed/duration, 0, 1)))
            bunnyData.model:PivotTo(CFrame.new(p, p + dir))
        end
        if bunnyData.model and bunnyData.model.Parent then
            bunnyData.model:SetAttribute("Moving", false)
        end
    end)
end

local function doBunnyJump(bunnyData, targetAnimal)
    if bunnyData.busy or not bunnyData.model.Parent then return end
    bunnyData.busy = true
    bunnyData.model:SetAttribute("Moving", true)

    task.spawn(function()
        local timeout = os.clock() + 12
        local reached = false

        while running and bunnyData.model.Parent and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart do
            if os.clock() > timeout then break end
            local myPos  = bunnyData.model:GetPivot().Position
            local tgtPos = targetAnimal.PrimaryPart.Position
            local dist   = (tgtPos - myPos).Magnitude
            if dist < 10 then reached = true; break end
            local dt  = task.wait()
            local dir = (tgtPos - myPos).Unit
            local np  = stickToGround(myPos + dir * math.min(HOP_SPEED * dt, dist))
            bunnyData.model:PivotTo(CFrame.new(np, np + dir))
        end

        bunnyData.model:SetAttribute("Moving", false)

        if reached and targetAnimal and targetAnimal.Parent then
            bunnyData.model:SetAttribute("Jumping", true)
            local burst = EventAssets:FindFirstChild("Burst") and EventAssets.Burst:Clone()
            if burst then
                burst.CFrame = CFrame.new(targetAnimal.PrimaryPart.Position)
                burst.Parent = workspace
                VFX.emit(burst)
                task.delay(3, function() burst:Destroy() end)
            end
            if Sounds:FindFirstChild("BurstSound") then
                SoundController:PlaySound(Sounds.BurstSound, targetAnimal.PrimaryPart.Position)
            end
            task.wait(1.4)
            bunnyData.model:SetAttribute("Jumping", false)
        end

        bunnyData.busy = false
    end)
end

-- ── coins ──────────────────────────────────────────────────────────────────
local function spawnCoinWave(count)
    local baseParts = {}
    if WANDER_FOLDER then
        for _, p in ipairs(WANDER_FOLDER:GetDescendants()) do
            if p:IsA("BasePart") then table.insert(baseParts, p) end
        end
    end

    for _ = 1, count do
        coinCounter += 1
        local coinId = ("eastercoin_%d_%d"):format(os.time(), coinCounter)

        local origin, landPos
        if #baseParts > 0 then
            local part    = baseParts[math.random(1, #baseParts)]
            local size    = part.Size
            local topFace = part.CFrame:PointToWorldSpace(Vector3.new((math.random()-0.5)*size.X, size.Y/2, (math.random()-0.5)*size.Z))
            local hit     = workspace:Raycast(topFace + Vector3.new(0,10,0), Vector3.new(0,-30,0), RaycastParams.new())
            landPos = hit and hit.Position or topFace
            origin  = part.Position + Vector3.new(0, 4, 0)
        else
            local angle   = math.random() * math.pi * 2
            local r       = math.random(15, FALLOFF_RADIUS)
            origin        = Vector3.new(0, 5, 0)
            local scatter = Vector3.new(math.cos(angle)*r, 20, math.sin(angle)*r)
            local hit     = workspace:Raycast(scatter, Vector3.new(0,-40,0), RaycastParams.new())
            landPos = hit and hit.Position or (scatter - Vector3.new(0,20,0))
        end

        -- visual coin
        if EventAssets:FindFirstChild("BunnyCoin") then
            local coin    = EventAssets.BunnyCoin:Clone()
            coin.CFrame   = CFrame.new(origin)
            coin.Parent   = workspace
            local elapsed = 0
            local conn
            conn = RunService.PostSimulation:Connect(function(dt)
                elapsed += dt
                local t   = math.clamp(elapsed / COIN_FLIGHT_TIME, 0, 1)
                local mid = (origin + landPos)/2 + Vector3.new(0, 15, 0)
                coin.CFrame = CFrame.new(Vector3.new(
                    origin.X + (landPos.X - origin.X) * t,
                    origin.Y + (mid.Y - origin.Y) * math.sin(t * math.pi),
                    origin.Z + (landPos.Z - origin.Z) * t
                ))
                if t >= 1 then
                    conn:Disconnect()
                    local bob = 0
                    local bobConn
                    bobConn = RunService.PostSimulation:Connect(function(dt2)
                        bob += dt2
                        coin.CFrame = CFrame.new(landPos + Vector3.new(0, math.sin(bob*3)*0.3, 0)) * CFrame.Angles(0, bob, 0)
                        if not activeCoins[coinId] then
                            task.delay(0.3, function() coin:Destroy() end)
                            bobConn:Disconnect()
                        end
                    end)
                end
            end)
            activeCoins[coinId] = true
        end

        task.delay(COIN_LIFETIME, function() activeCoins[coinId] = nil end)
    end
end

-- ── spawn bunnies ──────────────────────────────────────────────────────────
for _ = 1, TOTAL_BUNNIES do
    local home = getRandomWanderPart()
    if home then
        local size   = home.Size
        local offset = Vector3.new((math.random()-0.5)*size.X, 0, (math.random()-0.5)*size.Z)
        local pos    = stickToGround(home.Position + offset)
        local model  = spawnBunnyVisual(pos)
        table.insert(spawnedBunnies, { model = model, home = home, busy = false })
    end
end

-- ── loops ──────────────────────────────────────────────────────────────────
task.spawn(function()
    while running do
        for _, b in ipairs(spawnedBunnies) do
            if b.model and b.model.Parent and not b.busy
                and not b.model:GetAttribute("Moving") and math.random() > 0.35
            then wanderBunny(b) end
        end
        task.wait(2.5)
    end
end)

task.spawn(function()
    while running do
        task.wait(math.random(6, 10))
        local candidates = {}
        for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
            if animal.PrimaryPart and not hasTrait(animal) then
                table.insert(candidates, animal)
            end
        end
        if #candidates == 0 then continue end
        local free = {}
        for _, b in ipairs(spawnedBunnies) do
            if not b.busy and b.model and b.model.Parent then table.insert(free, b) end
        end
        if #free == 0 then continue end
        doBunnyJump(free[math.random(1,#free)], candidates[math.random(1,#candidates)])
    end
end)

task.spawn(function()
    task.wait(COIN_INITIAL_DELAY)
    while running do
        spawnCoinWave(math.random(COIN_WAVE_MIN, COIN_WAVE_MAX))
        task.wait(math.random(COIN_LOOP_MIN*100, COIN_LOOP_MAX*100) / 100)
    end
end)

-- ── cleanup ────────────────────────────────────────────────────────────────
task.spawn(function()
    while ReplicatedStorage:GetAttribute("EasterEvent") do task.wait(1) end
    running = false
    for _, b in ipairs(spawnedBunnies) do
        if b.model and b.model.Parent then b.model:Destroy() end
    end
    activeCoins    = {}
    spawnedBunnies = {}
end)
