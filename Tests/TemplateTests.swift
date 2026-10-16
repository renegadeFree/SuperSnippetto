import Foundation

@main
struct TemplateTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1; do { if try !condition() { fatalError(message) } } catch { fatalError("\(message): \(error)") }
    }
    static func rejects(_ operation: () throws -> Void) {
        checks += 1; do { try operation(); fatalError("Expected an error") } catch {}
    }
    static func main() throws {
        let renderer = TemplateRenderer()
        func render(_ text: String, _ context: RenderContext = RenderContext()) throws -> RenderedText { try renderer.render(text, context: context) }
        let form = try render("{{field:Nome|Mario}} {{multiline:Note|Riga}} {{choice:Tipo|Privato|Azienda}} {{check:Extra|Accetto|Rifiuto}} {{datefield:Scadenza|dd/MM/yyyy}}")
        check(form.fields == ["Nome", "Note", "Tipo", "Extra", "Scadenza"], "Fields retain presentation order")
        check(form.fieldSpecs[0].defaultValue == "Mario", "Text default")
        check(form.fieldSpecs[1].kind == .multiline && form.fieldSpecs[1].defaultValue == "Riga", "Multiline definition")
        check(form.fieldSpecs[2].options == ["Privato", "Azienda"], "Choice options")
        check(form.fieldSpecs[3].kind == .checkbox && form.fieldSpecs[3].options == ["Accetto", "Rifiuto"], "Checkbox labels")
        check(form.fieldSpecs[4].kind == .date && form.fieldSpecs[4].dateFormat == "dd/MM/yyyy", "Date field format")
        check(try render("{{field:Nome}}/{{field:Nome}}").fields == ["Nome"], "Repeated field asks once")
        rejects { _ = try render("{{field:Nome}}{{choice:Nome|A|B}}") }
        rejects { _ = try render("{{choice:Tipo}}") }
        rejects { _ = try render("{{field:}}") }
        rejects { _ = try render((0...50).map { "{{field:F\($0)}}" }.joined()) }
        var context = RenderContext(variables: ["Nome": "<Mario & C>", "Extra": "Accetto"])
        check(try render("Ciao {{field:Nome}}", context).text == "Ciao <Mario & C>", "Plain values preserved literally")
        let conditional = "{{check:Extra|Accetto|Rifiuto}}{{if:Extra|{{field:Dettagli}}|vuoto}}"
        check(try render(conditional).fields == ["Extra"], "Hidden branch not asked before checkbox")
        check(try render(conditional, context).fields == ["Dettagli"], "Conditional branch discovers next field")
        context.variables["Dettagli"] = "nota"
        check(try render(conditional, context).text == "Accettonota", "All conditional fields substituted")
        context.variables["Extra"] = "Rifiuto"; context.fieldTruth["Extra"] = false
        check(try render("{{if:Extra|sì|no}}{{check:Extra|Accetto|Rifiuto}}", context).text == "noRifiuto", "Checkbox false with custom label and condition before definition")
        check(try render("{{var:Nome}}", context).text == "<Mario & C>", "Variable reference")
        check(try render("{{replace:a|{{upper:z}}|aba}}").text == "ZbZ", "Nested replacement expands")
        check(try render(#"{{replace:a\|b|X|a\|b}}"#).text == "X", "Literal pipe arguments")
        check(try render(#"{{regex:a\|b|X|abc}}"#).text == "XXc", "Regex alternation escaped delimiter")
        check(try render(#"{{upper:{{regex:a\|b|x|ab}}}}"#).text == "XX", "Nested regex preserves delimiter escapes")
        check(try render(#"{{regex:a\\\|b|X|a\|b}}"#).text == "X", "Regex matching literal pipe")
        check(try render(#"{{regex:(\d+)|[$1]|a12b3}}"#).text == "a[12]b[3]", "Regex captures and Unicode ranges")
        rejects { _ = try render("{{regex:[|X|abc}}") }
        check(try render("{{trim:  ciao \n}}").text == "ciao", "Trim")
        check(try render("{{length:👨‍👩‍👧‍👦è}}").text == "2", "Length counts graphemes")
        check(try render("{{urldecode:{{urlencode:è /&?}}}}").text == "è /&?", "URL Unicode roundtrip")
        check(try render("{{unbase64:{{base64:ciao🙂}}}}").text == "ciao🙂", "Base64 Unicode roundtrip")
        rejects { _ = try render("{{unbase64:?!}}") }
        rejects { _ = try render("{{urldecode:%ZZ}}") }
        let date = ISO8601DateFormatter().date(from: "2026-03-07T12:00:00Z")!
        let dated = RenderContext(date: date)
        check(try render("{{date:+1d|yyyy-MM-dd HH:mm|en_US|America/New_York}}", dated).text == "2026-03-08 07:00", "Offset uses target timezone across DST")
        check(try render("{{date:-1M|yyyy-MM-dd|en_US|UTC}}", dated).text == "2026-02-07", "Month offset")
        check(try render("{{time:+2h|HH:mm|en_US|UTC}}", dated).text == "14:00", "Hour offset")
        rejects { _ = try render("{{date:yyyy|it_IT|Not/AZone}}", dated) }
        rejects { _ = try render(String(repeating: "a", count: 4_000_001)) }
        rejects { _ = try render("{{replace:a|" + String(repeating: "b", count: 1001) + "|" + String(repeating: "a", count: 5000) + "}}") }
        rejects { _ = try render("{{regex:a|" + String(repeating: "b", count: 1001) + "|" + String(repeating: "a", count: 5000) + "}}") }
        let start = Date()
        rejects { _ = try render("{{regex:^(a+)+b$|X|" + String(repeating: "a", count: 26) + "}}") }
        check(Date().timeIntervalSince(start) < 3, "Slow regex cancelled at progress callback")
        print("TemplateTests: \(checks) checks passed")
    }
}
