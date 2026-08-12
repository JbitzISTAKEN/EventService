-- Los Matteos.lua (loadstring target)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Debris            = game:GetService("Debris")

local Trove       = require(ReplicatedStorage.Packages.Trove)
local CreateTween = require(ReplicatedStorage.Packages.CreateTween)
local EvLightning = require(ReplicatedStorage.Packages.EvLightning)
local Shake       = require(ReplicatedStorage.Packages.Shake)
local ShakePresets = require(ReplicatedStorage.Shared.ShakePresets)
local VFX          = require(ReplicatedStorage.Shared.VFX)
local SoundCtrl    = require(ReplicatedStorage.Controllers.SoundController)
local EventController = require(ReplicatedStorage.Controllers.EventController)

local EVENT_NAME = "Los Matteos"

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local startedAt = EventController:GetActiveEventData(EVENT_NAME).startedAt

local function timeLeftFor(t)
    return startedAt + t - workspace:GetServerTimeNow()
end

local trove = Trove.new()

-- ── Attributes ────────────────────────────────────────────────────────────────

ReplicatedStorage:SetAttribute("LosMatteosEvent", true)
trove:Add(task.delay(math.max(0, timeLeftFor(3)), function()
    ReplicatedStorage:SetAttribute("LosMatteosEventNightTime", true)
end))

trove:Add(function()
    ReplicatedStorage:SetAttribute("LosMatteosEvent", nil)
    ReplicatedStorage:SetAttribute("LosMatteosEventNightTime", nil)
end)

-- ── Roots ─────────────────────────────────────────────────────────────────────

