mutable struct RepairOp
    repair!::Function
    kwargs::Dict
end

mutable struct DestroyOp
    destroy_list::Vector{Function}
    destroy!::Function
    kwargs::Dict
    old_kwargs::Dict
    destroy_weights::Dict{String, Float64}
    weight_update::Function
end

mutable struct ChangeOp
    change!::Function
    kwargs::Dict
    change_weights::Dict{String, Float64}
    weight_update::Function
end

struct LNSConf
    conf_fp::String
    n_iterations::Union{Int, Nothing}
    n_iter_no_improve::Int
    time_limit::Float64
    rep::RepairOp
    des::DestroyOp
    change::ChangeOp
    adaptation!::Function
    seed::Union{Nothing, Int}
end

function DestroyOp(destroy!::Function,  destroy_kwargs::Dict; 
        destroy_weights::Dict=Dict{String, Float64}("random_model_destroy!"=>1., "random_station_destroy!"=>1., "random_subtree_destroy!"=>1.),
        weight_update::Function = no_weight_update,
        destroy_list::Array{Function} = [random_model_destroy!, random_station_destroy!, random_subtree_destroy!])
    old_destroy_kwargs = deepcopy(destroy_kwargs)
    return DestroyOp(destroy_list, destroy!, destroy_kwargs, old_destroy_kwargs, destroy_weights, weight_update)
end

function update_destroy_operator!(des::DestroyOp, new_destroy!::Function)
    des.destroy! = new_destroy!
end

function ChangeOp(change!::Function, change_kwargs::Dict; change_weights::Dict=Dict{String, Float64}("no_change!"=>1., "increase_size!"=>1., "decrement_y!"=>1., "change_destroy!"=>1.,  "increase_repair_time!"=>1.0), weight_update::Function = no_weight_update)
    return ChangeOp(change!, change_kwargs, change_weights, weight_update)
end



function read_search_strategy_YAML(config_filepath::Union{Nothing,String}, run_time::Float64; model_dependent::Bool=false, config_dict::Union{Nothing, Dict}=nothing)
    if !isnothing(config_dict)
        config_file = config_dict
    else
        config_file = YAML.load(open(config_filepath))
    end
    #if the LNS section is not in the config file, return an empty dictionary
    if !haskey(config_file, "lns")
        return Dict()
    elseif !haskey(config_file["lns"], "time_limit")
        @info "no time limit specified in config file, defaulting to command line defined $run_time seconds"
        config_file["lns"]["time_limit"] = run_time
    end
    search_strategy = config_file["lns"]
    search_strategy = get_search_strategy_config(search_strategy, config_filepath; model_dependent=model_dependent)
    return search_strategy
end

