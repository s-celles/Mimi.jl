using NamedTuples
using BenchmarkTools

fields = [:foo, :bar, :baz, :buz]
nt_type = NamedTuples.make_tuple(fields)
nt = nt_type(10, 20.1, 30.2, 12)


function direct_access(nt, fields::Vector{Symbol})
    sum = 0.0
    sum += nt.foo
    sum += nt.bar
    sum += nt.baz
    sum += nt.buz
    return sum
end


function use_getfield(nt, fields::Vector{Symbol})
    sum = 0.0
    for field in fields
        sum += getfield(nt, field)
    end
    return sum
end


@generated function ntfield(nt::T, ::Val{FIELD}) where {T, FIELD}
    return :(nt.$FIELD)
end

function use_ntfield(nt, fields::Vector{Symbol})
    sum = 0.0
    for field in fields
        sum += ntfield(nt, Val(field))
    end
    return sum
end


print("direct:   ")
@btime direct_access(nt, fields)

print("getfield: ")
@btime use_getfield(nt, fields)

print("ntfield:  ")
@btime use_ntfield(nt, fields)
