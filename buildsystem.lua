-- // CONSTANTS
local GRID_SIZE = 1 -- size of the grid (i set it to 1 as the grid texture is the default baseplate one which uses 1 stud gaps)
local GRID_TRANS = 0.8 -- transparency of the grid
local GRID_LERP = 14 -- animating speed of the grid
local MOVE_LERP = 18 -- animating speed of the object
local ROT_LERP = 16 -- rotation speed of the greed



-- // SERVICES
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")



-- // DEPENDENCIES
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local mouse = player:GetMouse()
local re = RS:WaitForChild("PlaceObject")

local gridlines = workspace:WaitForChild("Gridlines")
local tex1 = gridlines.TopTexture
local tex2 = gridlines.BottomTexture

local playerbuilds = workspace:WaitForChild("Builds"):WaitForChild(player.Name)
local objects = RS:WaitForChild("Objects")

local objectstbl = {} -- array of all objects
local sftypes = {} -- array of all surfaces

for _, obj in objects:GetChildren() do
	table.insert(objectstbl, obj.Name)
	sftypes[obj.Name] = obj:GetAttribute("SurfaceType")
end



-- // VARIABLES
local preview = nil
local index = math.random(1, #objectstbl)

local rotY = 0
local smoothRotY = 0
local gridY = 0
local targetCF = nil

local buildloopconn = nil
local deleteloopconn = nil
local currentSelection = nil

local placeDebounce = false

local tweeninfo = TweenInfo.new(.35, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out) -- tween info for selection boxes



-- // FUNCTIONS
local function snap(v)
	return math.floor(v / GRID_SIZE + 0.5) * GRID_SIZE -- to snap to the closest round integer in the grid
end

local function fadeGrid(on)
	local t = on and GRID_TRANS or 1
	TweenService:Create(tex1, TweenInfo.new(0.2), {Transparency = t}):Play()
	TweenService:Create(tex2, TweenInfo.new(0.2), {Transparency = t}):Play()
end

local function createPreview()
	if preview then preview:Destroy() end

	preview = objects[objectstbl[index]]:Clone()
	preview.Parent = workspace
	targetCF = preview.PrimaryPart.CFrame

	for _, p in preview:GetDescendants() do -- make the preview visuals
		if p:IsA("BasePart") and p ~= preview.PrimaryPart then
			p.Material = Enum.Material.ForceField
			p.Transparency = 0
			p.CanCollide = false
		end
	end
end

local function previewColorFeedback(c)
	for _, p in preview:GetDescendants() do -- red or green color feedback based on validity
		if p:IsA("BasePart") and p ~= preview.PrimaryPart then
			p.Color = c
		end
	end
end

local function gridColorFeedback(c)
	tex1.Color3 = c -- same color feedback as in the preview
	tex2.Color3 = c
end

local function enterBuildModeLoop()
	if buildloopconn then buildloopconn:Disconnect() end

	buildloopconn = RunService.RenderStepped:Connect(function(dt)
		local objType = objectstbl[index]
		local surfacetype = sftypes[objType]

		local params = RaycastParams.new()
		params.FilterDescendantsInstances = { preview, gridlines }
		params.FilterType = Enum.RaycastFilterType.Blacklist

		local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
		if not hit then return end

		local pos = hit.Position
		local n = hit.Normal
		local surfaceOK = false

		if surfacetype == "Ground" then -- deterministicically validate the placement position
			surfaceOK = n.Y > 0.9
		elseif surfacetype == "Ceiling" then
			surfaceOK = n.Y < -0.9
		elseif surfacetype == "Wall" then
			surfaceOK = math.abs(n.Y) < 0.5
		end

		local valid = surfaceOK

		if surfaceOK then
			if surfacetype == "Ground" then -- here, we keep the grid fixed to the ground
				local x = snap(pos.X)
				local z = snap(pos.Z)
				local y = pos.Y + preview.PrimaryPart.Size.Y / 2

				targetCF =
					CFrame.new(x, y, z)
					* CFrame.Angles(0, math.rad(rotY), 0)

				gridY = 0

			elseif surfacetype == "Ceiling" then -- and here, we fix the grid to the ceiling normal
				local x = snap(pos.X)
				local z = snap(pos.Z)
				local y = pos.Y - preview.PrimaryPart.Size.Y / 2

				targetCF =
					CFrame.new(x, y, z)
					* CFrame.Angles(0, math.rad(rotY), 0)

				gridY += (pos.Y - gridY) * math.clamp(dt * GRID_LERP, 0, 1)

			elseif surfacetype == "Wall" then -- but for wall placement, we dynamically change the grid's Y level to match that of the cursor (+ a little bit of adjustment)
				local size = preview:GetExtentsSize()
				local depth = size.Z / 2

				local placePos = pos + n * depth -- offset the placements by half the depth of the hitbox so it isnt clipping into the wall
				placePos = Vector3.new(
					placePos.X,
					snap(placePos.Y),
					placePos.Z
				)

				local lookCF =
					CFrame.lookAt(
						placePos,
						placePos - n
					)

				targetCF =
					lookCF
					* CFrame.Angles(0, math.rad(rotY), 0)

				gridY += (placePos.Y - gridY) * math.clamp(dt * GRID_LERP, 0, 1)
			end

			for _, p in workspace:GetPartsInPart(preview.PrimaryPart) do
				if p.CanCollide and not p:IsDescendantOf(preview) then
					valid = false
					break
				end
			end
		end

		if targetCF then -- and finally we position the preview
			preview:SetPrimaryPartCFrame(
				preview.PrimaryPart.CFrame:Lerp(
					targetCF,
					math.clamp(dt * MOVE_LERP, 0, 1)
				)
			)
		end

		gridlines.Position =
			surfacetype == "Wall" and Vector3.new(0, gridY - 1, 0)
			or surfacetype == "Ceiling" and Vector3.new(0, gridY, 0)
			or Vector3.new(0, 0, 0)

		previewColorFeedback(valid and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 0, 0))
		gridColorFeedback(valid and Color3.fromRGB(80, 255, 80) or Color3.fromRGB(255, 80, 80))

		if valid
			and UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) -- beam the placement info when MB1 is clicked
			and not placeDebounce
		then
			placeDebounce = true -- debounce so no spamming occurs
			re:FireServer("place", objType, preview.PrimaryPart.CFrame)
		end
	end)