function configure_change(search_strategy::Dict)
    #destroy operator change configuration
    if !haskey(search_strategy, "change")
        @info "No destroy change specified, defaulting to no_change!"
        destroy_change = no_change
        search_strategy["change"] = Dict("kwargs"=>Dict("change_freq"=>10), 
                                    "change_weights"=>Dict("no_change!"=>1.0, 
                                                        "increase_size!"=>1.0, 
                                                            "decrement_y!"=>1.0, 
                                                            "change_destroy!"=>1.0, 
                                                            "increase_repair_time!"=>1.0))
        weight_update = no_weight_update
    else
        if !haskey(search_strategy["change"], "kwargs")
            @info "No destroy change arguments specified, defaulting to change_freq=3"
            search_strategy["change"]["kwargs"] = Dict("change_freq"=>3, "change_decay"=>0.9)
        else 
            @info "Destroy change arguments specified: $(search_strategy["change"]["kwargs"])"
            if !haskey(search_strategy["change"]["kwargs"], "change_decay")
                @info "No change decay specified, defaulting to 0.9"
                search_strategy["change"]["kwargs"]["change_decay"] = 0.9
            end
            if !haskey(search_strategy["change"]["kwargs"], "change_freq")
                @info "No change frequency specified, defaulting to 3"
                search_strategy["change"]["kwargs"]["change_freq"] = 3
            end
        end
        if search_strategy["change"]["operator"] == "increase_size!" || search_strategy["change"]["operator"] == "increase_destroy!"
            @info "Deconstructor change operator $(search_strategy["change"]["operator"]) recognized"
            destroy_change = increase_size!
        elseif search_strategy["change"]["operator"] == "no_change!" || search_strategy["change"]["operator"] == "no_change"
            @info "Deconstructor change operator $(search_strategy["change"]["operator"]) recognized"
            destroy_change = no_change!
        elseif search_strategy["change"]["operator"] == "decrement_y!"
            @info "Deconstructor change operator $(search_strategy["change"]["operator"]) recognized"
            destroy_change = decrement_y!
            if !haskey(search_strategy["change"]["kwargs"], "fix_steps")
                @info "no fix steps specified, defaulting to 1"
                search_strategy["change"]["kwargs"]["fix_steps"] = 1
            end
        elseif search_strategy["change"]["operator"] == "change_destroy!"
            @info "Deconstructor change operator $(search_strategy["change"]["operator"]) recognized"
            destroy_change = change_destroy!
        elseif search_strategy["change"]["operator"] == "change_destroy_increase_size!"
            @info "Deconstructor change operator $(search_strategy["change"]["operator"]) recognized"
            destroy_change = change_destroy_increase_size!
        elseif search_strategy["change"]["operator"] == "change_destroy_increase_size_reset_improve!"
            @info "Deconstructor change operator $(search_strategy["change"]["operator"]) recognized"
            destroy_change = change_destroy_increase_size_reset_improve!
        elseif search_strategy["change"]["operator"] == "change_destroy_increase_size_reduce_improve!"
            @info "Deconstructor change operator $(search_strategy["change"]["operator"]) recognized"
            destroy_change = change_destroy_increase_size_reduce_improve!
        elseif search_strategy["change"]["operator"] == "adapt_lns!"
            @info "Deconstructor change operator $(search_strategy["change"]["operator"]) recognized"
            destroy_change = adapt_lns!
        else
            @error "Deconstructor change operator $(search_strategy["change"]) not recognized"
        end
        if !haskey(search_strategy["change"], "weight_update")
            @info "no change weight update specified, defaulting to no_weight_update"
            weight_update = no_weight_update
        else
            @info "change weight update specified: $(search_strategy["change"]["weight_update"])"
            if search_strategy["change"]["weight_update"] == "iter_and_time_update"
                weight_update = iter_and_time_update
            elseif search_strategy["change"]["weight_update"] == "basic_update"
                weight_update = basic_update
            elseif search_strategy["change"]["weight_update"] == "no_weight_update"
                weight_update = no_weight_update
            elseif search_strategy["change"]["weight_update"] == "obj_val_update"
                weight_update = obj_val_update
            else
                @error "Deconstructor change operator $(search_strategy["change"]["weight_update"]) not recognized"
            end
        end
        if !haskey(search_strategy["change"], "change_weights")
            @info "no change reward specified, defaulting to 1 across all change operators"
            search_strategy["change"]["change_weights"] = Dict("no_change!"=>1.0, "increase_size!"=>1.0, "decrement_y!"=>1.0, "change_destroy!"=>1.0, "increase_repair_time!"=>1.0)
        end
    end
    #converst change_op kwargs to symbols
    search_strategy["change"]["kwargs"] = Dict(Symbol(k) => v for (k, v) in search_strategy["change"]["kwargs"])
    change_op = ChangeOp(destroy_change, search_strategy["change"]["kwargs"], search_strategy["change"]["change_weights"], weight_update)
    return change_op
end

function parse_destroy_list(destroy_list::Array{String})
    #new destroy list is a vector of runner_functions
    new_destroy_list = Vector{Function}()
    for i in destroy_list
        i = getfield(ModelRun, Symbol(i))
        push!(new_destroy_list, i)
    end
    return new_destroy_list
end

