# broadcasting operations

using Base.Broadcast

import Base.Broadcast: BroadcastStyle, Broadcasted, AbstractArrayStyle, instantiate

const BroadcastGPUArray{T} = Union{AnyGPUArray{T},
                                   Base.RefValue{<:AbstractGPUArray{T}}}

# Wrapper types otherwise forget that they are GPU compatible
# NOTE: don't directly use GPUArrayStyle here not to lose downstream customizations.
BroadcastStyle(W::Type{<:WrappedGPUArray})= BroadcastStyle(Adapt.parent(W){Adapt.eltype(W), Adapt.ndims(W)})
backend(W::Type{<:WrappedGPUArray}) = backend(Adapt.parent(W){Adapt.eltype(W), Adapt.ndims(W)})

# Ref is special: it's not a real wrapper, so not part of Adapt,
# but it is commonly used to bypass broadcasting of an argument
# so we need to preserve its dimensionless properties.
BroadcastStyle(::Type{Base.RefValue{AT}}) where {AT<:AbstractGPUArray} =
    typeof(BroadcastStyle(AT))(Val(0))
backend(::Type{Base.RefValue{AT}}) where {AT<:AbstractGPUArray} = backend(AT)
# but make sure we don't dispatch to the optimized copy method that directly indexes
function Broadcast.copy(bc::Broadcasted{<:AbstractGPUArrayStyle{0}})
    ElType = Broadcast.combine_eltypes(bc.f, bc.args)
    isbitstype(ElType) || error("Cannot broadcast function returning non-isbits $ElType.")
    dest = copyto!(similar(bc, ElType), bc)
    return @allowscalar dest[CartesianIndex()]  # 0D broadcast needs to unwrap results
end

# we need to override the outer copy method to make sure we never fall back to scalar
# iteration (see, e.g., CUDA.jl#145)
@inline function Broadcast.copy(bc::Broadcasted{<:AbstractGPUArrayStyle})
    ElType = Broadcast.combine_eltypes(bc.f, bc.args)
    if !Base.isconcretetype(ElType)
        error("""GPU broadcast resulted in non-concrete element type $ElType.
                 This probably means that the function you are broadcasting contains an error or type instability.""")
    end
    copyto!(similar(bc, ElType), bc)
end

@inline function Base.materialize!(::Style, dest, bc::Broadcasted) where {Style<:AbstractGPUArrayStyle}
    return _copyto!(dest, instantiate(Broadcasted{Style}(bc.f, bc.args, axes(dest))))
end

@inline Base.copyto!(dest::BroadcastGPUArray, bc::Broadcasted{Nothing}) = _copyto!(dest, bc) # Keep it for ArrayConflict

@inline Base.copyto!(dest::AbstractArray, bc::Broadcasted{<:AbstractGPUArrayStyle}) = _copyto!(dest, bc)

@inline function _copyto!(dest::AbstractArray, bc::Broadcasted)
    axes(dest) == axes(bc) || Broadcast.throwdm(axes(dest), axes(bc))
    isempty(dest) && return dest
    bc′ = Broadcast.preprocess(dest, bc)

    # grid-stride kernel
    function broadcast_kernel(ctx, dest, ::Val{Is}, bc′, nelem) where Is
        j = 0
        while j < nelem
            j += 1

            i = @linearidx(dest, j)

            # cartesian indexing is slow, so avoid it if possible
            if isa(IndexStyle(dest), IndexCartesian) || isa(IndexStyle(bc′), IndexCartesian)
                # this performs an integer division, which is expensive. to make it possible
                # for the compiler to optimize it away, we put the iterator in the type
                # domain so that the indices are available at compile time. note that LLVM
                # only seems to replace pow2 divisions (with bitshifts), but other back-ends
                # may be smarter and replace arbitrary divisions by bit operations.
                #
                # also see maleadt/StaticCartesian.jl, which implements this in Julia,
                # but does not result in an additional speed-up on tested back-ends.
                #
                # in addition, we use @inbounds to avoid bounds checks, but we also need to
                # inform the compiler about the bounds that we are assuming. this is done
                # using the assume intrinsic, and in case of Metal yields a 8x speed-up.
                assume(1 <= i <= length(Is))
                I = @inbounds Is[i]
            end

            val = if isa(IndexStyle(bc′), IndexCartesian)
                @inbounds bc′[I]
            else
                @inbounds bc′[i]
            end

            if isa(IndexStyle(dest), IndexCartesian)
                @inbounds dest[I] = val
            else
                @inbounds dest[i] = val
            end
        end
        return
    end
    elements = length(dest)
    elements_per_thread = typemax(Int)
    Is = CartesianIndices(dest)
    heuristic = launch_heuristic(backend(dest), broadcast_kernel, dest, Val(Is), bc′, 1;
                                 elements, elements_per_thread)
    config = launch_configuration(backend(dest), heuristic;
                                  elements, elements_per_thread)
    gpu_call(broadcast_kernel, dest, Val(Is), bc′, config.elements_per_thread;
             threads=config.threads, blocks=config.blocks)

    return dest
end

## map

allequal(x) = true
allequal(x, y, z...) = x == y && allequal(y, z...)

function Base.map(f, x::BroadcastGPUArray, xs::AbstractArray...)
    # if argument sizes match, their shape needs to be preserved
    xs = (x, xs...)
    if allequal(size.(xs)...)
         return f.(xs...)
    end

    # if not, treat them as iterators
    indices = LinearIndices.(xs)
    common_length = minimum(length.(indices))

    # construct a broadcast to figure out the destination container
    ElType = Broadcast.combine_eltypes(f, xs)
    isbitstype(ElType) || error("Cannot map function returning non-isbits $ElType.")
    dest = similar(x, ElType, common_length)

    return map!(f, dest, xs...)
end

function Base.map!(f, dest::BroadcastGPUArray, xs::AbstractArray...)
    # custom broadcast, ignoring the container size mismatches
    # (avoids the reshape + view that our mapreduce impl has to do)
    indices = LinearIndices.((dest, xs...))
    common_length = minimum(length.(indices))
    common_length==0 && return

    bc = Broadcast.instantiate(Broadcast.broadcasted(f, xs...))
    if bc isa Broadcast.Broadcasted
        bc = Broadcast.preprocess(dest, bc)
    end

    # grid-stride kernel
    function map_kernel(ctx, dest, bc, nelem)
        for i in 1:nelem
            j = linear_index(ctx, i)
            j > common_length && return

            J = CartesianIndices(axes(bc))[j]
            @inbounds dest[j] = bc[J]
        end
        return
    end
    elements = common_length
    elements_per_thread = typemax(Int)
    heuristic = launch_heuristic(backend(dest), map_kernel, dest, bc, 1;
                                 elements, elements_per_thread)
    config = launch_configuration(backend(dest), heuristic;
                                  elements, elements_per_thread)
    gpu_call(map_kernel, dest, bc, config.elements_per_thread;
             threads=config.threads, blocks=config.blocks)

    return dest
end
