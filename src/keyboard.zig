const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const utility = @import("utility.zig");
const gpa = std.heap.c_allocator;
const Toplevel = @import("toplevel.zig").Toplevel;
const Server = @import("server.zig").Server;
const DLL = std.DoublyLinkedList(KeyEvent);

pub const KeyEvent = struct {
    keysym: xkb.Keysym,
    keycode: u32,
    timems: u32 = 0, // Use event.time_msec from wlroots
    state: enum { pressed, released } = .pressed,
    processed: bool = false,
};

pub const Keyboard = struct {
    server: *Server,
    link: wl.list.Link = undefined,
    device: *wlr.InputDevice,
    // keypressedtime: [256]u64 = .{0} ** 256,
    //zero means not pressed at all!
    //for storing last press time in this keyboard!

    // keyreleased:std.ArrayList(KeyEvent),
    bufferin: utility.OrderedAutoHashMap(u64, KeyEvent),
    bufferout: DLL,
    // releasedlist: std.ArrayList(KeyEvent),
    listpresstime: [256]u64 = .{0} ** 256,

    keychecktimer: ?*wl.EventSource = null,
    // keybuffertimer: ?*wl.EventSource = null,
    keyholdthreshold: i32 = 200,
    keycheckdelay: i32 = 50,
    // keybufferdelay: i32 = 400,

    wlrkeyboard: *wlr.Keyboard,
    // lastkeyreleased: KeyEvent = undefined,

    modifierflags: wlr.Keyboard.ModifierMask = wlr.Keyboard.ModifierMask{},

    modifiers: wl.Listener(*wlr.Keyboard) = .init(handleModifiers),
    key: wl.Listener(*wlr.Keyboard.event.Key) = .init(handleKey),
    destroy: wl.Listener(void) = .init(handleDestroy),

    pub fn create(server: *Server, device: *wlr.InputDevice) !void {
        const keyboard = try server.alloc.create(Keyboard);
        errdefer server.alloc.destroy(keyboard);

        keyboard.* = .{
            .server = server,
            .device = device,
            .bufferin = utility.OrderedAutoHashMap(u64, KeyEvent).init(server.alloc),
            .wlrkeyboard = device.toKeyboard(),
            .bufferout = DLL{},
            // .releasedlist = std.ArrayList(KeyEvent).init(server.alloc),
        };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        // const wlr_keyboard = device.toKeyboard();
        if (!keyboard.wlrkeyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        keyboard.wlrkeyboard.setRepeatInfo(25, 600);

        keyboard.wlrkeyboard.events.modifiers.add(&keyboard.modifiers);
        keyboard.wlrkeyboard.events.key.add(&keyboard.key);

        // keyboard.lastkeyreleased = KeyEvent{
        // .presstime = 0,
        // .keycode = 0,
        // .keysym = xkb.State.keyGetOneSym(wlrkeyboard.xkb_state.?, 0),
        // .state = .pressed,
        // };

        keyboard.setupTimer(keyboard.keycheckdelay, keyboard.keychecktimer, Keyboard, handleKeyCheckTimeOut, keyboard);
        server.seat.setKeyboard(keyboard.wlrkeyboard);
        server.keyboards.append(keyboard);
    }

    pub fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlrkeyboard: *wlr.Keyboard) void {
        const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);
        keyboard.server.seat.setKeyboard(wlrkeyboard);
        keyboard.server.seat.keyboardNotifyModifiers(&wlrkeyboard.modifiers);
    }

    fn setupTimer(keyboard: *Keyboard, delay: i32, keytimer: ?*wl.EventSource, comptime T: type, comptime func: fn (data: *T) c_int, data: *T) void {
        // keyboard.server.loop.addT
        const server = keyboard.server;
        if (keytimer) |timer| {
            timer.timerUpdate(delay) catch |err| {
                std.log.err("Failed to update timer: {}", .{err});
                return;
            };
        } else {
            if (keytimer == keyboard.keychecktimer) {
                keyboard.keychecktimer = server.loop.addTimer(*T, func, data) catch null;
                if (keyboard.keychecktimer) |timer| {
                    timer.timerUpdate(delay) catch |err| {
                        std.log.err("Failed to update timer: {}", .{err});
                        return;
                    };
                }
            }
            // else if (keytimer == keyboard.keybuffertimer) {
            // keyboard.keybuffertimer = server.loop.addTimer(*T, func, data) catch null;
            // if (keyboard.keybuffertimer) |timer| {
            // timer.timerUpdate(delay) catch |err| {
            // std.log.err("Failed to update timer: {}", .{err});
            // return;
            // };
            // }
            // }
        }
    }

    pub fn setModifierFlag(keyboard: *Keyboard, keymod: wlr.Keyboard.ModifierMask, flag: bool) void {
        if (keymod.caps) {
            keyboard.modifierflags.caps = flag;
        } else if (keymod.alt) {
            keyboard.modifierflags.alt = flag;
        } else if (keymod.ctrl) {
            keyboard.modifierflags.ctrl = flag;
        } else if (keymod.logo) {
            keyboard.modifierflags.logo = flag;
        } else if (keymod.mod2) {
            keyboard.modifierflags.mod2 = flag;
        } else if (keymod.mod3) {
            keyboard.modifierflags.mod3 = flag;
        } else if (keymod.mod5) {
            keyboard.modifierflags.mod5 = flag;
        } else if (keymod.shift) {
            keyboard.modifierflags.shift = flag;
        }
    }

    pub fn addKeyToBufferIn(keyboard: *Keyboard, keyev: KeyEvent) bool {
        keyboard.bufferin.put(keyev.timems, keyev) catch |e| {
            std.log.err("Could not append keyevent to initial buffer: {}", .{e});
            return false;
        };
        return true;
    }

    // pub fn addKeyToBufferOut(keyboard: *Keyboard, keyev: KeyEvent) bool {
    // keyboard.bufferout.put(keyev.timems, keyev) catch |e| {
    // std.log.err("Could not append keyevent to final buffer: {}", .{e});
    // return false;
    // };
    // return true;
    // }

    pub fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *Keyboard = @fieldParentPtr("key", listener);
        const server = keyboard.server;
        // const wlr_keyboard = keyboard.device.toKeyboard();
        var handled = true;

        // Translate libinput keycode -> xkbcommon
        const keycode = event.keycode + 8;
        // std.debug.print("keycode: {}\n", .{keycode});
        var keyev = KeyEvent{
            .timems = event.time_msec,
            .keycode = keycode,
            .keysym = xkb.State.keyGetOneSym(keyboard.wlrkeyboard.xkb_state.?, keycode),
        };

        //if modifiersflag is on we have to affect the key
        //if key is f and shift is on the f must be F
        //but doing so would mean we cannot effectively have two homerow
        //keys combined, because for example:
        //if holding f gives shift and we want to press ctrl+shift
        //where ctrl is d, then holding f will turn it to shift and
        //d will automatically be read as D which is not good!
        //we need to process each key separately and then pass what is written
        //to applications or keybinding check.
        //so maybe it is good to have two buffers, one for processing and one for after processing.
        //keys after a threshold pass from processing to after processing!
        //for processing we name the hashkey as listprocesskey
        //for final after processing we name the hashkey as listfinalkey

        if (event.state == .pressed) {
            // _ = keyboard.addKeyToBufferIn(keyev);
            keyboard.listpresstime[keyev.keycode] = keyev.timems;
            _ = keyboard.addKeyToBufferIn(keyev);
        } else {
            keyev.state = .released;
            keyev.processed = true;
            //we dont care if releasedkeys are processed or not!
            // if (keyboard.process(keyboard.listpresstime[keyev.keycode], false)) {
            if (keyboard.bufferin.getPtr(keyboard.listpresstime[keyev.keycode])) |presskey| {
                presskey.processed = true;
                _ = keyboard.addKeyToBufferIn(keyev);
            } else {
                // if the press key is not in bufferin then release key must move to buffer out!
                // const node = keyboard.server.alloc.create(std.DoublyLinkedList(KeyEvent).Node) catch {
                // std.log.err("Failed to allocate node", .{});
                // };
                // node.data = keyev;
                var node = DLL.Node{ .data = keyev };
                keyboard.bufferout.append(&node);
                // const node = keyboard.server.alloc.create(DLL.Node) catch |e| {
                // std.log.err("Could not create DoublyLinkedList node: {}", .{e});
                // };
                // node.*.data = keyev;
                // var node_ptr = try keyboard.server.alloc.alloc(DLL.Node, 1);
                // node_ptr[0] = DLL.Node{ .data = keyev_ptr.value }; // Use .value to extract the KeyEvent from the hash map node.
                // keyboard.bufferout.append(node);
            }
            // }
            if (keyboard.server.config.mapmodifiers.get(keyev.keycode)) |keymod| {
                keyboard.setModifierFlag(keymod, false);
            }
            keyboard.listpresstime[keyev.keycode] = 0;
        }

        //in any situation we add keys to bufferin
        //we process them in timer cycles
        //we move them in each timer cycles to bufferout if they are processed==true
        //here we do the process as well if only released is pressed and processed==false
        //if they are processed in timer cycle, we do not need to process them at release again!

        // else {
        // _ = keyboard.addKeyToBufferOut(keyev);
        // }
        // const duration = keyev.timems - keyboard.listpresstime[keyev.keycode];
        // if (keyboard.listpresstime[keyev.keycode] > 0 and duration >= keyboard.keyholdthreshold) {
        // _ = keyboard.bufferin.remove(keyboard.listpresstime[keyev.keycode]);

        //and add it to final buffer
        //remove the original key from initial buffer
        //put a key in final buffer for modifier!
        // } else {
        //add the pressed key to the final buffer as well:
        //this could be a function that adds the pressed key to final buffer
        //and removes it from initial buffer.
        //also puts the release to final buffer!
        //
        //this has to be done in orderly fashion to respect order of all keys.
        //for example: hold f, press d, then we have to keep the initial buffer first
        //key as is until we figure out what happend to f(is it modifier) then pass f
        //as modifier (or not) and pass all the other keys with release time to final
        //buffer.
        //
        //final buffer must be a doubly linked list so that keys come and go in o(1)
        //orderly.
        //
        //initial buffer must be a hashmap with double linked list property for the keys
        //so that we have the beginning and ending and be able to change it anytime we want
        // _ = keyboard.addKeyToBufferOut(keyev);
        // }
        // keyboard.setupTimer(keyboard.bufferindelay, keyboard.keybuffertimer, Keyboard, handleBufferTimeOut, keyboard);

        // var buffer: [8]u8 = undefined;
        // const len = xkb.State.keyGetUtf8(wlrkeyboard.xkb_state.?, keycode, &buffer);
        // const char = if (len > 0) buffer[0..@intCast(len)] else ""; // Get the actual character

        //added code for the printing all the keys
        // const symo = wlrkeyboard.xkb_state.?.keyGetOneSym(keycode);
        // const sym_name = xkb.Keymap.keyGetName(wlrkeyboard.xkb_state.?.getKeymap(), keycode);
        // const state_str = if (event.state == .pressed) "press" else "release";

        // Log the key event
        // std.log.info("Key {s}: code={} sym={s} ({x})", .{
        // state_str,
        // keycode,
        // char,
        // @intFromEnum(symo),
        // });

        // if (wlrkeyboard.getModifiers().logo and event.state == .pressed) {
        // for (wlrkeyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
        // if (keyboard.handleKeybind(sym)) {
        // handled = true;
        // break;
        // }
        // }
        // }

        if (keyboard.wlrkeyboard.getModifiers().logo and event.state == .pressed) {
            if (keyboard.wlrkeyboard.xkb_state) |xkb_state| {
                for (xkb_state.keyGetSyms(keycode)) |sym| {
                    if (keyboard.handleKeybind(sym)) {
                        handled = true;
                        break;
                    }
                }
            } else {
                std.log.err("xkb_state is null, cannot process key symbols", .{});
            }
        }

        if (!handled) {
            //sending to application for handling the key event!
            server.seat.setKeyboard(keyboard.wlrkeyboard);
            server.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        }
    }

    pub fn handleDestroy(listener: *wl.Listener(void)) void {
        const keyboard: *Keyboard = @fieldParentPtr("destroy", listener);
        keyboard.link.remove();
        gpa.destroy(keyboard);
    }

    pub fn handleKeybind(keyboard: *Keyboard, key: xkb.Keysym) bool {
        switch (@intFromEnum(key)) {
            xkb.Keysym.Return => {
                const cmd = "kitty";
                var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, keyboard.server.alloc);
                var env_map = std.process.getEnvMap(keyboard.server.alloc) catch |err| {
                    std.log.err("Failed to spawn: {}", .{err});
                    return false;
                };
                defer env_map.deinit();
                env_map.put("WAYLAND_DISPLAY", keyboard.server.socket) catch |err| {
                    std.log.err("Failed to put the socket for the enviornment {}", .{err});
                };
                child.env_map = &env_map;

                // Set the environment variables
                _ = child.spawn() catch |err| {
                    std.log.err("Failed to spawn: {}", .{err});
                    return false;
                };
                return true;
            },

            //giving cycling effect to super+tab.
            xkb.Keysym.Tab => {
                const pre = keyboard.server.workspace_cur;
                keyboard.server.workspace_cur += 1;
                if (keyboard.server.workspace_cur >= keyboard.server.workspace_num) keyboard.server.workspace_cur -= keyboard.server.workspace_num;
                keyboard.server.switchWS(pre);
            },

            xkb.Keysym.Escape => {
                keyboard.server.deinit();
            },
            // Focus the next toplevel in the stack, pushing the current top to the back
            // xkb.Keysym.F1 => {
            // std.log.info("Key F1 pressed", .{});
            // if (server.workspaces.items[server.workspace_cur].toplevels.items.len < 2) return true;
            // const toplevel: *Toplevel = @fieldParentPtr("link", server.workspaces.items[server.workspace_cur].toplevels.link.prev.?);
            // server.focusView(toplevel, toplevel.xdg_toplevel.base.surface);
            // },
            else => return false,
        }
        return true;
    }
};

