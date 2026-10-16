
# Monarch API

## Preparation and readiness

Navigation prepares the destination before changing the stack or starting outgoing transitions. Register `on_prepare` during the scene's `init`, just like `on_transition`, to opt into explicit readiness. No proxy/factory setting is needed. Without a handler, the scene is automatically ready after initialization. Ordinary proxy scenes initialize before rendering is enabled. Scenes with a preparation handler are then enabled so updates and timers run: **the scene owns hiding its visuals, withholding input, and not starting gameplay until its entrance**. Factory instances also need scene-owned initial visibility because creation has no separate rendering-enable phase. Monarch does not acquire incoming input focus during preparation.

```lua
-- In the scene's init; keep visuals hidden here.
monarch.on_prepare("level", function(token)
    build_level_incrementally(function()
        monarch.ready_to_show("level", token)
    end)
end)
-- Continue forwarding on_message to monarch.on_message as for transitions.
```

The registered `on_prepare(id, fn)` handler runs after initialization and also when returning to a retained hidden scene. Register it during `init`, not later in an update/timer: Monarch makes its readiness decision after initialization. A visible scene being reused is already ready. A destroyed instance's handler is discarded; a retained instance keeps it. `preparation_id(id)` returns the current activation token (or nil), allowing immediate readiness from init after registering the handler. `ready_to_show(id, token)` accepts a current token once; duplicate, expired and stale signals return false. Capture the token when starting asynchronous work rather than retrieving a new token in an old callback. `fail_to_show(id, token, reason)` reports setup failure. All required setup must be completed before signaling; optional decorations can continue after show-in.

Preparation must use independent asynchronous work (engine resource APIs, updates, timers, events). Do not wait for another queued Monarch show/preload action to complete before signaling ready: that queue is deliberately reserved by the current navigation. Preload dependent screens before starting navigation if needed. Nested registration is supported; it does not bypass the navigation queue.

Pass `timeout` in seconds to show/replace/back. Omitted or zero disables the deadline. A finite positive value covers loading, initialization and manual readiness from when the queued action starts, excluding transition animations. Synchronous Lua cannot be interrupted; elapsed wall time is checked when execution resumes. The callback receives `(success, result)` with `result.navigation_id`, and on failure `reason` and `stage` (loading/initializing/readiness). Handle false before assuming a scene appeared.

Register `on_navigation(id, fn)` in the outgoing scene to receive `NAVIGATION_STARTED`, `NAVIGATION_FAILED`, and, if that scene remains loaded, `NAVIGATION_FINISHED`. Forward on_message to Monarch. Global add_listener listeners also receive these messages. Fields: navigation_id, screen (destination), previous_screen (source), operation (show/back), stage, and failure reason. Started means dequeued navigation, not a raw queued request; it is not an awaited exit transition. Failure leaves the outgoing scene's stack/focus intact so it can restore controls. Failure also emits SCREEN_TRANSITION_FAILED. Completion is after transitions and cleanup; unloaded sources cannot receive it, so use the callback or a persistent listener. Closing the last screen via back has no destination preparation phase.

An underlying engine load may outlive timeout. Its scene remains reserved until completion/cleanup; attempts to reuse it report `cleanup_pending` while other destinations can proceed. A load that never reports completion remains reserved. Explicit preload/unload also reject that reserved scene rather than stealing its pending operation. Loaded-scene `reload=true` fails before teardown with `reload_requires_unloaded_screen`: an instance cannot be destroyed and preserved for recovery simultaneously. Use a separate loading scene, or unload while another scene provides coverage. Normal same-instance reuse retains it while replaying transitions.

For slow-readiness testing, delay ready_to_show in your scene. The old set_debug_load_delay API has been removed; resource delays remain covered by automated tests. Readiness means safe to begin revealing, not that gameplay has started. Existing show-in, transition-finished and focus events still control presentation: entrance transition completion precedes acquiring focus and FOCUS_GAINED, then SCREEN_TRANSITION_IN_FINISHED. Custom handlers must acknowledge TRANSITION_DONE; preparation timeout does not time out an unfinished animation.

## monarch.show(screen_id, [options], [data], [callback])
Show a Monarch screen. Note that the screen must be registered before it can be shown. The `init()` function of the screen script (either `screen_proxy.script` or `screen_factory.script`) takes care of registration. This operation will be added to the queue if Monarch is busy.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to show.
* `options` (table) - Options when showing the new screen (see below).
* `data` (table) - Optional data to associate with the screen.  Retrieve using `monarch.data()`.
* `callback` (function) - Optional `(success, result)` callback after navigation completes or preparation fails.

The options table can contain the following fields:

