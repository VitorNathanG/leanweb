import LeanHttp.Wire.Basic

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

theorem tokenChar_eq_spec (c : Char) : tokenChar c = Spec.token c := by
  simp only [tokenChar, asciiAlphaNum, Spec.token, String.contains_char_eq, List.contains_eq_mem]
  ac_rfl

theorem trimOWS_eq_spec (text : String) : trimOWS text = Spec.trimOWS text := rfl

private theorem lowerChar_eq (c : Char) :
    c.toLower = if 'A' <= c && c <= 'Z' then Char.ofNat (c.toNat + 32) else c := by
  unfold Char.toLower
  split
  next upper =>
    have yes : ('A' <= c && c <= 'Z') = true := by
      simpa only [Bool.and_eq_true, decide_eq_true_eq, Char.le_def] using upper
    rw [if_pos yes]
    apply Char.toNat_inj.mp
    have bound : c.toNat <= 90 := UInt32.le_iff_toNat_le.mp upper.2
    have valid : (c.toNat + 32).isValidChar := by left; omega
    change (c.val + 32).toNat = (Char.ofNat (c.toNat + 32)).toNat
    rw [Char.ofNat, dif_pos valid]
    simp only [Char.ofNatAux, Char.toNat, UInt32.toNat_add]
    change (c.toNat + 32) % 4294967296 = c.toNat + 32
    exact Nat.mod_eq_of_lt (by omega)
  next notUpper =>
    have no : ('A' <= c && c <= 'Z') = false := by
      apply Bool.eq_false_iff.mpr
      intro yes
      apply notUpper
      simpa only [Bool.and_eq_true, decide_eq_true_eq, Char.le_def] using yes
    rw [if_neg (by simp [no])]

theorem toLower_eq_spec (text : String) : text.toLower = Spec.asciiLower text := by
  apply String.toList_inj.mp
  simp only [String.toLower, String.toList_map, Spec.asciiLower, String.toList_ofList]
  congr 1
  funext c
  exact lowerChar_eq c

theorem splitChar_first (separator : Char) (first rest : String)
    (absent : separator ∉ first.toList) :
    splitChar separator (first ++ String.singleton separator ++ rest) =
      first :: splitChar separator rest := by
  simp only [splitChar, String.toList_split_char, String.toList_append, String.toList_singleton]
  rw [List.append_assoc]
  simp only [List.singleton_append, List.splitOn_append_cons_self_of_not_mem absent,
    List.map_cons, String.ofList_toList]

theorem trimOWS_padded (leading value trailing : String)
    (left : leading.toList.all Spec.ows = true)
    (right : trailing.toList.all Spec.ows = true)
    (normalized : trimOWS value = value) :
    trimOWS (leading ++ value ++ trailing) = value := by
  let p := Spec.ows
  have front : value.toList.dropWhile p = value.toList := by
    rw [← normalized]
    exact trimOWS_front value
  have back : value.toList.reverse.dropWhile p = value.toList.reverse := by
    rw [← normalized]
    exact trimOWS_back value
  have leadAll : ∀ c ∈ leading.toList, p c = true := List.all_eq_true.mp left
  have trailAll : ∀ c ∈ trailing.toList.reverse, p c = true := by
    intro c member
    exact List.all_eq_true.mp right c (List.mem_reverse.mp member)
  apply String.toList_inj.mp
  simp only [trimOWS, String.toList_ofList, String.toList_append]
  change (((leading.toList ++ value.toList ++ trailing.toList).dropWhile p).reverse.dropWhile p).reverse = value.toList
  rw [List.append_assoc, List.dropWhile_append_of_pos leadAll]
  by_cases empty : value.toList = []
  · have trailingEmpty : trailing.toList.dropWhile p = [] := by
      have all : ∀ c ∈ trailing.toList, p c = true := List.all_eq_true.mp right
      simpa using List.dropWhile_append_of_pos (l₂ := []) all
    simp only [empty, List.nil_append, trailingEmpty, List.reverse_nil, List.dropWhile_nil]
  · rw [List.dropWhile_append, front]
    simp only [List.isEmpty_iff, empty, ↓reduceIte, List.reverse_append,
      List.dropWhile_append_of_pos trailAll, back, List.reverse_reverse]

structure ParsedField where
  name : String
  value : String

theorem fieldValue_error (value : String) :
    value.toList.any (fun c => (c.toNat < 32 && c != '\t') || c.toNat == 127) =
      !Spec.fieldValue value := by
  simp only [Spec.fieldValue, List.not_all_eq_any_not]
  congr 1
  funext c
  apply Bool.eq_iff_iff.mpr
  simp

def parseField (line : String) : Except Response ParsedField := do
  let name :: parts := splitChar ':' line | throw (bad "Malformed header")
  if parts.isEmpty || name.isEmpty || !name.toList.all tokenChar then
    throw (bad "Malformed header name")
  let name := name.toLower
  let value := trimOWS (String.intercalate ":" parts)
  if value.toList.any (fun c => (c.toNat < 32 && c != '\t') || c.toNat == 127) then
    throw (bad "Invalid header value")
  return { name, value }

