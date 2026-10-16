# Transitions
You can add optional transitions when navigating between screens. The default behavior is that screen navigation is instant but if you have defined a transition for a screen Monarch will wait until the transition is completed before proceeding.

Transitions are configured through the `monarch.on_transition(screen_id, fn)` function. The function defines for which screen to configure transitions and sets a function to be called when a transition should be started. This function must accept (message_id, message, sender) as arguments, with `message_id` defining which type of transition to start:

* `transition_show_in` (constant defined as `monarch.TRANSITION_SHOW_IN`)
* `transition_show_out` (constant defined as `monarch.TRANSITION_SHOW_OUT`)
* `transition_back_in` (constant defined as `monarch.TRANSITION_BACK_IN`)
* `transition_back_out` (constant defined as `monarch.TRANSITION_BACK_OUT`)

When a transition is completed it is up to the developer to send a `transition_done` (constant `monarch.TRANSITION_DONE`) message back to the sender to indicate that the transition is completed and that Monarch can continue the navigation sequence.

## Per-navigation overrides

`show()` (including `replace()`) and `back()` accept independent `transition_in = false` and `transition_out = false` options. Omitted or true preserves the scene's configured animation. A false value requests the final visual state immediately, without the animation's duration or delay. Exit overrides on `show()` also apply to each departing popup. `parallel_popup_exit = true` additionally allows those popup exits to overlap when showing a non-popup; `sequential = true` takes precedence.

Monarch still delivers the appropriate `TRANSITION_SHOW_IN`, `TRANSITION_SHOW_OUT`, `TRANSITION_BACK_IN` or `TRANSITION_BACK_OUT` message, with `message.instant = true`, and waits for its normal `TRANSITION_DONE` acknowledgement. Loading, script initialization, focus messages and unload cleanup keep their normal lifecycle. An instant animation is not a promise that navigation completes in one frame.

The standard GUI transition helper handles the flag for all four directions. Built-in fade, slide and scale functions set the final property directly, cancel its previous animation and acknowledge completion. Custom functions registered with `.show_in()`, `.show_out()`, `.back_in()` or `.back_out()` receive duration and delay zero and must apply their final state and invoke the callback. A custom `monarch.on_transition()` handler must check `message.instant` itself and acknowledge after applying its final state. Ignoring this flag preserves its normal animation; Monarch does not forcibly interrupt arbitrary user code.

## Visual handover and cleanup

When navigating to a different screen with `show()`, `replace()` or `back()`, Monarch prepares the incoming resources before starting exits. It retains outgoing collections until the incoming collection is enabled and its scripts have initialized. An exit handler can finish its animation and acknowledge `TRANSITION_DONE` without destroying the background it leaves on screen. Unloading and its cleanup waits then happen after the handover, rather than creating an empty interval between collections. This also applies to popup replacement and already-preloaded destinations; no new option is required.

`sequential = true` still orders exit animation before entrance animation. It no longer requires resource unloading to finish before the incoming collection can be enabled. Default popup exit animations remain serial unless `parallel_popup_exit` applies. Navigation remains busy, and its completion callback and queued requests wait for all transitions and cleanup. A resource preparation failure leaves the outgoing stack and input focus intact, emits `SCREEN_TRANSITION_FAILED`, and clears queued requests through the existing error path.

Transition handlers still own visibility: a handler that fades everything to transparent can intentionally expose what is behind it. Monarch does not capture the framebuffer, force opacity, or change GUI render orders. When replacing translucent overlays, both collections may briefly be enabled during the handover. The guarantee is lifecycle coverage, not pixel-identical compositing of arbitrary transitions.

Reloading/reopening the **same registered instance** retains the existing serial teardown behavior: the same instance cannot be retained while being destroyed and recreated. Use distinct screen instances or a separate transition overlay if that operation needs uninterrupted coverage. Returning from a popup to its already-visible underlying non-popup retains its existing teardown-before-resume behavior. `clear()` and hiding the last screen intentionally remove coverage.

## Transition URL
This property is deprecated and will be removed in a future version of Monarch.

~~It is also possible to configure transitions through the `Transition Url` (proxy) or `Transition Id` (collectionfactory) property. This property must be the URL/Id to a script with an `on_message` handlers for the transition messages mentioned above.~~


## Predefined transitions
Monarch comes with a system for setting up transitions easily in a gui_script using the `monarch.transitions.gui` module. Example:

