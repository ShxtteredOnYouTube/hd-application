-- // CONSTANTS
local GRID_SIZE = 1
local GRID_TRANSPARENCY = 0.8
local GRID_LERP_SPEED = 14
local MOVE_LERP_SPEED = 18

-- // SERVICES
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- // DEPENDENCIES
local player = Players.LocalPlayer
local mouse = player:GetMouse()
local camera = workspace.CurrentCamera

local PlaceRemote = ReplicatedStorage:WaitForChild("PlaceObject")
local ObjectsFolder = ReplicatedStorage:WaitForChild("Objects")

local Gridlines = workspace:WaitForChild("Gridlines")
local GridTop = Gridlines.TopTexture
local GridBottom = Gridlines.BottomTexture

local PlayerBuilds = workspace:WaitForChild("Builds"):WaitForChild(player.Name)

-- // PLACEMENT SOLVER
--[[
THese methods are responsible for checking surfaces and computing CFrames for
different surface types like the ground, walls and ceilings so spatial logic doesnt
get mixed up with other non-related things.
]]

local PlacementSolver = {}

function PlacementSolver.snap(v)
	return math.floor(v / GRID_SIZE + 0.5) * GRID_SIZE -- Snap the axis to the nearest increment
end

function PlacementSolver.surfaceAllowed(surfaceType, normal) -- This makes it easy to determine if a surface can be placed on by simply comparing normals
	if surfaceType == "Ground" then
		return normal.Y > 0.9
	elseif surfaceType == "Ceiling" then
		return normal.Y < -0.9
	elseif surfaceType == "Wall" then
		return math.abs(normal.Y) < 0.5
	end
	return false
end

function PlacementSolver.computeGroundCF(hitPos, preview, rotY)
	local y = hitPos.Y + preview.PrimaryPart.Size.Y / 2 -- We add half the size of the model as the model is pivoted based on its center, so incrementing the position by its half prevents clipping
	return CFrame.new(
		PlacementSolver.snap(hitPos.X),
		y,
		PlacementSolver.snap(hitPos.Z)
	) * CFrame.Angles(0, math.rad(rotY), 0)
end

function PlacementSolver.computeCeilingCF(hitPos, preview, rotY)
	local y = hitPos.Y - preview.PrimaryPart.Size.Y / 2 -- Similarly, we subtract half the size of the model so it doesn't clip through the ceiling
	return CFrame.new(
		PlacementSolver.snap(hitPos.X),
		y,
		PlacementSolver.snap(hitPos.Z)
	) * CFrame.Angles(0, math.rad(rotY), 0)
end

function PlacementSolver.computeWallCF(hitPos, normal, preview, rotY)
	local depth = preview:GetExtentsSize().Z / 2 -- Conceptually the same, this is the depth by which the preview should be offseted from the wall (again, half the size)
	local offset = hitPos + normal * depth

	offset = Vector3.new(
		offset.X,
		PlacementSolver.snap(offset.Y),
		offset.Z
	)

	local lookCF = CFrame.lookAt(offset, offset - normal) -- This is so the preview maintains the same orientation respective to the normal when the cursor is pointed at a different surface of the same type
	return lookCF * CFrame.Angles(0, math.rad(rotY), 0)
end

-- // PREVIEW CLASS
local PreviewObject = {}
PreviewObject.__index = PreviewObject -- Set the __index of the metatable so lookups are directed into here

function PreviewObject.new(template)
	local self = setmetatable({}, PreviewObject) -- THis creates an object in the metatable representig the preview so its easy to work with

	self.Model = template:Clone()
	self.Model.Parent = workspace
	self.TargetCF = self.Model.PrimaryPart.CFrame

	for _, part in self.Model:GetDescendants() do
		if part:IsA("BasePart") and part ~= self.Model.PrimaryPart then
			part.CanCollide = false
			part.Material = Enum.Material.ForceField
			part.Transparency = 0
		end
	end

	return self
end

function PreviewObject:setTarget(cf)
	self.TargetCF = cf
end

function PreviewObject:update(dt)
	self.Model:SetPrimaryPartCFrame(
		self.Model.PrimaryPart.CFrame:Lerp(
			self.TargetCF,
			math.clamp(dt * MOVE_LERP_SPEED, 0, 1) -- To create the smooth movement animation when the preview follows the cursor around
		)
	)
end

function PreviewObject:setColor(color)
	for _, part in self.Model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Color = color
		end
	end
end

function PreviewObject:destroy()
	self.Model:Destroy()
end

