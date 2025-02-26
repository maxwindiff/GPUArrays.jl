module GPUArraysCore

using Adapt


## essential types

export AbstractGPUArray, AbstractGPUVector, AbstractGPUMatrix, AbstractGPUVecOrMat,
       WrappedGPUArray, AnyGPUArray, AbstractGPUArrayStyle,
       AnyGPUArray, AnyGPUVector, AnyGPUMatrix

"""
    AbstractGPUArray{T, N} <: DenseArray{T, N}

Supertype for `N`-dimensional GPU arrays (or array-like types) with elements of type `T`.
Instances of this type are expected to live on the host, see [`AbstractDeviceArray`](@ref)
for device-side objects.
"""
abstract type AbstractGPUArray{T, N} <: DenseArray{T, N} end

const AbstractGPUVector{T} = AbstractGPUArray{T, 1}
const AbstractGPUMatrix{T} = AbstractGPUArray{T, 2}
const AbstractGPUVecOrMat{T} = Union{AbstractGPUArray{T, 1}, AbstractGPUArray{T, 2}}

# convenience aliases for working with wrapped arrays
const WrappedGPUArray{T,N} = WrappedArray{T,N,AbstractGPUArray,AbstractGPUArray{T,N}}
const AnyGPUArray{T,N} = Union{AbstractGPUArray{T,N}, WrappedGPUArray{T,N}}
const AnyGPUVector{T} = AnyGPUArray{T, 1}
const AnyGPUMatrix{T} = AnyGPUArray{T, 2}

## broadcasting

"""
Abstract supertype for GPU array styles. The `N` parameter is the dimensionality.

Downstream implementations should provide a concrete array style type that inherits from
this supertype.
"""
abstract type AbstractGPUArrayStyle{N} <: Base.Broadcast.AbstractArrayStyle{N} end

## scalar iteration

export allowscalar, @allowscalar, assertscalar

@enum ScalarIndexing ScalarAllowed ScalarWarn ScalarWarned ScalarDisallowed

# if the user explicitly calls allowscalar, use that setting for all new tasks
# XXX: use context variables to inherit the parent task's setting, once available.
const default_scalar_indexing = Ref{Union{Nothing,ScalarIndexing}}(nothing)

"""
    allowscalar() do
        # code that can use scalar indexing
    end

Denote which operations can use scalar indexing.

See also: [`@allowscalar`](@ref).
"""
function allowscalar(f::Base.Callable)
    task_local_storage(f, :ScalarIndexing, ScalarAllowed)
end

"""
    allowscalar(::Bool)

Calling this with `false` replaces the default warning about scalar indexing
(show once per session) with an error.

Instead of calling this with `true`, the preferred style is to allow this locally.
This can be done with the `allowscalar(::Function)` method (with a `do` block)
or with the [`@allowscalar`](@ref) macro.

Writes to `task_local_storage` for `:ScalarIndexing`. The default is `:ScalarWarn`,
and this function sets `:ScalarAllowed` or `:ScalarDisallowed`.
"""
function allowscalar(allow::Bool=true)
    if allow
        Base.depwarn("allowscalar([true]) is deprecated, use `allowscalar() do end` or `@allowscalar` to denote exactly which operations can use scalar operations.", :allowscalar)
    end
    setting = allow ? ScalarAllowed : ScalarDisallowed
    task_local_storage(:ScalarIndexing, setting)
    default_scalar_indexing[] = setting
    return
end

"""
    assertscalar(op::String)

Assert that a certain operation `op` performs scalar indexing. If this is not allowed, an
error will be thrown ([`allowscalar`](@ref)).
"""
function assertscalar(op = "operation")
    val = get!(task_local_storage(), :ScalarIndexing) do
        something(default_scalar_indexing[], isinteractive() ? ScalarWarn : ScalarDisallowed)
    end
    desc = """Invocation of $op resulted in scalar indexing of a GPU array.
              This is typically caused by calling an iterating implementation of a method.
              Such implementations *do not* execute on the GPU, but very slowly on the CPU,
              and therefore are only permitted from the REPL for prototyping purposes.
              If you did intend to index this array, annotate the caller with @allowscalar."""
    if val == ScalarDisallowed
        error("""Scalar indexing is disallowed.
                 $desc""")
    elseif val == ScalarWarn
        @warn("""Performing scalar indexing on task $(current_task()).
                 $desc""")
        task_local_storage(:ScalarIndexing, ScalarWarned)
    end
    return
end

"""
    @allowscalar() begin
        # code that can use scalar indexing
    end

Denote which operations can use scalar indexing.

See also: [`allowscalar`](@ref).
"""
macro allowscalar(ex)
    quote
        task_local_storage(:ScalarIndexing, ScalarAllowed) do
            $(esc(ex))
        end
    end
end

"""
    backend(T::Type)
    backend(x)

Gets the GPUArrays back-end responsible for managing arrays of type `T`.
"""
backend(::Type) = error("This object is not a GPU array") # COV_EXCL_LINE
backend(x) = backend(typeof(x))

backend(::Type{WA}) where WA<:WrappedArray = backend(parent(WA)) # WrappedArray from Adapt for Base wrappers.

end # module GPUArraysCore
