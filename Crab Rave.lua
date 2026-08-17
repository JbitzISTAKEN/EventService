-- LocalScript: Crab Rave Client — zero remotes
-- Fix 1: double crab — mesh PrimaryPart weld was creating a ghost root visual
-- Fix 2: assertion — animator loaded before Humanoid settled, wrapped in pcall + wait
-- Fix 3: wall crabs skip stickToGround entirely, use CFrame direct
-- Movement: NpcPathfinding module wired in for chase + moveTo

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)
local NpcPathfinding   = require(game:GetService("ServerScriptService").Components.NpcPathfinding)

local EVENT_NAME  = "Crab Rave"
local EventScript = ReplicatedStorage.Controllers.EventController.Events["Crab Rave"]

-- ─── Config ──────────────────────────────────────────────────────────────────

local GROUND_ASSET_ID   = "rbxassetid://109050002810374"
local WALL_ASSET_ID     = "rbxassetid://136326795890759"
local MAP_CENTER_X      = -410.697
local COOLDOWN          = 15
local MAX_ATTACKERS     = 2
local MAX_WANDERERS     = 5
local CHASE_SPEED       = 22
local WANDER_SPEED      = 20
local ATTACK_REACH_DIST = 10
local CHASE_TIMEOUT     = 30
local ATTACK_WAIT       = 1
local POST_ATTACK_WAIT  = 1
local WANDER_INTERVAL   = 1.0
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

-- ─── Asset folders ───────────────────────────────────────────────────────────

local groundFolder: Folder? = nil
local wallFolder:   Folder? = nil

task.spawn(function()
    for _, obj in ipairs(game:GetObjects(GROUND_ASSET_ID)) do
        if obj:IsA("Folder") then groundFolder = obj; break end
    end
end)
task.spawn(function()
    for _, obj in ipairs(game:GetObjects(WALL_ASSET_ID)) do
        if obj:IsA("Folder") then wallFolder = obj; break end
    end
end)

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

-- ─── Crab model ──────────────────────────────────────────────────────────────
-- ONE model, ONE root part, mesh welded to root.
-- Mesh PrimaryPart is set to nil after weld — kills the ghost double visual.

local function createCrab(cf: CFrame, crabType: string): (Model, Animator?)
    local model = Instance.new("Model")
    model.Name  = "Crab"

    -- Invisible anchor — this is the ONLY part that moves
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

    local template = EventScript:FindFirstChild("Crab")
    if template then
        local mesh = template:Clone()

        -- Strip any existing rig from the template
        for _, child in ipairs(mesh:GetChildren()) do
            if child:IsA("Humanoid") or child:IsA("AnimationController")
                or child.Name == "AnimationController"
            then
                child:Destroy()
            end
        end

        -- Find the mesh's visual root part for welding
        local meshRoot = mesh.PrimaryPart
        if not meshRoot then
            for _, desc in ipairs(mesh:GetDescendants()) do
                if desc:IsA("BasePart") then
                    meshRoot = desc
                    break
                end
            end
        end

        if meshRoot then
            -- Weld visual root to invisible anchor
            local weld   = Instance.new("Weld")
            weld.Part0   = meshRoot
            weld.Part1   = root
            weld.C1      = CFrame.new(0, 3.6, 0)
            weld.Parent  = root  -- parent to root, not mesh, so mesh clone is clean

            -- CRITICAL: clear PrimaryPart on mesh so PivotTo on the parent model
            -- only moves the invisible root — not the mesh independently.
            -- This is what caused the double-crab: two parts both responding to pivot.
            mesh.PrimaryPart = nil
        end

        -- Humanoid + Animator — parented BEFORE mesh so it exists when mesh lands
        local humanoid = Instance.new("Humanoid")
        humanoid.Name                 = "AnimationController"
        humanoid.EvaluateStateMachine = false
        humanoid.DisplayDistanceType  = Enum.HumanoidDisplayDistanceType.None
        humanoid.PlatformStand        = true

        local animInst  = Instance.new("Animator")
        animInst.Parent = humanoid
        animator        = animInst

        humanoid.Parent = model   -- on model, not mesh — animator scope is the model
        mesh.Parent     = model
    end

    model.Parent = workspace
    return model, animator