trove:Add(task.delay(math.max(0, timeLeftFor(3)), function()
    local roots = game:GetObjects("rbxassetid://76357454979877")[1]
    if not roots then return end
    roots.Name = "Roots"

    local mapCenterPart = workspace:FindFirstChild("MapCenterGround")
    local spawnPos = mapCenterPart and mapCenterPart.Position or Vector3.new(0, 0, 0)

    roots:PivotTo(CFrame.new(spawnPos))

    -- stagger parts in by distance from center, mirrors server START_DELAY + DURATION logic
    local entries = {}
    for _, d in roots:GetDescendants() do
        if d:IsA("BasePart") then
            table.insert(entries, {
                part     = d,
                distance = (d.Position - spawnPos).Magnitude,
            })
            d.Parent = nil
        end
    end

    table.sort(entries, function(a, b) return a.distance < b.distance end)

    local minD  = entries[1] and entries[1].distance or 0
    local maxD  = entries[#entries] and entries[#entries].distance or 1
    local range = math.max(maxD - minD, 1)
    local DURATION = 5

    roots.Parent = workspace
    trove:Add(roots)

    for i, entry in entries do
        local norm     = (entry.distance - minD) / range
        local delay    = norm * DURATION
        local nextNorm = entries[i + 1] and ((entries[i + 1].distance - minD) / range) or (norm + 0.02)
        local tweenDur = math.max((nextNorm - norm) * DURATION, 0.05)

        trove:Add(task.delay(delay, function()
            if not roots.Parent then return end
            entry.part.Parent = roots

            local orig = entry.part.Size
            entry.part.Size = Vector3.new(orig.X, 0, orig.Z)
            CreateTween(
                entry.part,
                TweenInfo.new(tweenDur, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                { Size = orig }
            )
        end))
    end
end))

-- ── Lightning ─────────────────────────────────────────────────────────────────

local boltPart = Instance.new("Part")
boltPart.Anchored     = true
boltPart.CanCollide   = false
boltPart.TopSurface   = Enum.SurfaceType.Smooth
boltPart.BottomSurface = Enum.SurfaceType.Smooth
boltPart.Material     = Enum.Material.Neon
boltPart.Color        = Color3.fromRGB(96, 234, 255)

local shakeBase = Shake.new()
shakeBase.Amplitude         = 3
shakeBase.Frequency         = 0.1
shakeBase.FadeInTime        = 0
shakeBase.FadeOutTime       = 0.6
shakeBase.PositionInfluence = Vector3.new(0.5, 0.5, 0.5)
shakeBase.RotationInfluence = Vector3.new(2.5, 0.5, 0.5)

local strikeId = 0

local function fireLocalLightning(strikePos)
    strikeId += 1
    local id   = strikeId
    local rand = Random.new(id)

    local camDist = (workspace.CurrentCamera.CFrame.Position - strikePos).Magnitude
    if camDist <= 75 then
        local s   = shakeBase:Clone()
        local fac = (1 - camDist / 75 * 0.5) ^ 2
        s.Amplitude         = s.Amplitude * fac
        s.RotationInfluence = s.RotationInfluence * fac
        ShakePresets.BindShakeToCamera(s)
        s:Start()
    end

    local boltStart = strikePos + Vector3.new(0, 70, 0)

    local bolt = EvLightning.create(boltStart, strikePos, {
        bends       = 4,
        thickness   = 1,
        max_depth   = 1,
        fork_bends  = 1,
        fork_chance = 30,
        decay       = 3,
        material    = Enum.Material.Neon,
    })

    local boltModel    = Instance.new("Model")
    boltModel.Name     = "LightningBolt"
    bolt.model         = boltModel

    local lines = bolt:GetLines()
    table.sort(lines, function(a, b) return a.origin.Y > b.origin.Y end)

    local lowestY  = lines[#lines].origin.Y
    local highestY = lines[1].origin.Y
    local yRange   = math.max(highestY - lowestY, 1)
    local baseDelay = bolt.random:NextInteger(10, 20) / 100

    local tweenedParts = {}

    for i, line in lines do
        if line.goal.Y >= strikePos.Y then
            local t    = math.max((highestY - line.origin.Y) / yRange * baseDelay, 0)
            local part = boltPart:Clone()
            part.Size  = Vector3.new(
                bolt.thickness - line.depth * 2 * 0.1,
                bolt.thickness - line.depth * 2 * 0.1,
                (line.origin - line.goal).Magnitude + 0.5
            )
            part.CFrame       = CFrame.new((line.goal + line.origin) / 2, line.goal)
            part.Transparency = 1
            part.Parent       = boltModel
            tweenedParts[i]   = part

            CreateTween(
                part,
                TweenInfo.new(0.05, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, t),
                { Transparency = line.transparency }
            )
        end
    end

    task.delay(baseDelay + 0.05, function()
        SoundCtrl:PlaySound(
            ReplicatedStorage.Sounds.Events["Los Matteos"]["HitNothing"],
            strikePos,
            false
        )

        for _, p in tweenedParts do
            if not p then continue end
            task.spawn(function()
                p.Transparency = 0
                task.wait(0.1)
                p.Transparency = 1
                task.wait(0.1)
                CreateTween(
                    p,
                    TweenInfo.new(0.1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, true),
                    { Transparency = 0.4 }
                )
            end)
        end

        task.delay(bolt.options.decay or 1, function()
            boltModel:Destroy()
            bolt.destroyed = true
        end)
    end)

    boltModel.Parent = workspace.CurrentCamera
    bolt.drew        = true
end

-- lightning loop starts at t=8, matches server LIGHTNING_START_DELAY
trove:Add(task.delay(math.max(0, timeLeftFor(8)), function()
    local rainArea = workspace.Events["Los Matteos"]:FindFirstChild("RainArea")

    while EventController:GetActiveEventData(EVENT_NAME) do
        task.wait(0.5)

        local strikePos
        if rainArea then
            local s  = rainArea.Size
            local cf = rainArea.CFrame
            strikePos = (cf * CFrame.new(
                math.random(-s.X / 2, s.X / 2),
                0,
                math.random(-s.Z / 2, s.Z / 2)
            )).Position
        else
            local angle = math.random() * math.pi * 2
            local dist  = math.random(20, 80)
            local base  = workspace:FindFirstChild("MapCenterGround")
            local origin = base and base.Position or Vector3.new(0, 0, 0)
            strikePos   = origin + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
        end

        task.spawn(fireLocalLightning, strikePos)

        -- double strike, matches server math.random(1,2)
        if math.random(1, 2) == 2 then
            task.wait(0.3)
            task.spawn(fireLocalLightning, strikePos + Vector3.new(
                math.random(-15, 15), 0, math.random(-15, 15)
            ))
        end
    end

    trove:Destroy()
end))
