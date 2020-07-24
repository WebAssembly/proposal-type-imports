open Types

type module_inst =
{
  types : type_inst list;
  funcs : func_inst list;
  tables : table_inst list;
  memories : memory_inst list;
  globals : global_inst list;
  exports : export_inst list;
  elems : elem_inst list;
  datas : data_inst list;
}

and type_inst = Types.heap_type
and func_inst = module_inst Lib.Promise.t Func.t
and table_inst = Table.t
and memory_inst = Memory.t
and global_inst = Global.t
and export_inst = Ast.name * extern
and elem_inst = Value.ref_ list ref
and data_inst = string ref

and extern =
  | ExternType of type_inst
  | ExternFunc of func_inst
  | ExternTable of table_inst
  | ExternMemory of memory_inst
  | ExternGlobal of global_inst


(* Filters *)

let types =
  Lib.List.map_filter (function ExternType t -> Some t | _ -> None)
let funcs =
  Lib.List.map_filter (function ExternFunc f -> Some f | _ -> None)
let tables =
  Lib.List.map_filter (function ExternTable t -> Some t | _ -> None)
let memories =
  Lib.List.map_filter (function ExternMemory m -> Some m | _ -> None)
let globals =
  Lib.List.map_filter (function ExternGlobal g -> Some g | _ -> None)


(* Reference types *)

type Value.ref_ += FuncRef of func_inst

let () =
  let type_of_ref' = !Value.type_of_ref' in
  Value.type_of_ref' := function
    | FuncRef f -> DefHeapType (SemVar (Func.type_var_of f))
    | r -> type_of_ref' r

let () =
  let string_of_ref' = !Value.string_of_ref' in
  Value.string_of_ref' := function
    | FuncRef _ -> "func"
    | r -> string_of_ref' r


(* Auxiliary functions *)

let empty_module_inst =
  { types = []; funcs = []; tables = []; memories = []; globals = [];
    exports = []; elems = []; datas = [] }

let extern_type_of c = function
  | ExternType type_ -> ExternTypeType (EqType type_)
  | ExternFunc func -> ExternFuncType (Func.type_of func)
  | ExternTable tab -> ExternTableType (Table.type_of tab)
  | ExternMemory mem -> ExternMemoryType (Memory.type_of mem)
  | ExternGlobal glob -> ExternGlobalType (Global.type_of glob)

let export inst name =
  try Some (List.assoc name inst.exports) with Not_found -> None
