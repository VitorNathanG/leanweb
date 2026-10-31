import LeanHttp.Wire

set_option autoImplicit false

namespace LeanHttp.Wire

open Internal

/-- The executable renderer produces exactly the independently specified bytes. -/
theorem render_represents (response : Response) (headOnly : Bool) :
    Spec.ResponseRepresents response headOnly (render response headOnly) := by
  cases headOnly <;> simp [Spec.ResponseRepresents, Spec.responseHeader, render,
    String.intercalate_cons_cons, String.append_assoc, ByteArray.append_assoc] <;> rfl

theorem render_head (response : Response) :
    render response true = (Spec.responseHeader response).toUTF8 := by
  simpa only [Spec.ResponseRepresents, ↓reduceIte, ByteArray.append_empty] using
    render_represents response true

theorem render_body (response : Response) :
    render response false = render response true ++ response.body.toUTF8 := by
  simpa only [Spec.ResponseRepresents, Bool.false_eq_true, ↓reduceIte, render_head] using
    render_represents response false

theorem render_size (response : Response) (headOnly : Bool) :
    (render response headOnly).size = (render response true).size +
      if headOnly then 0 else response.body.toUTF8.size := by
  cases headOnly <;> simp [render_body]

private theorem decimal_toString (n : Nat) : Spec.decimal (toString n) = n := by
  simpa only [Spec.decimal, Nat.toString_eq_repr, Nat.toList_repr, Nat.ofDigitChars] using
    (Nat.ofDigitChars_ten_toDigits (n := n))

private theorem digits_toString (n : Nat) : Spec.digits (toString n) = true := by
  have nonempty : toString n ≠ "" := by simp
  have notEmpty : (toString n).isEmpty = false := by
    apply Bool.eq_false_iff.mpr
    intro empty
    exact nonempty (String.isEmpty_iff.mp empty)
  unfold Spec.digits
  rw [notEmpty]
  simp only [Bool.not_false, Bool.true_and, Nat.toString_eq_repr, Nat.toList_repr]
  apply List.all_eq_true.mpr
  intro c member
  exact Nat.isDigit_of_mem_toDigits (by decide) (by decide) member

private theorem number_fieldValue (n : Nat) : Spec.fieldValue (toString n) = true := by
  have digits := digits_toString n
  simp only [Spec.digits, Bool.and_eq_true] at digits
  apply List.all_eq_true.mpr
  intro c member
  have range := List.all_eq_true.mp digits.2 c member
  simp only [Bool.and_eq_true, decide_eq_true_eq, Char.le_def, UInt32.le_iff_toNat_le] at range
  change 48 <= c.toNat ∧ c.toNat <= 57 at range
  change ((32 <= c.toNat || c == '\t') && c.toNat != 127) = true
  simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, bne_iff_ne]
  exact ⟨Or.inl (by omega), by omega⟩

private def responseLines (response : Response) : List String := [
  "HTTP/1.1 " ++ toString response.status.code ++ " " ++ response.status.reason,
  "Content-Type: " ++ response.contentType.value,
  "Content-Length: " ++ toString response.body.toUTF8.size,
  "Connection: close"]

private theorem responseLines_valid (response : Response) :
    ∀ line ∈ responseLines response, line ≠ "" ∧ Spec.fieldValue line = true := by
  intro line member
  simp only [responseLines, List.mem_cons, List.not_mem_nil, or_false] at member
  rcases member with rfl | rfl | rfl | rfl
  · cases response.status <;> decide
  · cases response.contentType <;> decide
  · constructor
    · simp [String.append_eq_empty_iff]
    · have valid := number_fieldValue response.body.toUTF8.size
      have constant : Spec.fieldValue "Content-Length: " = true := by decide
      simp only [Spec.fieldValue, String.toList_append, List.all_append] at constant valid ⊢
      rw [constant]
      exact valid
  · decide

private theorem responseHeader_lines (response : Response) :
    Spec.responseHeader response = String.intercalate "\r\n" (responseLines response) ++ "\r\n\r\n" := by
  simp [Spec.responseHeader, responseLines, String.intercalate_cons_cons, String.append_assoc]

theorem render_header (response : Response) (headOnly : Bool) :
    (render response headOnly).extract 0 (render response true).size = render response true := by
  cases headOnly
  · rw [render_body, ByteArray.extract_append_eq_left rfl]
  · simp

theorem render_body_bytes (response : Response) (headOnly : Bool) :
    (render response headOnly).extract (render response true).size (render response headOnly).size =
      if headOnly then ByteArray.empty else response.body.toUTF8 := by
  cases headOnly
  · rw [render_body, ByteArray.size_append, ByteArray.extract_append_eq_right rfl rfl]
    rfl
  · simp

