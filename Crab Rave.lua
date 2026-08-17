-- LocalScript: Crab Rave Client — zero remotes
-- Fix: GetObjects returns Folder, not Model — iterate children for mesh parts

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

local EVENT_NAME = "Crab Rave"

-- ─── Config ──────────────────────────────────────────────────────────────────

local GROUND_ASSET_ID   = "rbxassetid://109050002810374"
local WALL_ASSET_ID     = "rbxassetid://136326795890759"
local COOLDOWN          = 15
local TICK_MIN          = 1.5
local TICK_MAX          = 3.0
local MAX_ATTACKERS     = 2
local CHASE_SPEED       = 22
local WANDER_SPEED      = 20
local ATTACK_REACH_DIST = 10
local CHASE_TIMEOUT     = 30
local ATTACK_WAIT       = 1
local POST_ATTACK_WAIT  = 1
local WANDER_INTERVAL   = 1.0
local MAX_WANDERERS     = 5
local MAP_CENTER_X      = -410.697
local DANCE_SWITCH_MIN  = 10
local DANCE_SWITCH_MAX  = 15
local DANCE_PAUSE_MIN   = 1
local DANCE_PAUSE_MAX   = 3
local DANCE_LOCK_TIME   = 141

-- ─── Event wait ──────────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

local function getElapsed(): number
    return workspace:GetServerTimeNow() - startedAt
end

local scriptTrove      = Trove.new()
local crabs            = {}
local activeCrabs      = {}
local recentlyTargeted = {}
local isActive         = true
local globalDanceIndex = 0

-- ─── Asset load — GetObjects returns a Folder, children are the actual parts ──

local groundParts: { Instance } = {}
local wallParts:   { Instance } = {}

local function loadAssets()
    task.spawn(function()
        local objs = game:GetObjects(GROUND_ASSET_ID)
        for _, obj in ipairs(objs) do
            if obj:IsA("Folder") or obj:IsA("Model") then
                for _, child in ipairs(obj:GetDescendants()) do
                    if child:IsA("BasePart") or child:IsA("MeshPart") or child:IsA("SpecialMesh") then
                        table.insert(groundParts, obj)
                        break
                    end
                end
                -- obj itself is the usable root
                if #groundParts == 0 then
                    table.insert(groundParts, obj)
                end
                break
            elseif obj:IsA("BasePart") or obj:IsA("Model") then
                table.insert(groundParts, obj)
            end
        end
        groundParts = objs  -- store all roots, pick first valid per spawn
    end)
    task.spawn(function()
        local objs = game:GetObjects(WALL_ASSET_ID)
        wallParts = objs
    end)
end

loadAssets()

-- ─── Ground stick ─────────────────────────────────────────────────────────────

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
    for _, t in ipairs(traits) do if t == "Claws" then return end end
    table.insert(traits, "Claws")
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

local function pruneTargets()
    local now = workspace:GetServerTimeNow()
    for name, t in pairs(recentlyTargeted) do
        if now - t > COOLDOWN then recentlyTargeted[name] = nil end
    end
end

-- ─── Crab model — mesh cloned from asset folder children ─────────────────────

local EventScript = ReplicatedStorage.Controllers.EventController.Events["Crab Rave"]

local function cloneMeshFromAsset(assetObjs: { Instance }): (Instance?, BasePart?)
    -- GetObjects returns array of roots — could be Model, Folder, BasePart
    -- Walk until we find something with geometry
    for _, obj in ipairs(assetObjs) do
        if obj:IsA("Model") and obj.PrimaryPart then
            local clone = obj:Clone()
            return clone, clone.PrimaryPart
        elseif obj:IsA("Model") then
            -- Model without PrimaryPart set — find first BasePart
            local clone = obj:Clone()
            for _, desc in ipairs(clone:GetDescendants()) do
                if desc:IsA("BasePart") then
                    clone.PrimaryPart = desc
                    return clone, desc
                end
            end
        elseif obj:IsA("BasePart") then
            local clone = obj:Clone()
            return clone, clone
        elseif obj:IsA("Folder") then
            -- Folder wrapping a model — check children
            for _, child in ipairs(obj:GetChildren()) do
                if child:IsA("Model") then
                    local clone = child:Clone()
                    if not clone.PrimaryPart then
                        for _, desc in ipairs(clone:GetDescendants()) do
                            if desc:IsA("BasePart") then
                                clone.PrimaryPart = desc
                                break
                            end
                        end
                    end
                    return clone, clone.PrimaryPart
                elseif child:IsA("BasePart") then
                    local clone = child:Clone()
                    return clone, clone
                end
            end
        end
    end
    return nil, nil