pub fn handleKeyCheckTimeOut(keyboard: *Keyboard) c_int {
    const bufferin = &keyboard.bufferin;
    // const bufferout = &keyboard.bufferout;

    // Start at the head of the ordered list
    var current_key = bufferin.head;
    while (current_key) |key| {
        // Capture next key BEFORE any potential removal
        const next_key = blk: {
            const node = bufferin.map.get(key) orelse break :blk null;
            break :blk node.next;
        };

        // Check if the key still exists (may have been removed earlier)
        const keyev_ptr = bufferin.map.getPtr(key) orelse {
            current_key = next_key;
            continue;
        };

        // Condition 1: Check if the key event is unprocessed
        if (!keyev_ptr.value.processed) {
            // Condition 2: Check if it's a modifier key with hold time exceeded
            if (keyboard.server.config.mapmodifiers.get(keyev_ptr.value.keycode)) |keymod| {
                const now: u64 = @intCast(std.time.milliTimestamp());
                const time_held = now - keyboard.listpresstime[keyev_ptr.value.keycode];

                if (time_held > keyboard.keyholdthreshold) {
                    // Mark as processed and update modifier
                    keyboard.setModifierFlag(keymod, true);
                    std.debug.print("we have a flag change to true", .{});
                    keyev_ptr.value.processed = true;
                } else {
                    // Stop processing entirely (condition failed)
                    break;
                }
            }
        }

        // If processed, move to bufferout and remove from bufferin
        if (keyev_ptr.value.processed) {
            var node = DLL.Node{ .data = keyev_ptr.value };
            keyboard.bufferout.append(&node);
            // var node_ptr = try keyboard.server.alloc.alloc(DLL.Node, 1);
            // node_ptr[0] = DLL.Node{ .data = keyev_ptr.value }; // Use .value to extract the KeyEvent from the hash map node.
            // keyboard.bufferout.append(&node_ptr[0]);
            _ = bufferin.remove(key);
        } else {
            // Stop processing (found an unprocessed key that doesn't meet conditions)
            break;
        }

        current_key = next_key;
    }

    keyboard.server.seat.setKeyboard(keyboard.wlrkeyboard);

    // Process all entries in bufferout in order (from head to tail)
    while (keyboard.bufferout.popFirst()) |node| {
        const event = node.data;
        // Send the key event to applications
        keyboard.server.seat.keyboardNotifyKey(event.timems, event.keycode, if (event.state == .pressed) .pressed else .released);
    }

    // Restart the timer
    keyboard.setupTimer(
        keyboard.keycheckdelay,
        keyboard.keychecktimer,
        Keyboard,
        handleKeyCheckTimeOut,
        keyboard,
    );

    return 0;
}

