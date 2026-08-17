-- LocalScript: Crab Rave Client — zero remotes
-- Ground crabs: rbxassetid://109050002810374
-- Wall crabs:   rbxassetid://136326795890759
-- Animation state: Dance attribute (1-4) + IsRunning + Attack
-- Mirrors: CrabRave server OnStart structure, client observer pattern

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)
local SoundController = require(ReplicatedStorage.Controllers.SoundController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

local EVENT_NAME = "Crab Rave"

-- ─── Config ──────────────────────────────────────────────────────────────────

local GROUND_ASSET_ID    = "rbxassetid://109050002810374"
local WALL_ASSET_ID      = "rbxassetid://136326795890759"
local CARPET_CHECK       = SharedEventUtils
local COOLDOWN           = 15
local TICK_MIN           = 1.5
local TICK_MAX           = 3.0
local MAX_ATTACKERS      = 2
local CHASE_SPEED        = 22
local WANDER_SPEED       = 20
local ATTACK_REACH_DIST  = 10
local CHASE_TIMEOUT      = 30
local ATTACK_WAIT        = 1
local POST_ATTACK_WAIT   = 1
local WANDER_INTERVAL    = 1.0
local WANDER_CHANCE      = 0.6
local MAX_WANDERERS      = 5
local MAP_CENTER_X       = -410.697

-- Dance cycle timing — mirrors server globalDanceIndex scheduler
local DANCE_SWITCH_MIN  = 10
local DANCE_SWITCH_MAX  = 15
local DANCE_PAUSE_MIN   = 1
local DANCE_PAUSE_MAX   = 3
local DANCE_LOCK_TIME   = 141  -- elapsed seconds: lock to dance 4

-- ─── State ───────────────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData  = EventController:GetActiveEventData(EVENT_NAME)
local startedAt  = eventData.startedAt

local function getElapsed(): number
    return workspace:GetServerTimeNow() - startedAt
end

local scriptTrove      = Trove.new()
local crabs            = {}         -- { Model, Type, Home, IsBusy, StartCFrame, Role, wanderGen, Trove }
local activeCrabs      = {}         -- [crab] = true
local recentlyTargeted = {}         -- [animalName] = timestamp
local isActive         = true
local globalDanceIndex = 0

-- ─── Asset templates (loaded once) ───────────────────────────────────────────

local groundTemplate: Model? = nil
local wallTemplate: Model?   = nil

local function loadTemplates()
    task.spawn(function()
        local g = game:GetObjects(GROUND_ASSET_ID)
        if g and g[1] then
            groundTemplate = g[1]
            groundTemplate.Name = "CrabGround"
        end
    end)
    task.spawn(function()
        local w = game:GetObjects(WALL_ASSET_ID)
        if w and w[1] then
            wallTemplate = w[1]
            wallTemplate.Name = "CrabWall"
        end
    end)
end

loadTemplates()

-- ─── Raycast ground stick ─────────────────────────────────────────────────────

local RAY_PARAMS = RaycastParams.new()
RAY_PARAMS.FilterType = Enum.RaycastFilterType.Include
RAY_PARAMS.FilterDescendantsInstances = {
    workspace:FindFirstChild("Map") or workspace,
    workspace.Terrain,
}

local function stickToGround(pos: Vector3): Vector3
    local result = workspace:Raycast(pos + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0), RAY_PARAMS)
    return result and result.Position + Vector3.new(0, 1, 0) or pos
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function hasClaws(animal: Model): boolean
    local json = animal:GetAttribute("Traits")
    if not json then return false end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return false end
    for _, t in ipairs(decoded) do
        if t == "Claws" then return true end
    end
    return false
end

local function giveClaws(animal: Model)
    local json   = animal:GetAttribute("Traits")
    local traits = {}
    if json then
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
        if ok and type(decoded) == "table" then traits = decoded end
    end
    for _, t in ipairs(traits) do
        if t == "Claws" then return end
    end
    table.insert(traits, "Claws")
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function pruneTargets()
    local now = workspace:GetServerTimeNow()
    for name, t in pairs(recentlyTargeted) do
        if now - t > COOLDOWN then recentlyTargeted[name] = nil end
    end
end

-- ─── Crab model ──────────────────────────────────────────────────────────────