private theorem headerEnd_lines (lines : List String) (nonempty : lines ≠ [])
    (valid : ∀ line ∈ lines, line ≠ "" ∧ Spec.fieldValue line = true) (suffix : ByteArray) :
    ∃ boundary : HeaderBoundary ((String.intercalate "\r\n" lines ++ "\r\n\r\n").toUTF8 ++ suffix),
      headerEnd ((String.intercalate "\r\n" lines ++ "\r\n\r\n").toUTF8 ++ suffix) = .ok (some boundary) ∧
      boundary.endPos = (String.intercalate "\r\n" lines ++ "\r\n\r\n").toUTF8.size := by
  have clean : ∀ line ∈ lines, line.toUTF8.data.toList ≠ [] ∧
      ∀ b ∈ line.toUTF8.data.toList, SafeByte b := by
    intro line member
    have lineValid := valid line member
    refine ⟨?_, text_safe line lineValid.2⟩
    intro empty
    have size := congrArg List.length empty
    simp only [Array.length_toList, List.length_nil] at size
    exact lineValid.1 (String.utf8ByteSize_eq_zero_iff.mp size)
  have source : ((String.intercalate "\r\n" lines ++ "\r\n\r\n").toUTF8 ++ suffix).data.toList =
      List.intercalate [13, 10] (lines.map (fun line => line.toUTF8.data.toList)) ++
        [13, 10, 13, 10] ++ suffix.data.toList := by
    simp only [String.toUTF8_eq_toByteArray, String.toByteArray_append,
      ByteArray.data_append, Array.toList_append]
    change (String.intercalate "\r\n" lines).toUTF8.data.toList ++ [13, 10, 13, 10] ++
      suffix.data.toList = _
    rw [intercalate_bytes]
    rfl
  obtain ⟨boundary, found, endPos⟩ := scan_lines
    ((String.intercalate "\r\n" lines ++ "\r\n\r\n").toUTF8 ++ suffix)
    [] suffix.data.toList
    (lines.map (fun line => line.toUTF8.data.toList)) (by simpa using nonempty)
    (by simpa using clean) (by simpa using source)
  refine ⟨boundary, found, ?_⟩
  have size := congrArg List.length (intercalate_bytes "\r\n" lines)
  simp only [Array.length_toList] at size
  change (String.intercalate "\r\n" lines).utf8ByteSize =
    (List.intercalate [13, 10] (lines.map (fun line => line.toUTF8.data.toList))).length at size
  simp only [String.toUTF8_eq_toByteArray, String.toByteArray_append, ByteArray.size_append]
  change boundary.endPos = (String.intercalate "\r\n" lines).utf8ByteSize + 4
  simpa only [List.length_nil, Nat.zero_add, ← size] using endPos

/-- The first header terminator is unchanged by any bytes in the body. -/
theorem render_boundary (response : Response) (headOnly : Bool) :
    (headerEnd (render response headOnly)).map (fun result => result.map (·.endPos)) =
      .ok (some (render response true).size) := by
  have represented := render_represents response headOnly
  unfold Spec.ResponseRepresents at represented
  have framed :=
    headerEnd_lines (responseLines response) (by simp [responseLines]) (responseLines_valid response)
      (if headOnly then ByteArray.empty else response.body.toUTF8)
  obtain ⟨boundary, found, endPos⟩ := framed
  rw [represented, responseHeader_lines, found]
  simp only [Except.map, Option.map, endPos, render_head, responseHeader_lines]

theorem render_contentLength (response : Response) (headOnly : Bool) :
    ∃ header : String,
      String.fromUTF8? ((render response headOnly).extract 0 (render response true).size) = some header ∧
      (splitLines header)[2]? = some ("Content-Length: " ++ toString response.body.toUTF8.size) ∧
      contentLength (toString response.body.toUTF8.size) response.body.toUTF8.size =
        .ok response.body.toUTF8.size := by
  refine ⟨Spec.responseHeader response, ?_, ?_, ?_⟩
  · rw [render_header, render_head]
    exact (fromUTF8_eq_some _ _).mpr rfl
  · have clean : ∀ line ∈ responseLines response ++ ["", ""], '\r' ∉ line.toList := by
      intro line member
      simp only [List.mem_append, List.mem_cons, List.not_mem_nil, or_false, or_self] at member
      rcases member with member | rfl
      · have valid := (responseLines_valid response line member).2
        intro cr
        have := List.all_eq_true.mp valid '\r' cr
        contradiction
      · simp
    have split := splitLines_intercalate (responseLines response ++ ["", ""])
      (by simp) clean
    have header : Spec.responseHeader response =
        String.intercalate "\r\n" (responseLines response ++ ["", ""]) := rfl
    rw [header, split]
    rfl
  · exact (contentLength_ok_iff _ _ _).mpr
      ⟨digits_toString _, decimal_toString _, Nat.le_refl _⟩

/-- For fixed status, type, and byte length, body contents cannot change the headers. -/
theorem render_same_headers (left right : Response)
    (status : left.status = right.status) (contentType : left.contentType = right.contentType)
    (length : left.body.toUTF8.size = right.body.toUTF8.size) :
    render left true = render right true := by
  simp only [render_head, Spec.responseHeader, status, contentType, length]

end LeanHttp.Wire
