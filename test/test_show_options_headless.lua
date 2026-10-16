-- Standalone regression tests for show options. Runs with Lua 5.1+ (or Fengari).
-- Models asynchronous messages, proxy lifecycle and timers; not a native-render test.
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/test/[^/]+$") or "."
package.path = root .. "/?.lua;" .. package.path
unpack = unpack or table.unpack
hash = function(value) return value end

local function fixture()
	package.loaded["monarch.monarch"] = nil
	local events, history, pending, proxies = {}, {}, {}, {}
	local drawn, focused, settings_by_id, factory_status = {}, {}, {}, {}
	local coverage
	local frame, order, current = 0, 0, "controller"
	local monarch
	local f = { history = history, load_waits = {} }
	local clock_offset = 0
	local function initialize(id)
		-- Model scene init registering its handler before optional setup work.
		local previous_context = current
		current = id
		local settings = settings_by_id[id]
		if settings.prepare then monarch.on_prepare(id, settings.prepare) end
		if settings.init then settings.init() end
		current = previous_context
	end
	package.loaded.socket = { gettime = function() return frame / 60 + clock_offset end }
	function f.block(seconds) clock_offset = clock_offset + seconds end
	local function schedule(delay, context, fn)
		order = order + 1
		local event = { at = frame + math.max(1, delay), order = order, context = context, fn = fn }
		events[#events + 1] = event
		return event
	end
	timer = { delay = function(delay, repeating, fn)
		assert(not repeating)
		if delay > 0 then f.load_waits[#f.load_waits + 1] = { seconds = delay, screen = current } end
		return schedule(math.max(1, math.ceil(delay * 60)), current, fn)
	end, cancel = function(handle) handle.cancelled = true end }
	msg = {
		url = function(url) return url or current end,
		post = function(url, id, data)
			local sender = current
			data = data or {}
			history[#history + 1] = { frame = frame, url = url, id = id, data = data }
			schedule(1, url, function()
				local screen = proxies[url]
				if screen and (id == "enable" or id == "disable" or id == "unload") then
					drawn[screen] = id == "enable" and not settings_by_id[screen].prepare
				end
				if screen and id == "init" then
					initialize(screen)
				end
				if id == "acquire_input_focus" then focused[url] = true end
				if id == "release_input_focus" then focused[url] = false end
				if id == "async_load" or id == "unload" then
					local reply = id == "async_load" and "proxy_loaded" or "proxy_unloaded"
					if id == "async_load" and settings_by_id[screen].fail_load then reply = "proxy_error" end
					local delay = id == "async_load" and (settings_by_id[screen].load_delay or 1) or 1
					schedule(delay, sender, function() monarch.on_message(reply, { code = 5 }, url) end)
				elseif not proxies[url] then
					monarch.on_message(id, data, sender)
				end
			end)
		end,
	}
	collectionfactory = {
		STATUS_UNLOADED = 0, STATUS_LOADED = 1,
		get_status = function(url) return factory_status[url] or 0 end,
		load = function(url, cb)
			local context = current
			schedule(settings_by_id[context].load_delay or 1, context, function()
				local ok = not settings_by_id[context].fail_load
				factory_status[url] = ok and 1 or 0
				cb(nil, url, ok)
			end)
		end,
		create = function(url)
			drawn[current] = not settings_by_id[current].prepare
			initialize(current)
			return { root = current .. "_instance" }
		end,
		unload = function(url) factory_status[url] = 0 end,
	}
	go = {
		exists = function() return true end,
		delete = function(instance) drawn[instance:gsub("_instance$", "")] = false end,
	}
	monarch = require "monarch.monarch"
	f.monarch = monarch
	function f.check_coverage()
		if coverage then
			for _, id in ipairs(coverage) do if drawn[id] then return end end
			error("Empty rendered frame " .. frame .. " between " .. table.concat(coverage, ", "))
		end
	end
	function f.cover(...) coverage = {...}; f.check_coverage() end
	function f.is_drawn(id) return drawn[id] end
	function f.is_focused(id) return focused[id] end
	function f.settings(id) return settings_by_id[id] end
	function f.step()
		assert(#events > 0, "No events left while waiting")
		table.sort(events, function(a, b)
			return a.at < b.at or (a.at == b.at and a.order < b.order)
		end)
		local event = table.remove(events, 1)
		if event.at ~= frame then f.check_coverage() end
		frame, current = event.at, event.context
		if not event.cancelled then event.fn() end
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
		f.check_coverage()
	end
	function f.add(id, settings)
		settings = settings or {}
		settings_by_id[id] = settings
		current = id
		if settings.factory then
			monarch.register_factory(id, id .. "_factory", settings)
		else
			proxies[id .. "_proxy"] = id
			monarch.register_proxy(id, id .. "_proxy", settings)
		end
		if not settings.no_transition then monarch.on_transition(id, function(kind, message, sender)
			if kind == monarch.TRANSITION_SHOW_IN or kind == monarch.TRANSITION_BACK_IN then drawn[id] = true end
			local key = id .. ":" .. kind
			if settings.hold_out and kind == monarch.TRANSITION_SHOW_OUT and not message.instant then
				pending[key] = function() msg.post(sender, monarch.TRANSITION_DONE, {}) end
			else
				msg.post(sender, monarch.TRANSITION_DONE, {})
			end
		end) end
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
	function f.prepare(id, fn)
		settings_by_id[id].prepare = fn
	end
	function f.navigation(id, fn)
		current = id
		monarch.on_navigation(id, fn)
		current = "controller"
	end
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

for _, sequential in ipairs({ false, true }) do
	for _, queue_next in ipairs({ false, true }) do
		test("unsafe loaded reload fails before exits: sequential=" .. tostring(sequential) .. ", queued=" .. tostring(queue_next), function()
			local f = fixture()
			f.add("old")
			f.add("new", { factory = true })
			f.add("queued")
			f.monarch.add_listener("listener")
			f.show("old")
			f.show("new", { no_stack = true })
			f.settings("new").fail_load = true
			local completed, queued_completed = 0, 0
			f.monarch.show("new", { reload = true, sequential = sequential }, nil, function(ok, result)
				assert(ok == false and result.reason == "reload_requires_unloaded_screen")
				completed = completed + 1
			end)
			if queue_next then
				f.monarch.show("queued", nil, nil, function() queued_completed = queued_completed + 1 end)
			end
			f.drain()
			assert(not f.monarch.is_busy(), "Failed incoming reload left the handover busy")
			assert(completed == 1 and f.monarch.queue_size() == 0)
			assert(f.seen("listener", f.monarch.SCREEN_TRANSITION_FAILED))
			assert(f.monarch.is_loaded("new"))
			if queue_next then
				assert(queued_completed == 1 and f.monarch.is_top("queued"))
				assert(f.is_drawn("queued") and f.is_focused("queued"))
			else
				assert(not f.seen("old_proxy", "unload") and f.is_drawn("old") and f.is_focused("old"))
				assert(not f.seen("queued_proxy", "async_load"))
				f.settings("new").fail_load = false
				f.show("new")
					assert(f.is_drawn("new") and f.monarch.is_top("new"))
			end
		end)
	end
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

for _, sequential in ipairs({ false, true }) do
	for _, preloaded in ipairs({ false, true }) do
		for _, instant in ipairs({ false, true }) do
			for _, kind in ipairs({ "popup", "screen", "back", "factory" }) do
				test("continuous " .. kind .. " sequential=" .. tostring(sequential)
					.. " preloaded=" .. tostring(preloaded) .. " instant=" .. tostring(instant), function()
					local f = fixture()
					f.add("base")
					f.add("old", { popup = kind == "popup", factory = kind == "factory" })
					f.add("new", { popup = kind == "popup", factory = kind == "factory", load_delay = 12 })
					f.show("base")
					if kind == "back" then f.show("new") end
					f.show("old")
					if preloaded then
						f.monarch.preload("new", { keep_loaded = true })
						f.drain()
					end
					f.cover("old", "new")
					local done = 0
					local options = { sequential = sequential }
					if instant then options.transition_in, options.transition_out = false, false end
					local navigate = kind == "back" and function()
						f.monarch.back(options, nil, function() done = done + 1 end)
					end or function()
						f.monarch.show("new", options, nil, function() done = done + 1 end)
					end
					navigate()
					f.drain()
					assert(done == 1 and f.monarch.is_top("new") and not f.monarch.is_busy())
					assert(f.is_drawn("new") and not f.is_drawn("old"))
					assert(not f.monarch.is_loaded("old"))
					if kind ~= "factory" then
						assert(f.is_focused("new") and not f.is_focused("old"))
					end
				end)
			end
		end
	end
end

test("replace retains popup coverage and removes its stack entry", function()
	local f = fixture()
	f.add("base")
	f.add("old", { popup = true, auto_preload = true })
	f.add("new", { popup = true, load_delay = 20 })
	f.show("base")
	f.show("old")
	f.cover("old", "new")
	f.monarch.replace("new", { transition_out = false })
	f.drain()
	assert(table.concat(f.monarch.get_stack(), ",") == "base,new")
	assert(f.monarch.is_preloaded("old") and not f.is_drawn("old"))
end)

test("slow loading does not start an outgoing animation or accept another navigation", function()
	local f = fixture()
	f.add("old")
	f.add("new", { load_delay = 20 })
	f.add("queued")
	f.show("old")
	f.monarch.show("new")
	f.monarch.show("queued")
	f.until_true(function() return f.seen("new_proxy", "async_load") end)
	assert(f.monarch.is_busy() and f.is_drawn("old") and f.monarch.is_top("old"))
	assert(not f.seen("old", f.monarch.TRANSITION_SHOW_OUT))
	assert(not f.seen("queued_proxy", "async_load"))
	f.drain()
	assert(f.monarch.is_top("queued") and not f.monarch.is_busy())
end)

test("failed preparation keeps the outgoing popup, stack and focus", function()
	local f = fixture()
	f.add("base")
	f.add("old", { popup = true })
	f.add("new", { factory = true, fail_load = true })
	f.show("base")
	f.show("old")
	f.cover("old")
	local called = false
	f.monarch.show("new", nil, nil, function() called = true end)
	f.drain()
	assert(called and not f.monarch.is_busy())
	assert(table.concat(f.monarch.get_stack(), ",") == "base,old")
	assert(f.is_focused("old") and not f.seen("old", f.monarch.TRANSITION_SHOW_OUT))
	f.settings("new").fail_load = false
	f.cover("old", "new")
	f.show("new")
	assert(f.monarch.is_top("new"))
end)

test("failed back preparation keeps the current scene and its stack", function()
	local f = fixture()
	f.add("old")
	f.add("new", { factory = true })
	f.show("new")
	f.show("old")
	f.settings("new").fail_load = true
	f.cover("old")
	f.monarch.back()
	f.drain()
	assert(f.monarch.is_top("old") and f.is_focused("old") and not f.monarch.is_busy())
	assert(table.concat(f.monarch.get_stack(), ",") == "new,old")
end)

test("sequential exit animation finishes before entrance but cleanup waits for readiness", function()
	local f = fixture()
	f.add("old", { hold_out = true })
	f.add("new")
	f.show("old")
	f.cover("old", "new")
	f.monarch.show("new", { sequential = true })
	f.until_true(function() return f.held("old") end)
	assert(not f.seen("new", f.monarch.TRANSITION_SHOW_IN))
	assert(not f.seen("new_proxy", "enable"))
	f.release("old")
	f.drain()
	assert(f.last("new_proxy", "enable").frame < f.last("old_proxy", "unload").frame)
end)

test("scenes without transition handlers keep coverage and finish queued callbacks", function()
	local f = fixture()
	f.add("old", { no_transition = true })
	f.add("new", { no_transition = true })
	f.show("old")
	f.cover("old", "new")
	f.show("new", { sequential = true })
	f.monarch.back({ sequential = true })
	f.drain()
	assert(f.is_drawn("old") and not f.monarch.is_busy())
end)

test("show waits for an already running preload without retiring the current scene", function()
	local f = fixture()
	f.add("old")
	f.add("new", { load_delay = 20 })
	f.show("old")
	f.cover("old", "new")
	f.monarch.preload("new")
	f.until_true(function() return f.monarch.is_preloading("new") end)
	f.monarch.show("new")
	f.drain()
	assert(f.monarch.is_top("new") and not f.monarch.is_busy())
end)

test("back with sequential on the last scene completes without a destination", function()
	local f = fixture()
	f.add("old")
	f.show("old")
	local done = 0
	f.monarch.back({ sequential = true }, nil, function() done = done + 1 end)
	f.drain()
	assert(done == 1 and #f.monarch.get_stack() == 0 and not f.monarch.is_busy())
end)

test("unregister during resource loading preserves the old screen and ignores the late reply", function()
	local f = fixture()
	f.add("old")
	f.add("new", { load_delay = 30 })
	f.show("old")
	f.cover("old")
	f.monarch.show("new")
	f.until_true(function() return f.seen("new_proxy", "async_load") end)
	f.monarch.unregister("new")
	f.drain()
	assert(not f.monarch.is_busy() and f.monarch.is_top("old") and f.is_focused("old"))
end)

for _, factory in ipairs({ false, true }) do
	for _, preloaded in ipairs({ false, true }) do
		for _, immediate in ipairs({ false, true }) do
			test("manual readiness: factory=" .. tostring(factory) .. ", preloaded=" .. tostring(preloaded) .. ", init-ready=" .. tostring(immediate), function()
				local f = fixture()
				f.add("old")
				local token, started
				f.monarch.add_listener("observer")
				local settings = { factory = factory }
				if immediate then settings.init = function()
					token = f.monarch.preparation_id("new")
					assert(token and f.monarch.ready_to_show("new", token))
				end end
				f.add("new", settings)
				f.navigation("old", function(event)
					if event == f.monarch.NAVIGATION_STARTED then started = true end
				end)
				f.prepare("new", function(id)
					token = id
					assert(started and f.is_drawn("old") and not f.is_drawn("new"))
					assert(not f.seen("old", f.monarch.TRANSITION_SHOW_OUT))
					assert(not f.is_focused("new"))
					timer.delay(.2, false, function() assert(f.monarch.ready_to_show("new", id)) end)
				end)
				f.show("old")
				if preloaded then f.monarch.preload("new"); f.drain() end
				f.cover("old", "new")
				local calls = 0
				f.monarch.show("new", { sequential = true, timeout = 1 }, nil, function(ok)
					assert(ok); calls = calls + 1
				end)
				f.drain()
				assert(started and f.seen("observer", f.monarch.NAVIGATION_FINISHED) and calls == 1 and not f.monarch.is_busy())
				assert(f.is_drawn("new") and not f.monarch.ready_to_show("new", token))
			end)
		end
	end
end

for _, stage in ipairs({ "loading", "readiness" }) do
	test("timeout preserves old screen during " .. stage .. " and rejects late completion", function()
		local f = fixture()
		f.add("old")
		f.add("new", { load_delay = stage == "loading" and 30 or 1 })
		f.show("old")
		f.cover("old")
		local token, failures, calls = nil, 0, 0
		f.navigation("old", function(event, message)
			if event == f.monarch.NAVIGATION_FAILED then
				assert(message.reason == "timeout" and message.stage == stage)
				failures = failures + 1
			end
		end)
		f.prepare("new", function(id) token = id end)
		f.monarch.show("new", { timeout = .15 }, nil, function(ok, result)
			assert(not ok and result.reason == "timeout"); calls = calls + 1
		end)
		f.drain()
		assert(calls == 1 and failures == 1 and not f.monarch.is_busy())
		assert(f.monarch.is_top("old") and f.is_focused("old"))
		assert(not f.seen("old", f.monarch.TRANSITION_SHOW_OUT))
		assert(not f.is_drawn("new") and not f.monarch.is_loaded("new"))
		assert(not f.monarch.ready_to_show("new", token))
		f.settings("new").load_delay = 1
		f.prepare("new", function(id)
			assert(id ~= token)
			assert(not f.monarch.ready_to_show("new", token))
			assert(f.monarch.ready_to_show("new", id))
		end)
		f.cover("old", "new")
		f.show("new", { timeout = 1 })
		assert(f.monarch.is_top("new"))
	end)
end

test("timeout releases the queue while late loading is reserved for cleanup", function()
	local f = fixture()
	f.add("old"); f.add("slow", { load_delay = 40 }); f.add("queued")
	f.show("old")
	local failure, rejected = 0, 0
	f.monarch.show("slow", { timeout = .1 }, nil, function(ok, result)
		assert(not ok and result.reason == "timeout"); failure = failure + 1
	end)
	f.monarch.show("slow", nil, nil, function(ok, result)
		assert(not ok and result.reason == "cleanup_pending"); rejected = rejected + 1
	end)
	f.monarch.show("queued")
	f.drain()
	assert(failure == 1 and rejected == 1 and f.monarch.is_top("queued"))
	assert(f.is_drawn("queued") and not f.is_drawn("slow") and not f.monarch.is_busy())
end)

test("synchronous initialization overrun fails before outgoing exits", function()
	local f = fixture()
	f.add("old")
	f.add("new", { init = function()
		-- The clock advances without delivering the scheduled timer callback.
		f.block(2)
	end })
	f.show("old")
	f.cover("old")
	local called = 0
	f.monarch.show("new", { timeout = 1 }, nil, function(ok, result)
		assert(not ok and result.reason == "timeout" and result.stage == "initializing")
		called = called + 1
	end)
	f.drain()
	assert(called == 1 and not f.monarch.is_busy() and f.is_focused("old"))
	assert(not f.seen("old", f.monarch.TRANSITION_SHOW_OUT))
end)

test("manual popup covers its source only after readiness and reports completion to it", function()
	local f = fixture()
	f.add("base"); f.add("popup", { popup = true })
	f.show("base")
	local token, finished
	f.navigation("base", function(event) if event == f.monarch.NAVIGATION_FINISHED then finished = true end end)
	f.prepare("popup", function(id) token = id end)
	f.monarch.show("popup")
	f.drain()
	assert(token and f.is_focused("base") and not f.is_drawn("popup"))
	assert(f.monarch.ready_to_show("popup", token))
	f.drain()
	assert(finished and f.is_drawn("base") and f.is_drawn("popup") and f.is_focused("popup"))
end)

test("retained manual scene gets a fresh preparation token when backing into it", function()
	local f = fixture()
	f.add("level", { auto_preload = true }); f.add("menu")
	local previous, count = nil, 0
	f.prepare("level", function(id)
		assert(id ~= previous and not f.monarch.ready_to_show("level", previous))
		previous, count = id, count + 1
		assert(f.monarch.ready_to_show("level", id))
	end)
	f.show("level"); f.show("menu")
	f.cover("menu", "level")
	local done
	f.monarch.back({ timeout = 1 }, nil, function(ok) done = ok end)
	f.drain()
	assert(done and count == 2 and f.monarch.is_top("level") and not f.monarch.is_busy())
end)

test("manual failure reports once and restores outgoing controls through notification", function()
	local f = fixture()
	f.add("old"); f.add("new")
	f.show("old")
	f.monarch.add_listener("old") -- Also registered globally: no duplicate delivery.
	local blocked, failures, completed = false, 0, 0
	f.navigation("old", function(event)
		if event == f.monarch.NAVIGATION_STARTED then blocked = true end
		if event == f.monarch.NAVIGATION_FAILED then blocked = false; failures = failures + 1 end
	end)
	f.prepare("new", function(id)
		assert(f.monarch.fail_to_show("new", id, "level_setup_failed"))
		assert(not f.monarch.fail_to_show("new", id, "duplicate"))
	end)
	f.monarch.show("new", nil, nil, function(ok, result)
		assert(not ok and result.reason == "level_setup_failed"); completed = completed + 1
	end)
	f.drain()
	assert(not blocked and failures == 1 and completed == 1 and f.is_focused("old"))
end)

test("preparation timeout stops before a deliberately long outgoing transition", function()
	local f = fixture()
	f.add("old", { hold_out = true }); f.add("new")
	f.show("old")
	local calls = 0
	f.monarch.show("new", { sequential = true, timeout = 1 }, nil, function(ok)
		assert(ok); calls = calls + 1
	end)
	f.until_true(function() return f.held("old") end)
	f.block(10)
	f.drain()
	assert(calls == 0 and f.monarch.is_busy())
	f.release("old"); f.drain()
	assert(calls == 1 and not f.monarch.is_busy())
end)

test("invalid timeouts never occupy the navigation queue", function()
	local f = fixture(); f.add("new")
	for _, timeout in ipairs({ -1, math.huge, 0 / 0, "2" }) do
		assert(not pcall(f.monarch.show, "new", { timeout = timeout }))
		assert(not pcall(f.monarch.back, { timeout = timeout }))
		assert(not f.monarch.is_busy())
	end
end)

test("proxy error reports failure and leaves the outgoing scene usable", function()
	local f = fixture(); f.add("old"); f.add("new", { fail_load = true })
	f.show("old")
	local called = 0
	f.monarch.show("new", nil, nil, function(ok, result)
		assert(not ok and result.reason == "proxy_error:5"); called = called + 1
	end)
	f.drain()
	assert(called == 1 and not f.monarch.is_busy() and f.is_focused("old"))
	assert(not f.seen("old", f.monarch.TRANSITION_SHOW_OUT))
end)

test("removing a scene waiting for readiness rejects its token and releases navigation", function()
	local f = fixture(); f.add("old"); f.add("new")
	f.show("old")
	local token, called
	f.prepare("new", function(id) token = id end)
	f.monarch.show("new", { timeout = 1 }, nil, function(ok, result)
		assert(not ok and result.reason == "unregistered"); called = true
	end)
	f.until_true(function() return token end)
	f.monarch.unregister("new")
	f.drain()
	assert(called and not f.monarch.is_busy() and f.is_focused("old"))
	assert(not f.monarch.ready_to_show("new", token))
end)

for _, sequential in ipairs({ false, true }) do
	test("prepared show dispatches entrance with enable: sequential=" .. tostring(sequential), function()
		local f = fixture(); f.add("old"); f.add("new")
		f.show("old")
		f.show("new", { sequential = sequential })
		local enabled = f.last("new_proxy", "enable")
		local entrance = f.last("new", f.monarch.TRANSITION_SHOW_IN)
		assert(enabled.frame == entrance.frame, "Enabled GUI can render before entrance sets its starting state")
	end)
end

test("prepared back dispatches entrance with enable", function()
	local f = fixture(); f.add("old"); f.add("new")
	f.show("old"); f.show("new")
	f.monarch.back(); f.drain()
	local enabled = f.last("old_proxy", "enable")
	local entrance = f.last("old", f.monarch.TRANSITION_BACK_IN)
	assert(enabled.frame == entrance.frame, "Returning GUI can render before its entrance")
end)

for _, settings in ipairs({ {}, { factory = true }, { factory = true, auto_preload = true } }) do
	test("destroyed scene drops preparation handler: factory=" .. tostring(settings.factory) .. ", cached=" .. tostring(settings.auto_preload), function()
		local f = fixture(); f.add("level", settings); f.add("menu")
		local calls = 0
		f.prepare("level", function(token)
			calls = calls + 1
			assert(f.monarch.ready_to_show("level", token))
		end)
		f.show("level"); f.show("menu")
		-- A new instance that does not register a handler is automatically ready.
		f.prepare("level", nil)
		local completed
		f.monarch.back({ timeout = 1 }, nil, function(ok) completed = ok end)
		f.drain()
		assert(completed and calls == 1 and f.monarch.is_top("level"))
		assert(not f.monarch.is_busy())
	end)
end

print(count .. " show/back option tests passed")