end

-- ─── Animation state machine ──────────────────────────────────────────────────
-- Assertion fix: LoadAnimation wrapped in task.defer so Humanoid is fully
-- settled in the data model before the call fires.

local function buildCrabAnims(rootModel: Model, animator: Animator, trove: typeof(Trove.new()))
    -- Defer one frame — kills the assertion that fired when animator
    -- was accessed before the Humanoid finished parenting
    task.defer(function()
        if not rootModel or not rootModel.Parent then return end

        local function load(name: string): AnimationTrack?
            local anim = EventScript:FindFirstChild(name)
            if not anim then return nil end
            local ok, track = pcall(function()
                return animator:LoadAnimation(anim)
            end)
            if not ok or not track then return nil end
            trove:Add(function()
                if track.IsPlaying then track:Stop(0) end
                track:Destroy()
            end)
            return track
        end

        local anim1       = load("Animation1")
        local anim2       = load("Animation2")
        local walkTrack   = load("Animation4_Walk")
        local attackTrack = load("Animation4_Attack")
        local dance1      = load("Animation5")
        local dance2      = load("Animation6")
        local dance3      = load("Animation7")
        local dance4      = load("Animation8")

        local danceMap = { [1]=dance1, [2]=dance2, [3]=dance3, [4]=dance4 }

        if walkTrack   then walkTrack.Priority   = Enum.AnimationPriority.Action  end
        if attackTrack then attackTrack.Priority = Enum.AnimationPriority.Action4 end
        for _, t in pairs(danceMap) do
            if t then t.Priority = Enum.AnimationPriority.Action2 end
        end

        local currentDanceTrack: AnimationTrack? = nil

        -- Spawn idle
        if anim1 then anim1:Play() end

        -- t=7: swap to anim2 (walk-in)
        trove:Add(task.delay(math.max(0, startedAt + 7 - workspace:GetServerTimeNow()), function()
            if not rootModel or not rootModel.Parent then return end
            if anim1 and anim1.IsPlaying then anim1:Stop() end
            if anim2 then anim2:Play() end
        end))

        -- t=31: anim2 done, walk track takes over via IsRunning
        trove:Add(task.delay(math.max(0, startedAt + 31 - workspace:GetServerTimeNow()), function()
            if not rootModel or not rootModel.Parent then return end
            if anim2 and anim2.IsPlaying then anim2:Stop() end
        end))

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

        -- Dance attr → dance tracks, synced to elapsed
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

        -- Attack → one-shot
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

        -- Dance speed slowdown t=141→161
        local delay141 = startedAt + 141 - workspace:GetServerTimeNow()
        if delay141 > 0 then
            trove:Add(task.delay(delay141, function()
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
    end)
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
            if getElapsed() >= DANCE_LOCK_TIME then applyDance(4); break end
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
        local WALK_START = 7
        local WALK_DUR   = 2
        local WALK_END   = WALK_START + WALK_DUR
        local crab       = data.Model
        local spawnCF    = data.SpawnCFrame
        local targetCF   = data.StartCFrame

        if getElapsed() >= WALK_END then
            if crab and crab.PrimaryPart then crab:PivotTo(targetCF) end
            crab:SetAttribute("IsRunning", false)
            return
        end

        while getElapsed() < WALK_START and isActive do task.wait(0.1) end
        if not isActive or not crab or not crab.Parent then return end

        crab:SetAttribute("IsRunning", true)
        local startPos = spawnCF.Position
        local endPos   = targetCF.Position

        while isActive and crab.Parent do
            local t = getElapsed()
            if t >= WALK_END then break end
            local alpha  = math.clamp((t - WALK_START) / WALK_DUR, 0, 1)
            local pos    = startPos:Lerp(endPos, alpha)
            local lookAt = Vector3.new(endPos.X, pos.Y, endPos.Z)
            crab:PivotTo(
                (lookAt - pos).Magnitude > 0.1
                and CFrame.new(pos, lookAt)
                or  CFrame.new(pos) * targetCF.Rotation
            )
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

        local crab      = data.Model
        local isMiddle  = data.Role == "Middle"
        local sideMulti = (data.StartCFrame.Position.X > MAP_CENTER_X) and -1 or 1
        local moveSeq   = isMiddle and {50, -90, 80} or {-50, 90, -80}
        local origRot   = data.StartCFrame.Rotation
        local linePos   = data.StartCFrame.Position
        local SPEED     = 20
        local cumTime   = 30
        local timeSaved = 0

        local colParams = OverlapParams.new()
        colParams.FilterType = Enum.RaycastFilterType.Exclude
        colParams.FilterDescendantsInstances = { crab }

        for i, xOffset in ipairs(moveSeq) do
            if not isActive or not crab.Parent then break end

            local segDist   = math.abs(xOffset)
            local remaining = #moveSeq - i + 1
            local extra     = (timeSaved > 0 and remaining > 0) and (timeSaved / remaining) or 0
            if timeSaved > 0 then timeSaved -= extra end

            local moveDur   = segDist / SPEED + extra
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
            crab:SetAttribute("Dance",     0)

            local startPos     = linePos
            local lastSafePos  = startPos
            local hitSomething = false
            local crabSize     = crab.PrimaryPart and crab.PrimaryPart.Size or Vector3.new(2,2,2)

            while isActive and crab.Parent do
                local t = getElapsed()
                if t >= segEnd then break end
                local alpha      = math.clamp((t - segStart) / moveDur, 0, 1)
                local currentPos = startPos:Lerp(targetPos, alpha)
                local nextPos    = startPos:Lerp(targetPos, math.clamp(alpha + 0.05, 0, 1))
                local hits       = workspace:GetPartBoundsInBox(
                    CFrame.new(nextPos) * origRot,
                    crabSize * Vector3.new(1.2, 1, 1.2),
                    colParams
                )
                local blocked = false
                for _, hit in ipairs(hits) do
                    if hit.CanCollide then blocked = true; break end
                end
                if blocked then
                    hitSomething = true
                    local moveDir    = (targetPos - startPos).Unit
                    local stoppedPos = lastSafePos - moveDir * 5
                    if (stoppedPos - startPos):Dot(moveDir) < 0 then stoppedPos = startPos end
                    timeSaved += (segDist - (stoppedPos - startPos).Magnitude) / SPEED
                    linePos    = stoppedPos
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
            crab:SetAttribute("Dance",     globalDanceIndex)
        end
    end)
end

-- ─── Spawn ───────────────────────────────────────────────────────────────────

local function spawnGroundCrabs()
    if not groundFolder then warn("[CrabRave] groundFolder nil"); return end

    for _, part in ipairs(groundFolder:GetChildren()) do
        if not part:IsA("BasePart") then continue end
        if part.Name ~= "Position" and part.Name ~= "PositionMiddle" then continue end

        local role     = (part.Name == "PositionMiddle") and "Middle" or "Side"
        local targetCF = part.CFrame
        local offsetX  = (targetCF.Position.X < MAP_CENTER_X) and -40 or 40
        local spawnCF  = CFrame.new(targetCF.Position + Vector3.new(offsetX, 0, 0)) * targetCF.Rotation

        local crab, animator = createCrab(spawnCF, "Ground")
        local crabTrove = scriptTrove:Extend()
        crabTrove:Add(crab)
        if animator then buildCrabAnims(crab, animator, crabTrove) end

        local data = {
            Model       = crab,
            Type        = "Ground",
            StartCFrame = targetCF,
            SpawnCFrame = spawnCF,
            Role        = role,
            IsBusy      = false,
            Trove       = crabTrove,
        }
        table.insert(crabs, data)
        doGroundWalkIn(data)
        doMovementRoutine(data)
    end
end

local function spawnWallCrabs()
    if not wallFolder then warn("[CrabRave] wallFolder nil"); return end

    for _, part in ipairs(wallFolder:GetChildren()) do
        if not part:IsA("BasePart") or part.Name ~= "Position" then continue end

        -- Wall crabs: use exact CFrame from Position part, no ground raycast
        local cf   = part.CFrame
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
            Trove       = crabTrove,
        }
        table.insert(crabs, data)
        crab:SetAttribute("Dance", 1)
    end