-- // BUILD CLASS
local BuildSession = {}
BuildSession.__index = BuildSession -- Similarly, the __index is set so lookups are directed into here

function BuildSession.new(objects, surfaceTypes)
	local self = setmetatable({}, BuildSession) -- Again, creates a new object in the metatable

	self.ObjectNames = objects
	self.SurfaceTypes = surfaceTypes
	self.Index = math.random(1, #objects)
	self.RotationY = 0
	self.GridY = 0

	self.Preview = nil
	self.RenderConn = nil
	self.PlaceDebounce = false

	return self
end

function BuildSession:start() -- Start build mode by creating the preview and making the grid appear
	self:createPreview()
	self:fadeGrid(true)

	self.RenderConn = RunService.RenderStepped:Connect(function(dt)
		self:update(dt)
	end)
end

function BuildSession:createPreview()
	if self.Preview then
		self.Preview:destroy()
	end

	local name = self.ObjectNames[self.Index]
	self.Preview = PreviewObject.new(ObjectsFolder[name])
end

function BuildSession:update(dt)
	local name = self.ObjectNames[self.Index]
	local surfaceType = self.SurfaceTypes[name]

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { self.Preview.Model, Gridlines } -- The model itself and the grid is ignored so the placement isn't weird
	params.FilterType = Enum.RaycastFilterType.Blacklist

	local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if not hit then return end

	local valid = PlacementSolver.surfaceAllowed(surfaceType, hit.Normal) -- Determine whether the surface can be placed on before continuing
	local targetCF

	if valid then -- Update the grid's position dynamically 
		if surfaceType == "Ground" then
			targetCF = PlacementSolver.computeGroundCF(hit.Position, self.Preview.Model, self.RotationY)
			self:updateGrid(dt, hit.Position.Y) -- The computeGroundCF() function keeps the grid fixed to the ground when placing on the ground
		elseif surfaceType == "Ceiling" then
			targetCF = PlacementSolver.computeCeilingCF(hit.Position, self.Preview.Model, self.RotationY)
			self:updateGrid(dt, hit.Position.Y) -- The computeCeilingCF() fixes the grid to the ceiling's surface so its easy to tell where on the grid you're placing a hanging object
		elseif surfaceType == "Wall" then
			targetCF = PlacementSolver.computeWallCF(hit.Position, hit.Normal, self.Preview.Model, self.RotationY)
			self:updateGrid(dt, hit.Position.Y - 2) -- The computeWallCF() function dynamically moves the grid so its just under the preview object so its easy to tell where youre positioning it
		end
	end

	if targetCF then
		self.Preview:setTarget(targetCF)
	end

	self.Preview:update(dt)

	local color = valid and Color3.fromRGB(0,255,0) or Color3.fromRGB(255,0,0)
	self.Preview:setColor(color) -- This gives color feedback (i.e. green if valid, red if invalid) based on whether the current placing position is valid or not
	GridTop.Color3 = color
	GridBottom.Color3 = color

	if valid
		and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		and not self.PlaceDebounce
	then
		self.PlaceDebounce = true -- This debounce prevents spam placement 
		PlaceRemote:FireServer("place", name, self.Preview.Model.PrimaryPart.CFrame)
		
		task.delay(0.2, function()
			self.PlaceDebounce = false
		end)
	end
end

function BuildSession:fadeGrid(on)
	local t = on and GRID_TRANSPARENCY or 1
	TweenService:Create(GridTop, TweenInfo.new(0.2), {Transparency = t}):Play()
	TweenService:Create(GridBottom, TweenInfo.new(0.2), {Transparency = t}):Play()
end

function BuildSession:updateGrid(dt, targetY)
	self.GridY += (targetY - self.GridY) * dt * GRID_LERP_SPEED -- Update the grid's position with the lerp speed factored in

	Gridlines.CFrame = CFrame.new(
			0,
			self.GridY,
			0
		)
end

function BuildSession:stop()
	if self.RenderConn then
		self.RenderConn:Disconnect()
	end
	if self.Preview then
		self.Preview:destroy()
	end
	self:fadeGrid(false)
end

-- // DELETE CLASS
local DeleteSession = {}
DeleteSession.__index = DeleteSession

function DeleteSession.new()
	local self = setmetatable({}, DeleteSession)

	self.Highlight = Instance.new("Highlight")
	self.Highlight.FillColor = Color3.fromRGB(255,60,60)
	self.Highlight.OutlineTransparency = 1
	self.Highlight.FillTransparency = 1
	self.Highlight.OutlineColor = Color3.fromRGB(255,0,0)
	self.Highlight.Enabled = false
	self.Highlight.Parent = workspace


	self.Target = nil
	self.DeleteDebounce = false
	self.RenderConn = nil

	return self
end

function DeleteSession:fadeIn()
	TweenService:Create(
		self.Highlight,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			FillTransparency = 0.5,
			OutlineTransparency = 0
		}
	):Play()
