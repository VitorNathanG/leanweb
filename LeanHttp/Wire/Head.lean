import LeanHttp.Wire.Headers
import LeanHttp.Wire.Lines
import LeanHttp.Wire.Target

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

private theorem intercalate_terminated (separator first : String) (rest : List String) :
    String.intercalate separator (first :: rest) ++ separator =
      first ++ separator ++ String.join (rest.map (· ++ separator)) := by
  induction rest generalizing first with
  | nil => simp
  | cons next rest ih =>
    simpa only [String.intercalate_cons_cons, List.map_cons, String.join_cons, String.append_assoc] using
      congrArg (fun tail => first ++ separator ++ tail) (ih next)

theorem form_header_text (form : Spec.RequestForm) :
    form.header = String.intercalate "\r\n"
      ((Spec.methodText form.method ++ " " ++ form.target.text ++ " HTTP/1.1") ::
        form.fields.map Spec.Field.line) ++ "\r\n\r\n" := by
  have joined := intercalate_terminated "\r\n"
    (Spec.methodText form.method ++ " " ++ form.target.text ++ " HTTP/1.1")
    (form.fields.map Spec.Field.line)
  have terminated := congrArg (· ++ "\r\n") joined
  unfold Spec.RequestForm.header
  rw [show Spec.Field.text = (fun field => field.line ++ "\r\n") from rfl,
    show " HTTP/1.1\r\n" = " HTTP/1.1" ++ "\r\n" from rfl,
    show "\r\n\r\n" = "\r\n" ++ "\r\n" from rfl]
  simpa only [List.map_map, Function.comp_def, String.append_assoc] using terminated.symm

theorem field_line_noCR (field : Spec.Field) (valid : field.valid = true) :
    '\r' ∉ field.line.toList := by
  have properties : field.name ≠ "" ∧ field.name.toList.all Spec.token = true ∧
      Spec.fieldValue field.value = true ∧ Spec.trimOWS field.value = field.value ∧
      field.leading.toList.all Spec.ows = true ∧ field.trailing.toList.all Spec.ows = true := by
    simpa [Spec.Field.valid, Bool.and_assoc] using valid
  intro member
  simp only [Spec.Field.line, String.toList_append, List.mem_append, or_assoc] at member
  rcases member with name | colon | leading | value | trailing
  · have := List.all_eq_true.mp properties.2.1 '\r' name
    contradiction
  · contradiction
  · have := List.all_eq_true.mp properties.2.2.2.2.1 '\r' leading
    contradiction
  · have := List.all_eq_true.mp properties.2.2.1 '\r' value
    contradiction
  · have := List.all_eq_true.mp properties.2.2.2.2.2 '\r' trailing
    contradiction

private theorem targetChars_noCR (text : String) (valid : text.toList.all Spec.targetChar = true) :
    '\r' ∉ text.toList := by
  intro member
  have := List.all_eq_true.mp valid '\r' member
  contradiction

theorem target_text_noCR (target : Spec.Target) (method : Method) (valid : target.valid method = true) :
    '\r' ∉ target.text.toList := by
  cases target with
  | asterisk => decide
  | origin path query =>
    simp only [Spec.Target.valid, Bool.and_eq_true] at valid
    have pathClean := targetChars_noCR path valid.1.2
    cases query with
    | none => exact pathClean
    | some query =>
      have queryClean := targetChars_noCR query valid.2
      simp [Spec.Target.text, String.toList_append, pathClean, queryClean]

theorem splitLines_form (form : Spec.RequestForm) (limit : Nat) (valid : form.Valid limit) :
    splitLines (String.intercalate "\r\n"
      ((Spec.methodText form.method ++ " " ++ form.target.text ++ " HTTP/1.1") ::
        form.fields.map Spec.Field.line)) =
      (Spec.methodText form.method ++ " " ++ form.target.text ++ " HTTP/1.1") ::
        form.fields.map Spec.Field.line := by
  have facts := valid
  simp only [Spec.RequestForm.Valid, Spec.RequestForm.valid, Bool.and_eq_true] at facts
  have targetValid := facts.1.1.1.1.1.1
  have fieldsValid := facts.1.1.1.1.1.2
  apply splitLines_intercalate _ (by simp)
  intro line member
  rcases List.mem_cons.mp member with rfl | member
  · have methodClean : '\r' ∉ (Spec.methodText form.method).toList := by cases form.method <;> decide
    have targetClean := target_text_noCR form.target form.method targetValid
    simp [String.toList_append, methodClean, targetClean]
  · obtain ⟨field, mem, rfl⟩ := List.mem_map.mp member
    exact field_line_noCR field (List.all_eq_true.mp fieldsValid field mem)