local function createCrab(cf: CFrame, crabType: string): Model
    local model = Instance.new("Model")
    model.Name  = "Crab"

    local root = Instance.new("Part")
    root.Name         = "HumanoidRootPart"
    root.Size         = Vector3.new(2, 2, 2)
    root.Transparency = 1
    root.CanCollide   = false
    root.Anchored     = true
    root.CFrame       = cf
    root.Parent       = model
    model.PrimaryPart = root

    model:SetAttribute("CrabType",  crabType)
    model:SetAttribute("IsRunning", false)
    model:SetAttribute("Dance",     0)
    model:SetAttribute("Attack",    false)

    CollectionService:AddTag(model, "CrabRaveCrabs")
    model.Parent = workspace

    -- Mesh clone from asset
    local template = crabType == "Wall" and wallTemplate or groundTemplate
    if template then
        local mesh = template:Clone()

        -- Strip old AnimationController, install Humanoid+Animator rig
        local oldAC = mesh:FindFirstChild("AnimationController")
        if oldAC then oldAC:Destroy() end

        local humanoid           = Instance.new("Humanoid")
        humanoid.Name            = "AnimationController"
        humanoid.EvaluateStateMachine = false
        humanoid.DisplayDistanceType  = Enum.HumanoidDisplayDistanceType.None
        humanoid.PlatformStand   = true
        humanoid.Parent          = mesh

        Instance.new("Animator").Parent = humanoid

        -- Weld mesh primary to invisible root
        if mesh.PrimaryPart then
            local weld   = Instance.new("Weld")
            weld.Part0   = mesh.PrimaryPart
            weld.Part1   = root
            weld.Parent  = mesh.PrimaryPart
        end

        mesh.Parent = model
    end

    return model
end

-- ─── Animation state machine ──────────────────────────────────────────────────
-- Mirrors client observer: Dance attr (1-4) drives dance tracks,
-- IsRunning drives walk track, Attack drives attack track.
-- Script.Animation1-8 pattern replaced with EventScript child lookup.

local EventScript = ReplicatedStorage.Controllers.EventController.Events["Crab Rave"]

