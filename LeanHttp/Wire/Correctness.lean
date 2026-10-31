import LeanHttp.Wire

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

theorem form_valid_of_model (form : Spec.RequestForm) (state : HeaderState) (limit bodyLimit : Nat)
    (model : HeaderState.Model form.fields.reverse state bodyLimit)
    (target : form.target.valid form.method = true) (host : state.hostSeen = true)
    (length : state.length.getD 0 = form.body.toUTF8.size) (fits : form.bytes.size <= limit) :
    form.Valid limit := by
  have validFields : form.fields.all Spec.Field.valid = true := by simpa using model.validFields
  have hosts : (hostFields form.fields).length = 1 := by
    simpa [hostFields, List.filter_reverse, host] using model.hosts
  have hostValues : (hostFields form.fields).all (fun f => Spec.hostValue f.value) = true := by
    apply List.all_eq_true.mpr
    intro f member
    obtain ⟨member, name⟩ := List.mem_filter.mp member
    exact model.hostValues f (List.mem_reverse.mpr member) (beq_iff_eq.mp name)
  have extensions : form.fields.all (fun f =>
      Spec.asciiLower f.name != "transfer-encoding" && Spec.asciiLower f.name != "expect") = true := by
    simpa using model.extensions
  have framed : (match lengthFields form.fields with
    | [] => form.body.isEmpty
    | [f] => Spec.digits f.value && Spec.decimal f.value == form.body.toUTF8.size
    | _ => false) = true := by
    have count := model.lengths
    have reversed : lengthFields form.fields.reverse = (lengthFields form.fields).reverse := by
      simp [lengthFields, List.filter_reverse]
    rw [reversed, List.length_reverse] at count
    cases lengths : lengthFields form.fields with
    | nil =>
      have noLength : state.length = none := by
        rw [lengths] at count
        cases h : state.length <;> simp_all
      have empty : form.body = "" := by
        apply String.utf8ByteSize_eq_zero_iff.mp
        simpa [noLength] using length.symm
      simp [empty]
    | cons f rest =>
      have member : f ∈ lengthFields form.fields := by rw [lengths]; simp
      obtain ⟨member, name⟩ := List.mem_filter.mp member
      obtain ⟨declared, digits, _⟩ := model.lengthValues f (List.mem_reverse.mpr member) (beq_iff_eq.mp name)
      have number : Spec.decimal f.value = form.body.toUTF8.size := by simpa [declared] using length
      cases rest with
      | nil => simp [digits, number]
      | cons g rest =>
        rw [lengths, declared] at count
        simp at count
  simp only [Spec.RequestForm.Valid, Spec.RequestForm.valid]
  change (form.target.valid form.method && form.fields.all Spec.Field.valid &&
    ((hostFields form.fields).length == 1) &&
    (hostFields form.fields).all (fun f => Spec.hostValue f.value) &&
    (match lengthFields form.fields with
      | [] => form.body.isEmpty
      | [f] => Spec.digits f.value && Spec.decimal f.value == form.body.toUTF8.size
      | _ => false) && _ && decide (form.bytes.size <= limit)) = true
  rw [target, validFields, hosts, hostValues, framed, extensions]
  simpa using fits

end LeanHttp.Wire.Internal

namespace LeanHttp.Wire

open Internal

theorem parse_sound (bytes : ByteArray) (limit : Nat) (request : Request)
    (parsed : parse bytes limit = .ok (some request)) : Spec.Represents limit bytes request := by
  unfold parse at parsed
  simp only [Bind.bind, Except.bind, Pure.pure, Except.pure] at parsed
  split at parsed
  next large => cases parsed
  next fits =>
    split at parsed
    next error rejected => cases parsed
    next boundary boundaryOk =>
      split at parsed
      next boundary =>
        split at parsed
        next header headerOk =>
          split at parsed
          next error rejected => cases parsed
          next head headOk =>
            split at parsed
            next large => cases parsed
            next totalFits =>
              split at parsed
              next short => cases parsed
              next notShort =>
                split at parsed
                next trailing => cases parsed
                next notLong =>
                  split at parsed
                  next body bodyOk =>
                    split at parsed
                    next path parts splitEq =>
                      cases Option.some.inj (Except.ok.inj parsed)
                      obtain ⟨line, fields, state, lines, start, model, host, headers, length⟩ :=
                        parseHead_source header (limit - boundary.endPos) head headOk
                      obtain ⟨target, targetValid, targetText, decoded⟩ :=
                        target_source head.target path parts head.method splitEq (parseStartLine_target line _ start)
                      let form : Spec.RequestForm := { method := head.method, target, fields, body }
                      have startText := parseStartLine_source line _ start
                      have headerText : header ++ "\r\n\r\n" = form.header := by
                        rw [form_header_text]
                        have rejoined := splitLines_source header
                        rw [lines, startText, ← targetText] at rejoined
                        exact congrArg (· ++ "\r\n\r\n") rejoined.symm
                      have exactSize : bytes.size = boundary.endPos + head.length := by omega
                      have bodySource := (fromUTF8_eq_some _ _).mp bodyOk
                      have headerSource := (fromUTF8_eq_some _ _).mp headerOk
                      have source : bytes = form.bytes := by
                        have append : (header ++ "\r\n\r\n").toUTF8 =
                            header.toUTF8 ++ "\r\n\r\n".toUTF8 := rfl
                        rw [Spec.RequestForm.bytes, ← headerText, append,
                          headerSource, bodySource, ← exactSize]
                        exact boundary.source
                      have bodyLength : body.toUTF8.size = head.length := by
                        rw [bodySource, ByteArray.size_extract]
                        have upper := boundary.upper
                        omega
                      refine ⟨form, ?_, source, ?_⟩
                      · exact form_valid_of_model form state limit _ model targetValid host
                          (length.symm.trans bodyLength.symm) (by rw [← source]; omega)
                      · simp only [form, Spec.RequestForm.request]
                        have headerFields := congrArg List.reverse model.headers
                        simp only [← List.map_reverse, List.reverse_reverse] at headerFields
                        cases target <;> simp_all
                    next missing => cases parsed
                  next invalid => cases parsed
        next invalid => cases parsed
      next missing =>
        split at parsed <;> cases parsed