pub fn process(keyboard: *Keyboard, timems: u32) void {
    if (keyboard.bufferin.map.getPtr(timems)) |keyev| {
        if (!keyev.processed) {
            if (keyboard.server.config.mapmodifiers.get(keyev.keycode)) |keymod| {
                const now: u64 = @intCast(std.time.milliTimestamp());
                if ((now - keyboard.listpresstime[keyev.keycode]) > keyboard.keyholdthreshold) {
                    keyboard.setModifierFlag(keymod, true);
                    // std.debug.print("entry keyptr: {any}\n", .{entry.key_ptr.*});
                    keyev.processed = true;
                    // flag = true;
                }
            }
        }
    }
}

pub fn handleKeykCheckTimeOut(keyboard: *Keyboard) c_int {
    const count = keyboard.bufferin.map.count();
    if (count > 0) {
        // var delcount: usize = 0;
        // std.debug.print("key check time out\n", .{});
        var flag = true;
        var it = keyboard.bufferin.iterator();
        while (it.next()) |keybufin| {
            if (keyboard.bufferin.map.getPtr(keybufin)) |keyev| {
                if (!keyev.?.processed) {
                    //only pressed keys can have keyev.processed=false
                    if (keyboard.server.config.mapmodifiers.get(keyev.?.keycode)) |keymod| {
                        const now: u64 = @intCast(std.time.milliTimestamp());
                        if ((now - keyboard.listpresstime[keyev.?.keycode]) > keyboard.keyholdthreshold) {
                            keyboard.setModifierFlag(keymod, true);
                            // std.debug.print("entry keyptr: {any}\n", .{entry.key_ptr.*});
                            keyev.?.processed = true;
                        } else {
                            //now that there is a pressed key that needs to be
                            //processed again we cannot add the rest of the keys to
                            //bufferout
                            flag = false;
                        }
                    }
                }
                if (flag) {
                    const keyev2 = keyboard.bufferin.get(keyev.?.timems);
                    keyboard.bufferout.append(keyev2);
                    _ = keyboard.bufferin.remove(keybufin);
                }
            }
        }

        //move all the movkeys to bufferout
        // for (.items) |key| {
        // if (keyboard.bufferin.get(key)) |keyev| {
        // keyboard.bufferout.append(keyev);
        // _ = keyboard.bufferin.remove(key);
        // }
        // }
    }

    keyboard.setupTimer(keyboard.keycheckdelay, keyboard.keychecktimer, Keyboard, handleKeyCheckTimeOut, keyboard);

    return 0;
}

