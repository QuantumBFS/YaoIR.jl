using RBNF
using RBNF: Token

# NOTE:
# we can only transform routines satisfy the following:
# 1. locations are constants, in Julia we can calculate locations dynamically
#    but this is not allowed in QASM
# 2. do not contain classical functions calls except for 
# fn = ("sin" | "cos" | "tan" | "exp" | "ln" | "sqrt")
# binop = ('+' | '-' | '*' | '/')
# since QASM's if is actually a GotoIfNot node
# we don't reloop the SSA here, but assume the CodeInfo should
# not contain any GotoNode, which is incompatible with QASM
mutable struct QASMCtx
    ri::RoutineInfo
    src::CodeInfo
    pc::Int
    nstmts::Int
    record::QASM.RegisterRecord
    cbits::Dict{String, Int}
    # intrinsics called
    intrinsics::Vector{Symbol}
    regs_to_locs::Dict{Int, Vector{Int}}
    locs_to_reg_addr::Dict{Int, Tuple{Int, Int}}
end

function QASMCtx(ri::RoutineInfo)
    pc = first(first(ri.code.blocks))
    nstmts = length(ri.code.ci.code)
    regs_to_locs, locs_to_reg_addr = allocate_qreg(ri)
    QASMCtx(ri, ri.code.ci, pc, nstmts,
        QASM.RegisterRecord(),
        Dict{String, Int}(),
        Symbol[],
        regs_to_locs, locs_to_reg_addr
    )
end

codegen_main(ri::RoutineInfo) = codegen_main(QASMCtx(ri))

function _record_qalloc!(locs_to_regs, locs)
    if length(locs) == 1
        raw = locs.storage
        get!(locs_to_regs, raw, 1)
    else
        k_reg = maximum(get(locs_to_regs, each, 1) for each in locs) + 1
        
        for each in locs
            locs_to_regs[each] = k_reg
        end
    end
end

function allocate_qreg(ri::RoutineInfo)
    locs_to_regs = Dict{Int, Int}()

    for b in ri.code.blocks
        for v in b
            stmt = ri.code.ci.code[v]
            type = quantum_stmt_type(stmt)
            if type === :measure
                # we need to use entirely new qreg
                # since measure statement is not allowed to
                # take multiple qregs
                _record_qalloc!(locs_to_regs, stmt.args[2].args[2])
            elseif type === :barrier
                locs = stmt.args[2]::Locations
                for each in stmt.args[2]
                    get!(locs_to_regs, each, 1)
                end
            elseif type == :gate
                for each in stmt.args[3]
                    get!(locs_to_regs, each, 1)
                end
            elseif type == :ctrl
                for each in stmt.args[3]
                    get!(locs_to_regs, each, 1)
                end

                for each in stmt.args[4]
                    get!(locs_to_regs, each, 1)
                end
            else
                error("statement is incompatible to QASM, got: $stmt")
            end
        end
    end

    regs_to_locs = Dict{Int, Vector{Int}}()
    for (k, r) in locs_to_regs
        locs = get!(regs_to_locs, r, Int[])
        push!(locs, k)
    end


    
    # loc => reg, addr
    locs_to_reg_addr = Dict{Int, Tuple{Int, Int}}()
    for (r, locs) in regs_to_locs
        sort!(locs)
        for (k, loc) in enumerate(locs)
            locs_to_reg_addr[loc] = (r, k - 1)
        end
    end

    return regs_to_locs, locs_to_reg_addr
end

function codegen_main(ctx::QASMCtx)
    prog = Any[]

    for (k, locs) in ctx.regs_to_locs
        push!(prog, QASM.Parse.RegDecl(
            Token{:reserved}("qreg"),
            Token{:id}(string("q", k)),
            Token{:int}(string(length(locs)))
        ))
    end

    while ctx.pc <= ctx.nstmts
        stmt = ctx.src.code[ctx.pc]
        stmt_type = ctx.src.ssavaluetypes[ctx.pc]
        if stmt isa Expr
            e = codegen_expr(ctx, stmt)
            isnothing(e) || push!(prog, e)
            ctx.pc += 1
        elseif stmt isa Core.GotoIfNot
            e = codegen_ifnot(ctx, stmt)
            isnothing(e) || push!(prog, e)
            ctx.pc += 2
        else
            # ignore other statement
            # we assume the code is QASM compatible here
            # and validate it in a separte function
            ctx.pc += 1
        end
    end

    for (c, len) in ctx.cbits
        pushfirst!(prog, QASM.Parse.RegDecl(
            Token{:reserved}("creg"),
            Token{:id}(c),
            Token{:int}(string(len))
        ))
    end

    return QASM.Parse.MainProgram(v"2.0", prog)
end

function codegen_routine(ctx::QASMCtx, stmt)
end

