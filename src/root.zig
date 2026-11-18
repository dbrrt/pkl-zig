//! Zig bindings for [Apple Pkl](https://pkl-lang.org).
//!
//! Evaluate modules by talking to the `pkl` CLI over its MessagePack
//! message-passing API, the same protocol used by the official Go and Swift
//! bindings. `pkl` must be on `PATH`, or `PKL_EXECUTABLE` must point at it.

const std = @import("std");

pub const value = @import("value.zig");
pub const typed = @import("typed.zig");
pub const binary = @import("binary.zig");
pub const evaluator = @import("evaluator.zig");
pub const codegen = @import("codegen.zig");

pub const Value = value.Value;
pub const Object = value.Object;
pub const Duration = value.Duration;
pub const DurationUnit = value.DurationUnit;
pub const DataSize = value.DataSize;
pub const DataSizeUnit = value.DataSizeUnit;
pub const IntSeq = value.IntSeq;
pub const Pair = value.Pair;
pub const Entry = value.Entry;
pub const NameRef = value.NameRef;

pub const Evaluator = evaluator.Evaluator;
pub const Manager = evaluator.Manager;
pub const Options = evaluator.Options;
pub const Decoded = evaluator.Decoded;
pub const Logger = evaluator.Logger;
pub const stderr_logger = evaluator.stderr_logger;
pub const ModuleSource = evaluator.ModuleSource;
pub const ModuleReader = evaluator.ModuleReader;
pub const ResourceReader = evaluator.ResourceReader;
pub const PathElement = evaluator.PathElement;
pub const Property = evaluator.Property;
pub const Error = evaluator.Error;

pub const textSource = evaluator.textSource;
pub const textSourceUri = evaluator.textSourceUri;
pub const uriSource = evaluator.uriSource;
pub const fileUri = evaluator.fileUri;

pub const generate = codegen.generate;
pub const GenerateOptions = codegen.GenerateOptions;
pub const GeneratedFile = codegen.File;

test {
    _ = @import("msgpack.zig");
    _ = @import("value.zig");
    _ = @import("binary.zig");
    _ = @import("tests.zig");
}
