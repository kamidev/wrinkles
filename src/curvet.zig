// curve visualizer tool for opentime
const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zm = @import("zmath");
const zstbi = @import("zstbi");

const build_options = @import("build_options");
const content_dir = build_options.curvet_content_dir;

const opentime = @import("opentime");
const interval = opentime.interval;
const curve = @import("curve");
const string = @import("string_stuff");
const time_topology = @import("time_topology");
const util = opentime.util;

const DebugBezierFlags = packed struct (i8) {
    bezier: bool = true,
    knots: bool = false,
    control_points: bool = false,
    linearized: bool = false,

    _padding: i4 = 0,

    pub fn draw_ui(self: * @This(), name: []const u8) void {
        const fields = .{
            .{ "Draw Bezier Curves", "bezier"},
            .{ "Draw Knots", "knots"},
            .{ "Draw Control Points", "control_points" },
            .{ "Draw Linearized", "linearized" },
        };

        zgui.pushStrId(name);
        zgui.text("{s}:", .{ name });

        inline for (fields) 
            |field| 
        {
            // unpack into a bool type
            var c_value:bool = @field(self, field[1]);
            _ = zgui.checkbox(field[0], .{ .v = &c_value,});
            // pack back into the aligned field
            @field(self, field[1]) = c_value;

        }
        zgui.popId();
    }
};

const DebugDrawCurveFlags = struct {
    input_curve: DebugBezierFlags = .{},
    split_critical_points: DebugBezierFlags = .{ .bezier = false },
    three_point_approximation: struct {
        result_curves: DebugBezierFlags = .{ .bezier = false },
        A: bool = false,
        midpoint: bool = false,
        C: bool = false,
        e1_2: bool = false,
        v1_2: bool = false,
        C1_2: bool = false,
        pub fn draw_ui(self: *@This(), name: []const u8) void {
            self.result_curves.draw_ui(name);

            const fields = .{
                "A", 
                "midpoint", 
                "C",
                "e1_2",
                "v1_2",
                "C1_2",
            };

            inline for (fields) |field| {
                _ = zgui.checkbox(field, .{ .v = & @field(self, field) });
            }
        }
    } = .{},

    pub fn draw_ui(self: *@This(), name: []const u8) void {
        zgui.pushStrId(name);
        self.input_curve.draw_ui("input_curve");
        self.split_critical_points.draw_ui("split on critical points");
        self.three_point_approximation.draw_ui("three point approximation");
        zgui.popId();
    }
};

const VisCurve = struct {
    fpath: [:0]u8,
    curve: curve.TimeCurve,
    split_hodograph: curve.TimeCurve,
    active: bool = true,
    editable: bool = false,
    show_approximation: bool = false,
    draw_flags: DebugDrawCurveFlags = .{},
};

const projTmpTest = struct {
    fst: VisCurve,
    snd: VisCurve,
};

fn _is_between(val: f32, fst: f32, snd: f32) bool {
    return ((fst <= val and val < snd) or (fst >= val and val > snd));
}

const VisTransform = struct {
    topology: time_topology.AffineTopology = .{},
    active: bool = true,
};

const VisOperation = union(enum) {
    curve: VisCurve,
    transform: VisTransform,
};

const VisState = struct {
    operations: std.ArrayList(VisOperation),
    show_demo: bool = false,
    show_test_curves: bool = false,
    show_projection_result: bool = true,

    pub fn deinit(
        self: *const @This(),
        allocator: std.mem.Allocator
    ) void 
    {
        for (self.operations.items) 
            |visop| 
        {
            switch (visop) 
            {
                .curve => |crv| {
                    allocator.free(crv.curve.segments);
                    allocator.free(crv.split_hodograph.segments);
                    allocator.free(crv.fpath);
                },
                else => {},
            }
        }
        self.operations.deinit();
    }
};

