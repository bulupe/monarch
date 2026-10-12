-- Standalone regression tests for show options. Runs with Lua 5.1+ (or Fengari).
-- Models asynchronous messages, proxy lifecycle and timers; not a native-render test.
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/test/[^/]+$") or "."
package.path = root .. "/?.lua;" .. package.path
unpack = unpack or table.unpack
hash = function(value) return value end

local function fixture()
	package.loaded["monarch.monarch"] = nil
	local events, history, pending, proxies = {}, {}, {}, {}
	local frame, order, current = 0, 0, "controller"
	local monarch
	local f = { history = history }
	local function schedule(delay, context, fn)
		order = order + 1
		events[#events + 1] = { at = frame + math.max(1, delay), order = order, context = context, fn = fn }
	end
	timer = { delay = function(delay, repeating, fn)
		assert(not repeating)
		schedule(1, current, fn)
	end }
	msg = {
		url = function(url) return url or current end,
		post = function(url, id, data)
			local sender = current
			data = data or {}
			history[#history + 1] = { frame = frame, url = url, id = id, data = data }
			schedule(1, url, function()
				if id == "async_load" or id == "unload" then
					local reply = id == "async_load" and "proxy_loaded" or "proxy_unloaded"
					schedule(1, sender, function() monarch.on_message(reply, {}, url) end)
				elseif not proxies[url] then
					monarch.on_message(id, data, sender)
				end
			end)
		end,
	}
	monarch = require "monarch.monarch"
	f.monarch = monarch
	function f.step()
		assert(#events > 0, "No events left while waiting")
		table.sort(events, function(a, b)
			return a.at < b.at or (a.at == b.at and a.order < b.order)
		end)
		local event = table.remove(events, 1)
		frame, current = event.at, event.context
		event.fn()
		current = "controller"
	end
	function f.until_true(fn)
		for _ = 1, 2000 do
			if fn() then return end
			f.step()
		end
		error("Timed out")
	end
	function f.drain()
		f.until_true(function() return #events == 0 end)
	end
	function f.add(id, settings)
		settings = settings or {}
		current = id
		proxies[id .. "_proxy"] = true
		monarch.register_proxy(id, id .. "_proxy", settings)
		monarch.on_transition(id, function(kind, message, sender)
			local key = id .. ":" .. kind
			if settings.hold_out and kind == monarch.TRANSITION_SHOW_OUT and not message.instant then
				pending[key] = function() msg.post(sender, monarch.TRANSITION_DONE, {}) end
			else
				msg.post(sender, monarch.TRANSITION_DONE, {})
			end
		end)
		current = "controller"
	end
	function f.release(id)
		local key = id .. ":" .. monarch.TRANSITION_SHOW_OUT
		assert(pending[key], "No pending exit for " .. id)
		current = id
		pending[key]()
		pending[key] = nil
		current = "controller"
	end
	function f.held(id) return pending[id .. ":" .. monarch.TRANSITION_SHOW_OUT] ~= nil end
	function f.show(id, options)
		local done = false
		monarch.show(id, options, nil, function() done = true end)
		f.until_true(function() return done end)
		f.drain()
	end
	function f.seen(id, kind)
		for _, event in ipairs(history) do
			if event.url == id and event.id == kind then return true end
		end
		return false
	end
	function f.last(id, kind)
		for i = #history, 1, -1 do
			local event = history[i]
			if event.url == id and event.id == kind then return event end
		end
	end
	return f
end

local count = 0
local function test(name, fn)
	fn()
	count = count + 1
	print("PASS " .. name)
end

local function stack_fixture()
	local f = fixture()
	f.add("game")
	f.add("menu")
	f.add("next")
	f.add("popup1", { popup = true, hold_out = true })
	f.add("popup2", { popup = true, popup_on_popup = true, hold_out = true })
	f.show("game")
	f.show("popup1")
	f.show("popup2")
	return f
end

test("legacy popup exits remain serial", function()
	local f = stack_fixture()
	f.monarch.show("menu")
	f.until_true(function() return f.held("popup2") end)
	assert(not f.held("popup1"))
	assert(not f.seen("menu", f.monarch.TRANSITION_SHOW_IN))
	f.release("popup2")
	f.until_true(function() return f.held("popup1") end)
	assert(not f.seen("menu", f.monarch.TRANSITION_SHOW_IN))
	f.release("popup1")
	f.drain()
	assert(f.monarch.is_visible("menu") and not f.monarch.is_busy())
end)

test("parallel exits track the slowest popup and resume queued navigation", function()
	local f = stack_fixture()
	local completed = 0
	f.monarch.show("menu", { parallel_popup_exit = true }, nil, function() completed = completed + 1 end)
	f.monarch.show("next")
	f.until_true(function() return f.monarch.is_visible("menu") and f.held("popup1") and f.held("popup2") end)
	f.drain()
	assert(completed == 0 and f.monarch.is_busy())
	assert(not f.seen("next", f.monarch.TRANSITION_SHOW_IN))
	f.release("popup1")
	f.drain()
	assert(completed == 0 and f.monarch.is_busy())
	f.release("popup2")
	f.drain()
	assert(completed == 1)
	assert(f.monarch.is_visible("next") and not f.monarch.is_busy())
	assert(not f.monarch.is_loaded("popup1") and not f.monarch.is_loaded("popup2"))
end)

test("sequential wins over parallel_popup_exit", function()
	local f = stack_fixture()
	f.monarch.show("menu", { parallel_popup_exit = true, sequential = true })
	f.until_true(function() return f.held("popup2") end)
	assert(not f.held("popup1") and not f.seen("game", f.monarch.TRANSITION_SHOW_OUT))
	f.release("popup2")
	f.until_true(function() return f.held("popup1") end)
	assert(not f.seen("menu", f.monarch.TRANSITION_SHOW_IN))
	f.release("popup1")
	f.drain()
	assert(f.monarch.is_visible("menu") and not f.monarch.is_busy())
end)

test("same popup can be reopened safely with parallel option", function()
	local f = stack_fixture()
	local completed = false
	f.monarch.show("popup1", { parallel_popup_exit = true }, nil, function() completed = true end)
	f.until_true(function() return f.held("popup2") end)
	assert(not f.held("popup1"))
	f.release("popup2")
	f.until_true(function() return f.held("popup1") end)
	assert(not completed)
	f.release("popup1")
	f.drain()
	assert(completed and f.monarch.is_visible("popup1") and not f.monarch.is_busy())
end)

test("back still resumes the game after closing its popup", function()
	local f = fixture()
	f.add("game")
	f.add("popup", { popup = true, timestep_below_popup = 0 })
	f.show("game")
	f.show("popup")
	f.monarch.back()
	f.drain()
	assert(f.monarch.is_visible("game") and not f.monarch.is_loaded("popup"))
	assert(not f.monarch.is_busy())
end)

test("five popup exits overlap", function()
	local f = fixture()
	f.add("game")
	f.add("menu")
	f.show("game")
	for i = 1, 5 do
		f.add("popup" .. i, { popup = true, popup_on_popup = true, hold_out = true })
		f.show("popup" .. i)
	end
	f.monarch.show("menu", { parallel_popup_exit = true })
	f.drain()
	for i = 1, 5 do assert(f.held("popup" .. i)) end
	assert(f.monarch.is_visible("menu"))
	for i = 1, 5 do f.release("popup" .. i) end
	f.drain()
	assert(not f.monarch.is_busy())
end)

test("exit override reaches every popup and game without overriding menu entrance", function()
	local f = stack_fixture()
	f.show("menu", { parallel_popup_exit = true, transition_out = false })
	for _, id in ipairs({ "popup1", "popup2", "game" }) do
		assert(f.last(id, f.monarch.TRANSITION_SHOW_OUT).data.instant == true)
		assert(not f.monarch.is_loaded(id))
	end
	assert(f.last("menu", f.monarch.TRANSITION_SHOW_IN).data.instant == nil)
	assert(not f.monarch.is_busy())
end)

test("entrance override is independent and not sticky", function()
	local f = fixture()
	f.add("game")
	f.add("menu")
	f.show("game")
	f.show("menu", { transition_in = false })
	assert(f.last("menu", f.monarch.TRANSITION_SHOW_IN).data.instant == true)
	assert(f.last("game", f.monarch.TRANSITION_SHOW_OUT).data.instant == nil)
	f.show("game")
	assert(f.last("game", f.monarch.TRANSITION_SHOW_IN).data.instant == nil)
	assert(f.last("menu", f.monarch.TRANSITION_SHOW_OUT).data.instant == nil)
end)

test("instant serial replacement of the same popup remains safe", function()
	local f = stack_fixture()
	f.show("popup1", { transition_in = false, transition_out = false, parallel_popup_exit = true })
	assert(f.last("popup1", f.monarch.TRANSITION_SHOW_IN).data.instant == true)
	assert(f.last("popup1", f.monarch.TRANSITION_SHOW_OUT).data.instant == true)
	assert(f.monarch.is_visible("popup1") and not f.monarch.is_busy())
end)

for _, sequential in ipairs({ false, true }) do
	for _, side in ipairs({ "in", "out", "both" }) do
		test("back overrides " .. side .. ", sequential=" .. tostring(sequential), function()
			local f = fixture()
			f.add("game")
			f.add("menu")
			f.show("game")
			f.show("menu")
			local options = { sequential = sequential }
			if side ~= "out" then options.transition_in = false end
			if side ~= "in" then options.transition_out = false end
			f.monarch.back(options)
			f.drain()
			assert((f.last("game", f.monarch.TRANSITION_BACK_IN).data.instant == true) == (side ~= "out"))
			assert((f.last("menu", f.monarch.TRANSITION_BACK_OUT).data.instant == true) == (side ~= "in"))
			assert(f.monarch.is_visible("game") and not f.monarch.is_busy())
		end)
	end
end

test("instant popup back-out preserves resume behavior", function()
	local f = fixture()
	f.add("game", { timestep_below_popup = 0 })
	f.add("popup", { popup = true })
	f.show("game")
	f.show("popup")
	f.monarch.back({ transition_in = false, transition_out = false })
	f.drain()
	assert(f.last("popup", f.monarch.TRANSITION_BACK_OUT).data.instant == true)
	assert(not f.seen("game", f.monarch.TRANSITION_BACK_IN))
	assert(f.last("game_proxy", "set_time_step").data.factor == 1)
	assert(f.monarch.is_visible("game") and not f.monarch.is_busy())
end)

test("instant exit also works with no underlying screen", function()
	local f = fixture()
	f.add("game")
	f.show("game")
	f.monarch.back({ transition_out = false })
	f.drain()
	assert(f.last("game", f.monarch.TRANSITION_BACK_OUT).data.instant == true)
	assert(not f.monarch.is_loaded("game") and not f.monarch.is_busy())
end)

print(count .. " show/back option tests passed")