end

function DeleteSession:fadeOut()
	TweenService:Create(
		self.Highlight,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			FillTransparency = 1,
			OutlineTransparency = 1
		}
	):Play()
end


function DeleteSession:start()
	self.RenderConn = RunService.RenderStepped:Connect(function()
		self:update()
	end)
end

function DeleteSession:update()
	local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000)

	local newTarget = nil

	if hit and hit.Instance then
		local model = hit.Instance:FindFirstAncestorOfClass("Model")
		if model and model:IsDescendantOf(PlayerBuilds) then -- This makes it so that you can only select your own builds while in delete mode
			newTarget = model
		end
	end

	if newTarget ~= self.Target then -- When the target changes:

		if self.Target then -- When the target is lost:
			self:fadeOut()
			task.delay(0.15, function()
				if not self.Target then
					self.Highlight.Enabled = false
				end
			end)
		end

		self.Target = newTarget

		if self.Target then -- When the target is gained again:
			self.Highlight.Adornee = self.Target
			self.Highlight.Enabled = true
			self:fadeIn()
		end
	end

	if self.Target
		and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		and not self.DeleteDebounce
	then
		self.DeleteDebounce = true
		PlaceRemote:FireServer("delete", self.Target)
	end
end

function DeleteSession:stop()
	if self.RenderConn then
		self.RenderConn:Disconnect() -- Delete the connection to prevent memory leaks
		self.RenderConn = nil
	end

	self.Highlight.Enabled = false
	self.Highlight:Destroy()
end

-- // BUILD CLASS
local BuildController = {}
BuildController.__index = BuildController

function BuildController.new()
	local self = setmetatable({}, BuildController) -- Create a new manager for objects

	self.Objects = {}
	self.SurfaceTypes = {}

	for _, obj in ObjectsFolder:GetChildren() do
		table.insert(self.Objects, obj.Name)
		self.SurfaceTypes[obj.Name] = obj:GetAttribute("SurfaceType") -- The type of surface that an object can be placed on is stored as an attribute in the model itself, so we retrieve that here
	end

	self.Session = nil
	self.DeleteSession = nil
	self.Mode = "None"

	return self
end

function BuildController:enterBuildMode()
	self.Session = BuildSession.new(self.Objects, self.SurfaceTypes)
	self.Session:start() -- Create a new session and enter build mode
	self.Mode = "Build"
end

function BuildController:enterDeleteMode()
	if self.Session then
		self.Session:stop() -- Before entering DELETE mode, we stop build mode to prevent any inference
		self.Session = nil
	end
	self.DeleteSession = DeleteSession.new()
	self.DeleteSession:start()
	self.Mode = "Delete"
end

function BuildController:exitAll()
	if self.Session then self.Session:stop() end
	if self.DeleteSession then self.DeleteSession:stop() end
	self.Session = nil
	self.DeleteSession = nil
	self.Mode = "None"
end

-- // INPUT HANDLING
local Controller = BuildController.new()

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end

	if input.KeyCode == Enum.KeyCode.E then -- E as the toggle for build mode
		if Controller.Mode == "None" then
			Controller:enterBuildMode()
		else
			Controller:exitAll()
		end

	elseif input.KeyCode == Enum.KeyCode.V then -- V as the toggle for delete mode
		if Controller.Mode == "Build" then
			Controller:enterDeleteMode()
		elseif Controller.Mode == "Delete" then
			Controller:exitAll()
			Controller:enterBuildMode()
		end

	elseif Controller.Mode == "Build" and Controller.Session then
		if input.KeyCode == Enum.KeyCode.R then
			Controller.Session.RotationY += 90
		elseif input.KeyCode == Enum.KeyCode.X then
			Controller.Session.Index = Controller.Session.Index % #Controller.Objects + 1 -- Skip to the next object
			Controller.Session:createPreview()
		elseif input.KeyCode == Enum.KeyCode.Z then
			Controller.Session.Index = (Controller.Session.Index - 2) % #Controller.Objects + 1 -- Go back to the previous object
			Controller.Session:createPreview()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if Controller.Session then
			Controller.Session.PlaceDebounce = false
		end
		if Controller.DeleteSession then
			Controller.DeleteSession.DeleteDebounce = false
		end
	end
end)
