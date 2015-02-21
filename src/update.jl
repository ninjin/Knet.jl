# TODO: express the math in readable and generic form 
# TODO: use blas for cpu versions to take advantage of multicore.

using InplaceOps

function update(w, dw, o::UpdateParam)
    initupdate(w, dw, o)
    isdefined(o,:l1reg) && (o.l1reg > zero(o.l1reg)) && l1reg!(o.l1reg, w, dw)
    isdefined(o,:l2reg) && (o.l2reg > zero(o.l2reg)) && l2reg!(o.l2reg, w, dw)
    isdefined(o,:adagrad) && (o.adagrad > zero(o.adagrad)) && adagrad!(o.adagrad, o.ada, dw)
    isdefined(o,:learningRate) && (o.learningRate != one(o.learningRate)) && (@in1! dw .* o.learningRate)
    isdefined(o,:momentum) && (o.momentum > zero(o.momentum)) && momentum!(o.momentum, o.mom, dw)
    isdefined(o,:nesterov) && (o.nesterov > zero(o.nesterov)) && nesterov!(o.nesterov, o.nes, dw)
    @in1! w .- dw
    isdefined(o,:maxnorm) && (o.maxnorm > zero(o.maxnorm)) && maxnorm!(o.maxnorm, w)
end

using Base.LinAlg

l1reg!(l1, w, dw)=(for i=1:length(dw) (w[i]>zero(w[i])) ? (dw[i]+=l1) : (w[i]<zero(w[i])) ? (dw[i]-=l1) : 0 end)
l1reg!(l1, w::CudaMatrix, dw::CudaMatrix)=ccall((:l1reg,libkunet),Void,(Cint,Cfloat,Cmat,Cmat),length(dw),l1,w,dw)

l2reg!(l2, w, dw)=axpy!(length(dw), l2, w, 1, dw, 1)
l2reg!(l2, w::CudaMatrix, dw::CudaMatrix) = CUBLAS.axpy!(length(dw), l2, w, 1, dw, 1)

adagrad!(eps, dw2, dw)=(for i=1:length(dw) (dw2[i] += dw[i] * dw[i]; dw[i] /= (eps + sqrt(dw2[i]))) end)
adagrad!(eps, dw2::CudaMatrix, dw::CudaMatrix)=ccall((:adagrad,libkunet),Void,(Cint,Cfloat,Cmat,Cmat),length(dw),eps,dw2,dw)

momentum!(m, dw2, dw)=(axpy!(length(dw), m, dw2, 1, dw, 1);copy!(dw2,dw))
momentum!(m, dw2::CudaMatrix, dw::CudaMatrix)=(CUBLAS.axpy!(length(dw), m, dw2, 1, dw, 1);copy!(dw2,dw))

nesterov!(m, dw2, dw)=(nw=length(dw);scal!(nw, m, dw2, 1); axpy!(nw, one(eltype(dw)), dw, 1, dw2, 1); axpy!(nw, m, dw2, 1, dw, 1))
nesterov!(m, dw2::CudaMatrix, dw::CudaMatrix)=(nw=length(dw);CUBLAS.scal!(nw, m, dw2, 1); CUBLAS.axpy!(nw, one(eltype(dw)), dw, 1, dw2, 1); CUBLAS.axpy!(nw, m, dw2, 1, dw, 1))

function maxnorm!(maxnorm, w)
    error("Did not debug maxnorm yet.")
    norms = sqrt(sum(w.^2, 2))
    if any(norms > o.maxnorm)
        scale = min(o.maxnorm ./ norms, 1)
        w *= scale
    end
end

function initupdate(w, dw, o::UpdateParam)
    isdefined(o,:adagrad) && (o.adagrad > zero(o.adagrad)) && chksize(o, :ada, dw)
    isdefined(o,:momentum) && (o.momentum > zero(o.momentum)) && chksize(o, :mom, dw)
    isdefined(o,:nesterov) && (o.nesterov > zero(o.nesterov)) && chksize(o, :nes, dw)
end

chksize(o, n, a)=(!isdefined(o,n) ? (o.(n) = zeros(a)) : assert(size(o.(n)) == size(a)))


function setparam!(l::Layer,k,v)
    if (k == :dropout)
        l.dropout = v
        (v > zero(v)) && (l.fx = drop)
        return
    end
    if isdefined(l, :w)
        isdefined(l, :pw) || (l.pw = UpdateParam())
        setparam!(l.pw, k, v)
    end
    if isdefined(l, :b)
        isdefined(l, :pb) || (l.pb = UpdateParam())
        if in(k, [:l1reg, :l2reg, :maxnorm]) && (v != zero(v))
            warn("Skipping $k regularization for bias.")
        else
            setparam!(l.pb, k, v)
        end
    end
end

setparam!(p::UpdateParam,k,v)=(p.(k)=v)
setparam!(net::Net,k,v)=for l=net setparam!(l,k,v) end