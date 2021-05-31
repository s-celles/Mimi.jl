using LightGraphs
using MetaGraphs

"""
    disconnect_param!(obj::AbstractCompositeComponentDef, comp_def::AbstractComponentDef, param_name::Symbol)

Remove any parameter connections for a given parameter `param_name` in a given component
`comp_def` which must be a direct subcomponent of composite `obj`.
"""
function disconnect_param!(obj::AbstractCompositeComponentDef, comp_def::AbstractComponentDef, param_name::Symbol)
    # If the path isn't set yet, we look for a comp in the eventual location
    path = @or(comp_def.comp_path, ComponentPath(obj, comp_def.name))

    # @info "disconnect_param!($(obj.comp_path), $path, :$param_name)"

    if is_descendant(obj, comp_def) === nothing
        error("Cannot disconnect a component ($path) that is not within the given composite ($(obj.comp_path))")
    end

    filter!(x -> !(x.dst_comp_path == path && x.dst_par_name == param_name), obj.internal_param_conns)

    if obj isa ModelDef
        
        # if disconnecting an unshared parameter, it will become unreachable since
        # it's name is a random, unique symbol so remove it from the ModelDef's 
        # list of model parameters
        model_param_name = get_model_param_name(obj, nameof(comp_def), param_name; missing_ok = true)
        if !isnothing(model_param_name) && !(model_param(obj, model_param_name).is_shared)
            delete!(obj.model_params, model_param_name);
        end

        filter!(x -> !(x.comp_path == path && x.param_name == param_name), obj.external_param_conns)
    end
    dirty!(obj)
end

"""
    disconnect_param!(obj::AbstractCompositeComponentDef, comp_name::Symbol, param_name::Symbol)

Remove any parameter connections for a given parameter `param_name` in a given component
`comp_def` which must be a direct subcomponent of composite `obj`.
"""
function disconnect_param!(obj::AbstractCompositeComponentDef, comp_name::Symbol, param_name::Symbol)
    comp = compdef(obj, comp_name)
    comp === nothing && error("Did not find $comp_name in composite $(printable(obj.comp_path))")
    disconnect_param!(obj, comp, param_name)
end

# Default string, string unit check function
verify_units(unit1::AbstractString, unit2::AbstractString) = (unit1 == unit2)

"""
    _check_labels(obj::AbstractCompositeComponentDef,
                comp_def::AbstractComponentDef, param_name::Symbol, 
                mod_param::ArrayModelParameter)

Check that the labels of the ArrayModelParameter `mod_param` match the labels
of the model parameter `param_name` in component `comp_def` of object `obj`, 
including datatype and dimensions. 
"""
function _check_labels(obj::AbstractCompositeComponentDef,
                       comp_def::AbstractComponentDef, param_name::Symbol, mod_param::ArrayModelParameter)
    param_def = parameter(comp_def, param_name)

    t1 = eltype(mod_param.values)
    t2 = eltype(param_def.datatype)
    if !(t1 <: Union{Missing, t2})
        error("Mismatched datatype of parameter connection: Component: $(comp_def.comp_id) ($t1), Parameter: $param_name ($t2)")
    end

    comp_dims  = dim_names(param_def)
    param_dims = dim_names(mod_param)

    if ! isempty(param_dims) && size(param_dims) != size(comp_dims)
        d1 = size(comp_dims)
        d2 = size(param_dims)
        error("Mismatched dimensions of parameter connection: Component: $(comp_def.comp_id) ($d1), Parameter: $param_name ($d2)")
    end

    # Don't check sizes for ConnectorComps since they won't match.
    if nameof(comp_def) in (:ConnectorCompVector, :ConnectorCompMatrix)
        return nothing
    end

    # index_values = indexvalues(obj)

    for (i, dim) in enumerate(comp_dims)
        if isa(dim, Symbol)
            param_length = size(mod_param.values)[i]
            comp_length = dim_count(obj, dim)
            if param_length != comp_length
                error("Mismatched data size for a parameter connection: dimension :$dim in $(comp_def.comp_id) has $comp_length elements; model parameter :$param_name has $param_length elements.")
            end
        end
    end
end

"""
    _check_labels(obj::AbstractCompositeComponentDef,
                comp_def::AbstractComponentDef, param_name::Symbol, 
                mod_param::ScalarModelParameter)

Check that the labels of the ScalarModelParameter `mod_param` match the labels
of the model parameter `param_name` in component `comp_def` of object `obj`, 
including datatype. 
"""
function _check_labels(obj::AbstractCompositeComponentDef,
                        comp_def::AbstractComponentDef, param_name::Symbol, 
                        mod_param::ScalarModelParameter)

    # check datatype conversion
    parameter_datatype = parameter(comp_def, param_name).datatype
    model_parameter_dataype = typeof(mod_param.value)

    # if the parameter_datatype is Number (the default), we just need our value
    # to be a subtype of Number
    if parameter_datatype == Number && !(model_parameter_dataype <: Number)
        error("Cannot connect $(nameof(compdef)):$param_name, with datatype $parameter_datatype, ", 
        "to shared model parameter $(nameof(model_param)) with datatype $model_parameter_dataype ",
        "because of $model_parameter_dataype is not a subtype of $parameter_datatype.")
    
    # if the parameter_datatype is not Number, it was specified exactly and needs
    # an error
    elseif parameter_datatype !== Number && parameter_datatype!== (typeof(mod_param.value))
        error("Cannot connect $(nameof(compdef)):$param_name, with datatype $parameter_datatype, " ,
        "to shared model parameter $(nameof(model_param)) with datatype $model_parameter_dataype because ",
        "the two types should match.")
    end
end

"""
    connect_param!(obj::AbstractCompositeComponentDef, comp_name::Symbol, param_name::Symbol, model_param_name::Symbol;
                   check_labels::Bool=true, ignoreunits::Bool=false))

Connect a parameter `param_name` in the component `comp_name` of composite `obj` to
the model parameter `model_param_name`.
"""
function connect_param!(obj::AbstractCompositeComponentDef, comp_name::Symbol,
                        param_name::Symbol, model_param_name::Symbol;
                        check_labels::Bool=true, ignoreunits::Bool = false)
    comp_def = compdef(obj, comp_name)
    connect_param!(obj, comp_def, param_name, model_param_name, check_labels=check_labels, ignoreunits = ignoreunits)