structure ParsedHead where
  method : Method
  target : String
  headers : List (String × String)
  length : Nat

def parseHead (header : String) (bodyLimit : Nat) : Except Response ParsedHead := do
  let requestLine :: headerLines := splitLines header | throw (bad "Missing request line")
  let { method, target } ← parseStartLine requestLine
  let { headers, hostSeen, length } ← readFields headerLines bodyLimit
  if !hostSeen then throw (bad "Missing Host")
  return { method, target, headers := headers.reverse, length := length.getD 0 }

theorem parseHead_source (header : String) (bodyLimit : Nat) (result : ParsedHead)
    (parsed : parseHead header bodyLimit = .ok result) :
    ∃ (line : String) (fields : List Spec.Field) (state : HeaderState),
      splitLines header = line :: fields.map Spec.Field.line ∧
      parseStartLine line = .ok { method := result.method, target := result.target } ∧
      HeaderState.Model fields.reverse state bodyLimit ∧ state.hostSeen = true ∧
      result.headers = state.headers.reverse ∧ result.length = state.length.getD 0 := by
  unfold parseHead at parsed
  split at parsed
  next line lines splitEq =>
    simp only [Bind.bind, Except.bind, Pure.pure, Except.pure] at parsed
    split at parsed
    next error rejected => cases parsed
    next start startOk =>
      split at parsed
      next error rejected => cases parsed
      next state stateOk =>
        split at parsed
        next missing => cases parsed
        next hostPresent =>
          cases Except.ok.inj parsed
          obtain ⟨fields, fieldLines, model⟩ := readFields_source lines [] {} state bodyLimit
            (HeaderState.empty_model _) stateOk
          refine ⟨line, fields, state, ?_, ?_, ?_, ?_, rfl, rfl⟩
          · rw [← fieldLines]
            exact splitEq
          · cases start
            exact startOk
          · simpa using model
          · simpa using hostPresent
  next missing => cases parsed

theorem parseHead_form_complete (form : Spec.RequestForm) (limit : Nat) (valid : form.Valid limit) :
    parseHead (String.intercalate "\r\n"
      ((Spec.methodText form.method ++ " " ++ form.target.text ++ " HTTP/1.1") ::
        form.fields.map Spec.Field.line)) (limit - form.header.toUTF8.size) =
      .ok {
        method := form.method, target := form.target.text,
        headers := form.fields.map (fun f => (Spec.asciiLower f.name, f.value)),
        length := form.body.toUTF8.size } := by
  have facts := valid
  simp only [Spec.RequestForm.Valid, Spec.RequestForm.valid, Bool.and_eq_true] at facts
  have targetValid := facts.1.1.1.1.1.1
  have hostCount := facts.1.1.1.1.2
  have startOk := parseStartLine_complete form.method form.target.text (target_check _ _ targetValid)
  obtain ⟨state, stateOk, model⟩ := readFields_form_complete form limit valid
  have present : state.hostSeen = true := by
    have counted := model.hosts
    have reversed : hostFields form.fields.reverse = (hostFields form.fields).reverse := by
      simp [hostFields, List.filter_reverse]
    rw [reversed, List.length_reverse] at counted
    change ((hostFields form.fields).length == 1) = true at hostCount
    have count : (hostFields form.fields).length = 1 := beq_iff_eq.mp hostCount
    rw [count] at counted
    cases h : state.hostSeen
    · simp only [h, Bool.false_eq_true, ↓reduceIte] at counted
      contradiction
    · rfl
  have headers := congrArg List.reverse model.headers
  simp only [← List.map_reverse, List.reverse_reverse] at headers
  have length := HeaderState.Model.bodyLength form limit _ state valid model
  unfold parseHead
  rw [splitLines_form form limit valid]
  simp only [startOk, Bind.bind, Except.bind, stateOk, present, Bool.not_true,
    Bool.false_eq_true, ↓reduceIte, Pure.pure, Except.pure, headers, length]

end LeanHttp.Wire.Internal
