using BenchmarkTools
const SUITE = BenchmarkGroup()

#const benchmarkpath = normpath(joinpath(@__DIR__, "benchmark"))

SUITE["region_models"] = BenchmarkGroup
SUITE["region_models"] = @benchmarkable (include("RegionTutorialBenchmarks.jl"))