* `clear` (boolean) - If the `clear` flag is set Monarch will search the stack for the screen that is to be shown. If the screen already exists in the stack and the clear flag is set Monarch will remove all screens between the current top and the screen in question.
* `reload` (boolean) - Loaded-instance reload is rejected before teardown; see Preparation and readiness.
* `timeout` (number) - Optional preparation deadline in seconds; zero or omitted disables it.
* `no_stack` (boolean) - If the `no_stack` flag is set Monarch will load the screen without adding it to the screen stack.
* `sequential` (boolean) - Finish the outgoing transition before starting the incoming transition. Resources are prepared before the exit; outgoing collection cleanup waits until the incoming collection has been enabled and initialized.
* `parallel_popup_exit` (boolean) - Opt into concurrent popup exits when showing a non-popup screen. Defaults to false. Ignored for popup destinations and when `sequential` is true. The show callback and queued navigation wait for every departing popup as well as the screen transitions. This overlaps lifecycle operations; it does not promise same-frame loading or unloading.
* `transition_in` (boolean) - Set to false to request an instant `show_in` transition. Omitted or true uses the configured animation.
* `transition_out` (boolean) - Set to false to request instant `show_out` transitions for all departing popups and the current screen. Omitted or true uses their configured animations.
* `pop` (number) - If `pop` is set to a number, Monarch will pop that number of screens from the stack before adding the new one.