const GraphicsState = struct {
    gctx: *zgpu.GraphicsContext,

    font_normal: zgui.Font,
    font_large: zgui.Font,

    // texture: zgpu.TextureHandle,
    texture_view: zgpu.TextureViewHandle,

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        window: *zglfw.Window
    ) !*GraphicsState 
    {
        const gctx = try zgpu.GraphicsContext.create(allocator, window);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Create a texture.
        zstbi.init(arena);
        defer zstbi.deinit();

        const font_path = content_dir ++ "genart_0025_5.png";

        var image = try zstbi.Image.loadFromFile(font_path, 4);
        defer image.deinit();

        const texture = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{
                .width = image.width,
                .height = image.height,
                .depth_or_array_layers = 1,
            },
            .format = .rgba8_unorm,
            .mip_level_count = 1,
        });
        const texture_view = gctx.createTextureView(texture, .{});

        gctx.queue.writeTexture(
            .{ .texture = gctx.lookupResource(texture).? },
            .{
                .bytes_per_row = image.bytes_per_row,
                .rows_per_image = image.height,
            },
            .{ .width = image.width, .height = image.height },
            u8,
            image.data,
        );

        zgui.init(allocator);
        zgui.plot.init();
        const scale_factor = scale_factor: {
            const scale = window.getContentScale();
            break :scale_factor @max(scale[0], scale[1]);
        };

        // const fira_font_path = content_dir ++ "FiraCode-Medium.ttf";
        const robota_font_path = content_dir ++ "Roboto-Medium.ttf";

        const font_size = 16.0 * scale_factor;
        const font_large = zgui.io.addFontFromFile(
            robota_font_path,
            font_size * 1.1
        );
        const font_normal = zgui.io.addFontFromFile(
            robota_font_path,
            font_size
        );
        std.debug.assert(zgui.io.getFont(0) == font_large);
        std.debug.assert(zgui.io.getFont(1) == font_normal);

        // This needs to be called *after* adding your custom fonts.
        zgui.backend.init(
            window,
            gctx.device,
            @intFromEnum(zgpu.GraphicsContext.swapchain_format)
        );

        // This call is optional. Initially, zgui.io.getFont(0) is a default font.
        zgui.io.setDefaultFont(font_normal);

        // You can directly manipulate zgui.Style *before* `newFrame()` call.
        // Once frame is started (after `newFrame()` call) you have to use
        // zgui.pushStyleColor*()/zgui.pushStyleVar*() functions.
        const style = zgui.getStyle();

        style.window_min_size = .{ 320.0, 240.0 };
        style.window_border_size = 8.0;
        style.scrollbar_size = 6.0;
        {
            var color = style.getColor(.scrollbar_grab);
            color[1] = 0.8;
            style.setColor(.scrollbar_grab, color);
        }
        style.scaleAllSizes(scale_factor);

        // To reset zgui.Style with default values:
        //zgui.getStyle().* = zgui.Style.init();

        {
            zgui.plot.getStyle().line_weight = 3.0;
            const plot_style = zgui.plot.getStyle();
            plot_style.marker = .circle;
            plot_style.marker_size = 5.0;
        }


        const gfx_state = try allocator.create(GraphicsState);
        gfx_state.* = .{
            .gctx = gctx,
            .texture_view = texture_view,
            .font_normal = font_normal,
            .font_large = font_large,
            .allocator = allocator,
        };

        return gfx_state;
    }

    fn deinit(self: *@This()) void {
        zgui.backend.deinit();
        zgui.plot.deinit();
        zgui.deinit();
        self.gctx.destroy(self.allocator);
        self.allocator.destroy(self);
    }
};

pub fn main() !void {
    zglfw.init() catch {
        std.log.err("GLFW did not initialize properly.", .{});
        return;
    };
    defer zglfw.terminate();

    zglfw.WindowHint.set(.cocoa_retina_framebuffer, 1);
    zglfw.WindowHint.set(.client_api, 0);

    const title = (
        "OpenTimelineIO V2 Prototype Bezier Curve Visualizer [" 
        ++ build_options.hash[0..6] 
        ++ "]"
    );

    const window = (
        zglfw.Window.create(1600, 1000, title, null) 
        catch {
            std.log.err("Could not create a window", .{});
            return;
        }
    );
    defer window.destroy();
    window.setSizeLimits(400, 400, -1, -1);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const gfx_state = GraphicsState.init(allocator, window) catch {
        std.log.err("Could not initialize resources", .{});
        return;
    };
    defer gfx_state.deinit();

    var state = try _parse_args(allocator);

    var pbuf:[1024:0]u8 = .{};
    var u_path:[:0]u8 = try std.fmt.bufPrintZ(
        &pbuf,
        "{s}",
        .{ "curves/upside_down_u.curve.json" }
    );
    const u_curve = try curve.read_curve_json(u_path, allocator);
    defer u_curve.deinit(allocator);

    // const identSeg_half = curve.create_linear_segment(
    //     .{ .time = -2, .value = -1 },
    //     .{ .time = 2, .value = 1 },
    // );
    // const lin_half = try curve.TimeCurve.init(&.{identSeg_half});
    // const lin_name_half = try std.fmt.bufPrintZ(
    //     pbuf[512..],
    //     "{s}",
    //     .{  "linear slope of 0.5 [-2, 2)" }
    // );


    const identSeg = curve.create_identity_segment(-0.2, 1) ;
    const lin = try curve.TimeCurve.init(&.{identSeg});
    const lin_name = try std.fmt.bufPrintZ(
        pbuf[512..],
        "{s}",
        .{  "linear [0, 1)" }
    );
    var tmpCurves = projTmpTest{
        .fst = .{ 
            .curve = u_curve,
            // .curve = lin_half,
            .fpath = u_path,
            // .fpath = lin_name_half,
            // .split_hodograph = try lin_half.split_on_critical_points(allocator),
            .split_hodograph = try u_curve.split_on_critical_points(allocator),
        },
        .snd = .{ 
            .curve = lin,
            .fpath = lin_name,
            .split_hodograph = try lin.split_on_critical_points(allocator),
        },
    };
    defer tmpCurves.fst.split_hodograph.deinit(allocator);
    defer tmpCurves.snd.split_hodograph.deinit(allocator);
    defer state.deinit(allocator);

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
        try update(gfx_state, &state, &tmpCurves, allocator);
        draw(gfx_state);
    }
}


