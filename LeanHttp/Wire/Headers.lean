import LeanHttp.Wire.Field

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

structure HeaderState where
  headers : List (String × String) := []
  hostSeen : Bool := false
  length : Option Nat := none

def addField (field : ParsedField) (state : HeaderState) (limit : Nat) : Except Response HeaderState := do
  let hostSeen ← if field.name == "host" then do
    if state.hostSeen then throw (bad "Duplicate Host")
    if field.value.isEmpty || field.value.toList.any (fun c =>
        c.toNat <= 32 || c.toNat >= 127 || ",/\\@#?".contains c) then
      throw (bad "Invalid Host")
    pure true
  else pure state.hostSeen
  let length ← if field.name == "content-length" then do
    if state.length.isSome then throw (bad "Duplicate Content-Length")
    pure (some (← contentLength field.value limit))
  else pure state.length
  if field.name == "transfer-encoding" then
    throw (unsupported "Transfer-Encoding is not supported")
  if field.name == "expect" then
    throw (unsupported "Expect is not supported")
  return { headers := (field.name, field.value) :: state.headers, hostSeen, length }

def readFields (lines : List String) (limit : Nat) (state : HeaderState := {}) : Except Response HeaderState :=
  match lines with
  | [] => .ok state
  | line :: rest => do
    let field ← parseField line
    let next ← addField field state limit
    readFields rest limit next

def hostFields (fields : List Spec.Field) : List Spec.Field :=
  fields.filter (fun field => Spec.asciiLower field.name == "host")

def lengthFields (fields : List Spec.Field) : List Spec.Field :=
  fields.filter (fun field => Spec.asciiLower field.name == "content-length")

structure HeaderState.Model (fields : List Spec.Field) (state : HeaderState) (limit : Nat) : Prop where
  validFields : fields.all Spec.Field.valid = true
  headers : state.headers = fields.map (fun field => (Spec.asciiLower field.name, field.value))
  hosts : (hostFields fields).length = if state.hostSeen then 1 else 0
  hostValues : ∀ field ∈ fields, Spec.asciiLower field.name = "host" → Spec.hostValue field.value = true
  lengths : (lengthFields fields).length = if state.length.isSome then 1 else 0
  lengthValues : ∀ field ∈ fields, Spec.asciiLower field.name = "content-length" →
    state.length = some (Spec.decimal field.value) ∧ Spec.digits field.value = true ∧ Spec.decimal field.value <= limit
  extensions : fields.all (fun field =>
    Spec.asciiLower field.name != "transfer-encoding" && Spec.asciiLower field.name != "expect") = true

theorem HeaderState.empty_model (limit : Nat) : HeaderState.Model [] {} limit := by
  constructor <;> simp [hostFields, lengthFields]

theorem hostValue_error (value : String) :
    (value.isEmpty || value.toList.any (fun c =>
      c.toNat <= 32 || c.toNat >= 127 || ",/\\@#?".contains c)) = !Spec.hostValue value := by
  simp only [Spec.hostValue, Bool.not_and, Bool.not_not, List.not_all_eq_any_not]
  congr 2
  funext c
  apply Bool.eq_iff_iff.mpr
  have full : ",/\\@#?".toList = [',', '/', '\\', '@', '#', '?'] := by decide
  have restricted : ",/\\@?".toList = [',', '/', '\\', '@', '?'] := by decide
  simp [Spec.targetChar, String.contains_char_eq, List.contains_eq_mem, full, restricted]
  simp only [or_assoc, or_left_comm, or_comm]

