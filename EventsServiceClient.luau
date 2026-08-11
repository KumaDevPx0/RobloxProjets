--[[
	EventsServiceClient

	Client-side controller for live server events. Listens for event
	lifecycle packets (start / end / full state sync / next-random timer),
	keeps the event list UI, info panel, popup, and ambient "luck" icon
	effect in sync, and exposes an init entrypoint that requests the
	current event state from the server.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ContentProvider = game:GetService("ContentProvider")

local colorModules = require(game.ReplicatedStorage.ModulesFolder.ColorModules)
local EventsData = require(game.ReplicatedStorage.ModulesFolder.EventsData.EventsData)
local Packets = require(game.ReplicatedStorage.ModulesFolder.Packets)
local UILoader = require(game.ReplicatedStorage.ModulesFolder.UILoaderFolder.UILoader)

local player = Players.LocalPlayer

local LUCK_ICON_MIN_INTERVAL = 0.4
local LUCK_ICON_MAX_INTERVAL = 0.8
local NEXT_EVENT_FALLBACK_SECONDS = 300
local POPUP_VISIBLE_SECONDS = 4

export type ActiveEventEntry = {
	name: string,
	timeLeft: number,
}

--[[
	Maid

	Small connection/task janitor used to make sure we never leak
	RBXScriptConnections or running threads when UI elements are
	rebuilt or destroyed. This keeps long-lived listeners (like the
	countdown loops) from piling up across repeated events.
]]
local Maid = {}
Maid.__index = Maid

export type MaidType = typeof(setmetatable(
	{} :: {
		_tasks: { [string]: any },
	},
	Maid
))

function Maid.new(): MaidType
	local self = {
		_tasks = {},
	}
	setmetatable(self, Maid)
	return self
end

function Maid.give(self: MaidType, key: string, task_: any)
	self:clean(key)
	self._tasks[key] = task_
end

function Maid.clean(self: MaidType, key: string)
	local task_ = self._tasks[key]
	if not task_ then
		return
	end
	self._tasks[key] = nil

	if typeof(task_) == "RBXScriptConnection" then
		task_:Disconnect()
	elseif typeof(task_) == "thread" then
		-- Countdown/animation threads are expected to already be dead most
		-- of the time this fires, so a failed cancel is not an error.
		pcall(task.cancel, task_)
	elseif typeof(task_) == "Instance" then
		task_:Destroy()
	end
end

function Maid.destroy(self: MaidType)
	for key in pairs(self._tasks) do
		self:clean(key)
	end
end

local EventsServiceClient = {}

local activeEvents: { [string]: ActiveEventEntry } = {}
local slotMaids: { [string]: MaidType } = {}
local luckIconsRunning = false
local iconsThread: thread? = nil
local nextRandomCountdownThread: thread? = nil

local function getEventList()
	return UILoader.EventsFolder():FindFirstChild("EventList")
end

local function getInfoDisplay()
	return UILoader.EventsFolder():FindFirstChild("InfoDisplayMainFrame")
end

local function getEventPopup()
	return UILoader.EventsFolder():FindFirstChild("EventPopup")
end

local function getDeco()
	return UILoader.EventsFolder():FindFirstChild("Deco")
end

local function getNextEventsLabel()
	return UILoader.NextEvents()
end

local function getEventPreset(eventData): string?
	if eventData.ServerLuckBonus and eventData.ServerMoneyBonus then
		return "Cosmic"
	end
	if eventData.ServerRateBonus then
		if eventData.ServerRateBonus.Rainbow then
			return "Rainbow"
		end
		if eventData.ServerRateBonus.Diamond then
			return "Diamond"
		end
		if eventData.ServerRateBonus.Gold then
			return "Gold"
		end
		if eventData.ServerRateBonus.Shiny then
			return "Shiny"
		end
	end
	if eventData.ServerLuckBonus then
		return "Toxic"
	end
	if eventData.ServerSpeedBonus then
		return "Frost"
	end
	if eventData.ServerMoneyBonus then
		return "Celestial"
	end
	return nil
end

local function applyEventColor(label, eventId: string, property: string?)
	local data = EventsData[eventId]
	if not data or not label then
		return
	end
	local preset = getEventPreset(data)
	if not preset then
		return
	end
	colorModules.DailyRewardEffects(label, preset, property or "activeEffectsEvents")
end

local function isLuckEvent(eventId: string): boolean
	return eventId:find("Luck") ~= nil
end

local function hasActiveLuckEvent(): boolean
	for eventId in pairs(activeEvents) do
		if isLuckEvent(eventId) then
			return true
		end
	end
	return false
end

local function getActiveLuckNames(): { string }
	local names = {}
	for eventId in pairs(activeEvents) do
		if isLuckEvent(eventId) then
			table.insert(names, eventId)
		end
	end
	return names
end

local function spawnLuckIcon()
	local deco = getDeco()
	if not deco then
		return
	end
	local luckNames = getActiveLuckNames()
	if #luckNames == 0 then
		return
	end
	local luckName = luckNames[math.random(1, #luckNames)]

	-- Cloning can fail if the template was removed mid-session; that's not
	-- fatal to the ambient effect, so we just skip this spawn.
	local ok, icon = pcall(function()
		return script.LuckIcon:Clone()
	end)
	if not ok or not icon then
		return
	end

	icon.Image = EventsData[luckName].Icon
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.ZIndex = 20
	icon.BackgroundTransparency = 1

	local sizeScale = math.random(30, 70) / 1000
	icon.Size = UDim2.new(sizeScale, 0, sizeScale * 1.45, 0)
	icon.ScaleType = Enum.ScaleType.Fit

	local randomX = math.random(2, 98) / 100
	local randomDrift = math.random(-8, 8) / 100
	local duration = math.random(30, 60) / 10

	icon.Position = UDim2.new(randomX, 0, -0.08, 0)
	icon.ImageTransparency = math.random(0, 3) / 10
	icon.Parent = deco

	TweenService:Create(icon, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
		Position = UDim2.new(randomX + randomDrift, 0, 1.08, 0),
		Rotation = math.random(-45, 45),
		ImageTransparency = 0.1,
	}):Play()

	Debris:AddItem(icon, duration + 0.5)
end

local function startLuckIcons()
	if luckIconsRunning then
		return
	end
	local deco = getDeco()
	if not deco then
		return
	end

	-- Preload icon assets for every currently active luck event so the
	-- first few spawns don't pop in half-loaded.
	local luckNames = getActiveLuckNames()
	local iconIds = {}
	for _, eventId in ipairs(luckNames) do
		local data = EventsData[eventId]
		if data and data.Icon then
			table.insert(iconIds, data.Icon)
		end
	end
	if #iconIds > 0 then
		task.spawn(function()
			pcall(ContentProvider.PreloadAsync, ContentProvider, iconIds)
		end)
	end

	deco.Visible = true
	luckIconsRunning = true

	iconsThread = task.spawn(function()
		local nextSpawnAt = os.clock()
		while luckIconsRunning do
			if os.clock() >= nextSpawnAt then
				task.spawn(spawnLuckIcon)
				nextSpawnAt = os.clock() + math.random(LUCK_ICON_MIN_INTERVAL * 100, LUCK_ICON_MAX_INTERVAL * 100) / 100
			end
			RunService.Heartbeat:Wait()
		end
	end)
end

local function stopLuckIcons()
	luckIconsRunning = false
	if iconsThread then
		-- The loop checks luckIconsRunning every frame and exits on its
		-- own; cancel is just a safety net in case it's mid-yield.
		pcall(task.cancel, iconsThread)
		iconsThread = nil
	end

	local deco = getDeco()
	if deco then
		deco.Visible = false
		for _, child in ipairs(deco:GetChildren()) do
			if child:IsA("ImageLabel") then
				child:Destroy()
			end
		end
	end
end

local function formatTimeLeft(timeLeft: number): string
	if timeLeft < 0 then
		return "Active"
	end
	return string.format("%02d:%02d", math.floor(timeLeft / 60), timeLeft % 60)
end

local function updateEventSlot(eventId: string, timeLeft: number)
	local eventList = getEventList()
	if not eventList then
		return
	end
	local slot = eventList:FindFirstChild(eventId)
	if not slot then
		return
	end
	local timer = slot:FindFirstChild("Timer")
	if timer then
		timer.Text = formatTimeLeft(timeLeft)
	end
end

local function removeEventSlot(eventId: string)
	local eventList = getEventList()
	if not eventList then
		return
	end
	local slot = eventList:FindFirstChild(eventId)
	if not slot then
		return
	end

	local tween = TweenService:Create(slot, TweenInfo.new(0.3), { Size = UDim2.new(0, 0, 0, 0) })
	tween:Play()
	tween.Completed:Connect(function()
		if slot and slot.Parent then
			slot:Destroy()
		end
	end)
end

local function startCountdown(eventId: string, timeLeft: number)
	if type(timeLeft) ~= "number" then
		return
	end

	local maid = slotMaids[eventId]
	if not maid then
		maid = Maid.new()
		slotMaids[eventId] = maid
	end

	if timeLeft < 0 then
		updateEventSlot(eventId, -1)
		return
	end

	-- Drive the countdown off wall-clock time rather than accumulating
	-- task.wait(1) drift, so long-running events stay accurate.
	local countdownThread = task.spawn(function()
		local endTime = os.clock() + timeLeft
		while true do
			local remaining = math.ceil(endTime - os.clock())
			if remaining <= 0 then
				updateEventSlot(eventId, 0)
				break
			end
			updateEventSlot(eventId, remaining)
			task.wait(1)
		end
	end)
	maid:give("countdown", countdownThread)
end

local function startNextRandomTimer(timeLeft: number)
	if nextRandomCountdownThread then
		pcall(task.cancel, nextRandomCountdownThread)
		nextRandomCountdownThread = nil
	end

	nextRandomCountdownThread = task.spawn(function()
		local remaining = math.max(1, timeLeft)
		local label = getNextEventsLabel()
		if label then
			label.Visible = true
		end

		while true do
			label = getNextEventsLabel()
			if label then
				label.Text = string.format("Next Event: %s", formatTimeLeft(remaining))
			end
			task.wait(1)
			remaining -= 1
			if remaining <= 0 then
				remaining = NEXT_EVENT_FALLBACK_SECONDS
			end
		end
	end)
end

local function addEventSlot(eventId: string, name: string, timeLeft: number)
	local data = EventsData[eventId]
	if not data then
		return
	end
	local eventList = getEventList()
	if not eventList then
		return
	end

	local maid = Maid.new()
	slotMaids[eventId] = maid

	local slot = script.EventSlotTemplate:Clone()
	slot.Name = eventId

	local icon = slot:FindFirstChild("Icon")
	local timer = slot:FindFirstChild("Timer")
	if icon and data.Icon then
		icon.Image = data.Icon
	end
	if timer then
		timer.Text = formatTimeLeft(timeLeft)
	end
	slot.Parent = eventList
	maid:give("slot", slot)

	local infoDisplayRoot = getInfoDisplay()
	if infoDisplayRoot then
		local infoDisplayFrame = infoDisplayRoot:FindFirstChild("InfoDisplayFrame")
		local header = infoDisplayFrame and infoDisplayFrame:FindFirstChild("Header")
		local body = infoDisplayFrame and infoDisplayFrame:FindFirstChild("Body")
		local nameLabel = header and header:FindFirstChild("NameLabel")
		local imageLabel = header and header:FindFirstChild("Image")
		local rarityOrTime = header and header:FindFirstChild("RarityOrTime")
		local itemFrame = body and body:FindFirstChild("ItemFrame")
		local description = itemFrame and itemFrame:FindFirstChild("Description")

		local enterConnection = slot.HoverButton.MouseEnter:Connect(function()
			colorModules.ClearEffects("activeEffectsEvents")
			if imageLabel then
				imageLabel.Image = data.Icon
			end
			if nameLabel then
				nameLabel.Text = data.Name
				applyEventColor(nameLabel, eventId)
			end
			if description then
				description.Text = data.Description
			end
			if rarityOrTime then
				rarityOrTime.Text = data.Rarity or ""
				colorModules.applyEffect(rarityOrTime, data.Rarity, true, "activeEffectsEvents")
			end

			infoDisplayRoot.Visible = false
			task.defer(function()
				local inset = GuiService:GetGuiInset()
				local slotPos = slot.AbsolutePosition
				local parentPos = infoDisplayRoot.Parent.Parent.Parent.AbsolutePosition
				local dispSize = infoDisplayRoot.AbsoluteSize
				infoDisplayRoot.Position = UDim2.new(
					0,
					slotPos.X - parentPos.X + 25,
					0,
					slotPos.Y - parentPos.Y - dispSize.Y + 50 - inset.Y
				)
				infoDisplayRoot.Visible = true
			end)
		end)

		local leaveConnection = slot.HoverButton.MouseLeave:Connect(function()
			colorModules.ClearEffects("activeEffectsEvents")
			if nameLabel then
				nameLabel.Text = ""
			end
			if description then
				description.Text = ""
			end
			infoDisplayRoot.Visible = false
		end)

		maid:give("enterConnection", enterConnection)
		maid:give("leaveConnection", leaveConnection)
	end

	startCountdown(eventId, timeLeft)
	if isLuckEvent(eventId) then
		startLuckIcons()
	end
end

local function playEventSound()
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://6042053626"
	sound.Volume = 0.8
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 5)
end

local function showPopup(name: string, eventId: string)
	local popup = getEventPopup()
	if not popup then
		return
	end

	local nameLabel = popup:FindFirstChild("EventName")
	if nameLabel then
		nameLabel.Text = name .. " is now active!"
		colorModules.ClearEffects("activeEffectsEventsPopUp")
		applyEventColor(nameLabel, eventId, "activeEffectsEventsPopUp")
	end

	popup.Visible = true
	popup.Position = UDim2.new(0.5, 0, -0.1, 0)
	playEventSound()

	TweenService:Create(popup, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0.2, 0),
	}):Play()

	task.delay(POPUP_VISIBLE_SECONDS, function()
		TweenService:Create(popup, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, -0.1, 0),
		}):Play()
		task.delay(0.3, function()
			colorModules.ClearEffects("activeEffectsEventsPopUp")
			popup.Visible = false
		end)
	end)
