local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage.Packages.Trove)
local Observers        = require(ReplicatedStorage.Packages.Observers)
local Shake            = require(ReplicatedStorage.Packages.Shake)
local FFlags           = require(ReplicatedStorage.Packages.FFlags)
local VFX              = require(ReplicatedStorage.Shared.VFX)
local MathUtils        = require(ReplicatedStorage.Utils.MathUtils)
local ShakePresets     = require(ReplicatedStorage.Shared.ShakePresets)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local EffectController = require(ReplicatedStorage.Controllers.EffectController)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ServerData       = require(ReplicatedStorage.Datas.ServerData)

local EVENT_NAME  = "Bombardiro Crocodilo"
local EventAssets = ReplicatedStorage.Controllers.EventController.Events[EVENT_NAME]
local SvininaAsset   = EventAssets["Svinina Bombardino"]
local CrocodiloAsset = EventAssets["Bombardiro Crocodilo"]
local ExplosionAsset = EventAssets["ExplosionBoom"]
local Sounds         = ReplicatedStorage.Sounds.Events[EVENT_NAME]

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local startedAt = EventController:GetActiveEventData(EVENT_NAME).startedAt

-- ─── Shake ────────────────────────────────────────────────────────────────────

local shakeBase = Shake.new()
shakeBase.Amplitude         = 4.5
shakeBase.Frequency         = 0.05
shakeBase.FadeInTime        = 0
shakeBase.FadeOutTime       = 0.6
shakeBase.PositionInfluence = Vector3.new(0.5, 0.5, 0.5)
shakeBase.RotationInfluence = Vector3.new(2.5, 0.5, 0.5)

-- ─── State ────────────────────────────────────────────────────────────────────

local trove       = Trove.new()
local planeModels = {} -- [plane.Name] = Crocodilo model parented to plane
local activePlanes = {} -- ordered list for BulkMoveTo

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function shakeCameraBasedOnProximity(pos: Vector3)
    local mag = (workspace.CurrentCamera.CFrame.Position - pos).Magnitude
    if mag > 300 then return end
    local s  = shakeBase:Clone()
    local v2 = (1 - mag / 300 * 0.5) ^ 2
    s.Amplitude         = s.Amplitude         * v2
    s.RotationInfluence = s.RotationInfluence * v2
    ShakePresets.BindShakeToCamera(s)
    s:Start()
end

local function hasExplosive(animal: Model): boolean
    local json = animal:GetAttribute("Traits")
    if not json then return false end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return false end
    for _, t in ipairs(decoded) do
        if t == "Explosive" then return true end
    end
    return false
end

local function playExplosion(pos: Vector3)
    local explosion = ExplosionAsset:Clone()
    explosion.CFrame = CFrame.new(pos)
    explosion.Parent = workspace
    VFX.emit(explosion)
    task.delay(5, function() explosion:Destroy() end)

    local hitSound = Sounds:FindFirstChild("BombHit")
    if hitSound then
        SoundController:PlaySound(hitSound, pos, false)
    end

    shakeCameraBasedOnProximity(pos)
end

-- ─── BulkMoveTo sync — croco model follows plane hitbox every PreRender ───────

trove:Add(RunService.PreRender:Connect(function()
    debug.profilebegin("Bombardiro Crocodilo:BulkMoveTo")
    local parts  = {}
    local frames = {}
    for _, plane in ipairs(activePlanes) do
        local model = planeModels[plane.Name]
        if plane.Parent and model and model.Parent then
            table.insert(parts,  model.PrimaryPart)
            table.insert(frames, plane.CFrame)
        end
    end
    if #parts > 0 then
        workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
    end
    debug.profileend()
end))

-- ─── BombardiroPlane observer — mirrors original local initGatitoObserver ─────