local function buildCrabAnims(rootModel: Model, trove: typeof(Trove.new()))
    local mesh = nil
    for _, child in ipairs(rootModel:GetChildren()) do
        if child:IsA("Model") and child:FindFirstChild("AnimationController") then
            mesh = child
            break
        end
    end
    if not mesh then return end

    local humanoid = mesh:FindFirstChild("AnimationController")
    if not humanoid then return end
    local animator = humanoid:FindFirstChild("Animator")
    if not animator then return end

    local function loadAnim(name: string): AnimationTrack?
        local anim = EventScript:FindFirstChild(name)
        if not anim then return nil end
        local track = animator:LoadAnimation(anim)
        trove:Add(function()
            track:Stop(0)
            track:Destroy()
        end)
        return track
    end

    -- Animation slots — mirror decompiled naming
    local idleTrack   = loadAnim("Animation1")   -- spawn idle
    local walkTrack   = loadAnim("Animation4_Walk")
    local attackTrack = loadAnim("Animation4_Attack")
    local dance1      = loadAnim("Animation5")
    local dance2      = loadAnim("Animation6")
    local dance3      = loadAnim("Animation7")
    local dance4      = loadAnim("Animation8")

    local danceMap = { [1] = dance1, [2] = dance2, [3] = dance3, [4] = dance4 }

    if walkTrack   then walkTrack.Priority   = Enum.AnimationPriority.Action  end
    if attackTrack then attackTrack.Priority = Enum.AnimationPriority.Action4 end
    if dance1 then dance1.Priority = Enum.AnimationPriority.Action2 end
    if dance2 then dance2.Priority = Enum.AnimationPriority.Action2 end
    if dance3 then dance3.Priority = Enum.AnimationPriority.Action2 end
    if dance4 then dance4.Priority = Enum.AnimationPriority.Action2 end

    local currentDanceTrack: AnimationTrack? = nil

    -- Play idle on spawn, switch to walk at t=7 (mirrors client task.delay)
    if idleTrack then idleTrack:Play() end
    local elapsed = getElapsed()
    if elapsed < 7 then
        trove:Add(task.delay(math.max(0, startedAt + 7 - workspace:GetServerTimeNow()), function()
            if idleTrack and idleTrack.IsPlaying then idleTrack:Stop() end
            if walkTrack then walkTrack:Play() end
        end))
    else
        if idleTrack then idleTrack:Stop(0) end
    end

    -- IsRunning → walk track
    trove:Add(rootModel:GetAttributeChangedSignal("IsRunning"):Connect(function()
        if rootModel:GetAttribute("IsRunning") then
            if walkTrack and not walkTrack.IsPlaying then walkTrack:Play() end
            if currentDanceTrack and currentDanceTrack.IsPlaying then
                currentDanceTrack:Stop()
            end
        else
            if walkTrack and walkTrack.IsPlaying then walkTrack:Stop() end
        end
    end))

    -- Dance attr (1-4) → dance tracks, synced to music phase
    trove:Add(rootModel:GetAttributeChangedSignal("Dance"):Connect(function()
        local idx = rootModel:GetAttribute("Dance")

        if currentDanceTrack and currentDanceTrack.IsPlaying then
            currentDanceTrack:Stop()
            currentDanceTrack = nil
        end

        if idx and idx ~= 0 and danceMap[idx] then
            currentDanceTrack = danceMap[idx]
            currentDanceTrack:Play()
            -- Sync to elapsed so all crabs stay on the same beat
            local e = getElapsed()
            if currentDanceTrack.Length > 0 then
                currentDanceTrack.TimePosition = e % currentDanceTrack.Length
            end
        end
    end))

    -- Attack attr → one-shot attack track
    trove:Add(rootModel:GetAttributeChangedSignal("Attack"):Connect(function()
        if not rootModel:GetAttribute("Attack") then return end
        if attackTrack then
            attackTrack:Play()
            attackTrack.Stopped:Once(function()
                if rootModel and rootModel.Parent then
                    rootModel:SetAttribute("Attack", false)
                end
            end)
        end
    end))

    -- Dance speed slowdown at elapsed >= 141 (mirrors client task.delay + lerp)
    local elapsed141 = startedAt + 141 - workspace:GetServerTimeNow()
    if elapsed141 > 0 then
        trove:Add(task.delay(elapsed141, function()
            local lerpDuration = 20  -- 141→161 = 20s
            local t0 = os.clock()
            trove:Add(RunService.PreSimulation:Connect(function(dt)
                local alpha = math.clamp((os.clock() - t0) / lerpDuration, 0, 1)
                local speed = math.lerp(1, 0.1, alpha)
                for _, track in pairs(danceMap) do
                    if track and track.IsPlaying then
                        track:AdjustSpeed(speed)
                    end
                end
            end))
        end))
    end
end

-- ─── Dance scheduler — mirrors server globalDanceIndex loop ──────────────────

local function startDanceScheduler()
    scriptTrove:Add(task.spawn(function()
        -- Wait until t=9 (crabs are in position before dancing)
        local gate = startedAt + 9 - workspace:GetServerTimeNow()
        if gate > 0 then task.wait(gate) end

        while isActive do
            local elapsed = getElapsed()

            if elapsed >= DANCE_LOCK_TIME then
                globalDanceIndex = 4
                for _, data in ipairs(crabs) do
                    if data.Model and data.Model.Parent and not activeCrabs[data.Model] then
                        data.Model:SetAttribute("Dance", 4)
                    end
                end
                break
            end

            local newDance = math.random(1, 4)
            globalDanceIndex = newDance
            for _, data in ipairs(crabs) do
                if data.Model and data.Model.Parent and not activeCrabs[data.Model] then
                    data.Model:SetAttribute("Dance", newDance)
                end
            end

            task.wait(math.random(DANCE_SWITCH_MIN, DANCE_SWITCH_MAX))
            if not isActive then break end

            globalDanceIndex = 0
            for _, data in ipairs(crabs) do
                if data.Model and data.Model.Parent and not activeCrabs[data.Model] then
                    data.Model:SetAttribute("Dance", 0)
                end
            end

            task.wait(math.random(DANCE_PAUSE_MIN, DANCE_PAUSE_MAX))
        end
    end))
end

