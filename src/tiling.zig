const Server = @import("server.zig").Server;
const std = @import("std");
const wlr = @import("wlroots");
const Toplevel = @import("toplevel.zig").Toplevel;
const config = @import("config.zig");
const sumSize=@import("utility.zig").sumSize;

pub fn refreshLayout(server: *Server) void {
    const num = server.workspaces.items[server.workspace_cur].toplevels.items.len;
    if (num == 0) return;
    const origin = sumSize(usize, num - 1);
    const boxs = server.config.layouts.items[server.workspaces.items[server.workspace_cur].layout_cur].boxs;
    var screen: wlr.Box = undefined;
    server.output_layout.getBox(null, &screen);
    const width: f64 = @floatFromInt(screen.width);
    const height: f64 = @floatFromInt(screen.height);
    var i: usize = 0;
    std.debug.print("boxs: {any}\n",.{boxs});
    for (server.workspaces.items[server.workspace_cur].toplevels.items) |toplvl| {
        const x_f: f64 = width * boxs[origin + i][0];
        const y_f: f64 = height * boxs[origin + i][1];
        const w_f: f64 = width * boxs[origin + i][2];
        const h_f: f64 = height * boxs[origin + i][3];
        toplvl.x = @intFromFloat(x_f);
        toplvl.y = @intFromFloat(y_f);
        _ = toplvl.xdg_toplevel.setSize(@intFromFloat(w_f), @intFromFloat(h_f));
        toplvl.scene_tree.node.setPosition(toplvl.x, toplvl.y);
        i += 1;
    }
}
