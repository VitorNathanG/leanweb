import LeanHttp.Wire.Head

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

def SafeByte (b : UInt8) : Prop := b = 9 ∨ (32 <= b ∧ b ≠ 127)

theorem encoded_safe (c : Char) (valid : (32 <= c.toNat ∨ c = '\t') ∧ c.toNat ≠ 127) :
    ∀ b ∈ String.utf8EncodeChar c, SafeByte b := by
  have high (b mask : UInt8) (bound : 128 <= mask.toNat) : SafeByte (b ||| mask) := by
    right
    have lower := Nat.right_le_or (n := b.toNat) (m := mask.toNat)
    simp only [UInt8.le_iff_toNat_le, UInt8.toNat_or, UInt8.reduceToNat]
    constructor
    · omega
    · intro eq
      have := congrArg UInt8.toNat eq
      simp only [UInt8.toNat_or, UInt8.reduceToNat] at this
      omega
  rcases Char.utf8Size_eq c with one | two | three | four
  · rw [String.utf8EncodeChar_eq_singleton one]
    intro b member
    have equal : b = c.val.toUInt8 := by simpa using member
    subst equal
    have bound : c.toNat <= 127 := by
      simpa only [Char.toNat, UInt32.le_iff_toNat_le, UInt32.reduceToNat] using
        (Char.utf8Size_eq_one_iff.mp one)
    rcases valid.1 with lower | tab
    · right
      have value : c.val.toUInt8.toNat = c.toNat := by
        change c.val.toNat % 256 = c.toNat
        change c.val.toNat <= 127 at bound
        change c.val.toNat % 256 = c.val.toNat
        exact Nat.mod_eq_of_lt (by omega)
      constructor
      · simpa only [UInt8.le_iff_toNat_le, UInt8.reduceToNat, value] using lower
      · intro equal
        have := congrArg UInt8.toNat equal
        simp only [value, UInt8.reduceToNat] at this
        exact valid.2 this
    · subst tab
      left
      rfl
  · rw [String.utf8EncodeChar_eq_cons_cons two]
    intro b member
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with rfl | rfl <;> exact high _ _ (by decide)
  · rw [String.utf8EncodeChar_eq_cons_cons_cons three]
    intro b member
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with rfl | rfl | rfl <;> exact high _ _ (by decide)
  · rw [String.utf8EncodeChar_eq_cons_cons_cons_cons four]
    intro b member
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with rfl | rfl | rfl | rfl <;> exact high _ _ (by decide)

theorem text_safe (text : String) (valid : Spec.fieldValue text = true) :
    ∀ b ∈ text.toUTF8.data.toList, SafeByte b := by
  have source : text.toUTF8.data.toList = text.toList.flatMap String.utf8EncodeChar := by
    rw [String.toUTF8_eq_toByteArray, ← String.utf8Encode_toList]
    simp [List.utf8Encode]
  rw [source]
  intro b member
  obtain ⟨c, member, byte⟩ := List.mem_flatMap.mp member
  have char := List.all_eq_true.mp valid c member
  apply encoded_safe c ?_ b byte
  simpa [Bool.and_eq_true, Bool.or_eq_true] using char

private theorem byte_at (bytes : ByteArray) (before suffix : List UInt8) (b : UInt8)
    (source : bytes.data.toList = before ++ b :: suffix) :
    before.length < bytes.size ∧ bytes[before.length]! = b := by
  have size := congrArg List.length source
  simp only [Array.length_toList, List.length_append, List.length_cons] at size
  have bound : before.length < bytes.size := by change before.length < bytes.data.size; omega
  refine ⟨bound, ?_⟩
  rw [getElem!_pos bytes before.length bound]
  change bytes.data[before.length] = b
  rw [← Array.getElem_toList]
  exact List.getElem_of_append source rfl

private theorem scan_safe (bytes : ByteArray) (i : Nat) (within : i < bytes.size)
    (safe : SafeByte bytes[i]!) : scanHeader bytes i = scanHeader bytes (i + 1) := by
  have noLF : bytes[i]! ≠ 10 := by
    intro eq
    rcases safe with h | ⟨h, _⟩ <;> simp [eq] at h
  have noCR : bytes[i]! ≠ 13 := by
    intro eq
    rcases safe with h | ⟨h, _⟩ <;> simp [eq] at h
  have noControl : ((bytes[i]! < 32 && bytes[i]! != 9 && bytes[i]! != 10 && bytes[i]! != 13) ||
      bytes[i]! == 127) = false := by
    rcases safe with h | ⟨h, notDel⟩
    · simp [h]
    · simp [UInt8.not_lt.mpr h, notDel]
  rw [scanHeader]
  simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
  simp only [within, ↓reduceDIte, noControl, beq_eq_false_iff_ne.mpr noLF,
    beq_eq_false_iff_ne.mpr noCR, Bool.false_and, Bool.false_eq_true, ↓reduceIte]