end

"""
    connect_param!(obj::AbstractCompositeComponentDef, comp_def::AbstractComponentDef,
                    param_name::Symbol, model_param_name::Symbol; check_labels::Bool=true,
                    ignoreunits::Bool = false)

Connect a parameter `param_name` in the component `comp_def` of composite `obj` to
the model parameter `model_param_name`.
"""
function connect_param!(obj::AbstractCompositeComponentDef, comp_def::AbstractComponentDef,
                        param_name::Symbol, model_param_name::Symbol; check_labels::Bool=true,
                        ignoreunits::Bool = false)
    
    mod_param = model_param(obj, model_param_name)

    # check the labels 
    if check_labels && !is_nothing_param(mod_param)
        _check_labels(obj, comp_def, param_name, mod_param)
    end

    if is_shared(mod_param) && !ignoreunits
        
        param_units = parameter_unit(comp_def, param_name)
        units_match = true
        errorstring = string("Units of $(nameof(compdef)):$param_name ($param_units) do not match ", 
                        "the following other parameters connected to the same shared ",
                        "model parameter $model_param_name.  To override this error and connect anyways, ",
                        "set the `ignoreunits` flag to true: `connect_param!(m, comp_def, param_name, ",
                        "model_param_name; ignoreunits = true)`. MISMATCHES OCCUR WITH: ")

        for conn in filter(i -> i.model_param_name == model_param_name, external_param_conns(obj))
            conn_comp_def = compdef(obj, conn.comp_path)
            conn_comp_name = nameof(conn_comp_def)
            conn_param_name = conn.param_name
            conn_units =  parameter_unit(conn_comp_def, conn_param_name)
            
            if ! verify_units(param_units, conn_units)
                units_match = false
                errorstring = string(errorstring, "[$conn_comp_name:$conn_param_name with units $conn_units]  ")
            end
        end

        units_match || error(errorstring)
    end

    disconnect_param!(obj, comp_def, param_name)    # calls dirty!()

    comp_path = @or(comp_def.comp_path, ComponentPath(obj.comp_path, comp_def.name))
    conn = ExternalParameterConnection(comp_path, param_name, model_param_name)
    add_external_param_conn!(obj, conn)

    return nothing
end

"""
    _connect_param!(obj::AbstractCompositeComponentDef,
        dst_comp_path::ComponentPath, dst_par_name::Symbol,
        src_comp_path::ComponentPath, src_var_name::Symbol,
        backup::Union{Nothing, Array}=nothing;
        ignoreunits::Bool=false, backup_offset::Int=0)

Bind the parameter `dst_par_name` of one component `dst_comp_path` of composite `obj` to a
variable `src_var_name` in another component `src_comp_path` of the same model using
`backup` to provide default values and the `ignoreunits` flag to indicate the need to
check match units between the two.  The `backup_offset` argument, which is only valid 
when `backup` data has been set, indicates that the backup data should be used for
a specified number of timesteps after the source component begins. ie. the value would be 
`1` if the destination component parameter should only use the source component 
data for the second timestep and beyond.
"""
function _connect_param!(obj::AbstractCompositeComponentDef,
                        dst_comp_path::ComponentPath, dst_par_name::Symbol,
                        src_comp_path::ComponentPath, src_var_name::Symbol,
                        backup::Union{Nothing, Array}=nothing;
                        ignoreunits::Bool=false, backup_offset::Union{Nothing, Int}=nothing)

    dst_comp_def = compdef(obj, dst_comp_path)
    src_comp_def = compdef(obj, src_comp_path)

    # remove any existing connections for this dst parameter
    disconnect_param!(obj, dst_comp_def, dst_par_name)  # calls dirty!()

    # @info "dst_comp_def: $dst_comp_def"
    # @info "src_comp_def: $src_comp_def"

    if backup !== nothing
        # If value is a NamedArray, we can check if the labels match
        if isa(backup, NamedArray)
            dims = dimnames(backup)
            check_parameter_dimensions(obj, backup, dims, dst_par_name)
        else
            dims = nothing
        end

        # Check that the backup data is the right size
        if size(backup) != datum_size(obj, dst_comp_def, dst_par_name)
            error("Cannot connect parameter; the provided backup data is the wrong size. ",
                  "Expected size $(datum_size(obj, dst_comp_def, dst_par_name)) but got $(size(backup)).")
        end

        # convert number type and, if it's a NamedArray, convert to Array
        backup = convert(Array{Union{Missing, number_type(obj)}}, backup)

        dst_param = parameter(dst_comp_def, dst_par_name)
        dst_dims  = dim_names(dst_param)
        dim_count = length(dst_dims)

        ti = get_time_index_position(dst_param)

        if ti === nothing # not time dimension
            values = backup
        else # handle time dimension

            # get first and last of the ModelDef, NOT the ComponentDef
            first = first_period(obj)
            last = last_period(obj) 

            T = eltype(backup)

            if isuniform(obj)
                stepsize = step_size(obj)
                values = TimestepArray{FixedTimestep{first, stepsize, last}, T, dim_count, ti}(backup)
            else
                times = time_labels(obj)
                values = TimestepArray{VariableTimestep{(times...,)}, T, dim_count, ti}(backup)
            end

        end

        # TODO: potentially unsafe way to add parameter, advise using create_model_param!
        # and add_model_param! combo if possible ... but would need a specific ParameterDef
        add_model_array_param!(obj, dst_par_name, values, dst_dims)
        backup_param_name = dst_par_name

    else
        # cannot use backup_offset keyword argument if there is no backup
        if backup_offset !== nothing
            error("Cannot set `backup_offset` keyword argument if `backup` data is not explicitly provided")
        end

        # If backup not provided, make sure the source component covers the span of the destination component
        src_first, src_last = first_and_last(src_comp_def)
        dst_first, dst_last = first_and_last(dst_comp_def)
        if (dst_first !== nothing && src_first !== nothing && dst_first < src_first) ||
            (dst_last  !== nothing && src_last  !== nothing && dst_last  > src_last)
            src_first = printable(src_first)
            src_last  = printable(src_last)
            dst_first = printable(dst_first)
            dst_last  = printable(dst_last)
            error("""Cannot connect parameter: $src_comp_path runs only from $src_first to $src_last,
whereas $dst_comp_path runs from $dst_first to $dst_last. Backup data must be provided for missing years.
Try calling:
    `connect_param!(m, comp_name, par_name, comp_name, var_name, backup_data)`""")
        end

        backup_param_name = nothing
    end

    # Check the units, if provided
    if ! ignoreunits && ! verify_units(variable_unit(src_comp_def, src_var_name),
                                       parameter_unit(dst_comp_def, dst_par_name))
        error("Units of $src_comp_path:$src_var_name do not match $dst_comp_path:$dst_par_name.")
    end

    conn = InternalParameterConnection(src_comp_path, src_var_name, dst_comp_path, dst_par_name,
                                       ignoreunits, backup_param_name, backup_offset=backup_offset)
    add_internal_param_conn!(obj, conn)

    return nothing