function codegen_expr(ctx::QASMCtx, @nospecialize(stmt))
    if is_quantum_statement(stmt)
        type = quantum_stmt_type(stmt)
        if type === :gate
            gate = stmt.args[2]
            locs = stmt.args[3]
            return codegen_gate(ctx, gate, locs)
        elseif type === :ctrl
        elseif type === :measure
            return codegen_measure(ctx, stmt)
        elseif type === :barrier
            return codegen_barrier(ctx, stmt)
        end
    end
    return
end

function _qasm_name(x)
    if x in [:X, :Y, :Z, :H, :T, :Rx, :Ry, :Rz]
        return lowercase(string(x))
    else
        return string(x)
    end
end

function codegen_gate(ctx::QASMCtx, @nospecialize(gate), @nospecialize(locs))
    if gate isa SSAValue
        gate = ctx.src.ssavaluetypes[gate.id]
    end

    if locs isa SSAValue
        locs = ci.ssavaluetypes[locs.id]
    end

    if gate isa Core.Const
        gate = gate.val
    end

    if locs isa SSAValue
        locs = locs.val
    end

    gate isa RoutineSpec || gate isa IntrinsicSpec || error("invalid gate statement")
    
    name = routine_name(gate)

    if gate isa IntrinsicSpec
        push!(ctx.intrinsics, name)
    end

    # NOTE:
    # all classical arguments in QASM compatible code
    # should be constants, thus we just transform them
    # to strings
    cargs = Any[Token{:unnamed}(string(x)) for x in gate.variables]

    qargs = Any[]
    for k in locs
        r, addr = ctx.locs_to_reg_addr[k]
        push!(qargs, QASM.Parse.Bit(string("q", r), addr))
    end

    return QASM.Parse.Instruction(
        Token{:id}(_qasm_name(name)),
        cargs, qargs
    )
end

function codegen_ifnot(ctx::QASMCtx, @nospecialize(stmt))
    if stmt.cond isa SSAValue
        ctx.src.ssavaluetypes[stmt.cond.id] == Core.Const(QuantumBool()) ||
            error("condition does not contain measurement result")
        cond_ex = ctx.src.code[stmt.cond.id]
        cond_ex isa Expr && cond_ex.head === :call &&
            (cond_ex.args[1] === :(==) || (cond_ex.args[1] isa GlobalRef && cond_ex.args[1].name === :(==))) ||
            error("only `==` is compatible when compiling to QASM, got $cond_ex")

        cvar = cond_ex.args[2]
        if cvar isa Core.SlotNumber
            cname = ctx.src.slotnames[cvar.id]
        else
            cname = string("c", length(keys(ctx.cbits)) + 1)
        end

        cond_ex.args[3] isa Int || error("right hand condition must be constant Int for QASM")
        right = cond_ex.args[3]

        body = codegen_expr(ctx, ctx.src.code[ctx.pc+1])
        return QASM.Parse.IfStmt(Token{:id}(cname), Token{:int}(string(right)), body)
    else
        error("invalid GotoIfNot node: $stmt")
    end
end

function codegen_measure(ctx::QASMCtx, @nospecialize(stmt))
    if stmt.head === :(=)
        cvar = stmt.args[1]::Core.SlotNumber
        name = string(ctx.src.slotnames[cvar.id])
    else
        error("QASM compatible program must assign the measurement result to a variable")
    end

    measure_ex = stmt.args[2]
    locs = measure_ex.args[2]
    ctx.cbits[name] = length(locs)

    r, addr = ctx.locs_to_reg_addr[first(locs)]
    if length(locs) == 1
        # do write addr explicitly if the qreg has only one qubit
        if length(ctx.regs_to_locs[r]) == 1
            qarg = QASM.Parse.Bit(string("q", r))
        else
            qarg = QASM.Parse.Bit(string("q", r), addr)
        end
        return QASM.Parse.Measure(qarg, QASM.Parse.Bit(name, 0))
    else
        # by construction the registers are the same
        # and is exactly of size length(locs)
        return QASM.Parse.Measure(
            QASM.Parse.Bit(string("q", r)),
            QASM.Parse.Bit(name, length(locs))
        )
    end
end

function codegen_barrier(ctx::QASMCtx, @nospecialize(stmt))
    locs = stmt.args[2]
    qargs = Any[]

    args = Dict{Int, Vector{Int}}()

    for each in locs
        r, addr = ctx.locs_to_reg_addr[each]
        addrs = get!(args, r, Int[])
        push!(addrs, addr)
    end

    for (r, addrs) in args
        # do not index qreg explicitly if barrier size
        # is the same with register size
        if length(ctx.regs_to_locs[r]) == length(addrs)
            push!(qargs, QASM.Parse.Bit(string("q", r)))
        else
            for addr in addrs
                push!(qargs, QASM.Parse.Bit(string("q", r), addr))
            end
        end
    end
    return QASM.Parse.Barrier(qargs)
end