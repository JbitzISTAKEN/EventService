local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local VFX              = require(ReplicatedStorage.Shared.VFX)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local MathUtils        = require(ReplicatedStorage.Utils.MathUtils)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

local EventAssets = ReplicatedStorage.Controllers.EventController.Events["4th of July"]
local Sounds      = ReplicatedStorage.Sounds.Events["4th of July"]

repeat task.wait() until ReplicatedStorage:GetAttribute("4thOfJulyEvent")

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Include
RayParams.FilterDescendantsInstances = { workspace:WaitForChild("Map"), workspace:WaitForChild("Plots") }

local model  = workspace:WaitForChild("Fireworks", 30) or error("[4thJuly] Fireworks never appeared")
local source = ReplicatedStorage.Models.Events["4th of July"].Fireworks

local targets, launchers, originalCFrames = {}, {}, {}

for _, p in source:GetChildren() do
    if p:IsA("BasePart") then targets[p.Name] = p.Position end
end

for _, p in model:GetChildren() do
    if p:IsA("BasePart") and targets[p.Name] then
        table.insert(launchers, p)
        originalCFrames[p] = CFrame.new(targets[p.Name])
    end
end

if #launchers == 0 then return end

local function fireOne(launcher)
    local launchCF = originalCFrames[launcher]
    local height   = math.random(80, 120)
    local peakCF   = launchCF + Vector3.new(0, height, 0)
    local travel   = height / 20

    local startup = EventAssets.FireworkStartup:Clone()
    startup.CFrame = launchCF + Vector3.new(0, launcher.Size.Y * 0.5 - startup.Size.Y * 0.5, 0)
    startup.Parent = workspace
    VFX.emit(startup)
    SoundController:PlaySound(Sounds.Shot:Clone(), startup)
    task.delay(2, function() startup:Destroy() end)

    local proj = EventAssets.Firework:Clone()
    proj.CFrame  = launchCF
    proj.Parent  = workspace
    SoundController:PlaySound(Sounds["Trail Sound Ball"]:Clone(), proj)

    local rise = TweenService:Create(proj, TweenInfo.new(travel, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = peakCF })
    rise:Play()

    task.delay(travel * 0.8, function()
        rise:Destroy()
        proj:Destroy()

        SoundController:PlaySound(Sounds["Firework Explosion"], peakCF.Position)

        local fx = EventAssets.Effects[tostring(math.random(1, 3))]:Clone()
        fx.CFrame = peakCF
        fx.Parent = workspace
        VFX.emit(fx)
        task.delay(4, function() fx:Destroy() end)

        local groundCF = launchCF - Vector3.new(0, launcher.Size.Y, 0)

        for _ = 1, math.random(6, 9) do
            local angle  = math.random() * math.pi * 2
            local r      = math.random() * 70
            local ox, oz = math.cos(angle) * r, math.sin(angle) * r
            local hit    = workspace:Raycast((peakCF + Vector3.new(ox, 0, oz)).Position, Vector3.new(0, -200, 0), RayParams)
            local destCF = hit and CFrame.new(hit.Position) or groundCF + Vector3.new(ox, 0, oz)

            local trail   = EventAssets.Falloff:Clone()
            trail.CFrame  = peakCF
            trail.Parent  = workspace
            local elapsed = 0
            local conn
            conn = RunService.PostSimulation:Connect(function(dt)
                debug.profilebegin("4th of July:Falloff")
                elapsed += dt
                local t = elapsed / 2.3
                SharedEventUtils.pushPartCFrame(trail, CFrame.new(MathUtils.quadBezier(t,
                    peakCF.Position,
                    peakCF.Position + Vector3.new(0, height, 0) + (destCF.Position - peakCF.Position) * Vector3.new(1, 0, 1) * 0.7,
                    destCF.Position
                )))
                if t >= 1 then
                    local impact = EventAssets.GroundImpact:Clone()
                    impact.CFrame = destCF + Vector3.new(0, impact.Size.Y * 0.5, 0)
                    impact.Parent = workspace
                    VFX.emit(impact)
                    VFX.disable(trail)
                    task.delay(3, function() trail:Destroy() impact:Destroy() end)
                    conn:Disconnect()
                end
                debug.profileend()
            end)
        end
    end)
end

-- watch for rise completion then start salvo
local risen = 0
local function onRise()
    risen += 1
    if risen < #launchers then return end
    print("[4thJuly] All launchers have risen!")

    task.spawn(function()
        while ReplicatedStorage:GetAttribute("4thOfJulyEvent") do
            for _ = 1, math.random(1, 3) do
                fireOne(launchers[math.random(1, #launchers)])
            end
            task.wait(math.random(20, 40) / 10)
        end

        model.Destroying:Once(function()
            print("[4thJuly] All launchers have fallen!")
        end)
    end)
end

for _, p in launchers do
    local targetPos = targets[p.Name]
    if (p.Position - targetPos).Magnitude <= 0.2 then
        onRise()
    else
        local conn
        conn = p:GetPropertyChangedSignal("Position"):Connect(function()
            if (p.Position - targetPos).Magnitude <= 0.2 then
                conn:Disconnect()
                onRise()
            end
        end)
    end
end