end

local function createCrab(cf: CFrame, crabType: string): (Model, Animator?)
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

    local animator: Animator? = nil
    local assetObjs = crabType == "Wall" and wallParts or groundParts

    local mesh, meshPrimary = cloneMeshFromAsset(assetObjs)
    if mesh and meshPrimary then
        -- Strip old AnimationController
        local oldAC = mesh:FindFirstChildWhichIsA("AnimationController", true)
            or mesh:FindFirstChildWhichIsA("Humanoid", true)
        if oldAC then oldAC:Destroy() end

        -- Humanoid + Animator rig
        local humanoid = Instance.new("Humanoid")
        humanoid.Name                 = "AnimationController"
        humanoid.EvaluateStateMachine = false
        humanoid.DisplayDistanceType  = Enum.HumanoidDisplayDistanceType.None
        humanoid.PlatformStand        = true

        local animInst = Instance.new("Animator")
        animInst.Parent  = humanoid
        humanoid.Parent  = mesh
        animator         = animInst

        -- Weld mesh primary to invisible root
        local weld   = Instance.new("Weld")
        weld.Part0   = meshPrimary
        weld.Part1   = root
        weld.Parent  = meshPrimary

        mesh.Parent = model
    end

    model.Parent = workspace
    return model, animator
end

-- ─── Animation controller ─────────────────────────────────────────────────────

local function buildCrabAnims(rootModel: Model, animator: Animator, trove: typeof(Trove.new()))
    local function loadAnim(name: string): AnimationTrack?
        local anim = EventScript:FindFirstChild(name)
        if not anim then return nil end
        local track = animator:LoadAnimation(anim)
        trove:Add(function() track:Stop(0); track:Destroy() end)
        return track
    end

    local idleTrack   = loadAnim("Animation1")
    local walkTrack   = loadAnim("Animation4_Walk")
    local attackTrack = loadAnim("Animation4_Attack")
    local dance1      = loadAnim("Animation5")
    local dance2      = loadAnim("Animation6")
    local dance3      = loadAnim("Animation7")
    local dance4      = loadAnim("Animation8")

    local danceMap = { [1]=dance1, [2]=dance2, [3]=dance3, [4]=dance4 }

    if walkTrack   then walkTrack.Priority   = Enum.AnimationPriority.Action  end
    if attackTrack then attackTrack.Priority = Enum.AnimationPriority.Action4 end
    for _, t in pairs(danceMap) do
        if t then t.Priority = Enum.AnimationPriority.Action2 end
    end

    local currentDanceTrack: AnimationTrack? = nil

    if idleTrack then idleTrack:Play() end

    local gateDelay = startedAt + 7 - workspace:GetServerTimeNow()
    if gateDelay > 0 then
        trove:Add(task.delay(gateDelay, function()
            if idleTrack and idleTrack.IsPlaying then idleTrack:Stop() end
        end))
    else
        if idleTrack then idleTrack:Stop(0) end
    end

    trove:Add(rootModel:GetAttributeChangedSignal("IsRunning"):Connect(function()
        if rootModel:GetAttribute("IsRunning") then
            if walkTrack and not walkTrack.IsPlaying then walkTrack:Play() end
            if currentDanceTrack and currentDanceTrack.IsPlaying then currentDanceTrack:Stop() end
        else
            if walkTrack and walkTrack.IsPlaying then walkTrack:Stop() end
        end
    end))

    trove:Add(rootModel:GetAttributeChangedSignal("Dance"):Connect(function()
        local idx = rootModel:GetAttribute("Dance")
        if currentDanceTrack and currentDanceTrack.IsPlaying then
            currentDanceTrack:Stop()
            currentDanceTrack = nil
        end
        if idx and idx ~= 0 and danceMap[idx] then
            currentDanceTrack = danceMap[idx]
            currentDanceTrack:Play()
            local e = getElapsed()
            if currentDanceTrack.Length > 0 then
                currentDanceTrack.TimePosition = e % currentDanceTrack.Length
            end
        end
    end))

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

    local slowDelay = startedAt + 141 - workspace:GetServerTimeNow()
    if slowDelay > 0 then
        trove:Add(task.delay(slowDelay, function()
            local lerpDur = 20
            local t0 = os.clock()
            trove:Add(RunService.PreSimulation:Connect(function()
                local alpha = math.clamp((os.clock() - t0) / lerpDur, 0, 1)
                local speed = math.lerp(1, 0.1, alpha)
                for _, track in pairs(danceMap) do
                    if track and track.IsPlaying then track:AdjustSpeed(speed) end
                end
            end))
        end))
    end
