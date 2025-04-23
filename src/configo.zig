
fn parseCommandLayout(allocator: std.mem.Allocator, input: []const u8, layout_name: []const u8) !datatypes.Layout {
    var k: usize = 0;
    var dep: u8 = 0;
    var layout_size: u8 = 0;
    var cur: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    var cur_arr: std.ArrayList([4]f32) = std.ArrayList([4]f32).init(allocator);
    while (k < input.len) : (k += 1) {
        switch (input[k]) {
            '[' => {
                dep += 1;
                if (dep == 2) {
                    layout_size += 1;
                }
            },
            ']' => {
                if (dep == 3) {
                    const p = cur.toOwnedSlice() catch "";
                    if (p.len > 0) {
                        var ts = std.mem.tokenizeAny(u8, p, ",");
                        var arr: [4]f32 = .{ 0, 0, 0, 0 };
                        var j: usize = 0;
                        while (ts.next()) |t| {
                            if (t.len == 0) continue;
                            arr[j] = std.fmt.parseFloat(f32, t) catch return datatypes.BlakeError.WrongLayoutNumbers;
                            j += 1;
                        }
                        if (arr.len != 4) return datatypes.BlakeError.LayoutLessNumbers;
                        try cur_arr.append(arr);
                    }
                }
                dep -= 1;
            },
            ' ', '\t' => continue,
            else => {
                if (dep == 3) {
                    try cur.append(input[k]);
                }
            },
        }
    }
    const layout = datatypes.Layout{
        .name = layout_name,
        .boxs = cur_arr,
        .size = layout_size,
    };
    return layout;
}
