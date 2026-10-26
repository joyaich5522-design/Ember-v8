--[[
	Ember -- a floating-dock UI for the UAI agent core.

	Layout (nothing like a sidebar + window):
	  * a small draggable dock pill at the bottom: Chat / Menu / Stop
	  * the chat slides up as a sheet from behind the dock
	  * settings live in a drawer that slides in from the right edge
	  * tool calls collapse into one "Activity" row per turn

	The UI never touches the agent directly. It only talks to a `core` table,
	so you wire it once (see GLUE at the bottom) and the rest is self-contained.

	core = {
		send     = function(text) end,
		abort    = function() end,
		newChat  = function() end,
		onEvent  = function(handler) return disconnect end,  -- handler(ev) gets session events
		modes    = function() return { {id=, label=, hint=}, ... } end,
		getMode  = function() return id end,
		setMode  = function(id) end,
		groups   = function() return { {id=, label=, total=, enabled=}, ... } end,
		setGroup = function(id, enabled) end,
	}
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local T = {
	bg = Color3.fromRGB(24, 26, 43),
	panel = Color3.fromRGB(32, 35, 58),
	raised = Color3.fromRGB(43, 47, 77),
	line = Color3.fromRGB(62, 67, 104),
	text = Color3.fromRGB(233, 230, 221),
	dim = Color3.fromRGB(142, 147, 176),
	accent = Color3.fromRGB(143, 211, 182),
	accentText = Color3.fromRGB(20, 40, 33),
	warn = Color3.fromRGB(242, 182, 109),
	bad = Color3.fromRGB(229, 124, 124),
	font = Enum.Font.Nunito,
	fontBold = Enum.Font.GothamBold,
}

local function make(class, props, children)
	local inst = Instance.new(class)
	local parent
	for key, value in pairs(props or {}) do
		if key == "Parent" then parent = value else inst[key] = value end
	end
	for _, child in ipairs(children or {}) do child.Parent = inst end
	if parent then inst.Parent = parent end
	return inst
end

local function corner(radius)
	return make("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function outline(color, thickness)
	return make("UIStroke", {
		Color = color, Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function padding(top, side)
	return make("UIPadding", {
		PaddingTop = UDim.new(0, top), PaddingBottom = UDim.new(0, top),
		PaddingLeft = UDim.new(0, side or top), PaddingRight = UDim.new(0, side or top),
	})
end

local function text(props)
	local base = {
		BackgroundTransparency = 1, Font = T.font, TextColor3 = T.text, TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true, RichText = false, BorderSizePixel = 0,
	}
	for key, value in pairs(props) do base[key] = value end
	return make("TextLabel", base)
end

local function button(props, children)
	local base = {
		AutoButtonColor = false, BackgroundColor3 = T.raised, BorderSizePixel = 0,
		Font = T.font, TextColor3 = T.text, TextSize = 15,
	}
	for key, value in pairs(props) do base[key] = value end
	local btn = make("TextButton", base, children)
	local rest = btn.BackgroundColor3
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = rest:Lerp(Color3.new(1, 1, 1), 0.12) }):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = rest }):Play()
	end)
	return btn
end

local function shorten(value, limit)
	value = tostring(value or "")
	if #value <= limit then return value end
	return value:sub(1, limit - 1) .. "..."
end

local function guiParent()
	local ok, hui = pcall(function() return gethui() end)
	if ok and hui then return hui end
	local okCore, core = pcall(function()
		local service = game:GetService("CoreGui")
		local probe = Instance.new("Folder")
		probe.Parent = service -- errors in a normal LocalScript, which has no CoreGui access
		probe:Destroy()
		return service
	end)
	if okCore and core then return core end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