theorem scan_safe_prefix (bytes : ByteArray) (before safe rest : List UInt8)
    (source : bytes.data.toList = before ++ safe ++ rest)
    (clean : ∀ b ∈ safe, SafeByte b) :
    scanHeader bytes before.length = scanHeader bytes (before.length + safe.length) := by
  induction safe generalizing before with
  | nil => simp
  | cons b bs ih =>
    have source' : bytes.data.toList = before ++ b :: (bs ++ rest) := by simpa using source
    obtain ⟨within, value⟩ := byte_at bytes before (bs ++ rest) b source'
    rw [scan_safe bytes before.length within (value ▸ clean b (by simp))]
    have tail := ih (before ++ [b]) (by simpa [List.append_assoc] using source)
      (by intro x mem; exact clean x (by simp [mem]))
    simpa [List.length_append, List.length_cons, Nat.add_assoc, Nat.add_comm 1 bs.length] using tail

theorem scan_crlf (bytes : ByteArray) (before rest : List UInt8) (b : UInt8)
    (source : bytes.data.toList = before ++ 13 :: 10 :: b :: rest) (safe : SafeByte b) :
    scanHeader bytes before.length = scanHeader bytes (before.length + 2) := by
  obtain ⟨within, cr⟩ := byte_at bytes before (10 :: b :: rest) 13 source
  obtain ⟨nextWithin, lf⟩ := byte_at bytes (before ++ [13]) (b :: rest) 10
    (by simpa [List.append_assoc] using source)
  obtain ⟨lastWithin, last⟩ := byte_at bytes (before ++ [13, 10]) rest b
    (by simpa [List.append_assoc] using source)
  simp only [List.length_append, List.length_cons, List.length_nil, Nat.reduceAdd] at nextWithin lf lastWithin last
  have noCR : b ≠ 13 := by
    intro eq
    rcases safe with h | ⟨h, _⟩ <;> simp [eq] at h
  rw [scanHeader]
  simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
  simp only [within, ↓reduceDIte, cr, lf, last, beq_eq_false_iff_ne.mpr noCR, nextWithin]
  simp
  rw [scanHeader]
  simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
  have prev : before.length + 1 - 1 = before.length := by omega
  simp only [nextWithin, ↓reduceDIte, lf, prev, cr]
  simp [Nat.add_assoc]

theorem scan_delimiter (bytes : ByteArray) (before rest : List UInt8)
    (source : bytes.data.toList = before ++ 13 :: 10 :: 13 :: 10 :: rest) :
    ∃ boundary, scanHeader bytes before.length = .ok (some boundary) ∧
      boundary.endPos = before.length + 4 := by
  obtain ⟨within, cr⟩ := byte_at bytes before (10 :: 13 :: 10 :: rest) 13 source
  obtain ⟨_, lf⟩ := byte_at bytes (before ++ [13]) (13 :: 10 :: rest) 10
    (by simpa [List.append_assoc] using source)
  obtain ⟨_, cr'⟩ := byte_at bytes (before ++ [13, 10]) (10 :: rest) 13
    (by simpa [List.append_assoc] using source)
  obtain ⟨lastWithin, lf'⟩ := byte_at bytes (before ++ [13, 10, 13]) rest 10
    (by simpa [List.append_assoc] using source)
  simp only [List.length_append, List.length_cons, List.length_nil, Nat.reduceAdd] at lf cr' lastWithin lf'
  have nextWithin : before.length + 1 < bytes.size := by omega
  rw [scanHeader]
  simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
  simp only [within, ↓reduceDIte, cr, lf, cr', lf', nextWithin, lastWithin]
  simp
  exact ⟨_, rfl, rfl⟩