end

"""
    connect_param!(obj::AbstractCompositeComponentDef,
                    dst_comp_name::Symbol, dst_par_name::Symbol,
                    src_comp_name::Symbol, src_var_name::Symbol,
                    backup::Union{Nothing, Array}=nothing; ignoreunits::Bool=false, 
                    backup_offset::Union{Nothing, Int} = nothing)

Bind the parameter `dst_par_name` of one component `dst_comp_name` of composite `obj` to a
variable `src_var_name` in another component `src_comp_name` of the same model using
`backup` to provide default values and the `ignoreunits` flag to indicate the need to
check match units between the two.  The `backup_offset` argument, which is only valid 
when `backup` data has been set, indicates that the backup data should be used for
a specified number of timesteps after the source component begins. ie. the value would be 
`1` if the destination component parameter should only use the source component 
data for the second timestep and beyond.
"""

function connect_param!(obj::AbstractCompositeComponentDef,
                        dst_comp_name::Symbol, dst_par_name::Symbol,
                        src_comp_name::Symbol, src_var_name::Symbol,
                        backup::Union{Nothing, Array}=nothing; ignoreunits::Bool=false, 
                        backup_offset::Union{Nothing, Int} = nothing)
    _connect_param!(obj, ComponentPath(obj, dst_comp_name), dst_par_name,
                        ComponentPath(obj, src_comp_name), src_var_name,
                        backup; ignoreunits=ignoreunits, backup_offset=backup_offset)
end

"""
    connect_param!(obj::AbstractCompositeComponentDef,
        dst::Pair{Symbol, Symbol}, src::Pair{Symbol, Symbol},
        backup::Union{Nothing, Array}=nothing;
        ignoreunits::Bool=false, backup_offset::Union{Nothing, Int} = nothing)

Bind the parameter `dst[2]` of one component `dst[1]` of composite `obj`
to a variable `src[2]` in another component `src[1]` of the same composite
using `backup` to provide default values and the `ignoreunits` flag to indicate the need
to check match units between the two.  The `backup_offset` argument, which is only valid 
when `backup` data has been set, indicates that the backup data should be used for
a specified number of timesteps after the source component begins. ie. the value would be 
`1` if the destination componentm parameter should only use the source component 
data for the second timestep and beyond.
"""
function connect_param!(obj::AbstractCompositeComponentDef,
                        dst::Pair{Symbol, Symbol}, src::Pair{Symbol, Symbol},
                        backup::Union{Nothing, Array}=nothing; ignoreunits::Bool=false, 
                        backup_offset::Union{Nothing, Int} = nothing)
    connect_param!(obj, dst[1], dst[2], src[1], src[2], backup; ignoreunits=ignoreunits, backup_offset=backup_offset)
end

"""
    split_datum_path(obj::AbstractCompositeComponentDef, s::AbstractString)

Split a string of the form "/path/to/component:datum_name" into the component path,
`ComponentPath(:path, :to, :component)` and name `:datum_name`.
"""
function split_datum_path(obj::AbstractCompositeComponentDef, s::AbstractString)
    elts = split(s, ":")
    length(elts) != 2 && error("Cannot split datum path '$s' into ComponentPath and datum name")
    return (ComponentPath(obj, elts[1]), Symbol(elts[2]))
end

"""
    connection_refs(obj::AbstractCompositeComponentDef)

Return a vector of UnnamedReference's to parameters from subcomponents that are either found in
internal connections or that have been already imported in a parameter definition.
"""
function connection_refs(obj::AbstractCompositeComponentDef)
    refs = UnnamedReference[]

    for conn in obj.internal_param_conns
        push!(refs, UnnamedReference(conn.dst_comp_path.names[end], conn.dst_par_name))
    end

    for item in values(obj.namespace)
        if item isa CompositeParameterDef
            for ref in item.refs
                push!(refs, ref)
            end
        end
    end

    return refs
end

"""
    connection_refs(obj::ModelDef)

Return a vector of UnnamedReference's to parameters from subcomponents that are either found in
internal connections or that have been already connected to model parameter values.
"""
function connection_refs(obj::ModelDef)
    refs = UnnamedReference[]

    for conn in obj.internal_param_conns
        push!(refs, UnnamedReference(conn.dst_comp_path.names[end], conn.dst_par_name))
    end

    for conn in obj.external_param_conns
        push!(refs, UnnamedReference(conn.comp_path.names[end], conn.param_name))
    end

    return refs
end

"""
    nothing_params(obj::AbstractCompositeComponentDef)

Return a list of UnnamedReference's to parameters that are connected to a model
parameter with a value of nothing.
"""
function nothing_params(obj::AbstractCompositeComponentDef)

    refs = UnnamedReference[]

    for conn in obj.external_param_conns
        param = model_param(obj, conn.model_param_name)
        if is_nothing_param(param)
            push!(refs, UnnamedReference(conn.comp_path.names[end], conn.param_name))
        end
    end
    return refs
end