pub fn evaluated_curve(
    crv: curve.TimeCurve,
    comptime steps:usize
) !struct{ xv: [steps]f32, yv: [steps]f32 }
{
    if (crv.segments.len == 0) {
        return .{ .xv = .{}, .yv = .{} };
    }

    const ext = crv.extents();
    const stepsize:f32 = (ext[1].time - ext[0].time) / @as(f32, steps);

    var xv:[steps]f32 = .{};
    var yv:[steps]f32 = .{};

    var i:usize = 0;
    var uv:f32 = ext[0].time;
    for (crv.segments) |seg| {
        uv = seg.p0.time;

        while (i < steps - 1) : (i += 1) {

            // guarantee that it hits the end point
            if (uv > seg.p3.time) {
                xv[i] = seg.p3.time;
                yv[i] = seg.p3.value;
                i += 1;

                break;
            }

            // should not ever be hit
            errdefer std.log.err(
                "error: uv was: {:0.3} extents: {any:0.3}\n",
                .{ uv, ext }
            );
            const p = crv.evaluate(uv) catch blk: {
                break :blk ext[0].value;
            };

            xv[i] = uv;
            yv[i] = p;

            uv += stepsize;
        }
    }

    if (crv.segments.len > 0) {
        const end_point = crv.segments[crv.segments.len - 1].p3;

        xv[steps - 1] = end_point.time;
        yv[steps - 1] = end_point.value;
    }

    return .{ .xv = xv, .yv = yv };
}

fn plot_point(
    full_label: [:0]const u8,
    short_label: [:0]const u8,
    pt: curve.ControlPoint,
    size: f32,
) void
{
    zgui.plot.pushStyleVar1f(.{ .idx = .marker_size, .v = size });
    _ = zgui.plot.plotScatter(
        full_label,
        f32,
        .{
            .xv = &.{pt.time},
            .yv = &.{pt.value},
        }
    );
    zgui.plot.plotText(
        short_label,
        .{
            .x = pt.time,
            .y = pt.value,
            .pix_offset = .{ 0, size * 1.75 },
        }
    );
    zgui.plot.popStyleVar(.{ .count = 1 });
}

fn plot_knots(
    hod: curve.TimeCurve, 
    name: [:0]const u8,
    allocator: std.mem.Allocator,
) !void 
{
    var buf:[1024:0]u8 = .{};
    @memset(&buf, 0);

    {
        const name_ = try std.fmt.bufPrintZ(
            &buf,
            "{s}: Bezier Knots",
            .{name}
        );

        const knots_xv = try allocator.alloc(f32, hod.segments.len + 1);
        defer allocator.free(knots_xv);
        const knots_yv = try allocator.alloc(f32, hod.segments.len + 1);
        defer allocator.free(knots_yv);

        const endpoints = try hod.segment_endpoints();

        for (endpoints, 0..) |knot, knot_ind| {
            knots_xv[knot_ind] = knot.time;
            knots_yv[knot_ind] = knot.value;
        }

        zgui.plot.pushStyleVar1f(.{ .idx = .marker_size, .v = 30 });
        zgui.plot.plotScatter(
            name_,
            f32,
            .{
                .xv = knots_xv,
                .yv = knots_yv,
            }
        );

        for (endpoints, 0..) |pt, pt_ind| {
            const label = try std.fmt.bufPrintZ(&buf, "{d}", .{ pt_ind });
            zgui.plot.plotText(
                label,
                .{ .x = pt.time, .y = pt.value, .pix_offset = .{ 0, 45 } }
            );
        }

        zgui.plot.popStyleVar(.{ .count = 1 });
    }
}

fn plot_control_points(
    hod: curve.TimeCurve, 
    name: [:0]const u8,
    allocator: std.mem.Allocator,
) !void 
{
    var buf:[1024:0]u8 = .{};
    @memset(&buf, 0);

    {
        const name_ = try std.fmt.bufPrintZ(
            &buf,
            "{s}: Bezier Control Points",
            .{name}
        );

        const knots_xv = try allocator.alloc(f32, 4 * hod.segments.len);
        defer allocator.free(knots_xv);
        const knots_yv = try allocator.alloc(f32, 4 * hod.segments.len);
        defer allocator.free(knots_yv);

        zgui.pushStrId(name_);
        zgui.text(
            "Mid point debug: {s}",
            .{name},
        );
        for (hod.segments, 0..) |seg, seg_ind| {
            for (seg.points(), 0..) |pt, pt_ind| {
                knots_xv[seg_ind * 4 + pt_ind] = pt.time;
                knots_yv[seg_ind * 4 + pt_ind] = pt.value;
                const pt_text = try std.fmt.bufPrintZ(
                    buf[512..],
                    "{d}.{d}: ({d:0.2}, {d:0.2})",
                    .{ seg_ind, pt_ind, pt.time, pt.value },
                );
                zgui.plot.plotText(
                    pt_text,
                    .{.x = pt.time, .y = pt.value, .pix_offset = .{0, 36}} 
                );
                zgui.bulletText("{s}", .{pt_text});
            }
        }
        zgui.popId();
        
        zgui.plot.plotLine(
            name_,
            f32,
            .{
                .xv = knots_xv,
                .yv = knots_yv,
            }
        );

        zgui.plot.pushStyleVar1f(.{ .idx = .marker_size, .v = 20 });
        zgui.plot.plotScatter(
            name_,
            f32,
            .{
                .xv = knots_xv,
                .yv = knots_yv,
            }
        );
        zgui.plot.popStyleVar(.{ .count = 1 });
    }
}

fn plot_linear_curve(
    lin:curve.TimeCurveLinear,
    name:[:0]const u8,
    allocator:std.mem.Allocator
) !void
{
    var xv:[]f32 = try allocator.alloc(f32, lin.knots.len);
    defer allocator.free(xv);
    var yv:[]f32 = try allocator.alloc(f32, lin.knots.len);
    defer allocator.free(yv);

    for (lin.knots, 0..) |knot, knot_index| {
        xv[knot_index] = knot.time;
        yv[knot_index] = knot.value;
    }

    var tmp_buf:[1024:0]u8 = .{};
    @memset(&tmp_buf, 0);

    const label = try std.fmt.bufPrintZ(
        &tmp_buf,
        "{s}: {d} knots",
        .{ name, lin.knots.len }
    );

    zgui.plot.plotLine(
        label,
        f32,
        .{ .xv = xv, .yv = yv }
    );
}