end



local function enterDeleteModeLoop()
	if deleteloopconn then deleteloopconn:Disconnect() end -- disconnect any existing connections

	deleteloopconn = RunService.RenderStepped:Connect(function()
		local params = RaycastParams.new()
		params.FilterDescendantsInstances = {gridlines}
		params.FilterType = Enum.RaycastFilterType.Blacklist

		local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)

		if not hit then
			if currentSelection and currentSelection:FindFirstChild("DeleteSB") then
				currentSelection.DeleteSB.Transparency = 1
			end
			currentSelection = nil
			return
		end

		local model = hit.Instance:FindFirstAncestorOfClass("Model") -- find the actual object model
		if not model
			or not model:IsDescendantOf(playerbuilds)
			or not model:FindFirstChild("DeleteSB") then

			if currentSelection and currentSelection:FindFirstChild("DeleteSB") then -- show the hitbox when deleting an object
				TweenService:Create(currentSelection.DeleteSB, tweeninfo, {Transparency = 1}):Play()
			end
			currentSelection = nil
			return
		end

		if model ~= currentSelection then
			if currentSelection and currentSelection:FindFirstChild("DeleteSB") then
				TweenService:Create(currentSelection.DeleteSB, tweeninfo, {Transparency = 1}):Play()
			end

			currentSelection = model
			TweenService:Create(currentSelection.DeleteSB, tweeninfo, {Transparency = 0}):Play()
		end
	end)
end

local function enterBuildMode()
	rotY = 0
	smoothRotY = 0
	index = math.random(1, #objectstbl)
	createPreview()
	fadeGrid(true)
	enterBuildModeLoop()
end

local function enterDeleteMode()
	if buildloopconn then
		buildloopconn:Disconnect()
		buildloopconn = nil
	end

	if preview then
		preview:Destroy()
		preview = nil
	end

	enterDeleteModeLoop()
end

local function exitDeleteMode()
	if deleteloopconn then
		deleteloopconn:Disconnect()
		deleteloopconn = nil
	end

	if currentSelection and currentSelection:FindFirstChild("DeleteSB") then
		TweenService:Create(currentSelection.DeleteSB, tweeninfo, {Transparency = 1}):Play()
	end
	currentSelection = nil

	enterBuildMode()
end

local function exitBuildMode()
	if preview then preview:Destroy() preview = nil end
	fadeGrid(false)

	if buildloopconn then buildloopconn:Disconnect() buildloopconn = nil end -- disconnect all connections
	if deleteloopconn then deleteloopconn:Disconnect() deleteloopconn = nil end
end




-- // HANDLER
UIS.InputBegan:Connect(function(i, gp)
	if gp then return end

	if i.KeyCode == Enum.KeyCode.E then -- listener to toggle build mode with E
		if buildloopconn or deleteloopconn then
			exitBuildMode()
		else
			enterBuildMode()
		end

	elseif buildloopconn then
		if i.KeyCode == Enum.KeyCode.R then -- rotate with R
			rotY += 90
		elseif i.KeyCode == Enum.KeyCode.X then -- next object with X
			index = index % #objectstbl + 1
			createPreview()
		elseif i.KeyCode == Enum.KeyCode.Z then -- previous object with Z
			index = (index - 2) % #objectstbl + 1
			createPreview()
		elseif i.KeyCode == Enum.KeyCode.V then -- listener to enter delete mode with V
			enterDeleteMode()
		end

	elseif deleteloopconn then
		if i.KeyCode == Enum.KeyCode.V then -- listener to exit delete mode with V
			exitDeleteMode()
		elseif i.UserInputType == Enum.UserInputType.MouseButton1 and currentSelection then -- listener to delete when MB1 is clicked
			re:FireServer("delete", currentSelection)
			currentSelection = nil
		end
	end
end)

UIS.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then -- debounce to prevent multiple object placements at once
		placeDebounce = false
	end
end)
