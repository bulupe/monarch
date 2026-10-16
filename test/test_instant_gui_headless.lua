-- Standalone Lua 5.1+/Fengari tests for final GUI state and completion ordering.
-- Property/message doubles verify the helper contract, not native rendering.
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/test/[^/]+$") or "."
package.path = root .. "/?.lua;" .. package.path
package.loaded.socket = { gettime = function() return 0 end }
hash = function(value) return value end
local vector_mt = { __add = function(a, b)
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end }
vmath = { vector3 = function(x, y, z)
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vector_mt)
end }
sys = { get_config_int = function() return 100 end }
local messages, animations, cancellations = {}, {}, {}
local function copy(t)
	local c = {}
	for k, v in pairs(t) do c[k] = v end
	return c
end
msg = {
	url = function() return "gui" end,
	post = function(url, id, data) messages[#messages + 1] = { url = url, id = id, data = data } end,
}
gui = {
	PROP_POSITION = "position", PROP_SCALE = "scale", PROP_COLOR = "color",
	get_position = function(node) return node.position end,
	get_scale = function(node) return node.scale end,
	get_color = function(node) return copy(node.color) end,
	set_position = function(node, value) node.position = copy(value) end,
	set_scale = function(node, value) node.scale = copy(value) end,
	set_color = function(node, value) node.color = copy(value) end,
	set = function(node, prop, value) node[prop] = copy(value) end,
	cancel_animations = function(node, prop) cancellations[#cancellations + 1] = { node, prop } end,
	animate = function(node, prop, value, easing, duration, delay, cb)
		animations[#animations + 1] = { node = node, prop = prop, value = value, duration = duration, delay = delay, cb = cb }
	end,
}
local monarch = require "monarch.monarch"
local transitions = require "monarch.transitions.gui"
local function node()
	return { position = vmath.vector3(10, 20, 0), scale = vmath.vector3(2, 2, 1), color = { x = 1, y = 1, z = 1, w = 1 } }
end
local count = 0
local function test(name, fn)
	messages, animations, cancellations = {}, {}, {}
	fn()
	count = count + 1
	print("PASS " .. name)
end

for _, direction in ipairs({ "show_in", "show_out", "back_in", "back_out" }) do
	test(direction .. " instant fade/scale/slide sets final state and acknowledges once", function()
		local fade, scale, slide = node(), node(), node()
		local entering = direction:sub(-2) == "in"
		local helper = transitions.create()
		helper[direction](fade, entering and transitions.fade_in or transitions.fade_out, "linear", 2, 3)
		helper[direction](scale, entering and transitions.scale_in or transitions.scale_out, "linear", 2, 3)
		helper[direction](slide, entering and transitions.slide_in_right or transitions.slide_out_right, "linear", 2, 3)
		-- Simulate a cached GUI left at the opposite transition endpoint.
		fade.color.w = entering and 0 or 1
		if entering then scale.scale = vmath.vector3(0, 0, 1) end
		helper.handle(monarch["TRANSITION_" .. direction:upper()], { instant = true }, "screen")
		assert(#animations == 0 and #cancellations == 3)
		assert(fade.color.w == (entering and 1 or 0))
		assert(scale.scale.x == (entering and 2 or 0))
		assert(slide.position.x == (entering and 10 or 110))
		assert(#messages == 1 and messages[1].id == monarch.TRANSITION_DONE)
		assert(messages[1].data.transition == monarch["TRANSITION_" .. direction:upper()])
	end)
end

test("normal animation retains timings and waits for every node", function()
	local helper = transitions.create()
	helper.show_in(node(), transitions.fade_in, "linear", 2, 3)
	helper.show_in(node(), transitions.scale_in, "linear", 4, 5)
	helper.handle(monarch.TRANSITION_SHOW_IN, {}, "screen")
	assert(#messages == 0 and #animations == 2 and #cancellations == 0)
	assert(animations[1].duration == 2 and animations[1].delay == 3)
	assert(animations[2].duration == 4 and animations[2].delay == 5)
	animations[1].cb()
	assert(#messages == 0)
	animations[2].cb()
	assert(#messages == 1)
end)

test("custom transitions receive zero timings and all finish before acknowledgement", function()
	local helper = transitions.create()
	local called = 0
	local function custom(n, to, easing, duration, delay, cb)
		assert(duration == 0 and delay == 0)
		assert(#messages == 0, "Acknowledged before every node was updated")
		called = called + 1
		cb()
	end
	helper.back_out(node(), custom, "linear", 2, 3)
	helper.back_out(node(), custom, "linear", 4, 5)
	helper.handle(monarch.TRANSITION_BACK_OUT, { instant = true }, "screen")
	assert(called == 2 and #messages == 1)
end)

test("a synchronous node does not finish a mixed transition early", function()
	local helper = transitions.create()
	helper.show_in(node(), transitions.instant, "linear", 2, 3)
	helper.show_in(node(), transitions.fade_in, "linear", 2, 3)
	helper.handle(monarch.TRANSITION_SHOW_IN, {}, "screen")
	assert(#messages == 0 and #animations == 1)
	animations[1].cb()
	assert(#messages == 1)
end)

test("no configured transition still acknowledges once", function()
	transitions.create().handle(monarch.TRANSITION_BACK_OUT, { instant = true }, "screen")
	assert(#messages == 1 and #animations == 0)
end)

print(count .. " instant GUI tests passed")