"""
    is_nothing_param(param::ScalarModelParameter)

Return true if `param`'s value is nothing, and false otherwise.
"""
function is_nothing_param(param::ScalarModelParameter)
    return isnothing(param.value)
end

"""
    is_nothing_param(param::ArrayModelParameter)

Return true if `param`'s values is nothing, and false otherwise.
"""
function is_nothing_param(param::ArrayModelParameter)
    return isnothing(param.values)
end
 
"""
    unconnected_params(obj::AbstractCompositeComponentDef)

Return a list of UnnamedReference's to parameters that have not been connected
to a value.
"""
function unconnected_params(obj::AbstractCompositeComponentDef)
    return setdiff(subcomp_params(obj), connection_refs(obj))
end

"""
    set_leftover_params!(md::ModelDef, parameters::Dict{T, Any}) 

Set all of the parameters in `ModelDef` `md` that don't have a value and are not connected
to some other component to a value from a dictionary `parameters`. This method assumes
the dictionary keys are strings that match the names of unset parameters in the model,
and all resulting new model parameters will be shared parameters.
"""
function set_leftover_params!(md::ModelDef, parameters::Dict{T, Any}) where T
    for param_ref in nothing_params(md)

        param_name = param_ref.datum_name
        comp_name = param_ref.comp_name

        comp_def = find_comp(md, comp_name)
        param_def = comp_def[param_name]

        # check whether we need to add the model parameter to the ModelDef
        if isnothing(model_param(md, param_name, missing_ok=true))
            if haskey(parameters, string(param_name))  
                value = parameters[string(param_name)]
                param = create_model_param(md, param_def, value; is_shared = true)
                add_model_param!(md, param_name, param)
            else
                error("Cannot set parameter :$param_name, not found in provided dictionary.")
            end
        end
        connect_param!(md, comp_name, param_name, param_name)
    end
    nothing
end

# Find internal param conns to a given destination component
function internal_param_conns(obj::AbstractCompositeComponentDef, dst_comp_path::ComponentPath)
    return filter(x->x.dst_comp_path == dst_comp_path, internal_param_conns(obj))
end

function internal_param_conns(obj::AbstractCompositeComponentDef, comp_name::Symbol)
    return internal_param_conns(obj, ComponentPath(obj.comp_path, comp_name))
end

function add_internal_param_conn!(obj::AbstractCompositeComponentDef, conn::InternalParameterConnection)
    push!(obj.internal_param_conns, conn)
    dirty!(obj)
end

#
# These should all take ModelDef instead of AbstractCompositeComponentDef as 1st argument
#

# Find external param conns for a given comp
function external_param_conns(obj::ModelDef, comp_path::ComponentPath)
    return filter(x -> x.comp_path == comp_path, external_param_conns(obj))
end

function external_param_conns(obj::ModelDef, comp_name::Symbol)
    return external_param_conns(obj, ComponentPath(obj.comp_path, comp_name))
end

function model_param(obj::ModelDef, name::Symbol; missing_ok=false)
    haskey(obj.model_params, name) && return obj.model_params[name]

    missing_ok && return nothing

    error("$name not found in model parameter list")
end

function model_param(obj::ModelDef, comp_name::Symbol, param_name::Symbol; missing_ok = false)

    model_param_name = get_model_param_name(obj, comp_name, param_name; missing_ok = true)

    if isnothing(model_param_name)
        missing_ok && return nothing
        error("Model parameter connected to $comp_name's parameter $param_name not found in model's parameter connections list.")
    else
        return model_param(obj, model_param_name)
    end

end

"""
    get_model_param_name(obj::ModelDef, comp_name::Symbol, param_name::Symbol; missing_ok=false)

Get the model parameter name for the exernal parameter conneceted to comp_name's
parameter param_name.  The keyword argument `missing_ok` defaults to false so
if no parameter is found an error is thrown, if it is set to true the function will
return `nothing`.
"""
function get_model_param_name(obj::ModelDef, comp_name::Symbol, param_name::Symbol; missing_ok=false)
    for conn in obj.external_param_conns
        if conn.comp_path.names[end] == comp_name && conn.param_name == param_name
            return conn.model_param_name
        end
    end

    missing_ok && return nothing

    error("Model parameter connected to $comp_name's parameter $param_name not found in model's parameter connections list.")
end

"""
    get_model_param_name(obj::Model, comp_name::Symbol, param_name::Symbol; missing_ok=false)

Get the model parameter name for the exernal parameter connected to comp_name's
parameter param_name.  The keyword argument `missing_ok` defaults to false so
if no parameter is found an error is thrown, if it is set to true the function will
return `nothing`.
"""
function get_model_param_name(obj::Model, comp_name::Symbol, param_name::Symbol; missing_ok=false)
    get_model_param_name(obj.md, comp_name, param_name; missing_ok = missing_ok)
end

function add_external_param_conn!(obj::ModelDef, conn::ExternalParameterConnection)
    push!(obj.external_param_conns, conn)
    dirty!(obj)
end

"""
    add_model_param!(md::ModelDef, name::Symbol, value::ModelParameter)

Add an model parameter with name `name` and Model Parameter `value` to ModelDef `md`.
"""
function add_model_param!(md::ModelDef, name::Symbol, value::ModelParameter)
    # if haskey(obj.model_params, name)
    #     @warn "Redefining model param :$name in $(obj.comp_path) from $(obj.model_params[name]) to $value"
    # end
    md.model_params[name] = value
    dirty!(md)
    return value
end


"""
    add_model_param!(md::ModelDef, name::Symbol, value::Number;
                        param_dims::Union{Nothing,Array{Symbol}} = nothing, 
                        is_shared::Bool = false)

Create and add a model parameter with name `name` and Model Parameter `value` 
to ModelDef `md`. The Model Parameter will be created with value `value`, dimensions
`param_dims` which can be left to be created automatically from the Model Def, and 
an is_shared attribute `is_shared` which defaults to false.

WARNING: this has been mostly replaced by combining create_model_param with add_model_param
method using the paramdef ... certain checks are not done here ... should be careful 
using it and only do so under the hood?
"""
function add_model_param!(md::ModelDef, name::Symbol, value::Number;
                            param_dims::Union{Nothing,Array{Symbol}} = nothing, 
                            is_shared::Bool = false)
    add_model_scalar_param!(md, name, value, is_shared = is_shared)