-- ─── Ground crab walk-in sequence — mirrors server groundCrabData walk loop ───

local function doGroundWalkIn(data)
    task.spawn(function()
        local walkStartTime  = 7
        local walkDuration   = 2
        local walkEndTime    = walkStartTime + walkDuration

        local spawnCFrame = data.SpawnCFrame
        local targetCFrame = data.StartCFrame
        local crab = data.Model

        local currentTime = getElapsed()
        if currentTime >= walkEndTime then
            if crab and crab.PrimaryPart then
                crab:PivotTo(targetCFrame)
                crab:SetAttribute("IsRunning", false)
            end
            return
        end

        -- Wait for walk start
        while getElapsed() < walkStartTime and isActive do task.wait(0.1) end
        if not isActive or not crab or not crab.Parent then return end

        crab:SetAttribute("IsRunning", true)
        local startPos = spawnCFrame.Position
        local endPos   = targetCFrame.Position

        while isActive and crab.Parent do
            local t = getElapsed()
            if t >= walkEndTime then break end
            local alpha   = math.clamp((t - walkStartTime) / walkDuration, 0, 1)
            local pos     = startPos:Lerp(endPos, alpha)
            local lookAt  = Vector3.new(endPos.X, pos.Y, endPos.Z)
            if (lookAt - pos).Magnitude > 0.1 then
                crab:PivotTo(CFrame.new(pos, lookAt))
            else
                crab:PivotTo(CFrame.new(pos) * targetCFrame.Rotation)
            end
            task.wait()
        end

        if isActive and crab.Parent then
            crab:PivotTo(targetCFrame)
            crab:SetAttribute("IsRunning", false)
        end
    end)
end

-- ─── Movement routine — mirrors server movementSequence loop ─────────────────

local function doMovementRoutine(data)
    task.spawn(function()
        while getElapsed() < 31 and isActive do task.wait(0.1) end
        if not isActive then return end

        local crab           = data.Model
        local isMiddle       = data.Role == "Middle"
        local sideMultiplier = (data.StartCFrame.Position.X > MAP_CENTER_X) and -1 or 1
        local movementSeq    = isMiddle and {50, -90, 80} or {-50, 90, -80}
        local origRotation   = data.StartCFrame.Rotation
        local linePos        = data.StartCFrame.Position
        local CRAB_SPEED     = 20
        local ROUTINE_START  = 30
        local cumulativeTime = ROUTINE_START
        local timeSaved      = 0

        local collisionParams = OverlapParams.new()
        collisionParams.FilterType = Enum.RaycastFilterType.Exclude
        collisionParams.FilterDescendantsInstances = { crab }

        for i, xOffset in ipairs(movementSeq) do
            if not isActive or not crab.Parent then break end

            local segDist    = math.abs(xOffset)
            local remaining  = #movementSeq - i + 1
            local extra      = (timeSaved > 0 and remaining > 0)
                and (timeSaved / remaining) or 0
            if timeSaved > 0 then timeSaved -= extra end

            local moveDur        = segDist / CRAB_SPEED + extra
            local segStart       = cumulativeTime
            local segEnd         = segStart + moveDur
            local adjOffset      = xOffset * sideMultiplier
            local targetPos      = linePos + Vector3.new(adjOffset, 0, 0)
            local currentElapsed = getElapsed()

            if currentElapsed >= segEnd then
                linePos = targetPos
                crab:PivotTo(CFrame.new(linePos) * origRotation)
                cumulativeTime = segEnd
                continue
            end

            crab:SetAttribute("IsRunning", true)
            crab:SetAttribute("Dance", 0)

            local startPos    = linePos
            local lastSafePos = startPos
            local hitSomething = false
            local crabSize    = crab.PrimaryPart and crab.PrimaryPart.Size or Vector3.new(2,2,2)

            while isActive and crab.Parent do
                local t = getElapsed()
                if t >= segEnd then break end

                local alpha       = math.clamp((t - segStart) / moveDur, 0, 1)
                local currentPos  = startPos:Lerp(targetPos, alpha)
                local nextAlpha   = math.clamp(alpha + 0.05, 0, 1)
                local nextPos     = startPos:Lerp(targetPos, nextAlpha)
                local checkCF     = CFrame.new(nextPos) * origRotation

                local hits   = workspace:GetPartBoundsInBox(checkCF, crabSize * Vector3.new(1.2,1,1.2), collisionParams)
                local blocked = false
                for _, hit in ipairs(hits) do
                    if hit.CanCollide then blocked = true; break end
                end

                if blocked then
                    hitSomething = true
                    local moveDir       = (targetPos - startPos).Unit
                    local stoppedPos    = lastSafePos - moveDir * 5
                    local distFromStart = (stoppedPos - startPos):Dot(moveDir)
                    if distFromStart < 0 then stoppedPos = startPos end
                    local distTraveled  = (stoppedPos - startPos).Magnitude
                    local timeSkipped   = (segDist - distTraveled) / CRAB_SPEED
                    timeSaved += timeSkipped
                    linePos   = stoppedPos
                    crab:PivotTo(CFrame.new(linePos) * origRotation)
                    cumulativeTime = getElapsed()
                    break
                end

                lastSafePos = currentPos
                crab:PivotTo(CFrame.new(currentPos) * origRotation)
                task.wait()
            end

            if not hitSomething then
                linePos = targetPos
                crab:PivotTo(CFrame.new(linePos) * origRotation)
                while getElapsed() < segEnd and isActive do task.wait() end
                cumulativeTime = segEnd
            end
        end

        if crab and crab.Parent then
            crab:SetAttribute("IsRunning", false)
            -- Hand back to dance scheduler
            crab:SetAttribute("Dance", globalDanceIndex)
        end
    end)
