local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local Observers        = require(ReplicatedStorage.Packages.Observers)

local script_ref = ReplicatedStorage.Controllers.EventController.Events.Easter

repeat task.wait() until ReplicatedStorage:GetAttribute("EasterEvent")

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

-- ── bunny visual — mirrors the decompiled client exactly ──────────────────
-- original observes "EasterEventBunny" tag, welds script.Bunny to the anchor,
-- plays BunnyIdle looped, BunnyRun on Moving, BunnyAttack on Jumping,
-- and does the arc jump via PreRender when JumpTarget is set
local function attachBunnyVisual(anchor, entityData)
    local bunny = script_ref.Bunny:Clone()
    if bunny.ScaleTo then bunny:ScaleTo(1) end
    bunny.Parent = workspace

    local weld = Instance.new("Weld")
    weld.Part0 = bunny.PrimaryPart
    weld.Part1 = anchor
    weld.C0    = bunny.PrimaryPart.PivotOffset
    weld.Parent = bunny.PrimaryPart

    local animator = bunny.AnimationController.Animator

    local idleAnim   = animator:LoadAnimation(script_ref.BunnyIdle)
    idleAnim.Priority = Enum.AnimationPriority.Idle
    idleAnim.Looped   = true
    idleAnim:Play()

    local runAnim    = animator:LoadAnimation(script_ref.BunnyRun)
    runAnim.Priority  = Enum.AnimationPriority.Action
    runAnim.Looped    = true

    local attackAnim = animator:LoadAnimation(script_ref.BunnyAttack)
    attackAnim.Priority = Enum.AnimationPriority.Action4
    attackAnim.Looped   = false

    -- Moving attribute drives run anim
    anchor:GetAttributeChangedSignal("Moving"):Connect(function()
        if anchor:GetAttribute("Moving") then
            runAnim:Play()
        else
            runAnim:Stop()
        end
    end)

    -- Jumping attribute drives attack anim + arc jump
    local jumpTrove
    anchor:GetAttributeChangedSignal("Jumping"):Connect(function()
        if jumpTrove then jumpTrove:Disconnect(); jumpTrove = nil end

        local jumping = anchor:GetAttribute("Jumping")
        if not jumping then
            attackAnim:Stop(0)
            weld.Enabled = true
            if bunny.PrimaryPart then bunny.PrimaryPart.Anchored = false end
            return
        end

        runAnim:Stop()
        attackAnim:Play()

        local target = anchor:GetAttribute("JumpTarget")
        if not target then return end

        weld.Enabled = false
        bunny.PrimaryPart.Anchored = true

        local startPos  = bunny:GetPivot().Position
        local horizDist = ((ClientEventUtils.getAnimalCFrame(target).Position - startPos) * Vector3.new(1,0,1)).Magnitude
        local arcHeight = math.clamp(horizDist / 20, 0, 1) * 4 + 1
        local elapsed   = 0

        jumpTrove = RunService.PreRender:Connect(function(dt)
            elapsed += dt
            local t = math.clamp((elapsed - 0.767) / 0.567, 0, 1)
            if elapsed < 0.767 then return end

            local targetPos = ClientEventUtils.getAnimalCFrame(target, { top = true }).Position
            local px = startPos.X + (targetPos.X - startPos.X) * t
            local pz = startPos.Z + (targetPos.Z - startPos.Z) * t
            local py
            if t <= 0.471 then
                py = startPos.Y + math.sin(t / 0.471 * math.pi * 0.5) * arcHeight
            else
                py = startPos.Y + math.cos((t - 0.471) / 0.529 * math.pi * 0.5) * arcHeight
            end

            local newPos = Vector3.new(px, py, pz)
            local horiz  = (targetPos - startPos) * Vector3.new(1,0,1)
            if horiz.Magnitude > 0.01 then
                bunny:PivotTo(CFrame.lookAt(newPos, newPos + horiz.Unit))
            else
                bunny:PivotTo(CFrame.new(newPos))
            end

            if t >= 0.95 then
                ClientEventUtils.playBurst(script_ref.Burst, target, {
                    ReplicatedStorage.Sounds.Events.Easter.Hit
                })
                bunny:Destroy()
                jumpTrove:Disconnect()
                jumpTrove = nil
            end
        end)
    end)

    entityData.bunny  = bunny
    entityData.weld   = weld
    entityData.anchor = anchor
end

-- ── server-side bunny anchor (invisible, tagged) ───────────────────────────
local function createAnchor(pos)
    local anchor = Instance.new("Part")
    anchor.Name        = "AnchorPart"
    anchor.Size        = Vector3.new(1,1,1)
    anchor.Transparency = 1
    anchor.CanCollide  = false
    anchor.Anchored    = true
    anchor.CFrame      = CFrame.new(pos)

    local model = Instance.new("Model")
    model.Name        = "EasterBunny"
    model.PrimaryPart = anchor
    model:SetAttribute("Scale",   1)
    model:SetAttribute("Moving",  false)
    model:SetAttribute("Jumping", false)
    anchor.Parent = model
    model.Parent  = workspace

    CollectionService:AddTag(anchor, "EasterEventBunny")
    return model, anchor
end

local function wanderBunny(entityData)
    if entityData.busy or not entityData.model.Parent then return end
    local home   = entityData.home
    local size   = home.Size
    local offset = Vector3.new((math.random()-0.5)*size.X, 0, (math.random()-0.5)*size.Z)
    local target = stickToGround(home.Position + offset)
    local start  = entityData.anchor.CFrame.Position
    local dist   = (target - start).Magnitude
    if dist < 1 then return end

    local dir      = (target - start).Unit
    local duration = dist / HOP_SPEED
    local elapsed  = 0

    entityData.anchor:SetAttribute("Moving", true)
    task.spawn(function()
        while elapsed < duration and running and entityData.model.Parent and not entityData.busy do
            local dt = task.wait()
            elapsed += dt
            local p = stickToGround(start:Lerp(target, math.clamp(elapsed/duration,0,1)))
            entityData.anchor.CFrame = CFrame.new(p, p + dir)
        end
        if entityData.anchor and entityData.anchor.Parent then
            entityData.anchor:SetAttribute("Moving", false)
        end
    end)