end

-- ─── Dance scheduler ─────────────────────────────────────────────────────────

local function applyDance(idx: number)
    globalDanceIndex = idx
    for _, data in ipairs(crabs) do
        if data.Model and data.Model.Parent and not activeCrabs[data.Model] then
            data.Model:SetAttribute("Dance", idx)
        end
    end
end

local function startDanceScheduler()
    scriptTrove:Add(task.spawn(function()
        local gate = startedAt + 9 - workspace:GetServerTimeNow()
        if gate > 0 then task.wait(gate) end

        while isActive do
            if getElapsed() >= DANCE_LOCK_TIME then
                applyDance(4)
                break
            end
            applyDance(math.random(1, 4))
            task.wait(math.random(DANCE_SWITCH_MIN, DANCE_SWITCH_MAX))
            if not isActive then break end
            applyDance(0)
            task.wait(math.random(DANCE_PAUSE_MIN, DANCE_PAUSE_MAX))
        end
    end))
end

-- ─── Ground walk-in ──────────────────────────────────────────────────────────

local function doGroundWalkIn(data)
    task.spawn(function()
        local walkStart = 7
        local walkDur   = 2
        local walkEnd   = walkStart + walkDur

        local crab       = data.Model
        local spawnCF    = data.SpawnCFrame
        local targetCF   = data.StartCFrame

        if getElapsed() >= walkEnd then
            if crab and crab.PrimaryPart then
                crab:PivotTo(targetCF)
                crab:SetAttribute("IsRunning", false)
            end
            return
        end

        while getElapsed() < walkStart and isActive do task.wait(0.1) end
        if not isActive or not crab or not crab.Parent then return end

        crab:SetAttribute("IsRunning", true)
        local startPos = spawnCF.Position
        local endPos   = targetCF.Position

        while isActive and crab.Parent do
            local t = getElapsed()
            if t >= walkEnd then break end
            local alpha  = math.clamp((t - walkStart) / walkDur, 0, 1)
            local pos    = startPos:Lerp(endPos, alpha)
            local lookAt = Vector3.new(endPos.X, pos.Y, endPos.Z)
            if (lookAt - pos).Magnitude > 0.1 then
                crab:PivotTo(CFrame.new(pos, lookAt))
            else
                crab:PivotTo(CFrame.new(pos) * targetCF.Rotation)
            end
            task.wait()
        end

        if isActive and crab.Parent then
            crab:PivotTo(targetCF)
            crab:SetAttribute("IsRunning", false)
        end
    end)
end

-- ─── Movement routine ────────────────────────────────────────────────────────