end

-- ─── Chase + attack — NpcPathfinding.chase for ground movement ───────────────

local function chaseAndAttack(crabData, targetAnimal: Model)
    local crab = crabData.Model
    if not crab or not crab.Parent or crabData.IsBusy then return end

    crabData.IsBusy   = true
    activeCrabs[crab] = true
    crab:SetAttribute("Dance",     0)
    crab:SetAttribute("IsRunning", true)

    local startPos = crab:GetPivot().Position

    scriptTrove:Add(task.spawn(function()
        -- Chase using NpcPathfinding — same as server CrabRave.OnStart chase block
        NpcPathfinding.chase(
            crab,
            function()
                if targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart then
                    return targetAnimal.PrimaryPart.Position
                end
                return nil
            end,
            CHASE_SPEED,
            ATTACK_REACH_DIST,
            CHASE_TIMEOUT,
            { shouldStop = function() return not isActive end }
        )

        crab:SetAttribute("IsRunning", false)

        -- Face target
        if crab.PrimaryPart and targetAnimal and targetAnimal.Parent and targetAnimal.PrimaryPart then
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

        -- Return using NpcPathfinding.moveTo
        if crab and crab.Parent then
            crab:SetAttribute("IsRunning", true)
            local returnDist = (startPos - crab:GetPivot().Position).Magnitude
            NpcPathfinding.moveTo(crab, startPos, WANDER_SPEED, {
                maxTime  = math.max(5, returnDist / WANDER_SPEED + 2),
                shouldStop = function() return not isActive end,
            })
            crab:SetAttribute("IsRunning", false)
        end

        activeCrabs[crab] = nil
        crabData.IsBusy   = false
        if isActive and crab and crab.Parent then
            crab:SetAttribute("Dance", globalDanceIndex)
        end
    end))
