const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const gpa = std.heap.c_allocator;

const datatypes = @import("datatypes.zig");
const Toplevel = @import("toplevel.zig").Toplevel;
const Workspace = @import("toplevel.zig").Workspace;
const keyboard = @import("keyboard.zig");
const Output = @import("output.zig").Output;
const Popup = @import("popup.zig").Popup;
const config = @import("config.zig");
const Tiling = @import("tiling.zig");
pub const Server = struct {
    wlserver: *wl.Server,
    backend: *wlr.Backend,
    socket: []const u8 = undefined,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    alloc: std.mem.Allocator = std.heap.c_allocator,
    scene: *wlr.Scene,

    output_layout: *wlr.OutputLayout,
    scene_output_layout: *wlr.SceneOutputLayout,
    new_output: wl.Listener(*wlr.Output) = .init(newOutput),

    xdg_shell: *wlr.XdgShell,
    new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevel),
    new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(newXdgPopup),

    config: *config.Config,
    workspaces: std.ArrayList(Workspace) = undefined,
    workspace_num: usize = undefined,
    workspace_cur: usize = undefined,
    mode: datatypes.Mode,

    seat: *wlr.Seat,
    new_input: wl.Listener(*wlr.InputDevice) = .init(newInput),
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursor),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelection),
    keyboards: wl.list.Head(keyboard.Keyboard, .link) = undefined,

    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(cursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(cursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(cursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(cursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) = .init(cursorFrame),

    cursor_mode: enum { passthrough, move, resize } = .passthrough,
    grabbed_view: ?*Toplevel = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: wlr.Box = undefined,
    resize_edges: wlr.Edges = .{},
    loop: *wl.EventLoop,

    pub fn init(server: *Server) !void {
        const wlserver = try wl.Server.create();
        const loop = wlserver.getEventLoop();
        const backend = try wlr.Backend.autocreate(loop, null);
        const renderer = try wlr.Renderer.autocreate(backend);
        const output_layout = try wlr.OutputLayout.create(wlserver);
        const scene = try wlr.Scene.create();
        server.* = .{
            .loop = loop,
            .mode = datatypes.Mode.n,
            .config = undefined,
            .wlserver = wlserver,
            .backend = backend,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(backend, renderer),
            .scene = scene,
            .output_layout = output_layout,
            .scene_output_layout = try scene.attachOutputLayout(output_layout),
            .xdg_shell = try wlr.XdgShell.create(wlserver, 2),
            .seat = try wlr.Seat.create(wlserver, "default"),
            .cursor = try wlr.Cursor.create(),
            .cursor_mgr = try wlr.XcursorManager.create(null, 24),
        };
        server.config = try config.Config.init(server);
        server.setUpConfig();
        // server.keybuffer = std.ArrayList(keyboard.KeyEvent).init(server.alloc);
        server.workspaces = std.ArrayList(Workspace).init(server.alloc);
        var wi: usize = 0;
        while (wi < server.workspace_num) {
            var w = Workspace{
                .id = wi,
                .name = std.fmt.allocPrint(server.alloc, "{}", .{wi + 1}) catch "w",
                .toplevels = undefined,
                .layout_cur = 0,
                .toplvl_cur = 0,
            };
            w.toplevels = std.ArrayList(*Toplevel).init(server.alloc);
            try server.workspaces.append(w);
            wi += 1;
        }

        try server.renderer.initServer(wlserver);

        _ = try wlr.Compositor.create(server.wlserver, 6, server.renderer);
        _ = try wlr.Subcompositor.create(server.wlserver);
        _ = try wlr.DataDeviceManager.create(server.wlserver);

        server.backend.events.new_output.add(&server.new_output);
        server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
        server.xdg_shell.events.new_popup.add(&server.new_xdg_popup);
        server.backend.events.new_input.add(&server.new_input);
        server.seat.events.request_set_cursor.add(&server.request_set_cursor);
        server.seat.events.request_set_selection.add(&server.request_set_selection);
        server.keyboards.init();

        server.cursor.attachOutputLayout(server.output_layout);
        try server.cursor_mgr.load(1);
        server.cursor.events.motion.add(&server.cursor_motion);
        server.cursor.events.motion_absolute.add(&server.cursor_motion_absolute);
        server.cursor.events.button.add(&server.cursor_button);
        server.cursor.events.axis.add(&server.cursor_axis);
        server.cursor.events.frame.add(&server.cursor_frame);
    }

    pub fn deinit(server: *Server) void {
        // server.sigint_source.remove();
        // server.sigterm_source.remove();
        for (server.workspaces.items) |*ws| {
            for (ws.toplevels.items) |toplevel| {
                toplevel.scene_tree.node.destroy();
                gpa.destroy(toplevel);
            }
            ws.toplevels.deinit();
            server.alloc.free(ws.name);
        }
        server.workspaces.deinit();

        server.cursor_mgr.destroy();
        server.cursor.destroy();
        server.wlserver.terminate();
        // server.xdg_shell.destroy();
        // server.scene_output_layout.destroy();
        server.output_layout.destroy();
        // server.scene.deinit();
        // server.wlserver.destroyClients();
        server.seat.destroy();
        server.backend.destroy();
        server.allocator.destroy();
        server.renderer.destroy();

        server.wlserver.destroy();
    }

    pub fn setUpConfig(server: *Server) void {
        const symg: xkb.Keysym = @enumFromInt(xkb.Keysym.g);
        const symf: xkb.Keysym = @enumFromInt(xkb.Keysym.f);
        const symshl: xkb.Keysym = @enumFromInt(xkb.Keysym.Shift_L);
        const symsupl: xkb.Keysym = @enumFromInt(xkb.Keysym.Super_L);
        const mapsul: datatypes.Keymap = datatypes.Keymap{
            .hold = symsupl,
        };
        const mapshl: datatypes.Keymap = datatypes.Keymap{
            .hold = symshl,
        };
        server.config.keymaps.put(symg, mapshl) catch {};
        server.config.keymaps.put(symf, mapsul) catch {};

        // if (server.config.configs.get("workspace_num")) |buf| {
            // server.workspace_num = std.fmt.parseInt(u8, buf, 10) catch 1;
        // } else server.workspace_num = 1;
        // std.debug.print("workspace_num: {}\n",.{server.workspace_num});

        // if (server.config.configs.get("workspace_cur")) |buf| {
            // server.workspace_cur = std.fmt.parseInt(u8, buf, 10) catch 0;
        // } else server.workspace_cur = 0;
        // std.debug.print("workspace_cur: {}\n",.{server.workspace_cur});
        // if (server.config.binds.search(&[_]u64{ 0x1, 0x2, 0x3 })) |node| {
        // std.debug.print("Found node with {any} apps\n", .{node.appnames.items});
        // }
        // var it = server.config.configs.iterator();
        // while (it.next()) |entry| {
        // std.debug.print("config: {s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        // }
        std.process.exit(0);
    }

    pub fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *Server = @fieldParentPtr("new_output", listener);

        if (!wlr_output.initRender(server.allocator, server.renderer)) return;

        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(true);
        if (wlr_output.preferredMode()) |mode| {
            state.setMode(mode);
        }
        if (!wlr_output.commitState(&state)) return;

        Output.create(server, wlr_output) catch {
            std.log.err("failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };
    }

    pub fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
        const server: *Server = @fieldParentPtr("new_xdg_toplevel", listener);
        const xdg_surface = xdg_toplevel.base;

        // Don't add the toplevel to server.toplevels until it is mapped
        const toplevel = gpa.create(Toplevel) catch {
            std.log.err("failed to allocate new toplevel", .{});
            return;
        };

        toplevel.* = .{
            .server = server,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = server.scene.tree.createSceneXdgSurface(xdg_surface) catch {
                gpa.destroy(toplevel);
                std.log.err("failed to allocate new toplevel", .{});
                return;
            },
        };
        toplevel.scene_tree.node.data = @intFromPtr(toplevel);
        xdg_surface.data = @intFromPtr(toplevel.scene_tree);

        xdg_surface.surface.events.commit.add(&toplevel.commit);
        xdg_surface.surface.events.map.add(&toplevel.map);
        xdg_surface.surface.events.unmap.add(&toplevel.unmap);
        xdg_toplevel.events.destroy.add(&toplevel.destroy);
        xdg_toplevel.events.request_move.add(&toplevel.request_move);
        xdg_toplevel.events.request_resize.add(&toplevel.request_resize);
    }

    pub fn newXdgPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const xdg_surface = xdg_popup.base;

        // These asserts are fine since  tinywl.zig doesn't support anything else that can
        // make xdg popups (e.g. layer shell).
        const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrFromInt(parent.data)) orelse {
            // The xdg surface user data could be left null due to allocation failure.
            return;
        };
        const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("failed to allocate xdg popup node", .{});
            return;
        };
        xdg_surface.data = @intFromPtr(scene_tree);

        const popup = gpa.create(Popup) catch {
            std.log.err("failed to allocate new popup", .{});
            return;
        };
        popup.* = .{
            .xdg_popup = xdg_popup,
        };

        xdg_surface.surface.events.commit.add(&popup.commit);
        xdg_popup.events.destroy.add(&popup.destroy);
    }

    const ViewAtResult = struct {
        toplevel: *Toplevel,
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };

    pub fn viewAt(server: *Server, lx: f64, ly: f64) ?ViewAtResult {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (server.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
            if (node.type != .buffer) return null;
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

            var it: ?*wlr.SceneTree = node.parent;
            while (it) |n| : (it = n.node.parent) {
                if (@as(?*Toplevel, @ptrFromInt(n.node.data))) |toplevel| {
                    return ViewAtResult{
                        .toplevel = toplevel,
                        .surface = scene_surface.surface,
                        .sx = sx,
                        .sy = sy,
                    };
                }
            }
        }
        return null;
    }

    pub fn focusView(server: *Server, toplevel: *Toplevel, surface: *wlr.Surface) !void {
        if (server.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                _ = xdg_surface.role_data.toplevel.?.setActivated(false);
            }
        }

        toplevel.scene_tree.node.raiseToTop();

        const ws = &server.workspaces.items[server.workspace_cur];
        if (std.mem.indexOfScalar(*Toplevel, ws.toplevels.items, toplevel)) |idx| {
            _ = ws.toplevels.swapRemove(idx);
        }

        try server.workspaces.items[server.workspace_cur].toplevels.insert(0, toplevel);
        server.workspaces.items[server.workspace_cur].toplvl_cur = 0;

        _ = toplevel.xdg_toplevel.setActivated(true);

        const wlr_keyboard = server.seat.getKeyboard() orelse return;
        server.seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );
    }

    pub fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const server: *Server = @fieldParentPtr("new_input", listener);
        switch (device.type) {
            .keyboard => keyboard.Keyboard.create(server, device) catch |err| {
                std.log.err("failed to create keyboard: {}", .{err});
                return;
            },
            .pointer => server.cursor.attachInputDevice(device),
            else => {},
        }

        server.seat.setCapabilities(.{
            .pointer = true,
            .keyboard = server.keyboards.length() > 0,
        });
    }

    pub fn switchWS(server: *Server, workspace_pre: usize) void {
        for (server.workspaces.items[workspace_pre].toplevels.items) |toplvl| {
            toplvl.scene_tree.node.setEnabled(false); // show window
        }
        for (server.workspaces.items[server.workspace_cur].toplevels.items) |toplvl| {
            toplvl.scene_tree.node.setEnabled(true); // show window
        }

        if (server.workspaces.items[server.workspace_cur].toplevels.items.len > 0) {
            const toplvl_cur = server.workspaces.items[server.workspace_cur].toplvl_cur;
            const toplvl = server.workspaces.items[server.workspace_cur].toplevels.items[toplvl_cur];
            toplvl.server.focusView(toplvl, toplvl.xdg_toplevel.base.surface) catch |e| {
                std.log.err("focusView failed to work: {}", .{e});
            };
        }
        Tiling.refreshLayout(server);
    }

    pub fn requestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_cursor", listener);
        if (event.seat_client == server.seat.pointer_state.focused_client)
            server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }

    pub fn requestSetSelection(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
        event: *wlr.Seat.event.RequestSetSelection,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_selection", listener);
        server.seat.setSelection(event.source, event.serial);
    }

    pub fn cursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion", listener);
        server.cursor.move(event.device, event.delta_x, event.delta_y);
        server.processCursorMotion(event.time_msec);
    }

    pub fn cursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion_absolute", listener);
        server.cursor.warpAbsolute(event.device, event.x, event.y);
        server.processCursorMotion(event.time_msec);
    }

    pub fn processCursorMotion(server: *Server, time_msec: u32) void {
        switch (server.cursor_mode) {
            .passthrough => if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
                server.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
                server.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
            } else {
                server.cursor.setXcursor(server.cursor_mgr, "default");
                server.seat.pointerClearFocus();
            },
            .move => {
                const toplevel = server.grabbed_view.?;
                toplevel.x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
                toplevel.y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
            },
            .resize => {
                const toplevel = server.grabbed_view.?;
                const border_x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
                const border_y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));

                var new_left = server.grab_box.x;
                var new_right = server.grab_box.x + server.grab_box.width;
                var new_top = server.grab_box.y;
                var new_bottom = server.grab_box.y + server.grab_box.height;

                if (server.resize_edges.top) {
                    new_top = border_y;
                    if (new_top >= new_bottom)
                        new_top = new_bottom - 1;
                } else if (server.resize_edges.bottom) {
                    new_bottom = border_y;
                    if (new_bottom <= new_top)
                        new_bottom = new_top + 1;
                }

                if (server.resize_edges.left) {
                    new_left = border_x;
                    if (new_left >= new_right)
                        new_left = new_right - 1;
                } else if (server.resize_edges.right) {
                    new_right = border_x;
                    if (new_right <= new_left)
                        new_right = new_left + 1;
                }

                var geo_box: wlr.Box = undefined;
                toplevel.xdg_toplevel.base.getGeometry(&geo_box);
                toplevel.x = new_left - geo_box.x;
                toplevel.y = new_top - geo_box.y;
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);

                const new_width = new_right - new_left;
                const new_height = new_bottom - new_top;
                _ = toplevel.xdg_toplevel.setSize(new_width, new_height);
            },
        }
    }

    pub fn cursorButton(
        listener: *wl.Listener(*wlr.Pointer.event.Button),
        event: *wlr.Pointer.event.Button,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_button", listener);
        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        if (event.state == .released) {
            server.cursor_mode = .passthrough;
        } else if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.focusView(res.toplevel, res.surface) catch |e| {
                std.log.err("fosucView failed to work: {}", .{e});
            };
        }
    }

    pub fn cursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_axis", listener);
        server.seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    pub fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const server: *Server = @fieldParentPtr("cursor_frame", listener);
        server.seat.pointerNotifyFrame();
    }
};