local function doMovementRoutine(data)
    task.spawn(function()
        while getElapsed() < 31 and isActive do task.wait(0.1) end
        if not isActive then return end

        local crab        = data.Model
        local isMiddle    = data.Role == "Middle"
        local sideMulti   = (data.StartCFrame.Position.X > MAP_CENTER_X) and -1 or 1
        local moveSeq     = isMiddle and {50, -90, 80} or {-50, 90, -80}
        local origRot     = data.StartCFrame.Rotation
        local linePos     = data.StartCFrame.Position
        local CRAB_SPEED  = 20
        local cumTime     = 30
        local timeSaved   = 0

        local colParams = OverlapParams.new()
        colParams.FilterType = Enum.RaycastFilterType.Exclude
        colParams.FilterDescendantsInstances = { crab }

        for i, xOffset in ipairs(moveSeq) do
            if not isActive or not crab.Parent then break end

            local segDist   = math.abs(xOffset)
            local remaining = #moveSeq - i + 1
            local extra     = (timeSaved > 0 and remaining > 0) and (timeSaved / remaining) or 0
            if timeSaved > 0 then timeSaved -= extra end

            local moveDur   = segDist / CRAB_SPEED + extra
            local segStart  = cumTime
            local segEnd    = segStart + moveDur
            local adjOffset = xOffset * sideMulti
            local targetPos = linePos + Vector3.new(adjOffset, 0, 0)

            if getElapsed() >= segEnd then
                linePos = targetPos
                crab:PivotTo(CFrame.new(linePos) * origRot)
                cumTime = segEnd
                continue
            end

            crab:SetAttribute("IsRunning", true)
            crab:SetAttribute("Dance", 0)

            local startPos     = linePos
            local lastSafePos  = startPos
            local hitSomething = false
            local crabSize     = crab.PrimaryPart and crab.PrimaryPart.Size or Vector3.new(2,2,2)

            while isActive and crab.Parent do
                local t = getElapsed()
                if t >= segEnd then break end
                local alpha      = math.clamp((t - segStart) / moveDur, 0, 1)
                local currentPos = startPos:Lerp(targetPos, alpha)
                local nextAlpha  = math.clamp(alpha + 0.05, 0, 1)
                local nextPos    = startPos:Lerp(targetPos, nextAlpha)
                local checkCF    = CFrame.new(nextPos) * origRot
                local hits       = workspace:GetPartBoundsInBox(checkCF, crabSize * Vector3.new(1.2,1,1.2), colParams)
                local blocked    = false
                for _, hit in ipairs(hits) do
                    if hit.CanCollide then blocked = true; break end
                end
                if blocked then
                    hitSomething = true
                    local moveDir    = (targetPos - startPos).Unit
                    local stoppedPos = lastSafePos - moveDir * 5
                    if (stoppedPos - startPos):Dot(moveDir) < 0 then stoppedPos = startPos end
                    timeSaved += (segDist - (stoppedPos - startPos).Magnitude) / CRAB_SPEED
                    linePos = stoppedPos
                    crab:PivotTo(CFrame.new(linePos) * origRot)
                    cumTime = getElapsed()
                    break
                end
                lastSafePos = currentPos
                crab:PivotTo(CFrame.new(currentPos) * origRot)
                task.wait()
            end

            if not hitSomething then
                linePos = targetPos
                crab:PivotTo(CFrame.new(linePos) * origRot)
                while getElapsed() < segEnd and isActive do task.wait() end
                cumTime = segEnd
            end
        end

        if crab and crab.Parent then
            crab:SetAttribute("IsRunning", false)
            crab:SetAttribute("Dance", globalDanceIndex)
        end
    end)
end

-- ─── Spawn ───────────────────────────────────────────────────────────────────