fn plot_editable_bezier_curve(
    crv:*curve.TimeCurve,
    name:[:0]const u8,
    allocator:std.mem.Allocator
) !void 
{
    const col: [4]f32 = .{ 1, 0, 0, 1 };

    var hasher = std.hash.Wyhash.init(0);
    for (name) |char| {
        std.hash.autoHash(&hasher, char);
    }

    for (crv.segments, 0..) |*seg, seg_ind| {
        std.hash.autoHash(&hasher, seg_ind);

        var in_pts = seg.points();
        var times: [4]f64 = .{ 
            @floatCast(f64, in_pts[0].time),
            @floatCast(f64, in_pts[1].time),
            @floatCast(f64, in_pts[2].time),
            @floatCast(f64, in_pts[3].time),
        };
        var values: [4]f64 = .{ 
            @floatCast(f64, in_pts[0].value),
            @floatCast(f64, in_pts[1].value),
            @floatCast(f64, in_pts[2].value),
            @floatCast(f64, in_pts[3].value),
        };

        inline for (0..4) |idx| {
            std.hash.autoHash(&hasher, idx);

            _ = zgui.plot.dragPoint(
                @truncate(i32, @intCast(i65, hasher.final())),
                .{ 
                    .x = &times[idx],
                    .y = &values[idx], 
                    .size = 20,
                    .col = &col,
                }
            );
            in_pts[idx] = .{
                .time = @floatCast(f32, times[idx]),
                .value = @floatCast(f32, values[idx]),
            };
        }

        seg.set_points(in_pts);
    }

    try plot_bezier_curve(crv.*, name, .{}, allocator);
}

fn plot_bezier_curve(
    crv:curve.TimeCurve,
    name:[:0]const u8,
    flags: DebugBezierFlags,
    allocator:std.mem.Allocator
) !void 
{
    const pts = try evaluated_curve(crv, 1000);

    var buf:[1024:0]u8 = .{};
    @memset(&buf, 0);

    const label = try std.fmt.bufPrintZ(
        &buf,
        "{s} [{d} segments]",
        .{ name, crv.segments.len }
    );

    if (flags.bezier) {
        zgui.plot.plotLine(
            label,
            f32,
            .{ .xv = &pts.xv, .yv = &pts.yv }
        );
    }

    if (flags.control_points) {
        try plot_control_points(crv, name, allocator);
    }

    if (flags.knots) {
        try plot_knots(crv, name, allocator);
    }
}

const tpa_result = struct {
    result: ?curve.Segment = null,
    A:  ?curve.ControlPoint = null,
    C:  ?curve.ControlPoint = null,
    e1: ?curve.ControlPoint = null,
    e2: ?curve.ControlPoint = null,
    v1: ?curve.ControlPoint = null,
    v2: ?curve.ControlPoint = null,
    C1: ?curve.ControlPoint = null,
    C2: ?curve.ControlPoint = null,
};

fn three_point_guts_plot(
        start_knot: curve.ControlPoint,
        mid_point: curve.ControlPoint,
        u_mid_point: f32,
        d_mid_point_dt: curve.ControlPoint,
        end_knot: curve.ControlPoint,
) tpa_result
{
    var final_result = tpa_result{};

    // from pomax
    // if B is the midpoint, there are points A and C such that C is the
    // midpoint of the first and last control points and A is the midpoint
    // of the inner control points.
    // 
    // Based on this we can infer the position of the inner control points

    // C is a lerp between the end points
    const C = curve.bezier_math.lerp_cp(u_mid_point, start_knot, end_knot);
    final_result.C = C;

    // abs( (t^3 + (1-t)^3 - 1) / ( t^3 + (1-t)^3 ) )
    const ratio_t = cmp_t: {
        const t = u_mid_point;
        const t_cubed = t * t * t;
        const one_minus_t = 1 - t;
        const one_minus_t_cubed = one_minus_t * one_minus_t * one_minus_t;

        const result = @fabs(
            (t_cubed + one_minus_t_cubed - 1)
            /
            (t_cubed + one_minus_t_cubed)
        );
        break :cmp_t result;
    };
    // A = B - (C-B)/ratio_t
    const A = mid_point.sub(
        ((C.sub(mid_point)).div(ratio_t))
    );
    final_result.A = A;

    // then set up an e1 and e2 parallel to the baseline
    const e2 = curve.ControlPoint{
        .time= mid_point.time + d_mid_point_dt.time * u_mid_point,
        .value = mid_point.value + d_mid_point_dt.value * u_mid_point,
    };
    const e1 = curve.ControlPoint{
        .time= mid_point.time - d_mid_point_dt.time * (1-u_mid_point),
        .value= mid_point.value - d_mid_point_dt.value * (1-u_mid_point),
    };
    final_result.e1 = e1;
    final_result.e2 = e2;

    // then use those e1/e2 to derive the new hull coordinates
    const v1 = (e1.sub(A.mul(u_mid_point))).mul(1/(1-u_mid_point));
    const v2 = (e2.sub(A.mul(1-u_mid_point))).mul(1/u_mid_point);
    final_result.v1 = v1;
    final_result.v2 = v2;

    // C1 = (v1 - (1 - t) * start) / t
    const C1 = (v1.sub(start_knot.mul(1-u_mid_point))).div(u_mid_point);
    // C2 = (v2 - t * end) / (1 - t)
    const C2 = (v2.sub(end_knot.mul(u_mid_point))).div(1 - u_mid_point);
    final_result.C1 = C1;
    final_result.C2 = C2;

    const result_seg : curve.Segment = .{
        .p0 = start_knot,
        .p1 = C1,
        .p2 = C2,
        .p3 = end_knot,
    };
    final_result.result = result_seg;

    return final_result;
}

