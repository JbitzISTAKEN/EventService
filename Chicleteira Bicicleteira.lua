local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Observers        = require(ReplicatedStorage.Packages.Observers)
local Trove            = require(ReplicatedStorage.Packages.Trove)
local Spr              = require(ReplicatedStorage.Packages.Spr)
local VFX              = require(ReplicatedStorage.Shared.VFX)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local EventScript = ReplicatedStorage.Controllers.EventController.Events["Chicleteira Bicicleteira"]
local Sounds      = ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"]

repeat task.wait() until ReplicatedStorage:GetAttribute("ChicleteiraBicicleteiraEvent")

local managedObj = Trove.new()

local BIKE_SPEED   = 35
local PATH_START_Z = -132.1
local PATH_END_Z   = 251.706
local TRAVEL_TIME  = math.abs(PATH_END_Z - PATH_START_Z) / BIKE_SPEED

local DEFAULT_LANES = {
    { x = -419.394, baseY = -9.074 },
    { x = -402.863, baseY = -9.074 },
}

-- ── moving bike ────────────────────────────────────────────────────────────
local function spawnBike(startCF, endCF, jumpCF)
    local bike = EventScript["Chicleteira Bicicleteira"]:Clone()
    bike:PivotTo(startCF)
    bike.Parent = workspace

    local walkAnim = bike.AnimationController.Animator:LoadAnimation(EventScript.Walk)
    walkAnim.Looped = true
    walkAnim:Play()
    walkAnim:AdjustSpeed(2)

    local bikeSfx = Sounds.Bike:Clone()
    bikeSfx.Parent = bike.PrimaryPart
    bikeSfx:Play()

    local dist    = math.abs(endCF.Z - startCF.Z)
    local duration = dist / BIKE_SPEED
    local elapsed  = 0
    local conn
    conn = managedObj:Add(RunService.PostSimulation:Connect(function(dt)
        elapsed += dt
        local t = math.clamp(elapsed / duration, 0, 1)

        if t >= 1 then
            conn:Disconnect()
            bike:Destroy()
            return
        end

        if jumpCF == nil then
            bike:PivotTo(startCF:Lerp(endCF, t))
        else
            local lerped     = startCF:Lerp(endCF, t)
            local jumpLerped = jumpCF:Lerp(endCF, t)
            local blend      = math.clamp(t / 0.05, 0, 1)
            local y          = math.lerp(jumpLerped.Y, lerped.Y, blend) + math.sin(math.pi * blend) * (5 + (jumpLerped.Y - lerped.Y))
            bike:PivotTo(CFrame.new(lerped.X, y, jumpLerped.Z) * lerped.Rotation)
        end
    end))
end

-- ── standing chicletera ────────────────────────────────────────────────────
local function spawnStanding(lane)
    local addObj = Trove.new()
    local pivot  = CFrame.new(lane.x, lane.baseY, 0) * CFrame.fromOrientation(0, math.pi, 0)

    local model = addObj:Clone(EventScript["Standing Chicleteira Bicicleteira"])
    local Y     = model:GetExtentsSize().Y
    model:PivotTo(pivot - Vector3.new(0, Y, 0))
    model.Parent = workspace

    local Animator = model.AnimationController.Animator

    local idleAnim = Animator:LoadAnimation(EventScript.Idle)
    idleAnim.Looped   = true
    idleAnim.Priority = Enum.AnimationPriority.Idle
    idleAnim:Play()
    addObj:Add(function() idleAnim:Stop(0) idleAnim:Destroy() end)

    local paintAnim = Animator:LoadAnimation(EventScript.Painting)
    paintAnim.Looped   = false
    paintAnim.Priority = Enum.AnimationPriority.Action4
    addObj:Add(function() paintAnim:Stop(0) paintAnim:Destroy() end)

    addObj:Add(idleAnim:GetMarkerReachedSignal("Shake"):Connect(function()
        if not paintAnim.IsPlaying then
            task.spawn(function()
                SoundController:PlaySound(Sounds.Shake, pivot.Position)
            end)
        end
    end))

    -- ForceSpray watch — server sets this attribute on the chicletera part
    addObj:Add(task.spawn(function()
        while model.Parent and ReplicatedStorage:GetAttribute("ChicleteiraBicicleteiraEvent") do
            task.wait(0.1)
            local target    = model:GetAttribute("ForceSpray")
            local targetPos = target and ClientEventUtils.getAnimalPosition(target)
            if targetPos then
                local flat = Vector3.new(targetPos.X, pivot.Y, targetPos.Z)
                Spr.target(model, 1, 2, {
                    Pivot = CFrame.lookAt(pivot.Position, flat) * CFrame.fromOrientation(0, math.pi, 0)
                })
            else
                Spr.target(model, 1, 2, { Pivot = pivot })
            end
        end
    end))

    addObj:Add(model:GetAttributeChangedSignal("ForceSpray"):Connect(function()
        if model:GetAttribute("ForceSpray") then
            task.spawn(function()
                SoundController:PlaySound(Sounds.Spray, pivot.Position)
            end)
            paintAnim:Stop(0)
            paintAnim:Play()
            task.wait(0.3)
            VFX.enable(model.Handle.vfx)
            task.wait(1)
            VFX.disable(model.Handle.vfx)
        end
    end))

    SoundController:PlaySound(Sounds.Ground, pivot.Position)
    managedObj:Add(addObj)
end

-- ── fire bikes then drop standing models ──────────────────────────────────
task.delay(3, function()
    if not ReplicatedStorage:GetAttribute("ChicleteiraBicicleteiraEvent") then return end

    local rot = CFrame.Angles(0, math.rad(180), 0)
    for _, lane in DEFAULT_LANES do
        local startCF = CFrame.new(lane.x, lane.baseY, PATH_START_Z) * rot
        local endCF   = CFrame.new(lane.x, lane.baseY, PATH_END_Z)   * rot
        spawnBike(startCF, endCF, nil)
    end
end)

task.delay(3 + TRAVEL_TIME, function()
    if not ReplicatedStorage:GetAttribute("ChicleteiraBicicleteiraEvent") then return end
    for _, lane in DEFAULT_LANES do
        spawnStanding(lane)
    end
end)

-- ── cleanup ────────────────────────────────────────────────────────────────
task.spawn(function()
    while ReplicatedStorage:GetAttribute("ChicleteiraBicicleteiraEvent") do task.wait(1) end
    managedObj:Destroy()
end)
