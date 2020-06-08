export is_quantum, is_pure_quantum, is_qasm_compatible

const PRIMITIVES_GATE = [:shift, :X, :Y, :Z, :H, :phase, :Rx, :Ry, :Rz, :T, :S, :rot]

"""
    is_quantum(ex)

Check if the given expression is a quantum statement.
"""
is_quantum(ex::Statement) = is_quantum(ex.expr)
is_quantum(ex::Expr) = ex.head === :quantum
is_quantum(ex) = false

function is_pure_quantum(ir::YaoIR)
    return all(ir.body) do (v, st)
        is_pure_quantum(st)
    end
end

is_pure_quantum(x) = false
is_pure_quantum(ex::Statement) = is_pure_quantum(ex.expr)

function is_pure_quantum(ex::Expr)
    ex.head === :quantum && return true

    if ex.head === :call
        if ex.args[1] isa Symbol
            return true
        elseif ex.args[1] isa GlobalRef
            (ex.args[1].name in PRIMITIVES_GATE) && return true
        elseif (ex.args[1] isa Expr)
            (ex.args[1].head === :(.)) &&
                (ex.args[1].args[1] === :YaoLang) &&
                (ex.args[1].args[2] in PRIMITIVES_GATE) &&
                return true
        end
    end
    return false
end

function hasmeasure(ir::YaoIR)
    for (v, st) in ir.body
        if is_quantum(st) && (st.expr.args[1] === :measure)
            return true
        end
    end
    return false
end

const QASM_VALIDE_EX = Any[:(+), :(-), :(*), :(\), :(/), :(^)]

for fn in [:sin, :cos, :tanh, :exp, :log, :sqrt]
    push!(QASM_VALIDE_EX, GlobalRef(Base, fn))
end

for fn in [:shift, :X, :Y, :Z, :H, :phase, :Rx, :Ry, :Rz, :T, :S, :rot]
    push!(QASM_VALIDE_EX, GlobalRef(YaoLang, fn))
    push!(QASM_VALIDE_EX, fn)
end

"""
    is_qasm_compatible(ir)

Check if the given expression is compatible with openQASM.
"""
function is_qasm_compatible(ir::YaoIR)
    return all(ir.body) do (v, st)
        is_qasm_compatible(st)
    end
end

is_qasm_compatible(st::Statement) = is_qasm_compatible(st.expr)

function is_qasm_compatible(ex::Expr)
    ex.head === :quantum && return true
    if (ex.head == :call) && (ex.args[1] in QASM_VALIDE_EX)
        return true
    end
    return false
end

function is_qasm_compatible(x)
    return false
end
