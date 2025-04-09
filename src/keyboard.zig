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

pub const ModifierFlags = struct {
    superL: i8 = 0,
    superR: i8 = 0,
    altL: i8 = 0,
    altR: i8 = 0,
    shiftL: i8 = 0,
    shiftR: i8 = 0,
    ctrlL: i8 = 0,
    ctrlR: i8 = 0,
    numlock: i8 = 0,
    caps: i8 = 0,
};

pub const KeyEvent = struct {
    keysym: xkb.Keysym,
    keycode: u32,
    timems: u32 = 0, // Use event.time_msec from wlroots
    state: enum { pressed, released } = .pressed,
    // processed: enum { raw, notmodifier, modifier } = .raw,
    processed: bool = false,
    // out: bool = false,
    ismodifier: bool = false,
    // raw: not processed at all, notmodifier: processed but not a modifier,
    // modifier: processed and it is a modifier
};

pub const Keyboard = struct {
    server: *Server,
    link: wl.list.Link = undefined,
    device: *wlr.InputDevice,

    bufferin: utility.OrderedAutoHashMap(u64, KeyEvent),
    bufferout: DLL,
    listpresstime: [256]u32 = .{0} ** 256,
    listismodifier: [256]bool = .{false} ** 256,

    keychecktimer: ?*wl.EventSource = null,
    keyholdthreshold: i32 = 200,
    keycheckdelay: i32 = 30,
    wlrtimedelay: u64 = 0,

    wlrkeyboard: *wlr.Keyboard,

    // modifierflags: wlr.Keyboard.ModifierMask = wlr.Keyboard.ModifierMask{},
    modifierflags: ModifierFlags = ModifierFlags{},

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

    pub fn isWLRModifierOn(keyboard: *Keyboard, mod: wlr.Keyboard.ModifierMask) bool {
        // const mod=keyboard.wlrkeyboard.getModifiers();
        _ = keyboard;
        if (mod.caps) return true;
        if (mod.alt) return true;
        if (mod.ctrl) return true;
        if (mod.logo) return true;
        if (mod.mod2) return true;
        if (mod.mod3) return true;
        if (mod.mod5) return true;
        if (mod.shift) return true;
        return false;
    }

    pub fn isSymKeyModifier(keyboard: *Keyboard, sym: xkb.Keysym) bool {
        const symshl: xkb.Keysym = @enumFromInt(xkb.Keysym.Shift_L);
        const symshr: xkb.Keysym = @enumFromInt(xkb.Keysym.Shift_R);
        const symsul: xkb.Keysym = @enumFromInt(xkb.Keysym.Super_L);
        const symsur: xkb.Keysym = @enumFromInt(xkb.Keysym.Super_R);
        const symctl: xkb.Keysym = @enumFromInt(xkb.Keysym.Control_L);
        const symctr: xkb.Keysym = @enumFromInt(xkb.Keysym.Control_R);
        const symall: xkb.Keysym = @enumFromInt(xkb.Keysym.Alt_L);
        const symalr: xkb.Keysym = @enumFromInt(xkb.Keysym.Alt_R);
        const symcaps: xkb.Keysym = @enumFromInt(xkb.Keysym.Caps_Lock);
        const symnuml: xkb.Keysym = @enumFromInt(xkb.Keysym.Num_Lock);
        _ = keyboard;
        switch (sym) {
            symshl => {
                return true;
            },
            symshr => {
                return true;
            },
            symsul => {
                return true;
            },
            symsur => {
                return true;
            },
            symctl => {
                return true;
            },
            symctr => {
                return true;
            },
            symnuml => {
                return true;
            },
            symcaps => {
                return true;
            },
            symall => {
                return true;
            },
            symalr => {
                return true;
            },
            else => {
                return false;
            },
        }
    }

    pub fn setModifierFlags(keyboard: *Keyboard, sym: xkb.Keysym, flag: bool) void {
        const symshl: xkb.Keysym = @enumFromInt(xkb.Keysym.Shift_L);
        const symshr: xkb.Keysym = @enumFromInt(xkb.Keysym.Shift_R);
        const symsul: xkb.Keysym = @enumFromInt(xkb.Keysym.Super_L);
        const symsur: xkb.Keysym = @enumFromInt(xkb.Keysym.Super_R);
        const symctl: xkb.Keysym = @enumFromInt(xkb.Keysym.Control_L);
        const symctr: xkb.Keysym = @enumFromInt(xkb.Keysym.Control_R);
        const symall: xkb.Keysym = @enumFromInt(xkb.Keysym.Alt_L);
        const symalr: xkb.Keysym = @enumFromInt(xkb.Keysym.Alt_R);
        const symcaps: xkb.Keysym = @enumFromInt(xkb.Keysym.Caps_Lock);
        const symnuml: xkb.Keysym = @enumFromInt(xkb.Keysym.Num_Lock);
        const delt: i8 = if (flag) 1 else -1;
        switch (sym) {
            symshl => {
                keyboard.modifierflags.shiftL +|= delt;
            },
            symshr => {
                keyboard.modifierflags.shiftR +|= delt;
            },
            symsul => {
                keyboard.modifierflags.superL +|= delt;
            },
            symsur => {
                keyboard.modifierflags.superR +|= delt;
            },
            symctl => {
                keyboard.modifierflags.ctrlL +|= delt;
            },
            symctr => {
                keyboard.modifierflags.ctrlR +|= delt;
            },
            symnuml => {
                keyboard.modifierflags.numlock +|= delt;
            },
            symcaps => {
                keyboard.modifierflags.caps +|= delt;
            },
            symall => {
                keyboard.modifierflags.altL +|= delt;
            },
            symalr => {
                keyboard.modifierflags.altR +|= delt;
            },
            else => {},
        }
    }

    pub fn addKeyToBufferIn(keyboard: *Keyboard, keyev: KeyEvent) bool {
        keyboard.bufferin.put(keyev.timems, keyev) catch |e| {
            std.log.err("Could not append keyevent to initial buffer: {}", .{e});
            return false;
        };
        return true;
    }

    pub fn addKeyToBufferOut(keyboard: *Keyboard, keyev: KeyEvent) bool {
        const node_ptr_opt = keyboard.server.alloc.create(DLL.Node) catch null;
        if (node_ptr_opt) |node_ptr| {
            node_ptr.* = DLL.Node{ .data = keyev };
            keyboard.bufferout.append(node_ptr);
        } else {
            std.log.err("Could not create DoublyLinkedList node.", .{});
            return false;
        }
        return true;
    }

    pub fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *Keyboard = @fieldParentPtr("key", listener);
        const now: u64 = @intCast(std.time.milliTimestamp());
        // if (keyboard.wlrtimedelay==0)
        keyboard.wlrtimedelay = now - event.time_msec;
        const keycode = event.keycode + 8;
        var keyev = KeyEvent{
            .timems = event.time_msec,
            .keycode = keycode,
            .keysym = xkb.State.keyGetOneSym(keyboard.wlrkeyboard.xkb_state.?, keycode),
        };

        if (event.state == .pressed) {
            keyboard.listpresstime[keyev.keycode] = keyev.timems;
        } else {
            keyev.state = .released;
            keyev.processed = true;
            //we dont care if releasedkeys are raw or not because they follow their pressed version!
            if (keyboard.bufferin.getPtr(keyboard.listpresstime[keyev.keycode])) |presskey| {
                if (!presskey.processed) {
                    presskey.processed = true;
                    if (keyboard.server.config.mapkeys.get(keyev.keysym)) |sym| {
                        if (keyboard.isSymKeyModifier(sym)) {
                            const time_held = now - keyboard.wlrtimedelay - presskey.timems;
                            if (time_held > keyboard.keyholdthreshold) {
                                presskey.ismodifier = true;
                                keyev.ismodifier = true;
                            }
                        }
                    }
                } else {
                    if (presskey.ismodifier) keyev.ismodifier = true;
                }
            } else {
                if (keyboard.listismodifier[keyev.keycode]) {
                    keyev.ismodifier = true;
                    keyboard.listismodifier[keyev.keycode] = false;
                }
            }
        }
        _ = keyboard.addKeyToBufferIn(keyev);

        // std.debug.print("handlekey goingout: {}\n", .{std.time.milliTimestamp()});
        // so here we have to first see if there is no modifier or
        // any keymapping available for the keyevent then we should never send it to
        // any function and no need to send them to any buffer. they can immediately go to
        // applicaitons in insert mode and ignored in normal mode, cause they do not do anything!
    }

    pub fn updateModifiers(keyboard: *Keyboard, sym: xkb.Keysym) void {
        keyboard.wlrkeyboard.modifiers.depressed |= ~@intFromEnum(sym);
        const modifiers = &keyboard.wlrkeyboard.modifiers;
        keyboard.server.seat.keyboardNotifyModifiers(modifiers);
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
            else => return false,
        }
        return true;
    }
};