end

-- ─── Wander — NpcPathfinding.moveTo ──────────────────────────────────────────

local function wander(crabData)
    local crab = crabData.Model
    if not crab or not crab.Parent or crabData.IsBusy then return end

    crabData.IsBusy   = true
    activeCrabs[crab] = true
    crab:SetAttribute("Dance",     0)
    crab:SetAttribute("IsRunning", true)

    local startPos  = crab:GetPivot().Position
    local offset    = Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
    local targetPos = NpcPathfinding.stickToGround(startPos + offset)
    local dist      = (targetPos - startPos).Magnitude

    scriptTrove:Add(task.spawn(function()
        NpcPathfinding.moveTo(crab, targetPos, WANDER_SPEED, {
            maxTime    = math.max(3, dist / WANDER_SPEED + 2),
            shouldStop = function() return not isActive end,
        })
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
    local t0 = os.clock()
    while (not groundFolder or not wallFolder) and os.clock() - t0 < 10 do
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
            task.wait(math.random(15, 30) / 10)
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
            if not isActive or currentWanderers >= MAX_WANDERERS then continue end

            local available = {}
            for _, data in ipairs(crabs) do
                if data.Model and data.Model.Parent and data.Type == "Ground" and not data.IsBusy then
                    table.insert(available, data)
                end
            end
            if #available == 0 then continue end

            local count = math.min(math.random(1, 2), MAX_WANDERERS - currentWanderers, #available)
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