pub fn handleBufferTimeOut(keyboard: *Keyboard) c_int {
    defer keyboard.keybuffertimer = null;
    // findAction(keyboard) catch |err| {
    // std.log.err("Could not find the action for the key buffer {}", .{err});
    // return -1;
    // }e
    // std.debug.print("hellow from handle buffer time out\n", .{});
    keyboard.bufferin.clearRetainingCapacity();
    return 0;
}

// pub fn isModifier(keyboard:*Keyboard,keyev:*KeyEvent) bool{
// const flag:bool=false;
//
// if(keyboard.server.config.mapholdmap.get(keyev.keycode))|value|{
// if (keyev.state==.pressed){
// start a timer for keyholddelay time!
// }
// return true;
// }
//
// return flag;
// }

pub fn findAction(keyboard: *Keyboard) !void {
    // const wlrkeyboard = keyboard.device.toKeyboard();
    var str: std.ArrayList(u8) = std.ArrayList(u8).init(keyboard.server.alloc);
    var i: usize = keyboard.bufferin.items.len - 1;
    while (i >= 0) : (i -= 1) {
        const keyev = keyboard.bufferin.items[i];
        if (keyev.state == .pressed) {
            var buffer: [8]u8 = undefined;
            const len = xkb.State.keyGetUtf8(keyboard.wlrkeyboard.xkb_state.?, keyev.keycode, &buffer);
            const char = if (len > 0) buffer[0..@intCast(len)] else ""; // Get the actual character
            // std.debug.print("{s}\n", .{buffer});
            if (char.len > 0) try str.append(char[0]);
        } else {
            if (i == 0) break;
            var j: usize = i - 1;
            while (j >= 0) : (j -= 1) {
                const keyev2 = keyboard.bufferin.items[j];
                // what happens to multiple keyboards??
                if (keyev.keycode == keyev2.keycode and keyev2.state == .pressed) {
                    const duration = keyev.presstime - keyev2.presstime;
                    if (duration >= keyboard.keyholddelay) {
                        // here is homerow action.
                        if (keyboard.server.config.mapmodifiers.get(keyev.keycode)) |value| {
                            //we have to write a code that checks if this value is a modifier!
                            if (value.logo) {
                                std.debug.print("pressed super!{}\n", .{value});
                            } else if (value.ctrl) {} else if (value.caps) {} else if (value.alt) {} else if (value.shift) {} else if (value.mod2) {} else if (value.mod3) {} else if (value.mod5) {}
                        }
                    }
                    // if (j > 0) i = j - 1;
                    break;
                }
                if (j == 0) break;
            }
        }
        if (i == 0) break;
    }
}
