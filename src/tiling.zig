const Server = @import("server.zig").Server;
const std = @import("std");
const wlr = @import("wlroots");
const Toplevel = @import("toplevel.zig").Toplevel;

pub fn layoutFibonacci(topleveli: *Toplevel) void {
    const server = topleveli.*.server;
    const num = topleveli.*.server.toplevels.length();
    if (num == 0) return;
    var remaining: wlr.Box = undefined;
    topleveli.*.server.output_layout.getBox(null, &remaining);
    std.debug.print("width: {}, height:{}\n", .{ remaining.width, remaining.height });
    var horizontal = true; // alternate splitting direction

    // .forward, .reverse
    var it = server.toplevels.iterator(.reverse);
    var i: u32 = 0;
    while (it.next()) |toplevel| {
        if (i == num - 1) {
            toplevel.x = remaining.x;
            toplevel.y = remaining.y;
            _ = toplevel.xdg_toplevel.setSize(remaining.width, remaining.height);
        } else {
            const phi = 2;
            if (horizontal) {
                const width_f: f32 = @floatFromInt(remaining.width);
                const new_width: i32 = @intFromFloat(width_f / phi);
                toplevel.x = remaining.x;
                toplevel.y = remaining.y;
                _ = toplevel.xdg_toplevel.setSize(new_width, remaining.height);
                remaining.x += new_width;
                remaining.width -= new_width;
            } else {
                const height_f: f32 = @floatFromInt(remaining.height);
                const new_height: i32 = @intFromFloat(height_f / phi);
                toplevel.x = remaining.x;
                toplevel.y = remaining.y;
                _ = toplevel.xdg_toplevel.setSize(remaining.width, new_height);
                remaining.y += new_height;
                remaining.height -= new_height;
            }
            horizontal = !horizontal;
        }
        toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
        i += 1;
    }
}

pub fn sortApps(server: *Server) void {
    //i should make this addaptable to workspaces later. now, it only corresponds to one workspace.
    var it = server.*.toplevels.iterator(.forward);
    var i: u32 = 0;
    while (it.next()) |toplvl| {
        toplvl.wid = i;
        i += 1;
    }
}