theorem scan_lines (bytes : ByteArray) (before rest : List UInt8) (lines : List (List UInt8))
    (nonempty : lines ≠ [])
    (clean : ∀ line ∈ lines, line ≠ [] ∧ ∀ b ∈ line, SafeByte b)
    (source : bytes.data.toList = before ++ List.intercalate [13, 10] lines ++ [13, 10, 13, 10] ++ rest) :
    ∃ boundary, scanHeader bytes before.length = .ok (some boundary) ∧
      boundary.endPos = before.length + (List.intercalate [13, 10] lines).length + 4 := by
  induction lines generalizing before with
  | nil => contradiction
  | cons line lines ih =>
    have lineClean := clean line (by simp)
    cases lines with
    | nil =>
      have step := scan_safe_prefix bytes before line ([13, 10, 13, 10] ++ rest)
        (by simpa [List.append_assoc] using source) lineClean.2
      obtain ⟨boundary, accepted, endPos⟩ := scan_delimiter bytes (before ++ line) rest
        (by simpa [List.append_assoc] using source)
      refine ⟨boundary, step.trans ?_, ?_⟩
      · simpa using accepted
      · simpa using endPos
    | cons next lines =>
      have nextClean := clean next (by simp)
      obtain ⟨b, tail, nextEq⟩ := List.exists_cons_of_ne_nil nextClean.1
      subst nextEq
      have step := scan_safe_prefix bytes before line
        ([13, 10] ++ List.intercalate [13, 10] ((b :: tail) :: lines) ++ [13, 10, 13, 10] ++ rest)
        (by simpa [List.intercalate_cons_cons, List.append_assoc] using source) lineClean.2
      have skip := scan_crlf bytes (before ++ line)
        (tail ++ (if lines = [] then [] else [13, 10]) ++ List.intercalate [13, 10] lines ++
          [13, 10, 13, 10] ++ rest) b
        (by
          cases lines <;> simpa [List.intercalate_cons_cons, List.append_assoc] using source)
        (nextClean.2 b (by simp))
      obtain ⟨boundary, accepted, endPos⟩ := ih (before ++ line ++ [13, 10]) (by simp)
        (by intro l mem; exact clean l (by simp [mem]))
        (by simpa [List.intercalate_cons_cons, List.append_assoc] using source)
      refine ⟨boundary, step.trans ?_, ?_⟩
      · have skip' : scanHeader bytes (before.length + line.length) =
            scanHeader bytes (before ++ line ++ [13, 10]).length := by simpa [Nat.add_assoc] using skip
        exact skip'.trans accepted
      · simp only [List.intercalate_cons_cons, List.length_append, List.length_cons, List.length_nil] at endPos ⊢
        omega

theorem token_fieldValue (c : Char) (valid : Spec.token c = true) :
    (32 <= c.toNat ∨ c = '\t') ∧ c.toNat ≠ 127 := by
  simp only [Spec.token, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
    Char.le_def, UInt32.le_iff_toNat_le] at valid
  change (((65 <= c.toNat ∧ c.toNat <= 90) ∨ (97 <= c.toNat ∧ c.toNat <= 122)) ∨
    (48 <= c.toNat ∧ c.toNat <= 57)) ∨ "!#$%&'*+-.^_`|~".toList.contains c = true at valid
  rcases valid with ((alpha | alpha) | digit) | symbol
  · constructor <;> omega
  · constructor <;> omega
  · constructor <;> omega
  · have symbol : c ∈ "!#$%&'*+-.^_`|~".toList := by simpa only [List.contains_eq_mem, decide_eq_true_eq] using symbol
    have chars : "!#$%&'*+-.^_`|~".toList = ['!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'] := by decide
    rw [chars] at symbol
    simp only [List.mem_cons, List.not_mem_nil, or_false] at symbol
    rcases symbol with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide

theorem field_line_safe (field : Spec.Field) (valid : field.valid = true) :
    Spec.fieldValue field.line = true := by
  have facts := valid
  simp only [Spec.Field.valid, Bool.and_eq_true] at facts
  have name : Spec.fieldValue field.name = true := by
    apply List.all_eq_true.mpr
    intro c member
    have safe := token_fieldValue c (List.all_eq_true.mp facts.1.1.1.1.2 c member)
    simpa only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq, bne_iff_ne] using safe
  have leading : Spec.fieldValue field.leading = true := by
    apply List.all_eq_true.mpr
    intro c member
    have space := List.all_eq_true.mp facts.1.2 c member
    simp only [Spec.ows, Bool.or_eq_true, beq_iff_eq] at space
    rcases space with rfl | rfl <;> decide
  have trailing : Spec.fieldValue field.trailing = true := by
    apply List.all_eq_true.mpr
    intro c member
    have space := List.all_eq_true.mp facts.2 c member
    simp only [Spec.ows, Bool.or_eq_true, beq_iff_eq] at space
    rcases space with rfl | rfl <;> decide
  have value := facts.1.1.1.2
  simp only [Spec.Field.line, Spec.fieldValue, String.toList_append, List.all_append] at *
  rw [name, leading, trailing, value]
  decide

theorem target_fieldValue (target : Spec.Target) (method : Method) (valid : target.valid method = true) :
    Spec.fieldValue target.text = true := by
  have checked := target_check target method valid
  rw [targetChars_error] at checked
  have checked' := checked
  simp only [Bool.or_eq_false_iff, Bool.not_eq_false'] at checked'
  have chars : target.text.toList.all Spec.targetChar = true := by
    exact checked'.2
  apply List.all_eq_true.mpr
  intro c member
  have safe := List.all_eq_true.mp chars c member
  simp only [Spec.targetChar, Bool.and_eq_true, decide_eq_true_eq, bne_iff_ne] at safe
  simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, bne_iff_ne]
  constructor
  · left; omega
  · omega