end

"""
    add_model_param!(md::ModelDef, name::Symbol, value::Number;
                        param_dims::Union{Nothing,Array{Symbol}} = nothing, 
                        is_shared::Bool = false)

Create and add a model parameter with name `name` and Model Parameter `value` 
to ModelDef `md`. The Model Parameter will be created with value `value`, dimensions
`param_dims` which can be left to be created automatically from the Model Def, and 
an is_shared attribute `is_shared` which defaults to false.
"""
function add_model_param!(md::ModelDef, name::Symbol,
                             value::Union{AbstractArray, AbstractRange, Tuple};
                             param_dims::Union{Nothing,Array{Symbol}} = nothing, 
                             is_shared::Bool = false)

    ti = get_time_index_position(param_dims)
    if !isnothing(ti)
        value = convert(Array{number_type(md)}, value)
        num_dims = length(param_dims)
        values = get_timestep_array(md, eltype(value), num_dims, ti, value)
    else
        values = value
    end

    add_model_array_param!(md, name, values, param_dims, is_shared = is_shared)
end

"""
    add_model_array_param!(md::ModelDef,
                                name::Symbol, value::TimestepVector, 
                                dims; is_shared::Bool = false)

Add a one dimensional time-indexed array parameter indicated by `name` and
`value` to the Model Def `md`. The `is_shared` attribute of the ArrayModelParameter
will default to false. In this case `dims` must be `[:time]`.
"""
function add_model_array_param!(md::ModelDef,
                                    name::Symbol, value::TimestepVector, 
                                    dims; is_shared::Bool = false)
    param = ArrayModelParameter(value, [:time], is_shared)  # must be :time
    add_model_param!(md, name, param)
end

"""
    add_model_array_param!(md::ModelDef,
                              name::Symbol, value::TimestepMatrix, dims; 
                              is_shared::Bool = false)

Add a multi-dimensional time-indexed array parameter `name` with value
`value` to the Model Def `md`.  The `is_shared` attribute of the ArrayModelParameter
will default to false. In this case `dims` must contain `[:time]`.
"""
function add_model_array_param!(md::ModelDef,
                                name::Symbol, value::TimestepArray, dims; 
                                is_shared::Bool = false)
    !(:time in dims) && error("When adding an `ArrayModelParameter` the dimensions array must include `:time`, but here it is $dims.")
    param = ArrayModelParameter(value, dims, is_shared)
    add_model_param!(md, name, param)
end

"""
    add_model_array_param!(md::ModelDef,
                              name::Symbol, value::AbstractArray, dims; 
                              is_shared::Bool = false)

Add an array type parameter `name` with value `value` and `dims` dimensions to the 
Model Def `md`. The `is_shared` attribute of the ArrayModelParameter will default to 
false. 
"""
function add_model_array_param!(md::ModelDef,
                                   name::Symbol, value::AbstractArray, dims; 
                                   is_shared::Bool = false)
    param = ArrayModelParameter(value, dims === nothing ? Vector{Symbol}() : dims, is_shared)
    add_model_param!(md, name, param)
end

"""
    add_model_scalar_param!(md::ModelDef, name::Symbol, value::Any; is_shared::Bool = false)

Add a scalar type parameter `name` with the value `value` to the Model Def `md`.
"""
function add_model_scalar_param!(md::ModelDef, name::Symbol, value::Any; is_shared::Bool = false)
    param = ScalarModelParameter(value, is_shared)
    add_model_param!(md, name, param)
end

"""
    update_param!(obj::AbstractCompositeComponentDef, name::Symbol, value; update_timesteps = nothing)

Update the `value` of a model parameter in composite `obj`, referenced
by `name`. The update_timesteps keyword argument is deprecated, we keep it here 
just to provide warnings.
"""
function update_param!(obj::AbstractCompositeComponentDef, name::Symbol, value; update_timesteps = nothing)
    !isnothing(update_timesteps) ? @warn("Use of the `update_timesteps` keyword argument is no longer supported or needed, time labels will be adjusted automatically if necessary.") : nothing
    _update_param!(obj::AbstractCompositeComponentDef, name, value)
end

function update_param!(mi::ModelInstance, name::Symbol, value)
    param = mi.md.model_params[name]

    if param isa ScalarModelParameter
        param.value = value
    elseif param.values isa TimestepArray
        copyto!(param.values.data, value)
    else
        copyto!(param.values, value)
    end

    return nothing
end

function update_param!(mi::ModelInstance, comp_name::Symbol, param_name::Symbol, value)
    param = mi.md.model_params[get_model_param_name(mi.md, comp_name, param_name)]

    if param isa ScalarModelParameter
        param.value = value
    elseif param.values isa TimestepArray
        copyto!(param.values.data, value)
    else
        copyto!(param.values, value)
    end

    return nothing
end

"""
    update_param!(md::ModelDef, comp_name::Symbol, param_name::Symbol, value)

Update the `value` of the unshared model parameter in Model Def `md` connected to component 
`comp_name`'s parameter `param_name`. 
"""
function update_param!(md::ModelDef, comp_name::Symbol, param_name::Symbol, value)

    model_param_name = get_model_param_name(md, comp_name, param_name; missing_ok = true)

    # check if we need a new parameter, maybe because it was previously a nothing
    # parameter that got disconnected
    if isnothing(model_param_name)
        
        comp_def = find_comp(md, comp_name)
        param_def = comp_def[param_name]

        param = create_model_param(md, param_def, value; is_shared = false)

        model_param_name = gensym()
        add_model_param!(md, model_param_name, param)

        connect_param!(md, comp_name, param_name, model_param_name)
        dirty!(md)

    # update existing parameter
    else
        mod_param = model_param(md, model_param_name)
        is_shared(mod_param) && error("$comp_name:$param_name is connected to a ",
                "a shared model parameter with name $model_param_name in the model, ",
                "to update the shared model parameter please call `update_param!(m, param_name, value)` ", 
                "to explicitly update a shared parameter that may be connected to ", 
                "several components. If you want to disconnect $comp_name:$param_name ",
                "from the shared model parameter and connect it to it's own unshared ",
                "model parameter, first use `disconnect_param!` and then you can use this same ", 
                "call to `update_param!`.")

        # update the parameter
        _update_param!(md, model_param_name, value)
    end