end

-- ─── Spawn ground + wall crabs ───────────────────────────────────────────────

local function spawnGroundCrabs()
    -- 6 ground positions — 3 left of center, 3 right
    -- Offset 40 studs off-screen on X, walk to position
    local positions = {
        { x = MAP_CENTER_X - 60, z = 55,  role = "Side"   },
        { x = MAP_CENTER_X - 30, z = 55,  role = "Middle" },
        { x = MAP_CENTER_X,      z = 55,  role = "Middle" },
        { x = MAP_CENTER_X + 30, z = 55,  role = "Side"   },
        { x = MAP_CENTER_X + 60, z = 55,  role = "Side"   },
        { x = MAP_CENTER_X - 15, z = 70,  role = "Side"   },
    }

    for _, pos in ipairs(positions) do
        local targetCF = CFrame.new(stickToGround(Vector3.new(pos.x, 0, pos.z)))
        local offsetX  = (pos.x < MAP_CENTER_X) and -40 or 40
        local spawnCF  = CFrame.new(stickToGround(Vector3.new(pos.x + offsetX, 0, pos.z)))

        local crab = createCrab(spawnCF, "Ground")
        local crabTrove = scriptTrove:Extend()
        crabTrove:Add(crab)
        buildCrabAnims(crab, crabTrove)

        local data = {
            Model       = crab,
            Type        = "Ground",
            StartCFrame = targetCF,
            SpawnCFrame = spawnCF,
            Role        = pos.role,
            IsBusy      = false,
            wanderGen   = 0,
            Trove       = crabTrove,
        }
        table.insert(crabs, data)
        doGroundWalkIn(data)
        doMovementRoutine(data)
    end
end

local function spawnWallCrabs()
    -- Wall crabs sit static at their positions — no walk-in, no movement routine
    local positions = {
        { x = MAP_CENTER_X - 80, y = 25, z = 40 },
        { x = MAP_CENTER_X + 80, y = 25, z = 40 },
        { x = MAP_CENTER_X - 80, y = 45, z = 40 },
        { x = MAP_CENTER_X + 80, y = 45, z = 40 },
    }

    for _, pos in ipairs(positions) do
        local cf    = CFrame.new(pos.x, pos.y, pos.z)
        local crab  = createCrab(cf, "Wall")
        local crabTrove = scriptTrove:Extend()
        crabTrove:Add(crab)
        buildCrabAnims(crab, crabTrove)

        local data = {
            Model       = crab,
            Type        = "Wall",
            StartCFrame = cf,
            SpawnCFrame = cf,
            Role        = "Wall",
            IsBusy      = false,
            wanderGen   = 0,
            Trove       = crabTrove,
        }
        table.insert(crabs, data)
        crab:SetAttribute("Dance", 1)
    end