theorem parse_form_complete (form : Spec.RequestForm) (limit : Nat) (valid : form.Valid limit) :
    parse form.bytes limit = .ok (some form.request) := by
  have facts := valid
  simp only [Spec.RequestForm.Valid, Spec.RequestForm.valid, Bool.and_eq_true] at facts
  have fits : form.bytes.size <= limit := by simpa using facts.2
  have targetValid := facts.1.1.1.1.1.1
  obtain ⟨boundary, found, endEq⟩ := headerEnd_form_complete form limit valid
  let text := String.intercalate "\r\n"
    ((Spec.methodText form.method ++ " " ++ form.target.text ++ " HTTP/1.1") ::
      form.fields.map Spec.Field.line)
  have headerBytes : form.header.toUTF8 = text.toUTF8 ++ "\r\n\r\n".toUTF8 := by
    rw [form_header_text]
    rfl
  have endPos : boundary.endPos = text.toUTF8.size + 4 := by
    rw [endEq, headerBytes, ByteArray.size_append]
    rfl
  have headerSource : form.bytes.extract 0 (boundary.endPos - 4) = text.toUTF8 := by
    change (form.header.toUTF8 ++ form.body.toUTF8).extract 0 (boundary.endPos - 4) = text.toUTF8
    rw [headerBytes, endPos, Nat.add_sub_cancel, ByteArray.append_assoc]
    exact ByteArray.extract_append_eq_left rfl
  have headerUTF8 : String.fromUTF8? (form.bytes.extract 0 (boundary.endPos - 4)) = some text :=
    (fromUTF8_eq_some _ _).mpr headerSource.symm
  have headOk := parseHead_form_complete form limit valid
  have bodySource : form.bytes.extract boundary.endPos (boundary.endPos + form.body.toUTF8.size) = form.body.toUTF8 := by
    change (form.header.toUTF8 ++ form.body.toUTF8).extract boundary.endPos
      (boundary.endPos + form.body.toUTF8.size) = form.body.toUTF8
    rw [endEq]
    exact ByteArray.extract_append_eq_right rfl rfl
  have bodyUTF8 : String.fromUTF8? (form.bytes.extract boundary.endPos
      (boundary.endPos + form.body.toUTF8.size)) = some form.body :=
    (fromUTF8_eq_some _ _).mpr bodySource.symm
  have size : form.bytes.size = boundary.endPos + form.body.toUTF8.size := by
    change (form.header.toUTF8 ++ form.body.toUTF8).size = _
    rw [ByteArray.size_append, endEq]
  have totalFits : boundary.endPos + form.body.toUTF8.size <= limit := by omega
  obtain ⟨path, parts, split, decoded⟩ := target_split_complete form.target form.method targetValid
  have headOk' : parseHead text (limit - boundary.endPos) = .ok {
      method := form.method, target := form.target.text,
      headers := form.fields.map (fun f => (Spec.asciiLower f.name, f.value)),
      length := form.body.toUTF8.size } := by simpa only [endEq] using headOk
  unfold parse
  simp only [Nat.not_lt.mpr fits, ↓reduceIte, found, Bind.bind, Except.bind, headerUTF8]
  rw [headOk']
  simp only [Nat.not_lt.mpr totalFits, size, Nat.lt_irrefl, ↓reduceIte, bodyUTF8, split,
    Pure.pure, Except.pure]
  congr 2
  have decoded' : (form.request.path, form.request.query) = (path, String.intercalate "?" parts) := by
    cases form with
    | mk method target fields body =>
      cases target <;> exact decoded
  have pathEq := congrArg Prod.fst decoded'
  have queryEq := congrArg Prod.snd decoded'
  change form.request.path = path at pathEq
  change form.request.query = String.intercalate "?" parts at queryEq
  rw [← pathEq, ← queryEq]
  cases form.target <;> rfl

theorem parse_complete (bytes : ByteArray) (limit : Nat) (request : Request)
    (represented : Spec.Represents limit bytes request) : parse bytes limit = .ok (some request) := by
  obtain ⟨form, valid, rfl, rfl⟩ := represented
  exact parse_form_complete form limit valid

theorem parse_iff_represents (bytes : ByteArray) (limit : Nat) (request : Request) :
    parse bytes limit = .ok (some request) ↔ Spec.Represents limit bytes request :=
  ⟨parse_sound bytes limit request, parse_complete bytes limit request⟩

end LeanHttp.Wire
