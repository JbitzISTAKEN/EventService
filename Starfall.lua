local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")

local VFX          = require(ReplicatedStorage.Shared.VFX)
local SoundController = require(ReplicatedStorage.Controllers.SoundController)
local ShakePresets = require(ReplicatedStorage.Shared.ShakePresets)
local Shake        = require(ReplicatedStorage.Packages.Shake)

local EventScript  = ReplicatedStorage.Controllers.EventController.Events.Starfall
local Sounds       = ReplicatedStorage.Sounds.Events.Starfall

local v4 = Shake.new()
v4.Amplitude        = 1.5
v4.Frequency        = 0.1
v4.FadeInTime       = 0
v4.FadeOutTime      = 0.6
v4.PositionInfluence = Vector3.new(0.2, 0.2, 0.2)
v4.RotationInfluence = Vector3.new(2.5, 0.5, 0.5)

repeat task.wait() until ReplicatedStorage:GetAttribute("Starfall")

local activeMeteors = {}
local nextStarId    = 1

local function spawnMeteor(starId, startPos, targetPos, fallDuration)
    local meteor = EventScript.Meteor:Clone()
    meteor:PivotTo(CFrame.new(startPos))
    meteor.Parent = workspace

    local primary = meteor.PrimaryPart
    if not primary then
        warn("[Starfall] Meteor missing PrimaryPart")
        meteor:Destroy()
        return
    end

    local tween = TweenService:Create(
        primary,
        TweenInfo.new(fallDuration, Enum.EasingStyle.Linear),
        { CFrame = CFrame.lookAt(targetPos, startPos) }
    )
    tween:Play()

    activeMeteors[starId] = { Model = meteor, Tween = tween }

    tween.Completed:Once(function()
        local data = activeMeteors[starId]
        if not data then return end

        activeMeteors[starId] = nil

        -- hide meteor
        for _, desc in meteor:GetDescendants() do
            if desc:IsA("ParticleEmitter") then
                desc.Enabled = false
            elseif desc:IsA("BasePart") then
                desc.Transparency = 1
            end
        end
        Debris:AddItem(meteor, 3)

        -- explosion VFX
        SoundController:PlaySound(Sounds.Impact, targetPos)

        local explosion = EventScript.Explosion:Clone()
        explosion:PivotTo(CFrame.new(targetPos))
        explosion.Parent = workspace

        for _, desc in explosion:GetDescendants() do
            if desc:IsA("ParticleEmitter") then
                task.delay(desc:GetAttribute("EmitDelay") or 0, function()
                    desc:Emit(desc:GetAttribute("EmitCount") or 1)
                end)
            end
        end
        Debris:AddItem(explosion, 5)

        -- camera shake if close enough
        local magnitude = (workspace.CurrentCamera.CFrame.Position - targetPos).Magnitude
        if magnitude <= 150 then
            local shakeClone = v4:Clone()
            local scale = math.pow(1 - magnitude / 150, 2)
            shakeClone.Amplitude        = shakeClone.Amplitude * scale
            shakeClone.RotationInfluence = shakeClone.RotationInfluence * scale
            ShakePresets.BindShakeToCamera(shakeClone)
            shakeClone:Start()
        end
    end)
end

local function loop()
    while ReplicatedStorage:GetAttribute("Starfall") do
        local waitTime    = math.random(25) / 100
        task.wait(waitTime)

        if not ReplicatedStorage:GetAttribute("Starfall") then break end

        local mapFloor  = workspace.Events.Starfall.MapFloor
        local floorSize = mapFloor.Size
        local floorCF   = mapFloor.CFrame

        local randomX = math.random(-floorSize.X / 2, floorSize.X / 2)
        local randomZ = math.random(-floorSize.Z / 2, floorSize.Z / 2)
        local targetPos = (floorCF * CFrame.new(randomX, 0, randomZ)).Position

        local fixedOrigin = Vector3.new(-1000, 225, 50)
        local dir         = targetPos - fixedOrigin
        local hDist       = Vector3.new(dir.X, 0, dir.Z).Magnitude
        local startPos    = Vector3.new(fixedOrigin.X, targetPos.Y + hDist, fixedOrigin.Z)

        local fallDuration = math.random(250, 400) / 100
        local starId       = nextStarId
        nextStarId        += 1

        spawnMeteor(starId, startPos, targetPos, fallDuration)
    end

    -- cleanup on event end
    for _, data in activeMeteors do
        if data.Tween  then data.Tween:Cancel() end
        if data.Model  then data.Model:Destroy() end
    end
    table.clear(activeMeteors)
end

task.spawn(loop)