end

-- ─── Chase + attack ───────────────────────────────────────────────────────────

local function chaseAndAttack(crabData, targetAnimal: Model)
    local crab = crabData.Model
    if not crab or not crab.Parent then return end
    if crabData.IsBusy then return end

    crabData.IsBusy = true
    activeCrabs[crab] = true
    crab:SetAttribute("Dance", 0)
    crab:SetAttribute("IsRunning", true)

    local startPos = crab:GetPivot().Position

    scriptTrove:Add(task.spawn(function()
        local chaseStart = os.clock()
        local reached    = false

        while isActive and crab and crab.Parent
            and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart
        do
            if os.clock() - chaseStart > CHASE_TIMEOUT then break end

            local myPos  = crab:GetPivot().Position
            local tgtPos = targetAnimal.PrimaryPart.Position
            local delta  = tgtPos - myPos
            local dist   = delta.Magnitude

            if dist <= ATTACK_REACH_DIST then
                reached = true
                break
            end

            local dt     = task.wait()
            local flat   = Vector3.new(delta.X, 0, delta.Z)
            if flat.Magnitude < 1e-4 then continue end
            flat = flat.Unit
            local newPos = stickToGround(myPos + flat * math.min(CHASE_SPEED * dt, dist))
            crab:PivotTo(CFrame.new(newPos, newPos + flat))
        end

        crab:SetAttribute("IsRunning", false)

        if reached and targetAnimal and targetAnimal.Parent then
            -- Face the animal
            if crab.PrimaryPart and targetAnimal.PrimaryPart then
                local tPos = targetAnimal.PrimaryPart.Position
                local cPos = crab.PrimaryPart.Position
                crab:PivotTo(CFrame.new(cPos, Vector3.new(tPos.X, cPos.Y, tPos.Z)))
            end

            -- Attack animation + sound
            crab:SetAttribute("Attack", true)
            SoundController:PlaySound(
                ReplicatedStorage.Sounds.Events["Crab Rave"].Hit,
                crab.PrimaryPart and crab.PrimaryPart.Position or Vector3.zero
            )

            task.wait(ATTACK_WAIT)

            -- Give Claws trait
            if targetAnimal and targetAnimal.Parent then
                giveClaws(targetAnimal)
            end

            task.wait(POST_ATTACK_WAIT)
        end

        -- Return to start position
        if crab and crab.Parent then
            crab:SetAttribute("IsRunning", true)
            local returnDist = (startPos - crab:GetPivot().Position).Magnitude
            local maxReturnTime = math.max(5, returnDist / WANDER_SPEED + 2)
            local t0 = os.clock()

            while isActive and crab and crab.Parent do
                if os.clock() - t0 > maxReturnTime then break end
                local myPos = crab:GetPivot().Position
                local delta = startPos - myPos
                local dist  = delta.Magnitude
                if dist < 1 then break end
                local dt    = task.wait()
                local flat  = Vector3.new(delta.X, 0, delta.Z)
                if flat.Magnitude < 1e-4 then break end
                flat = flat.Unit
                local newPos = stickToGround(myPos + flat * math.min(WANDER_SPEED * dt, dist))
                crab:PivotTo(CFrame.new(newPos, newPos + flat))
            end

            crab:SetAttribute("IsRunning", false)
        end

        activeCrabs[crab] = nil
        crabData.IsBusy   = false

        -- Restore global dance
        if isActive and crab and crab.Parent then
            crab:SetAttribute("Dance", globalDanceIndex)
        end
    end))
end

-- ─── Wander ──────────────────────────────────────────────────────────────────