local function Ember(core)
	local screen = make("ScreenGui", {
		Name = "Ember", ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999,
	})

	local connections, busy, order = {}, false, 0
	local activity -- the Activity row for the turn in progress

	---------------------------------------------------------------- sheet
	local SHEET_OPEN = UDim2.new(0.5, 0, 1, -84)
	local SHEET_SHUT = UDim2.new(0.5, 0, 1.8, 0)

	local sheet = make("Frame", {
		Name = "Sheet", AnchorPoint = Vector2.new(0.5, 1), Position = SHEET_SHUT,
		Size = UDim2.new(0.94, 0, 0.58, 0), BackgroundColor3 = T.bg, Visible = false,
		BorderSizePixel = 0, Parent = screen,
	}, {
		corner(20), outline(T.line, 1),
		make("UISizeConstraint", { MaxSize = Vector2.new(580, 600), MinSize = Vector2.new(260, 240) }),
	})

	local header = make("Frame", {
		Size = UDim2.new(1, 0, 0, 46), BackgroundTransparency = 1, Parent = sheet,
	})
	local titleLabel = text({
		Text = "Agent", Font = T.fontBold, TextSize = 17, Position = UDim2.new(0, 18, 0, 0),
		Size = UDim2.new(0.62, 0, 1, 0), TextYAlignment = Enum.TextYAlignment.Center,
		RichText = true, TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
	})
	local statusLabel = text({
		Text = "Ready", TextSize = 14, TextColor3 = T.dim, TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 0),
		Size = UDim2.new(0.3, 0, 1, 0), TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
	})

	-- "Agent  gpt-5": the model in use sits beside the title so you always see
	-- which one is answering.
	local function refreshTitle()
		local info = core.connection and core.connection.get() or nil
		local label = info and info.model or nil
		if label == "auto" and info.active then label = "auto / " .. info.active end
		if label and label ~= "" then
			titleLabel.Text = 'Agent  <font size="13" color="#8E93B0">' .. shorten(label, 34) .. "</font>"
		else
			titleLabel.Text = "Agent"
		end
	end
	refreshTitle()
	make("Frame", {
		Size = UDim2.new(1, -28, 0, 1), Position = UDim2.new(0, 14, 1, -1),
		BackgroundColor3 = T.line, BorderSizePixel = 0, Parent = header,
	})

	local scroll = make("ScrollingFrame", {
		Position = UDim2.new(0, 0, 0, 48), Size = UDim2.new(1, 0, 1, -48 - 64),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
		ScrollBarImageColor3 = T.line, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = sheet,
	}, {
		padding(12, 16),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12) }),
	})

	-- The canvas grows a frame after a message is added, so a one-off scroll lands
	-- short and hides the newest reply. Instead, follow the canvas while the user
	-- is at the bottom, and stop following once they scroll up to read.
	local stick = true
	local jump
	local function pin()
		scroll.CanvasPosition = Vector2.new(0,
			math.max(scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y, 0))
	end
	local function toBottom()
		stick = true
		task.defer(pin)
	end
	scroll:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(function()
		if stick then pin() end
	end)
	scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local gap = scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y - scroll.CanvasPosition.Y
		stick = gap < 24
		if jump then jump.Visible = not stick end
	end)
	jump = button({
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -70), Size = UDim2.fromOffset(150, 30),
		BackgroundColor3 = T.raised, Text = "Jump to latest", TextSize = 13, Font = T.fontBold,
		Visible = false, ZIndex = 4, Parent = sheet,
	}, { corner(15), outline(T.line, 1) })
	jump.MouseButton1Click:Connect(function() toBottom() end)

	local function nextOrder()
		order = order + 1
		return order
	end

	local function addUser(body)
		local wrap = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = scroll,
		})
		make("TextLabel", {
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0.82, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = T.raised, BorderSizePixel = 0, Font = T.font, TextSize = 16,
			TextColor3 = T.text, TextWrapped = true, Text = body,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = wrap,
		}, { corner(14), padding(10, 14) })
		toBottom()
	end

	local function addReply(body)
		local wrap = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = scroll,
		})
		make("Frame", {
			Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = T.accent, BorderSizePixel = 0, Parent = wrap,
		}, { corner(2) })
		local column = make("Frame", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -14, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, Parent = wrap,
		}, { make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }) })
		text({
			Text = body, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			TextSelectable = true, LayoutOrder = 1, Parent = column,
		})

		-- A reply that carries a fenced script gets a one-tap copy.
		local clip = setclipboard or toclipboard
		local code = body:match("```[%w_]*\r?\n(.-)```")
		if code and clip then
			local copy = button({
				Text = "Copy script", Size = UDim2.new(0, 0, 0, 30), AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = T.raised, TextSize = 13, Font = T.fontBold, LayoutOrder = 2, Parent = column,
			}, { corner(15), padding(0, 14) })
			copy.MouseButton1Click:Connect(function()
				pcall(clip, code)
				copy.Text = "Copied"
				task.delay(1.5, function() copy.Text = "Copy script" end)
			end)
		end
		toBottom()
	end

	local function addNote(body, color)
		local wrap = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = scroll,
		})
		text({
			Text = body, TextSize = 14, TextColor3 = color or T.dim,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			TextXAlignment = Enum.TextXAlignment.Center, Parent = wrap,
		})
		toBottom()
	end

	---------------------------------------------------------------- activity
	local function newActivity()
		local row = make("Frame", {
			BackgroundColor3 = T.panel, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), BorderSizePixel = 0, Parent = scroll,
		}, {
			corner(10),
			make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
		})
		local head = button({
			Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, Text = "",
			LayoutOrder = 0, Parent = row,
		})
		local title = text({
			Text = "Working", TextSize = 14, TextColor3 = T.dim, Position = UDim2.new(0, 12, 0, 0),
			Size = UDim2.new(1, -24, 1, 0), TextYAlignment = Enum.TextYAlignment.Center, Parent = head,
		})
		local list = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false, LayoutOrder = 1, Parent = row,
		}, {
			padding(4, 12),
			make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
		})
		local state = { rows = {}, count = 0, failed = 0, list = list, title = title }
		local function retitle()
			local arrow = list.Visible and "Hide" or "Show"
			local what = state.count == 1 and "1 step" or (state.count .. " steps")
			local tail = state.failed > 0 and (", " .. state.failed .. " failed") or ""
			title.Text = what .. tail .. "  (" .. arrow:lower() .. ")"
		end
		head.MouseButton1Click:Connect(function()
			list.Visible = not list.Visible
			retitle()
		end)
		state.retitle = retitle
		return state
	end

	local function addTool(id, name)
		if not activity then activity = newActivity() end
		activity.count = activity.count + 1
		local line = text({
			Text = "...  " .. tostring(name), TextSize = 14, TextColor3 = T.dim,
			Size = UDim2.new(1, 0, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = activity.count, Parent = activity.list,
		})
		activity.rows[tostring(id)] = { line = line, name = tostring(name) }
		activity.retitle()
		toBottom()
	end

	local function finishTool(id, ok)
		if not activity then return end
		local entry = activity.rows[tostring(id)]
		if not entry then return end
		entry.line.Text = (ok and "ok   " or "fail ") .. entry.name
		entry.line.TextColor3 = ok and T.accent or T.bad
		if not ok then activity.failed = activity.failed + 1 end
		activity.retitle()
	end

	---------------------------------------------------------------- permission card
	local function addPermission(ev)
		local card = make("Frame", {
			BackgroundColor3 = T.panel, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(), BorderSizePixel = 0, Parent = scroll,
		}, {
			corner(12), outline(T.warn, 1), padding(12),
			make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }),
		})
		text({
			Text = "Allow " .. tostring(ev.name) .. "?", Font = T.fontBold, TextSize = 16,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = card,
		})
		local ok, encoded = pcall(function() return HttpService:JSONEncode(ev.args or {}) end)
		text({
			Text = shorten(ok and encoded or "", 220), TextSize = 13, TextColor3 = T.dim,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = card,
		})
		local actions = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 3, Parent = card,
		}, { make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}) })

		local function settle(allowed, remember, label)
			actions:Destroy()
			text({
				Text = label, TextSize = 14, TextColor3 = allowed and T.accent or T.bad,
				Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Parent = card,
			})
			if type(ev.resolve) == "function" then pcall(ev.resolve, allowed, remember) end
		end
		local function choice(label, fill, textColor, order, handler)
			local b = button({
				Text = label, BackgroundColor3 = fill, TextColor3 = textColor, Font = T.fontBold,
				Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = order, Parent = actions,
			}, { corner(8), padding(0, 14) })
			b.MouseButton1Click:Connect(handler)
		end
		choice("Allow", T.accent, T.accentText, 1, function() settle(true, false, "Allowed") end)
		choice("Always allow", T.raised, T.text, 2, function() settle(true, true, "Always allowed") end)
		choice("Deny", T.raised, T.bad, 3, function() settle(false, false, "Denied") end)
		toBottom()
	end

	---------------------------------------------------------------- helper agents
	-- The core can delegate work to subagents and reports them as subagent:* events.
	-- Field names beyond `kind` and `text` are read defensively, since I have not
	-- seen that module: the card still works if some of them are missing.
	local agents = {}

	local function agentCard(ev)
		local key = tostring(ev.callId or ev.agentId or ev.id or "agent")
		local card = agents[key]
		if card then return card end
		local frame = make("Frame", {
			BackgroundColor3 = T.panel, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(), BorderSizePixel = 0, Parent = scroll,
		}, {
			corner(12), outline(T.line, 1), padding(10, 12),
			make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
		})
		card = { tools = 0, frame = frame }
		card.title = text({
			Text = "Helper agent", Font = T.fontBold, TextSize = 15, LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = frame,
		})
		card.status = text({
			Text = "Working", TextSize = 13, TextColor3 = T.warn, LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 16), Parent = frame,
		})
		card.body = text({
			Text = "", TextSize = 13, TextColor3 = T.dim, LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = frame,
		})
		agents[key] = card
		return card
	end

	local function renderAgent(card)
		local lines = {}
		if card.tools > 0 then
			lines[#lines + 1] = card.tools == 1 and "1 tool call" or (card.tools .. " tool calls")
		end
		if card.last then lines[#lines + 1] = card.last end
		card.body.Text = table.concat(lines, "\n")
		toBottom()
	end

	local function handleAgent(kind, ev)
		local card = agentCard(ev)
		if kind == "subagent:start" then
			local task = ev.task or ev.title or ev.description or ev.name
			if task then card.title.Text = "Helper: " .. shorten(task, 90) end
			card.status.Text = "Working"
		elseif kind == "subagent:tool" then
			card.tools = card.tools + 1
			card.last = "Running " .. tostring(ev.name or ev.tool or "a tool")
		elseif kind == "subagent:text" then
			if ev.text and ev.text ~= "" then card.last = shorten(ev.text, 160) end
		elseif kind == "subagent:done" then
			local failed = ev.error ~= nil or ev.ok == false
			card.status.Text = failed and "Failed" or "Done"
			card.status.TextColor3 = failed and T.bad or T.accent
			if failed and ev.error then card.last = shorten(ev.error, 160) end
		end
		renderAgent(card)
	end

	---------------------------------------------------------------- composer
	local composer = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.new(1, -24, 0, 46), BackgroundColor3 = T.panel, BorderSizePixel = 0, Parent = sheet,
	}, { corner(23), outline(T.line, 1) })

	local input = make("TextBox", {
		BackgroundTransparency = 1, Position = UDim2.new(0, 18, 0, 0), Size = UDim2.new(1, -72, 1, 0),
		Font = T.font, TextSize = 16, TextColor3 = T.text, PlaceholderText = "Tell the agent what to do",
		PlaceholderColor3 = T.dim, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
		Text = "", Parent = composer,
	})
	local sendButton = button({
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = T.accent, Text = "Go", TextColor3 = T.accentText, Font = T.fontBold, TextSize = 14,
		Parent = composer,
	}, { corner(17) })

	local function submit()
		local body = input.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if body == "" then return end
		local ok, reason = core.send(body)
		if ok == false then
			addNote(tostring(reason or "The agent could not take that message."), T.warn)
			return
		end
		input.Text = ""
	end
	sendButton.MouseButton1Click:Connect(submit)
	input.FocusLost:Connect(function(enter) if enter then submit() end end)

	---------------------------------------------------------------- drawer
	local DRAWER_OPEN = UDim2.new(1, 0, 0, 0)
	local DRAWER_SHUT = UDim2.new(1, 300, 0, 0)

	local drawer = make("Frame", {
		AnchorPoint = Vector2.new(1, 0), Position = DRAWER_SHUT, Size = UDim2.new(0, 280, 1, 0),
		BackgroundColor3 = T.bg, BorderSizePixel = 0, Visible = false, ZIndex = 5, Parent = screen,
	}, { outline(T.line, 1) })

	local drawerList = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 3, ScrollBarImageColor3 = T.line, AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(), ZIndex = 5, Parent = drawer,
	}, {
		padding(16),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }),
	})

	local modelChoices, modelNote = nil, nil
	local setSheet, setDrawer -- assigned below the dock; the drawer needs them earlier

	local function clearTranscript()
		for _, child in ipairs(scroll:GetChildren()) do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		activity = nil
		agents = {}
	end

	-- Rebuilds a saved chat on screen from the items the core hands back.
	local function replayChat(items)
		clearTranscript()
		for index, item in ipairs(items) do
			if item.kind == "user" then
				addUser(item.text)
			elseif item.kind == "assistant" then
				addReply(item.text)
			elseif item.kind == "tools" then
				activity = nil
				for step, name in ipairs(item.names) do
					local id = "h" .. index .. "_" .. step
					addTool(id, name)
					finishTool(id, true)
				end
				activity = nil
			end
		end
		toBottom()
	end

	local function refreshDrawer()
		for _, child in ipairs(drawerList:GetChildren()) do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		local n = 0
		local function add(inst) n = n + 1 inst.LayoutOrder = n inst.ZIndex = 5 inst.Parent = drawerList return inst end

		add(text({ Text = "Menu", Font = T.fontBold, TextSize = 20, Size = UDim2.new(1, 0, 0, 30) }))

		local fresh = add(button({
			Text = "Start a new chat", Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = T.accent,
			TextColor3 = T.accentText, Font = T.fontBold,
		}, { corner(10) }))
		fresh.MouseButton1Click:Connect(function()
			core.newChat()
			for _, child in ipairs(scroll:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			activity = nil
		end)

		if core.history then
			add(text({ Text = "Past chats", Font = T.fontBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 30),
				TextYAlignment = Enum.TextYAlignment.Bottom }))
			local list = core.history()
			if #list == 0 then
				add(text({ Text = "Nothing saved yet. Chats are saved as you talk.", TextSize = 13,
					TextColor3 = T.dim, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }))
			end
			-- Grouped by the game each chat happened in.
			local byGame, gameOrder = {}, {}
			for index, chat in ipairs(list) do
				if index > 25 then break end
				if not byGame[chat.place] then
					byGame[chat.place] = {}
					gameOrder[#gameOrder + 1] = chat.place
				end
				table.insert(byGame[chat.place], chat)
			end
			for _, place in ipairs(gameOrder) do
				add(text({ Text = place, TextSize = 13, TextColor3 = T.dim, Size = UDim2.new(1, 0, 0, 22),
					TextYAlignment = Enum.TextYAlignment.Bottom, TextTruncate = Enum.TextTruncate.AtEnd }))
				for _, chat in ipairs(byGame[place]) do
					local row = add(make("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1 }))
					local open = button({
						Text = chat.title, Size = UDim2.new(1, -42, 1, 0), TextSize = 14, ZIndex = 5, Parent = row,
						BackgroundColor3 = chat.current and T.raised or T.panel,
						TextColor3 = chat.current and T.accent or T.text,
						TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
					}, { corner(8), padding(0, 12) })
					local remove = button({
						Text = "x", Size = UDim2.fromOffset(36, 36), AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.new(1, 0, 0, 0), BackgroundColor3 = T.panel, TextColor3 = T.dim,
						ZIndex = 5, Parent = row,
					}, { corner(8) })
					open.MouseButton1Click:Connect(function()
						local items, why = core.openChat(chat.id)
						if not items then
							addNote(why or "Could not open that chat.", T.warn)
							return
						end
						replayChat(items)
						setDrawer(false)
						setSheet(true)
					end)
					remove.MouseButton1Click:Connect(function()
						if core.deleteChat(chat.id) then clearTranscript() end
						refreshDrawer()
					end)
				end
			end
		end

		if core.scan then
			local info = core.scan.get()
			add(text({ Text = "Game scan", Font = T.fontBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 30),
				TextYAlignment = Enum.TextYAlignment.Bottom }))
			add(text({
				Text = info.name .. "\n" .. (info.summary or "Not scanned yet."), TextSize = 13, TextColor3 = T.dim,
				Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			}))
			local toggle = add(button({
				Text = "Scan when a chat starts: " .. (info.enabled and "On" or "Off"),
				Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = T.panel,
			}, { corner(10) }))
			toggle.MouseButton1Click:Connect(function()
				core.scan.setEnabled(not info.enabled)
				refreshDrawer()
			end)
			local now = add(button({
				Text = "Scan this game now", Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = T.raised,
				Font = T.fontBold,
			}, { corner(10) }))
			now.MouseButton1Click:Connect(function()
				now.Text = "Scanning..."
				task.spawn(function()
					core.scan.now()
					refreshDrawer()
				end)
			end)
		end

		if core.connection then
			local info = core.connection.get()
			add(text({ Text = "Connection", Font = T.fontBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 30),
				TextYAlignment = Enum.TextYAlignment.Bottom }))

			local providerRow = add(make("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1 }, {
				make("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			}))
			for position, option in ipairs({
				{ id = "anthropic", label = "Claude" }, { id = "gemini", label = "Gemini" },
				{ id = "openai", label = "Other" },
			}) do
				local picked = info.provider == option.id
				local choice = button({
					Text = option.label, Size = UDim2.new(1 / 3, -6, 1, 0), TextSize = 14, Font = T.fontBold,
					LayoutOrder = position, ZIndex = 5, Parent = providerRow,
					BackgroundColor3 = picked and T.accent or T.panel, TextColor3 = picked and T.accentText or T.text,
				}, { corner(10) })
				choice.MouseButton1Click:Connect(function()
					core.connection.set("provider", option.id)
					modelChoices, modelNote = nil, nil
					refreshTitle()
					refreshDrawer()
				end)
			end
			if info.provider == "anthropic" then
				add(text({
					Text = "Use your own key from console.anthropic.com. Requests go straight to Anthropic.",
					TextSize = 13, TextColor3 = T.dim, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				}))
			end

			if info.provider == "gemini" then
				add(text({
					Text = "Free key from aistudio.google.com. Ember always uses Google's correct address for this one.",
					TextSize = 13, TextColor3 = T.dim, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				}))
			end

			local function field(label, value, placeholder, onSave)
				add(text({ Text = label, TextSize = 13, TextColor3 = T.dim, Size = UDim2.new(1, 0, 0, 16) }))
				local box = add(make("TextBox", {
					Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = T.panel, BorderSizePixel = 0,
					Font = T.font, TextSize = 14, TextColor3 = T.text, PlaceholderText = placeholder,
					PlaceholderColor3 = T.dim, Text = value, ClearTextOnFocus = false,
					TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
				}, { corner(10), padding(0, 12) }))
				box.FocusLost:Connect(function() onSave(box.Text) end)
			end

			field("Base URL", info.baseUrl, "https://.../v1", function(value)
				core.connection.set("baseUrl", value)
			end)
			field("API key", "", info.hasKey and ("Saved, ends in " .. info.keyTail) or "Paste your key", function(value)
				if value ~= "" then
					core.connection.set("apiKey", value)
					task.defer(refreshDrawer)
				end
			end)
			field("Model (type auto to let it choose)", info.model, "Model id", function(value)
				core.connection.set("model", value)
				refreshTitle()
				task.defer(refreshDrawer)
			end)

			if info.model == "auto" then
				add(text({
					Text = "Auto picks per message: quick for chat and lookups, standard for scripts, deep for long or hard jobs. Set which model each tier uses:",
					TextSize = 13, TextColor3 = T.dim, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				}))
				for _, tier in ipairs({ "quick", "standard", "deep" }) do
					field("Auto: " .. tier, info.tiers[tier] or "", "Model id", function(value)
						core.connection.set("tier_" .. tier, value)
					end)
				end
			end

			local load = add(button({
				Text = "Load models from provider", Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = T.raised,
				Font = T.fontBold,
			}, { corner(10) }))
			load.MouseButton1Click:Connect(function()
				load.Text = "Loading..."
				task.spawn(function()
					local list, err = core.connection.fetchModels()
					modelChoices = list
					modelNote = err and ("Could not load models: " .. shorten(err, 120)) or nil
					refreshDrawer()
				end)
			end)
			if modelNote then
				add(text({ Text = modelNote, TextSize = 13, TextColor3 = T.bad, Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y }))
			end

			local function modelRows(title, ids)
				if not ids or #ids == 0 then return end
				add(text({ Text = title, TextSize = 13, TextColor3 = T.dim, Size = UDim2.new(1, 0, 0, 22),
					TextYAlignment = Enum.TextYAlignment.Bottom }))
				for _, id in ipairs(ids) do
					local picked = id == info.model
					local row = add(button({
						Text = tostring(id), Size = UDim2.new(1, 0, 0, 34), TextSize = 14,
						BackgroundColor3 = picked and T.raised or T.panel, TextColor3 = picked and T.accent or T.text,
						TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
					}, { corner(8), padding(0, 12) }))
					row.MouseButton1Click:Connect(function()
						core.connection.set("model", id)
						refreshTitle()
						refreshDrawer()
					end)
				end
			end
			local picks = { "auto" }
			for _, id in ipairs(info.recent) do
				if id ~= "auto" then picks[#picks + 1] = id end
			end
			modelRows("Models", picks)
			modelRows("Available from your provider", modelChoices)
		end

		add(text({ Text = "What the agent may do", Font = T.fontBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 30),
			TextYAlignment = Enum.TextYAlignment.Bottom }))
		local current = core.getMode()
		for _, mode in ipairs(core.modes()) do
			local picked = mode.id == current
			local row = add(button({
				Text = "", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = picked and T.raised or T.panel,
			}, { corner(10), padding(10, 12), picked and outline(T.accent, 1) or nil }))
			text({ Text = mode.label, Font = T.fontBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 18),
				TextColor3 = picked and T.accent or T.text, ZIndex = 6, Parent = row })
			text({ Text = mode.hint or "", TextSize = 13, TextColor3 = T.dim, Position = UDim2.new(0, 0, 0, 20),
				Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 6, Parent = row })
			row.MouseButton1Click:Connect(function()
				core.setMode(mode.id)
				refreshDrawer()
			end)
		end

		add(text({ Text = "Tool groups", Font = T.fontBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 30),
			TextYAlignment = Enum.TextYAlignment.Bottom }))
		for _, group in ipairs(core.groups()) do
			local row = add(button({
				Text = "", Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = T.panel,
			}, { corner(10) }))
			text({ Text = group.label, TextSize = 15, TextColor3 = group.enabled and T.text or T.dim,
				Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -90, 1, 0),
				TextYAlignment = Enum.TextYAlignment.Center, ZIndex = 6, Parent = row })
			text({ Text = group.enabled and "On" or "Off", TextSize = 14, Font = T.fontBold,
				TextColor3 = group.enabled and T.accent or T.dim, TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.new(0, 60, 1, 0),
				TextYAlignment = Enum.TextYAlignment.Center, ZIndex = 6, Parent = row })
			row.MouseButton1Click:Connect(function()
				core.setGroup(group.id, not group.enabled)
				refreshDrawer()
			end)
		end
	end

	---------------------------------------------------------------- dock
	local dock = make("Frame", {
		Name = "Dock", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.new(0, 0, 0, 52), AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = T.bg, BorderSizePixel = 0, ZIndex = 8, Parent = screen,
	}, {
		corner(26), outline(T.line, 1),
		padding(7, 10),
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
			VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	local grip = make("Frame", {
		Size = UDim2.fromOffset(14, 30), BackgroundTransparency = 1, LayoutOrder = 0, ZIndex = 9, Parent = dock,
	}, {
		make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(4, 22), BackgroundColor3 = T.line, BorderSizePixel = 0, ZIndex = 9 }, { corner(2) }),
	})

	local function dockButton(label, order, fill, color)
		return button({
			Text = label, Size = UDim2.new(0, 0, 0, 38), AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = fill or T.panel, TextColor3 = color or T.text, Font = T.fontBold,
			LayoutOrder = order, ZIndex = 9, Parent = dock,
		}, { corner(19), padding(0, 16) })
	end

	local chatButton = dockButton("Chat", 1, T.accent, T.accentText)
	local menuButton = dockButton("Menu", 2)
	local stopButton = dockButton("Stop", 3, T.bad, Color3.fromRGB(45, 18, 18))
	stopButton.Visible = false

	local sheetOpen, drawerOpen = false, false

	function setSheet(open)
		sheetOpen = open
		if open then sheet.Visible = true end
		local tween = TweenService:Create(sheet,
			TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Position = open and SHEET_OPEN or SHEET_SHUT })
		tween.Completed:Connect(function() if not sheetOpen then sheet.Visible = false end end)
		tween:Play()
		chatButton.Text = open and "Hide" or "Chat"
		if open then toBottom() end
	end

	function setDrawer(open)
		drawerOpen = open
		if open then
			refreshDrawer()
			drawer.Visible = true
		end
		local tween = TweenService:Create(drawer,
			TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Position = open and DRAWER_OPEN or DRAWER_SHUT })
		tween.Completed:Connect(function() if not drawerOpen then drawer.Visible = false end end)
		tween:Play()
		menuButton.Text = open and "Close" or "Menu"
	end

	chatButton.MouseButton1Click:Connect(function() setSheet(not sheetOpen) end)
	menuButton.MouseButton1Click:Connect(function() setDrawer(not drawerOpen) end)
	stopButton.MouseButton1Click:Connect(function() core.abort() end)

	-- Drag the dock by its grip.
	local dragging, dragStart, dockStart = false, nil, nil
	grip.InputBegan:Connect(function(inputObject)
		local kind = inputObject.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			dragging, dragStart, dockStart = true, inputObject.Position, dock.Position
			inputObject.Changed:Connect(function()
				if inputObject.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	table.insert(connections, UserInputService.InputChanged:Connect(function(inputObject)
		local kind = inputObject.UserInputType
		if dragging and (kind == Enum.UserInputType.MouseMovement or kind == Enum.UserInputType.Touch) then
			local delta = inputObject.Position - dragStart
			dock.Position = UDim2.new(dockStart.X.Scale, dockStart.X.Offset + delta.X,
				dockStart.Y.Scale, dockStart.Y.Offset + delta.Y)
		end
	end))

	---------------------------------------------------------------- events
	local function setBusy(value)
		busy = value
		stopButton.Visible = value
	end

	local function handle(ev)
		local kind = ev.kind
		if kind == "user" then
			activity = nil
			agents = {}
			setBusy(true)
			addUser(tostring(ev.text or ""))
		elseif type(kind) == "string" and kind:sub(1, 9) == "subagent:" then
			handleAgent(kind, ev)
		elseif kind == "assistant:text" then
			addReply(tostring(ev.text or ""))
		elseif kind == "tool:call" then
			addTool(ev.id, ev.name)
		elseif kind == "tool:result" then
			finishTool(ev.id, true)
		elseif kind == "tool:error" then
			finishTool(ev.id, false)
		elseif kind == "permission:ask" then
			addPermission(ev)
			if not sheetOpen then setSheet(true) end
		elseif kind == "status" then
			statusLabel.Text = tostring(ev.text or "")
			if ev.text == "Ready" then setBusy(false) end
		elseif kind == "error" then
			addNote(tostring(ev.message or "Something went wrong."), T.bad)
			if ev.fatal then setBusy(false) end
		elseif kind == "abort" then
			addNote("Stopped", T.dim)
			setBusy(false)
		elseif kind == "turn:end" then
			setBusy(false)
		elseif kind == "model" then
			refreshTitle()
		elseif kind == "scan" then
			addNote(tostring(ev.text or "Scanned this game."), T.accent)
		elseif kind == "cleared" then
			for _, child in ipairs(scroll:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			activity = nil
		end
	end

	local detach = core.onEvent(function(ev) task.defer(handle, ev) end)

	local api = {}
	function api.destroy()
		if type(detach) == "function" then pcall(detach)
		elseif type(detach) == "table" and detach.Disconnect then pcall(detach.Disconnect, detach) end
		for _, c in ipairs(connections) do c:Disconnect() end
		screen:Destroy()
	end
	function api.toggle() setSheet(not sheetOpen) end

	screen.Parent = guiParent()
	return api
end

---------------------------------------------------------------- agent
-- Ember's own agent. It talks to the Claude API directly, or to any provider
-- with an OpenAI-style chat completions API. Set the provider, key and model in
-- Menu > Connection; set the model to "auto" and it picks one per message.

local function agentCore()
	local FILE = "ember_settings.json"
	local MAX_STEPS = 14
	local RESULT_CAP = 4000

	-- One profile per provider, so switching between them never loses a key.
	-- Auto picks from `tiers` per message; the Claude ids below come from Anthropic's
	-- current model list, and Menu can load the live list to check them.
	local settings = {
		provider = "anthropic", mode = "ask", off = {}, autoScan = true,
		profiles = {
			anthropic = {
				baseUrl = "https://api.anthropic.com/v1", apiKey = "", model = "auto", recent = {},
				tiers = { quick = "claude-haiku-5-5", standard = "claude-sonnet-5-5", deep = "claude-opus-5-5" },
			},
			gemini = {
				baseUrl = "https://generativelanguage.googleapis.com/v1beta/openai", apiKey = "",
				model = "gemini-flash-latest", recent = {}, tiers = { quick = "", standard = "", deep = "" },
			},
			openai = {
				baseUrl = "https://agentrouter.org/v1", apiKey = "", model = "gpt-5", recent = {},
				tiers = { quick = "", standard = "", deep = "" },
			},
		},
	}
	local saved = nil
	pcall(function()
		if isfile and readfile and isfile(FILE) then saved = HttpService:JSONDecode(readfile(FILE)) end
	end)
	if type(saved) == "table" then
		for key, value in pairs(saved) do
			if key ~= "profiles" and key ~= "baseUrl" and key ~= "apiKey" and key ~= "model" and key ~= "recent" then
				settings[key] = value
			end
		end
		if type(saved.profiles) == "table" then
			for name, stored in pairs(saved.profiles) do
				if type(stored) == "table" and settings.profiles[name] then
					for key, value in pairs(stored) do settings.profiles[name][key] = value end
				end
			end
		elseif saved.apiKey then -- settings from the first version, which only knew OpenAI-style APIs
			local old = settings.profiles.openai
			old.baseUrl = saved.baseUrl or old.baseUrl
			old.apiKey = saved.apiKey
			old.model = saved.model or old.model
			if type(saved.recent) == "table" then old.recent = saved.recent end
		end
	end
	do -- a Gemini key saved under OpenAI-style moves to its own Gemini profile
		local legacy, target = settings.profiles.openai, settings.profiles.gemini
		if tostring(legacy.baseUrl):find("generativelanguage", 1, true) and target.apiKey == "" then
			target.apiKey = legacy.apiKey
			target.recent = type(legacy.recent) == "table" and legacy.recent or {}
			for _, id in ipairs(target.recent) do
				if id ~= "auto" then
					target.model = id
					break
				end
			end
			legacy.baseUrl = "https://agentrouter.org/v1"
			legacy.apiKey = ""
			legacy.recent = {}
			if settings.provider == "openai" then settings.provider = "gemini" end
		end
	end
	if type(settings.off) ~= "table" then settings.off = {} end
	if not settings.profiles[settings.provider] then settings.provider = "anthropic" end
	for _, stored in pairs(settings.profiles) do
		if type(stored.recent) ~= "table" then stored.recent = {} end
		if type(stored.tiers) ~= "table" then stored.tiers = {} end
	end
	local function profile() return settings.profiles[settings.provider] end

	local function save()
		pcall(function()
			if writefile then writefile(FILE, HttpService:JSONEncode(settings)) end
		end)
	end

	local httpRequest = (syn and syn.request) or (http and http.request) or http_request or request
		or (fluxus and fluxus.request)

	local listeners, messages = {}, {}
	local busy, aborted = false, false
	local sessionAllow = {} -- "Always allow" lasts until the script is re-run, never saved

	local function emit(ev)
		for _, fn in ipairs(listeners) do fn(ev) end
	end

	---------------------------------------------------------------- game scan
	-- Reads the game the way you would in Dex: what is in Workspace, which remotes
	-- exist, which GUIs are up. The result rides in the system prompt so scripts are
	-- written against this game's real names instead of guesses.
	local gameName, scanText, scanSummary, scanPlace = nil, nil, nil, nil
	task.spawn(function()
		local ok, info = pcall(function()
			return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
		end)
		if ok and type(info) == "table" and info.Name then gameName = info.Name end
	end)

	local REMOTE = { RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true }

	local function inline(root, cap)
		local children = root:GetChildren()
		if #children == 0 then return "(empty)" end
		local out = {}
		for i = 1, math.min(#children, cap) do
			local child = children[i]
			local n = #child:GetChildren()
			out[#out + 1] = child.Name .. " [" .. child.ClassName .. "]" .. (n > 0 and (" (" .. n .. ")") or "")
		end
		if #children > cap then out[#out + 1] = "+" .. (#children - cap) .. " more" end
		return table.concat(out, ", ")
	end

	local function scanOverview()
		local waited = 0
		while not gameName and waited < 3 do
			task.wait(0.1)
			waited += 0.1
		end
		local name = gameName or "Unknown game"
		local me = Players.LocalPlayer
		local lines = {}
		local function add(line) lines[#lines + 1] = line end

		add("Game: " .. name .. " (PlaceId " .. tostring(game.PlaceId) .. ", GameId " .. tostring(game.GameId) .. ")")
		add("Players in server: " .. #Players:GetPlayers())

		local character = me and me.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			add("Your character: " .. humanoid.RigType.Name .. ", WalkSpeed " .. humanoid.WalkSpeed .. ", "
				.. (humanoid.UseJumpPower and ("JumpPower " .. humanoid.JumpPower) or ("JumpHeight " .. humanoid.JumpHeight)))
		end

		add("Workspace: " .. inline(workspace, 40))
		local storage = game:GetService("ReplicatedStorage")
		add("ReplicatedStorage: " .. inline(storage, 30))

		-- Remotes and module names under ReplicatedStorage, bounded so a huge game
		-- cannot stall the scan.
		local remotes, modules, seen, partial = {}, {}, 0, false
		for _, inst in ipairs(storage:GetDescendants()) do
			seen += 1
			if seen > 6000 then
				partial = true
				break
			end
			if seen % 500 == 0 then task.wait() end
			if REMOTE[inst.ClassName] then
				if #remotes < 40 then
					local path = inst:GetFullName():gsub("^ReplicatedStorage%.", "")
					remotes[#remotes + 1] = path .. " [" .. inst.ClassName .. "]"
				end
			elseif inst:IsA("ModuleScript") and #modules < 25 then
				modules[#modules + 1] = inst.Name
			end
		end
		if #remotes > 0 then add("Remotes in ReplicatedStorage: " .. table.concat(remotes, "; ")) end
		if #modules > 0 then add("ModuleScripts in ReplicatedStorage: " .. table.concat(modules, ", ")) end
		if partial then add("(ReplicatedStorage is large, so only the first 6000 objects were read)") end

		local gui = me and me:FindFirstChildOfClass("PlayerGui")
		if gui then add("PlayerGui: " .. inline(gui, 25)) end

		local tools = {}
		local backpack = me and me:FindFirstChildOfClass("Backpack")
		if backpack then
			for _, tool in ipairs(backpack:GetChildren()) do tools[#tools + 1] = tool.Name end
		end
		if character then
			for _, tool in ipairs(character:GetChildren()) do
				if tool:IsA("Tool") then tools[#tools + 1] = tool.Name .. " (held)" end
			end
		end
		if #tools > 0 then add("Your tools: " .. table.concat(tools, ", ")) end

		local body = table.concat(lines, "\n")
		if #body > 5000 then body = body:sub(1, 5000) .. "\n(scan cut at 5000 characters)" end
		local summary = "Scanned " .. name .. ": " .. #workspace:GetChildren() .. " objects in Workspace, "
			.. #remotes .. " remotes found"
		return body, summary
	end

	local function runScan()
		emit({ kind = "status", text = "Scanning game" })
		local ok, body, summary = pcall(scanOverview)
		if not ok then
			emit({ kind = "error", message = "Scan failed: " .. tostring(body), fatal = false })
			return nil
		end
		scanText, scanSummary, scanPlace = body, summary, game.PlaceId
		emit({ kind = "scan", text = summary })
		return body
	end

	---------------------------------------------------------------- saved chats
	local CHATS_FILE = "ember_chats.json"
	local CHAT_LIMIT = 30
	local chats, currentId = {}, nil
	pcall(function()
		if isfile and readfile and isfile(CHATS_FILE) then
			local saved = HttpService:JSONDecode(readfile(CHATS_FILE))
			if type(saved) == "table" then chats = saved end
		end
	end)

	local function writeChats()
		pcall(function()
			if writefile then writefile(CHATS_FILE, HttpService:JSONEncode(chats)) end
		end)
	end

	---------------------------------------------------------------- tools
	local function resolve(path)
		local node = game
		local first = true
		for part in tostring(path or "game"):gmatch("[^%.]+") do
			if not (first and part == "game") then
				local nextNode = node:FindFirstChild(part)
				if not nextNode and node == game then
					local ok, service = pcall(game.GetService, game, part)
					if ok then nextNode = service end
				end
				if not nextNode then return nil, "nothing named '" .. part .. "' under " .. node:GetFullName() end
				node = nextNode
			end
			first = false
		end
		return node
	end

	local function coerce(current, raw)
		local kind = typeof(current)
		raw = tostring(raw)
		if kind == "number" then return tonumber(raw) end
		if kind == "boolean" then return raw == "true" end
		if kind == "string" then return raw end
		local a, b, c = raw:match("^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
		if a then
			a, b, c = tonumber(a), tonumber(b), tonumber(c)
			if kind == "Vector3" then return Vector3.new(a, b, c) end
			if kind == "Color3" then return Color3.fromRGB(a, b, c) end
		end
		return nil
	end

	local TOOLS = {
		{
			name = "get_children", group = "inspect", risk = "read",
			description = "List the children of an instance, with class names. Use path like game.Workspace.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Instance path, for example game.Workspace" },
					depth = { type = "integer", description = "How many levels to list, 1 to 3. Default 1." },
				},
				required = { "path" },
			},
			run = function(a)
				local node, err = resolve(a.path)
				if not node then return "Error: " .. err end
				local depth = math.clamp(tonumber(a.depth) or 1, 1, 3)
				local lines, count = {}, 0
				local function walk(inst, level)
					for _, child in ipairs(inst:GetChildren()) do
						count += 1
						if count > 120 then return end
						lines[#lines + 1] = string.rep("  ", level - 1) .. child.Name .. " [" .. child.ClassName .. "]"
						if level < depth then walk(child, level + 1) end
					end
				end
				walk(node, 1)
				if #lines == 0 then return node:GetFullName() .. " has no children." end
				return table.concat(lines, "\n") .. (count > 120 and "\n(list cut at 120 entries)" or "")
			end,
		},
		{
			name = "get_property", group = "inspect", risk = "read",
			description = "Read one property of an instance.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Instance path" },
					property = { type = "string", description = "Property name, for example Position" },
				},
				required = { "path", "property" },
			},
			run = function(a)
				local node, err = resolve(a.path)
				if not node then return "Error: " .. err end
				local ok, value = pcall(function() return node[a.property] end)
				if not ok then return "Error: " .. tostring(value) end
				return typeof(value) .. ": " .. tostring(value)
			end,
		},
		{
			name = "list_players", group = "inspect", risk = "read",
			description = "List the players in this server.",
			parameters = {
				type = "object",
				properties = { include_ids = { type = "boolean", description = "Also show user ids" } },
			},
			run = function(a)
				local lines = {}
				for _, player in ipairs(Players:GetPlayers()) do
					lines[#lines + 1] = player.Name .. " (" .. player.DisplayName .. ")"
						.. (a.include_ids and (" id " .. player.UserId) or "")
				end
				return table.concat(lines, "\n")
			end,
		},
		{
			name = "set_property", group = "edit", risk = "write",
			description = "Set a property on an instance. Numbers, booleans and strings are plain; Vector3 and Color3 (0-255) are written as 'x,y,z'.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Instance path" },
					property = { type = "string", description = "Property name" },
					value = { type = "string", description = "New value as text" },
				},
				required = { "path", "property", "value" },
			},
			run = function(a)
				local node, err = resolve(a.path)
				if not node then return "Error: " .. err end
				local okRead, current = pcall(function() return node[a.property] end)
				if not okRead then return "Error: " .. tostring(current) end
				local value = coerce(current, a.value)
				if value == nil then return "Error: cannot turn '" .. tostring(a.value) .. "' into a " .. typeof(current) end
				local okWrite, werr = pcall(function() node[a.property] = value end)
				if not okWrite then return "Error: " .. tostring(werr) end
				return "Set " .. node:GetFullName() .. "." .. a.property .. " to " .. tostring(value)
			end,
		},
		{
			name = "run_lua", group = "code", risk = "danger",
			description = "Run Luau code on this client. print() output and the return value come back. Always task.wait() inside loops. Stops after 15 seconds.",
			parameters = {
				type = "object",
				properties = { code = { type = "string", description = "The Luau code to run" } },
				required = { "code" },
			},
			run = function(a)
				local code = tostring(a.code or "")
				if code == "" then return "Error: no code was given." end
				local fn, compileError = loadstring(code)
				if not fn then return "Compile error: " .. tostring(compileError) end

				local out = {}
				local function capture(...)
					local parts = {}
					for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
					out[#out + 1] = table.concat(parts, " ")
				end
				local okEnv, base = pcall(getfenv)
				if okEnv and type(base) == "table" then
					pcall(setfenv, fn, setmetatable({ print = capture, warn = capture }, { __index = base }))
				end

				local finished, ok, result = false, nil, nil
				local thread = task.spawn(function()
					ok, result = pcall(fn)
					finished = true
				end)
				local waited = 0
				while not finished and waited < 15 do
					task.wait(0.1)
					waited += 0.1
				end
				if not finished then
					pcall(task.cancel, thread)
					return "Stopped: the code was still running after 15 seconds."
				end
				local lines = {}
				if #out > 0 then lines[#lines + 1] = "Output:\n" .. table.concat(out, "\n") end
				if not ok then lines[#lines + 1] = "Error: " .. tostring(result)
				elseif result ~= nil then lines[#lines + 1] = "Returned: " .. tostring(result) end
				return #lines > 0 and table.concat(lines, "\n") or "Ran with no output."
			end,
		},
	}

	local TOOL_BY_NAME -- filled in just below; scan_game needs it
	table.insert(TOOLS, {
		name = "scan_game", group = "inspect", risk = "read",
		description = "Scan this game again. With no arguments it re-reads the overview (workspace, remotes, GUIs). With path it lists that part of the game in more depth.",
		parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "Optional part to look into, for example game.Workspace.Map" },
				depth = { type = "integer", description = "How many levels, 1 to 3. Default 2." },
			},
		},
		run = function(a)
			if type(a.path) == "string" and a.path ~= "" then
				return TOOL_BY_NAME.get_children.run({ path = a.path, depth = a.depth or 2 })
			end
			return runScan() or "The scan failed."
		end,
	})

	TOOL_BY_NAME = {}
	for _, tool in ipairs(TOOLS) do TOOL_BY_NAME[tool.name] = tool end

	local GROUPS = {
		{ id = "inspect", label = "Look around" },
		{ id = "edit", label = "Change properties" },
		{ id = "code", label = "Run code" },
	}

	local function visibleTools()
		local out = {}
		for _, tool in ipairs(TOOLS) do
			local hidden = settings.off[tool.group] == true
				or (settings.mode == "readonly" and tool.risk ~= "read")
			if not hidden then out[#out + 1] = tool end
		end
		return out
	end

	---------------------------------------------------------------- permissions
	local MATRIX = {
		readonly = { read = "allow", write = "deny", danger = "deny" },
		ask = { read = "allow", write = "ask", danger = "ask" },
		auto = { read = "allow", write = "allow", danger = "ask" },
		full = { read = "allow", write = "allow", danger = "allow" },
	}
	local MODES = {
		{ id = "readonly", label = "Read only", hint = "It can look, nothing is changed or run." },
		{ id = "ask", label = "Ask first", hint = "Looking is free. Changes and code wait for you." },
		{ id = "auto", label = "Auto", hint = "Property edits run freely. Code still asks." },
		{ id = "full", label = "Allow everything", hint = "No prompts at all. Only if you trust the model." },
	}

	local function permit(tool, args)
		if sessionAllow[tool.name] then return true end
		local verdict = (MATRIX[settings.mode] or MATRIX.ask)[tool.risk]
		if verdict == "allow" then return true end
		if verdict == "deny" then return false end

		local answered, allowed = false, false
		emit({
			kind = "permission:ask", name = tool.name, args = args,
			resolve = function(yes, remember)
				if answered then return end
				answered, allowed = true, yes == true
				if allowed and remember then sessionAllow[tool.name] = true end
			end,
		})
		local waited = 0
		while not answered and waited < 180 do
			if aborted then return false end
			task.wait(0.1)
			waited += 0.1
		end
		return allowed
	end

	---------------------------------------------------------------- model calls
	local function systemPrompt()
		local place = "an unnamed place"
		pcall(function()
			place = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
		end)
		local me = Players.LocalPlayer
		return table.concat({
			"You are an agent running inside a Roblox client, working for the person who runs it. You act through tools: when something can be done with a tool, do it, then say what happened.",
			"Environment: " .. place .. " (PlaceId " .. tostring(game.PlaceId) .. "), local player "
				.. (me and me.Name or "unknown") .. ".",
			"Read before you write: look at an instance before you change it. Use get_children, get_property and set_property for simple work and run_lua for the rest. Code runs on this client, so put task.wait() inside every loop.",
			"If a tool result says the user did not approve a call, accept that and do not repeat it. Never invent a result; if a tool returned nothing useful, say so.",
			"When asked for a script, write one complete, working script in a single fenced lua block. Build it from the real names and paths in the game scan below, and call scan_game for any part you have not seen instead of guessing. Say where it runs (a LocalScript on this client) and offer to run it with run_lua.",
			"Reply in plain text. Be short and direct.",
			scanText and ("Game scan, taken when this chat started:\n" .. scanText)
				or "No game scan yet: call scan_game before writing code that depends on this game's structure.",
		}, "\n")
	end

	local function trimHistory()
		while #messages > 60 do
			table.remove(messages, 1)
			while messages[1] and messages[1].role ~= "user" do table.remove(messages, 1) end
		end
	end

	local function api(path, method, body)
		if not httpRequest then return nil, "This executor has no HTTP request function." end
		local p = profile()
		if p.apiKey == "" then return nil, "Add your API key in Menu first." end
		local base = tostring(p.baseUrl):gsub("%s+", ""):gsub("/chat/completions/*$", ""):gsub("/models/*$", ""):gsub("/+$", "")
		if settings.provider == "gemini" then
			-- Google's address never changes, and one wrong character gives a blank 404,
			-- so the field is ignored here and the known-good address is always used.
			base = "https://generativelanguage.googleapis.com/v1beta/openai"
		end
		local headers = { ["Content-Type"] = "application/json" }
		if settings.provider == "anthropic" then
			if not base:match("/v1$") then base = base .. "/v1" end
			headers["x-api-key"] = p.apiKey
			headers["anthropic-version"] = "2023-06-01"
		else
			headers["Authorization"] = "Bearer " .. p.apiKey
		end
		local ok, res = pcall(httpRequest, {
			Url = base .. path, Method = method, Headers = headers,
			Body = body and HttpService:JSONEncode(body) or nil,
		})
		if not ok or not res then return nil, "Request failed: " .. tostring(res) end
		local status = tonumber(res.StatusCode or res.status_code) or 0
		local okJson, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
		if status < 200 or status >= 300 then
			local detail = okJson and type(data) == "table" and type(data.error) == "table" and data.error.message
				or shorten(res.Body or "", 200)
			detail = tostring(detail)
			local lower = detail:lower()
			local hint = ""
			if lower:find("unauthorized client", 1, true) or lower:find("content-blocked", 1, true) then
				hint = " That block comes from the provider, not Ember. Switch to Claude API in Menu."
			elseif status == 401 or status == 403 then
				hint = " Check the API key and the model name."
			end
			if detail == "" then detail = "empty reply" end
			return nil, "HTTP " .. status .. ": " .. detail .. hint .. " (" .. base .. path .. ")"
		end
		if not okJson then return nil, "The provider sent something that was not JSON." end
		return data
	end

	-- History is kept in one neutral shape (OpenAI-style) and translated per provider.
	local function toClaudeMessages()
		local wire = {}
		local function push(role, blocks)
			local last = wire[#wire]
			if last and last.role == role then
				for _, block in ipairs(blocks) do last.content[#last.content + 1] = block end
			else
				wire[#wire + 1] = { role = role, content = blocks }
			end
		end
		for _, message in ipairs(messages) do
			if message.role == "user" then
				push("user", { { type = "text", text = tostring(message.content) } })
			elseif message.role == "assistant" then
				local blocks = {}
				if type(message.content) == "string" and message.content:match("%S") then
					blocks[#blocks + 1] = { type = "text", text = message.content }
				end
				for _, call in ipairs(message.tool_calls or {}) do
					local fn = call["function"] or {}
					local input = {}
					if type(fn.arguments) == "string" and fn.arguments ~= "" then
						local okArgs, decoded = pcall(HttpService.JSONDecode, HttpService, fn.arguments)
						if okArgs and type(decoded) == "table" then input = decoded end
					end
					-- An empty Lua table would be sent as [] and Claude wants an object.
					if next(input) == nil then input = { note = "no arguments" } end
					blocks[#blocks + 1] = { type = "tool_use", id = call.id, name = fn.name, input = input }
				end
				if #blocks == 0 then blocks[1] = { type = "text", text = "(no reply)" } end
				push("assistant", blocks)
			elseif message.role == "tool" then
				push("user", { { type = "tool_result", tool_use_id = message.tool_call_id, content = tostring(message.content) } })
			end
		end
		return wire
	end

	local function chat(model, useTools)
		local tools = useTools == false and {} or visibleTools()

		if settings.provider == "anthropic" then
			local body = { model = model, max_tokens = 8000, system = systemPrompt(), messages = toClaudeMessages() }
			if #tools > 0 then
				body.tools = {}
				for _, tool in ipairs(tools) do
					body.tools[#body.tools + 1] = {
						name = tool.name, description = tool.description, input_schema = tool.parameters,
					}
				end
			end
			local data, err = api("/messages", "POST", body)
			if not data then return nil, err end
			local texts, calls = {}, {}
			for _, block in ipairs(data.content or {}) do
				if block.type == "text" and type(block.text) == "string" then
					texts[#texts + 1] = block.text
				elseif block.type == "tool_use" then
					local okEnc, argText = pcall(HttpService.JSONEncode, HttpService, block.input or {})
					calls[#calls + 1] = {
						id = block.id, type = "function",
						["function"] = { name = block.name, arguments = okEnc and argText or "{}" },
					}
				end
			end
			local content = table.concat(texts, "\n")
			if data.stop_reason == "max_tokens" then
				content = content .. "\n\n(The reply hit the length limit and was cut off.)"
			end
			return { content = content, tool_calls = #calls > 0 and calls or nil }
		end

		local defs = {}
		for _, tool in ipairs(tools) do
			defs[#defs + 1] = {
				type = "function",
				["function"] = { name = tool.name, description = tool.description, parameters = tool.parameters },
			}
		end
		local wire = { { role = "system", content = systemPrompt() } }
		for _, message in ipairs(messages) do
			if message.role == "tool" and settings.provider ~= "gemini" and message.name then
				wire[#wire + 1] = { role = "tool", tool_call_id = message.tool_call_id, content = message.content }
			else
				wire[#wire + 1] = message
			end
		end
		local body = { model = model, messages = wire }
		if #defs > 0 then
			body.tools = defs
			body.tool_choice = "auto"
		end
		local data, err = api("/chat/completions", "POST", body)
		if not data then return nil, err end
		local choice = data.choices and data.choices[1]
		if not choice or not choice.message then return nil, "The provider returned no answer." end
		local okRaw, raw = pcall(HttpService.JSONEncode, HttpService, choice)
		return choice.message, nil, { finish = choice.finish_reason, raw = okRaw and shorten(raw, 300) or "" }
	end

	-- Auto: choose a model for this message. Plain chat and lookups go to the quick
	-- tier, building or fixing a script to the standard tier, and long or hard jobs
	-- to the deep tier. It is a keyword and length check, so you can always pin a
	-- model by name instead.
	local BUILD_WORDS = { "script", "make", "create", "build", "write", "code", "fix", "error", "bug", "gui",
		"loop", "function", "module", "remote", "tween", "system", "generate", "add " }
	local DEEP_WORDS = { "debug", "optimi", "refactor", "entire", "whole game", "full system", "complete system",
		"architecture", "step by step" }

	local function pickModel(body)
		local p = profile()
		if p.model ~= "auto" then return p.model end
		local lower = body:lower()
		local tier = "quick"
		for _, word in ipairs(BUILD_WORDS) do
			if lower:find(word, 1, true) then
				tier = "standard"
				break
			end
		end
		if #body > 140 then tier = "standard" end
		if #body > 700 then tier = "deep" end
		for _, word in ipairs(DEEP_WORDS) do
			if lower:find(word, 1, true) then
				tier = "deep"
				break
			end
		end
		local order = tier == "deep" and { "deep", "standard", "quick" }
			or tier == "standard" and { "standard", "quick", "deep" } or { "quick", "standard", "deep" }
		for _, name in ipairs(order) do
			local id = p.tiers[name]
			if type(id) == "string" and id ~= "" then return id end
		end
		if settings.provider == "anthropic" then return "claude-sonnet-5-5" end
		-- OpenAI-style provider with no tiers filled in: reuse the last model you picked by name.
		for _, id in ipairs(p.recent) do
			if id ~= "auto" then return id end
		end
		return settings.provider == "gemini" and "gemini-flash-latest" or "gpt-5"
	end

	---------------------------------------------------------------- the turn
	local function runTool(call, step, index)
		local fn = call["function"] or {}
		local name = tostring(fn.name or "unknown")
		local tool = TOOL_BY_NAME[name]
		local args = {}
		if type(fn.arguments) == "string" and fn.arguments ~= "" then
			local okArgs, decoded = pcall(HttpService.JSONDecode, HttpService, fn.arguments)
			if okArgs and type(decoded) == "table" then args = decoded end
		elseif type(fn.arguments) == "table" then
			args = fn.arguments
		end

		emit({ kind = "tool:call", id = call.id, name = name })
		local ok, result
		if not tool or settings.off[tool.group] then
			ok, result = false, "No tool named '" .. name .. "' is available."
		elseif not permit(tool, args) then
			ok, result = false, "The user did not approve this call. Do not repeat it; ask what to do instead."
		else
			ok, result = pcall(tool.run, args)
		end
		result = tostring(result)
		if #result > RESULT_CAP then result = result:sub(1, RESULT_CAP) .. "\n(cut at " .. RESULT_CAP .. " characters)" end
		emit({ kind = ok and "tool:result" or "tool:error", id = call.id, name = name })
		messages[#messages + 1] = { role = "tool", tool_call_id = call.id, name = name, content = result }
	end

	local function persist()
		if not currentId then return end
		local first = "Chat"
		for _, message in ipairs(messages) do
			if message.role == "user" then
				first = tostring(message.content)
				break
			end
		end
		local keep = {}
		for i = math.max(#messages - 39, 1), #messages do keep[#keep + 1] = messages[i] end
		while keep[1] and keep[1].role ~= "user" do table.remove(keep, 1) end
		chats[currentId] = {
			id = currentId, title = shorten(first, 44), placeId = game.PlaceId,
			placeName = gameName or "Unknown game", updatedAt = os.time(), messages = keep,
		}
		local ids = {}
		for id in pairs(chats) do ids[#ids + 1] = id end
		if #ids > CHAT_LIMIT then
			table.sort(ids, function(x, y) return (chats[x].updatedAt or 0) > (chats[y].updatedAt or 0) end)
			for i = CHAT_LIMIT + 1, #ids do chats[ids[i]] = nil end
		end
		writeChats()
	end

	local function textOf(content)
		if type(content) == "string" then return content end
		if type(content) == "table" then
			local parts = {}
			for _, part in ipairs(content) do
				if type(part) == "string" then
					parts[#parts + 1] = part
				elseif type(part) == "table" and type(part.text) == "string" then
					parts[#parts + 1] = part.text
				end
			end
			return table.concat(parts, "\n")
		end
		return ""
	end

	local toolsOff = {} -- models that answered nothing while tools were attached

	local function turn(body)
		busy, aborted = true, false
		local fresh = #messages == 0
		currentId = currentId or ("c" .. os.time() .. math.random(100, 999))
		emit({ kind = "user", text = body })
		messages[#messages + 1] = { role = "user", content = body }
		trimHistory()
		if settings.autoScan ~= false and (fresh or scanText == nil or scanPlace ~= game.PlaceId) then
			runScan()
		end
		local model = pickModel(body)
		profile().active = model
		emit({ kind = "model", text = model })

		local finished = false
		for step = 1, MAX_STEPS do
			if aborted then break end
			emit({ kind = "status", text = step == 1 and "Thinking" or ("Working, step " .. step) })
			local message, err, info = chat(model, not toolsOff[model])
			-- Some models return nothing at all when tools are attached. Ask once more
			-- without them, and keep tools off for that model if that works.
			if message and settings.provider ~= "anthropic" and not toolsOff[model]
				and not textOf(message.content):match("%S")
				and not (type(message.tool_calls) == "table" and #message.tool_calls > 0) then
				local again, _, againInfo = chat(model, false)
				if again and textOf(again.content):match("%S") then
					message, info = again, againInfo
					toolsOff[model] = true
					emit({ kind = "error", fatal = false,
						message = model .. " answered nothing while tools were attached, so tools are off for it. Chat works; scripts and scans by the agent will not." })
				end
			end
			if aborted then break end
			if not message then
				emit({ kind = "error", message = err, fatal = true })
				finished = true
				break
			end

			local content = textOf(message.content)
			local calls = type(message.tool_calls) == "table" and message.tool_calls or {}
			for index, call in ipairs(calls) do
				if call.id == nil or call.id == "" then call.id = "call_" .. step .. "_" .. index end
				call.type = call.type or "function"
			end
			if content:match("%S") then
				emit({ kind = "assistant:text", text = content })
			elseif #calls == 0 then
				-- Never fail silently: say what came back so the cause can be seen.
				emit({ kind = "error", fatal = false, message = "The model sent back an empty reply"
					.. (info and info.finish and (" (finish: " .. tostring(info.finish) .. ")") or "")
					.. ((info and info.raw ~= "") and (". Raw: " .. info.raw) or "") })
			end
			messages[#messages + 1] = {
				role = "assistant", content = content, tool_calls = #calls > 0 and calls or nil,
			}

			if #calls == 0 then
				finished = true
				break
			end
			for index, call in ipairs(calls) do
				if aborted then
					messages[#messages + 1] = { role = "tool", tool_call_id = call.id, content = "Stopped by the user." }
				else
					runTool(call, step, index)
				end
			end
		end

		if aborted then
			emit({ kind = "abort" })
		elseif not finished then
			emit({ kind = "error", message = "Stopped after " .. MAX_STEPS .. " steps. Send another message to keep going.", fatal = false })
		end
		busy = false
		persist()
		emit({ kind = "turn:end" })
		emit({ kind = "status", text = "Ready" })
	end

	---------------------------------------------------------------- what the UI sees
	local core = {}

	function core.send(body)
		if busy then return false, "The agent is still working. Tap Stop first." end
		if not httpRequest then return false, "This executor has no HTTP request function." end
		if profile().apiKey == "" then return false, "Add your API key first: Menu, then Connection." end
		task.spawn(turn, body)
		return true
	end

	function core.abort() aborted = true end

	function core.newChat()
		aborted = true
		messages = {}
		currentId = nil
		emit({ kind = "cleared" })
		emit({ kind = "status", text = "Ready" })
	end

	function core.onEvent(fn)
		table.insert(listeners, fn)
		return function()
			for i, existing in ipairs(listeners) do
				if existing == fn then table.remove(listeners, i) break end
			end
		end
	end

	function core.modes() return MODES end
	function core.getMode() return settings.mode end
	function core.setMode(id)
		settings.mode = id
		save()
	end

	function core.groups()
		local out = {}
		for _, group in ipairs(GROUPS) do
			out[#out + 1] = { id = group.id, label = group.label, enabled = settings.off[group.id] ~= true }
		end
		return out
	end
	function core.setGroup(id, enabled)
		settings.off[id] = (not enabled) or nil
		save()
	end

	function core.history()
		local list = {}
		for _, chat in pairs(chats) do
			list[#list + 1] = {
				id = chat.id, title = chat.title or "Chat", place = chat.placeName or "Unknown game",
				updatedAt = chat.updatedAt or 0, current = chat.id == currentId,
			}
		end
		table.sort(list, function(x, y) return x.updatedAt > y.updatedAt end)
		return list
	end

	function core.openChat(id)
		if busy then return nil, "Tap Stop first, the agent is still working." end
		local chat = chats[id]
		if not chat then return nil, "That chat is gone." end
		currentId = id
		messages = HttpService:JSONDecode(HttpService:JSONEncode(chat.messages or {}))
		local items = {}
		for _, message in ipairs(messages) do
			if message.role == "user" then
				items[#items + 1] = { kind = "user", text = tostring(message.content) }
			elseif message.role == "assistant" then
				if type(message.content) == "string" and message.content ~= "" then
					items[#items + 1] = { kind = "assistant", text = message.content }
				end
				if type(message.tool_calls) == "table" and #message.tool_calls > 0 then
					local names = {}
					for _, call in ipairs(message.tool_calls) do
						names[#names + 1] = tostring((call["function"] or {}).name or "tool")
					end
					items[#items + 1] = { kind = "tools", names = names }
				end
			end
		end
		scanText = nil -- the next message rescans, so the scan matches where you are now
		return items
	end

	function core.deleteChat(id)
		chats[id] = nil
		local wasCurrent = id == currentId
		if wasCurrent then
			currentId = nil
			messages = {}
		end
		writeChats()
		return wasCurrent
	end

	core.scan = {
		get = function()
			return { enabled = settings.autoScan ~= false, name = gameName or "Unknown game", summary = scanSummary }
		end,
		setEnabled = function(value)
			settings.autoScan = value == true
			save()
		end,
		now = function() return runScan() end,
	}

	core.connection = {
		get = function()
			local p = profile()
			return {
				provider = settings.provider, baseUrl = p.baseUrl, model = p.model, active = p.active,
				recent = p.recent, tiers = p.tiers, hasKey = p.apiKey ~= "", keyTail = p.apiKey:sub(-4),
			}
		end,
		set = function(field, value)
			value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
			local p = profile()
			-- Model ids never contain spaces, and almost all are lowercase, so typing
			-- "Gemini 3.5 flash" is turned into "gemini-3.5-flash". Ids with a slash
			-- (like models/... from a provider's list) are left exactly as given.
			if field == "model" or field:sub(1, 5) == "tier_" then
				value = value:gsub("%s+", "-")
				if not value:find("/", 1, true) then value = value:lower() end
			end
			if field == "provider" then
				if settings.profiles[value] then settings.provider = value end
			elseif field == "model" then
				if value == "" then return end
				p.model = value
				local recent = { value }
				for _, id in ipairs(p.recent) do
					if id ~= value and #recent < 6 then recent[#recent + 1] = id end
				end
				p.recent = recent
			elseif field == "baseUrl" then
				if value ~= "" then p.baseUrl = value end
			elseif field == "apiKey" then
				p.apiKey = value
			elseif field:sub(1, 5) == "tier_" then
				p.tiers[field:sub(6)] = value
			end
			save()
		end,
		fetchModels = function()
			local data, err = api("/models", "GET")
			if not data then return nil, err end
			local ids = {}
			for _, entry in ipairs(data.data or {}) do
				if type(entry) == "table" and entry.id then
					local id = tostring(entry.id)
					if settings.provider == "gemini" then id = id:gsub("^models/", "") end
					ids[#ids + 1] = id
				end
			end
			table.sort(ids)
			if #ids == 0 then return nil, "The provider did not list any models. Type a model id in the Model box." end
			return ids
		end,
	}

	return core
end

local shared = (getgenv and getgenv()) or _G
if shared.EmberUI and shared.EmberUI.destroy then pcall(shared.EmberUI.destroy) end
shared.EmberUI = Ember(shared.EmberCore or agentCore())
return shared.EmberUI

--[[ OPTIONAL GLUE (only to drive his UAI core instead of the built-in agent) ------------------------------------------------------------------
	Goes inside the bundle where `env` exists, in place of the call that
	starts the old UI (the boot step at the bottom of uai.lua). Set the core
	first, then run this file, which picks it up:

	local sessions = env.require("agent/session")
	local permissions = env.require("agent/permissions")
	local registry = env.require("agent/registry")

	getgenv().EmberCore = ({
		send = function(text) return sessions.current().send(text) end,
		abort = function() return sessions.current().abort() end,
		newChat = function() sessions.newThread() end,
		onEvent = function(handler)
			return sessions.anyEvent:connect(function(session, ev)
				if session == sessions.current() then handler(ev) end
			end)
		end,
		modes = function()
			local out = {}
			for _, id in ipairs(permissions.MODES) do
				out[#out + 1] = { id = id, label = permissions.MODE_LABELS[id], hint = permissions.MODE_HINTS[id] }
			end
			return out
		end,
		getMode = permissions.mode,
		setMode = permissions.setMode,
		groups = registry.groups,
		setGroup = registry.setGroupEnabled,
	})

	loadstring(readfile("ember_v8.lua"))()
------------------------------------------------------------------------- ]]
