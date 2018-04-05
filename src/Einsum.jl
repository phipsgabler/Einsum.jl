isdefined(Base, :__precompile__) && __precompile__()

module Einsum

using Base.Cartesian
export @einsum, @einsimd

macro einsum(ex)
    _einsum(ex)
end

macro einsimd(ex)
    _einsum(ex,true,true)
end

macro einsum_checkinbounds(ex)
    _einsum(ex,false)
end

function _einsum(ex::Expr, inbound = true, simd = false)

    # Get left hand side (lhs) and right hand side (rhs) of equation
    lhs = ex.args[1]
    rhs = ex.args[2]

    # Get info on the left-hand side
    lhs_idx, lhs_arr, lhs_dim = extractindices(lhs)
    length(lhs_arr) != 1 && throw(ArgumentError("Left-hand side of ",
        "equation contains multiple arguments. Only a single referencing ",
        " expression (e.g. @einsum A[i] = ...) should be used,"))

    # Get info on the right-hand side
    rhs_idx, rhs_arr, rhs_dim = extractindices(rhs)

    # remove duplicate indices on left-hand and right-hand side
    # and ensure that the array sizes match along these dimensions
    ###########################################################
    ex_check_dims = :()

    # remove duplicate indices on the right hand side
    for i in reverse(1:length(rhs_idx))
        duplicated = false
        di = rhs_dim[i]
        for j = 1:(i-1)
            if rhs_idx[j] == rhs_idx[i]
                # found a duplicate
                duplicated = true
                dj = rhs_dim[j]

                # add dimension check ensuring consistency
                ex_check_dims = quote
                    @assert $(esc(dj)) == $(esc(di))
                    $ex_check_dims
                end
            end
        end
        for j = 1:length(lhs_idx)
            if lhs_idx[j] == rhs_idx[i]
                dj = lhs_dim[j]
                if ex.head == :(:=)
                    # ex.head is :=
                    # infer the size of the lhs array
                    lhs_dim[j] = di
                else
                    # ex.head is =, +=, *=, etc.
                    lhs_dim[j] = :(min($dj,$di))
                end
                duplicated = true
            end
        end
        if duplicated
            deleteat!(rhs_idx,i)
            deleteat!(rhs_dim,i)
        end
    end

    # remove duplicate indices on the left hand side
    for i in reverse(1:length(lhs_idx))
        duplicated = false
        di = lhs_dim[i]

        # don't need to check rhs, already done above

        for j = 1:(i-1)
            if lhs_idx[j] == lhs_idx[i]
                # found a duplicate
                duplicated = true
                dj = lhs_dim[j]

                # add dimension check
                ex_check_dims = quote
                    @assert $(esc(dj)) == $(esc(di))
                    $ex_check_dims
                end
            end
        end
        if duplicated
            deleteat!(lhs_idx,i)
            deleteat!(lhs_dim,i)
        end
    end

    # Create output array if specified by user
    ex_get_type = :(nothing)
    ex_create_arrays = :(nothing)
    ex_assignment_op = :(=)

    if ex.head == :(:=)

        # infer type of allocated array
        #    e.g. rhs_arr = [:A,:B]
        #    then the following line produces :(promote_type(eltype(A),eltype(B)))
        rhs_type = Expr(:call,:promote_type, [ Expr(:call,:eltype,arr) for arr in rhs_arr ]...)

        ex_get_type = :($(esc(:(local T = $rhs_type))))
        if length(lhs_dim) > 0
            ex_create_arrays = :($(esc(:($(lhs_arr[1]) = Array{$rhs_type}($(lhs_dim...))))))
        else
            ex_create_arrays = :($(esc(:($(lhs_arr[1]) = zero($rhs_type)))))
        end
    else
        ex_get_type = :($(esc(:(local T = eltype($(lhs_arr[1]))))))
        ex_create_arrays = :(nothing)
        ex_assignment_op = ex.head
    end

    # Copy equation, ex is the Expr we'll build up and return.
    unquote_offsets!(ex)

    if length(rhs_idx) > 0
        # There are indices on rhs that do not appear in lhs.
        # We sum over these variables.

        # Innermost expression has form s += rhs
        ex.args[1] = :s
        ex.head = :(+=)
        ex = esc(ex)

        # Nest loops to iterate over the summed out variables
        ex = nest_loops(ex,rhs_idx,rhs_dim,simd)

        lhs_assignment = Expr(ex_assignment_op, lhs, :s)
        # Prepend with s = 0, and append with assignment
        # to the left hand side of the equation.
        ex = quote
            $(esc(:(local s = zero(T))))
            $ex
            $(esc(lhs_assignment))
        end
    else
        # We do not sum over any indices
        # ex.head = :(=)
        ex.head = ex_assignment_op
        ex = :($(esc(ex)))
    end

    # Next loops to iterate over the destination variables
    ex = nest_loops(ex,lhs_idx,lhs_dim)

    # Assemble full expression and return
    if inbound
        return quote
            $ex_create_arrays
            let
                @inbounds begin
                    $ex_check_dims
                    $ex_get_type
                    $ex
                end
            end
        end
    else
        return quote
            $ex_create_arrays
            let
                $ex_check_dims
                $ex_get_type
                $ex
            end
        end
    end
