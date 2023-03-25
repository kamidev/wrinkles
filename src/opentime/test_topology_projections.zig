const std = @import("std");
const opentime = @import("opentime.zig");
const util = @import("util.zig");
const EPSILON = @import("util.zig").EPSILON;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs= std.testing.expectApproxEqAbs;
const expectError = @import("std").testing.expectError;

pub fn expectNotNan(val: f32) !void {
    return try expect(std.math.isNan(val) == false);
}

///////////////////////////////////////////////////////////////////////////////
//
// test harness for functionality based on presentation notes
//
///////////////////////////////////////////////////////////////////////////////

test "identity projections" {
    const identity_inf = opentime.TimeTopology.init_inf_identity();

    const bounds = opentime.ContinuousTimeInterval{
        .start_seconds = 12,
        .end_seconds = 20,
    };
    const identity_bounded = opentime.TimeTopology.init_identity_finite(bounds);
    try expectEqual(@as(usize, 1), identity_bounded.mapping.len);
    try expectError(
        opentime.TimeTopology.ProjectionError.OutOfBounds, 
        identity_bounded.project_seconds(10),
    );
    try expectApproxEqAbs(
        @as(f32, 13),
        try identity_bounded.project_seconds(1),
        EPSILON
    );

    const inf_through_bounded = identity_bounded.project_topology(identity_inf);

    // no segments because identity_inf has no segments
    try expectEqual(@as(usize, 1), inf_through_bounded.mapping.len);

    try expectEqual(inf_through_bounded.bounds, bounds);
}

test "projection test: linear_through_linear" {
    const first = opentime.TimeTopology.init_linear(
        // slope
        4,
        // bounds
        .{.start_seconds = 0, .end_seconds=30},
    );

    try expectEqual(@as(f32, 0), try first.project_seconds(0));
    try expectApproxEqAbs(@as(f32, 8), try first.project_seconds(2), EPSILON);

    const second = opentime.TimeTopology.init_linear(
        // slope
        2,
        // bounds
        .{.start_seconds = 0, .end_seconds=15},
    );
    try expectEqual(@as(f32, 0), try second.project_seconds(0));
    try expectApproxEqAbs(@as(f32, 4), try second.project_seconds(2), EPSILON);

    // project one through the other
    const second_through_first_topo = first.project_topology(second);
    try expectEqual(
        @as(f32, 0),
        try second_through_first_topo.project_seconds(0)
    );
    try expectApproxEqAbs(
        @as(f32, 16),
        try second_through_first_topo.project_seconds(2),
        EPSILON
    );
}

test "projection test: linear_through_linear with boundary" {
    try util.skip_test();

    const first = opentime.TimeTopology.init_linear(
        // slope
        4,
        // bounds
        .{.start_seconds = 0, .end_seconds=5},
    );

    try expectEqual(@as(f32, 0), try first.project_seconds(0));
    try expectEqual(@as(f32, 8), try first.project_seconds(2));

    // because intervals are right-open, projecting the boundary value is 
    // outside of the boundary condition
    try std.testing.expectError(
        error.ProjectionError,
        first.project_seconds(5)
    );

    const second= opentime.TimeTopology.init_linear(
        // slope
        2,
        // bounds
        .{.start_seconds = 0, .end_seconds=15},
    );
    try expectEqual(@as(f32, 0),  try second.project_seconds(0));
    try expectEqual(@as(f32, 4),  try second.project_seconds(2));

    // not out of bounds for the second topology
    try expectEqual(@as(f32, 10), try second.project_seconds(5));

    // project one through the other
    const second_through_first_topo = first.project_topology(second);
    try expectEqual(@as(f32, 0), try second_through_first_topo.project_seconds(0));
    try expectEqual(@as(f32, 16), try second_through_first_topo.project_seconds(2));

    // ... but after projection, the bounds are smaller
    try std.testing.expectError(
        error.ProjectionError,
        first.project_seconds(5)
    );
}
