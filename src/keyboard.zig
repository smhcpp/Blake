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

    modifiers: wl.Listener(*wlr.Keyboard) = .init(handleModifiers),
    key: wl.Listener(*wlr.Keyboard.event.Key) = .init(handleKey),
    destroy: wl.Listener(void) = .init(handleDestroy),

    pub fn create(server: *Server, device: *wlr.InputDevice) !void {
        const keyboard = try server.alloc.create(Keyboard);
        errdefer server.alloc.destroy(keyboard);

        keyboard.* = .{
            .server = server,
            .device = device,
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

        server.seat.setKeyboard(wlr_keyboard);
        server.keyboards.append(keyboard);
    }

    pub fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
        const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);
        keyboard.server.seat.setKeyboard(wlr_keyboard);
        keyboard.server.seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
    }

    pub fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *Keyboard = @fieldParentPtr("key", listener);
        const wlr_keyboard = keyboard.device.toKeyboard();

        // Translate libinput keycode -> xkbcommon
        const keycode = event.keycode + 8;

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
        // Here is the rest of the code from tinwl.

        var handled = false;
        if (wlr_keyboard.getModifiers().logo and event.state == .pressed) {
            for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
                if (handleKeybind(keyboard.server, sym)) {
                    handled = true;
                    break;
                }
            }
        }

        if (!handled) {
            keyboard.server.seat.setKeyboard(wlr_keyboard);
            keyboard.server.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        }
    }

    pub fn handleDestroy(listener: *wl.Listener(void)) void {
        const keyboard: *Keyboard = @fieldParentPtr("destroy", listener);

        keyboard.link.remove();

        gpa.destroy(keyboard);
    }
};

/// Assumes the modifier used for compositor keybinds is pressed
/// Returns true if the key was handled
pub fn handleKeybind(server: *Server, key: xkb.Keysym) bool {
    // std.log.info("handle Keybind pressed", .{});
    switch (@intFromEnum(key)) {
        // Exit the compositor

        xkb.Keysym.Return => {
            const cmd = "kitty";
            var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, server.alloc);
            var env_map = std.process.getEnvMap(server.alloc) catch |err| {
                std.log.err("Failed to spawn: {}", .{err});
                return false;
            };
            defer env_map.deinit();
            env_map.put("WAYLAND_DISPLAY", server.socket) catch |err| {
                std.log.err("Failed to put the socket for the enviornment {}", .{err});
            };
            child.env_map = &env_map;
            // try child.spawn();
            // std.log.info("Key Enter pressed", .{});
            // child.env_map = env_map_ptr;

            // Set the environment variables
            _ = child.spawn() catch |err| {
                std.log.err("Failed to spawn: {}", .{err});
                return false;
            };
            return true;
        },

        //giving cycling effect to super+tab.
        xkb.Keysym.Tab => {
            const pre = server.workspace_cur;
            server.workspace_cur += 1;
            // server.workspace_num += 1;
            if (server.workspace_cur >= server.workspace_num) server.workspace_cur -= server.workspace_num;
            server.switchWS(pre);
        },

        xkb.Keysym.Escape => server.wl_server.terminate(),
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
