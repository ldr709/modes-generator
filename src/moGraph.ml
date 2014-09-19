open Core.Std
open MoOps
module MoInst = MoInstructions

module E = struct
  type t = Int.Set.t
  let compare = Int.Set.compare
  let default = Int.Set.empty
end
module V = struct type t = MoOps.instruction end
module G = Graph.Imperative.Digraph.AbstractLabeled(V)(E)

let string_of_e e =
  let l = G.E.label e |> Int.Set.to_list in
  List.to_string Int.to_string l

(* Maintain separate vertex and edge orderings so we can correctly traverse in
   order. We also need pointers to the out node in init and block, as these are
   needed in the decryptability check. *)
type t = { g : G.t; v : G.V.t list; e : G.E.t list; out_init : G.V.t;
           out_block : G.V.t }

let create init block =
  let s = Stack.create () in
  let g = G.create () in
  let vl = ref [] in
  let el = ref [] in
  let f inst =
    match inst with
    | Instruction i ->
       let dst = G.V.create i in
       G.add_vertex g dst;
       vl := List.append !vl [dst];
       for j = 1 to MoInst.n_in inst do
         let src = Stack.pop_exn s in
         let e = G.E.create src Int.Set.empty dst in
         G.add_edge_e g e;
         el := List.append !el [e];
       done;
       for j = 1 to MoInst.n_out inst do
         Stack.push s dst
       done
    | StackInstruction i ->
       begin
         match i with
         | Swap ->
            let first = Stack.pop_exn s in
            let second = Stack.pop_exn s in
            Stack.push s first;
            Stack.push s second
         | Twoswap ->
            let first = Stack.pop_exn s in
            let second = Stack.pop_exn s in
            let third = Stack.pop_exn s in
            Stack.push s first;
            Stack.push s second;
            Stack.push s third
       end
  in
  List.iter init f;
  let out_init = List.find_exn !vl ~f:(fun v -> G.V.label v = Out) in
  List.iter block f;
  let out_block = List.find_exn (List.rev !vl) ~f:(fun v -> G.V.label v = Out) in
  let t = { g = g; v = !vl; e = !el; out_init = out_init;
            out_block = out_block } in
  t

