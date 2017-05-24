##############
#  TIMESTEP  #
##############

immutable Timestep{Offset, Duration, Final}
	t::Int
end

function isfirsttimestep(ts::Timestep)
	return ts.t == 1
end

# for users to tell when they are on the final timestep 
function isfinaltimestep{Offset, Duration, Final}(ts::Timestep{Offset, Duration, Final})
	return gettime(ts) == Final
end

# used to determine when a clock is finished
function ispastfinaltimestep{Offset, Duration, Final}(ts::Timestep{Offset, Duration, Final})
	return gettime(ts) > Final
end

function getnexttimestep{Offset, Duration, Final}(ts::Timestep{Offset, Duration, Final})
	if ispastfinaltimestep(ts)
		error("Cannot get next timestep, this is final timestep.")
	end
	return Timestep{Offset, Duration, Final}(ts.t + 1)
end

function getnewtimestep{Offset, Duration, Final}(ts::Timestep{Offset, Duration, Final}, newoffset::Int)
	return Timestep{newoffset, Duration, Final}(Int64(ts.t + (Offset-newoffset)/Duration))
end

function gettime{Offset, Duration, Final}(ts::Timestep{Offset, Duration, Final})
	return Offset + (ts.t - 1) * Duration
end

###########
#  CLOCK  #
###########

type Clock
	ts::Timestep

	function Clock(offset::Int, final::Int, duration::Int)
		clk = new()
		clk.ts = Timestep{offset, duration, final}(1)
		return clk
	end
end

function gettimestep(c::Clock)
	return c.ts
end

function gettimeindex(c::Clock)
	return c.ts.t
end

function gettime(c::Clock)
	return gettime(c.ts)
end

function move_forward(c::Clock)
	c.ts = getnexttimestep(c.ts)
	nothing
end

function finished(c::Clock)
	return ispastfinaltimestep(c.ts)
end


################
#  OurTVector  #
################

type OurTVector{T, Offset, Duration} #don't need to encode N (number of dimensions) as a type parameter because we are hardcoding it as 1 for the vector case
	data::Array{T, 1}
end

function Base.getindex{T, Offset, Duration, Final}(x::OurTVector{T, Offset, Duration}, ts::Timestep{Offset, Duration, Final})
	return x.data[ts.t]
end

function Base.getindex{T, d_offset, Duration, t_offset, Final}(x::OurTVector{T, d_offset, Duration}, ts::Timestep{t_offset, Duration, Final})
	t = Int64(ts.t + (t_offset - d_offset)/Duration)
	return x.data[t]
end

function Base.indices{T, Offset, Duration}(x::OurTVector{T, Offset, Duration})
	return (Offset:Duration:(Offset + (length(x.data)-1)*Duration), )
end

################
#  OurTMatrix  #
################

type OurTMatrix{T, Offset, Duration} #don't need to encode N (number of dimensions) as a type parameter because we are hardcoding it as 2 for the matrix case
	data::Array{T, 2}
end

function Base.getindex{T, Offset, Duration, Final}(x::OurTMatrix{T, Offset, Duration}, ts::Timestep{Offset, Duration, Final}, i::Int)
	return x.data[ts.t, i]
end

function Base.getindex{T, d_offset, Duration, t_offset, Final}(x::OurTMatrix{T, d_offset, Duration}, ts::Timestep{t_offset, Duration, Final}, i::Int)
	t = Int64(ts.t + (t_offset - d_offset)/Duration)
	return x.data[t, i]
end

function Base.indices{T, Offset, Duration}(x::OurTMatrix{T, Offset, Duration})
	return (Offset:Duration:(Offset+(size(x.data)[1]-1)*Duration), 1:size(x.data)[2])
end