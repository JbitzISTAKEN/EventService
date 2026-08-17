if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local PhysicsService    = game:GetService("PhysicsService")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)

-- ─── Config ───────────────────────────────────────────────────────────────────

local EVENT_NAME = "Soccer"
local TRAIT_NAME = "Soccer Ball"

local TOTAL_BALLS         = math.random(4, 7)
local BALL_SPEED          = 55
local STRIKE_COOLDOWN_MIN = 8
local STRIKE_COOLDOWN_MAX = 14
local CHASE_TIMEOUT       = 15
local CHASE_REACH_DIST    = 12
local IMPACT_DURATION     = 1.2
local POST_IMPACT_WAIT    = 1
local RETIRE_WAIT         = 2
local WANDER_INTERVAL     = 3
local WANDER_CHANCE       = 0.6

local RAIN_AREA_CENTER = Vector3.new(0, 0, 0)
local RAIN_AREA_SIZE   = Vector3.new(60, 0, 60)

local rng = Random.new()

-- ─── Wait for spoofer ─────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove   = Trove.new()
local spawnedBalls = {}
local isActive     = true

-- ─── Physics groups ───────────────────────────────────────────────────────────

pcall(function()
    if not PhysicsService:IsCollisionGroupRegistered("SoccerBall") then
        PhysicsService:RegisterCollisionGroup("SoccerBall")
    end
    PhysicsService:CollisionGroupSetCollidable("SoccerBall", "Player", false)
    PhysicsService:CollisionGroupSetCollidable("SoccerBall", "Animal", false)
end)

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local HttpService = game:GetService("HttpService")

local function stickToGround(position: Vector3): Vector3
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = {
        workspace:FindFirstChild("Map") or workspace,
        workspace.Terrain,
    }
    local result = workspace:Raycast(position + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0), params)
    return result and result.Position + Vector3.new(0, 1, 0) or position
end

local function getRandomFieldPos(): Vector3
    local board = workspace:FindFirstChild("SoccerScoreBoard")
    local center = board and board:GetPivot().Position or RAIN_AREA_CENTER
    local offset = Vector3.new(
        (math.random() - 0.5) * RAIN_AREA_SIZE.X,
        0,
        (math.random() - 0.5) * RAIN_AREA_SIZE.Z
    )
    return stickToGround(center + offset)
end

local function animalHasTrait(animal: Model): boolean
    local json = animal:GetAttribute("Traits")
    if not json then return false end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return false end
    for _, t in ipairs(decoded) do
        if t == TRAIT_NAME then return true end
    end
    return false
end

