import LeanHttp.Wire.Basic

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

structure StartLine where
  method : Method
  target : String

def parseStartLine (line : String) : Except Response StartLine := do
  let [methodText, target, version] := splitChar ' ' line
    | throw (bad "Malformed request line")
  if methodText.isEmpty || !methodText.toList.all tokenChar then
    throw (bad "Malformed method")
  if version != "HTTP/1.1" then
    if version.startsWith "HTTP/" then throw (unsupported "Only HTTP/1.1 is supported")
    throw (bad "Malformed HTTP version")
  let some method := Method.parse methodText
    | throw (unsupported "Unsupported method")
  if !(target.startsWith "/" || (target == "*" && method == .options)) ||
      target.toList.any (fun c => c.toNat <= 32 || c.toNat >= 127 || c == '#') then
    throw (bad "Invalid request target")
  return { method, target }

theorem methodText_of_parse (text : String) (method : Method)
    (parsed : Method.parse text = some method) : text = Spec.methodText method := by
  unfold Method.parse at parsed
  split at parsed <;> simp only [Option.some.injEq, reduceCtorEq] at parsed
  all_goals cases parsed; rfl

theorem parse_methodText (method : Method) :
    Method.parse (Spec.methodText method) = some method := by
  cases method <;> rfl

theorem parseStartLine_source (line : String) (result : StartLine)
    (parsed : parseStartLine line = .ok result) :
    line = Spec.methodText result.method ++ " " ++ result.target ++ " HTTP/1.1" := by
  unfold parseStartLine at parsed
  split at parsed
  next method target version source =>
    simp only [Bind.bind, Except.bind, Pure.pure, Except.pure] at parsed
    split at parsed
    next invalid => cases parsed
    next valid =>
      split at parsed
      next invalid =>
        split at parsed <;> cases parsed
      next versionValid =>
        split at parsed
        next method parsedMethod =>
          split at parsed
          next invalid => cases parsed
          next targetValid =>
            cases Except.ok.inj parsed
            have methodSource := methodText_of_parse _ _ parsedMethod
            have rejoined := splitChar_rejoin ' ' line
            have versionSource : version = "HTTP/1.1" := by simpa using versionValid
            rw [source, methodSource, versionSource] at rejoined
            simpa [String.intercalate_cons_cons, String.append_assoc] using rejoined.symm
        next unsupported => cases parsed
  next malformed => cases parsed

theorem parseStartLine_complete (method : Method) (target : String)
    (valid : (!(target.startsWith "/" || (target == "*" && method == .options)) ||
      target.toList.any (fun c => c.toNat <= 32 || c.toNat >= 127 || c == '#')) = false) :
    parseStartLine (Spec.methodText method ++ " " ++ target ++ " HTTP/1.1") =
      .ok { method, target } := by
  have noSpace : ' ' ∉ target.toList := by
    intro mem
    have bad : target.toList.any
        (fun c => c.toNat <= 32 || c.toNat >= 127 || c == '#') = true :=
      List.any_eq_true.mpr ⟨' ', mem, by decide⟩
    simp [bad] at valid
  have noMethodSpace : ' ' ∉ (Spec.methodText method).toList := by
    cases method <;> decide
  have splitLine := splitChar_intercalate ' '
    [Spec.methodText method, target, "HTTP/1.1"] (by simp)
    (by
      intro part member
      simp only [List.mem_cons, List.mem_nil_iff, or_false] at member
      rcases member with rfl | rfl | rfl
      · exact noMethodSpace
      · exact noSpace
      · decide)
  simp only [String.intercalate_cons_cons, String.intercalate_singleton] at splitLine
  have methodSyntax : ((Spec.methodText method).isEmpty ||
      !(Spec.methodText method).toList.all tokenChar) = false := by
    cases method <;> decide
  unfold parseStartLine
  rw [show splitChar ' ' (Spec.methodText method ++ " " ++ target ++ " HTTP/1.1") =
    [Spec.methodText method, target, "HTTP/1.1"] from by
      simpa [String.append_assoc] using splitLine]
  simpa [methodSyntax, parse_methodText, Bind.bind, Except.bind,
    Pure.pure, Except.pure] using valid

theorem startsWith_slash (text : String) : text.startsWith "/" = (text.toList.head? == some '/') := by
  apply Bool.eq_iff_iff.mpr
  simp only [String.startsWith_string_iff, beq_iff_eq]
  change ['/'] <+: text.toList ↔ text.toList.head? = some '/'
  cases text.toList <;> simp [eq_comm]

theorem targetChars_error (text : String) :
    text.toList.any (fun c => c.toNat <= 32 || c.toNat >= 127 || c == '#') =
      !text.toList.all Spec.targetChar := by
  rw [List.not_all_eq_any_not]
  congr 1
  funext c
  apply Bool.eq_iff_iff.mpr
  simp [Spec.targetChar]

theorem target_check (target : Spec.Target) (method : Method) (valid : target.valid method = true) :
    (!(target.text.startsWith "/" || (target.text == "*" && method == .options)) ||
      target.text.toList.any (fun c => c.toNat <= 32 || c.toNat >= 127 || c == '#')) = false := by
  cases target with
  | asterisk =>
    simp only [Spec.Target.valid] at valid
    rw [targetChars_error, startsWith_slash]
    simp [Spec.Target.text, Spec.targetChar, valid]
  | origin path query =>
    simp only [Spec.Target.valid, Bool.and_eq_true] at valid
    have head := valid.1.1.1
    have pathChars := valid.1.2
    have queryChars := valid.2
    rw [targetChars_error, startsWith_slash]
    cases query with
    | none =>
      simp only [Spec.Target.text]
      rw [head, pathChars]
      rfl
    | some query =>
      simp only [Option.getD_some] at queryChars
      have chars : (path ++ "?" ++ query).toList.all Spec.targetChar = true := by
        simp only [String.toList_append, List.all_append, pathChars, queryChars]
        decide
      have starts : (path ++ "?" ++ query).toList.head? = some '/' := by
        have headEq : path.toList.head? = some '/' := beq_iff_eq.mp head
        cases h : path.toList <;> simp_all [String.toList_append]
      simp only [Spec.Target.text]
      rw [chars, starts]
      rfl

end LeanHttp.Wire.Internal