end

function nest_loops(ex::Expr,idx::Vector{Symbol},dim::Vector{Expr},simd=false)
    if simd && !isempty(idx)
        # innermost index and dimension
        i = idx[1]
        d = dim[1]

        # Add @simd to the innermost loop.
        ex = quote
            local $(esc(i))
            @simd for $(esc(i)) = 1:$(esc(d))
                $(ex)
            end
        end
        start_ = 2
    else
        start_ = 1
    end

    # Add remaining for loops
    for j = start_:length(idx)
        # index and dimension we are looping over
        i = idx[j]
        d = dim[j]

        # add for loop around expression
        ex = quote
            local $(esc(i))
            for $(esc(i)) = 1:$(esc(d))
                $(ex)
            end
        end
    end
    return ex
end


extractindices(ex) = extractindices!(ex, Symbol[], Symbol[], Expr[])

function extractindices!(ex::Symbol,
                         idx_store::Vector{Symbol},
                         arr_store::Vector{Symbol},
                         dim_store::Vector{Expr})
    push!(arr_store, ex)
    return idx_store, arr_store, dim_store
end

function extractindices!(ex::Number,
                         idx_store::Vector{Symbol},
                         arr_store::Vector{Symbol},
                         dim_store::Vector{Expr})
    return idx_store, arr_store, dim_store
end

function extractindices!(ex::Expr,
                         idx_store::Vector{Symbol},
                         arr_store::Vector{Symbol},
                         dim_store::Vector{Expr})
    
    if ex.head == :ref # e.g. A[i,j,k]
        arrname = ex.args[1]
        push!(arr_store, arrname)

        # ex.args[2:end] are indices (e.g. [i,j,k])
        for (pos, idx) in enumerate(ex.args[2:end])
            extractindex!(idx, arrname, pos, idx_store, arr_store, dim_store)
        end
    elseif ex.head == :call # e.g. 2*A[i,j], transpose(A[i,j]), or A[i] + B[j]
        # ex.args[2:end] are the individual tensor expressions (e.g. [A[i], B[j]])
        for arg in ex.args[2:end]
            extractindices!(arg, idx_store, arr_store, dim_store)
        end
    else
        throw(ArgumentError("Invalid expression head: `:$(ex.head)`"))
    end
    
    idx_store, arr_store, dim_store
end


function extractindex!(ex::Symbol, arrname, position,
                       idx_store, arr_store, dim_store)
    push!(idx_store, ex)
    push!(dim_store, :(size($arrname, $position)))
end

function extractindex!(ex::Number, arrname, position,
                       idx_store, arr_store, dim_store)
    # nothing
end

function extractindex!(ex::Expr, arrname, position,
                       idx_store, arr_store, dim_store)
    # e.g. A[i+:offset] or A[i+5]
    #    ex is an Expr in this case
    #    We restrict it to be a Symbol (e.g. :i) followed by either
    #        a number or quoted expression.
    #    As before, push :i to index list
    #    Need to add/subtract off the offset to dimension list
    
    if ex.head == :call && length(ex.args) == 3
        op = ex.args[1]
        
        idx = ex.args[2]
        @assert typeof(idx) == Symbol
        
        off_expr = ex.args[3]
        
        if off_expr isa Integer
            off = ex.args[3]::Integer
        elseif off_expr isa Expr && off_expr.head == :quote
            off = off_expr.args[1]
        elseif off_expr isa QuoteNode
                off = ex.args[3].value::Symbol
        # elseif off_expr isa Expr && off_expr.head == :$
            # off = :(esc($off_expr.args[1]))
        else
            throw(ArgumentError("Improper expression inside reference on rhs"))
        end

        # push :i to indices we're iterating over
        push!(idx_store, idx)

        # need to invert + or - to determine iteration range
        if op == :+
            push!(dim_store, :(size($arrname, $position) - $off))
        elseif op == :-
            push!(dim_store, :(size($arrname, $position) + $off))
        else
            throw(ArgumentError("Operations inside ref on rhs are limited to `+` or `-`"))
        end
    elseif ex.head == :quote
        # nothing
    else
        throw(ArgumentError("Invalid index expression: `$(ex)`"))
    end
end


function unquote_offsets!(ex::Expr, inside_ref = false)
    inside_ref = inside_ref || ex.head == :ref
    
    for i = 1:length(ex.args)
        if isa(ex.args[i], Expr)
            if ex.args[i].head == :quote && inside_ref
                ex.args[i] = :($(ex.args[i].args[1]))
            else
                unquote_offsets!(ex.args[i], inside_ref)
            end
        end
    end
    
    return ex
end

# end module
############
end