local function wander(crabData)
    local crab = crabData.Model
    if not crab or not crab.Parent then return end
    if crabData.IsBusy then return end

    activeCrabs[crab] = true
    crabData.IsBusy   = true
    crab:SetAttribute("Dance", 0)

    local startPos   = crab:GetPivot().Position
    local offset     = Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
    local targetPos  = stickToGround(startPos + offset)
    local dist       = (targetPos - startPos).Magnitude
    local maxTime    = math.max(3, dist / WANDER_SPEED + 2)

    crab:SetAttribute("IsRunning", true)

    scriptTrove:Add(task.spawn(function()
        local t0 = os.clock()
        while isActive and crab and crab.Parent do
            if os.clock() - t0 > maxTime then break end
            local myPos = crab:GetPivot().Position
            local delta = targetPos - myPos
            local d     = delta.Magnitude
            if d < 1 then break end
            local dt    = task.wait()
            local flat  = Vector3.new(delta.X, 0, delta.Z)
            if flat.Magnitude < 1e-4 then break end
            flat = flat.Unit
            local newPos = stickToGround(myPos + flat * math.min(WANDER_SPEED * dt, d))
            crab:PivotTo(CFrame.new(newPos, newPos + flat))
        end

        crab:SetAttribute("IsRunning", false)
        task.wait(math.random(10, 20) / 10)

        activeCrabs[crab] = nil
        crabData.IsBusy   = false

        if isActive and crab and crab.Parent then
            crab:SetAttribute("Dance", globalDanceIndex)
        end
    end))
end

-- ─── Main ────────────────────────────────────────────────────────────────────

local function main()
    -- Wait for asset templates
    local waitStart = os.clock()
    while (not groundTemplate or not wallTemplate) and os.clock() - waitStart < 10 do
        task.wait(0.1)
    end

    spawnGroundCrabs()
    spawnWallCrabs()
    startDanceScheduler()

    -- Attack tick — mirrors server attack loop, starts at t=46.5
    scriptTrove:Add(task.spawn(function()
        local gate = startedAt + 46.5 - workspace:GetServerTimeNow()
        if gate > 0 then task.wait(gate) end

        local currentAttackers = 0

        while isActive do
            task.wait(math.random(math.floor(TICK_MIN * 10), math.floor(TICK_MAX * 10)) / 10)
            if not isActive then break end
            if currentAttackers >= MAX_ATTACKERS then continue end

            pruneTargets()

            local available = {}
            for _, data in ipairs(crabs) do
                if data.Model and data.Model.Parent
                    and data.Type == "Ground"
                    and not data.IsBusy
                then
                    table.insert(available, data)
                end
            end
            if #available == 0 then continue end

            local candidates = {}
            for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                if animal.PrimaryPart
                    and not recentlyTargeted[animal.Name]
                    and not hasClaws(animal)
                    and CARPET_CHECK.isPointInCarpet(animal.PrimaryPart.Position)
                then
                    table.insert(candidates, animal)
                end
            end
            if #candidates == 0 then continue end

            local selected     = candidates[math.random(1, #candidates)]
            local selectedData = available[math.random(1, #available)]

            recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()
            currentAttackers += 1

            local origBusy = selectedData.IsBusy
            chaseAndAttack(selectedData, selected)

            -- Decrement when crab returns (poll)
            task.spawn(function()
                while selectedData.IsBusy do task.wait(0.5) end
                currentAttackers -= 1
            end)
        end
    end))

    -- Wander tick — mirrors server wander loop, starts at t=46.5
    scriptTrove:Add(task.spawn(function()
        local gate = startedAt + 46.5 - workspace:GetServerTimeNow()
        if gate > 0 then task.wait(gate) end

        local currentWanderers = 0

        while isActive do
            task.wait(WANDER_INTERVAL)
            if not isActive then break end
            if currentWanderers >= MAX_WANDERERS then continue end

            local available = {}
            for _, data in ipairs(crabs) do
                if data.Model and data.Model.Parent
                    and data.Type == "Ground"
                    and not data.IsBusy
                then
                    table.insert(available, data)
                end
            end
            if #available == 0 then continue end

            local openSlots = MAX_WANDERERS - currentWanderers
            local count     = math.min(math.random(1, 2), openSlots, #available)

            for i = 1, count do
                local idx  = math.random(1, #available)
                local data = available[idx]
                table.remove(available, idx)

                currentWanderers += 1
                wander(data)

                task.spawn(function()
                    while data.IsBusy do task.wait(0.5) end
                    currentWanderers -= 1
                end)
            end
        end
    end))

    -- Watchdog
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end

    isActive = false
    scriptTrove:Destroy()
    table.clear(crabs)
    table.clear(activeCrabs)
    table.clear(recentlyTargeted)
end

task.spawn(main)