```lua
local transitions = require "monarch.transitions.gui"
local monarch = require "monarch.monarch"

function init(self)
	-- create transitions for the node 'root'
	-- the node will slide in/out from left and right with
	-- a specific easing, duration and delay
	local transition = transitions.create(gui.get_node("root"))
		.show_in(transitions.slide_in_right, gui.EASING_OUTQUAD, 0.6, 0)
		.show_out(transitions.slide_out_left, gui.EASING_INQUAD, 0.6, 0)
		.back_in(transitions.slide_in_left, gui.EASING_OUTQUAD, 0.6, 0)
		.back_out(transitions.slide_out_right, gui.EASING_INQUAD, 0.6, 0)

	monarch.on_transition("foobar", transition)
end

function on_message(self, message_id, message, sender)
	monarch.on_message(message_id, message, sender)
	-- you can also check when a transition has completed:
	if message_id == monarch.TRANSITION_DONE and message.transition == monarch.TRANSITION_SHOW_IN then
		print("Show in done!")
	end
end
```

It is also possible to assign transitions to multiple nodes:

```lua
function init(self)
	local transition = transitions.create() -- note that no node is passed to transition.create()!
		.show_in(gui.get_node("node1"), transitions.slide_in_right, gui.EASING_OUTQUAD, 0.6, 0)
		.show_in(gui.get_node("node2"), transitions.slide_in_right, gui.EASING_OUTQUAD, 0.6, 0)
end
```

The predefined transitions provided by `monarch.transitions.gui` are:

* `slide_in_right`
* `slide_in_left`
* `slide_in_top`
* `slide_in_bottom`
* `slide_out_right`
* `slide_out_left`
* `slide_out_top`
* `slide_out_bottom`
* `scale_in`
* `scale_out`
* `fade_in` - Set node alpha to fully transparent (i.e. 0.0) and fade to fully opaque (i.e. 1.0)
* `fade_out` - Set node alpha to fully opaque (i.e. 1.0) and fade to fully transparent (i.e. 0.0)

Additionally there's functionality to create a full set of transitions for common transition styles:

* `transitions.in_right_out_left(node, duration, [delay], [easing])`
* `transitions.in_left_out_right(node, duration, [delay], [easing])`
* `transitions.in_left_out_left(node, duration, [delay], [easing])`
* `transitions.in_right_out_right(node, duration, [delay], [easing])`
* `transitions.fade_in_out(node, duration, [delay], [easing])`

**PARAMETERS**
* `node` (node) - Gui node to animate.
* `duration` (number) - Transition duration in seconds.
* `delay` (number) - Transition delay in seconds.
* `easing` (table) - Easing table, created from a function provided by `monarch.transitions.easings`

**RETURN**
* `instance` - The created transition instance


## Custom transitions
You can create and use your own transition as long as the provided transition function has the following function signature:

	custom_transition(node, to, easing, duration, delay, cb)

**PARAMETERS**
* `node` (node) - Gui node to animate.
* `to` (vector3) - Target position.
* `easing` (number) - One of gui.EASING_* constants.
* `duration` (number) - Transition duration in seconds.
* `delay` (number) - Transition delay in seconds.
* `cb` (function) - This function must be called when the transition is completed.


## Dynamic orientation and resized windows
When using dynamic screen orientation together with gui layouts or using transitions on a platform where the window can be resized it's important to make sure that the created transitions adapt to the change in orientation or window size. The transition system takes care of layout changes automatically, but when it comes to changes in window size you need to notify the transition manually:

```lua
local transitions = require "monarch.transitions.gui"

function init(self)
	self.transition = transitions.create(gui.get_node("root"))
end

function on_message(self, message_id, message, sender)
	if message_id == hash("my_resize_message") then
		transition.window_resized(message.width, message.height)
	end
end
```

## Screen stack info and transitions
The transition message sent transition listener script contains additional information about the transition. For the `transition_show_in` and `transition_back_out` messages the message contains the previous screen id:

```lua
function on_message(self, message_id, message, sender)
	if message_id == hash("transition_show_in") or message_id == hash("transition_back_out") then
		print(message.previous_screen)
	end
end
```

For the `transition_show_out` and `transition_back_in` messages the message contains the next screen id:

```lua
function on_message(self, message_id, message, sender)
	if message_id == hash("transition_show_out") or message_id == hash("transition_back_in") then
		print(message.next_screen)
	end
end
```

This information can be used to create dynamic transitions where the direction of the transition depends on the previous/next screen.