fn plot_curve(
    crv: *VisCurve,
    name: [:0]const u8,
    allocator: std.mem.Allocator,
) !void 
{
    var buf:[1024:0]u8 = .{};
    @memset(&buf, 0);

    const flags = crv.draw_flags;

    // input curve
    if (flags.input_curve.bezier) {
        if (crv.editable) {
            try plot_editable_bezier_curve(&crv.curve, name, allocator);
            crv.split_hodograph.deinit(allocator);
            crv.split_hodograph = try crv.curve.split_on_critical_points(allocator);
        } else {
            try plot_bezier_curve(
                crv.curve,
                name,
                flags.input_curve,
                allocator
            );
        }
    }

    // input curve linearized
    if (flags.input_curve.linearized) {
        const lin_label = try std.fmt.bufPrintZ(
            &buf,
            "{s} / linearized", 
            .{ name }
        );
        const orig_linearized = crv.curve.linearized();
        try plot_linear_curve(orig_linearized, lin_label, allocator);
    }

    // three point approximation
    {
        const approx_label = try std.fmt.bufPrintZ(
            &buf,
            "{s} / approximation using three point method",
            .{ name }
        );
        var approx_segments = std.ArrayList(curve.Segment).init(allocator);
        defer approx_segments.deinit();

        const crv_hodo = crv.split_hodograph;

        for (crv_hodo.segments) 
            |seg| 
        {
            var mid_point = seg.eval_at(0.5);

            const cSeg : curve.bezier_curve.hodographs.BezierSegment = .{
                .order = 3,
                .p = .{
                    .{ .x = seg.p0.time, .y = seg.p0.value },
                    .{ .x = seg.p1.time, .y = seg.p1.value },
                    .{ .x = seg.p2.time, .y = seg.p2.value },
                    .{ .x = seg.p3.time, .y = seg.p3.value },
                },
            };
            var hodo = curve.bezier_curve.hodographs.compute_hodograph(&cSeg);
            const d_mid_point_dt_v2 = curve.bezier_curve.hodographs.evaluate_bezier(
                &hodo,
                0.5
            );
            const d_mid_point_dt = curve.ControlPoint{
                .time = d_mid_point_dt_v2.x,
                .value = d_mid_point_dt_v2.y,
            };

            const tpa_guts = three_point_guts_plot(
                seg.p0,
                mid_point,
                0.5,
                d_mid_point_dt,
                seg.p3,
            );

            // derivative at the midpoint
            try approx_segments.append(tpa_guts.result.?);

            if (flags.three_point_approximation.midpoint) 
            {
                const label =  try std.fmt.bufPrintZ(
                    &buf,
                    "{s} / midpoint",
                    .{ name }
                );
                plot_point(label, "midpoint", mid_point, 20);
            }

            if (tpa_guts.A) |a| {
                if (flags.three_point_approximation.A)
                {
                    const label =  try std.fmt.bufPrintZ(
                        &buf,
                        "{s} / A",
                        .{ name }
                    );
                    plot_point(label, "A", a, 20);
                }
            }

            if (tpa_guts.C) |c| {
                if (flags.three_point_approximation.C) 
                {
                    const label =  try std.fmt.bufPrintZ(
                        &buf,
                        "{s} / C",
                        .{ name }
                    );
                    plot_point(label, "C", c, 20);
                }
            }

            if (flags.three_point_approximation.e1_2) 
            {
                const e1 = tpa_guts.e1.?;
                const e2 = tpa_guts.e2.?;
                
                const xv = &.{ e1.time, mid_point.time, e2.time };
                const yv = &.{ e1.value, mid_point.value, e2.value };

                const label =  try std.fmt.bufPrintZ(
                    &buf,
                    "{s} / e1->midpoint->e2",
                    .{ name }
                );

                zgui.plot.plotLine(
                    label,
                    f32,
                    .{ .xv = xv, .yv = yv }
                );

                plot_point(label, "e1", e1, 20);
                plot_point(label, "e2", e2, 20);
            }

            if (flags.three_point_approximation.v1_2) 
            {
                const v1 = tpa_guts.v1.?;
                const v2 = tpa_guts.v2.?;
                
                const xv = &.{ v1.time,  tpa_guts.A.?.time,  v2.time };
                const yv = &.{ v1.value, tpa_guts.A.?.value, v2.value };

                const label =  try std.fmt.bufPrintZ(
                    &buf,
                    "{s} / v1->A->v2",
                    .{ name }
                );

                zgui.plot.plotLine(
                    label,
                    f32,
                    .{ .xv = xv, .yv = yv }
                );

                plot_point(label, "v1", v1, 20);
                plot_point(label, "v2", v2, 20);
            }

            if (flags.three_point_approximation.C1_2) 
            {
                const c1 = tpa_guts.C1.?;
                const c2 = tpa_guts.C2.?;
                
                // const xv = &.{ v1.time,  mid_point.time,  v2.time };
                // const yv = &.{ v1.value, mid_point.value, v2.value };

                const label =  try std.fmt.bufPrintZ(
                    &buf,
                    "{s} / c1/c2",
                    .{ name }
                );

                // zgui.plot.plotLine(
                //     label,
                //     f32,
                //     .{ .xv = xv, .yv = yv }
                // );

                plot_point(label, "c1", c1, 20);
                plot_point(label, "c2", c2, 20);
            }
        }

        const approx_crv = try curve.TimeCurve.init(approx_segments.items);

        try plot_bezier_curve(
            approx_crv,
            approx_label,
            flags.three_point_approximation.result_curves,
            allocator
        );
    }

    // split on critical points
    {
        const split = try crv.curve.split_on_critical_points(allocator);
        defer split.deinit(allocator);

        @memset(&buf, 0);
        const label = try std.fmt.bufPrintZ(
            &buf,
            "{s} / split on critical points", 
            .{ name }
        );

        try plot_bezier_curve(
            split,
            label,
            flags.split_critical_points,
            allocator
        );

        if (flags.split_critical_points.linearized) {
            const linearized = split.linearized();
            try plot_linear_curve(linearized, label, allocator);
        }
    }

}

