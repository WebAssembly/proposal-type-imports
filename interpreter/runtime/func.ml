open Types
open Value

type 'inst t = 'inst func
and 'inst func =
  | AstFunc of sem_var * 'inst * Ast.func
  | HostFunc of sem_var * (value list -> value list)
  | ClosureFunc of sem_var * 'inst func * value list

let alloc x inst f = AstFunc (x, inst, f)
let alloc_host x f = HostFunc (x, f)
let alloc_closure x func vs = ClosureFunc (x, func, vs)

let type_var_of = function
  | AstFunc (x, _, _) -> x
  | HostFunc (x, _) -> x
  | ClosureFunc (x, _, _) -> x

let type_of f = as_func_def_type (def_of (type_var_of f))
