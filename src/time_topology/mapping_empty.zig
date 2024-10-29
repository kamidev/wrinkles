//! MappingEmpty & Tests

const std = @import("std");

const opentime = @import("opentime");
const serialization = @import("serialization.zig");
const mapping_mod = @import("mapping.zig");

/// Regardless what the input ordinate is, there is no value mapped to it
pub const MappingEmpty = struct {
    /// represents the input range (and effective output range) of the mapping
    defined_range: opentime.ContinuousTimeInterval,

    /// build a generic mapping from this empty mapping
    pub fn mapping(
        self:@This(),
    ) mapping_mod.Mapping
    {
        return .{
            .empty = self,
        };
    }

    pub fn project_instantaneous_cc(
        _: @This(),
        _: opentime.Ordinate
    ) !opentime.Ordinate 
    {
        return error.OutOfBounds;
    }

    pub fn project_instantaneous_cc_inv(
        _: @This(),
        _: opentime.Ordinate
    ) !opentime.Ordinate 
    {
        return error.OutOfBounds;
    }

    pub fn inverted(
        _: @This()
    ) !MappingEmpty 
    {
        return .{};
    }

    pub fn input_bounds(
        self: @This(),
    ) opentime.ContinuousTimeInterval 
    {
        return self.defined_range;
    }

    pub fn output_bounds(
        self: @This(),
    ) opentime.ContinuousTimeInterval 
    {
        return self.input_bounds();
    }

    pub fn clone(
        self: @This(),
        _: std.mem.Allocator,
    ) !MappingEmpty
    {
        return .{
            .defined_range = .{
                .start_seconds = self.defined_range.start_seconds,
                .end_seconds = self.defined_range.end_seconds,
            },
        };
    }

    pub fn shrink_to_input_interval(
        self: @This(),
        _: std.mem.Allocator,
        target_range: opentime.ContinuousTimeInterval,
    ) !MappingEmpty
    {
        const maybe_new_range = (
            opentime.interval.intersect(
                self.defined_range,
                target_range,
            )
        );
        if (maybe_new_range)
            |new_range|
        {
            return .{
                .defined_range = new_range,
            };
        }

        return error.OutOfBounds;
    }

    /// for the empty, return self, no output interval to shrink
    pub fn shrink_to_output_interval(
        self: @This(),
        _: std.mem.Allocator,
        _: opentime.ContinuousTimeInterval,
    ) !MappingEmpty
    {
        return self;
    }

    ///
    pub fn split_at_input_point(
        self: @This(),
        allocator: std.mem.Allocator,
        pt: opentime.Ordinate,
    ) ![2]mapping_mod.Mapping
    {
        _ = allocator;

        return .{ 
            .{
                .empty = .{
                    .defined_range = .{
                        .start_seconds = self.defined_range.start_seconds,
                        .end_seconds = pt,
                    },
                },
            },
            .{
                .empty = .{
                    .defined_range = .{
                        .start_seconds = pt,
                        .end_seconds = self.defined_range.end_seconds,
                    },
                },
            },
        };
    }
};

pub const EMPTY_INF = MappingEmpty{
    .defined_range = opentime.INF_CTI,
};

test "MappingEmpty: instantiate and convert"
{
    const me = (EMPTY_INF).mapping();
    const json_txt =  try serialization.to_string(
        std.testing.allocator,
        me
    );
    defer std.testing.allocator.free(json_txt);
}

test "MappingEmpty: Project"
{
    const me = (EMPTY_INF).mapping();

    var v : f32 = -10;
    while (v < 10)
        : (v += 0.2)
    {
        try std.testing.expectError(
            error.OutOfBounds,
            me.project_instantaneous_cc(v)
        );
    }
}

test "MappingEmpty: Bounds"
{
    const me = (
        MappingEmpty{
            .defined_range = .{
                .start_seconds = -2,
                .end_seconds = 2,
            },
        }
    ).mapping();

    const i_b = me.input_bounds();
    try std.testing.expectEqual(
        -2,
        i_b.start_seconds
    );
    try std.testing.expectEqual(
        2,
        i_b.end_seconds
    );

    // returns an infinite output bounds
    const o_b = me.output_bounds();
    try std.testing.expectEqual(
        -2,
        o_b.start_seconds
    );
    try std.testing.expectEqual(
        2,
        o_b.end_seconds
    );
}