local function spawnGroundCrabs()
    local positions = {
        { x = MAP_CENTER_X - 60, z = 55, role = "Side"   },
        { x = MAP_CENTER_X - 30, z = 55, role = "Middle" },
        { x = MAP_CENTER_X,      z = 55, role = "Middle" },
        { x = MAP_CENTER_X + 30, z = 55, role = "Side"   },
        { x = MAP_CENTER_X + 60, z = 55, role = "Side"   },
        { x = MAP_CENTER_X - 15, z = 70, role = "Side"   },
    }

    for _, pos in ipairs(positions) do
        local targetCF = CFrame.new(stickToGround(Vector3.new(pos.x, 0, pos.z)))
        local offsetX  = (pos.x < MAP_CENTER_X) and -40 or 40
        local spawnCF  = CFrame.new(stickToGround(Vector3.new(pos.x + offsetX, 0, pos.z)))

        local crab, animator = createCrab(spawnCF, "Ground")
        local crabTrove = scriptTrove:Extend()
        crabTrove:Add(crab)
        if animator then buildCrabAnims(crab, animator, crabTrove) end

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
    local positions = {
        { x = MAP_CENTER_X - 80, y = 25, z = 40 },
        { x = MAP_CENTER_X + 80, y = 25, z = 40 },
        { x = MAP_CENTER_X - 80, y = 45, z = 40 },
        { x = MAP_CENTER_X + 80, y = 45, z = 40 },
    }

    for _, pos in ipairs(positions) do
        local cf   = CFrame.new(pos.x, pos.y, pos.z)
        local crab, animator = createCrab(cf, "Wall")
        local crabTrove = scriptTrove:Extend()
        crabTrove:Add(crab)
        if animator then buildCrabAnims(crab, animator, crabTrove) end

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
    if not crab or not crab.Parent or crabData.IsBusy then return end

    crabData.IsBusy    = true
    activeCrabs[crab]  = true
    crab:SetAttribute("Dance",     0)
    crab:SetAttribute("IsRunning", true)

    local startPos = crab:GetPivot().Position

    scriptTrove:Add(task.spawn(function()
        local chaseStart = os.clock()
        local reached    = false

        while isActive and crab and crab.Parent
            and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart
        do
            if os.clock() - chaseStart > CHASE_TIMEOUT then break end
            local myPos = crab:GetPivot().Position
            local tgtPos = targetAnimal.PrimaryPart.Position
            local delta  = tgtPos - myPos
            if delta.Magnitude <= ATTACK_REACH_DIST then reached = true; break end
            local dt   = task.wait()
            local flat = Vector3.new(delta.X, 0, delta.Z)
            if flat.Magnitude < 1e-4 then continue end
            flat = flat.Unit
            local newPos = stickToGround(myPos + flat * math.min(CHASE_SPEED * dt, delta.Magnitude))
            crab:PivotTo(CFrame.new(newPos, newPos + flat))
        end

        crab:SetAttribute("IsRunning", false)

        if reached and targetAnimal and targetAnimal.Parent then
            if crab.PrimaryPart and targetAnimal.PrimaryPart then
                local tPos = targetAnimal.PrimaryPart.Position
                local cPos = crab.PrimaryPart.Position
                crab:PivotTo(CFrame.new(cPos, Vector3.new(tPos.X, cPos.Y, tPos.Z)))
            end
            crab:SetAttribute("Attack", true)
            SoundController:PlaySound(
                ReplicatedStorage.Sounds.Events["Crab Rave"].Hit,
                crab.PrimaryPart and crab.PrimaryPart.Position or Vector3.zero
            )
            task.wait(ATTACK_WAIT)
            if targetAnimal and targetAnimal.Parent then giveClaws(targetAnimal) end
            task.wait(POST_ATTACK_WAIT)
        end

        -- Return
        if crab and crab.Parent then
            crab:SetAttribute("IsRunning", true)
            local returnDist = (startPos - crab:GetPivot().Position).Magnitude
            local maxReturn  = math.max(5, returnDist / WANDER_SPEED + 2)
            local t0 = os.clock()
            while isActive and crab and crab.Parent do
                if os.clock() - t0 > maxReturn then break end
                local myPos = crab:GetPivot().Position
                local delta = startPos - myPos
                if delta.Magnitude < 1 then break end
                local dt   = task.wait()
                local flat = Vector3.new(delta.X, 0, delta.Z)
                if flat.Magnitude < 1e-4 then break end
                flat = flat.Unit
                local newPos = stickToGround(myPos + flat * math.min(WANDER_SPEED * dt, delta.Magnitude))
                crab:PivotTo(CFrame.new(newPos, newPos + flat))
            end
            crab:SetAttribute("IsRunning", false)
        end

        activeCrabs[crab]  = nil
        crabData.IsBusy    = false
        if isActive and crab and crab.Parent then
            crab:SetAttribute("Dance", globalDanceIndex)
        end
    end))