let display_with_feh t =
  let module Display = struct
    include G
    let ctr = ref 1
    let vertex_name v =
      let c =
        if Mark.get v = 0
        then begin
          Mark.set v !ctr;
          ctr := !ctr + 1;
          Mark.get v
        end
        else Mark.get v in
      Printf.sprintf "%s_%d" (MoInst.string_of_t (Instruction (V.label v))) c
    let graph_attributes _ = []
    let default_vertex_attributes _ = []
    let vertex_attributes _ = []
    let default_edge_attributes _ = []
    let edge_attributes e = [`Label (string_of_e e)]
    let get_subgraph _ = None
  end in
  let module Dot = Graph.Graphviz.Dot(Display) in
  let tmp = Filename.temp_file "mode" ".dot" in
  G.Mark.clear t.g;
  let oc = Out_channel.create tmp in
  Dot.output_graph oc t.g;
  Out_channel.close oc;
  ignore (Sys.command ("dot -Tpng " ^ tmp ^ " | feh -"));
  Sys.remove tmp

exception AssignFamiliesException

let assign_families t =
  Log.infof "Assigning families to graph...";
  let replace_edge e set =
    G.remove_edge_e t.g e;
    let e = G.E.create (G.E.src e) set (G.E.dst e) in
    Log.debugf "    Families = %s" (string_of_e e);
    G.add_edge_e t.g e
  in
  let parents e = G.E.src e |> G.pred_e t.g in
  let parent e = parents e |> List.hd_exn in
  let fam_cnt = ref 0 in
  let f e =
    let label = G.E.src e |> G.V.label in
    Log.debugf "  Hit edge %s -> %s"
      ((MoOps.Instruction label) |> MoInst.string_of_t)
      ((MoOps.Instruction (G.E.dst e |> G.V.label)) |> MoInst.string_of_t);
    match label with
    | Dup | Inc | Nextiv_init ->
      let e' = parent e in
      replace_edge e (G.E.label e')
    | Genrand | M | Prf | Prp | Start ->
      let set = Int.Set.singleton !fam_cnt in
      fam_cnt := !fam_cnt + 1;
      replace_edge e set
    | Xor ->
      let elist = parents e in
      let l = List.hd_exn elist in
      let r = List.last_exn elist in
      let inter = Int.Set.inter (G.E.label l) (G.E.label r) in
      if Int.Set.length inter <> 0 then
        raise AssignFamiliesException;
      let fam = Int.Set.union (G.E.label l) (G.E.label r) in
      replace_edge e fam
    | Nextiv_block | Out ->
      failwith "should not reach here!"
  in
  List.iter t.e f;
  t

let validate t =
  Log.infof "Validating graph...";
  let smt = MoSmt.create () in
  let f v =
    Log.debugf "  Hit %s" ((MoOps.Instruction (G.V.label v)) |> MoInst.string_of_t);
    MoSmt.op smt (G.V.label v) in
  List.iter t.v f;
  MoSmt.finalize smt;
  let fname = Filename.temp_file "z3" ".smt2" in
  MoSmt.write_to_file smt fname;
  let result = MoSmt.run fname in
  Sys.remove fname;
  result

type dir = Forward | Backward
let string_of_dir = function
  | Forward -> "Forward"
  | Backward -> "Backward"

(* Checks whether a graph is decryptable *)
let is_decryptable t =
  Log.debugf "Checking decryptability...";
  let replace_edge e label =
    G.remove_edge_e t.g e;
    let e = G.E.create (G.E.src e) label (G.E.dst e) in
    G.add_edge_e t.g e
  in
  let get_parent_edges v = G.pred_e t.g v in
  let get_parent_edge v =
    let l = get_parent_edges v in
    assert (List.length l = 1);
    List.hd_exn l
  in
  let get_child_edges v = G.succ_e t.g v in
  let get_child_edge v =
    let l = get_child_edges v in
    assert (List.length l = 1);
    List.hd_exn l
  in
  let get_parent_vertices v = G.pred t.g v in
  let get_parent_vertex v =
    let l = get_parent_vertices v in
    assert (List.length l = 1);
    List.hd_exn l
  in
  let get_child_vertices v = G.succ t.g v in
  let get_child_vertex v =
    let l = get_child_vertices v in
    assert (List.length l = 1);
    List.hd_exn l
  in
  (* Returns all edges touching 'cur' except the cur-prev edge *)
  let get_edges cur prev =
    let l = List.append (G.succ_e t.g cur) (G.pred_e t.g cur) in
    List.filter l ~f:(fun e -> ((G.E.src e = cur && G.E.dst e = prev) ||
                                (G.E.src e = prev && G.E.dst e = cur)) |> not)
  in
  let get_edge cur prev =
    let l = get_edges cur prev in
    assert (List.length l = 1);
    List.hd_exn l
  in
  let edge_to_item e cur prev =
    let src = G.E.src e in
    let dst = G.E.dst e in
    if src = cur then
      (dst, src, Forward)
    else
      (src, dst, Backward)
  in
  let set_edge e =
    let set = Int.Set.singleton 1 in
    replace_edge e set
  in
  let is_edge_set e =
    Int.Set.compare (G.E.label e) Int.Set.empty <> 0
  in
  let step cur prev dir =
    (* check if edge(s) already set; if so, ignore *)
    if match G.V.label cur with
      | Dup | Xor ->
        let l = List.append (G.succ_e t.g cur) (G.pred_e t.g cur) in
        List.for_all l ~f:is_edge_set
      | Genrand | M | Nextiv_block | Nextiv_init | Out | Start -> false
      | Inc | Prf | Prp ->
        let l = (match dir with
            | Forward -> get_child_edges
            | Backward -> get_parent_edges) cur in
        List.for_all l ~f:is_edge_set
    then
      []
    else
      match G.V.label cur with
      | Dup ->
        let l = get_edges cur prev in
        List.iter l ~f:(fun e -> set_edge e);
        List.map l ~f:(fun e -> edge_to_item e cur prev)
      | Genrand | M ->
        assert (dir = Backward);
        []
      | Nextiv_block | Nextiv_init ->
        assert (dir = Forward);
        []
      | Out ->
        let _ = get_parent_edge cur |> set_edge in
        [(get_parent_vertex cur, cur, Backward)]
      | Prf -> begin
          match dir with
          | Forward -> [edge_to_item (get_edge cur prev) cur prev]
          | Backward -> []
        end
      | Inc | Prp ->
        [edge_to_item (get_edge cur prev) cur prev]
      | Start ->
        assert (dir = Forward);
        let _ = get_child_edge cur |> set_edge in
        [(get_child_vertex cur, cur, Forward)]
      | Xor ->
        let l = get_edges cur prev in
        assert (List.length l = 2);
        (* How many other edges are set?  If one, then we have enough info
           to traverse down the unset edge. *)
        if List.count l ~f:(fun e -> is_edge_set e) = 1 then
          (* Find the unset edge *)
          let e = List.find_exn l ~f:(fun e -> is_edge_set e |> not) in
          set_edge e;
          [edge_to_item e cur dir]
        else
          []
  in
  (* find label 'label' in graph t.g *)
  let find label =
    let f x y = if (G.V.label x) = label then x :: y else y in
    let l = G.fold_vertex f t.g [] in
    assert (List.length l = 1);
    List.hd_exn l
  in
  let start = find Start in
  let m = find M in
  let nextiv_block = find Nextiv_block in
  let nextiv_init = find Nextiv_init in
  let out_block = t.out_block in
  let out_init = t.out_init in
  let block_array = [(start, start, Forward);
                     (out_block, out_block, Backward)] in
  let rec run array =
    let f l i =
      let cur, prev, dir = i in
      Log.debugf "  %s %s %s"
        (MoInst.string_of_t (Instruction (G.V.label cur)))
        (MoInst.string_of_t (Instruction (G.V.label prev)))
        (string_of_dir dir);
      List.append l (step cur prev dir)
    in
    if List.is_empty array then ()
    else run (List.fold_left array ~init:[] ~f:f)
  in
  (* Clear info on edges *)
  G.iter_edges_e (fun e -> replace_edge e Int.Set.empty) t.g;
  run block_array;
  let is_m_set = get_child_edge m |> is_edge_set in
  Log.debugf "    Is M set? %b" is_m_set;
  let r = if is_m_set then
      let is_nextiv_block_set = get_parent_edge nextiv_block |> is_edge_set in
      Log.debugf "    Is Nextiv_block set? %b" is_nextiv_block_set;
      let init_array = [(out_init, out_init, Backward)] in
      run init_array;
      let is_nextiv_init_set = get_parent_edge nextiv_init |> is_edge_set in
      Log.debugf "    Is Nextiv_init set? %b" is_nextiv_init_set;
      is_nextiv_block_set && is_nextiv_init_set
    else
      false in
  Log.debugf "Result: %b" r;
  (* Clear info on edges *)
  G.iter_edges_e (fun e -> replace_edge e Int.Set.empty) t.g;
  r

exception Vertex of G.V.t

let is_connected t =
  let module H = Caml.Hashtbl.Make(G.V) in
  let h = H.create 65537 in
  let rec visit s =
    match Stack.pop s with
      | None -> ()
      | Some v ->
        if not (H.mem h v) then begin
          H.add h v ();
          G.iter_succ (Stack.push s) t.g v;
          G.iter_pred (Stack.push s) t.g v
        end;
        visit s
  in
  let s = Stack.create () in
  let v =
    try
      List.iter t.v (fun v -> raise (Vertex v));
      raise Not_found
    with Vertex v -> v
  in
  Stack.push s v;
  visit s;
  try
    let f v = if not (H.mem h v) then raise Exit in
    List.iter t.v f;
    true
  with Exit ->
    Log.infof "Is not connected!";
    false

let has_right_nodes t =
  let prp_or_prf =
    (List.exists t.v (fun v -> G.V.label v = Prp))
    || (List.exists t.v (fun v -> G.V.label v = Prf))
  in
  let has inst num = List.count t.v (fun v -> G.V.label v = inst) = num in
  prp_or_prf
  && has M 1
  && has Start 1
  && has Out 2                  (* one in Init and Block each *)
  && has Nextiv_init 1
  && has Nextiv_block 1
  && has Genrand 1              (* one in Init, none in Block *)

let is_start_location_valid t =
  let f e =
    if G.E.src e |> G.V.label = Nextiv_init
       && G.E.dst e |> G.V.label <> Start then
      begin
        Log.infof "start location invalid!";
        raise Exit
      end
  in
  try List.iter t.e f; true with Exit -> false

let is_valid t = is_start_location_valid t && has_right_nodes t && is_connected t

let is_secure t =
  try
    assign_families t |> validate
  with AssignFamiliesException -> false
