const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const gpa = std.heap.c_allocator;
const Tiling = @import("tiling.zig");
const Server = @import("server.zig").Server;

pub const Toplevel = struct {
    server: *Server,
    // link: wl.list.Link = undefined,
    xdg_toplevel: *wlr.XdgToplevel,
    scene_tree: *wlr.SceneTree,

    wid: u32 = 0,
    focused: bool = false,

    x: i32 = 0,
    y: i32 = 0,

    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    map: wl.Listener(void) = .init(handleMap),
    unmap: wl.Listener(void) = .init(handleUnmap),
    destroy: wl.Listener(void) = .init(handleDestroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(handleRequestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(handleRequestResize),

    pub fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const toplevel: *Toplevel = @fieldParentPtr("commit", listener);
        if (toplevel.xdg_toplevel.base.initial_commit) {
            _ = toplevel.xdg_toplevel.setSize(0, 0);
        }
    }

    pub fn handleMap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("map", listener);
        toplevel.server.workspaces.items[toplevel.server.workspace_cur].toplevels.insert(0, toplevel) catch |e| {
            std.log.err("toplevel Insertion failed: {}", .{e});
        };
        toplevel.server.focusView(toplevel, toplevel.xdg_toplevel.base.surface) catch |e| {
            std.log.err("focusView failed to work: {}", .{e});
        };
        // Tiling.layoutFibonacci(toplevel);

        Tiling.refreshLayout(toplevel.server, toplevel.server.workspaces.items[toplevel.server.workspace_cur].layout_cur);
    }

    pub fn handleUnmap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("unmap", listener);
        const toplevels = toplevel.server.workspaces.items[toplevel.server.workspace_cur].toplevels;
        // toplevel.link.remove();
        // Remove from current position if exists
        const ws = &toplevel.server.workspaces.items[toplevel.server.workspace_cur];
        if (std.mem.indexOfScalar(*Toplevel, ws.toplevels.items, toplevel)) |idx| {
            _ = ws.toplevels.swapRemove(idx);
        }
        // var it = toplevels.iterator(.reverse);
        if (toplevels.items.len > 0) {
            const nexttoplevel = toplevels.items[0];
            nexttoplevel.server.focusView(nexttoplevel, nexttoplevel.xdg_toplevel.base.surface) catch |e| {
                std.log.err("focusView failed to work: {}", .{e});
            };
            // Tiling.refreshLayout(nexttoplevel.server, 0);
            // Tiling.layoutFibonacci(nexttoplevel);
            Tiling.refreshLayout(nexttoplevel.server, nexttoplevel.server.workspaces.items[nexttoplevel.server.workspace_cur].layout_cur);
        }
    }

    pub fn handleDestroy(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("destroy", listener);

        toplevel.commit.link.remove();
        toplevel.map.link.remove();
        toplevel.unmap.link.remove();
        toplevel.destroy.link.remove();
        toplevel.request_move.link.remove();
        toplevel.request_resize.link.remove();

        // Tiling.layoutFibonacci(toplevel);
        gpa.destroy(toplevel);
    }

    pub fn handleRequestMove(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
        _: *wlr.XdgToplevel.event.Move,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_move", listener);
        const server = toplevel.server;
        server.grabbed_view = toplevel;
        server.cursor_mode = .move;
        server.grab_x = server.cursor.x - @as(f64, @floatFromInt(toplevel.x));
        server.grab_y = server.cursor.y - @as(f64, @floatFromInt(toplevel.y));
    }

    pub fn handleRequestResize(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
        event: *wlr.XdgToplevel.event.Resize,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_resize", listener);
        const server = toplevel.server;

        server.grabbed_view = toplevel;
        server.cursor_mode = .resize;
        server.resize_edges = event.edges;

        var box: wlr.Box = undefined;
        toplevel.xdg_toplevel.base.getGeometry(&box);

        const border_x = toplevel.x + box.x + if (event.edges.right) box.width else 0;
        const border_y = toplevel.y + box.y + if (event.edges.bottom) box.height else 0;
        server.grab_x = server.cursor.x - @as(f64, @floatFromInt(border_x));
        server.grab_y = server.cursor.y - @as(f64, @floatFromInt(border_y));

        server.grab_box = box;
        server.grab_box.x += toplevel.x;
        server.grab_box.y += toplevel.y;
    }
};

pub const Workspace = struct {
    id: usize,
    name: []const u8,
    toplevels: std.ArrayList(*Toplevel),
    // toplevels: wl.list.Head(Toplevel, .link),
    layout_cur: usize,
};