end

-- ─── Wander ──────────────────────────────────────────────────────────────────

local function wander(crabData)
    local crab = crabData.Model
    if not crab or not crab.Parent or crabData.IsBusy then return end

    crabData.IsBusy   = true
    activeCrabs[crab] = true
    crab:SetAttribute("Dance", 0)

    local startPos  = crab:GetPivot().Position
    local offset    = Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
    local targetPos = stickToGround(startPos + offset)
    local dist      = (targetPos - startPos).Magnitude
    local maxTime   = math.max(3, dist / WANDER_SPEED + 2)

    crab:SetAttribute("IsRunning", true)

    scriptTrove:Add(task.spawn(function()
        local t0 = os.clock()
        while isActive and crab and crab.Parent do
            if os.clock() - t0 > maxTime then break end
            local myPos = crab:GetPivot().Position
            local delta = targetPos - myPos
            if delta.Magnitude < 1 then break end
            local dt   = task.wait()
            local flat = Vector3.new(delta.X, 0, delta.Z)
            if flat.Magnitude < 1e-4 then break end
            flat = flat.Unit
            local newPos = stickToGround(myPos + flat * math.min(WANDER_SPEED * dt, delta.Magnitude))
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
    local waitStart = os.clock()
    while (#groundParts == 0 or #wallParts == 0) and os.clock() - waitStart < 10 do
        task.wait(0.1)
    end

    spawnGroundCrabs()
    spawnWallCrabs()
    startDanceScheduler()

    -- Attack tick
    scriptTrove:Add(task.spawn(function()
        local gate = startedAt + 46.5 - workspace:GetServerTimeNow()
        if gate > 0 then task.wait(gate) end

        local currentAttackers = 0
        while isActive do
            task.wait(math.random(math.floor(TICK_MIN*10), math.floor(TICK_MAX*10)) / 10)
            if not isActive then break end
            if currentAttackers >= MAX_ATTACKERS then continue end

            pruneTargets()

            local available = {}
            for _, data in ipairs(crabs) do
                if data.Model and data.Model.Parent and data.Type == "Ground" and not data.IsBusy then
                    table.insert(available, data)
                end
            end
            if #available == 0 then continue end

            local candidates = {}
            for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                if animal.PrimaryPart
                    and not recentlyTargeted[animal.Name]
                    and not hasClaws(animal)
                    and SharedEventUtils.isPointInCarpet(animal.PrimaryPart.Position)
                then
                    table.insert(candidates, animal)
                end
            end
            if #candidates == 0 then continue end

            local selected     = candidates[math.random(1, #candidates)]
            local selectedData = available[math.random(1, #available)]
            recentlyTargeted[selected.Name] = workspace:GetServerTimeNow()
            currentAttackers += 1
            chaseAndAttack(selectedData, selected)
            task.spawn(function()
                while selectedData.IsBusy do task.wait(0.5) end
                currentAttackers -= 1
            end)
        end
    end))

    -- Wander tick
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
                if data.Model and data.Model.Parent and data.Type == "Ground" and not data.IsBusy then
                    table.insert(available, data)
                end
            end
            if #available == 0 then continue end

            local count = math.min(math.random(1,2), MAX_WANDERERS - currentWanderers, #available)
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

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end

    isActive = false
    scriptTrove:Destroy()
    table.clear(crabs)
    table.clear(activeCrabs)
    table.clear(recentlyTargeted)
end

task.spawn(main)
