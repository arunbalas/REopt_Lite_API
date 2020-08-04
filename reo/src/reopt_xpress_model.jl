using JuMP
using Xpress

function reopt_model(MAXTIME, MIPRELSTOP,LOGFILE)
   
    REopt = direct_model(Xpress.Optimizer(MAXTIME=-MAXTIME, MIPRELSTOP=MIPRELSTOP, logfile=LOGFILE))
	REopt[:solver_name] = "Xpress"
	REopt[:timeout_seconds] = MAXTIME
	REopt[:optimality_tolerance] = MIPRELSTOP
	return REopt

end