private theorem bytes_nonempty (text : String) (nonempty : text ≠ "") : text.toUTF8.data.toList ≠ [] := by
  intro empty
  have zero := congrArg List.length empty
  simp only [Array.length_toList, List.length_nil] at zero
  exact nonempty (String.utf8ByteSize_eq_zero_iff.mp zero)

theorem intercalate_bytes (separator : String) (lines : List String) :
    (String.intercalate separator lines).toUTF8.data.toList =
      List.intercalate separator.toUTF8.data.toList (lines.map (fun line => line.toUTF8.data.toList)) := by
  induction lines with
  | nil => rfl
  | cons line lines ih =>
    cases lines with
    | nil => simp
    | cons next rest =>
      simp only [String.intercalate_cons_cons, List.map_cons, List.intercalate_cons_cons,
        String.toUTF8_eq_toByteArray, String.toByteArray_append, ByteArray.data_append,
        Array.toList_append] at *
      rw [ih]

theorem headerEnd_form_complete (form : Spec.RequestForm) (limit : Nat) (valid : form.Valid limit) :
    ∃ boundary, headerEnd form.bytes = .ok (some boundary) ∧ boundary.endPos = form.header.toUTF8.size := by
  let first := Spec.methodText form.method ++ " " ++ form.target.text ++ " HTTP/1.1"
  let lines := first :: form.fields.map Spec.Field.line
  have facts := valid
  simp only [Spec.RequestForm.Valid, Spec.RequestForm.valid, Bool.and_eq_true] at facts
  have targetValid := facts.1.1.1.1.1.1
  have fieldsValid := facts.1.1.1.1.1.2
  have clean : ∀ line ∈ lines, line.toUTF8.data.toList ≠ [] ∧
      ∀ b ∈ line.toUTF8.data.toList, SafeByte b := by
    intro line member
    apply And.intro
    · apply bytes_nonempty
      rcases List.mem_cons.mp member with rfl | member
      · intro empty
        have size := congrArg String.utf8ByteSize empty
        simp only [first, String.utf8ByteSize_append, String.utf8ByteSize_empty] at size
        have space : " ".utf8ByteSize = 1 := rfl
        rw [space] at size
        omega
      · obtain ⟨field, mem, rfl⟩ := List.mem_map.mp member
        intro empty
        have size := congrArg String.utf8ByteSize empty
        simp only [Spec.Field.line, String.utf8ByteSize_append, String.utf8ByteSize_empty] at size
        have colon : ":".utf8ByteSize = 1 := rfl
        rw [colon] at size
        omega
    · apply text_safe
      rcases List.mem_cons.mp member with rfl | member
      · have methodSafe : Spec.fieldValue (Spec.methodText form.method) = true := by cases form.method <;> decide
        have targetSafe := target_fieldValue form.target form.method targetValid
        simp only [first, Spec.fieldValue, String.toList_append, List.all_append] at *
        rw [methodSafe, targetSafe]
        decide
      · obtain ⟨field, mem, rfl⟩ := List.mem_map.mp member
        exact field_line_safe field (List.all_eq_true.mp fieldsValid field mem)
  have source : form.bytes.data.toList =
      List.intercalate [13, 10] (lines.map (fun line => line.toUTF8.data.toList)) ++
        [13, 10, 13, 10] ++ form.body.toUTF8.data.toList := by
    have header := form_header_text form
    change form.header.toUTF8.data.toList ++ form.body.toUTF8.data.toList = _
    rw [header]
    change (String.intercalate "\r\n" lines).toUTF8.data.toList ++ [13, 10, 13, 10] ++ _ = _
    rw [intercalate_bytes]
    rfl
  obtain ⟨boundary, accepted, endPos⟩ := scan_lines form.bytes [] form.body.toUTF8.data.toList
    (lines.map (fun line => line.toUTF8.data.toList)) (by simp [lines])
    (by simpa using clean) (by simpa using source)
  refine ⟨boundary, accepted, ?_⟩
  rw [form_header_text]
  have size := congrArg List.length (intercalate_bytes "\r\n" lines)
  simp only [Array.length_toList] at size
  change (String.intercalate "\r\n" lines).utf8ByteSize =
    (List.intercalate [13, 10] (lines.map (fun line => line.toUTF8.data.toList))).length at size
  simp only [String.toUTF8_eq_toByteArray, ByteArray.size, String.toByteArray_append,
    ByteArray.data_append, Array.size_append]
  change boundary.endPos = (String.intercalate "\r\n" lines).utf8ByteSize + 4
  simpa only [List.length_nil, Nat.zero_add, ← size] using endPos

end LeanHttp.Wire.Internal