local function giveTrait(animal: Model)
    local json   = animal:GetAttribute("Traits")
    local traits = {}
    if json then
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
        if ok and type(decoded) == "table" then traits = decoded end
    end
    for _, t in ipairs(traits) do
        if t == TRAIT_NAME then return end
    end
    table.insert(traits, TRAIT_NAME)
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function removeFromList(ball)
    local idx = table.find(spawnedBalls, ball)
    if idx then
        spawnedBalls[idx] = spawnedBalls[#spawnedBalls]
        spawnedBalls[#spawnedBalls] = nil
    end
end

-- ─── Ball model ───────────────────────────────────────────────────────────────

local function createBall(position: Vector3): Model
    local model = Instance.new("Model")
    model.Name  = "SoccerEventBall"
    model:SetAttribute("Moving",   false)
    model:SetAttribute("Striking", false)

    local anchor = Instance.new("Part")
    anchor.Name         = "AnchorPart"
    anchor.Size         = Vector3.new(1, 1, 1)
    anchor.Transparency = 1
    anchor.CanCollide   = false
    anchor.Anchored     = true
    anchor.CFrame       = CFrame.new(position)
    anchor.Parent       = model

    model.PrimaryPart = anchor
    model.Parent      = workspace
    return model
end

-- ─── Behavior ─────────────────────────────────────────────────────────────────

local spawnBall

local function wander(ball)
    if not ball.Model or not ball.Model.Parent then return end
    if ball.IsBusy then return end

    local targetPos = getRandomFieldPos()
    local startPos  = ball.Model:GetPivot().Position
    local diff      = targetPos - startPos
    local distance  = diff.Magnitude
    if distance < 1 then return end

    local direction = diff.Unit
    local duration  = distance / BALL_SPEED

    ball.wanderGen = (ball.wanderGen or 0) + 1
    local myGen = ball.wanderGen

    ball.Model:SetAttribute("Moving", true)

    ball.Trove:Add(task.spawn(function()
        local elapsed = 0
        while elapsed < duration
            and not ball.IsBusy
            and isActive
            and ball.Model
            and ball.Model.Parent
        do
            local dt = task.wait()
            elapsed += dt
            local alpha = math.clamp(elapsed / duration, 0, 1)
            local pos   = stickToGround(startPos:Lerp(targetPos, alpha))
            ball.Model:PivotTo(CFrame.new(pos, pos + direction))
        end
        if ball.Model and ball.Model.Parent
            and ball.wanderGen == myGen
            and not ball.IsBusy
        then
            ball.Model:SetAttribute("Moving", false)
        end
    end))
end

local function retireAndRespawn(ball)
    removeFromList(ball)

    ball.Trove:Add(task.delay(RETIRE_WAIT, function()
        eventTrove:Remove(ball.Trove)
        if not isActive then return end
        spawnBall()
    end))
end

local function strikeAnimal(ball, targetAnimal: Model)
    if not ball.Model or not ball.Model.Parent then return end
    if ball.IsBusy then return end

    ball.IsBusy    = true
    ball.wanderGen = (ball.wanderGen or 0) + 1
    ball.Model:SetAttribute("Moving", false)

    ball.Trove:Add(task.spawn(function()
        local chaseStart = os.clock()
        local reached    = false

        ball.Model:SetAttribute("Moving", true)

        while isActive
            and ball.Model and ball.Model.Parent
            and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart
        do
            if os.clock() - chaseStart > CHASE_TIMEOUT then break end

            local myPos  = ball.Model:GetPivot().Position
            local tgtPos = targetAnimal.PrimaryPart.Position
            local dist   = (tgtPos - myPos).Magnitude

            if dist < CHASE_REACH_DIST then
                reached = true
                break
            end

            local dt     = task.wait()
            local dir    = (tgtPos - myPos).Unit
            local newPos = stickToGround(myPos + dir * math.min(BALL_SPEED * dt, dist))
            ball.Model:PivotTo(CFrame.new(newPos, newPos + dir))
        end

        ball.Model:SetAttribute("Moving", false)

        if not reached or not (targetAnimal and targetAnimal.Parent) then
            ball.IsBusy = false
            return
        end

        ball.Model:SetAttribute("StrikeTarget", targetAnimal.Name)
        ball.Model:SetAttribute("Striking",     true)
        task.wait(IMPACT_DURATION)

        giveTrait(targetAnimal)

        if ball.Model and ball.Model.Parent then
            ball.Model:SetAttribute("Striking",     false)
            ball.Model:SetAttribute("StrikeTarget", nil)
        end

        ball.IsBusy = false
        task.wait(POST_IMPACT_WAIT)

        if ball.Model and ball.Model.Parent then
            retireAndRespawn(ball)
        end
    end))
end

-- ─── Spawn ────────────────────────────────────────────────────────────────────

spawnBall = function()
    if not isActive then return end

    local pos   = getRandomFieldPos()
    local model = createBall(pos)

    local ballTrove = eventTrove:Extend()
    ballTrove:Add(model)

    local ball = {
        Model     = model,
        IsBusy    = false,
        wanderGen = 0,
        Trove     = ballTrove,
    }

    table.insert(spawnedBalls, ball)
    return ball
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    for _ = 1, TOTAL_BALLS do
        spawnBall()
    end

    -- wander tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(WANDER_INTERVAL)
            for _, ball in ipairs(spawnedBalls) do
                if ball.Model and ball.Model.Parent
                    and not ball.IsBusy
                    and not ball.Model:GetAttribute("Moving")
                    and math.random() < WANDER_CHANCE
                then
                    wander(ball)
                end
            end
        end
    end))

    -- strike tick
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(STRIKE_COOLDOWN_MIN, STRIKE_COOLDOWN_MAX))
            if not isActive or #spawnedBalls == 0 then break end

            local candidates = {}
            for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                if animal.PrimaryPart and not animalHasTrait(animal) then
                    table.insert(candidates, animal)
                end
            end
            if #candidates == 0 then continue end

            local free = {}
            for _, ball in ipairs(spawnedBalls) do
                if not ball.IsBusy and ball.Model and ball.Model.Parent then
                    table.insert(free, ball)
                end
            end
            if #free == 0 then continue end

            strikeAnimal(
                free[math.random(1, #free)],
                candidates[math.random(1, #candidates)]
            )
        end
    end))

    -- shutdown — identical to Easter
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end

    isActive = false
    eventTrove:Destroy()
    table.clear(spawnedBalls)
end

task.spawn(main)
