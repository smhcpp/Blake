const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const gpa = std.heap.c_allocator;
const Toplevel = @import("toplevel.zig").Toplevel;
const Server = @import("server.zig").Server;

pub const Keyboard = struct {
    server: *Server,
    link: wl.list.Link = undefined,
    device: *wlr.InputDevice,
    // keypressedtime: [256]u64 = .{0} ** 256,
    //zero means not pressed at all!
    //for storing last press time in this keyboard!

    // keyreleased:std.ArrayList(KeyEvent),
    keybuffer: std.AutoHashMap(u64, KeyEvent),
    // releasedlist: std.ArrayList(KeyEvent),
    listpressedtime: [256]u64 = .{0} ** 256,

    keychecktimer: ?*wl.EventSource = null,
    // keybuffertimer: ?*wl.EventSource = null,
    keyholdthreshold: i32 = 200,
    keycheckdelay: i32 = 50,
    // keybufferdelay: i32 = 400,

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
            .keybuffer = std.AutoHashMap(u64, KeyEvent).init(server.alloc),
            // .releasedlist = std.ArrayList(KeyEvent).init(server.alloc),
        };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        const wlr_keyboard = device.toKeyboard();
        if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_keyboard.setRepeatInfo(25, 600);

        wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
        wlr_keyboard.events.key.add(&keyboard.key);

        // keyboard.lastkeyreleased = KeyEvent{
        // .presstime = 0,
        // .keycode = 0,
        // .keysym = xkb.State.keyGetOneSym(wlr_keyboard.xkb_state.?, 0),
        // .state = .pressed,
        // };

        keyboard.setupTimer(keyboard.keycheckdelay, keyboard.keychecktimer, Keyboard, handleKeyCheckTimeOut, keyboard);
        server.seat.setKeyboard(wlr_keyboard);
        server.keyboards.append(keyboard);
    }

    pub fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
        const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);
        keyboard.server.seat.setKeyboard(wlr_keyboard);
        keyboard.server.seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
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

    pub fn addKeyToBuffer(keyboard: *Keyboard, keyev: KeyEvent) bool {
        keyboard.keybuffer.put(keyev.timems, keyev) catch |e| {
            std.log.err("Could not append keyevent to keybuffer: {}", .{e});
            return false;
        };
        return true;
    }

    pub fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *Keyboard = @fieldParentPtr("key", listener);
        const server = keyboard.server;
        const wlr_keyboard = keyboard.device.toKeyboard();
        var handled = true;

        // Translate libinput keycode -> xkbcommon
        const keycode = event.keycode + 8;
        // std.debug.print("keycode: {}\n", .{keycode});
        const keyev = KeyEvent{
            .state = if (event.state == .pressed) .pressed else .released,
            .timems = event.time_msec,
            .keycode = keycode,
            .keysym = xkb.State.keyGetOneSym(wlr_keyboard.xkb_state.?, keycode),
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
            _ = keyboard.addKeyToBuffer(keyev);
            keyboard.listpressedtime[keyev.keycode] = keyev.timems;
        } else {
            if (keyboard.server.config.keyholdmap.get(keyev.keycode)) |keymod| {
                const duration = keyev.timems - keyboard.listpressedtime[keyev.keycode];
                if (keyboard.listpressedtime[keyev.keycode] > 0 and duration >= keyboard.keyholdthreshold) {
                    keyboard.setModifierFlag(keymod, false);
                    _ = keyboard.keybuffer.remove(keyboard.listpressedtime[keyev.keycode]);
                } else {
                    _ = keyboard.addKeyToBuffer(keyev);
                }
            } else {
                _ = keyboard.addKeyToBuffer(keyev);
            }
        }
        // keyboard.setupTimer(keyboard.keybufferdelay, keyboard.keybuffertimer, Keyboard, handleBufferTimeOut, keyboard);

        // var buffer: [8]u8 = undefined;
        // const len = xkb.State.keyGetUtf8(wlr_keyboard.xkb_state.?, keycode, &buffer);
        // const char = if (len > 0) buffer[0..@intCast(len)] else ""; // Get the actual character

        //added code for the printing all the keys
        // const symo = wlr_keyboard.xkb_state.?.keyGetOneSym(keycode);
        // const sym_name = xkb.Keymap.keyGetName(wlr_keyboard.xkb_state.?.getKeymap(), keycode);
        // const state_str = if (event.state == .pressed) "press" else "release";

        // Log the key event
        // std.log.info("Key {s}: code={} sym={s} ({x})", .{
        // state_str,
        // keycode,
        // char,
        // @intFromEnum(symo),
        // });

        // if (wlr_keyboard.getModifiers().logo and event.state == .pressed) {
        // for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
        // if (keyboard.handleKeybind(sym)) {
        // handled = true;
        // break;
        // }
        // }
        // }

        if (wlr_keyboard.getModifiers().logo and event.state == .pressed) {
            if (wlr_keyboard.xkb_state) |xkb_state| {
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
            server.seat.setKeyboard(wlr_keyboard);
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

pub const KeyEvent = struct {
    keysym: xkb.Keysym,
    keycode: u32,
    timems: u64, // Use event.time_msec from wlroots
    state: enum { pressed, released },
};

pub fn handleKeyCheckTimeOut(keyboard: *Keyboard) c_int {
    // const server=keyboard.server;
    // defer keyboard.keyholdtimer=null;
    const count = keyboard.keybuffer.count();
    var keys: std.ArrayList(u64) = std.ArrayList(u64).init(keyboard.server.alloc);
    defer keys.deinit();
    if (count > 0) {
        // std.debug.print("key check time out\n", .{});
        // var i: usize = count - 1;
        var it = keyboard.keybuffer.iterator();
        while (it.next()) |entry| {
            const keyev = entry.value_ptr.*;
            if (keyev.state == .pressed) {
                if (keyboard.server.config.keyholdmap.get(keyev.keycode)) |keymod| {
                    const now: u64 = @intCast(std.time.milliTimestamp());
                    if ((now - keyboard.listpressedtime[keyev.keycode]) > keyboard.keyholdthreshold) {
                        keyboard.setModifierFlag(keymod, true);
                        // std.debug.print("entry keyptr: {any}\n", .{entry.key_ptr.*});
                        keys.append(entry.key_ptr.*) catch |e| {
                            std.log.err("Could not append the key to remove it from keybuffer: {}", .{e});
                        };
                    }
                }
            } else {
                // released is taken care of in the handlekey function and we dont
                // have to check it. so we really put the code empty here!
            }

            // if ( == keyreleased.keycode and keyboard.keybuffer.items[i].state == .pressed) {
            // if (keyboard.server.config.keyholdmap.get(keyreleased.keycode)) |value| {
            // std.debug.print("keyhold activated: {}\n", .{value});
            // }
            // }
            // if (i > 0) {
            // i -= 1;
            // } else break;
        }
        for (keys.items) |key| {
            _ = keyboard.keybuffer.remove(key);
        }
    }
    // keyboard.lastkeyreleased.presstime = 0;
    keyboard.setupTimer(keyboard.keycheckdelay, keyboard.keychecktimer, Keyboard, handleKeyCheckTimeOut, keyboard);

    // if (keyboard.keychecktimer) |keytimer| {
    // }

    return 0;
}

pub fn handleBufferTimeOut(keyboard: *Keyboard) c_int {
    defer keyboard.keybuffertimer = null;
    // findAction(keyboard) catch |err| {
    // std.log.err("Could not find the action for the key buffer {}", .{err});
    // return -1;
    // }e
    // std.debug.print("hellow from handle buffer time out\n", .{});
    keyboard.keybuffer.clearRetainingCapacity();
    return 0;
}

// pub fn isModifier(keyboard:*Keyboard,keyev:*KeyEvent) bool{
// const flag:bool=false;
//
// if(keyboard.server.config.keyholdmap.get(keyev.keycode))|value|{
// if (keyev.state==.pressed){
// start a timer for keyholddelay time!
// }
// return true;
// }
//
// return flag;
// }

pub fn findAction(keyboard: *Keyboard) !void {
    const wlr_keyboard = keyboard.device.toKeyboard();
    var str: std.ArrayList(u8) = std.ArrayList(u8).init(keyboard.server.alloc);
    var i: usize = keyboard.keybuffer.items.len - 1;
    while (i >= 0) : (i -= 1) {
        const keyev = keyboard.keybuffer.items[i];
        if (keyev.state == .pressed) {
            var buffer: [8]u8 = undefined;
            const len = xkb.State.keyGetUtf8(wlr_keyboard.xkb_state.?, keyev.keycode, &buffer);
            const char = if (len > 0) buffer[0..@intCast(len)] else ""; // Get the actual character
            // std.debug.print("{s}\n", .{buffer});
            if (char.len > 0) try str.append(char[0]);
        } else {
            if (i == 0) break;
            var j: usize = i - 1;
            while (j >= 0) : (j -= 1) {
                const keyev2 = keyboard.keybuffer.items[j];
                // what happens to multiple keyboards??
                if (keyev.keycode == keyev2.keycode and keyev2.state == .pressed) {
                    const duration = keyev.presstime - keyev2.presstime;
                    if (duration >= keyboard.keyholddelay) {
                        // here is homerow action.
                        if (keyboard.server.config.keyholdmap.get(keyev.keycode)) |value| {
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