function configure_destroy(search_strategy::Dict; model_dependent::Bool=false)
    if !haskey(search_strategy, "destroy") || !haskey(search_strategy["destroy"], "operator")
        @info "No destroy specified, defaulting to random_station_destroy"
        search_strategy["destroy"] = Dict()
        destroy_op = random_station_destroy!
        search_strategy["destroy"]["kwargs"] = Dict()
        search_strategy["change"]["operator"] = no_change
    else
        @info "Deconstructor specified: $(search_strategy["destroy"]["operator"])"
        if (haskey(search_strategy, "formulation") && search_strategy["formulation"] == "md") || model_dependent
            @info "Running model depedent formulation"
            destroy_list = [random_station_destroy_md!, random_model_destroy_md!]
            if haskey(search_strategy["destroy"], "operator")
                destroy = search_strategy["destroy"]["operator"]
            else
                @info destroy operator specified, defaulting to random
                destroy = "random"
            end
            if destroy == "random_station" || destroy == "random_station_destroy!"
                destroy_op = random_station_destroy_md!
            elseif destroy == "random_model" || destroy == "random_model_destroy!"
                destroy_op = random_model_destroy_md!
            elseif destroy == "random_station_model" || destroy == "random_station_model_destroy!"
                destroy_op = random_station_model_destroy_md!
            elseif destroy == "peak_station" || destroy == "peak_station_destroy!"
                destroy_op = peak_station_destroy_md!
            elseif destroy == "random_start" || destroy == "random"
                destroy_op = rand(destroy_list)
                @info "Deconstructor operator $(destroy) recognized, randomly selected $(destroy_op) from destroy operators"
            else
                @error "Deconstructor operator $(destroy) not recognized"
            end
            search_strategy["destroy"]["destroy_weights"] = Dict("random_station_destroy_md!"=>0.5, "random_model_destroy_md!"=>0.5)
    else
       
        if haskey(search_strategy["destroy"], "destroy_list")
            @info "Destroy list specified: $(search_strategy["destroy"]["destroy_list"])   the type is:  $(typeof(search_strategy["destroy"]["destroy_list"]))"
        else
            @info "No destroy list specified, defaulting to all"
        end
        if haskey(search_strategy["destroy"], "destroy_list") 
            if haskey(search_strategy["destroy"], "destroy_list") && search_strategy["destroy"]["destroy_list"] == "all"
                destroy_list = [random_station_destroy!, random_subtree_destroy!, random_model_destroy!, random_station_model_destroy!, random_model_subtree_destroy!, random_station_subtree_destroy!, peak_station_destroy!]
            elseif haskey(search_strategy["destroy"], "destroy_list") && search_strategy["destroy"]["destroy_list"] == "enhanced_random"
                destroy_list = [random_station_destroy!, random_subtree_destroy!, random_model_destroy!, random_station_model_destroy!, random_model_subtree_destroy!, random_station_subtree_destroy!,]
            elseif haskey(search_strategy["destroy"], "destroy_list") && search_strategy["destroy"]["destroy_list"] == "basic_random"
                destroy_list = [random_station_destroy!, random_subtree_destroy!, random_model_destroy!]
            elseif haskey(search_strategy["destroy"], "destroy_list") && search_strategy["destroy"]["destroy_list"] == "mixed_random"
                destroy_list = [random_station_model_destroy!, random_model_subtree_destroy!, random_station_subtree_destroy!]
            #If they pass an actual list of destroy operators, we will have to parse it
            elseif haskey(search_strategy["destroy"], "destroy_list") && typeof(search_strategy["destroy"]["destroy_list"]) == Vector{String} 
                destroy_list = parse_destroy_list(search_strategy["destroy"]["destroy_list"])
            else
                destroy_list = [random_station_destroy!, random_subtree_destroy!, random_model_destroy!]
            end
        end
        @info "Destroy list: $destroy_list"

        destroy = search_strategy["destroy"]["operator"]
        
        if destroy == "random_station" || destroy == "random_station_destroy!"
            destroy_op = random_station_destroy!
        elseif destroy == "random_subtree" || destroy == "random_subtree_destroy!"
            destroy_op = random_subtree_destroy!
        elseif destroy == "random_model" || destroy == "random_model_destroy!"
            destroy_op = random_model_destroy!
        elseif destroy == "random_station_model" || destroy == "random_station_model_destroy!"
            destroy_op = random_station_model_destroy!
        elseif destroy == "random_model_subtree" || destroy == "random_model_subtree_destroy!"
            destroy_op = random_model_subtree_destroy!
        elseif destroy  == "random_station_subtree" || destroy == "random_station_subtree_destroy!"
            destroy_op = random_station_subtree_destroy!
        elseif destroy == "peak_station" || destroy == "peak_station_destroy!"
            destroy_op = peak_station_destroy!
        elseif destroy == "random_start" || destroy == "random"
            destroy_op = rand(destroy_list)
            @info "randomly selected $(destroy_op) from destroy operators"
        else
            @error "Deconstructor operator $(destroy) not recognized"
        end
    end
        if !haskey(search_strategy["destroy"], "kwargs")
            @info "No destroy arguments specified, defaulting to n_destroy=2"
            destroy_kwargs = Dict("n_destroy"=>2, "des_decay"=>0.9, )
        else
            @info "Deconstructor arguments specified: $(search_strategy["destroy"]["kwargs"])"
            destroy_kwargs = search_strategy["destroy"]["kwargs"]
            if !haskey(destroy_kwargs, "des_decay")
                @info "No destroy decay specified, defaulting to 0.9"
                destroy_kwargs["des_decay"] = 0.9
            end
            if !haskey(destroy_kwargs, "fix_steps")
                @info "No fix steps specified, defaulting to 1"
                destroy_kwargs["fix_steps"] = 1
            end

        end
        if !haskey(search_strategy["destroy"], "destroy_weights")
            @info "No destroy weights specified, defaulting to equal weights"
            weights = [1 for i in destroy_list]
            destroy_names = [string(destroy) for destroy in destroy_list]
            search_strategy["destroy"]["destroy_weights"] = Dict(zip(destroy_names, weights))
        else
            @info "Destroy weights specified: $(search_strategy["destroy"]["destroy_weights"])"
        end
        if !haskey(search_strategy["destroy"], "weight_update")
            @info "No destroy weight update specified, defaulting to no_weight_update"
            weight_update = no_weight_update
        else
            @info "Destroy weight update specified: $(search_strategy["destroy"]["weight_update"])"
            if search_strategy["destroy"]["weight_update"] == "iter_and_time_update"
                weight_update = iter_and_time_update
            elseif search_strategy["destroy"]["weight_update"] == "basic_update"
                weight_update = basic_update
            elseif search_strategy["destroy"]["weight_update"] == "no_weight_update"
                weight_update = no_weight_update
            elseif search_strategy["change"]["weight_update"] == "obj_val_update"
                weight_update = obj_val_update
            else
                @error "Destroy weight update operator $(search_strategy["destroy"]["weight_update"]) not recognized"
            end
        end
    end 

    #converts the keys to symbols
    destroy_kwargs = Dict(Symbol(k) => v for (k, v) in destroy_kwargs)
    # DestroyOp(destroy!::Function,  destroy_kwargs::Dict; 
    #     destroy_weights::Dict=Dict{String, Float64}("random_model_destroy!"=>1., "random_station_destroy!"=>1., "random_subtree_destroy!"=>1.),
    #     weight_update::Function = no_weight_update,
    #     destroy_list::Array{Function} = [random_model_destroy!, random_station_destroy!, random_subtree_destroy!])
    destroy_operator = DestroyOp(destroy_op, 
                        destroy_kwargs; 
                        destroy_weights=search_strategy["destroy"]["destroy_weights"], 
                        weight_update=weight_update,
                        destroy_list=destroy_list)
    return destroy_operator
