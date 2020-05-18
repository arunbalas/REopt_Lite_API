using JuMP
using JLD2
using FileIO
using Xpress
import MathOptInterface
const MOI = MathOptInterface
include("utils.jl")


function reopt()

    reo_model = direct_model(Xpress.Optimizer(OUTPUTLOG=1))

    p = load("./scenarios/tou_pv.jld2", "p")

    MAXTIME = 100000

    return reopt_run(reo_model, MAXTIME, p)
end

function reopt_scen(filepath)
	reo_model = direct_model(Xpress.Optimizer(OUTPUTLOG=1))

    p = load(filepath, "p")

    MAXTIME = 100000

    return reopt_run(reo_model, MAXTIME, p)
end

function reopt_all_scens()
	paths = [
				"./scenarios/pv.jld2",
				"./scenarios/pv_storage.jld2",
				"./scenarios/tiered_pv.jld2",
				"./scenarios/tiered_pv_storage.jld2",
				"./scenarios/tou_pv.jld2",
				"./scenarios/tou_pv_storage.jld2"
				]
	objs = []
	for path in paths
		results = reopt_scen(path)
		push!(objs,results["lcc"])
	end
	for i in 1:6
		println(paths[i])
		println(objs[i])
	end
	return objs
end

function reopt_run(reo_model, MAXTIME::Int64, p::Parameter)

	REopt = reo_model
    Obj = 1  # 1 for minimize LCC, 2 for min LCC AND high mean SOC
	
	
	### Big-M Adjustments (should provide faster solutions and help with numerical instability issues)
	NewMaxUsageInTier = Array{Float64,2}(undef,12, p.FuelBinCount)
	NewMaxDemandInTier = Array{Float64,2}(undef, length(p.Ratchets), p.DemandBinCount)
	NewMaxDemandMonthsInTier = Array{Float64,2}(undef,12, p.DemandMonthsBinCount)
	NewMaxSizeByHour = Array{Float64,2}(undef,length(p.Tech),p.TimeStepCount)

	# NewMaxDemandMonthsInTier sets a new minimum if the new peak demand for the month, minus the size of all previous bins, is less than the existing bin size.
	for n in p.DemandMonthsBin
		for m in p.Month 
			if n > 1
				NewMaxDemandMonthsInTier[m,n] = minimum([p.MaxDemandMonthsInTier[n], 
					p.MaxStorageSizeKW + maximum([p.LoadProfile["1R",ts] #+ LoadProfileChillerElectric[ts]
					for ts in p.TimeStepRatchetsMonth[m]])  - 
					sum(NewMaxDemandMonthsInTier[m,np] for np in 1:(n-1)) ]
				)
			else 
				NewMaxDemandMonthsInTier[m,n] = minimum([p.MaxDemandMonthsInTier[n], 
					p.MaxStorageSizeKW + maximum([p.LoadProfile["1R",ts] #+ LoadProfileChillerElectric[ts]
					for ts in p.TimeStepRatchetsMonth[m]])   ])
			end
		end
	end

	# NewMaxDemandInTier sets a new minimum if the new peak demand for the ratchet, minus the size of all previous bins for the ratchet, is less than the existing bin size.
	for e in p.DemandBin
		for r in p.Ratchets 
			if e > 1
				NewMaxDemandInTier[r,e] = minimum([p.MaxDemandInTier[e], 
				p.MaxStorageSizeKW + maximum([p.LoadProfile["1R",ts] #+ p.LoadProfileChillerElectric[ts]
					for ts in p.TimeStep])  - 
				sum(NewMaxDemandInTier[r,ep] for ep in 1:(e-1))
				])
			else
				NewMaxDemandInTier[r,e] = minimum([p.MaxDemandInTier[e], 
				p.MaxStorageSizeKW + maximum([p.LoadProfile["1R",ts] #+ p.LoadProfileChillerElectric[ts]
					for ts in p.TimeStep])  
				])
			end
		end
	end

	# NewMaxUsageInTier sets a new minumum if the total demand for the month, minus the size of all previous bins, is less than the existing bin size.
	for u in p.FuelBin
		for m in p.Month 
			if u > 1
				NewMaxUsageInTier[m,u] = minimum([p.MaxUsageInTier[u], 
					p.MaxStorageSizeKWH + sum(p.LoadProfile["1R",ts] #+ p.LoadProfileChillerElectric[ts]
					for ts in p.TimeStepRatchetsMonth[m]) - sum(NewMaxUsageInTier[m,up] for up in 1:(u-1))
				])
			else
				NewMaxUsageInTier[m,u] = minimum([p.MaxUsageInTier[u], 
					p.MaxStorageSizeKWH + sum(p.LoadProfile["1R",ts] #+ p.LoadProfileChillerElectric[ts]
					for ts in p.TimeStepRatchetsMonth[m]) 
				])
			end
		end
	end

	# NewMaxSizeByHour is designed to scale the right-hand side of the constraint limiting rated production in each hour to the production factor; in most cases this is unaffected unless the production factor is zero, in which case the right-hand side is set to zero.
	#for t in NonUtilTechs 
	#	for ts in p.TimeStep
	#		NewMaxSizeByHour[t,ts] = minimum([p.MaxSize[t],
	#			sum(p.ProdFactor[t,d,ts] for d in p.Load if p.LoadProfile[d,ts] > 0)  * p.MaxSize[t],
	#			sum(p.LoadProfile[d,ts] for d in ["1R"], ts in p.TimeStep)  
	#		])
	#	end
	#end

    @variables REopt begin
		# Continuous Variables
	    dvSystemSize[p.Tech, p.Seg] >= 0   #to be replaced
	    #dvSize[p.Tech] >= 0     #X^{\sigma}_{t}: System Size of Technology t [kW]   (NEW)
	    #dvSystemSizeSegment[p.Tech, p.Subdivision, p.Seg] >= 0   #X^{\sigma s}_{tks}: System size of technology t allocated to segmentation k, segment s [kW]  (NEW)
	    dvGrid[p.Load, p.TimeStep, p.DemandBin, p.FuelBin, p.DemandMonthsBin] >= 0  #to be replaced
	    #dvGridPurchase[p.PricingTier, p.TimeStep] >= 0   # X^{g}_{uh}: Power from grid dispatched to meet electrical load in demand tier u during time step h [kW]  (NEW)
	    dvRatedProd[p.Tech, p.Load, p.TimeStep, p.Seg, p.FuelBin] >= 0  #to be replaced
	    #dvRatedProduction[p.Tech, p.TimeStep] >= 0   #X^{rp}_{th}: Rated production of technology t during time step h [kW]  (NEW)
	    #dvProductionToGrid[p.Tech, p.PricingTier, p.TimeStep] >= 0  # X^{ptg}_{tuh}: Exports from electrical production to the grid by technology t in demand tier u during time step h [kW]   (NEW)
	    #dvStorageToGrid[p.PricingTier, p.TimeStep] >= 0  # X^{g}_{uh}: Exports from electrical storage to the grid in demand tier u during time step h [kW]  (NEW)
	    #dvProductionToStorage[p.Storage, p.Tech, p.TimeStep] >= 0  # X^{ptg}_{bth}: Power from technology t used to charge storage system b during time step h [kW]  (NEW)
	    #dvDischargeFromStorage[p.Storage, p.TimeStep] >= 0 # X^{pts}_{bh}: Power discharged from storage system b during time step h [kW]  (NEW)
	    #dvGridToStorage[p.TimeStep] >= 0 # X^{gts}_{h}: Electrical power delivered to storage by the grid in time step h [kW]  (NEW)
	    dvStoredEnergy[p.TimeStepBat] >= 0  # To be replaced
	    #dvStorageSOC[p.Storage, p.TimeStepBat] >= 0  # X^{se}_{bh}: State of charge of storage system b in time step h   (NEW)
	    dvStorageSizeKW >= 0        # to be removed
	    dvStorageSizeKWH >= 0       # to be removed
	    #dvStorageCapPower[p.Storage] >= 0   # X^{bkW}_b: Power capacity of storage system b [kW]  (NEW)
	    #dvStorageCapEnergy[p.Storage] >= 0   # X^{bkWh}_b: Energy capacity of storage system b [kWh]  (NEW)
	    dvProdIncent[p.Tech] >= 0   # X^{pi}_{t}: Production incentive collected for technology [$]
		dvPeakDemandE[p.Ratchets, p.DemandBin] >= 0  # X^{de}_{re}:  Peak electrical power demand allocated to tier e during ratchet r [kW]
		dvPeakDemandEMonth[p.Month, p.DemandMonthsBin] >= 0  #  X^{dn}_{mn}: Peak electrical power demand allocated to tier n during month m [kW]
		dvPeakDemandELookback >= 0  # X^{lp}: Peak electric demand look back [kW]
        MinChargeAdder >= 0   #to be removed
		UtilityMinChargeAdder[p.Month] >= 0   #X^{mc}_m: Annual utility minimum charge adder in month m [kW]
		#CHP and Fuel-burning variables
		#dvFuelUsage[p.Tech, p.TimeStep]  # Fuel burned by technology t in time step h
		#dvFuelBurnYIntercept[p.Tech, p.TimeStep]  #X^{fb}_{th}: Y-intercept of fuel burned by technology t in time step h
		#dvThermalProduction[p.Tech, p.TimeStep]  #X^{tp}_{th}: Thermal production by technology t in time step h
		#dvAbsorptionChillerDemand[p.TimeStep]  #X^{ac}_h: Thermal power consumption by absorption chiller in time step h
		#dvElectricChillerDemand[p.TimeStep]  #X^{ec}_h: Electrical power consumption by electric chiller in time step h
		
		# Binary Variables
        binNMLorIL[p.NMILRegime], Bin    # Z^{nmil}_{v}: 1 If generation is in net metering interconnect limit regime v; 0 otherwise
        binSegChosen[p.Tech, p.Seg], Bin  # to be replaced
		#binSegmentSelect[p.Tech, p.Subdivision, p.Seg] # Z^{\sigma s}_{tks} 1 if technology t, segmentation k is in segment s; 0 ow. (NEW)
        binProdIncent[p.Tech], Bin # 1 If production incentive is available for technology t; 0 otherwise 
        binSingleBasicTech[p.Tech,p.TechClass], Bin   #  Z^\text{sbt}_{tc}: 1 If technology t is used for technology class c; 0 otherwise
        binTechIsOnInTS[p.Tech, p.TimeStep], Bin  # 1 Z^{to}_{th}: If technology t is operating in time step h; 0 otherwise
		binDemandTier[p.Ratchets, p.DemandBin], Bin  # 1 If tier e has allocated demand during ratchet r; 0 otherwise
        binDemandMonthsTier[p.Month, p.DemandMonthsBin], Bin # 1 If tier n has allocated demand during month m; 0 otherwise
        binUsageTier[p.Month, p.FuelBin], Bin    #  to be replaced
		#binEnergyTier[p.Month, p.PricingTier], Bin    #  Z^{ut}_{mu} 1 If demand tier $u$ is active in month m; 0 otherwise (NEW)
			
        dvElecToStor[p.Tech, p.TimeStep] >= 0  #to be removed
        dvElecFromStor[p.TimeStep] >= 0        #to be removed
        dvMeanSOC >= 0  # to be removed 
        dvFuelCost[p.Tech, p.FuelBin]   #to be removed
        dvFuelUsed[p.Tech, p.FuelBin]   #to be removed

    # ADDED due to implied types
        ElecToBatt[p.Tech] >= 0    # to be removed
        UsageInTier[p.Month, p.FuelBin] >= 0   # to be removed
        #TotalTechCapCosts >= 0
        #TotalStorageCapCosts >= 0
        #TotalEnergyCharges >= 0
        #DemandTOUCharges >= 0
        #DemandFlatCharges >= 0
        #TotalDemandCharges >= 0
        #TotalFixedCharges >= 0
        #TotalEnergyExports <= 0
        #TotalProductionIncentive >= 0
        #TotalMinCharge >= 0

    # ADDED due to calculations
        #Year1ElecProd
        #AverageElecProd
        #Year1WindProd
        #AverageWindProd

    # ADDED for modeling
        binMinTurndown[p.Tech, p.TimeStep], Bin   # to be removed
    end
	
	
	
	##############################################################################
	#############  		Constraints									 #############
	##############################################################################
    #TODO: account for exist formatting
    for t in p.Tech
        if p.MaxSize == 0
            for LD in p.Load
                if p.TechToLoadMatrix[t,LD] == 0
                    for ts in p.TimeStep
                        if p.LoadProfile[LD,ts] == 0
                            for s in p.Seg, fb in p.FuelBin
                            fix(dvRatedProd[t, LD, ts, s, fb], 0, force=true)
                            end
                        end
                    end
                end
            end
        end
    end
	
	for LD in ["1W","1X"]
		for ts in p.TimeStep
			for s in p.Seg
				for fb in p.FuelBin
					fix(dvRatedProd["UTIL1", LD, ts, s, fb], 0, force=true)
				end
			end
		end
	end
	

    ## Fuel Tracking Constraints
    @constraint(REopt, [t in p.Tech, fb in p.FuelBin],
                sum(p.ProdFactor[t,LD,ts] * p.LevelizationFactor[t] * dvRatedProd[t,LD,ts,s,fb] * p.FuelBurnRateM[t,LD,fb] * p.TimeStepScaling
                    for ts in p.TimeStep, LD in p.Load, s in p.Seg) +
                sum(binTechIsOnInTS[t,ts] * p.FuelBurnRateB[t,LD,fb] * p.TimeStepScaling
                    for ts in p.TimeStep, LD in p.Load) == dvFuelUsed[t,fb])
    @constraint(REopt, FuelCont[t in p.Tech, fb in p.FuelBin],
                dvFuelUsed[t,fb] <= p.FuelAvail[t,fb])
    @constraint(REopt, [t in p.Tech, fb in p.FuelBin],
                sum(p.ProdFactor[t, LD, ts] * p.LevelizationFactor[t] * dvRatedProd[t,LD,ts,s,fb] * p.FuelBurnRateM[t,LD,fb] * p.TimeStepScaling * p.FuelRate[t,fb,ts] * p.pwf_e
                    for ts in p.TimeStep, LD in p.Load, s in p.Seg) +
                sum(binTechIsOnInTS[t,ts] * p.FuelBurnRateB[t,LD,fb] * p.TimeStepScaling * p.FuelRate[t,fb,ts] * p.pwf_e
                    for ts in p.TimeStep, LD in p.Load) == dvFuelCost[t,fb])
					
	##Constraint (1a): Sum of fuel used must not exceed prespecified limits
	#@constraint(REopt, [f in p.FuelType],
	#			sum( dvFuelUsage[t,ts] for t in p.TechsByFuelType[f], ts in p.TimeStep ) <= 
	#			p.FuelAvail[f]
	#			)
	#
	## Constraint (1b): Fuel burn for non-CHP Constraints
	#@constraint(REopt, [t in p.Tech, ts in p.TimeStep],
	#			dvFuelUsage[t,ts]  <= (FuelBurnRateM[t] * ProductionFactor[t,ts] * dvRatedProduction[t,ts]) + 
	#				(FuelBurnRateB[t] * binTechIsOnInTS[t,ts])
	#			)
	#Skipping (1c)-(1f) until CHP implementation
	
	### Thermal Production Constraints (Placeholder for constraint set (2) until CHP is implemented)

    ### Switch Constraints
    @constraint(REopt, [t in p.Tech, ts in p.TimeStep],
                sum(p.ProdFactor[t,LD,ts] * dvRatedProd[t,LD,ts,s,fb] for LD in p.Load, s in p.Seg, fb in p.FuelBin) <=
                p.MaxSize[t] * 100 * binTechIsOnInTS[t,ts])
    @constraint(REopt, [t in p.Tech, ts in p.TimeStep],
                sum(p.MinTurndown[t] * dvSystemSize[t,s] for s in p.Seg) -
      		    sum(dvRatedProd[t,LD,ts,s,fb] for LD in p.Load, s in p.Seg, fb in p.FuelBin) <=
                p.MaxSize[t] * (1 - binTechIsOnInTS[t, ts]))
	
	### Section 3: New Switch Constraints
	##Constraint (3a): Technology must be on for nonnegative output (fuel-burning only)
	#@constraint(REopt, [t in p.Tech, ts in p.TimeStep],
	#			dvRatedProduction[t,ts] <= MaxSize[t] * binTechIsOnInTS[t,ts])
	##Constraint (3b): Technologies that are turned on must not be turned down
	#@constraint(REopt, [t in p.Tech, ts in p.TimeStep],
	#		MaxSize[t] * (1-binTechIsOnInTS[t,ts]))	- dvRatedProduction[t,ts] >= MinTurndown[t] * dvSystemSize[t]

    ### Section 4: Storage System Constraints
	### 
	### Boundary Conditions and Size Limits
    @constraint(REopt, dvStoredEnergy[0] == p.InitSOC * dvStorageSizeKWH )
    @constraint(REopt, p.MinStorageSizeKWH <= dvStorageSizeKWH)
    @constraint(REopt, dvStorageSizeKWH <=  p.MaxStorageSizeKWH)
    @constraint(REopt, p.MinStorageSizeKW <= dvStorageSizeKW)
    @constraint(REopt, dvStorageSizeKW <=  p.MaxStorageSizeKW)
	
	### New Boundary Conditions and Size Limits
	## Constraint (4a): Reconcile initial state of charge for storage systems
	#@constraint(REopt, [b in p.Storage], dvStorageSOC[b] = StorageInitSOC[b,0] * dvStorageCapEnergy[b])
	## Constraint (4b)-1: Lower bound on Storage Energy Capacity
	#@constraint(REopt, [b in p.Storage], dvStorageCapEnergy[b] >= p.StorageMinSizeEnergy)
	## Constraint (4b)-2: Upper bound on Storage Energy Capacity
	#@constraint(REopt, [b in p.Storage], dvStorageCapEnergy[b] <= p.StorageMaxSizeEnergy)
	## Constraint (4c)-1: Lower bound on Storage Power Capacity
	#@constraint(REopt, [b in p.Storage], dvStorageCapPower[b] >= p.StorageMinSizePower)
	## Constraint (4c)-2: Upper bound on Storage Power Capacity
	#@constraint(REopt, [b in p.Storage], dvStorageCapPower[b] <= p.StorageMaxSizePower)
	
    ### Battery Operations
    # AC electricity to be stored, generated by each Tech, applied to the storage load, for each timestep
    @constraint(REopt, [t in p.Tech, ts in p.TimeStep],
    	        dvElecToStor[t,ts] == sum(p.ProdFactor[t,"1S",ts] * p.LevelizationFactor[t] * dvRatedProd[t,"1S",ts,s,fb]
                                        for s in p.Seg, fb in p.FuelBin))
    @constraint(REopt, [ts in p.TimeStep],
    	        dvStoredEnergy[ts] == dvStoredEnergy[ts-1] + sum(dvElecToStor[t,ts] * p.EtaStorIn[t,"1S"] for t in p.Tech) - dvElecFromStor[ts] / p.EtaStorOut["1S"])
    @constraint(REopt, [ts in p.TimeStep],
    	        p.TimeStepScaling * dvElecFromStor[ts] / p.EtaStorOut["1S"] <=  dvStoredEnergy[ts-1])
    @constraint(REopt, [ts in p.TimeStep],
    	        dvStoredEnergy[ts] >=  p.StorageMinChargePcent * dvStorageSizeKWH)

	### New Storage Operations
	# Constraint (4d): Electrical production sent to storage or grid must be less than technology's rated production
	#@constraint(REopt, [b in p.ElecStorage, t in ElectricTechs, ts in p.TimeStep],
    #	        dvProductionToStorage[b,t,ts] + dvProductionToGrid[t,ts] <= 
	#			ProductionFactor[t,ts] * LevelizationFactor[t] * dvRatedProduction[t,ts]
	#			)
	# Constraint (4e)-1: (Hot) Thermal production sent to storage or grid must be less than technology's rated production
	#@constraint(REopt, [b in p.HotTES, t in HeatingTechs, ts in p.TimeStep],
    #	        dvProductionToStorage[b,t,ts]  <= 
	#			ProductionFactor[t,ts] * dvThermalProduction[t,ts]
	#			)
	# Constraint (4e)-2: (Cold) Thermal production sent to storage or grid must be less than technology's rated production
	#@constraint(REopt, [b in p.ColdTES, t in CoolingTechs, ts in p.TimeStep],
    #	        dvProductionToStorage[b,t,ts]  <= 
	#			ProductionFactor[t,ts] * dvThermalProduction[t,ts]
	#			)
	# Constraint (4f): Reconcile state-of-charge for electrical storage
	#@constraint(REopt, [b in p.ElecStorage, ts in p.TimeStep],
    #	        dvStorageSOC[b,ts] = dvStorageSOC[b,ts-1] + p.TimeStepScaling * (  
	#				sum(ChargeEfficiency[b,t] * dvProductionToStorage[b,t,ts] for t in p.ElecTechs) + 
	#				GridChargeEfficiency*dvGridToStorage[ts] - dvDischargeFromStorage[b,ts]/DischargeEfficiency[b]
	#				)
	#			)
	
	# Constraint (4g)-1: Reconcile state-of-charge for (hot) thermal storage
	#@constraint(REopt, [b in p.HotTES, ts in p.TimeStep],
    #	        dvStorageSOC[b,ts] = dvStorageSOC[b,ts-1] + p.TimeStepScaling * (  
	#				sum(ChargeEfficiency[b,t] * dvProductionToStorage[b,t,ts] for t in p.HeatingTechs) - 
	#				dvDischargeFromStorage[b,ts]/DischargeEfficiency[b]
	#				)
	#			)
				
	# Constraint (4g)-2: Reconcile state-of-charge for (cold) thermal storage
	#@constraint(REopt, [b in p.ColdTES, ts in p.TimeStep],
    #	        dvStorageSOC[b,ts] = dvStorageSOC[b,ts-1] + p.TimeStepScaling * (  
	#				sum(ChargeEfficiency[b,t] * dvProductionToStorage[b,t,ts] for t in p.CoolingTechs) - 
	#				dvDischargeFromStorage[b,ts]/DischargeEfficiency[b]
	#				)
	#			)
	
	# Constraint (4h): Minimum state of charge
	#@constraint(REopt, [b in p.Storage, ts in p.TimeStep],
    #	        dvStorageSOC[b,ts] >= StorageMinSOC[b] * dvStorageCapEnergy[b]
	#				)
	#			)
	#
				
				
    ### Operational Nuance
    # Storage inverter is AC rated. Following constrains the energy / timestep throughput of the inverter
    #     to the sum of the energy in and energy out of the battery.
    @constraint(REopt, [ts in p.TimeStep],
    	        dvStorageSizeKW >=  dvElecFromStor[ts] + sum(dvElecToStor[t,ts] for t in p.Tech))
    @constraint(REopt, dvMeanSOC == sum(dvStoredEnergy[ts] for ts in p.TimeStep) / p.TimeStepCount)
    @constraint(REopt, [ts in p.TimeStep],
    	        dvStorageSizeKWH >=  dvStoredEnergy[ts])
    @constraint(REopt, [t in p.Tech],
    	        ElecToBatt[t] == sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t,LD,ts] * p.LevelizationFactor[t]
                                     for ts in p.TimeStep, LD in ["1S"], s in p.Seg, fb in p.FuelBin))

    #New operational nuance
	#Constraint (4i)-1: Dispatch to hot storage is no greater than power capacity
	#@constraint(REopt, [b in p.HotTES, ts in p.TimeStep],
    #	        dvStorageCapPower[b] >= (  
	#				sum(ChargeEfficiency[b,t] * dvProductionToStorage[b,t,ts] for t in p.HeatingTechs)
	#				)
	#			)
	
	#Constraint (4i)-2: Dispatch to cold storage is no greater than power capacity
	#@constraint(REopt, [b in p.ColdTES, ts in p.TimeStep],
    #	        dvStorageCapPower[b] >= (  
	#				sum(ChargeEfficiency[b,t] * dvProductionToStorage[b,t,ts] for t in p.CoolingTechs)
	#				)
	#			)
	
	#Constraint (4j): Dispatch from storage is no greater than power capacity
	#@constraint(REopt, [b in p.ColdTES, ts in p.TimeStep],
    #	        dvStorageCapPower[b] >= dvDischargeFromStorage[b,ts]
	#			)
	
	#Constraint (4k): State of charge is no greater than energy capacity
	#@constraint(REopt, [b in p.Storage, ts in p.TimeStep],
    #	        dvStorageSOC[b,ts] >= StorageMinSOC[b] * dvStorageCapEnergy[b]
	#				)
	#			)
	#
	
	### Constraint set (5) - hot and cold thermal loads - reserved for later
	
	
	### Binary Bookkeeping
    @constraint(REopt, [t in p.Tech],
                sum(binSegChosen[t,s] for s in p.Seg) == 1)
    @constraint(REopt, [b in p.TechClass],
                sum(binSingleBasicTech[t,b] for t in p.Tech) <= 1)


    ### Capital Cost Constraints (NEED Had to modify b/c AxisArrays doesn't do well with range 0:20
    @constraint(REopt, [t in p.Tech, s in p.Seg],
                dvSystemSize[t,s] <= p.CapCostX[t,s+1] * binSegChosen[t,s])
    @constraint(REopt, [t in p.Tech, s in p.Seg],
                dvSystemSize[t,s] >= p.CapCostX[t,s] * binSegChosen[t,s])

    ### Production Incentive Cap Module
    @constraint(REopt, [t in p.Tech],
                dvProdIncent[t] <= binProdIncent[t] * p.MaxProdIncent[t] * p.pwf_prod_incent[t])
    @constraint(REopt, [t in p.Tech],
                dvProdIncent[t] <= sum(p.ProdFactor[t, LD, ts] * p.LevelizationFactorProdIncent[t] * dvRatedProd[t,LD,ts,s,fb] *
                                       p.TimeStepScaling * p.ProdIncentRate[t, LD] * p.pwf_prod_incent[t]
                                       for LD in p.Load, ts in p.TimeStep, s in p.Seg, fb in p.FuelBin))
    @constraint(REopt, [t in p.Tech, LD in p.Load,ts in p.TimeStep],
                sum(dvSystemSize[t,s] for s in p.Seg) <= p.MaxSizeForProdIncent[t] + p.MaxSize[t] * (1 - binProdIncent[t]))


	### Constraint set 6: Production Incentive Cap
	##Constraint (6a)-1: Production Incentive Upper Bound (unchanged)
	#@constraint(REopt, [t in p.Tech],
    #            dvProdIncent[t] <= binProdIncent[t] * p.MaxProdIncent[t] * p.pwf_prod_incent[t])
	##Constraint (6a)-2: Production Incentive According to Production (updated)
	#@constraint(REopt, [t in p.Tech],
    #            dvProdIncent[t] <= sum(p.ProductionFactor[t, ts] *  p.TimeStepScaling * p.ProdIncentRate[t]  * p.LevelizationFactorProdIncent[t] * dvRatedProduction[t,ts] for ts in p.TimeStep)
    #            )
	##Constraint (6b): System size max to achieve production incentive
	#@constraint(REopt, [t in p.Tech],
    #            dvSize[t]  <= p.MaxSizeForProdIncent[t] + p.MaxSize[t] * (1 - binProdIncent[t]))

    ### System Size and Production Constraints
    @constraint(REopt, [t in p.Tech, s in p.Seg],
                dvSystemSize[t,s] <=  p.MaxSize[t])
    @constraint(REopt, [b in p.TechClass],
                sum(dvSystemSize[t, s] * p.TechToTechClassMatrix[t,b] for t in p.Tech, s in p.Seg) >= p.TechClassMinSize[b])
    #NEED to tighten bound and check logic
	
	###Constraint set (7): System Size is zero unless single basic tech is selected for class
	#Constraint (7a): Single Basic Technology Constraints
	#@constraint(REopt, [c in p.TechClass, t in p.TechsInClass[c]],
	#	dvSize[t] <= p.MaxSize[t] * binSingleBasicTech[t,c]
	#	)
	##Constraint (7b): At most one Single Basic Technology per Class
	#@constraint(REopt, [c in p.TechClass],
	#	sum( binSingleBasicTech[t,c] for t in p.TechsInClass[c] ) <= 1
	#	)
	
	##Constraint (7c): Minimum size for each tech class
	#@constraint(REopt, [c in p.TechClass],
	#	sum( dvSize[t] for t in in p.TechsInClass[c] ) >= p.TechClassMinSize[c]
	#	)
	
	## Constraint (7d): Non-turndown technologies are always at rated production
	#@constraint(REopt, [t in p.TechsNoTurndown, ts in p.TimeStep],
	#	dvRatedProduction[t,ts] == dvSize[t]  
	#)
	#	
	
	##Constraint (7e): Derate factor limits production variable (separate from ProdFactor)
	#@constraint(REopt, [t in p.TechsTurndown, ts in p.TimeStep],
	#	dvRatedProduction[t,ts]  <= p.TurbineDerate[t,ts] * dvSize[t]
	#)
	#	
	
	##Constraint (7f)-1: Minimum segment size
	#@constraint(REopt, [t in p.Techs, k in p.Subdivisions, s in p.SegByTechSubdivision[t,k]],
	#	dvSystemSizeSegment[t,k,s]  >= p.SegmentMinSize[t,ts] * binSegChosen[t,k,s]
	#)
	#	
	
	##Constraint (7f)-2: Maximum segment size
	#@constraint(REopt, [t in p.Techs, k in p.Subdivisions, s in p.SegByTechSubdivision[t,k]],
	#	dvSystemSizeSegment[t,k,s]  <= p.SegmentMaxSize[t,ts] * binSegChosen[t,k,s]
	#)
	#	

	##Constraint (7g):  Segments add up to system size 
	#@constraint(REopt, [t in p.Techs, k in p.Subdivisions],
	#	sum(dvSystemSizeSegment[t,k,s] for s in p.SegByTechSubdivision[t,k])  == dvSize[t]
	#)
	#	
	
	##Constraint (7h): At most one segment allowed
	#@constraint(REopt, [t in p.Techs, k in p.Subdivisions],
	#	sum(binSegChosen[t,k,s] for s in p.SegByTechSubdivision[t,k])  <= 1
	#)
	#	
 
	### Constraint set (8): Electrical Load Balancing and Grid Sales
	
	##Constraint (8a): Electrical Load Balancing
	#@constraint(REopt, [ts in p.TimeStep],
	#	sum(p.ProductionFactor[t,ts] * p.LevelizationFactor[t] * dvRatedProduction[t,ts] for t in p.ElectricTechs) +  
	#sum( dvDischargeFromStorage[b] for b in p.ElecStorage ) + 
	#sum( dvGridPurchase[u,ts] for u in p.PricingTier ) ==
	#sum( sum(dvProductionToStorage[b,t,ts] for b in p.ElecStorage) + 
		#sum(dvProductionToGrid[t,u,ts] for b in p.ElecStorage) for t in p.ElectricTechs) +
	#sum(dvStorageToGrid[u,ts] for u in p.PricingTier) + dvGridToStorage[ts] + 
	## sum(dvThermalProduction[t,ts] for t in p.CoolingTechs )/ p.ElectricChillerEfficiency +
	#p.ElecLoad[ts]
	#)
	
	##Constraint (8b): Grid-to-storage no greater than grid purchases 
	#@constraint(REopt, [ts in p.TimeStep],
	#	sum( dvGridPurchase[u,ts] for u in p.PricingTier)  >= dvGridToStorage[ts]
	#)
	#	
	
	##Constraint (8c): Storage-to-grid no greater than discharge from Storatge
	#@constraint(REopt, [ts in p.TimeStep],
	#	sum( dvDischargeFromStorage[b,ts] for u in p.ElecStorage)  >= sum(dvStorageToGrid[u,ts] for u in p.PricingTier)
	#)
	#	
	
	
	##Constraint (8d): Production-to-grid no greater than production
	#@constraint(REopt, [t in p.Tech, ts in p.TimeStep],
	# p.ProductionFactor[t,ts] * p.LevelizationFactor[t] * dvRatedProduction[t,ts] >= sum(dvProductionToGrid[t,u,ts] for u in p.PricingTier)
	#)
	
	##Constraint (8e): Total sales to grid no greater than annual allocation
	#@constraint(REopt, [u in p.PricingTier],
	# sum( dvStorageToGrid[u,ts] +  sum(dvProductionToGrid[t,u,ts] for t in p.TechsByPricingTier[u]) for ts in p.TimeStep) <= MaxGridSales[u]
	#)
	## End constraint (8)
	
    for t in p.Tech
        if p.MinTurndown[t] > 0
            @constraint(REopt, [LD in p.Load, ts in p.TimeStep, s in p.Seg, fb in p.FuelBin],
                        binMinTurndown[t,ts] * p.MinTurndown[t] <= dvRatedProd[t,LD,ts,s,fb])
            @constraint(REopt, [LD in p.Load, ts in p.TimeStep, s in p.Seg, fb in p.FuelBin],
                        dvRatedProd[t,LD,ts,s,fb] <= binMinTurndown[t,ts] * p.AnnualElecLoad)
        end
    end

    @constraint(REopt, [t in p.Tech, s in p.Seg, ts in p.TimeStep],
                sum(dvRatedProd[t,LD,ts,s,fb] for LD in p.Load, fb in p.FuelBin) <= dvSystemSize[t, s])


    for LD in p.Load
        if LD != "1R" && LD != "1S"
            @constraint(REopt, [ts in p.TimeStep],
                        sum(p.ProdFactor[t,LD,ts] * p.LevelizationFactor[t] * dvRatedProd[t,LD,ts,s,fb]
                            for t in p.Tech, s in p.Seg, fb in p.FuelBin) <= p.LoadProfile[LD,ts])
        end
    end

    @constraint(REopt, [LD in ["1R"], ts in p.TimeStep],
                sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t,LD,ts] * p.LevelizationFactor[t]
                    for t in p.Tech, s in p.Seg, fb in p.FuelBin) + dvElecFromStor[ts] >= p.LoadProfile[LD,ts])

    ### Constraint set (9): Net Meter Module (copied directly from legacy model)
	#Constraint (9a): exactly one net-metering regime must be selected
    @constraint(REopt, sum(binNMLorIL[n] for n in p.NMILRegime) == 1)
	
	##Constraint (9b): Maximum system sizes for each net-metering regime
	#@constraint(REopt, [n in p.NMILRegime],
    #            sum(p.TurbineDerate[t] * dvSize[t]
    #                for t in p.TechsByNMILRegime[n]) <= p.NMILLimits[n] * binNMLorIL[n])
	###End constraint set (9)
	
	##Previous analog to (9b)
    @constraint(REopt, [n in p.NMILRegime],
                sum(p.TechToNMILMapping[t,n] * p.TurbineDerate[t] * dvSystemSize[t,s]
                    for t in p.Tech, s in p.Seg) <= p.NMILLimits[n] * binNMLorIL[n])

    ###  Rate Variable Definitions
    @constraint(REopt, [t in ["UTIL1"], LD in p.Load, fb in p.FuelBin, ts in p.TimeStep],
    	        sum(dvRatedProd[t,LD,ts,s,fb] for s in p.Seg) == sum(dvGrid[LD,ts,db,fb,dbm] for db in p.DemandBin, dbm in p.DemandMonthsBin))
    @constraint(REopt, [t in ["UTIL1"], fb in p.FuelBin, m in p.Month],
    	        UsageInTier[m, fb] ==  sum(dvRatedProd[t,LD,ts,s,fb] * p.TimeStepScaling for LD in p.Load, ts in p.TimeStepRatchetsMonth[m], s in p.Seg))

    ### Fuel Bins
    @constraint(REopt, [fb in p.FuelBin, m in p.Month],
                UsageInTier[m, fb] <= binUsageTier[m, fb] * NewMaxUsageInTier[m,fb])
    @constraint(REopt, [fb in 2:p.FuelBinCount, m in p.Month],
    	        binUsageTier[m, fb] - binUsageTier[m, fb-1] <= 0)
    @constraint(REopt, [fb in 2:p.FuelBinCount, m in p.Month],
    	        binUsageTier[m, fb] * NewMaxUsageInTier[m,fb-1] - UsageInTier[m, fb-1] <= 0)
				

    ### Peak Demand Energy Rates
    for db in p.DemandBin
        @constraint(REopt, [r in p.Ratchets],
                    dvPeakDemandE[r, db] <= binDemandTier[r,db] * NewMaxDemandInTier[r,db])
        if db >= 2
            @constraint(REopt, [r in p.Ratchets],
                        binDemandTier[r, db] - binDemandTier[r, db-1] <= 0)
            @constraint(REopt, [r in p.Ratchets],
                        binDemandTier[r, db] * NewMaxDemandInTier[r,db-1] - dvPeakDemandE[r, db-1] <= 0)
        end
    end
	### Constraint set (11): Peak Electrical Power Demand Charges: Months
	
	## Constraint (11a): Upper bound on peak electrical power demand by tier, by month, if tier is selected (0 o.w.)
	#@constraint(REopt, [n in p.DemandMonthsBin, m in p.Month],
    #            dvPeakDemandEMonth[m,n] <= NewMaxDemandMonthsInTier[m,n] * binDemandMonthsTier[m,n])
	
	## Constraint (11b): Monthly peak electrical power demand tier ordering
	@constraint(REopt, [m in p.Month, n in 2:p.DemandMonthsBinCount],
        	        binDemandMonthsTier[m, n] <= binDemandMonthsTier[m, n-1])
	
	## Constraint (11c): One monthly peak electrical power demand tier must be full before next one is active
	#@constraint(REopt, [m in p.Month, n in 2:p.DemandMonthsBinCount],
    #    	 binDemandMonthsTier[m, n] * NewMaxDemandMonthsInTier[m,n-1] <= dvPeakDemandEMonth[m, n-1])
	
	## Constraint (11d): Monthly peak demand is >= demand at each hour in the month` 
	#@constraint(REopt, [m in p.Month, ts in p.TimeStepRatchetsMonth[m]],
    #    	 sum( dvPeakDemandEMonth for n in p.DemandMonthsBin ) >= 
	#		 sum( dvGridPurchase[u,ts] for u in p.PricingTiers )
	#)
	
	### End Constraint Set (11)
	
	### Constraint set (12): Peak Electrical Power Demand Charges: Ratchets
	#if !isempty(p.TimeStepRatchets)
		## Constraint (12a): Upper bound on peak electrical power demand by tier, by ratchet, if tier is selected (0 o.w.)
		#@constraint(REopt, [r in p.Ratchets, e in p.DemandBin],
		#            dvPeakDemandE[r, e] <= p.MaxDemandInTier[e] * binDemandTier[r, e])
		
		## Constraint (12b): Ratchet peak electrical power ratchet tier ordering
		#@constraint(REopt, [r in p.Ratchets, e in 2:p.DemandBinCount],
		#    	        binDemandTier[r, e] <= binDemandTier[r, e-1])
		
		## Constraint (12c): One ratchet peak electrical power demand tier must be full before next one is active
		#@constraint(REopt, [r in p.Ratchets, e in 2:p.DemandBinCount],
		#    	 binDemandTier[r, e] * p.MaxDemandInTier[e-1] <= dvPeakDemandE[r, e-1])
		
		## Constraint (12d): Ratchet peak demand is >= demand at each hour in the ratchet` 
		#@constraint(REopt, [r in p.Ratchets, e in 2:p.DemandBinCount],
		#    	 sum( dvPeakDemandE[r, e] for e in p.DemandBin ) >= 
		#		 sum( dvGridPurchase[u, h] for u in p.PricingTiers )
		#)
		
		##Constraint (12e): Peak demand used in percent lookback calculation 
		#@constraint(REopt, [m in p.DemandLookbackMonths],
		#	        dvPeakDemandELookback >= sum(dvPeakDemandEMonth[m, n] for n in p.DemandMonthsBin)
		
		##Constraint (12f): Ratchet peak demand charge is bounded below by lookback
		#@constraint(REopt, [r in p.Ratchets],
		#			sum( dvPeakDemandEMonth[r,e] for e in p.DemandBin ) >= 
		#			p.DemandLookbackPercent * dvPeakDemandELookback )
	#end
	### End Constraint Set (12)

    if !isempty(p.TimeStepRatchets)
        @constraint(REopt, [db in p.DemandBin, r in p.Ratchets, ts in p.TimeStepRatchets[r]],
                    dvPeakDemandE[r,db] >= sum(dvGrid[LD,ts,db,fb,dbm] for LD in p.Load, fb in p.FuelBin, dbm in p.DemandMonthsBin))
        @constraint(REopt, [db in p.DemandBin, r in p.Ratchets, ts in p.TimeStepRatchets[r]],
                    dvPeakDemandE[r,db] >= p.DemandLookbackPercent * dvPeakDemandELookback)
    end

    ### Peak Demand Energy Ratchets
    for dbm in p.DemandMonthsBin
        @constraint(REopt, [m in p.Month],
        	        dvPeakDemandEMonth[m, dbm] <= binDemandMonthsTier[m,dbm] * NewMaxDemandMonthsInTier[m,dbm])
        if dbm >= 2
        @constraint(REopt, [m in p.Month],
        	        binDemandMonthsTier[m, dbm] - binDemandMonthsTier[m, dbm-1] <= 0)
        @constraint(REopt, [m in p.Month],
        	        binDemandMonthsTier[m, dbm] * NewMaxDemandMonthsInTier[m,dbm-1] <= dvPeakDemandEMonth[m, dbm-1])
        end
    end
    @constraint(REopt, [dbm in p.DemandMonthsBin, m in p.Month, ts in p.TimeStepRatchetsMonth[m]],
    	        dvPeakDemandEMonth[m, dbm] >=  sum(dvGrid[LD,ts,db,fb,dbm] for LD in p.Load, db in p.DemandBin, fb in p.FuelBin))
    @constraint(REopt, [LD in p.Load, lbm in p.DemandLookbackMonths],
                dvPeakDemandELookback >= sum(dvPeakDemandEMonth[lbm, dbm] for dbm in p.DemandMonthsBin))

    #= Annual energy produced by Tech's' (except UTIL) used to meet the 1R, 1W, and 1S loads must
    be less than the annual site load (in kWh) =#
    TechIsNotGridSet = filter(t->p.TechIsGrid[t] == 0, p.Tech)
    @constraint(REopt, sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.LevelizationFactor[t] *  p.TimeStepScaling
                           for t in TechIsNotGridSet, LD in ["1R", "1W", "1S"],
                           ts in p.TimeStep, s in p.Seg, fb in p.FuelBin) <=  p.AnnualElecLoad)

    ###
    #Added, but has awful bounds
    @constraint(REopt, [t in p.Tech, b in p.TechClass],
                sum(dvSystemSize[t, s] * p.TechToTechClassMatrix[t, b] for s in p.Seg) <= p.MaxSize[t] * binSingleBasicTech[t, b])

    for t in p.Tech
        if p.TechToTechClassMatrix[t, "PV"] == 1 || p.TechToTechClassMatrix[t, "WIND"] == 1
            @constraint(REopt, [ts in p.TimeStep, s in p.Seg],
            	        sum(dvRatedProd[t,LD,ts,s,fb] for fb in p.FuelBin,
                            LD in ["1R", "1W", "1X", "1S"]) ==  dvSystemSize[t, s])
        end
    end


    ### Parts of Objective

    ProdLoad = ["1R", "1W", "1X", "1S"]

    PVTechs = filter(t->p.TechToTechClassMatrix[t, "PV"] == 1, p.Tech)
    @expression(REopt, Year1PvProd, sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.TimeStepScaling
                                            for t in PVTechs, s in p.Seg, fb in p.FuelBin, ts in p.TimeStep, LD in ProdLoad))
    @expression(REopt, AveragePvProd, sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.TimeStepScaling * p.LevelizationFactor[t]
                                              for t in PVTechs, s in p.Seg, fb in p.FuelBin, ts in p.TimeStep, LD in ProdLoad))

    WindTechs = filter(t->p.TechToTechClassMatrix[t, "WIND"] == 1, p.Tech)
    @expression(REopt, Year1WindProd, sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.TimeStepScaling
                                            for t in WindTechs, s in p.Seg, fb in p.FuelBin, ts in p.TimeStep, LD in ProdLoad))
    @expression(REopt, AverageWindProd, sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.TimeStepScaling * p.LevelizationFactor[t]
                                              for t in WindTechs, s in p.Seg, fb in p.FuelBin, ts in p.TimeStep, LD in ProdLoad))

    GeneratorTechs = filter(t->p.TechToTechClassMatrix[t, "GENERATOR"] == 1, p.Tech)
    @expression(REopt, Year1GenProd, sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.TimeStepScaling
                       for t in GeneratorTechs, s in p.Seg, fb in p.FuelBin, ts in p.TimeStep, LD in ProdLoad))
    @expression(REopt, AverageGenProd, sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.TimeStepScaling * p.LevelizationFactor[t]
                       for t in GeneratorTechs, s in p.Seg, fb in p.FuelBin, ts in p.TimeStep, LD in ProdLoad))

    @expression(REopt, TotalTechCapCosts, sum(p.CapCostSlope[t, s] * dvSystemSize[t, s] + p.CapCostYInt[t,s] * binSegChosen[t,s]
                                                for t in p.Tech, s in p.Seg))
    @expression(REopt, TotalStorageCapCosts, dvStorageSizeKWH * p.StorageCostPerKWH + dvStorageSizeKW * p.StorageCostPerKW)
    @expression(REopt, TotalPerUnitSizeOMCosts, sum(p.OMperUnitSize[t] * p.pwf_om * dvSystemSize[t, s] for t in p.Tech, s in p.Seg))

    if !isempty(GeneratorTechs)
        @expression(REopt, TotalPerUnitProdOMCosts, sum(dvRatedProd[t,LD,ts,s,fb] * p.TimeStepScaling * p.ProdFactor[t,LD,ts] * p.OMcostPerUnitProd[t] * p.pwf_om
                                                    for t in GeneratorTechs, LD in p.Load, ts in p.TimeStep, s in p.Seg, fb in p.FuelBin))
    else
        @expression(REopt, TotalPerUnitProdOMCosts, 0.0)
    end

    @expression(REopt, GenPerUnitSizeOMCosts, sum(p.OMperUnitSize[t] * p.pwf_om * dvSystemSize[t, s] for t in GeneratorTechs, s in p.Seg))
    @expression(REopt, GenPerUnitProdOMCosts, sum(dvRatedProd[t,LD,ts,s,fb] * p.TimeStepScaling * p.ProdFactor[t,LD,ts] * p.OMcostPerUnitProd[t] * p.pwf_om
                                              for t in GeneratorTechs, LD in p.Load, ts in p.TimeStep, s in p.Seg, fb in p.FuelBin))


    ### Aggregates of definitions
    @expression(REopt, TotalEnergyCharges, sum(dvFuelCost[t,fb]
                                                 for t in p.Tech, fb in p.FuelBin))
    @expression(REopt, TotalEnergyChargesUtil, sum(dvFuelCost["UTIL1",fb] for fb in p.FuelBin))
    @expression(REopt, TotalGenFuelCharges, sum(dvFuelCost[t,fb] for t in GeneratorTechs, fb in p.FuelBin))
    @expression(REopt, DemandTOUCharges, sum(dvPeakDemandE[r, db] * p.DemandRates[r,db] * p.pwf_e
                                               for r in p.Ratchets, db in p.DemandBin))
    @expression(REopt, DemandFlatCharges, sum(dvPeakDemandEMonth[m, dbm] * p.DemandRatesMonth[m, dbm] * p.pwf_e
                                                for m in p.Month, dbm in p.DemandMonthsBin))
    @expression(REopt, TotalDemandCharges, DemandTOUCharges + DemandFlatCharges)
    @expression(REopt, TotalFixedCharges, p.FixedMonthlyCharge * 12 * p.pwf_e)

    ### Utility and Taxable Costs
    @expression(REopt, TotalEnergyExports, sum(dvRatedProd[t,LD,ts,s,fb] * p.TimeStepScaling * p.ProdFactor[t, LD, ts] * p.LevelizationFactor[t] *
                                                 p.ExportRates[t,LD,ts] * p.pwf_e for t in p.Tech, LD in p.Load, ts in p.TimeStep, s in p.Seg, fb in p.FuelBin))
    @expression(REopt, TotalProductionIncentive, sum(dvProdIncent[t] for t in p.Tech))


    ### MinChargeAdder
    if p.AnnualMinCharge > 12 * p.MonthlyMinCharge
        TotalMinCharge = p.AnnualMinCharge * p.pwf_e
    else
        TotalMinCharge = 12 * p.MonthlyMinCharge * p.pwf_e
    end

    if TotalMinCharge > 0
        @constraint(REopt, MinChargeAdder >= TotalMinCharge - (TotalEnergyCharges + TotalDemandCharges + TotalEnergyExports + TotalFixedCharges))
	else
		@constraint(REopt, MinChargeAdder == 0)
    end
	
	
	
    #= Note: 0.999*MinChargeAdder in Obj b/c when TotalMinCharge > (TotalEnergyCharges + TotalDemandCharges + TotalEnergyExports + TotalFixedCharges)
		it is arbitrary where the min charge ends up (eg. could be in TotalDemandCharges or MinChargeAdder).
		0.001*MinChargeAdder is added back into LCC when writing to results.  =#
		
	### Constraint (13): Annual minimum charge adder 
	#if p.AnnualMinCharge > 12 * p.MonthlyMinCharge
    #    TotalMinCharge = p.AnnualMinCharge 
    #else
    #    TotalMinCharge = 12 * p.MonthlyMinCharge
    #end
	
	#if TotalMinCharge > 0
    #    @constraint(REopt, MinChargeAdder >= TotalMinCharge - (
	#		#Demand Charges
	#		p.TimeStepScaling * sum( p.ElecRate[u,ts] * dvGridPurchase[u,ts] for ts in p.TimeStep, u in p.PricingTier ) +
	#		#Peak Ratchet Charges
	#		sum( p.DemandRates[r,e] * dvPeakDemandE[r,e] for r in p.Ratchets, e in p.DemandBin) + 
	#		#Preak Monthyl Demand Charges
	#		sum( p.DemandRatesMonth[m,n] * dvPeakDemandEMonth[m,n] for m in p.Month, n in p.DemandMonthsBin) -
	#		# Energy Exports
	#		p.TimeStepScaling * sum( p.GridExportRates[u,ts] * (dvStorageToGrid[u,ts] + sum(dvProductionToGrid[t,u,ts] for t in p.TechsByPricingTier[u])) for ts in p.TimeStep, u in p.PricingTier ) - 
	#		p.FixedMonthlyCharge * 12 )
	#	)
	#else
	#	@constraint(REopt, MinChargeAdder == 0)
    #end
	
	### Alternate constraint (13): Monthly minimum charge adder
	
	
	
	
    # Define Rates
    r_tax_fraction_owner = (1 - p.r_tax_owner)
    r_tax_fraction_offtaker = (1 - p.r_tax_offtaker)

    ### Objective Function
    @expression(REopt, REcosts,
		# Capital Costs
		TotalTechCapCosts + TotalStorageCapCosts +

		# Fixed O&M, tax deductible for owner
		TotalPerUnitSizeOMCosts * r_tax_fraction_owner +

		# Variable O&M, tax deductible for owner
		TotalPerUnitProdOMCosts * r_tax_fraction_owner +

		# Utility Bill, tax deductible for offtaker
		(TotalEnergyCharges + TotalDemandCharges + TotalEnergyExports + TotalFixedCharges + 0.999*MinChargeAdder) * r_tax_fraction_offtaker -

		# Subtract Incentives, which are taxable
		TotalProductionIncentive * r_tax_fraction_owner
	)
	
	###  New Objective Function
	#@expression(REopt, REcosts,
		## Non-Storage Technology Capital Costs
		#sum( p.CapCostSlope[t,s]*dvSystemSizeSegment[t,k,s] for t in p.Tech, k in p.CapCostSeg, t in p.SegByTechSubdivision[t,k]) +
		
		## Storage capital costs
		#sum( p.StoragePowerCost[b]*dvStorageCapPower[b] + p.StorageEnergyCost[b]*dvStorageCapEnergy[b] for b in p.Storage ) +  
		
		## Fixed O&M, tax deductible for owner
		#r_tax_fraction_owner * p.pwf_om * sum( p.OMperUnitSize[t] * dvSize[t] for t in p.Tech ) +

		## Variable O&M, tax deductible for owner
		#r_tax_fraction_owner * p.pwf_om * sum( p.OMcostPerUnitProd[t] * dvRatedProduction[t,ts] for t in p.FuelBurningTechs, ts in p.TimeStep ) +

		
		#r_tax_fraction_offtaker * p.pwf_e * (
		
		## Total Production Costs
		#  p.TimeStepScaling * sum( p.FuelCost[f] * sum(dvFuelUsage[t,ts] for t in p.TechsByFuelType[f], ts in p.TimeStep) for f in p.FuelType ) + 
		
		#
		## Total Demand Charges
		#		p.TimeStepScaling * sum( p.ElecRate[u,ts] * dvGridPurchase[u,ts] for ts in p.TimeStep, u in p.PricingTier ) +
		
		## Peak Ratchet Charges
		#sum( p.DemandRates[r,e] * dvPeakDemandE[r,e] for r in p.Ratchets, e in p.DemandBin) + 
		
		## Peak Monthly Demand Charges
		#sum( p.DemandRatesMonth[m,n] * dvPeakDemandEMonth[m,n] for m in p.Month, n in p.DemandMonthsBin) -
		
		## Energy Exports
		#		p.TimeStepScaling * sum( p.GridExportRates[u,ts] * (dvStorageToGrid[u,ts] + sum(dvProductionToGrid[t,u,ts] for t in p.TechsByPricingTier[u])) for ts in p.TimeStep, u in p.PricingTier )  + 
		
		## Fixed Charges
		# p.FixedMonthlyCharge * 12 + MinChargeAdder
		
		#) -
		
		## Production Incentives
		#r_tax_fraction_owner * sum( dvProdIncent[t] for t in p.Tech )
		
	#)
	
	
    if Obj == 1
		@objective(REopt, Min, REcosts)
	elseif Obj == 2  # Keep SOC high
		@objective(REopt, Min, REcosts - dvMeanSOC)
	end
	optimize!(REopt)

    ##############################################################################
    #############  		Outputs    									 #############
    ##############################################################################
    @expression(REopt, ExportedElecPV,
                sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.LevelizationFactor[t] * p.TimeStepScaling
                    for t in PVTechs, LD in ["1W", "1X"], ts in p.TimeStep, s in p.Seg, fb in p.FuelBin))
    @expression(REopt, ExportedElecWIND,
                sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.LevelizationFactor[t] * p.TimeStepScaling
                    for t in WindTechs, LD in ["1W", "1X"], ts in p.TimeStep, s in p.Seg, fb in p.FuelBin))
    @expression(REopt, ExportedElecGEN,
                sum(dvRatedProd[t,LD,ts,s,fb] * p.ProdFactor[t, LD, ts] * p.LevelizationFactor[t] * p.TimeStepScaling
                    for t in GeneratorTechs, LD in ["1W", "1X"], ts in p.TimeStep, s in p.Seg, fb in p.FuelBin))

    # Needs levelization factor?
    @expression(REopt, ExportBenefitYr1,
                sum(dvRatedProd[t,LD,ts,s,fb] * p.TimeStepScaling * p.ProdFactor[t, LD, ts] * p.ExportRates[t,LD,ts] * p.LevelizationFactor[t]
                    for t in p.Tech, LD in p.Load, ts in p.TimeStep, s in p.Seg, fb in p.FuelBin))
    @expression(REopt, Year1UtilityEnergy,
                sum(dvRatedProd["UTIL1",LD,ts,s,fb] * p.TimeStepScaling * p.ProdFactor["UTIL1", LD, ts]
                    for LD in p.Load, ts in p.TimeStep, s in p.Seg, fb in p.FuelBin))


    ojv = round(JuMP.objective_value(REopt)+ 0.001*value(MinChargeAdder))
    Year1EnergyCost = TotalEnergyChargesUtil / p.pwf_e
    Year1DemandCost = TotalDemandCharges / p.pwf_e
    Year1DemandTOUCost = DemandTOUCharges / p.pwf_e
    Year1DemandFlatCost = DemandFlatCharges / p.pwf_e
    Year1FixedCharges = TotalFixedCharges / p.pwf_e
    Year1MinCharges = MinChargeAdder / p.pwf_e
    Year1Bill = Year1EnergyCost + Year1DemandCost + Year1FixedCharges + Year1MinCharges

    results = Dict{String, Any}("lcc" => ojv)

    results["batt_kwh"] = value(dvStorageSizeKWH)
    results["batt_kw"] = value(dvStorageSizeKW)

    if results["batt_kwh"] != 0
    	@expression(REopt, soc[ts in p.TimeStep], dvStoredEnergy[ts] / results["batt_kwh"])
        results["year_one_soc_series_pct"] = value.(soc)
    else
        results["year_one_soc_series_pct"] = []
    end

    if !isempty(PVTechs)
        results["PV"] = Dict()
        results["pv_kw"] = round(value(sum(dvSystemSize[t,s] for s in p.Seg, t in PVTechs)), digits=4)
        @expression(REopt, PVtoBatt[t in PVTechs, ts in p.TimeStep],
                    sum(dvRatedProd[t, "1S", ts, s, fb] * p.ProdFactor[t, "1S", ts] * p.LevelizationFactor[t] for s in p.Seg, fb in p.FuelBin))
    end

    WindTechs = filter(t->p.TechToTechClassMatrix[t, "WIND"] == 1, p.Tech)
    if !isempty(WindTechs)
        results["Wind"] = Dict()
        results["wind_kw"] = round(value(sum(dvSystemSize[t,s] for s in p.Seg, t in WindTechs)), digits=4)
        @expression(REopt, WINDtoBatt[t in WindTechs, ts in p.TimeStep],
                    sum(dvRatedProd[t, "1S", ts, s, fb] * p.ProdFactor[t, "1S", ts] * p.LevelizationFactor[t] for s in p.Seg, fb in p.FuelBin))
    end

	results["gen_net_fixed_om_costs"] = 0
	results["gen_net_variable_om_costs"] = 0
	results["gen_total_fuel_cost"] = 0
	results["gen_year_one_fuel_cost"] = 0
	results["gen_year_one_variable_om_costs"] = 0

    GeneratorTechs = filter(t->p.TechToTechClassMatrix[t, "GENERATOR"] == 1, p.Tech)
    if !isempty(GeneratorTechs)
    	if value(sum(dvSystemSize[t,s] for s in p.Seg, t in GeneratorTechs)) > 0
			results["Generator"] = Dict()
            results["generator_kw"] = value(sum(dvSystemSize[t,s] for s in p.Seg, t in GeneratorTechs))
			results["gen_net_fixed_om_costs"] = round(value(GenPerUnitSizeOMCosts) * r_tax_fraction_owner, digits=0)
			results["gen_net_variable_om_costs"] = round(value(GenPerUnitProdOMCosts) * r_tax_fraction_owner, digits=0)
	        results["gen_total_fuel_cost"] = round(value(TotalGenFuelCharges) * r_tax_fraction_offtaker, digits=2)
	        results["gen_year_one_fuel_cost"] = round(value(TotalGenFuelCharges) * r_tax_fraction_offtaker / p.pwf_e, digits=2)
	        results["gen_year_one_variable_om_costs"] = round(value(GenPerUnitProdOMCosts) * r_tax_fraction_owner / p.pwf_om, digits=0)
		end
    end

    net_capital_costs_plus_om = value(TotalTechCapCosts + TotalStorageCapCosts) +
                                value(TotalPerUnitSizeOMCosts + TotalPerUnitProdOMCosts) * r_tax_fraction_owner +
                                value(TotalGenFuelCharges) * r_tax_fraction_offtaker

    push!(results, Dict("year_one_utility_kwh" => round(value(Year1UtilityEnergy), digits=2),
						 "year_one_energy_cost" => round(value(Year1EnergyCost), digits=2),
						 "year_one_demand_cost" => round(value(Year1DemandCost), digits=2),
						 "year_one_demand_tou_cost" => round(value(Year1DemandTOUCost), digits=2),
						 "year_one_demand_flat_cost" => round(value(Year1DemandFlatCost), digits=2),
						 "year_one_export_benefit" => round(value(ExportBenefitYr1), digits=0),
						 "year_one_fixed_cost" => round(value(Year1FixedCharges), digits=0),
						 "year_one_min_charge_adder" => round(value(Year1MinCharges), digits=2),
						 "year_one_bill" => round(value(Year1Bill), digits=2),
						 "year_one_payments_to_third_party_owner" => round(value(TotalDemandCharges) / p.pwf_e, digits=0),
						 "total_energy_cost" => round(value(TotalEnergyCharges) * r_tax_fraction_offtaker, digits=2),
						 "total_demand_cost" => round(value(TotalDemandCharges) * r_tax_fraction_offtaker, digits=2),
						 "total_fixed_cost" => round(value(TotalFixedCharges) * r_tax_fraction_offtaker, digits=2),
						 "total_export_benefit" => round(value(TotalEnergyExports) * r_tax_fraction_offtaker, digits=2),
						 "total_min_charge_adder" => round(value(MinChargeAdder) * r_tax_fraction_offtaker, digits=2),
						 "total_payments_to_third_party_owner" => 0,
						 "net_capital_costs_plus_om" => round(net_capital_costs_plus_om, digits=0),
						 "year_one_energy_produced" => round(value(Year1PvProd), digits=0),
                         "average_yearly_pv_energy_produced" => round(value(AveragePvProd), digits=0),
						 "average_annual_energy_exported_pv" => round(value(ExportedElecPV), digits=0),
						 "year_one_wind_energy_produced" => round(value(Year1WindProd), digits=0),
						 "average_wind_energy_produced" => round(value(AverageWindProd), digits=0),
						 "average_annual_energy_exported_wind" => round(value(ExportedElecWIND), digits=0),
                         "year_one_gen_energy_produced" => round(value(Year1GenProd), digits=0),
                         "average_yearly_gen_energy_produced" => round(value(AverageGenProd), digits=0),
                         "average_annual_energy_exported_gen" => round(value(ExportedElecGEN), digits=0),
						 "net_capital_costs" => round(value(TotalTechCapCosts + TotalStorageCapCosts), digits=2))...)

    @expression(REopt, GeneratorFuelUsed, sum(dvFuelUsed[t, fb] for t in GeneratorTechs, fb in p.FuelBin))
    results["fuel_used_gal"] = round(value(GeneratorFuelUsed), digits=2)

    @expression(REopt, GridToBatt[ts in p.TimeStep],
                sum(dvRatedProd["UTIL1", "1S", ts, s, fb] * p.ProdFactor["UTIL1", "1S", ts] * p.LevelizationFactor["UTIL1"]
					for s in p.Seg, fb in p.FuelBin))
    results["GridToBatt"] = round.(value.(GridToBatt), digits=3)

    @expression(REopt, GridToLoad[ts in p.TimeStep],
                sum(dvRatedProd["UTIL1", "1R", ts, s, fb] * p.ProdFactor["UTIL1", "1R", ts] * p.LevelizationFactor["UTIL1"]
					for s in p.Seg, fb in p.FuelBin))
    results["GridToLoad"] = round.(value.(GridToLoad), digits=3)

	if !isempty(GeneratorTechs)
		@expression(REopt, GENERATORtoBatt[ts in p.TimeStep],
					sum(dvRatedProd[t, "1S", ts, s, fb] * p.ProdFactor[t, "1S", ts] * p.LevelizationFactor[t]
						for t in GeneratorTechs, s in p.Seg, fb in p.FuelBin))
    	results["GENERATORtoBatt"] = round.(value.(GENERATORtoBatt), digits=3)

		@expression(REopt, GENERATORtoGrid[ts in p.TimeStep],
					sum(dvRatedProd[t, LD, ts, s, fb] * p.ProdFactor[t, LD, ts] * p.LevelizationFactor[t]
						for t in GeneratorTechs, LD in ["1W", "1X"], s in p.Seg, fb in p.FuelBin))
		results["GENERATORtoGrid"] = round.(value.(GENERATORtoGrid), digits=3)

		@expression(REopt, GENERATORtoLoad[ts in p.TimeStep],
					sum(dvRatedProd[t, "1R", ts, s, fb] * p.ProdFactor[t, "1R", ts] * p.LevelizationFactor[t]
						for t in GeneratorTechs, s in p.Seg, fb in p.FuelBin))
		results["GENERATORtoLoad"] = round.(value.(GENERATORtoLoad), digits=3)
    else
    	results["GENERATORtoBatt"] = []
		results["GENERATORtoGrid"] = []
		results["GENERATORtoLoad"] = []
	end

	if !isempty(PVTechs)
		@expression(REopt, PVtoLoad[ts in p.TimeStep],
					sum(dvRatedProd[t, "1R", ts, s, fb] * p.ProdFactor[t, "1R", ts] * p.LevelizationFactor[t]
						for t in PVTechs, s in p.Seg, fb in p.FuelBin))
    	results["PVtoLoad"] = round.(value.(PVtoLoad), digits=3)

		@expression(REopt, PVtoGrid[ts in p.TimeStep],
					sum(dvRatedProd[t, LD, ts, s, fb] * p.ProdFactor[t, LD, ts] * p.LevelizationFactor[t]
						for t in PVTechs, LD in ["1W", "1X"], s in p.Seg, fb in p.FuelBin))
    	results["PVtoGrid"] = round.(value.(PVtoGrid), digits=3)

		@expression(REopt, PVPerUnitSizeOMCosts,
					sum(p.OMperUnitSize[t] * p.pwf_om * dvSystemSize[t, s] for t in PVTechs, s in p.Seg))
		results["pv_net_fixed_om_costs"] = round(value(PVPerUnitSizeOMCosts) * r_tax_fraction_owner, digits=0)
		
		@expression(REopt, PVSize,
				sum(dvSystemSize["PV",s] for s in p.Seg) )
		results["pv_size"] = round(value(PVSize),digits=2)
		
		@expression(REopt, PVNMSize,
				sum(dvSystemSize["PVNM",s] for s in p.Seg) )
		results["pv_nm_size"] = round(value(PVNMSize),digits=2)
		
	else
		results["PVtoLoad"] = []
		results["PVtoGrid"] = []
		results["pv_net_fixed_om_costs"] = 0
		results["pv_size"] = 0
		results["pv_nm_size"] = 0
	end

	if !isempty(WindTechs)
		@expression(REopt, WINDtoLoad[ts in p.TimeStep],
					sum(dvRatedProd[t, "1R", ts, s, fb] * p.ProdFactor[t, "1R", ts] * p.LevelizationFactor[t]
						for t in WindTechs, s in p.Seg, fb in p.FuelBin))
		results["WINDtoLoad"] = round.(value.(WINDtoLoad), digits=3)

		@expression(REopt, WINDtoGrid[ts in p.TimeStep],
					sum(dvRatedProd[t, LD, ts, s, fb] * p.ProdFactor[t, LD, ts] * p.LevelizationFactor[t]
						for t in WindTechs, s in p.Seg, fb in p.FuelBin, LD in ["1W", "1X"]))
		results["WINDtoGrid"] = round.(value.(WINDtoGrid), digits=3)
	else
		results["WINDtoLoad"] = []
    	results["WINDtoGrid"] = []
	end

    results["Load"] = p.LoadProfile["1R", :]

	if termination_status(REopt) == MOI.TIME_LIMIT
		status = "timed-out"
    elseif termination_status(REopt) == MOI.OPTIMAL
        status = "optimal"
    else
        status = "not optimal"
    end

    results["status"] = status
	
	## Parameter values
	results["p"] = p
	results["model"] = REopt
	results["dvSystemSize"] = value.(dvSystemSize)
	results["dvStorageSizeKW"] = value.(dvStorageSizeKW)
	results["dvStorageSizeKWH"] = value.(dvStorageSizeKWH)
	results["dvPeakDemandE"] = value.(dvPeakDemandE)
	results["dvPeakDemandEMonth"] = value.(dvPeakDemandEMonth)
	results["dvRatedProd"] = value.(dvRatedProd)
	results["UsageInTier"] = value.(UsageInTier)
	results["dvMeanSOC"] = value.(UsageInTier)
	
	print("TotalTechCapCosts:")
	println(value(TotalTechCapCosts))
	print("TotalStorageCapCosts:")
	println(value(TotalStorageCapCosts))
	print("TotalPerUnitSizeOMCosts:")
	println(value(TotalPerUnitSizeOMCosts))
	println(value( TotalPerUnitSizeOMCosts * r_tax_fraction_owner ))
	print("TotalPerUnitProdOMCosts:")
	println(value(TotalPerUnitProdOMCosts))
	println(value( TotalPerUnitProdOMCosts * r_tax_fraction_owner ))
	print("TotalEnergyCharges:")
	println(value(TotalEnergyCharges))
	println(value( TotalEnergyCharges * r_tax_fraction_offtaker ))
	print("TotalDemandCharges:")
	println(value(TotalDemandCharges))
	println(value( TotalDemandCharges * r_tax_fraction_offtaker ))
	print("TotalEnergyExports:")
	println(value(TotalEnergyExports))
	println(value( TotalEnergyExports * r_tax_fraction_offtaker  ))
	print("TotalFixedCharges:")
	println(value(TotalFixedCharges))
	println(value( TotalFixedCharges * r_tax_fraction_offtaker ))
	print("MinChargeAdder:")
	println(value(MinChargeAdder))
	println(value( MinChargeAdder * r_tax_fraction_offtaker ))
	print("TotalProductionIncentive:")
	println(value(TotalProductionIncentive))
	println(value( TotalProductionIncentive * r_tax_fraction_owner ))
	print("Usage by Tier by Month:")
	println(results["UsageInTier"])
		
    return results
end