using PkgBenchmark
using BenchmarkTools

function benchmarkMimi(target::String = "", baseline::String = "master")
    return judge("Mimi", target, baseline) 
end

results = benchmarkMimi()