end

"""
    _update_param!(obj::AbstractCompositeComponentDef, name::Symbol, value)

Update the `value` of the model parameter `name` in Model Def `md`.
"""
function _update_param!(obj::AbstractCompositeComponentDef, name::Symbol, value)
    param = model_param(obj, name, missing_ok=true)
    if param === nothing
        error("Cannot update parameter; $name not found in composite's model parameters.")
    end

    # handle nothing params
    if is_nothing_param(param)
        _update_nothing_param!(obj, name, value)
    else
        if param isa ScalarModelParameter
            _update_scalar_param!(param, name, value)
        else
            _update_array_param!(obj, name, value)
        end
    end
    dirty!(obj)
end

"""
    _update_scalar_param!(param::ScalarModelParameter, name, value)

Update the `value` of the scalar model parameter `param`.
"""
function _update_scalar_param!(param::ScalarModelParameter, name, value)
    if ! (value isa typeof(param.value))
        try
            value = convert(typeof(param.value), value)
        catch e
            error("Cannot update parameter $name; expected type $(typeof(param.value)) but got $(typeof(value)).")
        end
    end
    param.value = value
    nothing
end

"""
    _update_array_param!(obj::AbstractCompositeComponentDef, name, value)

Update the `value` of the array model parameter `name` in object `obj`.
"""
function _update_array_param!(obj::AbstractCompositeComponentDef, name, value)
   
    # Get original parameter
    param = model_param(obj, name)

    # Check type of provided parameter
    if !(typeof(value) <: AbstractArray)
        error("Cannot update array parameter $name with a value of type $(typeof(value)).")

    elseif !(eltype(value) <: eltype(param.values))
        try
            value = convert(Array{eltype(param.values)}, value)
        catch e
            error("Cannot update parameter $name; expected array of type $(eltype(param.values)) but got $(eltype(value)).")
        end
    end

    # Check if the parameter dimensions match the model dimensions.  Note that we 
    # previously checked if parameter dimensions matched the dimensions of the 
    # parameter they were to replace, but given dimensions of a model can be changed,
    # we now choose to enforce that the new dimensions match the current model state, 
    # whatever that is.

    expected_size = ([length(dim_keys(obj, d)) for d in dim_names(param)]...,) 
    size(value) != expected_size ? error("Cannot update parameter $name; expected array of size $expected_size but got array of size $(size(value)).") : nothing

    # check if updating timestep labels is necessary
    if param.values isa TimestepArray
        time_label_change = time_labels(param.values) != dim_keys(obj, :time)
        N = ndims(value)
        if time_label_change
            T = eltype(value)
            ti = get_time_index_position(param)
            new_timestep_array = get_timestep_array(obj, T, N, ti, value)
            # TODO: potentially unsafe way to add parameter, advise using create_model_param!
            # and add_model_param! combo if possible ... but would need a specific ParameterDef
            add_model_param!(obj, name, ArrayModelParameter(new_timestep_array, dim_names(param), param.is_shared))
        else
            copyto!(param.values.data, value)
        end
    else
        copyto!(param.values, value)
    end

    dirty!(obj)
    nothing
end

"""
    _update_nothing_param!(obj::AbstractCompositeComponentDef, name::Symbol, value)

Update the `value` of the model parameter `name` in object `obj` where the model
parameter has an initial value of nothing likely from instanitate during `add_comp!`.
"""
function _update_nothing_param!(obj::AbstractCompositeComponentDef, name::Symbol, value)

    # get the component def and param def
    conn = filter(i -> i.model_param_name == name, obj.external_param_conns)[1]
    param_name = conn.param_name

    comp_def = find_comp(obj, conn.comp_path)
    param_def = comp_def[param_name]

    # create the unshared model parameter
    param = create_model_param(obj, param_def, value)
    
    # Need to check the dimensions of the parameter data against component 
    # before adding it to the model's parameter list
    if !is_nothing_param(param) # shouldn't be a nothing param since we're updating to non-nothing!
        _check_labels(obj, comp_def, param_name, param)
    end
    
    # add the unshared model parameter to the model def, which will replace the
    # old one and thus keep the connection in tact
    add_model_param!(obj, name, param)
end

"""
    update_params!(obj::AbstractCompositeComponentDef, parameters::Dict; update_timesteps = nothing)

For each (k, v) in the provided `parameters` dictionary, `update_param!`
is called to update the model parameter identified by k to value v.

For updating unshared parameters, each key k must be a Tuple matching the name of a 
component in `obj` and the name of an parameter in that component.

For updating shared parameters, each key k must be a symbol or convert to a symbol 
matching the name of a shared model parameter that already exists in the model.
"""
function update_params!(obj::AbstractCompositeComponentDef, parameters::Dict; update_timesteps = nothing)
    !isnothing(update_timesteps) ? @warn("Use of the `update_timesteps` keyword argument is no longer supported or needed, time labels will be adjusted automatically if necessary.") : nothing
    
    for (k, v) in parameters
        if k isa Tuple
            model_param_name = get_model_param_name(obj, first(k), last(k))
        else
            model_param_name = Symbol(k)
        end 
        _update_param!(obj, model_param_name, v)
    end
    nothing
end

