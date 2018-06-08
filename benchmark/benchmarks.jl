using BenchmarkTools
const SUITE = BenchmarkGroup()

SUITE["region_models"] = BenchmarkGroup
SUITE["region_models"] = @benchmarkable (include("RegionTutorialBenchmarks.jl"))