end

function configure_repair(search_strategy::Dict)
    if !haskey(search_strategy, "repair") || !haskey(search_strategy["repair"], "operator")
        @info "No repair specified, defaulting to MILP"
        search_strategy["repair"] = Dict()
        repair_op = optimize!
        search_strategy["repair"]["kwargs"] = Dict("time_limit"=>100, "mip_gap"=>1e-2, "mip_gap_decay"=>0.95)
    else
        @info "Repair operator specified: $(search_strategy["repair"]["operator"])"
        repair = search_strategy["repair"]["operator"]
        if repair == "optimize!" || repair == "MILP" || repair == "milp!"
            repair_op = optimize!
        else
            @error "Repair operator $(repair) not recognized"
        end
        if !haskey(search_strategy["repair"], "kwargs")
            @info "No repair arguments specified, defaulting to time_limit=100"
            kwargs = Dict("time_limit"=>100, "mip_gap"=>1e-2, "mip_gap_decay"=>0.95)
        else
            if !haskey(search_strategy["repair"]["kwargs"], "mip_gap_decay")
                @info "No mip_gap decay specified, defaulting to 0.95"
                search_strategy["repair"]["kwargs"]["mip_gap_decay"] = 0.95
            end
            if !haskey(search_strategy["repair"]["kwargs"], "mip_gap")
                @info "No mip_gap specified, defaulting to 1e-2"
                search_strategy["repair"]["kwargs"]["mip_gap"] = 1e-2
            end
            @info "Repair arguments specified: $(search_strategy["repair"]["kwargs"])"
            kwargs = search_strategy["repair"]["kwargs"]
            #converts the keys to symbols
            
        end
    end
    kwargs = Dict(Symbol(k) => v for (k, v) in kwargs)
    repair_operator = RepairOp(repair_op, kwargs)
    return repair_operator