theorem addField_model (field : Spec.Field) (fields : List Spec.Field)
    (state result : HeaderState) (limit : Nat) (model : HeaderState.Model fields state limit)
    (valid : field.valid = true)
    (accepted : addField { name := Spec.asciiLower field.name, value := field.value } state limit = .ok result) :
    HeaderState.Model (field :: fields) result limit := by
  by_cases host : Spec.asciiLower field.name = "host"
  · simp [addField, host, Bind.bind, Except.bind, Pure.pure, Except.pure] at accepted
    split at accepted
    next duplicate => cases accepted
    next fresh =>
      split at accepted
      next invalid => cases accepted
      next hostOk =>
        have goodHost : Spec.hostValue field.value = true := by
          have noError : (field.value.isEmpty || field.value.toList.any (fun c =>
            c.toNat <= 32 || c.toNat >= 127 || ",/\\@#?".contains c)) = false := by simpa using hostOk
          rw [hostValue_error] at noError
          simpa only [Bool.not_eq_false'] using noError
        cases Except.ok.inj accepted
        constructor
        · simp [valid, model.validFields]
        · simp [model.headers, host]
        · have counted := model.hosts
          simp [hostFields, host, fresh] at counted ⊢
          omega
        · intro f member isHost
          rcases List.mem_cons.mp member with rfl | member
          · exact goodHost
          · exact model.hostValues f member isHost
        · simpa [lengthFields, host] using model.lengths
        · intro f member isLength
          rcases List.mem_cons.mp member with rfl | member
          · simp [host] at isLength
          · exact model.lengthValues f member isLength
        · simpa [host] using model.extensions
  · by_cases length : Spec.asciiLower field.name = "content-length"
    · simp [addField, length, Bind.bind, Except.bind, Pure.pure, Except.pure] at accepted
      split at accepted
      next duplicate => cases accepted
      next fresh =>
        have empty : state.length = none := by simpa using fresh
        split at accepted
        next error rejected => cases accepted
        next n decoded =>
          have number := (contentLength_ok_iff field.value limit n).mp decoded
          cases Except.ok.inj accepted
          constructor
          · simp [valid, model.validFields]
          · simp [model.headers, length]
          · simpa [hostFields, length] using model.hosts
          · intro f member isHost
            rcases List.mem_cons.mp member with rfl | member
            · simp [length] at isHost
            · exact model.hostValues f member isHost
          · have counted := model.lengths
            simp [lengthFields, empty, length] at counted ⊢
            omega
          · intro f member isLength
            rcases List.mem_cons.mp member with rfl | member
            · exact ⟨congrArg some number.2.1.symm, number.1, by omega⟩
            · have old := (model.lengthValues f member isLength).1
              simp [empty] at old
          · simpa [length] using model.extensions
    · by_cases transfer : Spec.asciiLower field.name = "transfer-encoding"
      · simp [addField, transfer, Bind.bind, Except.bind] at accepted
        cases accepted
      · by_cases expect : Spec.asciiLower field.name = "expect"
        · simp [addField, expect, Bind.bind, Except.bind] at accepted
          cases accepted
        · simp [addField, host, length, transfer, expect, Bind.bind, Except.bind,
            Pure.pure, Except.pure] at accepted
          cases accepted
          constructor
          · simp [valid, model.validFields]
          · simp [model.headers]
          · simpa [hostFields, host] using model.hosts
          · intro f member isHost
            rcases List.mem_cons.mp member with rfl | member
            · contradiction
            · exact model.hostValues f member isHost
          · simpa [lengthFields, length] using model.lengths
          · intro f member isLength
            rcases List.mem_cons.mp member with rfl | member
            · contradiction
            · exact model.lengthValues f member isLength
          · simpa [transfer, expect] using model.extensions

theorem readFields_source (lines : List String) (fields : List Spec.Field)
    (state result : HeaderState) (limit : Nat) (model : HeaderState.Model fields state limit)
    (accepted : readFields lines limit state = .ok result) :
    ∃ parsed : List Spec.Field, lines = parsed.map Spec.Field.line ∧
      HeaderState.Model (parsed.reverse ++ fields) result limit := by
  induction lines generalizing fields state with
  | nil =>
    cases Except.ok.inj accepted
    exact ⟨[], rfl, by simpa using model⟩
  | cons line rest ih =>
    simp only [readFields, Bind.bind, Except.bind] at accepted
    split at accepted
    next error failed => cases accepted
    next decoded decodedOk =>
      obtain ⟨field, valid, textEq, nameEq, valueEq⟩ := parseField_source _ _ decodedOk
      have lineEq : field.line = line := by simpa only [Spec.Field.text, String.append_left_inj] using textEq
      have decodedEq : decoded = { name := Spec.asciiLower field.name, value := field.value } := by
        cases decoded
        simp_all
      split at accepted
      next error failed => cases accepted
      next nextState nextOk =>
        have nextModel := addField_model field fields state nextState limit model valid (decodedEq ▸ nextOk)
        obtain ⟨parsed, source, finalModel⟩ := ih (field :: fields) nextState nextModel accepted
        refine ⟨field :: parsed, ?_, ?_⟩
        · simp only [List.map_cons, ← lineEq, source]
        · simpa only [List.reverse_cons, List.append_assoc, List.singleton_append] using finalModel

theorem addField_accepts (field : Spec.Field) (state : HeaderState) (limit : Nat)
    (hostAllowed : Spec.asciiLower field.name = "host" → state.hostSeen = false ∧ Spec.hostValue field.value = true)
    (lengthAllowed : Spec.asciiLower field.name = "content-length" → state.length = none ∧
      Spec.digits field.value = true ∧ Spec.decimal field.value <= limit)
    (noTransfer : Spec.asciiLower field.name ≠ "transfer-encoding")
    (noExpect : Spec.asciiLower field.name ≠ "expect") :
    ∃ next, addField { name := Spec.asciiLower field.name, value := field.value } state limit = .ok next := by
  refine ⟨{
    headers := (Spec.asciiLower field.name, field.value) :: state.headers
    hostSeen := if Spec.asciiLower field.name == "host" then true else state.hostSeen
    length := if Spec.asciiLower field.name == "content-length" then some (Spec.decimal field.value) else state.length }, ?_⟩
  by_cases host : Spec.asciiLower field.name = "host"
  · obtain ⟨fresh, valid⟩ := hostAllowed host
    have noError : (field.value.isEmpty || field.value.toList.any (fun c =>
        c.toNat <= 32 || c.toNat >= 127 || ",/\\@#?".contains c)) = false := by
      rw [hostValue_error, valid]
      rfl
    simp only [addField, host, beq_self_eq_true, ↓reduceIte, fresh, Bool.false_eq_true, noError]
    simp [Bind.bind, Except.bind, Pure.pure, Except.pure]
  · by_cases length : Spec.asciiLower field.name = "content-length"
    · obtain ⟨fresh, digits, fits⟩ := lengthAllowed length
      have decoded := (contentLength_ok_iff field.value limit (Spec.decimal field.value)).mpr ⟨digits, rfl, fits⟩
      simp [addField, length, fresh, decoded, Bind.bind, Except.bind, Pure.pure, Except.pure]
    · simp [addField, host, length, noTransfer, noExpect, Bind.bind, Except.bind, Pure.pure, Except.pure]

theorem readFields_complete (fields previous : List Spec.Field)
    (state : HeaderState) (limit : Nat) (model : HeaderState.Model previous state limit)
    (possible : ∃ finalState, HeaderState.Model (fields.reverse ++ previous) finalState limit) :
    ∃ result, readFields (fields.map Spec.Field.line) limit state = .ok result ∧
      HeaderState.Model (fields.reverse ++ previous) result limit := by
  induction fields generalizing previous state with
  | nil => exact ⟨state, rfl, by simpa using model⟩
  | cons field fields ih =>
    obtain ⟨finalState, finalModel⟩ := possible
    have member : field ∈ (field :: fields).reverse ++ previous := by simp
    have valid : field.valid = true := List.all_eq_true.mp finalModel.validFields field member
    have hostAllowed : Spec.asciiLower field.name = "host" →
        state.hostSeen = false ∧ Spec.hostValue field.value = true := by
      intro host
      refine ⟨?_, finalModel.hostValues field member host⟩
      have past := model.hosts
      have total : (hostFields ((field :: fields).reverse ++ previous)).length <= 1 := by
        rw [finalModel.hosts]
        split <;> omega
      simp only [hostFields, List.filter_append, List.filter_reverse, List.reverse_cons,
        List.filter_cons, List.filter_nil, host, beq_self_eq_true, ↓reduceIte,
        List.length_append, List.length_reverse, List.length_cons, List.length_nil] at total past
      cases h : state.hostSeen
      · rfl
      · simp only [h, ↓reduceIte] at past
        omega
    have lengthAllowed : Spec.asciiLower field.name = "content-length" → state.length = none ∧
        Spec.digits field.value = true ∧ Spec.decimal field.value <= limit := by
      intro length
      obtain ⟨_, digits, fits⟩ := finalModel.lengthValues field member length
      refine ⟨?_, digits, fits⟩
      have past := model.lengths
      have total : (lengthFields ((field :: fields).reverse ++ previous)).length <= 1 := by
        rw [finalModel.lengths]
        split <;> omega
      simp only [lengthFields, List.filter_append, List.filter_reverse, List.reverse_cons,
        List.filter_cons, List.filter_nil, length, beq_self_eq_true, ↓reduceIte,
        List.length_append, List.length_reverse, List.length_cons, List.length_nil] at total past
      cases h : state.length with
      | none => rfl
      | some n =>
        simp only [h, Option.isSome_some, ↓reduceIte] at past
        omega
    have extensions := List.all_eq_true.mp finalModel.extensions field member
    have ⟨noTransfer, noExpect⟩ : Spec.asciiLower field.name ≠ "transfer-encoding" ∧
        Spec.asciiLower field.name ≠ "expect" := by simpa using extensions
    obtain ⟨next, nextOk⟩ := addField_accepts field state limit hostAllowed lengthAllowed noTransfer noExpect
    have nextModel := addField_model field previous state next limit model valid nextOk
    have possibleRest : ∃ s, HeaderState.Model (fields.reverse ++ field :: previous) s limit := by
      refine ⟨finalState, ?_⟩
      simpa only [List.reverse_cons, List.append_assoc, List.singleton_append] using finalModel
    obtain ⟨result, resultOk, resultModel⟩ := ih (field :: previous) next nextModel possibleRest
    refine ⟨result, ?_, ?_⟩
    · simp only [List.map_cons, readFields, Spec.Field.line,
        parseField_complete field valid, nextOk, Bind.bind, Except.bind, resultOk]
    · simpa only [List.reverse_cons, List.append_assoc, List.singleton_append] using resultModel

theorem model_of_form (form : Spec.RequestForm) (limit : Nat) (valid : form.Valid limit) :
    ∃ state, HeaderState.Model form.fields.reverse state (limit - form.header.toUTF8.size) := by
  have facts := valid
  simp only [Spec.RequestForm.Valid, Spec.RequestForm.valid, Bool.and_eq_true,
    decide_eq_true_eq, beq_iff_eq] at facts
  obtain ⟨⟨⟨⟨⟨⟨_, validFields⟩, hostCount⟩, hostValues⟩, framed⟩, extensions⟩, fits⟩ := facts
  have budget : form.body.toUTF8.size <= limit - form.header.toUTF8.size := by
    simp only [Spec.RequestForm.bytes, ByteArray.size_append] at fits
    omega
  have hosts : (hostFields form.fields).length = 1 := hostCount
  have reversedHosts : hostFields form.fields.reverse = (hostFields form.fields).reverse := by
    simp [hostFields, List.filter_reverse]
  have reversedLengths : lengthFields form.fields.reverse = (lengthFields form.fields).reverse := by
    simp [lengthFields, List.filter_reverse]
  have hostValues' : ∀ f ∈ form.fields.reverse, Spec.asciiLower f.name = "host" → Spec.hostValue f.value = true := by
    intro f mem name
    exact List.all_eq_true.mp hostValues f
      (List.mem_filter.mpr ⟨List.mem_reverse.mp mem, by simp [name]⟩)
  change (match lengthFields form.fields with
    | [] => form.body.isEmpty
    | [f] => Spec.digits f.value && Spec.decimal f.value == form.body.toUTF8.size
    | _ => false) = true at framed
  cases lengths : lengthFields form.fields with
  | nil =>
    refine ⟨{
      headers := form.fields.reverse.map (fun f => (Spec.asciiLower f.name, f.value)),
      hostSeen := true, length := none }, ?_⟩
    constructor
    · simpa using validFields
    · rfl
    · change (hostFields form.fields.reverse).length = 1
      rw [reversedHosts, List.length_reverse, hosts]
    · exact hostValues'
    · change (lengthFields form.fields.reverse).length = 0
      rw [reversedLengths, lengths]
      rfl
    · intro f mem name
      have member : f ∈ lengthFields form.fields := List.mem_filter.mpr
        ⟨List.mem_reverse.mp mem, by simp [name]⟩
      simp [lengths] at member
    · simpa using extensions
  | cons f rest =>
    cases rest with
    | nil =>
      simp only [lengths, Bool.and_eq_true, beq_iff_eq] at framed
      refine ⟨{
        headers := form.fields.reverse.map (fun f => (Spec.asciiLower f.name, f.value)),
        hostSeen := true, length := some (Spec.decimal f.value) }, ?_⟩
      constructor
      · simpa using validFields
      · rfl
      · change (hostFields form.fields.reverse).length = 1
        rw [reversedHosts, List.length_reverse, hosts]
      · exact hostValues'
      · change (lengthFields form.fields.reverse).length = 1
        rw [reversedLengths, lengths]
        rfl
      · intro g mem name
        have member : g ∈ lengthFields form.fields := List.mem_filter.mpr
          ⟨List.mem_reverse.mp mem, by simp [name]⟩
        have same : g = f := by simpa [lengths] using member
        subst same
        exact ⟨rfl, framed.1, by omega⟩
      · simpa using extensions
    | cons g rest => simp [lengths] at framed

theorem readFields_form_complete (form : Spec.RequestForm) (limit : Nat) (valid : form.Valid limit) :
    ∃ result, readFields (form.fields.map Spec.Field.line) (limit - form.header.toUTF8.size) {} = .ok result ∧
      HeaderState.Model form.fields.reverse result (limit - form.header.toUTF8.size) := by
  obtain ⟨state, model⟩ := model_of_form form limit valid
  obtain ⟨result, parsed, resultModel⟩ := readFields_complete form.fields [] {} _
    (HeaderState.empty_model _) ⟨state, by simpa using model⟩
  exact ⟨result, parsed, by simpa using resultModel⟩

theorem HeaderState.Model.bodyLength (form : Spec.RequestForm) (requestLimit bodyLimit : Nat)
    (state : HeaderState) (valid : form.Valid requestLimit)
    (model : HeaderState.Model form.fields.reverse state bodyLimit) :
    state.length.getD 0 = form.body.toUTF8.size := by
  have facts := valid
  simp only [Spec.RequestForm.Valid, Spec.RequestForm.valid, Bool.and_eq_true] at facts
  have framed := facts.1.1.2
  change (match lengthFields form.fields with
    | [] => form.body.isEmpty
    | [f] => Spec.digits f.value && Spec.decimal f.value == form.body.toUTF8.size
    | _ => false) = true at framed
  cases lengths : lengthFields form.fields with
  | nil =>
    have counted := model.lengths
    have reversed : lengthFields form.fields.reverse = (lengthFields form.fields).reverse := by
      simp [lengthFields, List.filter_reverse]
    rw [reversed, lengths] at counted
    have empty : state.length = none := by
      cases h : state.length with
      | none => rfl
      | some n => simp [h] at counted
    have bodyEmpty : form.body = "" := by simpa [lengths] using framed
    simp [empty, bodyEmpty]
  | cons f rest =>
    cases rest with
    | nil =>
      have member : f ∈ lengthFields form.fields := by rw [lengths]; simp
      obtain ⟨member, name⟩ := List.mem_filter.mp member
      have declared := (model.lengthValues f (List.mem_reverse.mpr member) (beq_iff_eq.mp name)).1
      rw [declared]
      have number : Spec.digits f.value = true ∧ Spec.decimal f.value = form.body.toUTF8.size := by
        simpa [lengths] using framed
      exact number.2
    | cons g rest => simp [lengths] at framed

end LeanHttp.Wire.Internal
