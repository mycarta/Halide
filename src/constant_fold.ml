open Ir
open Analysis

(* Is an expression sufficiently simple that it should just be substituted in when it occurs in a let *)
let is_simple = function
  | IntImm _ | FloatImm _ | UIntImm _ | Var (_, _) -> true
  | _ -> false

let rec constant_fold_expr expr = 
  let recurse = constant_fold_expr in
  
  let is_const_zero = function
    | IntImm 0 
    | UIntImm 0
    | FloatImm 0.0
    | Broadcast (IntImm 0, _)
    | Broadcast (UIntImm 0, _)
    | Broadcast (FloatImm 0.0, _) -> true
    | _ -> false
  and is_const_one = function
    | IntImm 1
    | UIntImm 1
    | FloatImm 1.0
    | Broadcast (IntImm 1, _)
    | Broadcast (UIntImm 1, _)
    | Broadcast (FloatImm 1.0, _) -> true
    | _ -> false
  and is_const = function
    | IntImm _ 
    | UIntImm _ 
    | FloatImm _
    | Broadcast (IntImm _, _)
    | Broadcast (UIntImm _, _)
    | Broadcast (FloatImm _, _) -> true
    | _ -> false
  in

  match expr with
    (* Ignoring most const-casts for now, because we can't represent immediates of arbitrary types *)
    | Cast (t, e) -> 
        begin match (t, recurse e) with
          | (Int 32, IntImm x)    -> IntImm x
          | (Int 32, UIntImm x)   -> IntImm x
          | (Int 32, FloatImm x)  -> IntImm (int_of_float x)
          | (UInt 32, IntImm x)   -> UIntImm x
          | (UInt 32, UIntImm x)  -> UIntImm x
          | (UInt 32, FloatImm x) -> UIntImm (int_of_float x)
          | (Float 32, IntImm x)  -> FloatImm (float_of_int x)
          | (Float 32, UIntImm x) -> FloatImm (float_of_int x)
          | (Float 32, FloatImm x) -> FloatImm x
          | (t, e)                -> Cast(t, e)
        end

    (* basic binary ops *)
    | Bop (op, a, b) ->
      begin match (op, recurse a, recurse b) with
        | (_, IntImm   x, IntImm   y) -> IntImm   (caml_iop_of_bop op x y)
        | (_, UIntImm  x, UIntImm  y) -> UIntImm  (caml_iop_of_bop op x y)
        | (_, FloatImm x, FloatImm y) -> FloatImm (caml_fop_of_bop op x y)

        (* Identity operations. These are not strictly constant
           folding, but they tend to come up at the same time *)
        | (Add, x, y) when is_const_zero x -> y
        | (Add, x, y) when is_const_zero y -> x
        | (Sub, x, y) when is_const_zero y -> x
        | (Mul, x, y) when is_const_one x -> y
        | (Mul, x, y) when is_const_one y -> x
        | (Mul, x, y) when is_const_zero x -> x
        | (Mul, x, y) when is_const_zero y -> y
        | (Div, x, y) when is_const_one y -> x

        (* op (Ramp, Broadcast) should be folded into the ramp *)
        | (Add, Broadcast (e, _), Ramp (b, s, n)) 
        | (Add, Ramp (b, s, n), Broadcast (e, _)) -> Ramp (recurse (b +~ e), s, n)
        | (Sub, Ramp (b, s, n), Broadcast (e, _)) -> Ramp (recurse (b -~ e), s, n)
        | (Mul, Broadcast (e, _), Ramp (b, s, n)) 
        | (Mul, Ramp (b, s, n), Broadcast (e, _)) -> Ramp (recurse (b *~ e), recurse (s *~ e), n)
        | (Div, Ramp (b, s, n), Broadcast (e, _)) -> Ramp (recurse (b /~ e), recurse (s /~ e), n)

        (* op (Broadcast, Broadcast) should be folded into the broadcast *)
        | (Add, Broadcast (a, n), Broadcast(b, _)) -> Broadcast (recurse (a +~ b), n)
        | (Sub, Broadcast (a, n), Broadcast(b, _)) -> Broadcast (recurse (a -~ b), n)
        | (Mul, Broadcast (a, n), Broadcast(b, _)) -> Broadcast (recurse (a *~ b), n)
        | (Div, Broadcast (a, n), Broadcast(b, _)) -> Broadcast (recurse (a /~ b), n)
        | (Mod, Broadcast (a, n), Broadcast(b, _)) -> Broadcast (recurse (a %~ b), n)

        (* Converting subtraction to addition *)
        | (Sub, x, IntImm y) -> recurse (x +~ (IntImm (-y)))
        | (Sub, x, UIntImm y) -> recurse (x +~ (UIntImm (-y)))
        | (Sub, x, FloatImm y) -> recurse (x +~ (FloatImm (-.y)))

        (* Convert const + varying to varying + const (reduces the number of cases to check later) *)
        | (Add, x, y) when is_const x -> recurse (y +~ x)
        | (Mul, x, y) when is_const x -> recurse (y *~ x)

        (* Convert divide by float constants to multiplication *)
        | (Div, x, FloatImm y) -> Bop (Mul, x, FloatImm (1.0 /. y))

        (* Ternary expressions that can be reassociated. Previous passes have cut down on the number we need to check. *)
        (* (X + y) + z -> X + (y + z) *)
        | (Add, Bop (Add, x, y), z) when is_const y && is_const z -> recurse (x +~ (y +~ z))
        (* (x - Y) + z -> (x + z) - Y *)
        | (Add, Bop (Sub, x, y), z) when is_const x && is_const z -> recurse ((x +~ z) -~ y)            

        (* Ternary expressions that should be distributed *)
        | (Mul, Bop (Add, x, y), z) when is_const y && is_const z -> recurse ((x *~ z) +~ (y *~ z))     

        (* These particular patterns are commonly generated by lowering, so we should catch and simplify them *)
        | (Max, Bop (Add, x, IntImm a), Bop (Add, y, IntImm b)) when x = y ->
            if a > b then x +~ IntImm a else x +~ IntImm b
        | (Max, x, Bop (Add, y, IntImm a)) 
        | (Max, Bop (Add, x, IntImm a), y) when x = y ->
            if a > 0 then x +~ IntImm a else x
        | (Min, Bop (Add, x, IntImm a), Bop (Add, y, IntImm b)) when x = y ->
            if a < b then x +~ IntImm a else x +~ IntImm b
        | (Min, x, Bop (Add, y, IntImm a)) 
        | (Min, Bop (Add, x, IntImm a), y) when x = y ->
            if a < 0 then x +~ IntImm a else x

        | (Min, x, y)
        | (Max, x, y) when x = y -> x

        | (op, x, y) -> Bop (op, x, y)
      end

    (* comparison *)
    | Cmp (op, a, b) ->
      begin match (recurse a, recurse b) with
        | (IntImm   x, IntImm   y)
        | (UIntImm  x, UIntImm  y) -> UIntImm (if caml_op_of_cmp op x y then 1 else 0)
        | (FloatImm x, FloatImm y) -> UIntImm (if caml_op_of_cmp op x y then 1 else 0)
        | (x, y) -> Cmp (op, x, y)
      end

    (* logical *)
    | And (a, b) ->
      begin match (recurse a, recurse b) with
        | (UIntImm 0, _)
        | (_, UIntImm 0) -> UIntImm 0
        | (UIntImm 1, x)
        | (x, UIntImm 1) -> x
        | (x, y) -> And (x, y)
      end
    | Or (a, b) ->
      begin match (recurse a, recurse b) with
        | (UIntImm 1, _)
        | (_, UIntImm 1) -> UIntImm 1
        | (UIntImm 0, x)
        | (x, UIntImm 0) -> x
        | (x, y) -> Or (x, y)
      end
    | Not a ->
      begin match recurse a with
        | UIntImm 0 -> UIntImm 1
        | UIntImm 1 -> UIntImm 0
        | x -> Not x
      end
    | Select (c, a, b) ->
      begin match (recurse c, recurse a, recurse b) with
        | (_, x, y) when x = y -> x
        | (UIntImm 0, _, x) -> x
        | (UIntImm 1, x, _) -> x
        | (c, x, y) -> Select (c, x, y)
      end
    | Load (t, buf, idx) -> Load (t, buf, recurse idx)
    | MakeVector l -> MakeVector (List.map recurse l)
    | Broadcast (e, n) -> Broadcast (recurse e, n)
    | Ramp (b, s, n) -> Ramp (recurse b, recurse s, n)
    | ExtractElement (a, b) -> ExtractElement (recurse a, recurse b)

    | Debug (e, n, args) -> Debug (recurse e, n, args)

    | Let (n, a, b) -> 
        let a = recurse a and b = recurse b in
        if is_simple a then
          subs_expr (Var (val_type_of_expr a, n)) a b
        else
          Let (n, a, b)

    (* Immediates are unchanged *)
    | x -> x

let rec constant_fold_stmt = function
  | For (var, min, size, order, stmt) ->
      (* Remove trivial for loops *)
      let min = constant_fold_expr min in 
      let size = constant_fold_expr size in
      if size = IntImm 1 or size = UIntImm 1 then
        constant_fold_stmt (subs_stmt (Var (i32, var)) min stmt)
      else
        For (var, min, size, order, constant_fold_stmt stmt)
  | Block l ->
      Block (List.map constant_fold_stmt l)
  | Store (e, buf, idx) ->
      Store (constant_fold_expr e, buf, constant_fold_expr idx)
  | LetStmt (name, value, stmt) ->
      let value = constant_fold_expr value in
      let var = Var (val_type_of_expr value, name) in
      let rec scoped_subs_stmt stmt = match stmt with
        | LetStmt (n, _, _) when n = name -> stmt
        | _ -> mutate_children_in_stmt (subs_expr var value) scoped_subs_stmt stmt
      in
      if (is_simple value) then
        constant_fold_stmt (scoped_subs_stmt stmt)
      else 
        LetStmt (name, value, constant_fold_stmt stmt)
  | Pipeline (n, ty, size, produce, consume) -> 
      Pipeline (n, ty, constant_fold_expr size,
                constant_fold_stmt produce,
                constant_fold_stmt consume)
  | Print (p, l) -> 
      Print (p, List.map constant_fold_expr l)