fn update(
    gfx_state: *GraphicsState,
    state: *VisState,
    tmpCurves: *projTmpTest,
    allocator: std.mem.Allocator,
) !void 
{
    var _proj = time_topology.TimeTopology.init_identity_infinite();
    const inf = time_topology.TimeTopology.init_identity_infinite();

    for (state.operations.items) 
        |visop| 
    {
        var _topology: time_topology.TimeTopology = .{ .empty = .{} };

        switch (visop) 
        {
            .transform => |xform| {
                if (!xform.active) {
                    continue;
                } else {
                    _topology = .{ .affine = xform.topology };
                }
            },
            .curve => |crv| {
                if (!crv.active) {
                    continue;
                } else {
                    _topology = .{ .bezier_curve = .{ .curve = crv.curve } };
                }
            },
        }

        _proj = _topology.project_topology(_proj) catch inf;
    }

    zgui.backend.newFrame(
        gfx_state.gctx.swapchain_descriptor.width,
        gfx_state.gctx.swapchain_descriptor.height,
    );

    zgui.setNextWindowPos(.{ .x = 0.0, .y = 0.0, });

    const size = gfx_state.gctx.window.getFramebufferSize();
    const width = @floatFromInt(f32, size[0]);
    const height = @floatFromInt(f32, size[1]);

    zgui.setNextWindowSize(.{ .w = width, .h = height, });

    var main_flags = zgui.WindowFlags.no_decoration;
    main_flags.no_resize = true;
    main_flags.no_background = true;
    main_flags.no_move = true;
    main_flags.no_scroll_with_mouse = true;
    main_flags.no_bring_to_front_on_focus = true;
    // main_flags.menu_bar = true;

    if (!zgui.begin("###FULLSCREEN", .{ .flags = main_flags })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    // FPS/status line
    zgui.bulletText(
        "Average : {d:.3} ms/frame ({d:.1} fps)",
        .{ gfx_state.gctx.stats.average_cpu_time, gfx_state.gctx.stats.fps },
    );
    zgui.spacing();

    var tmp_buf:[1024:0]u8 = .{};
    @memset(&tmp_buf, 0);

    {
        if (zgui.beginChild("Plot", .{ .w = width - 600 }))
        {

            if (zgui.plot.beginPlot(
                    "Curve Plot",
                    .{ 
                        .h = -1.0,
                        .flags = .{ .equal = true },
                    }
                )
            ) 
            {
                zgui.plot.setupAxis(.x1, .{ .label = "input" });
                zgui.plot.setupAxis(.y1, .{ .label = "output" });
                zgui.plot.setupLegend(
                    .{ 
                        .south = true,
                        .west = true 
                    },
                    .{}
                );
                zgui.plot.setupFinish();
                for (state.operations.items, 0..) 
                    |*visop, op_index| 
                {

                    switch (visop.*) 
                    {
                        .curve => |*crv| {
                            const name = try std.fmt.bufPrintZ(
                                &tmp_buf,
                                "{d}: Bezier Curve / {s}",
                                .{op_index, crv.fpath[0..]}
                            );

                            try plot_curve(crv, name, allocator);
                        },
                        else => {},
                    }
                }

                if (state.show_projection_result) {
                    switch (_proj) 
                    {
                        .linear_curve => |lint| { 
                            const lin = lint.curve;
                            try plot_linear_curve(lin, "result / linear", allocator);
                        },
                        .bezier_curve => |bez| {
                            const pts = try evaluated_curve(bez.curve, 1000);

                            zgui.plot.plotLine(
                                "result [bezier]",
                                f32,
                                .{ .xv = &pts.xv, .yv = &pts.yv }
                            );
                        },
                        .affine =>  {
                            zgui.plot.plotLine(
                                "NO RESULT: AFFINE",
                                f32,
                                .{ 
                                    .xv = &[_] f32{},
                                    .yv = &[_] f32{},
                                }
                            );
                        },
                        .empty => {
                            zgui.plot.plotLine(
                                "EMPTY RESULT",
                                f32,
                                .{ 
                                    .xv = &[_] f32{},
                                    .yv = &[_] f32{},
                                }
                            );
                        },
                    }
                }

                if (state.show_test_curves) 
                {
                    // debug 
                    var self = tmpCurves.fst.curve;
                    var other = tmpCurves.snd.curve;

                    try plot_editable_bezier_curve(&self, "self", allocator);
                    try plot_editable_bezier_curve(&other, "other", allocator);

                    const self_hodograph = try self.split_on_critical_points(allocator);
                    defer self_hodograph.deinit(allocator);
                    try plot_bezier_curve(self_hodograph, "self hodograph", .{}, allocator);

                    const other_hodograph = try other.split_on_critical_points(allocator);
                    defer other_hodograph.deinit(allocator);
                    try plot_bezier_curve(other_hodograph, "other hodograph", .{}, allocator);

                    const other_bounds = other.extents();
                    var other_copy = try curve.TimeCurve.init(
                        other_hodograph.segments
                    );

                    {
                        var split_points = std.ArrayList(f32).init(allocator);
                        defer split_points.deinit();

                        // find all knots in self that are within the other bounds
                        for (try self_hodograph.segment_endpoints())
                            |self_knot| 
                        {
                            if (
                                _is_between(
                                    self_knot.time,
                                    other_bounds[0].value,
                                    other_bounds[1].value
                                )
                            ) {
                                try split_points.append(self_knot.time);
                            }

                        }

                        var result = try other_copy.split_at_each_output_ordinate(
                            split_points.items,
                            allocator
                        );
                        other_copy = try curve.TimeCurve.init(result.segments);
                        result.deinit(allocator);
                    }

                    try plot_bezier_curve(other_copy, "other copy", .{}, allocator);

                    const result = self_hodograph.project_curve(other_hodograph);
                    var buf:[1024:0]u8 = .{};
                    @memset(&buf, 0);
                    const result_name = try std.fmt.bufPrintZ(
                        &buf,
                        "result of projection{s}",
                        .{
                            if (result.segments.len > 0) "" 
                            else " [NO SEGMENTS/EMPTY]",
                        }
                    );

                    zgui.text(
                        "Projection result debug:",
                        .{},
                    );
                    for (result.segments, 0..)
                        |seg, seg_ind|
                    {
                        for (seg.points(), 0..)
                            |pt, pt_ind|
                        {
                            zgui.bulletText(
                                "Result.segment_{d}.point_{d}: ({d}, {d})",
                                .{ seg_ind, pt_ind, pt.time, pt.value },
                            );
                        }
                    }

                    try plot_bezier_curve(result, result_name, .{}, allocator);
                }

                zgui.plot.endPlot();
            }
        }
        defer zgui.endChild();
    }

    zgui.sameLine(.{});

    {
        if (zgui.beginChild("Settings", .{ .w = 600, .flags = main_flags })) {
            _ = zgui.checkbox(
                "Show ZGui Demo Windows",
                .{ .v = &state.show_demo }
            );
            _ = zgui.checkbox(
                "Show Projection Test Curves",
                .{ .v = &state.show_test_curves }
            );
            _ = zgui.checkbox(
                "Show Projection Result",
                .{ .v = &state.show_projection_result }
            );

            var remove = std.ArrayList(usize).init(allocator);
            defer remove.deinit();
            var op_index:usize = 0;
            for (state.operations.items) |*visop| {
                switch (visop.*) {
                    .curve => |*crv| {
                        var buf:[1024:0]u8 = .{};
                        @memset(&buf, 0);
                        const top_label = try std.fmt.bufPrintZ(
                            &buf,
                            "Curve Settings: {s}",
                            .{ crv.fpath }
                        );

                        zgui.pushPtrId(@ptrCast(*const anyopaque, crv));
                        defer zgui.popId();
                        if (
                            zgui.collapsingHeader(
                                top_label,
                                .{ .default_open = true }
                            )
                        )
                        {
                            zgui.pushPtrId(&crv.active);
                            defer zgui.popId();

                            // debug flags
                            _ = zgui.checkbox(
                                "Active In Projections",
                                .{.v = &crv.active}
                            );
                            _ = zgui.checkbox(
                                "Editable",
                                .{.v = &crv.editable}
                            );

                            if (zgui.collapsingHeader("Draw Flags", .{})) {
                                crv.draw_flags.draw_ui(crv.fpath);
                            }

                            if (zgui.smallButton("Remove")) {
                                try remove.append(op_index);
                            }
                            zgui.sameLine(.{});
                            zgui.text(
                                "file path: {s}",
                                .{ crv.*.fpath[0..] }
                            );

                            // show the knots
                            if (zgui.collapsingHeader("Original Knots", .{})) {
                                for (try crv.curve.segment_endpoints(), 0..) 
                                    |pt, ind| 
                                {
                                    zgui.bulletText(
                                        "{d}: ({d}, {d})",
                                        .{ ind, pt.time, pt.value },
                                    );
                                }
                            }

                            if (zgui.collapsingHeader("Hodograph Debug", .{})) {
                                const cSeg : curve.bezier_curve.hodographs.BezierSegment = .{
                                    .order = 3,
                                    .p = .{
                                        .{ .x = crv.curve.segments[0].p0.time, .y = crv.curve.segments[0].p0.value },
                                        .{ .x = crv.curve.segments[0].p1.time, .y = crv.curve.segments[0].p1.value },
                                        .{ .x = crv.curve.segments[0].p2.time, .y = crv.curve.segments[0].p2.value },
                                        .{ .x = crv.curve.segments[0].p3.time, .y = crv.curve.segments[0].p3.value },
                                    },
                                };
                                const inflections = curve.bezier_curve.hodographs.inflection_points(&cSeg);
                                zgui.bulletText(
                                    "inflection point: {d:0.4}",
                                    .{inflections.x},
                                );
                                const hodo = curve.bezier_curve.hodographs.compute_hodograph(&cSeg);
                                const roots = curve.bezier_curve.hodographs.bezier_roots(&hodo);
                                zgui.bulletText(
                                    "roots: {d:0.4} {d:0.4}",
                                    .{roots.x, roots.y},
                                );
                            }

                            // split on critical points knots
                            if (
                                zgui.collapsingHeader(
                                    "Split on Critical Points Knots",
                                    .{}
                                )
                            )
                            {
                                const split = try crv.curve.split_on_critical_points(allocator);
                                defer split.deinit(allocator);

                                for (try split.segment_endpoints(), 0..) 
                                    |pt, ind| 
                                {
                                    zgui.bulletText(
                                        "{d}: ({d}, {d})",
                                        .{ ind, pt.time, pt.value },
                                    );
                                }
                            }
                        }

                    },
                    .transform => |*xform| {
                        if (
                            zgui.collapsingHeader(
                                "Affine Transform Settings",
                                .{ .default_open = true }
                            )
                        ) 
                        {
                            _ = zgui.checkbox("Active", .{.v = &xform.active});
                            zgui.sameLine(.{});
                            if (zgui.smallButton("Remove")) {
                                try remove.append(op_index);
                            }
                            var bounds: [2]f32 = .{
                                xform.topology.bounds.start_seconds,
                                xform.topology.bounds.end_seconds,
                            };
                            _ = zgui.sliderFloat(
                                "offset",
                                .{
                                    .min = -10,
                                    .max = 10,
                                    .v = &xform.topology.transform.offset_seconds
                                }
                            );
                            _ = zgui.sliderFloat(
                                "scale",
                                .{
                                    .min = -10,
                                    .max = 10,
                                    .v = &xform.topology.transform.scale
                                }
                            );
                            _ = zgui.inputFloat2(
                                "input space bounds",
                                .{ .v = &bounds }
                            );
                            xform.topology.bounds.start_seconds = bounds[0];
                            xform.topology.bounds.end_seconds = bounds[1];
                        }
                    },
                }
            }
            if (zgui.smallButton("Add")) {
                // @TODO: after updating to zig 0.11
                // zgui.openPopup("Delete?");
            }

            // Remove any "remove"'d operations
            var i:usize = remove.items.len;
            while (i > 0) {
                i -= 1;
                var visop = state.operations.orderedRemove(remove.items[i]);
                switch (visop) {
                    .curve => |crv| {
                        allocator.free(crv.curve.segments);
                        allocator.free(crv.split_hodograph.segments);
                        allocator.free(crv.fpath);
                    },
                    else => {},
                }
            }
        }
        defer zgui.endChild();
    }

    if (state.show_demo) {
        _ = zgui.showDemoWindow(null);
        _ = zgui.plot.showDemoWindow(null);
    }
}

fn draw(gfx_state: *GraphicsState) void {
    const gctx = gfx_state.gctx;

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // Gui pass.
        {
            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .load,
                .store_op = .store,
            }};
            const render_pass_info = wgpu.RenderPassDescriptor{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
            };
            const pass = encoder.beginRenderPass(render_pass_info);
            defer {
                pass.end();
                pass.release();
            }

            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});
    _ = gctx.present();
}

