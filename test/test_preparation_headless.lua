local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/test/[^/]+$")
package.path = root .. "/?.lua;" .. package.path
local preparation = require "monarch.utils.preparation"
local function fixture(timeout)
	local f = { now = 0, calls = 0, cancelled = 0 }
	f.request = preparation.new(timeout, function() return f.now end,
		function(delay, fn) f.delay, f.fire = delay, fn; return 1 end,
		function() f.cancelled = f.cancelled + 1 end,
		function(ok, reason, request)
			f.calls, f.ok, f.reason, f.finished_id = f.calls + 1, ok, reason, request.id
		end)
	return f
end

local f = fixture(2)
assert(f.request.signal(f.request.id))
assert(not f.request.done, "Early ready must still wait for initialization")
assert(not f.request.signal(f.request.id), "Duplicate signal must be ignored")
assert(f.request.complete() and f.calls == 1 and f.ok and f.cancelled == 1)
f.fire()
assert(f.calls == 1, "A late timeout must not fail a completed request")

local timed = fixture(2)
timed.fire()
assert(timed.calls == 1 and not timed.ok and timed.reason == "timeout")
assert(not timed.request.signal(timed.request.id) and not timed.request.complete())

local blocked = fixture(2)
blocked.now = 3 -- Synchronous init consumed the deadline before timers ran.
assert(not blocked.request.complete())
assert(blocked.calls == 1 and blocked.reason == "timeout")

local old, next_request = fixture(nil), fixture(0)
assert(old.fire == nil and next_request.fire == nil)
assert(not next_request.request.signal(old.request.id))
assert(old.request.fail("setup_failed") and old.reason == "setup_failed")
assert(not old.request.fail("again") and old.calls == 1)
assert(next_request.request.signal(next_request.request.id) and next_request.request.complete())
for _, value in ipairs({ -1, math.huge, "2" }) do
	assert(not pcall(fixture, value))
end
assert(not pcall(fixture, 0 / 0))
print("preparation deadline, token, failure and exactly-once completion tests passed")
