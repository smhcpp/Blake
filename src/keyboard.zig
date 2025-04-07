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

    bufferin: utility.OrderedAutoHashMap(u64, KeyEvent),
    bufferout: DLL,
    listpresstime: [256]u64 = .{0} ** 256,

    keychecktimer: ?*wl.EventSource = null,
    keyholdthreshold: i32 = 200,
    keycheckdelay: i32 = 50,

    wlrkeyboard: *wlr.Keyboard,

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
        };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        if (!keyboard.wlrkeyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        keyboard.wlrkeyboard.setRepeatInfo(25, 600);

        keyboard.wlrkeyboard.events.modifiers.add(&keyboard.modifiers);
        keyboard.wlrkeyboard.events.key.add(&keyboard.key);

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

    pub fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *Keyboard = @fieldParentPtr("key", listener);

        // Translate libinput keycode -> xkbcommon
        const keycode = event.keycode + 8;
        // const keycode = event.keycode;
        // std.debug.print("keycode: {}\n", .{keycode});
        var keyev = KeyEvent{
            .timems = event.time_msec,
            .keycode = keycode,
            .keysym = xkb.State.keyGetOneSym(keyboard.wlrkeyboard.xkb_state.?, keycode),
        };

        if (event.state == .pressed) {
            keyboard.listpresstime[keyev.keycode] = keyev.timems;
            _ = keyboard.addKeyToBufferIn(keyev);
        } else {
            keyev.state = .released;
            keyev.processed = true;
            //we dont care if releasedkeys are processed or not!
            if (keyboard.bufferin.getPtr(keyboard.listpresstime[keyev.keycode])) |presskey| {
                presskey.processed = true;
                _ = keyboard.addKeyToBufferIn(keyev);
            } else {
                const node_ptr_opt = keyboard.server.alloc.create(DLL.Node) catch null;
                if (node_ptr_opt) |node_ptr| {
                    node_ptr.* = DLL.Node{ .data = keyev };
                    keyboard.bufferout.append(node_ptr);
                } else {
                    std.log.err("Could not create DoublyLinkedList node.", .{});
                }
            }
            if (keyboard.server.config.mapmodifiers.get(keyev.keycode)) |keymod| {
                keyboard.setModifierFlag(keymod, false);
            }
            keyboard.listpresstime[keyev.keycode] = 0;
        }

        // so here we have to first see if there is no modifier or
        // any keymapping available for the keyevent then we should never send it to
        // any function and no need to send them to any buffer. they can immediately go to
        // applicaitons in insert mode and ignored in normal mode, cause they do not do anything!
        //

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

        // if (!handled) {
        // sending to application for handling the key event!
        // server.seat.setKeyboard(keyboard.wlrkeyboard);
        // server.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        // }
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
            // std.debug.print("here is keycheck: {}\n",.{keyev_ptr.value.keycode});
            // Condition 2: Check if it's a modifier key with hold time exceeded
            if (keyboard.server.config.mapmodifiers.get(keyev_ptr.value.keycode)) |keymod| {
                const now: u64 = @intCast(std.time.milliTimestamp());
                const time_held = now - keyboard.listpresstime[keyev_ptr.value.keycode];

                if (time_held > keyboard.keyholdthreshold) {
                    // Mark as processed and update modifier
                    keyboard.setModifierFlag(keymod, true);
                    std.debug.print("we have a flag change to true\n", .{});
                    keyev_ptr.value.processed = true;
                } else {
                    // Stop processing entirely (condition failed)
                    break;
                }
            }
        }

        if (keyev_ptr.value.processed) {
            const node_ptr_opt = keyboard.server.alloc.create(DLL.Node) catch null;
            if (node_ptr_opt) |node_ptr| {
                node_ptr.* = DLL.Node{ .data = keyev_ptr.value };
                keyboard.bufferout.append(node_ptr);
            } else {
                std.log.err("Could not create DoublyLinkedList node.", .{});
            }
            _ = bufferin.remove(key);
        } else {
            // Stop processing (found an unprocessed key that doesn't meet conditions)
            break;
        }

        current_key = next_key;
    }

    keyboard.server.seat.setKeyboard(keyboard.wlrkeyboard);

    // std.debug.print("bufferout length: {}\n",.{keyboard.bufferout.len});
    var idx: usize = keyboard.bufferout.len;
    while (idx > 0) : (idx -= 1) {
        if (keyboard.bufferout.popFirst()) |node| {
            const event = node.data;
            var handled = false;
            if ((keyboard.wlrkeyboard.getModifiers().logo or keyboard.modifierflags.logo) and event.state == .pressed) {
                std.debug.print("here logo is pressed!\n", .{});
                if (keyboard.handleKeybind(event.keysym)) {
                    handled = true;
                    break;
                }
            }
            std.debug.print("keyboard notification will happen: {}\n", .{event.keycode});
            // Send the key event to applications
            if (!handled) {
                keyboard.server.seat.keyboardNotifyKey(event.timems, event.keycode, if (event.state == .pressed) .pressed else .released);
            }
            // keyboard.server.alloc.destroy(node);
            std.debug.print("poping happened: {}\n", .{event.keycode});
        }
    }

    keyboard.setupTimer(
        keyboard.keycheckdelay,
        keyboard.keychecktimer,
        Keyboard,
        handleKeyCheckTimeOut,
        keyboard,
    );

    return 0;
}

pub fn processKeymap(keyboard: *Keyboard) void {
    //here wek
    _ = keyboard;
}

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
