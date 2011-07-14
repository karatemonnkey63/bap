open OUnit


let test_input_fails _ =
  assert_raises (Arg.Bad "No input specified") (fun _ -> Input.get_program());;

let test_input_nop () = 
  let p = Asmir.open_program ~loud:false "./x86/nop" in
  let stmts = Asmir.asmprogram_to_bap p in
  match stmts with
	| [] -> 
	  let s = 
		"Asmir.asmprogram_to_bap of Asmir.open_program \"./x86/nop\" returned \
         an empty list!" in
	  assert_failure s
	| stmt::stmts ->
	  (* XXX Skip for now; the intention is for this to find where the nop
		 should be and verify a nop is there *)
	  skip_if 
		true
		("First stmt of program ./x86/nop is "^(Pp.ast_stmt_to_string stmt))


let suite = "IL" >::: 
  [
	"test_input_fails" >:: test_input_fails;
	"test_input_nop" >:: test_input_nop;
  ]