/// parse the commandline arguments and setup the state
fn _parse_args(
    allocator: std.mem.Allocator
) !VisState 
{
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // ignore the app name, always first in args
    _ = args.skip();

    // inline for (std.meta.fields(@TypeOf(state))) |field| {
    //     std.debug.print("{s}: {}\n", .{ field.name, @field(state, field.name) });
    // }

    var operations = std.ArrayList(VisOperation).init(allocator);

    // read all the filepaths from the commandline
    while (args.next()) |nextarg| 
    {
        const fpath: [:0]const u8 = nextarg;

        if (
            string.eql_latin_s8(fpath, "--help")
            or (string.eql_latin_s8(fpath, "-h"))
        ) {
            usage();
        }

        std.debug.print("reading curve: '{s}'\n", .{ fpath });

        const crv = curve.read_curve_json(fpath, allocator) catch |err| {
            std.debug.print(
                "Something went wrong reading: '{s}'\n",
                .{ fpath }
            );

            return err;
        };

        var viscurve = VisCurve{
            .fpath = try allocator.dupeZ(u8, fpath),
            .curve = crv,
            .split_hodograph = try crv.split_on_critical_points(allocator),
        };

        std.debug.assert(crv.segments.len > 0);

        try operations.append(.{ .curve = viscurve });
    }

    try operations.append(.{ .transform = .{} });

    return .{ .operations = operations };
}

/// print the usage message out and quit
pub fn usage() void {
    std.debug.print(
        \\
        \\usage:
        \\  curvet path/to/seg1.json [path/to/seg2.json] [...] [args]
        \\
        \\arguments:
        \\  -h --help: print this message and exit
        \\
        \\
        , .{}
    );
    std.os.exit(1);
}