"""
    add_connector_comps!(obj::AbstractCompositeComponentDef)

Add all the needed Mimi connector components to object `obj`.
"""
function add_connector_comps!(obj::AbstractCompositeComponentDef)
    conns = internal_param_conns(obj)
    i = 1 # counter to track the number of connector comps added

    for comp_def in compdefs(obj)
        comp_name = nameof(comp_def)
        comp_path = comp_def.comp_path

        # first need to see if we need to add any connector components for this component
        internal_conns  = filter(x -> x.dst_comp_path == comp_path, conns)
        need_conn_comps = filter(x -> x.backup !== nothing, internal_conns)

        # isempty(need_conn_comps) || @info "Need connectors comps: $need_conn_comps"

        for conn in need_conn_comps
            add_backup!(obj, conn.backup)

            num_dims = length(size(model_param(obj, conn.backup).values))

            if ! (num_dims in (1, 2))
                error("Connector components for parameters with > 2 dimensions are not implemented.")
            end

            # Fetch the definition of the appropriate connector commponent
            conn_comp_def = (num_dims == 1 ? Mimi.ConnectorCompVector : Mimi.ConnectorCompMatrix)
            conn_comp_name = connector_comp_name(i) # generate a new name
            i += 1 # increment connector comp counter

            # Add the connector component before the user-defined component that 
            # required it, and for now let the first and last of the component 
            # be free and thus be set to the same as the model
            conn_comp = add_comp!(obj, conn_comp_def, conn_comp_name, before=comp_name)
            conn_path = conn_comp.comp_path

            # remove the connections added in add_comp!
            disconnect_param!(obj, conn_comp, :input1)
            disconnect_param!(obj, conn_comp, :input2)

            # add a connection between src_component and the ConnectorComp
            add_internal_param_conn!(obj, InternalParameterConnection(conn.src_comp_path, conn.src_var_name,
                                                                      conn_path, :input1,
                                                                      conn.ignoreunits))

            # add a connection between ConnectorComp and dst_component
            add_internal_param_conn!(obj, InternalParameterConnection(conn_path, :output,
                                                                      conn.dst_comp_path, conn.dst_par_name,
                                                                      conn.ignoreunits))

            # add a connection between ConnectorComp and the external backup data
            add_external_param_conn!(obj, ExternalParameterConnection(conn_path, :input2, conn.backup))

            # set the first and last parameters for WITHIN the component which 
            # decide when backup is used and when connection is used
            src_comp_def = compdef(obj, conn.src_comp_path)

            param_last = last_period(obj, src_comp_def)
            param_first = first_period(obj, src_comp_def)
            conn.backup_offset !== nothing ? param_first = param_first + conn.backup_offset : nothing

            set_param!(obj, conn_comp_name, :first, Symbol(conn_comp_name, "_", :first), param_first)
            set_param!(obj, conn_comp_name, :last, Symbol(conn_comp_name, "_", :last), param_last)
        end
    end

    return nothing
end


"""
    _pad_parameters!(obj::ModelDef)

Take each model parameter of the Model Definition `obj` and `update_param!` 
with new data values that are altered to match a new time dimension by (1) trimming
the values down if the time dimension has been shortened and (2) padding with missings 
as necessary.
"""
function _pad_parameters!(obj::ModelDef)

    model_times = time_labels(obj)

    for (name, param) in obj.model_params
        # there is only a chance we only need to pad a parameter if:
        #   (1) it is an ArrayModelParameter
        #   (2) it has a time dimension
        #   (3) it does not have a values attribute of nothing, as assigned on initialization
        if (param isa ArrayModelParameter) && (:time in param.dim_names) && !is_nothing_param(param)

           param_times = _get_param_times(param)
           padded_data = _get_padded_data(param, param_times, model_times)
           update_param!(obj, name, padded_data)

        end
    end
end

"""
    _get_padded_data(param::ArrayModelParameter, param_times::Vector, model_times::Vector)

Obtain the new data values for the Array Model Paramter `param` with current 
time labels `param_times` such that they are altered to match a new time dimension 
with keys `model_times` by (1) trimming the values down if the time dimension has 
been shortened and (2) padding with missings as necessary.
"""
function _get_padded_data(param::ArrayModelParameter, param_times::Vector, model_times::Vector)

    data = param.values.data
    ti = get_time_index_position(param)

    # first handle the back end 
    model_last = last(model_times)
    param_last = last(param_times)

    if model_last < param_last # trim down the data
        
        trim_idx = findfirst(isequal(last(model_times)), param_times) 
        idxs = repeat(Any[:], ndims(data))
        idxs[ti] = 1:trim_idx
        data = data[idxs...]

    elseif model_last > param_last # pad the data

        pad_length = length(model_times[findfirst(isequal(param_last), model_times)+1:end])
        dims = [size(data)...]
        dims[ti] = pad_length
        end_padding_rows = Array{Union{Missing, Number}}(missing, dims...)
        data = vcat(data, end_padding_rows)

    end

    # now handle the front end 
    model_first = first(model_times)
    param_first = first(param_times)

    # note we do not allow for any trimming off the front end
    if model_first < param_first

        pad_length = length(model_times[1:findfirst(isequal(param_first), model_times)-1])
        dims = [size(data)...]
        dims[ti] = pad_length
        begin_padding_rows = Array{Union{Missing, Number}}(missing, dims...)
        data = vcat(begin_padding_rows, data)

    end

    return data 
end

"""
    _get_param_times(param::ArrayModelParameter{TimestepArray{FixedTimestep{FIRST, STEP, LAST}, T, N, ti, S}})

Return the time labels that parameterize the `TimestepValue` which in turn parameterizes
the ArrayModelParameter `param`. 
"""
function _get_param_times(param::ArrayModelParameter{TimestepArray{FixedTimestep{FIRST, STEP, LAST}, T, N, ti, S}}) where {FIRST, STEP, LAST, T, N, ti, S}
    return collect(FIRST:STEP:LAST)
end

"""
    _get_param_times(param::ArrayModelParameter{TimestepArray{VariableTimestep{TIMES}, T, N, ti, S}})

Return the time labels that parameterize the `TimestepValue` which in turn parameterizes
the ArrayModelParameter `param`. 
"""
function _get_param_times(param::ArrayModelParameter{TimestepArray{VariableTimestep{TIMES}, T, N, ti, S}}) where {TIMES, T, N, ti, S}
    return [TIMES...]
end