end

local function doBunnyJump(entityData, targetAnimal)
    if entityData.busy or not entityData.model.Parent then return end
    entityData.busy = true
    entityData.anchor:SetAttribute("Moving", true)

    task.spawn(function()
        local timeout = os.clock() + 12
        local reached = false

        while running and entityData.model.Parent
            and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart
        do
            if os.clock() > timeout then break end
            local myPos  = entityData.anchor.CFrame.Position
            local tgtPos = targetAnimal.PrimaryPart.Position
            local dist   = (tgtPos - myPos).Magnitude
            if dist < 10 then reached = true; break end
            local dt  = task.wait()
            local dir = (tgtPos - myPos).Unit
            local np  = stickToGround(myPos + dir * math.min(HOP_SPEED * dt, dist))
            entityData.anchor.CFrame = CFrame.new(np, np + dir)
        end

        entityData.anchor:SetAttribute("Moving", false)

        if reached and targetAnimal and targetAnimal.Parent then
            entityData.anchor:SetAttribute("JumpTarget", targetAnimal.Name)
            entityData.anchor:SetAttribute("Jumping", true)
            task.wait(1.4)
            entityData.anchor:SetAttribute("Jumping", false)
            entityData.anchor:SetAttribute("JumpTarget", nil)
        end

        entityData.busy = false
    end)
end

-- ── coins ──────────────────────────────────────────────────────────────────
local function getWanderBaseParts()
    local parts = {}
    if WANDER_FOLDER then
        for _, p in ipairs(WANDER_FOLDER:GetDescendants()) do
            if p:IsA("BasePart") then table.insert(parts, p) end
        end
    end
    return parts
end

local function spawnCoinWave(count)
    local baseParts = getWanderBaseParts()

    for _ = 1, count do
        coinCounter += 1
        local coinId = ("eastercoin_%d_%d"):format(os.time(), coinCounter)
        local origin, landPos

        if #baseParts > 0 then
            local part    = baseParts[math.random(1,#baseParts)]
            local size    = part.Size
            local topFace = part.CFrame:PointToWorldSpace(
                Vector3.new((math.random()-0.5)*size.X, size.Y/2, (math.random()-0.5)*size.Z))
            local hit = workspace:Raycast(topFace+Vector3.new(0,10,0), Vector3.new(0,-30,0), RaycastParams.new())
            landPos = hit and hit.Position or topFace
            origin  = part.Position + Vector3.new(0,4,0)
        else
            local angle = math.random()*math.pi*2
            local r     = math.random(15,40)
            origin  = Vector3.new(0,5,0)
            local sc = Vector3.new(math.cos(angle)*r, 20, math.sin(angle)*r)
            local hit = workspace:Raycast(sc, Vector3.new(0,-40,0), RaycastParams.new())
            landPos = hit and hit.Position or (sc - Vector3.new(0,20,0))
        end

        if script_ref:FindFirstChild("BunnyCoin") then
            local coin    = script_ref.BunnyCoin:Clone()
            coin.CFrame   = CFrame.new(origin)
            coin.Parent   = workspace
            local elapsed = 0
            local conn
            conn = RunService.PostSimulation:Connect(function(dt)
                elapsed += dt
                local t = math.clamp(elapsed/COIN_FLIGHT_TIME, 0, 1)
                coin.CFrame = CFrame.new(Vector3.new(
                    origin.X + (landPos.X-origin.X)*t,
                    origin.Y + math.sin(t*math.pi)*15,
                    origin.Z + (landPos.Z-origin.Z)*t
                ))
                if t >= 1 then
                    conn:Disconnect()
                    local bob = 0
                    local bc
                    bc = RunService.PostSimulation:Connect(function(dt2)
                        bob += dt2
                        coin.CFrame = CFrame.new(landPos+Vector3.new(0,math.sin(bob*3)*0.3,0))
                            * CFrame.Angles(0,bob,0)
                        if not activeCoins[coinId] then
                            task.delay(0.3, function() coin:Destroy() end)
                            bc:Disconnect()
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
        local model, anchor = createAnchor(pos)
        local entityData = { model = model, anchor = anchor, home = home, busy = false }
        attachBunnyVisual(anchor, entityData)
        table.insert(spawnedBunnies, entityData)
    end
end

-- ── loops ──────────────────────────────────────────────────────────────────
task.spawn(function()
    while running do
        for _, b in ipairs(spawnedBunnies) do
            if b.model and b.model.Parent and not b.busy
                and not b.anchor:GetAttribute("Moving") and math.random() > 0.35
            then wanderBunny(b) end
        end
        task.wait(2.5)
    end
end)

task.spawn(function()
    while running do
        task.wait(math.random(6,10))
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
        task.wait(math.random(COIN_LOOP_MIN*100, COIN_LOOP_MAX*100)/100)
    end
end)

-- ── cleanup ────────────────────────────────────────────────────────────────
task.spawn(function()
    while ReplicatedStorage:GetAttribute("EasterEvent") do task.wait(1) end
    running = false
    for _, b in ipairs(spawnedBunnies) do
        if b.model and b.model.Parent then b.model:Destroy() end
        if b.bunny and b.bunny.Parent then b.bunny:Destroy() end
    end
    activeCoins    = {}
    spawnedBunnies = {}
end)