end

function get_search_strategy_config(search_strategy::Dict, config_filepath::String; model_dependent::Bool=false)
    if !haskey(search_strategy, "n_iterations")
        @info "No number of iterations specified, defaulting to 10000"
        search_strategy["n_iterations"] = 10000
    else
        @info "Number of iterations specified: $(search_strategy["n_iterations"])"
    end
    if !haskey(search_strategy, "n_iter_no_improve")
        @info "No number of iterations with no improvement specified, defaulting to 2"
        search_strategy["n_iter_no_improve"] = 2
    else
        @info "Number of iterations with no improvement specified: $(search_strategy["n_iter_no_improve"])"
    end
    if !haskey(search_strategy, "time_limit")
        @info "No time limit specified, defaulting to 600 seconds"
        search_strategy["time_limit"] = 600
    else
        @info "Time limit specified: $(search_strategy["time_limit"]) seconds"
    end
    if !haskey(search_strategy, "adaptation")
        @info "No LNS adaptation specified, defaulting to no_adapt_lns"
        adaptation_technique = no_adapt!
    else
        @info "LNS adaptation specified: $(search_strategy["adaptation"])"
        if search_strategy["adaptation"] == "adapt_lns!"
            adaptation_technique = adapt_lns!
        elseif search_strategy["adaptation"] == "adapt_des!"
            adaptation_technique = adapt_des!
        elseif search_strategy["adaptation"] == "no_adapt!" || search_strategy["adaptation"] == "no_adapt_lns" || search_strategy["adaptation"] == "no_adapt"
            adaptation_technique = no_adapt!
        else
            @error "LNS adaptation operator $(search_strategy["adaptation"]) not recognized"
        end
    end
    #repair configuration
    repair_op = configure_repair(search_strategy)
    #destroy configuration
    destroy_op = configure_destroy(search_strategy; model_dependent=model_dependent)
    #change configuration
    change_op = configure_change(search_strategy)
    #setting the seed (if not none)
    if !haskey(search_strategy, "seed")
        search_strategy["seed"] = nothing
    end
    lns_obj = LNSConf(config_filepath,
        search_strategy["n_iterations"], 
    search_strategy["n_iter_no_improve"], 
    search_strategy["time_limit"], 
    repair_op, 
    destroy_op, 
    change_op,
    adaptation_technique,
    search_strategy["seed"])
    return lns_obj
end


#sets the smallest percentage to increase destroy size for the destroy operator
function set_destroy_size!(des::DestroyOp, instance::MALBP_W_instance)
    des.kwargs[:min_destroy] =  min( 1/instance.equipment.n_stations, 1/instance.models.n_models )
    #combined operators need to consider the size of original operators
    mixed_random_list = [random_station_model_destroy!, random_model_subtree_destroy!, random_station_subtree_destroy!]
    if !haskey(des.kwargs, :percent_destroy) && length([i for i in des.destroy_list for j in mixed_random_list if i == j]) == 0
        percent_destroy = des.kwargs[:min_destroy]
        des.kwargs[:min_destroy] = percent_destroy
         @info "No percent destroy specified, defaulting to the smallest amount that can change an operator: $percent_destroy"
         des.kwargs[:percent_destroy] = percent_destroy
         des.old_kwargs[:percent_destroy] = percent_destroy
    elseif !haskey(des.kwargs, :percent_destroy)
        percent_destroy = 1/ (instance.equipment.n_stations * instance.models.n_models)
        des.kwargs[:min_destroy] = percent_destroy
         @info "No percent destroy specified, defaulting to the smallest amount that can change an operator: $percent_destroy"
         des.kwargs[:percent_destroy] = percent_destroy
         des.old_kwargs[:percent_destroy] = percent_destroy
    end
end