pub fn handleKeyCheckTimeOut(keyboard: *Keyboard) c_int {
    const bufferin = &keyboard.bufferin;
    var current_key = bufferin.head;
    while (current_key) |key| {
        const next_key = blk: {
            const node = bufferin.map.get(key) orelse break :blk null;
            break :blk node.next;
        };
        const keyev_ptr = bufferin.map.getPtr(key) orelse {
            current_key = next_key;
            continue;
        };

        if (keyboard.server.config.mapkeys.get(keyev_ptr.value.keysym)) |sym| {
            if (!keyev_ptr.value.processed) {
                if (keyboard.isSymKeyModifier(sym)) {
                    const now: u64 = @intCast(std.time.milliTimestamp());
                    const time_held = now - keyboard.wlrtimedelay - keyev_ptr.value.timems;
                    if (time_held > keyboard.keyholdthreshold) {
                        keyev_ptr.value.ismodifier = true;
                        keyboard.listismodifier[keyev_ptr.value.keycode] = true;
                        keyev_ptr.value.processed = true; // does not send this to app. just remove it
                    } else {
                        break;
                    }
                } else keyev_ptr.value.processed = true;
            }
        } else {
            keyev_ptr.value.processed = true;
            if (keyboard.isSymKeyModifier(keyev_ptr.value.keysym)) {
                keyev_ptr.value.ismodifier = true;
            }
        }

        if (keyev_ptr.value.processed) {
            _ = keyboard.addKeyToBufferOut(keyev_ptr.value);
            _ = bufferin.remove(key);
        } else {
            std.log.err("Error, found a key which is not been processed but is supposed to be processed.", .{});
            // Stop processing (found an unprocessed key that doesn't meet conditions)
            // break;
        }

        current_key = next_key;
    }

    keyboard.server.seat.setKeyboard(keyboard.wlrkeyboard);

    var idx: usize = keyboard.bufferout.len;
    while (idx > 0) : (idx -= 1) {
        if (keyboard.bufferout.popFirst()) |node| {
            const event = node.data;
            var handled = false;
            if (!event.ismodifier) {
                if (keyboard.modifierflags.superL > 0 and event.state == .pressed) {
                    if (keyboard.handleKeybind(event.keysym)) {
                        handled = true;
                        std.debug.print("here is the handled key: {}\n", .{event.keycode});
                    }
                }
                if (!handled) {
                    std.debug.print("here is the not handled key: {}\n", .{event.keycode});
                    //for now this -8 is good. probably should change it when it is loaded
                    //on its own rather than being called in x11.
                    keyboard.server.seat.keyboardNotifyKey(event.timems, event.keycode - 8, if (event.state == .pressed) .pressed else .released);
                }
            } else {
                if (keyboard.server.config.mapkeys.get(event.keysym)) |sym| {
                    keyboard.setModifierFlags(sym, event.state == .pressed);
                    keyboard.updateModifiers(sym);
                } else {
                    keyboard.setModifierFlags(event.keysym, event.state == .pressed);
                    keyboard.updateModifiers(event.keysym);
                }
            }
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
// var buffer: [8]u8 = undefined;
