@doc raw"""
    Fsys(X,XPrime,Xss,m_par,n_par,indexes,Γ,compressionIndexes,DC,IDC)

Equilibrium error function: returns deviations from equilibrium around steady state.

Split computation into *Aggregate Part*, handled by [`Fsys_agg()`](@ref),
and *Heterogeneous Agent Part*.

# Arguments
- `X`,`XPrime`: deviations from steady state in periods t [`X`] and t+1 [`XPrime`]
- `Xss`: states and controls in steady state
- `Γ`,`DC`,`IDC`: transformation matrices to retrieve marginal distributions [`Γ`] and
    marginal value functions [`DC`,`IDC`] from deviations
- `indexes`,`compressionIndexes`: access `Xss` by variable names
    (DCT coefficients of compressed ``V_m`` and ``V_k`` in case of `compressionIndexes`)

# Example
```jldoctest
julia> # Solve for steady state, construct Γ,DC,IDC as in SGU()
julia> Fsys(zeros(ntotal),zeros(ntotal),XSS,m_par,n_par,indexes,Γ,compressionIndexes,DC,IDC)
*ntotal*-element Array{Float64,1}:
 0.0
 0.0
 ...
 0.0
```
"""
function Fsys(X::AbstractArray, XPrime::AbstractArray, Xss::Array{Float64,1}, m_par::ModelParameters,
              n_par::NumericalParameters, indexes::IndexStruct, Γ::Array{Array{Float64,2},1},
              compressionIndexes::Array{Array{Int,1},1}, DC::Array{Array{Float64,2},1},
              IDC::Array{Adjoint{Float64,Array{Float64,2}},1}, DCD::Array{Array{Float64,2},1},
              IDCD::Array{Adjoint{Float64,Array{Float64,2}},1})
              # The function call with Duals takes
              # Reserve space for error terms
    F = zeros(eltype(X),size(X))

    ############################################################################
    #            I. Read out argument values                                   #
    ############################################################################
    # rougly 10% of computing time, more if uncompress is actually called

    ############################################################################
    # I.1. Generate code that reads aggregate states/controls
    #      from steady state deviations. Equations take the form of:
    # r       = exp.(Xss[indexes.rSS] .+ X[indexes.r])
    # rPrime  = exp.(Xss[indexes.rSS] .+ XPrime[indexes.r])
    ############################################################################

    @generate_equations(aggr_names)

    ############################################################################
    # I.2. Distributions (Γ-multiplying makes sure that they are distributions)
    ############################################################################

    # Controls copula
    θD      = uncompressD(compressionIndexes[3], X[indexes.D], DCD,IDCD, n_par)

    DISTRAUX =zeros(eltype(θD),n_par.nm,n_par.nk,n_par.ny)
    θDaux=reshape(θD,(n_par.nm-1,n_par.nk-1, n_par.ny-1))
    DISTRAUX[1:end-1,1:end-1,1:end-1]=θDaux;
    DISTRAUX[end,1:end-1,1:end-1] = -sum(θDaux, dims=(1));
    DISTRAUX[:,end,1:end-1] = -sum(DISTRAUX[:,:,1:end-1], dims=(2));
    DISTRAUX[:,:,end] = -sum(DISTRAUX, dims=(3));

    DISTR = Xss[indexes.DSS]+ DISTRAUX[:]
    DISTR = reshape(DISTR,(n_par.nm,n_par.nk, n_par.ny))
    DISTR = max.(DISTR,1e-16);
    DISTR = DISTR./sum(DISTR[:]);
    DISTR = cumsum(cumsum(cumsum(DISTR; dims=3);dims=2);dims=1)

    distr_m       = Xss[indexes.distr_m_SS] .+ Γ[1] * X[indexes.distr_m]
    distr_m_Prime = Xss[indexes.distr_m_SS] .+ Γ[1] * XPrime[indexes.distr_m]
    distr_k       = Xss[indexes.distr_k_SS] .+ Γ[2] * X[indexes.distr_k]
    distr_k_Prime = Xss[indexes.distr_k_SS] .+ Γ[2] * XPrime[indexes.distr_k]
    distr_y       = Xss[indexes.distr_y_SS] .+ Γ[3] * X[indexes.distr_y]
    distr_y_Prime = Xss[indexes.distr_y_SS] .+ Γ[3] * XPrime[indexes.distr_y]

    # Joint distributions (uncompressing)
    CDF_m         = cumsum([0.0; distr_m[:]])
    CDF_k         = cumsum([0.0; distr_k[:]])
    CDF_y         = cumsum([0.0; distr_y[:]])

    cum_zero = zeros(eltype(θD),n_par.nm+1,n_par.nk+1, n_par.ny+1);
    cum_zero[2:end,2:end,2:end] = DISTR;
    Copula1(x::AbstractVector,y::AbstractVector,z::AbstractVector) = mylinearinterpolate3(cum_zero[:,end,end],cum_zero[end,:,end],cum_zero[end,end,:],cum_zero, x, y, z)
    #Copula1 = LinearInterpolation((cum_zero[:,end,end],cum_zero[end,:,end],cum_zero[end,end,:]),cum_zero,extrapolation_bc=Line())

    CDF_joint     = Copula1(CDF_m[:], CDF_k[:], CDF_y[:]) # roughly 5% of time
    distr         = diff(diff(diff(CDF_joint; dims=3);dims=2);dims=1)



    ############################################################################
    # I.3 uncompressing policies/value functions
    ###########################################################################
    if any((tot_dual.(XPrime[indexes.Vm])+realpart.(XPrime[indexes.Vm])).!= 0.0)
        θm      = uncompress(compressionIndexes[1], XPrime[indexes.Vm], DC,IDC, n_par)
        VmPrime = Xss[indexes.VmSS]+ θm
    else
         VmPrime = Xss[indexes.VmSS].+ zeros(eltype(X),1)[1]
    end
    VmPrime .= (exp.(VmPrime))

     if any((tot_dual.(XPrime[indexes.Vk])+realpart.(XPrime[indexes.Vk])).!= 0.0)
        θk      = uncompress(compressionIndexes[2], XPrime[indexes.Vk], DC,IDC, n_par)
        VkPrime = Xss[indexes.VkSS]+  θk
     else
         VkPrime = Xss[indexes.VkSS].+ zeros(eltype(X),1)[1]
     end
    VkPrime .= (exp.(VkPrime))

    ############################################################################
    #           II. Auxiliary Variables                                        #
    ############################################################################
    # Transition Matrix Productivity
    if tot_dual.(σ .+ zeros(eltype(X),1)[1])==0.0
        if σ==1.0
            Π                  = n_par.Π .+ zeros(eltype(X),1)[1]
        else
            Π                  = n_par.Π
            PP                 =  ExTransition(m_par.ρ_h,n_par.bounds_y,sqrt(σ))
            Π[1:end-1,1:end-1] = PP.*(1.0-m_par.ζ)
        end
    else
        Π                  = n_par.Π .+ zeros(eltype(X),1)[1]
        PP                 =  ExTransition(m_par.ρ_h,n_par.bounds_y,sqrt(σ))
        Π[1:end-1,1:end-1] = PP.*(1.0-m_par.ζ)
    end

    ############################################################################
    #           III. Error term calculations (i.e. model starts here)          #
    ############################################################################

    ############################################################################
    #           III. 1. Aggregate Part #
    ############################################################################
    F            = Fsys_agg(X, XPrime, Xss, distr, m_par, n_par, indexes)

    # Error Term on prices/aggregate summary vars (logarithmic, controls)
    KP           = dot(n_par.grid_k,distr_k[:])
    F[indexes.K] = log.(K)     - log.(KP)
    BP           = dot(n_par.grid_m,distr_m[:])
    F[indexes.B] = log.(B)     - log.(BP)

    BDact = -sum(distr_m.*(n_par.grid_m.<0).*n_par.grid_m)

    F[indexes.BD]= log.(BD)  - log.(BDact)

    # Average Human Capital =
    # average productivity (at the productivit grid, used to normalize to 0)
    H       = dot(distr_y[1:end-1],n_par.grid_y[1:end-1])

    ############################################################################
    #               III. 2. Heterogeneous Agent Part                           #
    ############################################################################
    # Incomes
    eff_int      = ((RB .* A)           .+ (m_par.Rbar .* (n_par.mesh_m.<=0.0))) ./ π # effective rate (need to check timing below and inflation)
    eff_intPrime = (RBPrime .* APrime .+ (m_par.Rbar.*(n_par.mesh_m.<=0.0))) ./ πPrime

    GHHFA=((m_par.γ + τprog)/(m_par.γ+1)) # transformation (scaling) for composite good
    tax_prog_scale = (m_par.γ + m_par.τ_prog)/((m_par.γ + τprog))
    inc =[  GHHFA.*τlev.*((n_par.mesh_y/H).^tax_prog_scale .*mcw.*w.*N./(Ht)).^(1.0-τprog).+
            (unionprofits).*(1.0 .- av_tax_rate).* n_par.HW,# labor income (NEW)
            (r .- 1.0).* n_par.mesh_k, # rental income
            eff_int .* n_par.mesh_m, # liquid asset Income
            n_par.mesh_k .* q,
            τlev.*(mcw.*w.*N.*n_par.mesh_y./ H).^(1.0-τprog).*((1.0 - τprog)/(m_par.γ+1)),
            τlev.*((n_par.mesh_y/H).^tax_prog_scale .*mcw.*w.*N./(Ht)).^(1.0-τprog)] # capital liquidation Income (q=1 in steady state)
    inc[1][:,:,end].= τlev.*(n_par.mesh_y[:,:,end] .* profits).^(1.0-τprog) # profit income net of taxes
    inc[5][:,:,end].= 0.0
    inc[6][:,:,end].= τlev.*(n_par.mesh_y[:,:,end] .* profits).^(1.0-τprog) # profit income net of taxes

    incgross =[  ((n_par.mesh_y/H).^tax_prog_scale .*mcw.*w.*N./(Ht)).+
            (unionprofits),
            (r .- 1.0).* n_par.mesh_k,                                      # rental income
            eff_int .* n_par.mesh_m,                                        # liquid asset Income
            n_par.mesh_k .* q,
            ((n_par.mesh_y/H).^tax_prog_scale .*mcw.*w.*N./(Ht))]           # capital liquidation Income (q=1 in steady state)
    incgross[1][:,:,end].= (n_par.mesh_y[:,:,end] .* profits)
    incgross[5][:,:,end].= (n_par.mesh_y[:,:,end] .* profits)

    taxrev = incgross[5]-inc[6] # tax revenues w/o tax on union profits
    incgrossaux = incgross[5]
    F[indexes.τlev] = av_tax_rate - (distr[:]' * taxrev[:])./(distr[:]' * incgrossaux[:])
    F[indexes.T]    = log(T) - log(distr[:]' * taxrev[:] + av_tax_rate * (unionprofits))


    inc[6] = τlev.*((n_par.mesh_y/H).^tax_prog_scale .*mcw.*w.*N./(Ht)).^(1.0-τprog) .+ ((1.0 .- mcw).*w.*N).*(1.0 .- av_tax_rate)
    inc[6][:,:,end].= τlev.*(n_par.mesh_y[:,:,end] .* profits).^(1.0-τprog) # profit income net of taxes



    # Calculate optimal policies
    # expected margginal values
    EVkPrime = reshape(VkPrime,(n_par.nm,n_par.nk, n_par.ny))
    EVmPrime = reshape(VmPrime,(n_par.nm,n_par.nk, n_par.ny))

    @views @inbounds begin
        for mm = 1:n_par.nm
            EVkPrime[mm,:,:] .= EVkPrime[mm,:,:]*Π'
            EVmPrime[mm,:,:] .= eff_intPrime[mm,:,:].*(EVmPrime[mm,:,:]*Π')
        end
    end
    c_a_star, m_a_star, k_a_star, c_n_star, m_n_star =
                    EGM_policyupdate(EVmPrime ,EVkPrime ,q,π,RB.*A,1.0,inc,n_par,m_par, false) # policy iteration

    # Update marginal values
    Vk_new,Vm_new = updateV(EVkPrime ,c_a_star, c_n_star, m_n_star, r - 1.0, q, m_par, n_par, Π) # update expected marginal values time t

    # Calculate error terms on marginal values
    Vm_err        =  log.((Vm_new)) .- reshape(Xss[indexes.VmSS],(n_par.nm,n_par.nk,n_par.ny))
    Vm_thet       = compress(compressionIndexes[1], Vm_err, DC,IDC, n_par)
    F[indexes.Vm] = X[indexes.Vm] .- Vm_thet

    Vk_err        =log.((Vk_new)) .- reshape(Xss[indexes.VkSS],(n_par.nm,n_par.nk,n_par.ny))
    Vk_thet       = compress(compressionIndexes[2], Vk_err, DC,IDC, n_par)
    F[indexes.Vk] = X[indexes.Vk] .- Vk_thet

    # Error Term on distribution (in levels, states)
    dPrime        = DirectTransition(m_a_star,  m_n_star, k_a_star,distr, m_par.λ, Π, n_par)
    dPrs          = reshape(dPrime,n_par.nm,n_par.nk,n_par.ny)
    temp          = dropdims(sum(dPrs,dims=(2,3)),dims=(2,3))
    cum_m         = cumsum(temp)
    F[indexes.distr_m] = temp[1:end-1] - distr_m_Prime[1:end-1]
    temp          = dropdims(sum(dPrs,dims=(1,3)),dims=(1,3))
    cum_k         = cumsum(temp)
    F[indexes.distr_k] = temp[1:end-1] - distr_k_Prime[1:end-1]
    temp          = distr_y'*Π# dropdims(sum(dPrs,dims=(1,2)),dims=(1,2))
    cum_h         = cumsum(temp')
    F[indexes.distr_y] = temp[1:end-1] - distr_y_Prime[1:end-1]

    cum_zero=zeros(eltype(θD),n_par.nm+1,n_par.nk+1, n_par.ny+1);
    cum_dist_new = cumsum(cumsum(cumsum(dPrs; dims=3);dims=2);dims=1)
    cum_zero[2:end,2:end,2:end]=cum_dist_new;
    Copula2(x::AbstractVector,y::AbstractVector,z::AbstractVector) = mylinearinterpolate3([0; cum_m],[0; cum_k],[0; cum_h],
    cum_zero, x, y, z)

    CDF_joint     = Copula2([0.0; cumsum(Xss[indexes.distr_m_SS])] .+ zeros(eltype(θD),n_par.nm+1),
    [0.0; cumsum(Xss[indexes.distr_k_SS])].+ zeros(eltype(θD),n_par.nk+1),
    [0.0; cumsum(Xss[indexes.distr_y_SS])] .+ zeros(eltype(θD),n_par.ny+1)) # roughly 5% of time

    distr_up         = diff(diff(diff(CDF_joint; dims=3);dims=2);dims=1)
    distr_err        =((distr_up)) .- reshape(Xss[indexes.DSS],(n_par.nm,n_par.nk,n_par.ny))

    D_thet       = compressD(compressionIndexes[3], distr_err[1:end-1,1:end-1,1:end-1], DCD,IDCD, n_par)
    F[indexes.D] =  D_thet .- XPrime[indexes.D]


    distr_m_act, distr_k_act, distr_y_act, share_borroweract, GiniWact, I90shareact, I90sharenetact, GiniXact, #=
        =# sdlogxact, P9010Cact, GiniCact, sdlgCact, P9010Iact, GiniIact, sdlogyact, w90shareact, P10Cact, P50Cact, P90Cact =
        distrSummaries(distr,c_a_star, c_n_star, n_par, inc, incgross, m_par)

    Htact                   = dot(distr_y[1:end-1],(n_par.grid_y[1:end-1]/H).^(tax_prog_scale))
    F[indexes.Ht]           = log.(Ht)          - log.(Htact)
    F[indexes.GiniX]        = log.(GiniX)       - log.(GiniXact)
    F[indexes.I90share]     = log.(I90share)    - log.(I90shareact);
    F[indexes.I90sharenet]  = log.(I90sharenet) - log.(I90sharenetact);

    F[indexes.w90share]     = log.(w90share)    - log.(w90shareact);
    F[indexes.sdlogy]       = log.(sdlogy)      - log.(sdlogyact)
    F[indexes.GiniC]        = log.(GiniC)       - log.(GiniCact)

    return F
end