theorem parseField_source (line : String) (result : ParsedField)
    (parsed : parseField line = .ok result) :
    ∃ field : Spec.Field, field.valid = true ∧ field.text = line ++ "\r\n" ∧
      result.name = Spec.asciiLower field.name ∧ result.value = field.value := by
  unfold parseField at parsed
  split at parsed
  next name parts source =>
    simp only [Bind.bind, Except.bind, Pure.pure, Except.pure] at parsed
    split at parsed
    next invalid => cases parsed
    next nameOk =>
      split at parsed
      next invalid => cases parsed
      next valueOk =>
        cases Except.ok.inj parsed
        have names : parts ≠ [] ∧ name ≠ "" ∧ name.toList.all tokenChar = true := by
          simpa [Bool.or_assoc] using nameOk
        let raw := String.intercalate ":" parts
        obtain ⟨leading, trailing, leadOk, trailOk, textSource⟩ := trimOWS_source raw
        let field : Spec.Field := { name, value := trimOWS raw, leading, trailing }
        refine ⟨field, ?_, ?_, toLower_eq_spec name, rfl⟩
        · have chars : Spec.fieldValue (trimOWS raw) = true := by
            have valid := Bool.eq_false_iff.mpr valueOk
            rw [fieldValue_error] at valid
            simpa only [Bool.not_eq_false'] using valid
          have tokens : name.toList.all Spec.token = true := by
            rw [← show tokenChar = Spec.token from funext tokenChar_eq_spec]
            exact names.2.2
          have emptyName : name.isEmpty = false := by simpa using names.2.1
          have lead : leading.toList.all Spec.ows = true := leadOk
          have trail : trailing.toList.all Spec.ows = true := trailOk
          simp only [field, Spec.Field.valid, emptyName, tokens, chars,
            ← trimOWS_eq_spec, trimOWS_idempotent, beq_self_eq_true, lead, trail]
          rfl
        · have lineSource := splitChar_rejoin ':' line
          rw [source, String.intercalate_cons_of_ne_nil names.1] at lineSource
          calc
            field.text = (name ++ ":" ++ raw) ++ "\r\n" := by
              have joined := congrArg (fun value => (name ++ ":" ++ value) ++ "\r\n") textSource
              simpa only [field, Spec.Field.text, Spec.Field.line, String.append_assoc] using joined.symm
            _ = line ++ "\r\n" := congrArg (· ++ "\r\n") lineSource
  next invalid => cases parsed

theorem parseField_complete (field : Spec.Field) (valid : field.valid = true) :
    parseField (field.name ++ ":" ++ field.leading ++ field.value ++ field.trailing) =
      .ok { name := Spec.asciiLower field.name, value := field.value } := by
  have properties : field.name ≠ "" ∧ field.name.toList.all Spec.token = true ∧
      Spec.fieldValue field.value = true ∧ Spec.trimOWS field.value = field.value ∧
      field.leading.toList.all Spec.ows = true ∧ field.trailing.toList.all Spec.ows = true := by
    simpa [Spec.Field.valid, Bool.and_assoc] using valid
  have noColon : ':' ∉ field.name.toList := by
    intro mem
    have token := List.all_eq_true.mp properties.2.1 ':' mem
    contradiction
  let raw := field.leading ++ field.value ++ field.trailing
  have splitLine : splitChar ':' (field.name ++ ":" ++ field.leading ++ field.value ++ field.trailing) =
      field.name :: splitChar ':' raw := by
    simpa only [raw, String.append_assoc, show String.singleton ':' = ":" from rfl] using
      splitChar_first ':' field.name raw noColon
  have trimmed : trimOWS raw = field.value :=
    trimOWS_padded _ _ _ properties.2.2.2.2.1 properties.2.2.2.2.2
      ((trimOWS_eq_spec _).trans properties.2.2.2.1)
  have tokens : field.name.toList.all tokenChar = true := by
    rw [show tokenChar = Spec.token from funext tokenChar_eq_spec]
    exact properties.2.1
  have notEmpty : (splitChar ':' raw).isEmpty = false := by
    simpa using splitChar_ne_nil ':' raw
  have nameNotEmpty : field.name.isEmpty = false := by simpa using properties.1
  unfold parseField
  rw [splitLine]
  simp only [notEmpty, nameNotEmpty, tokens, Bool.not_true, Bool.or_self,
    Bool.false_eq_true, ↓reduceIte]
  rw [show String.intercalate ":" (splitChar ':' raw) = raw from splitChar_rejoin ':' raw,
    trimmed, fieldValue_error, properties.2.2.1, Bool.not_true]
  simp only [Bool.false_eq_true, ↓reduceIte, Pure.pure, Except.pure, toLower_eq_spec]

end LeanHttp.Wire.Internal