end

local function handleEventEnd(eventId: string)
	activeEvents[eventId] = nil

	local maid = slotMaids[eventId]
	if maid then
		maid:destroy()
		slotMaids[eventId] = nil
	end

	if isLuckEvent(eventId) and not hasActiveLuckEvent() then
		stopLuckIcons()
	end

	removeEventSlot(eventId)
end

Packets.Event_Start.listen(function(data)
	activeEvents[data.EventId] = { name = data.Name, timeLeft = data.Duration }
	addEventSlot(data.EventId, data.Name, data.Duration)
	showPopup(data.Name, data.EventId)
	if data.NextEventIn then
		startNextRandomTimer(data.NextEventIn)
	end
end)

Packets.Event_End.listen(function(data)
	handleEventEnd(data.EventId)
	local infoDisplay = getInfoDisplay()
	if infoDisplay then
		infoDisplay.Visible = false
	end
end)

Packets.Event_State.listen(function(data)
	for _, event in ipairs(data) do
		activeEvents[event.EventId] = { name = event.Name, timeLeft = event.TimeLeft }
		local eventList = getEventList()
		if eventList then
			if not eventList:FindFirstChild(event.EventId) then
				addEventSlot(event.EventId, event.Name, event.TimeLeft)
			else
				startCountdown(event.EventId, event.TimeLeft)
			end
		end
	end
end)

Packets.Event_NextRandom.listen(function(data)
	startNextRandomTimer(data)
end)

function EventsServiceClient.init()
	Packets.Event_Request.send({})
end

return EventsServiceClient