Instant requests preserve transition messages, completion tracking, focus handling and unloading. The standard GUI transitions snap to their final state. Custom transition handlers must honor `message.instant`; custom GUI transition functions receive duration and delay zero. See [Transitions](README_TRANSITIONS.md#per-navigation-overrides). These options do not skip engine lifecycle waits or change which transitions are normally sent.

Visual continuity requires overlapping outgoing and incoming collection lifetimes, including with `sequential = true`. This option sequences animations; it is not an unload-before-load memory mode. Peak memory may therefore increase for scene-specific resources and instances. For heavy scenes, an intermediate lightweight loading screen can allow the previous scene to unload before preparing the next.

Preparation failures preserve the current screen. Check the callback's success argument and/or NAVIGATION_FAILED instead of treating every completion callback as successful loading.

For example, leave gameplay and its overlays together while keeping the menu entrance:

```lua
monarch.show("menu", { clear = true, parallel_popup_exit = true, transition_out = false })
```

## monarch.replace(screen_id, [options], [data], [callback])
Replace the top of the stack with a new screen. Equivalent to calling `monarch.show()` with `pop = 1`. It takes the same parameters as `monarch.show()`.


## monarch.hide(screen_id, [callback])
Hide a screen that has been shown using the `no_stack` option. If used on a screen that was shown without the `no_stack` option it will only hide it if the screen is on top of the stack and the behavior will be exactly like if `monarch.back()` had been called. This operation will be added to the queue if Monarch is busy.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to hide.
* `callback` (function) - Optional function to call when the screen has been hidden.

**RETURN**
* `success` (boolean) - True if the process of hiding the screen was started successfully.


## monarch.clear([callback])
Clear the stack of screens completely. Any visible screen will be hidden by navigating back out from them. This operation will be added to the queue if Monarch is busy.

**PARAMETERS**
* `callback` (function) - Optional function to call when the stack has been cleared.


## monarch.back([options], [data], [callback])
Go back to a previous Monarch screen. This operation will be added to the queue if Monarch is busy.

**PARAMETERS**
* `options` (table) - Options when showing the new screen (see below).
* `data` (table) - Optional data to associate with the screen you are going back to.  Retrieve using `monarch.data()`.
* `callback` (function) - Optional `(success, result)` callback after navigation completes or preparation fails.

The options table can contain the following fields:

* `sequential` (boolean) - Finish the outgoing transition before starting the incoming transition. Resources are prepared before the exit; outgoing collection cleanup waits until the incoming collection has been enabled and initialized.
* `transition_in` (boolean) - Set to false to request an instant `back_in` transition.
* `transition_out` (boolean) - Set to false to request an instant `back_out` transition.
* `timeout` (number) - Optional preparation deadline in seconds; zero or omitted disables it.

Omitted or true uses the configured animation. These are the same overrides as `show()`, applied to back transitions. Returning from a popup to its underlying non-popup screen still does not send `back_in`, since that screen remained visible. Popup teardown still finishes before that screen regains focus and resumes its timestep. `hide()` and `clear()` retain their existing signatures and defaults.


## monarch.preload(screen_id, [options], [callback])
Preload a Monarch screen. This will load but not enable the screen. This is useful for content heavy screens that you wish to be able to show without having to wait for it load. This operation will be added to the queue if Monarch is busy.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to preload.
* `options` (table)
* `callback` (function) - Optional function to call when the screen is preloaded.

The options table can contain the following fields:

* `keep_loaded` (boolean) - If the `keep_loaded` flag is set Monarch will keep the screen preloaded even after a `hide()` or `back()` navigation event that normally would unload the screen.


## monarch.is_preloading(screen_id)
Check if a Monarch screen is preloading (via monarch.preload() or the Preload screen setting).

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to check

**RETURN**
* `preloading` (boolean) - True if the screen is preloading.


## monarch.when_preloaded(screen_id, callback)
Invoke a callback when a screen has been preloaded.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to check
* `callback` (function) - Function to call when the screen has been preloaded.


## monarch.unload(screen_id, [callback])
Unload a preloaded Monarch screen. A preloaded screen will automatically get unloaded when hidden, but this function can be useful if a screen has been preloaded and it needs to be unloaded again without actually hiding it. This operation will be added to the queue if Monarch is busy.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to unload.
* `callback` (function) - Optional function to call when the screen is unloaded.


## monarch.top([offset])
Get the id of the screen at the top of the stack.

**PARAMETERS**
* `offset` (number) - Optional offset from the top of the stack, ie -1 to get the previous screen

**RETURN**
* `screen_id` (string|hash) - Id of the requested screen


## monarch.bottom([offset])
Get the id of the screen at the bottom of the stack.

**PARAMETERS**
* `offset` (number) - Optional offset from the bottom of the stack

**RETURN**
* `screen_id` (string|hash) - Id of the requested screen


## monarch.data(screen_id)
Get the data associated with a screen (from a call to `monarch.show()` or `monarch.back()`).

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to get data for

**RETURN**
* `data` (table) - Data associated with the screen.


## monarch.screen_exists(screen_id)
Check if a Monarch screen exists.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to get data for

**RETURN**
* `exists` (boolean) - True if the screen exists.


## monarch.is_busy()
Check if Monarch is busy showing and/or hiding a screen.

**RETURN**
* `busy` (boolean) - True if busy hiding and/or showing a screen.


## monarch.is_top(screen_id)
Check if a Monarch screen is at the top of the view stack.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to check

**RETURN**
* `exists` (boolean) - True if the screen is at the top of the stack.


## monarch.is_visible(screen_id)
Check if a Monarch screen is visible.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to check

**RETURN**
* `exists` (boolean) - True if the screen is visible.


## monarch.set_timestep_below_popup(screen_id, timestep)
Set the timestep to apply for a screen when below a popup.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to change timestep setting for
* `timestep` (number) - Timestep to apply


## monarch.add_listener([url])
Add a URL that will be notified of navigation events.

**PARAMETERS**
* `url` (url) - URL to send navigation events to. Will use current URL if omitted.


## monarch.remove_listener([url])
Remove a previously added listener.

**PARAMETERS**
* `url` (url) - URL to remove. Will use current URL if omitted.


## monarch.post(screen_id, message_id, [message])
Post a message to a visible screen. The screen must have set a message listener using `monarch.on_post()`.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen to post message to
* `message_id` (string|hash) - Id of the message to send
* `message` (table|nil) - Optional message data to send

**RETURN**
* `result` (boolean) - True if the message was sent
* `error` (string|nil) - Error message if unable to send message


## monarch.on_transition(screen_id, fn)
Set a function to be called when a screen should transition in our out. The function will receive (message_id, message, sender) with `message_id` being one of the transition constants. 
IMPORTANT! You must call `monarch.on_message(message_id, message, sender)` from the same script as this function was called.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen
* `fn` (function) - The function to call when a transition should start


## monarch.on_focus_change(screen_id, fn)
Set a function to be called when a screen gains or loses focus. The function will receive (message_id, message, sender) with `message_id` being one of the focus change constants. 
IMPORTANT! You must call `monarch.on_message(message_id, message, sender)` from the same script as this function was called.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen
* `fn` (function) - The function to call screen focus changes


## monarch.on_post(screen_id, fn_or_url)
Set either a function to be called when `msg.post()` is called on a specific screen or a URL where the message is sent.

IMPORTANT! If you provide a function you must also make sure to call `monarch.on_message(message_id, message, sender)` from the same script as this function was called.

**PARAMETERS**
* `screen_id` (string|hash) - Id of the screen
* `fn_or_url` (function) - The function to call or URL to send message to


## monarch.debug()
Enable verbose logging of the internals of Monarch.


## monarch.SCREEN_TRANSITION_IN_STARTED
Message sent to listeners added using `monarch.add_listener()` when a screen has started to transition in.

**PARAMETERS**
* `screen` (hash) - Id of the screen
* `previous_screen` (hash) - Id of the previous screen (if any)


## monarch.SCREEN_TRANSITION_IN_FINISHED
Message sent to listeners added using `monarch.add_listener()` when a screen has finished to transition in.

**PARAMETERS**
* `screen` (hash) - Id of the screen
* `previous_screen` (hash) - Id of the previous screen (if any)


## monarch.SCREEN_TRANSITION_OUT_STARTED
Message sent to listeners added using `monarch.add_listener()` when a screen has started to transition out.

**PARAMETERS**
* `screen` (hash) - Id of the screen
* `next_screen` (hash) - Id of the next screen (if any)


## monarch.SCREEN_TRANSITION_OUT_FINISHED
Message sent to listeners added using `monarch.add_listener()` when a screen has finished to transition out.

**PARAMETERS**
* `screen` (hash) - Id of the screen
* `next_screen` (hash) - Id of the next screen (if any)