"""
    add_shared_param!(md::ModelDef, name::Symbol, value::Any; dims::Array{Symbol}=Symbol[])

User-facing API function to add a shared parameter to Model Def `md` with name
`name` and value `value`, and an array of dimension names `dims` which dfaults to 
an empty vector.  The `is_shared` attribute of the added Model Parameter will be `true`.

The `value` can by a scalar, an array, or a NamedAray. Optional keyword argument 'dims' is a list
of the dimension names of the provided data, and will be used to check that they match the
model's index labels.  This must be included if the `value` is not a scalar, and defaults
to an empty vector.
"""
function add_shared_param!(md::ModelDef, name::Symbol, value::Any; dims::Array{Symbol}=Symbol[])
    
    # check to make sure the parameter doesn't already exist
    has_parameter(md, name) && error("Cannot add parameter :$name, the model already has a shared parameter with this name.")

    # make sure all parameter dims are in model and have the appropriate number of elements
    if value isa NamedArray
        dims = dimnames(value)
    end

    for dim in dims
        isa(dim, Symbol) && !has_dim(md, dim) && error("Model doesn't have dimension :$dim indicated in the dims of added shared parameter, $dims.")
    end

    if value isa AbstractArray && ndims(value) != length(dims)
        error("Please provide $(ndims(value)) dimension names for value, $(length(dims))",
        " were given but value is $value. This is done with the `dims` keyword argument ",
        " ie. : `add_shared_param!(md, name, value; dims = [:time])")
    end
    
    # create shared model parameter with a ParameterDef, which takes advantage of
    # the checks and parameterization etc. in `check_model_param`
    data_type = value isa AbstractArray ? eltype(value) : typeof(value)
    data_type = data_type <: Number ? Number : data_type # raise any Number type to Number to avoid small errors
    param_def = ParameterDef(name, nothing, data_type, dims, "", "", nothing)
    param = create_model_param(md, param_def, value; is_shared = true)
    
    # check dimensions
    model_dims = dim_names(md) 
    param_dims = dim_names(param_def)

    for (i, dim) in enumerate(param_dims)
        if isa(dim, Symbol)
            param_length = size(param.values)[i]
            model_length = dim_count(md, dim)
            if param_length != model_length
                error("Mismatched data size for new shared param: dimension :$dim in model has $model_length elements; parameter :$name value $param_length elements.")
            end
        end
    end

    # add the shared model parameter to the model def
    add_model_param!(md, name, param)
    
end

"""
    create_model_param(md::ModelDef, param_def::AbstractParameterDef, value::Any; is_shared::Bool = false)

Create a new model parameter to be added to Model Def `md` with specifications
matching parameter definition `param_def` and with `value`.  The keyword argument
is_shared defaults to false, and thus an unshared parameter would be created, whereas
setting `is_shared` to true creates a shared parameter.
"""
function create_model_param(md::ModelDef, param_def::AbstractParameterDef, value::Any; is_shared::Bool = false)
    
    # gather info
    param_name = nameof(param_def)
    param_dims = param_def.dim_names
    num_dims = length(param_dims)
    data_type = param_def.datatype
    dtype = Union{Missing, (data_type == Number ? number_type(md) : data_type)}

    # create a sentinal unshared parameter
    if isnothing(value)
        if num_dims > 0 
            param = ArrayModelParameter(value, param_dims, is_shared)
        else
            param = ScalarModelParameter(value, is_shared)
        end

    # have a value - in the initiliazation of parameters case this is a default
    # value set in defcomp
    else
        if num_dims > 0 # array parameter case
                           
            # check dimensions
            if value isa NamedArray
                dims = dimnames(value)
                dims !== nothing && check_parameter_dimensions(md, value, dims, param_name)
            end
                
            # convert the number type and, if NamedArray, convert to Array
            if dtype <: AbstractArray
                value = convert(dtype, value)
            else
                # check that number of dimensions matches
                value_dims = length(size(value))
                if num_dims != value_dims
                    error("Mismatched data size: dimension :$param_name",
                        " in has $num_dims dimensions; indicated value",
                        " has $value_dims dimensions.")
                end
                value = convert(Array{dtype, num_dims}, value)
            end

            # create TimestepArray if there is a time dim
            ti = get_time_index_position(param_dims)
            if ti !== nothing   # there is a time dimension
                T = eltype(value)
                values = get_timestep_array(md, T, num_dims, ti, value)            
            else
                values = value
            end
             
            param = ArrayModelParameter(values, param_dims, is_shared)

        else # scalar parameter case
            value = convert(dtype, value)
            param = ScalarModelParameter(value, is_shared)
        end
    end
    return param
end

##
## DEPRECATIONS - Should move from warning --> error --> removal
##

# -- throw errors -- 

# -- throw warnings -- 

@deprecate external_param(obj::ModelDef, name::Symbol; missing_ok=false) model_param(obj, name,; missing_ok = missing_ok)

@deprecate set_external_param!(obj::ModelDef, name::Symbol, value::ModelParameter) add_model_param!(obj, name, value)
@deprecate set_external_param!(obj::ModelDef, name::Symbol, value::Number; param_dims::Union{Nothing,Array{Symbol}} = nothing, is_shared::Bool = false) add_model_param!(obj, name, value; param_dims = param_dims, is_shared = is_shared)
@deprecate set_external_param!(obj::ModelDef, name::Symbol, value::Union{AbstractArray, AbstractRange, Tuple}; param_dims::Union{Nothing,Array{Symbol}} = nothing, is_shared::Bool = false) add_model_param!(obj, name, value; param_dims = param_dims, is_shared = is_shared)

@deprecate set_external_array_param!(obj::ModelDef, name::Symbol, value::TimestepVector, dims; is_shared::Bool = false) add_model_array_param!(obj, name, value, dims; is_shared = is_shared)
@deprecate set_external_array_param!(obj::ModelDef, name::Symbol, value::TimestepArray, dims;  is_shared::Bool = false) add_model_array_param(obj, name, value, dims; is_shared = is_shared)
@deprecate set_external_array_param!(obj::ModelDef, name::Symbol, value::AbstractArray, dims; is_shared::Bool = false) add_model_array_param(obj, name, value, dims; is_shared = is_shared)

@deprecate set_external_scalar_param!(obj::ModelDef, name::Symbol, value::Any; is_shared::Bool = false) add_model_scalar_param(obj, name, value; is_shared = is_shared)