trove:Add(Observers.observeTag("BombardiroPlane", function(plane)
    local planeTrove = trove:Extend()

    -- Clone Crocodilo model, anchor it, hide Svinina children for 5s
    local croco = CrocodiloAsset:Clone()
    croco.PrimaryPart.Anchored = true

    for _, child in croco["Svinina Bombardino"]:GetChildren() do
        if child.Name ~= "RootPart" then
            child.Transparency = 1
        end
    end

    -- Match original FFlags optimisation path from decompiled local
    if FFlags:GetInstant("Optimisation.HumanoidBrainrotModels")
        or require(ReplicatedStorage.Shared.GetServerType):IsPublicServer()
    then
        local ac = croco:FindFirstChild("AnimationController")
        if ac then ac:Destroy() end
        local humanoid = Instance.new("Humanoid", croco)
        Instance.new("Animator", humanoid)
        humanoid.Name                 = "AnimationController"
        humanoid.EvaluateStateMachine = false
        humanoid.DisplayDistanceType  = Enum.HumanoidDisplayDistanceType.None
        humanoid.PlatformStand        = true
        humanoid.Parent               = croco
    end

    croco.Parent = workspace
    planeModels[plane.Name] = croco
    table.insert(activePlanes, plane)

    -- Reveal Svinina after 5s, same as original task.delay(5, ...)
    local revealThread = task.delay(5, function()
        if croco.Parent then
            for _, child in croco["Svinina Bombardino"]:GetChildren() do
                if child.Name ~= "RootPart" then
                    child.Transparency = 0
                end
            end
        end
    end)

    -- Bomb drop loop — fully client-side, no remotes
    -- Reads plane.Position each iteration so it's always current
    planeTrove:Add(task.spawn(function()
        while plane.Parent and EventController:GetActiveEventData(EVENT_NAME) do
            task.wait(math.random(5, 10))
            if not plane.Parent or not EventController:GetActiveEventData(EVENT_NAME) then break end

            -- Flash Svinina off the croco body (mirrors SpawnBomb remote behavior)
            for _, child in croco["Svinina Bombardino"]:GetChildren() do
                if child.Name ~= "RootPart" and child:IsA("BasePart") then
                    child.Transparency = 1
                    task.delay(1, function()
                        if child.Parent then child.Transparency = 0 end
                    end)
                end
            end

            -- Drop position: underside of plane hitbox
            local planePos = plane.Position
            local dropPos  = Vector3.new(
                planePos.X,
                planePos.Y - plane.Size.Y / 2 - 1,
                planePos.Z
            )

            -- Ground Y from Wander parts, same as server
            local wanderFolder = workspace:WaitForChild("Events"):WaitForChild("Wander")
            local wanderParts  = wanderFolder:GetChildren()
            local groundY      = 0
            if #wanderParts > 0 then
                local p = wanderParts[math.random(1, #wanderParts)]
                groundY = p.Position.Y + p.Size.Y / 2
            end

            local impactPos = Vector3.new(dropPos.X, groundY, dropPos.Z)

            -- Clone Svinina Bombardino as the falling bomb (mirrors cloneObj)
            local bomb = SvininaAsset:Clone()
            bomb.PrimaryPart.Anchored = true
            bomb:PivotTo(CFrame.new(dropPos))
            bomb.Parent = workspace

            local dropSound = Sounds.DroppingBomb:Clone()
            dropSound.Parent = bomb.PrimaryPart
            dropSound:Play()

            local elapsed  = 0
            local fallTime = MathUtils.calculateTimeToGround(dropPos.Y, groundY)
            local conn
            conn = planeTrove:Add(RunService.PostSimulation:Connect(function(dt)
                debug.profilebegin("Bombardiro Crocodilo:Bomb")
                elapsed += dt
                bomb:PivotTo(
                    CFrame.new(dropPos - vector.create(0, MathUtils.simulateGravity(elapsed), 0))
                    * CFrame.Angles(-elapsed * math.pi * 2, 0, 0)
                )
                if elapsed / fallTime >= 1 then
                    planeTrove:Remove(conn)

                    -- Hide bomb parts, destroy particles — mirrors original
                    for _, d in bomb:GetDescendants() do
                        if d:IsA("BasePart") then
                            d.Transparency = 1
                        elseif d:IsA("ParticleEmitter") then
                            d:Destroy()
                        end
                    end
                    task.delay(3, function() bomb:Destroy() end)

                    -- Explosion VFX + sound + shake
                    playExplosion(impactPos)

                    -- Apply Explosive trait to animals in blast radius — mirrors original
                    for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                        if animal.PrimaryPart and animal.Parent then
                            local apos   = animal.PrimaryPart.Position
                            local dist2d = Vector3.new(apos.X, 0, apos.Z)
                                - Vector3.new(impactPos.X, 0, impactPos.Z)
                            if dist2d.Magnitude <= 15 and not hasExplosive(animal) then
                                local traits = {}
                                local tj = animal:GetAttribute("Traits")
                                if tj then
                                    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, tj)
                                    if ok and type(decoded) == "table" then traits = decoded end
                                end
                                table.insert(traits, "Explosive")
                                animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
                            end
                        end
                    end
                end
                debug.profileend()
            end))
        end
    end))

    return function()
        pcall(task.cancel, revealThread)
        planeModels[plane.Name] = nil
        local idx = table.find(activePlanes, plane)
        if idx then table.remove(activePlanes, idx) end
        croco:Destroy()
        planeTrove:Clean()
    end
end))

-- ─── Activation visual (beam between players) — mirrors original OnStart ──────

local function initActivationVisual()
    local subCollector = trove:Extend()
    local connections  = table.create(3)
    subCollector:Add(function() table.clear(connections) end)

    local elapsed = 0
    subCollector:Add(RunService.PreRender:Connect(function(dt)
        debug.profilebegin("Bombardiro Event")
        elapsed += dt
        for idx, entry in connections do
            if entry.target and entry.targetAttachment then
                entry.beam.First.Enabled  = true
                entry.beam.Second.Enabled = true
                local t   = math.clamp(elapsed - idx + 1, 0, 1)
                local wp  = entry.beam.WorldPosition
                entry.targetAttachment.Position = wp + (entry.target:GetPivot().Position - wp) * t
            end
        end
        debug.profileend()
    end))

    subCollector:Add(Observers.observeTag("BombardiroCrocodiloPlayerVFX", function(parent)
        local beam  = script.PlayerVFX.Beam:Clone()
        beam.Parent = parent
        local torso = script.PlayerVFX.Torso:Clone()
        torso.Parent = parent
        local idx = parent:GetAttribute("BombardiroIndex")
        connections[idx] = { beam = beam, target = nil }

        local unsub = Observers.observeTag("BombardiroCrocodiloPlayerVFX", function(other)
            if other == parent then return nil end
            if other:GetAttribute("BombardiroIndex") ~= idx % 3 + 1 then return nil end
            local att = Instance.new("Attachment")
            att.Position = beam.WorldPosition
            att.Parent   = workspace.Terrain
            local c = connections[idx]
            c.target           = other
            c.beam.First.Attachment0  = att
            c.beam.Second.Attachment0 = att
            c.targetAttachment        = att
            return function() att:Destroy() end
        end)

        return function()
            torso:Destroy()
            beam:Destroy()
            unsub()
            connections[idx] = nil
        end
    end))
end

-- ─── Map VFX — mirrors original task.delay(startedAt + 8 - now) ──────────────

local function initMapVFX()
    local gate = startedAt + 8 - workspace:GetServerTimeNow()
    if gate > 0 then task.wait(gate) end

    local planesbg
    if ServerData.IsTsunamiServer() then
        planesbg = trove:Clone(script.PlanesbgTsunami)
    else
        planesbg = trove:Clone(script.Planesbg)
    end
    VFX.enable(planesbg)
    planesbg.Parent = workspace
    if ServerData.IsBiggerServer() then
        ClientEventUtils.resizeEffects(planesbg, 2)
    end
end

-- ─── Entry ────────────────────────────────────────────────────────────────────

trove:Add(task.spawn(initActivationVisual))
trove:Add(task.spawn(initMapVFX))

-- Cleanup watchdog
task.spawn(function()
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    trove:Destroy()
    planeModels  = {}
    activePlanes = {}
end)
